pragma SPARK_Mode (On);
with Lt_Soliton;

package body Lt_Sample is

   procedure Sample_Indices
     (Seed : Lt_Rng.U64;
      Deg  : out Degree_Range;
      Ids  : out Id_Array)
   is
      G    : Lt_Rng.Generator := Lt_Rng.Seeded (Seed);
      U    : Long_Float;
      Pool : array (Lt_Types.Source_Id) of Lt_Types.Source_Id;
      RN   : Natural;
      J    : Lt_Types.Source_Id;
      Tmp  : Lt_Types.Source_Id;
   begin
      --  Degree from the robust-soliton distribution.
      Lt_Rng.Next_Unit (G, U);
      Deg := Lt_Soliton.Sample_Degree (U);

      --  Identity pool 0 .. K-1.
      for I in Lt_Types.Source_Id loop
         Pool (I) := I;
      end loop;

      Ids := (others => 0);

      --  Partial Fisher-Yates: draw Deg distinct ids into the front of Pool.
      for I in 0 .. Deg - 1 loop
         Lt_Rng.Next_Below (G, Lt_Types.K - I, RN);   --  RN in [0, K - I)
         J := I + RN;                                 --  J in [I, K-1]
         Tmp      := Pool (I);
         Pool (I) := Pool (J);
         Pool (J) := Tmp;
         Ids (I + 1) := Pool (I);
      end loop;
   end Sample_Indices;

end Lt_Sample;
