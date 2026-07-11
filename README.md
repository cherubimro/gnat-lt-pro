# gnat-lt-pro

**A high-assurance Ada/SPARK port of [lt-diode-pro](https://github.com/cherubimro/lt-diode-pro)** —
a rateless **LT (Luby Transform) fountain-code transport for one-way data diodes**.

Files are sent over a strictly one-way channel (a hardware data diode, or any lossy UDP link with
**no feedback and no retransmission**). The sender emits a stream of XOR-combined coding packets over
the **Robust Soliton Distribution**; the receiver reconstructs the file from *any* sufficiently large
subset that arrives. This repository is a clean-slate rewrite of both ends in Ada, with the codec
core written in the **SPARK** subset and proved free of run-time errors by `gnatprove`.

> Status: **Phase 0 + Phase 1 complete** — the proven, allocation-free codec core plus an end-to-end
> round-trip test. The networking/daemon shell (sender + receiver binaries) is Phases 2–5 (see
> [Roadmap](#roadmap)). This is a work in progress, not yet a drop-in replacement for the C tools.

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
| **`src/codec` — the codec core** | `SPARK_Mode => On` | RNG, robust-soliton PMF/CDF + sampler, index sampling, LT encoder, peeling decoder, XOR checksum |
| **I/O + concurrency shell** *(Phases 2–5)* | `SPARK_Mode => Off` (trusted Ada) | UDP sockets / `recvmmsg`/`sendmmsg`, worker tasks, file writes, the per-FILEID context table, config/CLI, logging |

The core is **allocation-free**: it operates on caller-supplied buffers with fixed-capacity working
storage, so any heap lives only in the trusted shell and the bounds stay provable. It is also
**global-state-free**: every generator is threaded explicitly as an `in out` parameter.

### Modules (`src/codec/`)

| Unit | Purpose |
|---|---|
| `lt_types` | Symbol/byte types, group geometry (`K = 7375`, `Data_Len = 1356`), `Xor_Into` |
| `lt_rng` | SplitMix64 generator; uniform draws; no global state |
| `lt_soliton` | Robust Soliton cumulative table (frozen constants) + inverse-CDF degree sampler |
| `lt_sample` | Seed → degree + distinct source-index set (partial Fisher–Yates) — the one routine both ends must agree on |
| `lt_encoder` | Build one XOR coding symbol from a group + seed |
| `lt_decoder` | Generic peeling (belief-propagation) decoder over a caller-sized incidence store |
| `lt_decoder_std` | The concrete decoder instance (also the one `gnatprove` analyses) |
| `lt_checksum` | Whole-group XOR-fold integrity gate |

## Build, test, prove

Toolchain: **GNAT 14.2.0 + gprbuild 24 + gnatprove** (SPARK). `tools/env.sh` puts them on `PATH`
(adjust the paths there if the toolchain moves).

```sh
./tools/build.sh          # gprbuild -> bin/test_codec
./bin/test_codec          # end-to-end round-trip test matrix
./tools/prove.sh          # gnatprove over the codec core
```

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

**107 of 121 checks proved (88%).** Fully discharged: all data-dependency, initialization (30),
functional-contract (9) and termination (8) checks; the leaf core (`lt_rng`, `lt_soliton`,
`lt_sample`, `lt_encoder`, `lt_checksum`) and the decoder's `Add_Packet` prove **AoRTE-clean**.

Remaining (the next proof task, not correctness bugs — the round-trip test exercises these paths):

- **13 run-time checks in `lt_decoder.Decode`** — the peeling loop's incidence-array index checks.
  Discharging them needs a data invariant tying the CSR offset/degree/edge-count fields together
  (`Off(p) + Dg(p) - 1 ≤ Ne ≤ Max_Edges`) plus ripple/cursor-bound predicates.
- **1 assertion in `lt_soliton.Build_Cum`** — a float upper-bound loop invariant at elaboration time;
  its underlying overflow check is already proved independently.

## Roadmap

- **Phase 0 — scaffold** ✅ project, build/prove scripts, toolchain wiring
- **Phase 1 — proven codec core** ✅ this repository
- **Phase 2 — `sender_stream`** — stdin framing, three-channel emit, UDP (+`sendmmsg`), pacing, CLI
- **Phase 3 — `receiver_stream`** — `recvmmsg`, per-FILEID parallel decode, `O_EXCL|O_NOFOLLOW`
  writes, checksum gate, eviction, `--pipe`, config file
- **Phase 4 — integration** — loopback, simulated loss, multi-file, ENOSPC; reuse the systemd/init units
- **Phase 5 — proof hardening** — close the decoder VCs; document the trusted boundary as the assurance argument

## Attribution & license

Ada/SPARK port of **[lt-diode-pro](https://github.com/cherubimro/lt-diode-pro)** (Politehnica
University Timisoara), itself a fork of **melorian94/robust-soliton-LT-C** by Petra — the LT /
robust-soliton core, the feedback-free one-way design and the three-port UDP scheme are hers. As a
derivative of an **AGPL-3.0** work, this port is likewise **GNU AGPL-3.0**.
