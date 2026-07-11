pragma SPARK_Mode (Off);   --  verification tool: receive a sender stream, decode it

with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Streams;
with Ada.Unchecked_Conversion;
with Interfaces;               use Interfaces;
with GNAT.Sockets;             use GNAT.Sockets;
with GNAT.OS_Lib;
with Lt_Types;
with Lt_Rng;
with Lt_Sample;
with Lt_Checksum;
with Lt_Wire;
with Lt_Decoder_Std;

--  Minimal decode sink for Phase-2 verification (NOT the Phase-3 daemon): binds
--  a UDP port, decodes the sender's fountain stream group-by-group with the
--  proven decoder, writes the reconstructed bytes to a file, and checks the
--  end-of-transfer checksum.  The sender emits groups in order, so one decode
--  context processed sequentially suffices here.
--
--  Usage: udp_decode_sink <port> <SEED> <out-file>   (SEED must match sender)
procedure Udp_Decode_Sink is

   K            : constant := Lt_Types.K;
   Data_Len     : constant := Lt_Types.Data_Len;
   Group_Stride : constant := K * Data_Len;

   package Dec renames Lt_Decoder_Std;
   use type Lt_Types.Symbol;
   use type Interfaces.Unsigned_32;
   use type Ada.Streams.Stream_Element_Offset;
   use type GNAT.OS_Lib.File_Descriptor;

   subtype Wire_SEA is
     Ada.Streams.Stream_Element_Array (1 .. Lt_Wire.Max_Buf_Len);
   function To_Buf is
     new Ada.Unchecked_Conversion (Wire_SEA, Lt_Wire.Packet_Buffer);

   Max_Groups : constant := 8;                 --  verification cap (~80 MB)

   type Group_Ptr is access Lt_Types.Symbol_Array;
   type State_Ptr is access Dec.State;

   Sock   : Socket_Type;
   Rec    : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
   States : array (0 .. Max_Groups - 1) of State_Ptr := (others => null);

   Seed   : Unsigned_64;
   Out_FD : GNAT.OS_Lib.File_Descriptor;

   Cksum_Acc     : Lt_Types.Symbol := Lt_Types.Zero_Symbol;
   Trailer_Cksum : Lt_Types.Symbol := Lt_Types.Zero_Symbol;
   Written       : Unsigned_64 := 0;
   Total_Bytes   : Unsigned_64 := 0;
   Num_Groups    : Unsigned_32 := 0;

   Decode_Fail : Natural := 0;
   Recv_Count  : Natural := 0;

   --  Accumulate a packet into its group's decoder state.  Cheap (no decode),
   --  so the receive loop never stalls and the socket buffer does not overflow.
   procedure Add (Group : Unsigned_32; Part : Unsigned_32;
                  Payload : Lt_Types.Symbol) is
      G   : constant Natural := Natural (Group);
      Ids : Lt_Types.Id_Array (1 .. K);
      Deg : Lt_Types.Degree_Range;
      Ok  : Boolean;
   begin
      if G >= Max_Groups then
         return;
      end if;

      if Part < Unsigned_32 (K) then                     --  clear packet
         Ids (1) := Natural (Part);
         Dec.Add_Packet (States (G).all, 1, Ids, Payload, Ok);
      else                                               --  coding packet
         declare
            Idx   : constant Natural := Natural (Part) - K;
            CSeed : constant Unsigned_64 :=
              Lt_Rng.Coding_Seed (Seed, Unsigned_64 (Group), Unsigned_64 (Idx));
         begin
            Lt_Sample.Sample_Indices (CSeed, Deg, Ids);
            Dec.Add_Packet (States (G).all, Deg, Ids, Payload, Ok);
         end;
      end if;
   end Add;

