# Trusted-boundary assurance argument

This document is the assurance case for **gnat-lt-pro**: what is formally proven,
what is trusted, exactly where the line between them is drawn and why, what the
proof rests on, and how the trusted side is justified. It is written to be read
alongside the code — every claim points at a unit, a contract, or a piece of
evidence you can re-run.

## 1. Claim

> On the path that reconstructs a received file, the codec **cannot commit a
> language-defined run-time error** (no integer or float overflow, no
> out-of-bounds array access, no division by zero, no range violation), every
> loop **terminates**, and every functional contract and assertion holds —
> **machine-checked, with no assumptions injected into the proof**.
>
> Corrupt output is **never promoted**: a whole-stream checksum computed by the
> proven core gates every transfer, so a mis-decode (from loss, a hostile
> packet, or a fault in the trusted shell) is marked `.corrupt`, never
> `.finished`.

The claim is deliberately scoped. It is a **safety / integrity** claim about the
proven core plus the gate, *not* a proof of full functional correctness (see
§3.2) and *not* an availability guarantee (see §7).

## 2. The boundary

The system is two layers with a single, narrow interface between them.

| Layer | Files | `SPARK_Mode` | Status |
|---|---|---|---|
| **Proven codec core** | `src/codec/*` (`lt_types`, `lt_rng`, `lt_soliton`, `lt_sample`, `lt_encoder`, `lt_decoder`, `lt_decoder_std`, `lt_checksum`, `lt_wire`) | `On` | proved by `gnatprove` |
| **Trusted I/O shell** | `src/{sender,receiver}_stream.adb`, `src/lt_conf.*`, `src/lt_log.*`, `tests/*` | `Off` | reviewed + tested |

The core is **self-contained**: it makes no calls out to the trusted shell, has
no global mutable state (every generator is threaded as an `in out` parameter),
and never allocates — it operates on caller-supplied buffers with fixed-capacity
working storage. Data crosses the boundary only *into* the core, through a
handful of subprograms with explicit contracts. That is the entire interface:

```
Lt_Decoder.Reset  (S)                      -- Post => Valid (S)
Lt_Decoder.Add_Packet (S, Deg, Ids, ...)   -- Pre/Post => Valid (S)
Lt_Decoder.Decode (S, Value, Success)      -- Pre  => Valid (S)
Lt_Encoder.Encode_Symbol (...)
Lt_Sample.Sample_Indices (...)
Lt_Checksum.Fold (...)
Lt_Wire.Serialize / Parse (...)
```

## 3. What the proof establishes

`gnatprove` (level 2) over the core discharges **175 verification conditions,
0 unproved, 0 justified**:

- **Run-time checks** — no overflow (integer and floating-point), no array
  index or range violation, no division by zero, anywhere in the core.
- **Functional contracts** — the pre/postconditions, including the `Valid`
  well-formedness predicate that ties the decoder's incidence bookkeeping
  together (`Off(p)+Dg(p)-1 ≤ Ne`, `EPkt(e) ≤ Np`).
- **Loop termination** — every loop, including the peeling decoder's.
- **Initialization & data dependencies** — no read of an uninitialized value;
  declared data flow respected.

Reproduce with `./tools/prove.sh` (or `./tools/check.sh`, which fails the build
if any obligation is unproved).

### 3.1 Why this is the right target for a fountain codec

On a one-way diode there is **no retransmission** — a crash or a silently wrong
computation on the reconstruction path is unrecoverable. AoRTE removes the
entire class of language-level faults (the peeling decoder indexes a
15 000-entry incidence structure in a tight loop; a single off-by-one would be a
`Constraint_Error` mid-transfer). Proving it *once* is worth more than any amount
of testing of that specific class.

### 3.2 What the proof does **not** establish

- **Not** "the peeling decoder recovers the original message when enough packets
  arrive." That is a deep functional property; it is validated empirically
  (`tools/check.sh`, byte-exact at 0–30 % loss) and *contained* by the checksum
  gate (§6), not proved.
- **Not** anything about the trusted shell (§5).

## 4. The proof's trusted computing base (assumptions)

The proof is only as strong as what it rests on. These are the assumptions —
kept explicit and minimal:

1. **Toolchain soundness.** GNAT 14.2.0 correctly implements Ada semantics, and
   `gnatprove` with its provers (CVC5, Z3, alt-ergo) is sound. This is the
   standard SPARK assumption.
