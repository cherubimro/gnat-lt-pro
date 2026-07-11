pragma SPARK_Mode (On);
with Lt_Decoder;

--  The concrete decoder instance used by the transport (and the tests).  Making
--  it a library-level SPARK instantiation is what brings the generic decoder
--  body into `gnatprove`'s analysis: SPARK proves instances, not generics.
--
--  Capacities are sized for one 10 MB group at up to ~1.6 x K received packets
--  (K clear + coding overhead): Max_Packets bounds the received-packet table and
--  Max_Edges bounds the sum of their degrees (the incidence store).
package Lt_Decoder_Std is new Lt_Decoder
  (Max_Packets => 20_000,
   Max_Edges   => 600_000);
