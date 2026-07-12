# gnat-lt-pro

**A high-assurance Ada/SPARK port of [lt-diode-pro](https://github.com/cherubimro/lt-diode-pro)** —
a rateless **LT (Luby Transform) fountain-code transport for one-way data diodes**.

Files are sent over a strictly one-way channel (a hardware data diode, or any lossy UDP link with
**no feedback and no retransmission**). The sender emits a stream of XOR-combined coding packets over
the **Robust Soliton Distribution**; the receiver reconstructs the file from *any* sufficiently large
subset that arrives. This repository is a clean-slate rewrite of both ends in Ada, with the codec
core written in the **SPARK** subset and proved free of run-time errors by `gnatprove`.

> Status: **Phases 0–3 complete** — the proven codec core, the proven wire format, a working
> **`sender_stream`**, and a working **`receiver_stream`** daemon: decoupled receive/decode, checksum
> gate, file and `--pipe` modes, **parallel multi-transfer** (routed by FILEID, each finalizing
> independently), and lost-trailer eviction. Sender → receiver reconstructs the stream
> **byte-for-byte** over UDP, with `recvmmsg` batching on the capture path. Remaining receiver parity
> (config file, `verify.log`) and Phases 4–5 are in the [Roadmap](#roadmap). Not yet a drop-in C
> replacement.

## Why Ada/SPARK, and why a clean-slate rewrite

The goal is **high assurance**: formal, machine-checked proof that the reconstruction path cannot
commit a run-time error (no buffer overrun, no integer overflow, no division by zero), on a codec
that must be correct on a link where *there is no way to ask for a packet again*.

Rewriting **both** ends (rather than staying wire-compatible with the C binaries) is what makes this
tractable, and it unlocked two simplifications the C code could not make:

- **The glibc-`rand()` mimicry is deleted.** The C reference reproduces glibc's `rand()` bit-for-bit
  (`rbsoliton.c: glibc_srand_r/glibc_rand_r`, Schrage seeding, 310-cycle warm-up) *only* so two
  independent processes agree on block selection. Owning both ends, we replace it with one clean,
  well-defined generator (**SplitMix64**, pure modular arithmetic) that SPARK proves trivially and
  that carries **no global state** — resolving the unsynchronised-global-RNG hazard the C `rng.h`
  itself warns about.
- **The soliton distribution is frozen and libm-free.** Because `k`, `c`, `delta` are compile-time
  constants, the whole degree distribution is a compile-time constant. Its only transcendental inputs
  are two scalars (`R = c·ln(k/δ)·√k` and `ln(R/δ)`), which are **frozen as reviewed constants**, so
  the table is built from exact IEEE arithmetic and is **bit-identical on every host** — which is
  exactly what lets an independent sender and receiver agree with no feedback.

## Architecture: proven core + trusted shell

SPARK cannot prove sockets, tasking or heap, so the design is layered. Everything a packet touches on
its way to being decoded is in the **proven** column; everything the OS touches is in the small,
enumerable **trusted** column. The full assurance case — what is proven, what is trusted, the
proof's assumptions, and how the trusted shell is justified — is in
[`docs/ASSURANCE.md`](docs/ASSURANCE.md).

| Layer | Mode | Contents |
|---|---|---|
| **`src/codec` — the codec core** | `SPARK_Mode => On` | RNG + coding-seed mix, robust-soliton PMF/CDF + sampler, index sampling, LT encoder, peeling decoder, XOR checksum, **wire (de)serialization** |
| **`src` — the I/O shell** | `SPARK_Mode => Off` (trusted Ada) | `sender_stream` (UDP send, stdin framing, pacing); `receiver_stream` (`recvmmsg` capture, decoupled decode task, hardened file output, checksum gate, `--pipe`); `lt_conf` (config file), `lt_log` (timestamped/levelled logging) |

The core is **allocation-free**: it operates on caller-supplied buffers with fixed-capacity working
storage, so any heap lives only in the trusted shell and the bounds stay provable. It is also
**global-state-free**: every generator is threaded explicitly as an `in out` parameter.

### Modules (`src/codec/`)

| Unit | Purpose |
|---|---|
| `lt_types` | Symbol/byte types, group geometry (`K = 7375`, `Data_Len = 1356`), `Xor_Into` |
| `lt_rng` | SplitMix64 generator; uniform draws; no global state |
| `lt_soliton` | Robust Soliton cumulative table (frozen constants, spike `c=0.015` tuned for low overhead) + inverse-CDF degree sampler |
| `lt_sample` | Seed → degree + distinct source-index set (partial Fisher–Yates) — the one routine both ends must agree on |
| `lt_encoder` | Build one XOR coding symbol from a group + seed |
| `lt_decoder` | Generic peeling (belief-propagation) decoder over a caller-sized incidence store |
| `lt_decoder_std` | The concrete decoder instance (also the one `gnatprove` analyses) |
| `lt_checksum` | Whole-group XOR-fold integrity gate |
| `lt_wire` | Fixed 1472-byte packet format: `Serialize` / `Parse` (proved, so the receiver parses untrusted datagrams safely) |

## Build, test, prove

Toolchain: **GNAT 14.2.0 + gprbuild 24 + gnatprove** (SPARK). `tools/env.sh` puts them on `PATH`
(adjust the paths there if the toolchain moves).

```sh
./tools/build.sh           # gprbuild -> bin/{test_codec,sender_stream,receiver_stream,udp_decode_sink}
./bin/test_codec           # in-memory round-trip test matrix
./tools/prove.sh           # gnatprove over the whole SPARK core (incl. lt_wire)
./tools/receiver-test.sh   # end-to-end: sender_stream -> receiver_stream (file + pipe + parallel)
./tools/loopback-test.sh   # end-to-end: sender_stream -> decode sink, byte-compared
./tools/stress-test.sh     # adversarial soak of the trusted shell (attacks + floods + scale)
```

## Transports: kernel (default) or DPDK kernel-bypass (opt-in)

The proven core's entire input contract is a 1472-byte buffer, so it never names a socket —
**transport lives wholly in the trusted shell, and swapping it re-discharges none of the 175 proof
obligations.** Two are implemented:

| | Build | Run |
|---|---|---|
| **Kernel** (default) | `./tools/build.sh` | *(nothing — it is the default)* |
| **DPDK** (opt-in) | `WITH_DPDK=yes ./tools/build.sh` | `--with-dpdk --eal "<EAL args>"` |

A default build is DPDK-free in the strict sense: it compiles no C, links no DPDK, and `nm` finds
**zero `rte_*` symbols**. Passing `--with-dpdk` to such a binary exits 2 with *"built without DPDK
support"* — you cannot get DPDK into the TCB by accident.

On the DPDK path the LT packet rides **raw in an Ethernet frame** (EtherType `0x88B6`,
14 + 1472 = 1486 ≤ 1500 MTU): no IP, no UDP, no fragmentation. `rte_eth_rx_burst` replaces
`recvmmsg` and `rte_eth_tx_burst` replaces `Send_Socket`; `Handle`, `Lt_Wire.Parse`, the decoder and
the checksum gate are byte-for-byte the same code.

```sh
WITH_DPDK=yes ./tools/build.sh     # needs libdpdk via pkg-config (DPDK_PREFIX=... or libdpdk-dev)
./tools/dpdk-test.sh               # exercises the DPDK code path — no root, no hugepages, no NIC
```

### What that test proves, and what it does not

`dpdk-test.sh` joins the two ends with the **memif** PMD — a *shared-memory pipe between two
processes on one machine*. It is a real ethdev port, so it genuinely exercises EAL bring-up, the C
shim, `rte_eth_rx_burst`/`rte_eth_tx_burst` and the raw-Ethernet framing, and it shows transfers
decode byte-exact with the checksum gate intact. **But memif is not kernel bypass and does not cross
a wire.** It needs no root precisely *because* it bypasses nothing.

### Real kernel bypass (two physical machines) — the honest requirements

> **Full step-by-step recipe: [`KERNEL-BYPASS.TXT`](KERNEL-BYPASS.TXT)** — IOMMU, hugepages, binding
> a spare NIC, running non-root, and a troubleshooting section.

| | Needs root? | Kernel bypassed? |
|---|---|---|
| `memif` (the test above) | no | **no** — shared memory, one machine |
| `af_packet` (`--vdev=net_af_packet0,iface=eth0`) | no, with `setcap cap_net_raw,cap_net_admin+ep` | **no** — frames still traverse the kernel |
| `vfio-pci` (true bypass) | **yes, for setup** | **yes** |

True bypass needs, once, as root: an IOMMU (`intel_iommu=on`, BIOS + reboot), hugepages, and
`dpdk-devbind.py -b vfio-pci <addr>` on a **spare** NIC — a bound NIC *disappears from the kernel*,
so never bind the one carrying your SSH session. The *runtime* can then be non-root (chown
`/dev/vfio/<group>`, a writable hugepage mount, a raised `RLIMIT_MEMLOCK`); without an IOMMU,
`noiommu` mode needs `CAP_SYS_RAWIO` — effectively root, and genuinely unsafe (unrestricted DMA).

**Also: the vendored DPDK in `../dpdk/deps` cannot do it at all.** It was built with
`-Denable_drivers=bus/vdev,...,net/memif` — no PCI NIC PMD, and our binary links **zero PCI/VFIO
symbols**. For two physical machines you need a DPDK carrying your NIC's PMD (Debian/Ubuntu:
`apt install libdpdk-dev`, which ships e1000/ixgbe/i40e/mlx5/…), then rebuild with
`DPDK_PREFIX` unset so the system `libdpdk.pc` is used.

### Two physical machines, for real

Both ends must share an L2 segment (same switch/VLAN, or a direct cable). Prefer wired: Wi-Fi and
cloud virtual networks usually drop unknown-EtherType frames — and `0x88B6` is exactly that.

**(a) `af_packet` — works today, no root at run time, but *not* bypass.** The NIC keeps its kernel
driver, so SSH keeps working and nothing needs rebinding:

```sh
sudo setcap cap_net_raw,cap_net_admin+ep ./bin/receiver_stream ./bin/sender_stream   # once

# receiver                                    # sender
./bin/receiver_stream --with-dpdk \           ./bin/sender_stream --with-dpdk \
  --eal "--no-huge --vdev=net_af_packet0,iface=eno1" \
                                                --eal "--no-huge --vdev=net_af_packet0,iface=enp2s0" \
  0 /var/spool/lt 1234 0                        0 0 1234 myfile 0 < myfile
```

Watch the frames from a third box: `sudo tcpdump -i eno1 ether proto 0x88b6`.

**(b) `vfio-pci` — real kernel bypass.** Needs a **spare** NIC, an IOMMU and root for setup:

```sh
# once, as root, on each machine — NEVER the NIC carrying your SSH session
echo 512 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
sudo modprobe vfio-pci
sudo dpdk-devbind.py --status-dev net              # find the spare NIC's PCI address
sudo ip link set eno2 down
sudo dpdk-devbind.py -b vfio-pci 0000:03:00.0      # it now vanishes from the kernel

# then (no --vdev: the PCI port is probed; no --no-huge: use the hugepages)
sudo ./bin/receiver_stream --with-dpdk --eal "-l 0" 0 /var/spool/lt 1234 0
sudo ./bin/sender_stream   --with-dpdk --eal "-l 1" 0 0 1234 myfile 0 < myfile

sudo dpdk-devbind.py -b e1000e 0000:03:00.0        # hand it back to the kernel
```

The `sudo` on the run lines can be dropped after chowning `/dev/vfio/<group>` to the user, making
the hugepage mount writable, and raising `RLIMIT_MEMLOCK` — but the **setup** above is root, and
without an IOMMU the `noiommu` fallback needs `CAP_SYS_RAWIO` (effectively root, and unsafe:
unrestricted DMA). That privilege envelope is part of the DPDK trade, not separate from it.

> **The trade, stated plainly.** DPDK moves its EAL, mempool and NIC PMD — a large third-party C
> body — onto the data path *inside the TCB*, together with a small mandatory C shim (DPDK's burst
> API is `static inline`, so there is no symbol for Ada to link against). Safety is unaffected: the
> core is still proved, and the checksum gate still turns any mis-decode into a detected `.corrupt`.
> What grows is what you must **trust**. The kernel path stays the assurance-maximal default.
> The full ledger is [`docs/ASSURANCE.md` §5.1](docs/ASSURANCE.md).

### Sender

```sh
cat payload | sender_stream [--progress] [--pace-us N] <IP> <port> <SEED> <name> <loss%>
```

Reads the payload from **stdin**, splits it into group-local ~10 MB groups, and emits over one UDP
port a **pure LT fountain stream** — loss-scaled XOR coding packets per group (no systematic clear
channel) — then a 5×-repeated end-of-transfer trailer carrying the exact size, group count and
whole-stream checksum. `SEED` and `loss%` must match the receiver. `--pace-us` throttles the send
(a real diode is paced by network backpressure; loopback is not). Coding packets carry only their
index — both ends derive the packet seed from `(SEED, group, index)` with `Lt_Rng.Coding_Seed`.

The degree distribution's spike constant (`c=0.015`, `lt_soliton`) was tuned empirically
(`tests/test_overhead`) so the receiver decodes reliably at **~1.15× K** received; the sender
provisions to ~1.25× after loss. Pure coding at this `c` is markedly more efficient than a
systematic clear+coding scheme, which the tuned distribution pushes to >1.4× — so the clear channel
was dropped, cutting sender traffic ~17% versus the earlier 1.5× target and simplifying both ends.

### Receiver

```sh
receiver_stream [--pipe] [--progress] [--config <file>] \
                [--max-inflight <n>] [--evict-timeout <s>] [<port> <spool> <SEED> <loss%>]
```

Reads a `key = value` **config file** (`--config <file>`, else `/etc/lt-diode/receiver.conf` if
present) for `port`, `spool`, `seed`, `loss`, `verify_log`; with those set the positional args are
optional (precedence: defaults < config < CLI). Each finalized transfer appends a structured verdict
line to **`verify.log`** (`<ts> <path> bytes=… verdict=ok|corrupt reason=ok|decode|checksum|size|eviction`).
A sandboxed **systemd unit** and an annotated `receiver.conf.example` ship in the repo.

A tight **capture loop** parses each datagram, **routes it to its transfer by FILEID**, and
accumulates it into a pre-allocated group decoder state — never decoding inline. A separate
**decode task** reconstructs each completed group, writes it to that transfer's output, and on the
trailer applies the whole-stream **checksum gate**. Up to `Max_Inflight` transfers are in flight at
once, each finalizing independently; bounded RAM (a shared pool of group states handed off through a
protected scheduler).

- **file mode** is a daemon (loops indefinitely) creating `<spool>/<name>` with
  `open(O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW)` (never overwrites, never follows a planted symlink;
  numbered `.1`, `.2`, … on collision) after sanitizing the FILEID to a safe basename, then writes a
  `.finished` (or `.corrupt`) marker per the gate.
- **`--pipe`** streams the decoded bytes straight to stdout, single-shot; the exit code is the verdict.
- A stalled transfer (lost trailer) is evicted after a 10 s idle timeout → `.corrupt`, **without
  disturbing the other in-flight transfers**.

*Verification:* `tools/receiver-test.sh` runs sender → `receiver_stream` in file mode, `--pipe`, and
**3 concurrent parallel transfers**, byte-comparing each (PASS at 3/12/25 MB, 1–3 groups). Sequential
transfers through one daemon and eviction-then-recovery are exercised too.

The capture loop drains the socket in batches with **`recvmmsg` (`MSG_WAITFORONE`)** — up to 64
datagrams per syscall, returning as soon as one is in hand — which is what lets it keep up. The ABI
`struct msghdr`/`mmsghdr` layout is hand-bound and guarded by a start-up size check.

**Throughput note.** With `recvmmsg` the receiver keeps up an order of magnitude faster than
one-at-a-time (`--pace-us 5` is reliable here vs. `40` before). The residual limit is the OS socket
buffer, which is small by default (`net.core.rmem_max`) and can't be raised without privilege on this
host — under a full no-pacing blast on loopback a group still occasionally drops below the decode
margin. A real deployment raises `rmem_max` (as the C reference documents) and/or is paced by the
diode link; the tools pace the sender to stay comfortably inside the margin.

### Test result

`test_codec` builds a fresh random 10 MB group, emits `K` clear + N coding packets, drops a fraction
of *all* of them at random, replays the index set on the receiver side from the packet seed,
peel-decodes, and checks byte-exact reconstruction **and** the whole-group checksum gate. Redundancy
is scaled with the loss (as the sender's `N_send = ceil(N_needed/(1-loss))` does):

```
loss= 0% received=11062 decoded=TRUE mismatches=0 checksum=OK -> PASS
loss=10% received=11095 decoded=TRUE mismatches=0 checksum=OK -> PASS
loss=20% received=11093 decoded=TRUE mismatches=0 checksum=OK -> PASS
loss=30% received=11052 decoded=TRUE mismatches=0 checksum=OK -> PASS
ALL TRIALS PASS
```

### Proof status (`gnatprove`, level 2)

**All 175 checks proved — 0 unproved, 0 justified.** The whole codec core — the peeling `Decode` and
the `lt_wire` packet parser included — is proved **AoRTE-clean** (no overflow, no out-of-bounds
indexing, no division by zero), with every functional contract, loop termination and initialization
check discharged and **no `pragma Assume`/justification anywhere**.

| Check family | Proved |
|---|---|
| Run-time checks (overflow / index / range / division) | 66 / 66 |
| Assertions & loop invariants | 31 / 31 |
| Functional contracts (`Valid`, pre/post) | 11 / 11 |
| Termination | 9 / 9 |
| Initialization + data dependencies | 30 / 30 |

How the harder obligations were closed:

- **The peeling decoder (`Decode`, 38 checks).** The incidence index (source → packets) is an
  intrusive singly-linked list over the edge slots (a `Head`/`Nxt` pair keyed by a plain edge
  counter) rather than a counting-sort CSR, so every access is in range from its subtype with no
  prefix-sum reasoning. Edge-span bounds come from a `Valid` ghost predicate carried through
  `Add_Packet`'s `Post` and `Decode`'s `Pre`; the ripple-stack and `Remn` decrements are protected
  by capacity guards the algorithm never actually trips.
- **`Add_Packet` (18 checks).** Well-formedness lives in `Pre`/`Post` (checked at call boundaries)
  rather than a type predicate — a predicate is re-checked after every component write, and the
  intermediate state (edge count bumped before packet count) transiently violates it.
- **The soliton table.** The cumulative accumulator's overflow bound falls out of the prover's
  loop-bound analysis once each term is asserted to lie in `[0, 2]`.

## Roadmap

- **Phase 0 — scaffold** ✅ project, build/prove scripts, toolchain wiring
- **Phase 1 — proven codec core** ✅ AoRTE-clean incl. the peeling decoder
- **Phase 2 — `sender_stream`** ✅ proven wire format + stdin framing, single-port emit, UDP, pacing,
  CLI; verified byte-exact over loopback
- **Phase 3 — `receiver_stream`** ✅ *done*: decoupled capture/decode, parallel per-FILEID transfers
  (runtime **`--max-inflight`**), **`recvmmsg` batching**, `O_EXCL|O_NOFOLLOW` writes, checksum gate,
  runtime-tunable **`--evict-timeout`** eviction, `--pipe`, config file + `verify.log` journal +
  systemd unit, timestamped/levelled logging (stderr/file/syslog), byte-exact end-to-end
- **Phase 4 — integration & hardening** ✅ `tools/check.sh` (build + proof + in-memory matrix +
  file/pipe/parallel receiver + loopback) and `tools/stress-test.sh` — an adversarial soak of the
  *trusted* shell (path-traversal / symlink attacks, garbage-datagram floods, 40 MB transfers,
  concurrency + eviction) that asserts the daemon never crashes and never writes outside its spool.
  It surfaced and fixed three real robustness bugs: a `Natural(part_no)` overflow crash on hostile
  packets, a blocking pool-acquire that could deadlock the capture loop, and idle-only eviction; the
  capture loop now has a defence-in-depth handler so no single datagram can take it down
- **Phase 5 — docs & assurance** ✅ codec core fully proved AoRTE (0 unproved, 0 justified);
  `man/man1/{sender,receiver}_stream.1` man pages; and the **written assurance argument**,
  [`docs/ASSURANCE.md`](docs/ASSURANCE.md) — what is proven, what is trusted, where the boundary
  sits and why, the proof's assumptions, and how the trusted shell is justified

## Attribution & license

Ada/SPARK port of **[lt-diode-pro](https://github.com/cherubimro/lt-diode-pro)** (Politehnica
University Timisoara), itself a fork of **melorian94/robust-soliton-LT-C** by Petra — the LT /
robust-soliton core, the feedback-free one-way design and the three-port UDP scheme are hers. As a
derivative of an **AGPL-3.0** work, this port is likewise **GNU AGPL-3.0**.
