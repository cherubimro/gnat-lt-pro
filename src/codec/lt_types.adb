pragma SPARK_Mode (On);

package body Lt_Types is

   procedure Xor_Into (Acc : in out Symbol; X : Symbol) is
   begin
      for I in Symbol_Offset loop
         Acc (I) := Acc (I) xor X (I);
         pragma Loop_Invariant
           (for all J in Symbol_Offset =>
              (if J <= I then Acc (J) = (Acc'Loop_Entry (J) xor X (J))
                         else Acc (J) = Acc'Loop_Entry (J)));
      end loop;
   end Xor_Into;

end Lt_Types;
