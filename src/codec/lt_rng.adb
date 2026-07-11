pragma SPARK_Mode (On);

package body Lt_Rng is

   use type Interfaces.Unsigned_64;

   --  SplitMix64 constants (Steele, Lea & Flood, 2014).
   Gamma : constant U64 := 16#9E3779B97F4A7C15#;
   Mix_1 : constant U64 := 16#BF58476D1CE4E5B9#;
   Mix_2 : constant U64 := 16#94D049BB133111EB#;

   --  2.0**53 as an exact Long_Float constant (no run-time exponentiation).
   Two_53 : constant Long_Float := 9_007_199_254_740_992.0;

   function Seeded (Seed : U64) return Generator is
      (Generator'(State => Seed));

   procedure Next (G : in out Generator; Value : out U64) is
      Z : U64;
   begin
      G.State := G.State + Gamma;
      Z := G.State;
      Z := (Z xor Interfaces.Shift_Right (Z, 30)) * Mix_1;
      Z := (Z xor Interfaces.Shift_Right (Z, 27)) * Mix_2;
      Z := Z xor Interfaces.Shift_Right (Z, 31);
      Value := Z;
   end Next;

   procedure Next_Unit (G : in out Generator; U : out Long_Float) is
      V : U64;
      N : U64;
   begin
      Next (G, V);
      N := Interfaces.Shift_Right (V, 11);        --  top 53 bits, in [0, 2**53)
      pragma Assert (N <= 2**53 - 1);
      U := Long_Float (N) / Two_53;
   end Next_Unit;

   procedure Next_Below (G : in out Generator; Bound : Positive; R : out Natural)
   is
      V : U64;
   begin
      Next (G, V);
      R := Natural (V mod U64 (Bound));
   end Next_Below;

   --  SplitMix64 finalizer applied to a linear combination of the inputs.
   function Coding_Seed (Seed, Group, Idx : U64) return U64 is
      Z : U64 := Seed + Group * Gamma + Idx * Mix_1;
   begin
      Z := (Z xor Interfaces.Shift_Right (Z, 30)) * Mix_1;
      Z := (Z xor Interfaces.Shift_Right (Z, 27)) * Mix_2;
      return Z xor Interfaces.Shift_Right (Z, 31);
   end Coding_Seed;

end Lt_Rng;