2. **No injected assumptions.** There is **no `pragma Assume` and no
   `pragma Annotate (… Justification)` anywhere** in the core — the "Justified"
   column of the proof summary is empty. The proof therefore relies on **no
   human-asserted lemma**; nothing is taken on faith inside the analysis.
3. **The precondition obligation is met at the boundary.** Each core subprogram
   is proved safe *given its precondition*. The only non-trivial one is
   `Valid (S)` on `Add_Packet` / `Decode`. `Reset` **establishes** it (proved
   `Post`) and `Add_Packet` **preserves** it (proved `Post`), so a caller that
   does `Reset` once before adding packets and decoding always satisfies it.
   The trusted shell does exactly that (reviewed: `receiver_stream.adb`
   `Sched.Try_Acquire → Dec.Reset` before any `Add_Packet`, `Decode` only on a
   reset-then-filled state). **This is the one obligation the proof pushes onto
   the trusted side; it is discharged by review.**
4. **Analyzed instance.** The generic `Lt_Decoder` is proved *as instantiated*
   in `lt_decoder_std` (`Max_Packets => 20_000, Max_Edges => 600_000`), so the
   concrete capacities are what the prover saw. Over-capacity input cannot
   violate memory safety: `Add_Packet` **drops** a packet that would exceed a
   capacity (returns `Ok => False`), exactly as a lost packet would.
5. **Data representation.** Standard Ada representation is assumed. The one
   hand-written representation that escapes the language model — the C
   `iovec`/`msghdr`/`mmsghdr` layout used by `recvmmsg` — is a *trusted*
   assumption, guarded at start-up by an `Object_Size` check that aborts on a
   mismatch (§5).
6. **Determinism.** Sender and receiver agree on block selection because both
   run the same `Lt_Rng` (SplitMix64, pure modular arithmetic) and the same
   frozen, `libm`-free Robust-Soliton table — so the CDF is bit-identical on
   every host. The three frozen scalars (`R`, `LRD` = ln(R/δ), and the spike
   `Pivot` in `lt_soliton.adb`) are reviewed numeric values.

## 5. The trusted shell — surface and how it is assured

Everything the *operating system* touches is trusted, because SPARK cannot model
sockets, syscalls, tasking or the heap. The surface is small and enumerable:

| Trusted concern | Where | How it is assured |
|---|---|---|
| UDP capture (`recvmmsg`), hand-bound C structs | `receiver_stream.adb` | ABI layout guarded by a start-up `Object_Size` check; a mismatch aborts before any I/O |
| UDP send | `sender_stream.adb` | `GNAT.Sockets`; send errors on a one-way link treated as delivered |
| File output | `receiver_stream.adb` `Open_Output` | `open(O_CREAT│O_EXCL│O_WRONLY│O_NOFOLLOW)` — never overwrites, never follows a symlink; numbered suffixes on collision |
| FILEID handling | `Sanitize` | basename only, `[A-Za-z0-9._-]`, rejects `.`/`..`/leading-dot/separators |
| Concurrency (capture task + decode task + protected `Sched`/`Slots`) | `receiver_stream.adb` | ownership partition (capture-owned vs decode-owned per-slot arrays) + protected objects; **ThreadSanitizer: 0 data races** |
| Config / logging | `lt_conf.*`, `lt_log.*` | bounded parsing; logging serialized by a protected object |

The trusted side is justified by four independent means:

1. **Small, reviewed surface.** The table above is the whole of it. The proven
   core carries the algorithmic complexity; the shell is I/O plumbing.
2. **Correct use of the proven interface.** The shell's only contract obligation
   is the `Valid` precondition (§4.3), met by construction.
3. **Concurrency validated dynamically.** The capture/decode split shares state
   only through protected objects and a strict ownership partition; **TSan
   reports zero races**. Task stacks are sized for the decoder's ~2.7 MB of
   locals (a `STORAGE_ERROR` here was found and fixed during bring-up), and
   every task body has an `exception when others` handler so a task can never
   die silently.
