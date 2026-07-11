pragma SPARK_Mode (On);

package body Lt_Soliton is

   K : constant := Lt_Types.K;

   --  Frozen transcendental scalars (see spec).  Computed once as
   --    R   = 0.07 * ln(7375/0.001) * sqrt(7375)
   --    LRD = ln(R / 0.001)
   R     : constant Long_Float := 95.06266364627775545;
   LRD   : constant Long_Float := 11.46229157046002456;
   Pivot : constant := 77;                          --  floor(K / R)

   Kf : constant Long_Float := Long_Float (K);

   type Weight_Array is array (Degree) of Long_Float;

   --  Ideal-soliton mass rho(d).
   function Rho (D : Degree) return Long_Float is
     (if D = 1 then 1.0 / Kf
      else 1.0 / (Long_Float (D) * Long_Float (D - 1)))
   with Post => Rho'Result >= 0.0 and then Rho'Result <= 1.0;

   --  Robust correction tau(d): rises like R/(d*k), with a spike at Pivot.
   function Tau (D : Degree) return Long_Float is
     (if D <= Pivot - 1 then R / (Long_Float (D) * Kf)
      elsif D = Pivot then R * LRD / Kf
      else 0.0)
   with Post => Tau'Result >= 0.0 and then Tau'Result <= 1.0;

   --  Build the cumulative unnormalised weight table.
   function Build_Cum return Weight_Array with Global => null;

   function Build_Cum return Weight_Array is
      W   : Weight_Array := (others => 0.0);
      Acc : Long_Float   := 0.0;
   begin
      for D in Degree loop
         --  Each (Rho + Tau) term is in [0, 2], so after D steps Acc <= 2*D,
         --  which bounds the sum well away from Long_Float'Last (no overflow).
         pragma Assert (Rho (D) <= 1.0 and then Tau (D) <= 1.0);
         Acc   := Acc + Rho (D) + Tau (D);
         W (D) := Acc;
         pragma Loop_Invariant (Acc >= 0.0);
         pragma Loop_Invariant (Acc <= 2.0 * Long_Float (D));
      end loop;
      return W;
   end Build_Cum;

   Cum   : constant Weight_Array := Build_Cum;
   Total : constant Long_Float   := Cum (K);

   function Sample_Degree (U : Long_Float) return Degree is
      Target : constant Long_Float := U * Total;
      Lo : Degree := 1;
      Hi : Degree := K;
      Mid : Degree;
   begin
      --  Smallest d with Cum(d) >= Target.  Cum(K) = Total > Target (U < 1),
      --  so the invariant Lo <= Hi is preserved and Lo lands in 1 .. K.
      while Lo < Hi loop
         Mid := Lo + (Hi - Lo) / 2;         --  Lo <= Mid < Hi
         if Cum (Mid) < Target then
            Lo := Mid + 1;
         else
            Hi := Mid;
         end if;
         pragma Loop_Invariant (Lo <= Hi);
         pragma Loop_Variant (Decreases => Hi - Lo);
      end loop;
      return Lo;
   end Sample_Degree;

end Lt_Soliton;
