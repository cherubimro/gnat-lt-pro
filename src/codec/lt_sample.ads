pragma SPARK_Mode (On);
with Lt_Types;
with Lt_Rng;

--  Shared, deterministic block selection.  Given a per-packet seed, produce the
--  packet's degree and its set of distinct source-symbol ids.  This is the ONE
--  procedure the sender and receiver must agree on: the sender uses it to build
--  each coding packet, the receiver replays it (from the same seed carried in the
--  packet header) to learn which source symbols a received packet combined.
package Lt_Sample is

   subtype Degree_Range is Lt_Types.Degree_Range;
   subtype Id_Array     is Lt_Types.Id_Array;

   --  Fill Ids (1 .. Deg) with Deg distinct ids in 0 .. K-1, and return Deg.
   --  A partial Fisher-Yates shuffle of the identity pool, driven by the seed.
   procedure Sample_Indices
     (Seed : Lt_Rng.U64;
      Deg  : out Degree_Range;
      Ids  : out Id_Array)
   with
     Pre  => Ids'First = 1 and then Ids'Last = Lt_Types.K,
     Post => Deg <= Lt_Types.K
             and then (for all I in 1 .. Deg => Ids (I) in Lt_Types.Source_Id);

end Lt_Sample;
