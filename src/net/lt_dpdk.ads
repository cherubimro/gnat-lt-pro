--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

--  Lt_Dpdk -- optional DPDK poll-mode transport (kernel bypass).
--
--  This is TRUSTED shell, not proven core: SPARK_Mode is Off throughout.  See
--  docs/ASSURANCE.md §5.1 for the assurance ledger -- selecting this transport
--  moves DPDK (EAL + mempool + the NIC PMD) and a small C shim onto the data
--  path, inside the TCB.  The kernel path remains the default.
--
--  The body is chosen at BUILD time by the WITH_DPDK external:
--
--    WITH_DPDK=no   (default) -> src/net/stub  : Available = False, no DPDK,
--                                                nothing linked, no C compiled.
--    WITH_DPDK=yes            -> src/net/dpdk  : real bindings to the C shim.
--
--  So a default build neither links nor mentions DPDK; `--with-dpdk` at run
--  time then fails cleanly with "not built with DPDK support".
--
--  The proven core is untouched by either choice: both paths hand the decoder
--  exactly the same 1472-byte Lt_Wire.Packet_Buffer.

with Lt_Wire;

package Lt_Dpdk with SPARK_Mode => Off is

   --  RX burst size.  Mirrors LT_BURST in lt_dpdk_shim.c.
   Batch : constant := 64;

   --  A contiguous run of packet buffers; the shim copies whole LT packets
   --  into it back-to-back, so Ada never holds a DPDK mbuf pointer.
   type Packet_Array is array (1 .. Batch) of aliased Lt_Wire.Packet_Buffer;

   function Available return Boolean;
   --  True iff this build has the DPDK backend compiled in.

   procedure Init (Eal_Args : String; Ok : out Boolean);
   --  EAL init + bring-up of the first available ethdev port.  Eal_Args is a
   --  whitespace-separated EAL command line, e.g.
   --    "--no-huge --file-prefix=ltrx -l 0 --vdev=net_memif0,role=server,..."
   --  (argv[0] is supplied internally).  Ok = False on any failure.

   procedure Set_Dst (Mac : String; Ok : out Boolean);
   --  Destination MAC, "aa:bb:cc:dd:ee:ff".  Default is broadcast, which is
   --  what a diode wants: the receiver need not be known to the sender.

   procedure Wait_Link (Timeout_Ms : Natural; Up : out Boolean);
   --  Bounded wait for the link to come up.  SENDERS ONLY: peers (memif,
   --  af_packet) connect asynchronously, and frames blasted at a down link are
   --  dropped.  A receiver must NOT call this -- as the memif server it has no
   --  peer until the sender arrives, so it would stall for the whole timeout
   --  before ever polling.  A down link is not fatal either way: a TX drop on a
   --  fountain-coded diode is indistinguishable from ordinary loss.

   procedure Rx_Burst (Bufs : in out Packet_Array; Count : out Natural);
   --  Poll the port.  Copies out up to Batch LT packets, each exactly
   --  Lt_Wire.Max_Buf_Len bytes; Count is how many.  Frames that are not ours
   --  (wrong EtherType or too short) are dropped inside the shim, so every
   --  buffer 1 .. Count is a full-length candidate packet -- the same contract
   --  the recvmmsg path gets from its `Len = Max_Buf_Len` check.

   procedure Tx (Buf : Lt_Wire.Packet_Buffer);
   --  Transmit one LT packet as a raw Ethernet frame.  A drop (link down, TX
   --  ring full) is silent: on a one-way diode there is no retransmission and
   --  the fountain code is designed to lose packets.

   procedure Fini;

end Lt_Dpdk;
