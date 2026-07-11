pragma SPARK_Mode (On);
with Lt_Types;

--  Whole-group integrity gate: the XOR-fold of every source symbol.  The sender
--  transmits this fold; the receiver recomputes it over the decoded group and
--  refuses to promote a transfer whose fold does not match (the "checksum gate"
--  of the C receiver).
package Lt_Checksum is

   function Fold (Src : Lt_Types.Symbol_Array) return Lt_Types.Symbol;

end Lt_Checksum;
