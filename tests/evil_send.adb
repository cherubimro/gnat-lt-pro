--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

pragma SPARK_Mode (Off);   --  adversarial helper: send one packet with a raw FILEID

with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Streams;
with Ada.Unchecked_Conversion;
with Interfaces;               use Interfaces;
with GNAT.Sockets;             use GNAT.Sockets;
with Lt_Types;
with Lt_Wire;

--  Send a single data packet carrying an arbitrary, UNsanitised FILEID to a
--  receiver, to test its FILEID hardening against a hostile source (not our
--  sanitising sender).  Usage: evil_send <ip> <port> <raw-name> [part_no]
procedure Evil_Send is
   subtype Wire_SEA is
     Ada.Streams.Stream_Element_Array (1 .. Lt_Wire.Max_Buf_Len);
   function To_SEA is
     new Ada.Unchecked_Conversion (Lt_Wire.Packet_Buffer, Wire_SEA);

   Sock    : Socket_Type;
   Buf     : Lt_Wire.Packet_Buffer;
   Payload : constant Lt_Types.Symbol := (others => 16#5A#);
   Last    : Ada.Streams.Stream_Element_Offset;
begin
   if Argument_Count < 3 then
      return;
   end if;
   declare
      Raw  : constant String := Argument (3);
      Name : constant String :=
        (if Raw'Length > Lt_Wire.File_Id_Len
         then Raw (Raw'First .. Raw'First + Lt_Wire.File_Id_Len - 1) else Raw);
      Part : constant Lt_Wire.U32 :=
        (if Argument_Count >= 4 then Lt_Wire.U32'Value (Argument (4)) else 0);
   begin
      Lt_Wire.Serialize (Name, 0, 0, Part, Payload, Buf);
      Create_Socket (Sock, Family_Inet, Socket_Datagram);
      Connect_Socket
        (Sock, (Family => Family_Inet, Addr => Inet_Addr (Argument (1)),
                Port => Port_Type (Natural'Value (Argument (2)))));
      Send_Socket (Sock, To_SEA (Buf), Last);
      Close_Socket (Sock);
   end;
end Evil_Send;
