pragma SPARK_Mode (Off);   --  measure/tune the codec's decode overhead

with Ada.Text_IO;  use Ada.Text_IO;
with Ada.Numerics.Long_Elementary_Functions;
use  Ada.Numerics.Long_Elementary_Functions;
with Interfaces;    use Interfaces;
with Lt_Types;
with Lt_Rng;
with Lt_Decoder_Std;

--  Sweep the robust-soliton spike constant c and the received-packet overhead,
--  reporting the pure-coding decode success rate.  The decoder is distribution
--  agnostic (it only sees degree + indices + payload), so we can build any
--  degree distribution here without touching the proven core, find the best c,
--  then freeze it back into lt_soliton.
procedure Test_Overhead is

   K : constant := Lt_Types.K;
   package Dec renames Lt_Decoder_Std;
   use type Lt_Types.Symbol;
   use type Lt_Types.Symbol_Array;
   use type Lt_Rng.U64;

   type Group_Ptr is access Lt_Types.Symbol_Array;
   type State_Ptr is access Dec.State;

   Src : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
   Rec : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
   St  : constant State_Ptr := new Dec.State;

   Kf     : constant Long_Float := Long_Float (K);
   Dlt : constant Long_Float := 0.001;

   subtype Degree_Range is Positive range 1 .. K;
   type Weight_Array is array (Degree_Range) of Long_Float;
   Cum      : Weight_Array;
   Total    : Long_Float;
   Mean_Deg : Long_Float;

   --  Build the unnormalised cumulative robust-soliton weights for spike c.
   procedure Build (C : Long_Float) is
      R     : constant Long_Float := C * Log (Kf / Dlt) * Sqrt (Kf);
      LRD   : constant Long_Float := Log (R / Dlt);
      Pivot : constant Integer    := Integer (Long_Float'Floor (Kf / R));
      Acc   : Long_Float := 0.0;
      Wsum  : Long_Float := 0.0;

      function Rho (D : Integer) return Long_Float is
        (if D = 1 then 1.0 / Kf else 1.0 / (Long_Float (D) * Long_Float (D - 1)));
      function Tau (D : Integer) return Long_Float is
        (if D <= Pivot - 1 then R / (Long_Float (D) * Kf)
         elsif D = Pivot then R * LRD / Kf else 0.0);
   begin
      for D in Degree_Range loop
         Acc := Acc + Rho (D) + Tau (D);
         Cum (D) := Acc;
         Wsum := Wsum + Long_Float (D) * (Rho (D) + Tau (D));
      end loop;
      Total := Acc;
      Mean_Deg := Wsum / Acc;
   end Build;

   function Sample_Degree (U : Long_Float) return Degree_Range is
      Target : constant Long_Float := U * Total;
      Lo : Degree_Range := 1;
      Hi : Degree_Range := K;
      Mid : Degree_Range;
   begin
      while Lo < Hi loop
         Mid := Lo + (Hi - Lo) / 2;
         if Cum (Mid) < Target then Lo := Mid + 1; else Hi := Mid; end if;
      end loop;
      return Lo;
   end Sample_Degree;

   --  Encode one coding packet from Seed with the current distribution and add
   --  it to the decoder (mirrors Lt_Sample, but with the tunable degree).
   procedure Add_Coded (Seed : Lt_Rng.U64) is
      G     : Lt_Rng.Generator := Lt_Rng.Seeded (Seed);
      U     : Long_Float;
      Deg   : Degree_Range;
      Pool  : array (0 .. K - 1) of Natural;
      Ids   : Lt_Types.Id_Array (1 .. K) := (others => 0);
      Coded : Lt_Types.Symbol := Lt_Types.Zero_Symbol;
      RN, J, Tmp : Natural;
      Ok    : Boolean;
   begin
      Lt_Rng.Next_Unit (G, U);
      Deg := Sample_Degree (U);
      for I in 0 .. K - 1 loop Pool (I) := I; end loop;
      for I in 0 .. Deg - 1 loop
         Lt_Rng.Next_Below (G, K - I, RN);
         J := I + RN;
         Tmp := Pool (I); Pool (I) := Pool (J); Pool (J) := Tmp;
         Ids (I + 1) := Pool (I);
      end loop;
      for I in 1 .. Deg loop
         Lt_Types.Xor_Into (Coded, Src (Ids (I)));
      end loop;
      Dec.Add_Packet (St.all, Deg, Ids, Coded, Ok);
   end Add_Coded;

   Rng : Unsigned_64 := 0;
   function Rand return Unsigned_64 is
   begin
      Rng := Rng * 6364136223846793005 + 1442695040888963407;
      return Rng;
   end Rand;

   function Trial (Clear, Coded : Natural; Chan_Seed : Unsigned_64) return Boolean
   is
      Success : Boolean;
      Seed    : Lt_Rng.U64;
      Gen     : Lt_Rng.Generator := Lt_Rng.Seeded (Chan_Seed xor 16#BEEF#);
      Ids     : Lt_Types.Id_Array (1 .. K);
      Ok      : Boolean;
      Pick    : Unsigned_64;
   begin
      Rng := Chan_Seed;
      for I in Src.all'Range loop
         for B in Lt_Types.Symbol_Offset loop
            Src (I) (B) := Lt_Types.Byte (Rand and 16#FF#);
         end loop;
      end loop;
      Dec.Reset (St.all);
      --  Clear packets: a random subset of Clear distinct source ids.
      declare
         Chosen : array (0 .. K - 1) of Boolean := (others => False);
         Got    : Natural := 0;
      begin
         while Got < Clear loop
            Pick := Rand mod Unsigned_64 (K);
            if not Chosen (Natural (Pick)) then
               Chosen (Natural (Pick)) := True;
               Got := Got + 1;
               Ids (1) := Natural (Pick);
               Dec.Add_Packet (St.all, 1, Ids, Src (Natural (Pick)), Ok);
            end if;
         end loop;
      end;
      for I in 1 .. Coded loop
         Lt_Rng.Next (Gen, Seed);
         Add_Coded (Seed);
      end loop;
      Dec.Decode (St.all, Rec.all, Success);
      return Success and then Rec.all = Src.all;
   end Trial;

   Trials : constant := 40;
   Overs  : constant array (Positive range <>) of Long_Float :=
     (1.12, 1.15, 1.18, 1.20, 1.25, 1.30, 1.35, 1.40);

   procedure Sweep (Label : String; Clear : Natural) is
   begin
      Put ("  " & Label & "  |");
      for Over of Overs loop
         declare
            Recvd : constant Natural := Natural (Over * Kf);
            Coded : constant Integer := Recvd - Clear;
            Wins  : Natural := 0;
         begin
            for T in 1 .. Trials loop
               if Coded >= 0
                 and then Trial (Clear, Coded, Unsigned_64 (T) * 2654435761)
               then
                  Wins := Wins + 1;
               end if;
            end loop;
            Put (Wins'Image & "/" & Trials'Image & " ");
         end;
      end loop;
      New_Line;
   end Sweep;
begin
   Build (0.015);
   Put_Line ("Overhead at c=0.015  (K =" & K'Image & "," & Trials'Image
             & " trials, received = factor x K)");
   Put_Line ("             | x1.12 x1.15 x1.18 x1.20 x1.25 x1.30 x1.35 x1.40");
   Sweep ("pure coding    ", 0);
   Sweep ("sys, 15% loss  ", (K * 85) / 100);
   Sweep ("sys, 30% loss  ", (K * 70) / 100);
end Test_Overhead;