begin
   if Argument_Count /= 3 then
      Put_Line (Standard_Error, "usage: udp_decode_sink <port> <SEED> <out-file>");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   Seed   := Unsigned_64'Value (Argument (2));
   Out_FD := GNAT.OS_Lib.Create_File (Argument (3), GNAT.OS_Lib.Binary);
   if Out_FD = GNAT.OS_Lib.Invalid_FD then
      Put_Line (Standard_Error, "cannot create " & Argument (3));
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   --  Pre-allocate/zero every group state up front so no 19 MB allocation
   --  stalls the receive loop (which would burst-drop on loopback).
   for G in States'Range loop
      States (G) := new Dec.State;
      Dec.Reset (States (G).all);
   end loop;

   Create_Socket (Sock, Family_Inet, Socket_Datagram);
   Set_Socket_Option (Sock, Socket_Level, (Reuse_Address, True));
   --  Big receive buffer: the sender bursts ~11k packets/group with no pacing,
   --  so a small buffer would drop on loopback (the fountain code tolerates the
   --  rest, but keep the loss-free path clean).
   Set_Socket_Option (Sock, Socket_Level, (Receive_Buffer, 33_554_432));
   Bind_Socket (Sock, (Family => Family_Inet, Addr => Any_Inet_Addr,
                       Port => Port_Type (Natural'Value (Argument (1)))));
   Set_Socket_Option
     (Sock, Socket_Level, (Receive_Timeout, Timeout => 5.0));

   loop
      declare
         Buf  : Wire_SEA;
         Last : Ada.Streams.Stream_Element_Offset;
         From : Sock_Addr_Type;
      begin
         Receive_Socket (Sock, Buf, Last, From);
         exit when Last /= Buf'Last;                --  short/garbage datagram
         Recv_Count := Recv_Count + 1;

         declare
            PB        : constant Lt_Wire.Packet_Buffer := To_Buf (Buf);
            File_Size : Unsigned_64;
            Group     : Unsigned_32;
            Part      : Unsigned_32;
            Payload   : Lt_Types.Symbol;
         begin
            Lt_Wire.Parse (PB, File_Size, Group, Part, Payload);
            if Part = Lt_Wire.Part_Eot then
               Total_Bytes   := File_Size;
               Num_Groups    := Group;
               Trailer_Cksum := Payload;
               exit;
            else
               Add (Group, Part, Payload);
            end if;
         end;
      exception
         when Socket_Error =>
            Put_Line (Standard_Error, "[sink] receive timeout / no trailer");
            exit;
      end;
   end loop;
   Close_Socket (Sock);

   --  All packets in: decode every group in order and write the payload.
   for G in 0 .. Natural (Num_Groups) - 1 loop
      declare
         Success : Boolean := False;
         Remain  : constant Unsigned_64 :=
           (if Total_Bytes > Written then Total_Bytes - Written else 0);
         N_Bytes : constant Natural :=
           Natural (Unsigned_64'Min (Unsigned_64 (Group_Stride), Remain));
         N       : Integer;
         pragma Unreferenced (N);
      begin
         if G < Max_Groups and then States (G) /= null then
            Dec.Decode (States (G).all, Rec.all, Success);
         end if;
         if Success then
            Lt_Types.Xor_Into (Cksum_Acc, Lt_Checksum.Fold (Rec.all));
            if N_Bytes > 0 then
               N := GNAT.OS_Lib.Write (Out_FD, Rec.all'Address, N_Bytes);
               Written := Written + Unsigned_64 (N_Bytes);
            end if;
         else
            Decode_Fail := Decode_Fail + 1;
         end if;
      end;
   end loop;

   GNAT.OS_Lib.Close (Out_FD);

   Put_Line (Standard_Error,
     "[sink] packets=" & Recv_Count'Image
     & "  groups=" & Num_Groups'Image
     & "  bytes=" & Total_Bytes'Image
     & "  written=" & Written'Image
     & "  decode_fail=" & Decode_Fail'Image);

   if Decode_Fail = 0 and then Cksum_Acc = Trailer_Cksum
     and then Written = Total_Bytes
   then
      Put_Line (Standard_Error, "[sink] CHECKSUM OK");
   else
      Put_Line (Standard_Error, "[sink] CHECKSUM/SIZE MISMATCH");
      GNAT.OS_Lib.OS_Exit (1);
   end if;
end Udp_Decode_Sink;
