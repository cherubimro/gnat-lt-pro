pragma SPARK_Mode (On);

package body Lt_Soliton is

   K : constant := Lt_Types.K;

   --  Frozen transcendental scalars (see spec).  The spike constant c = 0.015
   --  was tuned empirically (tests/test_overhead) to minimise decode overhead:
   --  it decodes reliably at ~1.15x K received, vs ~1.25x for the C reference's
   --  c = 0.07.  Computed once as
   --    R   = 0.015 * ln(7375/0.001) * sqrt(7375)
   --    LRD = ln(R / 0.001)
   R     : constant Long_Float := 20.37057078134522925;
   LRD   : constant Long_Float := 9.92184652951287660;
   Pivot : constant := 362;                         --  floor(K / R)

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
         declare
            T : constant Long_Float := Rho (D) + Tau (D);   --  in [0, 2]
         begin
            --  Bounding each term by 2 lets the prover's loop-bound analysis
            --  cap the accumulator (Acc <= 2*K = 14750, far below overflow).
            pragma Assert (T >= 0.0 and then T <= 2.0);
            Acc := Acc + T;
         end;
         W (D) := Acc;
         pragma Loop_Invariant (Acc >= 0.0);
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