4. **Adversarially stress-tested.** `tools/stress-test.sh` soaks the shell with
   path-traversal and symlink attacks (via `tests/evil_send`, which crafts
   arbitrary un-sanitized FILEIDs), garbage-datagram floods, a 40 MB transfer,
   and concurrency + eviction, asserting the daemon **never crashes and never
   writes outside its spool**. It found and fixed three real robustness defects:
   a `Natural(part_no)` overflow crash on a hostile packet, a blocking
   pool-acquire that could deadlock the capture loop, and idle-only eviction
   that let stale slots accumulate under load. The capture loop now has a
   **defence-in-depth handler so no single datagram can take it down**.

### 5.1 Transport is a trusted-shell choice — and DPDK would be a TCB trade

Transport lives **entirely below the boundary of §2**. The proven core's whole
input contract is a 1472-byte buffer (`Lt_Wire.Packet_Buffer`, filled by
`Parse`, produced by `Serialize`); it never names a socket, an address family,
or a syscall. *Which* mechanism fills that buffer is a property of the trusted
shell alone. This has a sharp assurance consequence: **the transport can be
replaced without touching — and without re-discharging — a single one of the 175
proof obligations.** The boundary, the `Valid` obligation (§4.3), the integrity
gate (§6) and determinism (§4.6) are all transport-invariant.

Two transports are in scope. Only the first is implemented today; this
subsection records the analysis for the second **before** it is built, so its
cost is on paper rather than discovered later.

- **Kernel path (current default).** `GNAT.Sockets` UDP send on the sender; a
  `recvmmsg` batch drain on the receiver (`receiver_stream.adb:867`), the
  hand-bound `mmsghdr` ABI guarded by an `Object_Size` check. The trusted
  surface this adds is exactly the §5 table: a few syscalls the kernel itself
  bounds, reached through small reviewed C bindings. This is the
  **assurance-maximal** configuration and remains the default.
- **DPDK path (optional, evaluated, not implemented).** A userspace poll-mode
  driver would fill the same 1472-byte buffer from `rte_eth_rx_burst` instead of
  `recvmmsg`, and transmit with `rte_eth_tx_burst` instead of `Send_Socket`.
  Structurally this is a near-identity swap: the RX loop is already batch-shaped,
  `Handle` / `Parse` / the decoder / the gate are unchanged, and the shell
  already binds C by hand — so DPDK is the *same technique*, not a new one. A
  one-way diode is DPDK's ideal case (blast TX, promiscuous poll RX, no
  connection state), and the 1472-byte packet rides in a raw Ethernet payload
  (14 + 1472 = 1486 ≤ 1500 MTU) with no fragmentation.

**A C shim would be mandatory, not a convenience.** DPDK's data-path API is not
linkable from Ada: `rte_eth_rx_burst`, `rte_eth_tx_burst` and the `rte_pktmbuf_*`
accessors are `static inline` in the headers (DPDK inlines the burst path
deliberately — that is where its performance comes from), and `nm` confirms
**zero exported symbols** for them, while the *setup* calls (`rte_eal_init`,
`rte_eth_dev_configure`, `rte_eth_*_queue_setup`, `rte_eth_dev_start`) are real
symbols that bind directly. So `Import, Convention => C` reaches the port
bring-up but **cannot reach the packet loop**: there is no symbol to resolve.
The DPDK backend therefore necessarily adds a small C translation unit (~60–80
lines) exposing non-inline wrappers — `lt_dpdk_rx_burst` / `lt_dpdk_tx_burst` /
`lt_dpdk_mtod` / `lt_dpdk_free` — which Ada imports exactly as it imports
`recvmmsg` today. This is the same hand-bound-C technique already in the shell
(§5), and the shim is small enough to review line by line; but it is **a new C
file on the data path inside the TCB**, and the assurance ledger must say so
rather than treat the binding as free. `gprbuild` compiles it (`for Languages use
("Ada", "C")`); the DPDK flags come from `pkg-config libdpdk` — `--static --libs`
is required, not cosmetic, since it emits `--whole-archive` and without it the
PMD constructors never self-register and no port appears at run time.

The reason DPDK is **not** the default, and must be a deliberate opt-in, is the
trusted computing base:

| | Kernel path | DPDK path |
|---|---|---|
| In-process unproven C on the data path | small reviewed bindings (§5 table) | **DPDK EAL + mempool + the NIC PMD** — a large third-party C body |
| How Ada reaches the packet loop | direct `Import` of `recvmmsg` (a real symbol) | **an unavoidable C shim** — the burst/mbuf API is `static inline`, so nothing to link against |
| Who bounds a hostile datagram first | the kernel network stack, then `Handle` | the PMD, then `Handle` |
| Memory | kernel socket buffers | hugepages + mbuf pools; alloc/free discipline moves into the shell |
| Threading | the Ada capture/decode tasks | a pinned DPDK lcore feeding the existing decode task |
| Privilege / setup | a UDP port | `vfio-pci` bind of a **spare** NIC, an IOMMU, hugepages |

