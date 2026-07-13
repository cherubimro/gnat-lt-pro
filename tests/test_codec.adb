--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

pragma SPARK_Mode (Off);   --  trusted test harness (heap, I/O, RNG for the channel)

with Ada.Text_IO;       use Ada.Text_IO;
with Ada.Command_Line;  use Ada.Command_Line;
with Interfaces;         use Interfaces;
with Lt_Types;
with Lt_Rng;
with Lt_Sample;
with Lt_Encoder;
with Lt_Checksum;
with Lt_Decoder_Std;

--  End-to-end round-trip for one group of the LT codec, at production K.
--
--  For each configured loss level it builds a fresh random 10 MB group, emits K
--  degree-1 "clear" packets plus N_Coded XOR coding packets, drops a fraction of
--  ALL of them at random (a lossy one-way channel with no feedback), replays the
--  index set on the receiver side from the packet seed, peel-decodes, and checks:
--    * the decoder reports full success,
--    * every source symbol is byte-exact, and
--    * the whole-group checksum gate matches.
--  Exit status is 0 iff every trial passes.
procedure Test_Codec is

   K         : constant := Lt_Types.K;
   --  Pure LT coding: emit enough coding packets that the received count targets
   --  ~1.25 x K after loss (comfortably above the ~1.15x decode threshold).
   Recv_Num  : constant := 5;                   --  target received = 5/4 * K
   Recv_Den  : constant := 4;
   Max_Coded : constant := 18_000;              --  cap (enough for 30% at 1.25x)

   --  Coding packets to emit at a given loss so received ~= Recv_Num/Recv_Den*K.
   function Coded_For (Loss_Pct : Natural) return Natural is
      Total : constant Natural :=
        (Recv_Num * K * 100) / (Recv_Den * (100 - Loss_Pct));
   begin
      return Natural'Min (Max_Coded, Total);
   end Coded_For;

   --  Use the proved concrete instance (Max_Packets => 20_000, Max_Edges => 600_000).
   package Dec renames Lt_Decoder_Std;

   use type Lt_Types.Symbol;

   type Group_Ptr is access Lt_Types.Symbol_Array;
   type State_Ptr is access Dec.State;

   Src   : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
   Recov : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
   St    : constant State_Ptr := new Dec.State;

   --  Reproducible LCG standing in for the lossy channel + message source.
   Rng : Unsigned_64 := 0;
   function Rand return Unsigned_64 is
   begin
      Rng := Rng * 6364136223846793005 + 1442695040888963407;
      return Rng;
   end Rand;

   --  One trial at a given loss percentage and channel seed.  Returns True on a
   --  fully correct decode.
   function Run_Trial (Loss_Pct : Natural; Chan_Seed : Unsigned_64) return Boolean
   is
      N_Coded : constant Natural := Coded_For (Loss_Pct);
      Ids   : Lt_Types.Id_Array (1 .. K);
      Deg   : Lt_Types.Degree_Range;
      Coded : Lt_Types.Symbol;
      Seed  : Lt_Rng.U64;
      Gen   : Lt_Rng.Generator := Lt_Rng.Seeded (16#0123456789ABCDEF#);
      Ok    : Boolean;
      Recvd : Natural := 0;
      Success  : Boolean;
      Mismatch : Natural := 0;

      function Dropped return Boolean is (Rand mod 100 < Unsigned_64 (Loss_Pct));
   begin
      Rng := Chan_Seed;

      --  Fresh random source group.
      for I in Src.all'Range loop
         for B in Lt_Types.Symbol_Offset loop
            Src (I) (B) := Lt_Types.Byte (Rand and 16#FF#);
         end loop;
      end loop;

      Dec.Reset (St.all);

      --  Coding packets: encode, lose some, and re-derive the index set on the
      --  receiver side purely from the seed (as the real receiver will).
      for I in 1 .. N_Coded loop
         Lt_Rng.Next (Gen, Seed);
         Lt_Encoder.Encode_Symbol (Src.all, Seed, Deg, Ids, Coded);
         if not Dropped then
            declare
               RDeg : Lt_Types.Degree_Range;
               RIds : Lt_Types.Id_Array (1 .. K);
            begin
               Lt_Sample.Sample_Indices (Seed, RDeg, RIds);
               Dec.Add_Packet (St.all, RDeg, RIds, Coded, Ok);
            end;
            if Ok then Recvd := Recvd + 1; end if;
         end if;
      end loop;

      Dec.Decode (St.all, Recov.all, Success);

      for I in Src.all'Range loop
         if Recov (I) /= Src (I) then
            Mismatch := Mismatch + 1;
         end if;
      end loop;

      declare
         Cksum_Ok : constant Boolean :=
           Lt_Checksum.Fold (Recov.all) = Lt_Checksum.Fold (Src.all);
         Pass : constant Boolean := Success and Mismatch = 0 and Cksum_Ok;
      begin
         Put_Line ("  loss=" & Loss_Pct'Image & "%"
                   & "  received=" & Recvd'Image
                   & "  decoded=" & Success'Image
                   & "  mismatches=" & Mismatch'Image
                   & "  checksum=" & (if Cksum_Ok then "OK" else "BAD")
                   & "   -> " & (if Pass then "PASS" else "FAIL"));
         return Pass;
      end;
   end Run_Trial;

   Losses : constant array (Positive range <>) of Natural := [0, 10, 20, 30];
   Seeds  : constant array (Positive range <>) of Unsigned_64 :=
     [16#A5A5_1234_DEAD_BEEF#, 16#0F0F_9E37_79B9_7C15#];
   All_Pass : Boolean := True;
begin
   Put_Line ("LT codec round-trip  (K=" & K'Image
             & "  target received = " & Natural'Image (Recv_Num)
             & "/" & Natural'Image (Recv_Den) & " x K)");
   for L of Losses loop
      for Sd of Seeds loop
         if not Run_Trial (L, Sd) then
            All_Pass := False;
         end if;
      end loop;
   end loop;

   New_Line;
   if All_Pass then
      Put_Line ("ALL TRIALS PASS");
   else
      Put_Line ("SOME TRIALS FAILED");
      Set_Exit_Status (1);
   end if;
end Test_Codec;
