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
enumerable **trusted** column.

| Layer | Mode | Contents |
|---|---|---|
| **`src/codec` — the codec core** | `SPARK_Mode => On` | RNG + coding-seed mix, robust-soliton PMF/CDF + sampler, index sampling, LT encoder, peeling decoder, XOR checksum, **wire (de)serialization** |
| **`src` — the I/O shell** | `SPARK_Mode => Off` (trusted Ada) | `sender_stream` (UDP send, stdin framing, pacing); `receiver_stream` (UDP capture, decoupled decode task, hardened file output, checksum gate, `--pipe`) |

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
./tools/receiver-test.sh   # end-to-end: sender_stream -> receiver_stream (file + pipe)
./tools/loopback-test.sh   # end-to-end: sender_stream -> decode sink, byte-compared
```

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
receiver_stream [--pipe] [--progress] <port> <spool> <SEED> <loss%>
```

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
- **Phase 3 — `receiver_stream`** ✅ *daemon done*: decoupled capture/decode, parallel per-FILEID
  transfers, **`recvmmsg` batching**, `O_EXCL|O_NOFOLLOW` writes, checksum gate, eviction, `--pipe`,
  byte-exact end-to-end. *Remaining parity:* config file, `verify.log` journal
- **Phase 4 — integration** — loopback, simulated loss, multi-file, ENOSPC; reuse the systemd/init units
- **Phase 5 — proof hardening** ✅ codec core fully proved AoRTE (0 unproved, 0 justified); the
  remaining assurance task is documenting the trusted I/O boundary once Phases 2–3 land

## Attribution & license

Ada/SPARK port of **[lt-diode-pro](https://github.com/cherubimro/lt-diode-pro)** (Politehnica
University Timisoara), itself a fork of **melorian94/robust-soliton-LT-C** by Petra — the LT /
robust-soliton core, the feedback-free one-way design and the three-port UDP scheme are hers. As a
derivative of an **AGPL-3.0** work, this port is likewise **GNU AGPL-3.0**.
