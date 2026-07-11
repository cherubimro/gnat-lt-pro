pragma SPARK_Mode (On);

package body Lt_Checksum is

   function Fold (Src : Lt_Types.Symbol_Array) return Lt_Types.Symbol is
      Acc : Lt_Types.Symbol := Lt_Types.Zero_Symbol;
   begin
      for I in Src'Range loop
         Lt_Types.Xor_Into (Acc, Src (I));
      end loop;
      return Acc;
   end Fold;

end Lt_Checksum;