DPDK does not weaken the **safety** claim: the core is still proved AoRTE, and
the checksum gate still turns any mis-decode — including one caused by a PMD
fault or a dropped frame — into a detected `.corrupt`, never a `.finished`. What
it changes is the **trusted** side of the ledger. The project's thesis is a
small, enumerable trusted shell (§5: "the table above is the whole of it");
adding DPDK trades that for throughput by moving a large, unaudited C library
into the process, on the data path, inside the TCB. **That is a real assurance
regression, and it is recorded here as one — not amortized into a footnote.**

The trade is worth *offering* because it buys the one property the kernel path
cannot: it attacks the availability residual risk of §7 head-on. A dedicated
poll core with large RX descriptor rings does not suffer the "kernel cannot
drain the socket fast enough under a flood" loss that otherwise forces a raised
`net.core.rmem_max`; fewer dropped frames means fewer groups falling below the
decode margin. DPDK thus improves *whether a transfer completes*, at a cost paid
entirely in *what must be trusted for it to complete* — never in *whether a
completed transfer is correct*.

**Posture.** If the DPDK transport is built, it is a build-time / config-selected
backend behind the §2 buffer boundary, **not** a replacement. The kernel path
stays the default for assurance-sensitive deployments; the DPDK path is the
throughput option for a controlled link whose operator has explicitly accepted
DPDK in the TCB. The proof covers both identically — but this document, and any
deployment note, **must state which transport is in use, because the size of the
TCB differs between them.**

## 6. The integrity gate — safe degradation

The strongest part of the argument is that a fault in the *trusted* shell cannot
silently corrupt output. The sender's end-of-transfer trailer carries a
**whole-stream XOR checksum** computed by the proven `Lt_Checksum.Fold`; the
receiver re-folds the decoded groups (again `Lt_Checksum.Fold`) and compares.
Only on a match is a transfer promoted to `<name>.finished`; otherwise it becomes
`<name>.corrupt` with a `reason=` (`decode` / `checksum` / `size` /
`write-error` / `eviction`) in `verify.log`.

So even under the strongest trusted-side failure — a mis-route, a dropped write,
a partial decode — the outcome is a **detected, marked corruption**, never a
`.finished` file with wrong bytes. Integrity degrades safely; it does not fail
open. (The XOR fold is not cryptographic — it catches faults and loss, not a
deliberate forgery by an attacker who also rewrites the trailer.)

## 7. Residual risks and limitations

- **Functional decode correctness is tested, not proved** (§3.2). Mitigation:
  the checksum gate turns any residual mis-decode into a detected `.corrupt`.
- **The trusted shell is not proved.** Mitigation: small surface, review,
  TSan, and the stress soak — but it is assurance by argument and evidence, not
  by proof.
- **Availability, not safety.** On a link with no backpressure and an
  unraised `net.core.rmem_max`, a flood can drop legitimate packets; a group can
  fall below the decode margin. This affects *whether* a transfer completes, not
  *whether* a completed transfer is correct. Mitigation: `recvmmsg` batching, a
  large `SO_RCVBUF` request, and sender pacing; a raised `rmem_max` on a real
  deployment (documented in `receiver_stream(1)`); and, at the TCB cost recorded
  in §5.1, an optional userspace poll-mode (DPDK) transport.
- **Hand-bound ABI and the `syslog` varargs binding** are outside the language
  model. Mitigation: the `mmsghdr` layout is size-checked at start-up; the
  bindings are small and reviewed.

## 8. Reproducing the evidence

```sh
./tools/prove.sh          # gnatprove: 175 checks, 0 unproved, 0 justified
./tools/check.sh          # build + proof + in-memory matrix + end-to-end + loopback
./tools/stress-test.sh    # adversarial soak of the trusted shell (16 checks)
```

The assurance case is the composition of all three: **a proof that the
reconstruction path cannot fault, a checksum gate that never promotes corrupt
output, and a small trusted shell that is reviewed, race-checked and
stress-hardened.**
