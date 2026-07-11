pragma SPARK_Mode (Off);   --  trusted I/O + concurrency shell over the proven core

with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Streams;
with Ada.Exceptions;           use Ada.Exceptions;
with Ada.Strings;              use Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
with Interfaces;               use Interfaces;
with Interfaces.C;
with GNAT.Sockets;             use GNAT.Sockets;
with GNAT.OS_Lib;
with Lt_Types;
with Lt_Rng;
with Lt_Sample;
with Lt_Checksum;
with Lt_Wire;
with Lt_Decoder_Std;

--  Streaming LT receiver.  A tight capture loop accumulates each group's packets
--  into a pre-allocated decoder state (never decoding inline, so the socket
--  buffer does not overflow); a separate decode task reconstructs completed
--  groups, writes them out and, on the end-of-transfer trailer, applies the
--  whole-stream checksum gate.  Bounded RAM: at most Pool_N group states live.
--
--  Usage: receiver_stream [--pipe] [--progress] <port> <spool> <SEED> <loss%>
--    * SEED must match the sender.  loss% is accepted for CLI parity.
--    * file mode: writes <spool>/<name> (+ .finished / .corrupt marker).
--    * --pipe    : streams the decoded bytes to stdout; exit code is the verdict.
procedure Receiver_Stream is

   K            : constant := Lt_Types.K;
   Data_Len     : constant := Lt_Types.Data_Len;
   Group_Stride : constant := K * Data_Len;

   package Dec renames Lt_Decoder_Std;
   use type Lt_Types.Symbol;
   use type Interfaces.Unsigned_32;
   use type Interfaces.C.int;
   use type Ada.Streams.Stream_Element_Offset;
   use type GNAT.OS_Lib.File_Descriptor;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   subtype Wire_SEA is
     Ada.Streams.Stream_Element_Array (1 .. Lt_Wire.Max_Buf_Len);
   function To_Buf is
     new Ada.Unchecked_Conversion (Wire_SEA, Lt_Wire.Packet_Buffer);

   type Group_Ptr is access Lt_Types.Symbol_Array;
   type State_Ptr is access Dec.State;

   ---------------------------------------------------------------------------
   --  Hardened output open: open(O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW).  O_EXCL
   --  never overwrites (and skips a planted symlink -> EEXIST); O_NOFOLLOW
   --  refuses to follow one.  Numbered suffixes on collision, as in the C.
   ---------------------------------------------------------------------------
   O_WRONLY   : constant := 1;
   O_CREAT    : constant := 8#100#;
   O_EXCL     : constant := 8#200#;
   O_NOFOLLOW : constant := 8#400000#;

   function C_Open (Path : Interfaces.C.char_array;
                    Flags, Mode : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "open";

   --  Shared config / handles (written before the first job is posted; the
   --  protected scheduler orders those writes before the decode task reads).
   Pipe_Mode : Boolean := False;
   Progress  : Boolean := False;
   Seed      : U64 := 0;
   Out_FD    : GNAT.OS_Lib.File_Descriptor := GNAT.OS_Lib.Invalid_FD;
   Out_Path  : Unbounded_String;

   ---------------------------------------------------------------------------
   --  Decode pipeline scheduling.
   ---------------------------------------------------------------------------
   Pool_N : constant := 6;                       --  bounded RAM: ~6 * 19 MB
   Ring_N : constant := Pool_N + 2;

   Pool : array (1 .. Pool_N) of State_Ptr;

   type Job is record
      Idx           : Natural := 0;
      Group         : U32     := 0;
      Is_Last       : Boolean := False;
      Corrupt       : Boolean := False;          --  forced corrupt (eviction)
      Total_Bytes   : U64     := 0;
      Trailer_Cksum : Lt_Types.Symbol := Lt_Types.Zero_Symbol;
   end record;

   type Free_Array is array (1 .. Pool_N) of Natural;
   type Ring_Array is array (0 .. Ring_N - 1) of Job;

   protected Sched is
      entry     Acquire (Idx : out Natural);     --  a free pool slot
      procedure Release (Idx : Natural);
      procedure Post    (J : Job);
      entry     Take    (J : out Job; Done : out Boolean);
      procedure Shutdown;
      procedure Finish  (V : Integer);
      entry     Wait_Done (V : out Integer);
   private
      Free_Stack : Free_Array;
      Free_Cnt   : Natural := 0;
      Ring       : Ring_Array;
      Head, Tail : Natural := 0;
      Count      : Natural := 0;
      Stopping   : Boolean := False;
      Finalized  : Boolean := False;
      Verdict    : Integer := 1;
   end Sched;

   protected body Sched is
      entry Acquire (Idx : out Natural) when Free_Cnt > 0 is
      begin
         Idx := Free_Stack (Free_Cnt);
         Free_Cnt := Free_Cnt - 1;
      end Acquire;

      procedure Release (Idx : Natural) is
      begin
         Free_Cnt := Free_Cnt + 1;
         Free_Stack (Free_Cnt) := Idx;
      end Release;

      procedure Post (J : Job) is
      begin
         Ring (Tail) := J;
         Tail := (Tail + 1) mod Ring_N;
         Count := Count + 1;
      end Post;

      entry Take (J : out Job; Done : out Boolean)
        when Count > 0 or else Stopping is
      begin
         if Count > 0 then
            J := Ring (Head);
            Head := (Head + 1) mod Ring_N;
            Count := Count - 1;
            Done := False;
         else
            Done := True;
         end if;
      end Take;

      procedure Shutdown is
      begin
         Stopping := True;
      end Shutdown;

      procedure Finish (V : Integer) is
      begin
         Verdict := V;
         Finalized := True;
      end Finish;

      entry Wait_Done (V : out Integer) when Finalized is
      begin
         V := Verdict;
      end Wait_Done;
   end Sched;

   ---------------------------------------------------------------------------
   --  Decode task: reconstruct each posted group, write it, run the gate.
   ---------------------------------------------------------------------------
   --  Dec.Decode carries ~2.7 MB of scratch arrays; a task's default stack is
   --  far smaller than the environment task's, so size it up.
   task Decode_Task with Storage_Size => 16 * 1024 * 1024;

   task body Decode_Task is
      J         : Job;
      Done      : Boolean;
      Rec       : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
      Zeros     : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
      Cksum_Acc : Lt_Types.Symbol := Lt_Types.Zero_Symbol;
      Written   : U64 := 0;
      Failed    : Boolean := False;
      Ignore    : Integer;
      pragma Unreferenced (Ignore);

      procedure Emit (Buf : Group_Ptr; N : Natural) is
      begin
         if N > 0 then
            Ignore := GNAT.OS_Lib.Write (Out_FD, Buf.all'Address, N);
            Written := Written + U64 (N);
         end if;
      end Emit;
   begin
      Zeros.all := (others => Lt_Types.Zero_Symbol);
      loop
         Sched.Take (J, Done);
         exit when Done;

         declare
            Success  : Boolean := False;
            Last_Grp : constant Boolean := J.Is_Last;
            --  Bytes this group contributes to the output.
            N_Full   : constant Natural := Group_Stride;
            N_Last   : constant Natural :=
              Natural (U64'Min (U64 (Group_Stride),
                       (if J.Total_Bytes > Written then J.Total_Bytes - Written
                        else 0)));
            N_Bytes  : constant Natural := (if Last_Grp then N_Last else N_Full);
         begin
            if not J.Corrupt then
               Dec.Decode (Pool (J.Idx).all, Rec.all, Success);
            end if;

            if Success then
               Lt_Types.Xor_Into (Cksum_Acc, Lt_Checksum.Fold (Rec.all));
               Emit (Rec, N_Bytes);
            else
               Failed := True;
               Emit (Zeros, N_Bytes);           --  keep the output aligned
            end if;

            Sched.Release (J.Idx);

            if Last_Grp then
               declare
                  Ok : constant Boolean :=
                    not Failed and then not J.Corrupt
                    and then Cksum_Acc = J.Trailer_Cksum
                    and then Written = J.Total_Bytes;
               begin
                  Put_Line (Standard_Error,
                    "[rs] transfer done: bytes=" & J.Total_Bytes'Image
                    & " written=" & Written'Image
                    & (if Ok then "  VERIFIED" else "  CORRUPT"));
                  Sched.Finish (if Ok then 0 else 1);
               end;
            end if;
         end;
      end loop;
   exception
      when E : others =>
         Put_Line (Standard_Error,
           "[rs] decode task exception: " & Exception_Information (E));
         Sched.Finish (1);                        --  unblock Wait_Done
   end Decode_Task;

   ---------------------------------------------------------------------------
   --  FILEID sanitization (basename; allow [A-Za-z0-9._-]; reject . / .. etc).
   ---------------------------------------------------------------------------
   function Sanitize (Raw : Lt_Wire.Name_String) return String is
      B : String (1 .. Lt_Wire.File_Id_Len);
      N : Natural := 0;
      Base_Start : Natural := 1;
   begin
      --  Copy up to the first NUL; track the char after the last slash.
      for I in Raw'Range loop
         exit when Raw (I) = Character'Val (0);
         N := N + 1;
         B (N) := Raw (I);
         if Raw (I) = '/' or else Raw (I) = '\' then
            Base_Start := N + 1;
         end if;
      end loop;

      declare
         Base : constant String := B (Base_Start .. N);
      begin
         if Base'Length = 0 or else Base = "." or else Base = ".."
           or else Base (Base'First) = '.'
         then
            return "";
         end if;
         for C of Base loop
            if not ((C in 'A' .. 'Z') or else (C in 'a' .. 'z')
                    or else (C in '0' .. '9')
                    or else C = '.' or else C = '_' or else C = '-')
            then
               return "";
            end if;
         end loop;
         return Base;
      end;
   end Sanitize;

   function Open_Output (Spool, Name : String) return GNAT.OS_Lib.File_Descriptor
   is
      Flags : constant Interfaces.C.int := O_WRONLY + O_CREAT + O_EXCL + O_NOFOLLOW;
   begin
      for N in 0 .. 4096 loop
         declare
            Cand : constant String :=
              (if N = 0 then Spool & "/" & Name
               else Spool & "/" & Name & "."
                    & Ada.Strings.Fixed.Trim (N'Image, Both));
            FD : constant Interfaces.C.int :=
              C_Open (Interfaces.C.To_C (Cand), Flags, 8#640#);
         begin
            if FD >= 0 then
               Out_Path := To_Unbounded_String (Cand);
               return GNAT.OS_Lib.File_Descriptor (FD);
            end if;
         end;
      end loop;
      return GNAT.OS_Lib.Invalid_FD;
   end Open_Output;

   ---------------------------------------------------------------------------
   --  Capture loop state.
   ---------------------------------------------------------------------------
   Sock      : Socket_Type;
   Started   : Boolean := False;
   Cur_Group : U32 := 0;
   Cur_Idx   : Natural := 0;
   Argi      : Natural := 1;
   Verdict   : Integer := 1;

   procedure Post_Current (Last : Boolean; Corrupt : Boolean;
                           Total : U64; Cksum : Lt_Types.Symbol) is
      J : Job;
   begin
      J := (Idx => Cur_Idx, Group => Cur_Group, Is_Last => Last,
            Corrupt => Corrupt, Total_Bytes => Total, Trailer_Cksum => Cksum);
      Sched.Post (J);
   end Post_Current;

begin
   --  Pre-allocate and register the group-state pool.
   for I in Pool'Range loop
      Pool (I) := new Dec.State;
      Sched.Release (I);
   end loop;

   --  CLI: [--pipe] [--progress] <port> <spool> <SEED> <loss%>
   while Argi <= Argument_Count
     and then Argument (Argi)'Length >= 2
     and then Argument (Argi) (Argument (Argi)'First .. Argument (Argi)'First + 1) = "--"
   loop
      if Argument (Argi) = "--pipe" then
         Pipe_Mode := True;
      elsif Argument (Argi) = "--progress" then
         Progress := True;
      end if;
      Argi := Argi + 1;
   end loop;

   if Argument_Count - Argi + 1 /= 4 then
      Put_Line (Standard_Error,
        "[usage] receiver_stream [--pipe] [--progress] <port> <spool> <SEED> <loss%>");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   declare
      A_Port  : constant String := Argument (Argi);
      A_Spool : constant String := Argument (Argi + 1);
      A_Seed  : constant String := Argument (Argi + 2);
   begin
      Seed := U64'Value (A_Seed);

      Create_Socket (Sock, Family_Inet, Socket_Datagram);
      Set_Socket_Option (Sock, Socket_Level, (Reuse_Address, True));
      Set_Socket_Option (Sock, Socket_Level, (Receive_Buffer, 67_108_864));
      Bind_Socket (Sock, (Family => Family_Inet, Addr => Any_Inet_Addr,
                          Port => Port_Type (Natural'Value (A_Port))));
      --  Give up (evict) if the stream stalls for this long.
      Set_Socket_Option (Sock, Socket_Level, (Receive_Timeout, Timeout => 10.0));

      Put_Line (Standard_Error,
        "[rs] listening on port " & A_Port
        & (if Pipe_Mode then "  (pipe mode)" else "  spool " & A_Spool));

      Capture :
      loop
         declare
            Buf  : Wire_SEA;
            Last : Ada.Streams.Stream_Element_Offset;
            From : Sock_Addr_Type;
         begin
            Receive_Socket (Sock, Buf, Last, From);
            exit Capture when Last /= Buf'Last;

            declare
               PB        : constant Lt_Wire.Packet_Buffer := To_Buf (Buf);
               File_Size : U64;
               Group     : U32;
               Part      : U32;
               Payload   : Lt_Types.Symbol;
               Ok        : Boolean;
               Ids       : Lt_Types.Id_Array (1 .. K);
               Deg       : Lt_Types.Degree_Range;
            begin
               Lt_Wire.Parse (PB, File_Size, Group, Part, Payload);

               --  Start the transfer on the first data packet.
               if not Started then
                  if Part = Lt_Wire.Part_Eot then
                     exit Capture;              --  stray trailer, nothing to do
                  end if;
                  declare
                     Name : constant String := Sanitize (Lt_Wire.Name_Field (PB));
                  begin
                     if Name = "" then
                        Put_Line (Standard_Error, "[rs] rejected unsafe FILEID");
                        exit Capture;
                     end if;
                     if Pipe_Mode then
                        Out_FD := GNAT.OS_Lib.Standout;
                     else
                        Out_FD := Open_Output (A_Spool, Name);
                        if Out_FD = GNAT.OS_Lib.Invalid_FD then
                           Put_Line (Standard_Error,
                             "[rs] cannot create output for " & Name);
                           exit Capture;
                        end if;
                        Put_Line (Standard_Error,
                          "[rs] new transfer -> " & To_String (Out_Path));
                     end if;
                  end;
                  Sched.Acquire (Cur_Idx);
                  Dec.Reset (Pool (Cur_Idx).all);
                  Cur_Group := Group;
                  Started := True;
               end if;

               if Part = Lt_Wire.Part_Eot then
                  Post_Current (Last => True, Corrupt => False,
                                Total => File_Size, Cksum => Payload);
                  Sched.Shutdown;
                  exit Capture;
               end if;

               --  New group id => the current group is complete.
               if Group /= Cur_Group then
                  Post_Current (Last => False, Corrupt => False,
                                Total => 0, Cksum => Lt_Types.Zero_Symbol);
                  Sched.Acquire (Cur_Idx);
                  Dec.Reset (Pool (Cur_Idx).all);
                  Cur_Group := Group;
               end if;

               if Part < U32 (K) then
                  Ids (1) := Natural (Part);
                  Dec.Add_Packet (Pool (Cur_Idx).all, 1, Ids, Payload, Ok);
               else
                  declare
                     Idx   : constant Natural := Natural (Part) - K;
                     CSeed : constant U64 :=
                       Lt_Rng.Coding_Seed (Seed, U64 (Group), U64 (Idx));
                  begin
                     Lt_Sample.Sample_Indices (CSeed, Deg, Ids);
                     Dec.Add_Packet (Pool (Cur_Idx).all, Deg, Ids, Payload, Ok);
                  end;
               end if;
            end;
         exception
            when Socket_Error =>             --  receive timeout: lost EOT
               if Started then
                  Put_Line (Standard_Error, "[rs] stream stalled -> evicting");
                  Post_Current (Last => True, Corrupt => True,
                                Total => 0, Cksum => Lt_Types.Zero_Symbol);
                  Sched.Shutdown;
               end if;
               exit Capture;
         end;
      end loop Capture;

      Close_Socket (Sock);
   end;

   if not Started then
      Sched.Shutdown;                        --  wake the idle decode task
      GNAT.OS_Lib.OS_Exit (0);
   end if;

   --  Wait for the decode task to finish and gate the transfer.
   Sched.Wait_Done (Verdict);

   if not Pipe_Mode then
      GNAT.OS_Lib.Close (Out_FD);
      declare
         Marker : constant String :=
           To_String (Out_Path) & (if Verdict = 0 then ".finished" else ".corrupt");
         MFD : constant GNAT.OS_Lib.File_Descriptor :=
           GNAT.OS_Lib.Create_File (Marker, GNAT.OS_Lib.Binary);
      begin
         if MFD /= GNAT.OS_Lib.Invalid_FD then
            GNAT.OS_Lib.Close (MFD);
         end if;
      end;
   end if;

   GNAT.OS_Lib.OS_Exit (Verdict);
end Receiver_Stream;
