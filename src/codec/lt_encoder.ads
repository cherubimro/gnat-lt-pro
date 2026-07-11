pragma SPARK_Mode (On);
with Lt_Types;
with Lt_Rng;

--  LT encoder: produce one coding symbol from a group's K source symbols for a
--  given per-packet seed.  A "clear" packet is just the degree-1 case and does
--  not need this (the shell sends source symbols directly); this covers the
--  XOR-combined coding packets that provide the erasure resilience.
package Lt_Encoder is

   procedure Encode_Symbol
     (Src   : Lt_Types.Symbol_Array;
      Seed  : Lt_Rng.U64;
      Deg   : out Lt_Types.Degree_Range;
      Ids   : out Lt_Types.Id_Array;
      Coded : out Lt_Types.Symbol)
   with
     Pre => Src'First = 0 and then Src'Last = Lt_Types.K - 1
            and then Ids'First = 1 and then Ids'Last = Lt_Types.K;

end Lt_Encoder;
