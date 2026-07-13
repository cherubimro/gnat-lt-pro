--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

pragma SPARK_Mode (On);
with Lt_Sample;

package body Lt_Encoder is

   procedure Encode_Symbol
     (Src   : Lt_Types.Symbol_Array;
      Seed  : Lt_Rng.U64;
      Deg   : out Lt_Types.Degree_Range;
      Ids   : out Lt_Types.Id_Array;
      Coded : out Lt_Types.Symbol)
   is
   begin
      Lt_Sample.Sample_Indices (Seed, Deg, Ids);
      Coded := Lt_Types.Zero_Symbol;
      for I in 1 .. Deg loop
         Lt_Types.Xor_Into (Coded, Src (Ids (I)));
      end loop;
   end Encode_Symbol;

end Lt_Encoder;
