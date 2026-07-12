pragma SPARK_Mode (Off);   --  trusted I/O shell over the proven codec core

with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Streams;
with Ada.Unchecked_Conversion;
with Ada.Calendar;             use Ada.Calendar;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Interfaces;               use Interfaces;
with System;
with System.Storage_Elements;  use System.Storage_Elements;
with GNAT.Sockets;             use GNAT.Sockets;
with GNAT.OS_Lib;
with Lt_Types;
with Lt_Rng;
with Lt_Encoder;
with Lt_Checksum;
with Lt_Wire;
with Lt_Log;

--  Zero-temp streaming LT sender: reads the payload from stdin, emits an LT
--  fountain stream over UDP, and never seeks or spools the input.  Coding is
--  group-local, so the input is read sequentially one ~10 MB group at a time.
--
--  Usage: sender_stream [--progress] <IP> <port> <SEED> <name> <loss%>
--    * SEED and loss% must match the receiver.
--    * <name> is the logical transfer id only (basename), not a file to open.
--    * Data is read from STDIN.
procedure Sender_Stream is

   K            : constant := Lt_Types.K;
   Data_Len     : constant := Lt_Types.Data_Len;
   Group_Stride : constant := K * Data_Len;         --  10_000_500 bytes / group

   subtype U32 is Interfaces.Unsigned_32;           --  = Lt_Wire.U32

   subtype Wire_SEA is
     Ada.Streams.Stream_Element_Array (1 .. Lt_Wire.Max_Buf_Len);
   function To_SEA is
     new Ada.Unchecked_Conversion (Lt_Wire.Packet_Buffer, Wire_SEA);

   type Group_Ptr is access Lt_Types.Symbol_Array;

   procedure Die (Msg : String) is
   begin
      Put_Line (Standard_Error, "[sender] " & Msg);
      GNAT.OS_Lib.OS_Exit (1);
   end Die;

   --  Parsed configuration.
   Progress : Boolean := False;
   Sock     : Socket_Type;

   Log_Dest  : Lt_Log.Dest_Type  := Lt_Log.To_Stderr;
   Log_File  : Unbounded_String  := Null_Unbounded_String;
   Log_Level : Lt_Log.Level_Type := Lt_Log.Info;

   --  Optional pacing: sleep ~Pace_Us microseconds per packet, applied in
   --  batches so it respects the runtime's delay granularity.  A real diode is
   --  paced by network backpressure; this is for loopback / slow receivers.
   Pace_Us    : Natural := 0;
   Pace_Cnt   : Natural := 0;
   Pace_Batch : constant := 128;

   ---------------------------------------------------------------------------
   --  UDP send (connected datagram socket).  On a one-way diode there is no
   --  return path, so a transient socket error is treated as "delivered".
   ---------------------------------------------------------------------------
   procedure Send_Buf (Buf : Lt_Wire.Packet_Buffer) is
      Data : constant Wire_SEA := To_SEA (Buf);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      Send_Socket (Sock, Data, Last);
      if Pace_Us > 0 then
         Pace_Cnt := Pace_Cnt + 1;
         if Pace_Cnt >= Pace_Batch then
            delay Duration (Pace_Us * Pace_Batch) / 1_000_000.0;
            Pace_Cnt := 0;
         end if;
      end if;
   exception
      when Socket_Error => null;
   end Send_Buf;

   ---------------------------------------------------------------------------
   --  Read one group (Group_Stride bytes) from stdin into Grp.  The buffer is
   --  zeroed first, so a short final read leaves the tail zero-padded.  Returns
   --  the count of REAL bytes read (0 = clean EOF on a group boundary).
   ---------------------------------------------------------------------------
   function Read_Group (Grp : Group_Ptr) return Natural is
      use GNAT.OS_Lib;
      Got : Integer := 0;
      R   : Integer;
   begin
      Grp.all := (others => Lt_Types.Zero_Symbol);
      while Got < Group_Stride loop
         R := Read (Standin, Grp.all'Address + Storage_Offset (Got),
                    Group_Stride - Got);
         exit when R <= 0;                          --  EOF or error
         Got := Got + R;
      end loop;
      return Got;
   end Read_Group;

   ---------------------------------------------------------------------------
   --  Emit one group: K clear (degree-1) packets, then N_Coding XOR packets.
   ---------------------------------------------------------------------------
   procedure Emit_Group
     (Grp      : Group_Ptr;
      Group_No : U32;
      N_Coding : Natural;
      Seed     : Unsigned_64;
      Name     : String)
   is
      Buf   : Lt_Wire.Packet_Buffer;
      Deg   : Lt_Types.Degree_Range;
      Ids   : Lt_Types.Id_Array (1 .. K);
      Coded : Lt_Types.Symbol;
      CSeed : Unsigned_64;
   begin
      --  Pure LT coding (no systematic clear channel): the tuned c=0.015
      --  distribution decodes at ~1.15x K, which is far more efficient than the
      --  clear+coding scheme (>1.4x) with this distribution.  part_no is simply
      --  the coding index; the receiver derives the seed from (SEED, group, idx).
      for Idx in 0 .. N_Coding - 1 loop
         CSeed := Lt_Rng.Coding_Seed (Seed, Unsigned_64 (Group_No),
                                      Unsigned_64 (Idx));
         Lt_Encoder.Encode_Symbol (Grp.all, CSeed, Deg, Ids, Coded);
         Lt_Wire.Serialize (Name, 0, Group_No, U32 (Idx), Coded, Buf);
         Send_Buf (Buf);
      end loop;
   end Emit_Group;

   procedure Send_Trailer
     (Total_Bytes : Unsigned_64;
      Num_Groups  : U32;
      Cksum       : Lt_Types.Symbol;
      Name        : String)
   is
      Buf : Lt_Wire.Packet_Buffer;
   begin
      Lt_Wire.Serialize (Name, Total_Bytes, Num_Groups, Lt_Wire.Part_Eot,
                         Cksum, Buf);
      for I in 1 .. 5 loop            --  5x for UDP robustness (may be lost)
         Send_Buf (Buf);
      end loop;
   end Send_Trailer;

   function Basename (S : String) return String is
      Cut : Natural := S'First - 1;
   begin
      for I in S'Range loop
         if S (I) = '/' then Cut := I; end if;
      end loop;
      declare
         B : constant String := S (Cut + 1 .. S'Last);
      begin
         return (if B'Length > Lt_Wire.File_Id_Len
                 then B (B'First .. B'First + Lt_Wire.File_Id_Len - 1)
                 else B);
      end;
   end Basename;

   --  CLI: skip leading --flags, then 5 positional args.
   Argi : Natural := 1;
begin
   while Argi <= Argument_Count
     and then Argument (Argi)'Length >= 2
     and then Argument (Argi) (Argument (Argi)'First .. Argument (Argi)'First + 1) = "--"
   loop
      declare
         F : constant String := Argument (Argi);
      begin
         if F = "--progress" then
            Progress := True;
         elsif F = "--pace-us" then
            Argi := Argi + 1;
            if Argi <= Argument_Count then
               Pace_Us := Natural'Value (Argument (Argi));
            end if;
         elsif F = "--syslog" then
            Log_Dest := Lt_Log.To_Syslog;
         elsif F = "--log" then
            Argi := Argi + 1;
            if Argi <= Argument_Count then
               Log_File := To_Unbounded_String (Argument (Argi));
               Log_Dest := Lt_Log.To_File;
            end if;
         elsif F = "--log-level" then
            Argi := Argi + 1;
            if Argi <= Argument_Count then
               declare
                  Ignore : Boolean;
               begin
                  Ignore := Lt_Log.Parse_Level (Argument (Argi), Log_Level);
               end;
            end if;
         else
            exit;
         end if;
      end;
      Argi := Argi + 1;
   end loop;

   Lt_Log.Init (Log_Dest, To_String (Log_File), "[sender]",
                "lt-diode-sender", Log_Level);

   if Argument_Count - Argi + 1 /= 5 then
      Put_Line (Standard_Error,
        "[usage] sender_stream [--progress] <IP> <port> <SEED> <name> <loss%>");
      Put_Line (Standard_Error,
        "        DATA is read from STDIN; <name> is the logical transfer id.");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   declare
      A_IP   : constant String := Argument (Argi);
      A_Port : constant String := Argument (Argi + 1);
      A_Seed : constant String := Argument (Argi + 2);
      A_Name : constant String := Basename (Argument (Argi + 3));
      A_Loss : constant String := Argument (Argi + 4);

      Seed     : Unsigned_64;
      Loss_Pct : Natural;
      N_Coding : Natural;

      Grp         : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
      Cksum       : Lt_Types.Symbol := Lt_Types.Zero_Symbol;
      Total_Bytes : Unsigned_64 := 0;
      Group_No    : U32 := 0;
      Real_Bytes  : Natural;

      T0, T_Last  : Time;
   begin
      begin
         Seed     := Unsigned_64'Value (A_Seed);
         Loss_Pct := Natural'Value (A_Loss);
      exception
         when others => Die ("SEED and loss% must be non-negative integers");
      end;
      if Loss_Pct > 90 then
         Die ("loss% must be in 0 .. 90");
      end if;

      --  Emit enough coding packets that after `loss` the receiver still gets
      --  ~1.25 x K (comfortably above the tuned distribution's ~1.15x decode
      --  threshold; see tests/test_overhead).
      declare
         L        : constant Float := Float (Loss_Pct) / 100.0;
         Recv_Tgt : constant Float := 1.25 * Float (K);
      begin
         N_Coding := Natural (Recv_Tgt / (1.0 - L));
      end;

      --  Connect the datagram socket.
      begin
         Create_Socket (Sock, Family_Inet, Socket_Datagram);
         Connect_Socket
           (Sock,
            (Family => Family_Inet,
             Addr   => Inet_Addr (A_IP),
             Port   => Port_Type (Natural'Value (A_Port))));
      exception
         when others => Die ("cannot open/connect UDP socket to "
                             & A_IP & ":" & A_Port);
      end;

      Lt_Log.Log (Lt_Log.Info,
        A_Name & " -> " & A_IP & ":" & A_Port
        & "  seed=" & A_Seed & "  loss=" & A_Loss & "%  coding/group="
        & N_Coding'Image);

      T0     := Clock;
      T_Last := T0;

      loop
         Real_Bytes := Read_Group (Grp);
         exit when Real_Bytes = 0;

         Emit_Group (Grp, Group_No, N_Coding, Seed, A_Name);
         Lt_Types.Xor_Into (Cksum, Lt_Checksum.Fold (Grp.all));
         Total_Bytes := Total_Bytes + Unsigned_64 (Real_Bytes);
         Group_No := Group_No + 1;

         if Progress then
            declare
               Now : constant Time := Clock;
            begin
               if Now - T_Last >= 1.0 then
                  T_Last := Now;
                  declare
                     Secs : constant Float :=
                       Float (Now - T0) + 1.0e-9;
                     MBs  : constant Float :=
                       Float (Total_Bytes) / 1_048_576.0 / Secs;
                  begin
                     Put_Line (Standard_Error,
                       "[sender] progress:" & Group_No'Image & " groups,"
                       & Unsigned_64'Image (Total_Bytes) & " bytes,"
                       & Integer'Image (Integer (MBs)) & " MB/s");
                  end;
               end if;
            end;
         end if;

         exit when Real_Bytes < Group_Stride;      --  short read => last group
      end loop;

      Send_Trailer (Total_Bytes, Group_No, Cksum, A_Name);

      Lt_Log.Log (Lt_Log.Info,
        "done:" & Group_No'Image & " groups,"
        & Unsigned_64'Image (Total_Bytes) & " bytes.");
      Close_Socket (Sock);
   end;
end Sender_Stream;
