--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

pragma SPARK_Mode (On);
with Lt_Types;

--  Peeling (belief-propagation) LT decoder for one group.
--
--  Received packets are accumulated with Add_Packet, each carrying its degree,
--  its distinct source-symbol ids (clear packets: the single id; coding packets:
--  replayed from the seed via Lt_Sample) and its payload symbol.  Decode then
--  peels: it repeatedly takes a packet reduced to a single unknown source,
--  recovers that symbol, and XORs it out of every other packet that referenced
--  it, cascading until the whole group is recovered or the ripple runs dry.
--
--  Allocation-free: all working storage is fixed-capacity, sized by the generic
--  formals, so the trusted shell owns any heap and the core stays provable.
generic
   Max_Packets : Positive;   --  capacity: how many received packets to hold
   Max_Edges   : Positive;   --  capacity: sum of all packet degrees (incidences)
package Lt_Decoder is

   type State is private;

   --  Incidence well-formedness, carried through the contracts (ghost, so it
   --  is proof-only): every packet's edge span lies inside 1 .. Ne, and every
   --  edge names a packet that exists.  Expressed via Pre/Post rather than a
   --  type predicate so the check lands only at call boundaries -- a type
   --  predicate would be re-checked after each component write, and the
   --  intermediate state of Add_Packet (Ne bumped before Np) transiently
   --  violates it even though the completed operation does not.
   function Valid (S : State) return Boolean with Ghost;

   --  Empty the decoder for a fresh group.
   procedure Reset (S : out State) with Post => Valid (S);

   --  Fold one received packet into the decoder.  Ok is False (packet dropped)
   --  if a capacity would be exceeded -- the transfer simply has fewer packets
   --  to peel from, exactly as a lost packet would.
   procedure Add_Packet
     (S       : in out State;
      Deg     : Lt_Types.Degree_Range;
      Ids     : Lt_Types.Id_Array;
      Payload : Lt_Types.Symbol;
      Ok      : out Boolean)
   with Pre  => Valid (S) and then Ids'First = 1 and then Ids'Last >= Deg,
        Post => Valid (S);

   --  Attempt to reconstruct the group.  Value holds the K recovered source
   --  symbols; Success is True iff every source symbol was recovered.
   procedure Decode
     (S       : in out State;
      Value   : out Lt_Types.Symbol_Array;
      Success : out Boolean)
   with Pre => Valid (S)
               and then Value'First = 0 and then Value'Last = Lt_Types.K - 1;

   function Packet_Count (S : State) return Natural;

private

   subtype Pkt_Count  is Natural  range 0 .. Max_Packets;
   subtype Edge_Count is Natural  range 0 .. Max_Edges;
   subtype Edge_Pos   is Positive range 1 .. Max_Edges;       --  1-based edge slot
   subtype Pkt_Index  is Positive range 1 .. Max_Packets;

   type Edge_Ids  is array (1 .. Max_Edges)   of Lt_Types.Source_Id;
   type Edge_Pkts is array (1 .. Max_Edges)   of Pkt_Index;   --  owning packet / edge
   type Starts    is array (1 .. Max_Packets) of Edge_Pos;             --  edge start
   type Degrees   is array (1 .. Max_Packets) of Lt_Types.Degree_Range; --  edge count
   type Payloads  is array (1 .. Max_Packets) of Lt_Types.Symbol;

   --  Well-formedness carried across calls so the peeling loop's array accesses
   --  prove in range without re-deriving them: every packet's edge span lies
   --  inside 1 .. Ne, and every edge names a packet that exists.  A Ghost_Predicate
   --  is proof-only (no run-time cost) -- gnatprove assumes it on entry and must
   --  re-establish it after any change to State.
   type State is record
      Np   : Pkt_Count  := 0;                        --  packets held
      Ne   : Edge_Count := 0;                        --  edges (incidences) held
      Edge : Edge_Ids   := (others => 0);            --  concatenated source ids
      EPkt : Edge_Pkts  := (others => 1);            --  packet each edge belongs to
      Off  : Starts     := (others => 1);            --  packet p starts at Edge(Off(p))
      Dg   : Degrees    := (others => 1);            --  and spans Dg(p) edges
      Res  : Payloads   := (others => Lt_Types.Zero_Symbol);
   end record;

   function Valid (S : State) return Boolean is
     ((for all P in 1 .. S.Np => S.Off (P) + S.Dg (P) - 1 <= S.Ne)
        and then (for all E in 1 .. S.Ne => S.EPkt (E) <= S.Np));

end Lt_Decoder;
