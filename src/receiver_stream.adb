pragma SPARK_Mode (Off);   --  trusted I/O + concurrency shell over the proven core

with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Exceptions;           use Ada.Exceptions;
with Ada.Real_Time;         use Ada.Real_Time;
with Ada.Strings;              use Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Interfaces;               use Interfaces;
with Interfaces.C;
with System;
with GNAT.Sockets;             use GNAT.Sockets;
with GNAT.OS_Lib;
with Lt_Types;
with Lt_Rng;
with Lt_Sample;
with Lt_Checksum;
with Lt_Wire;
with Lt_Decoder_Std;

--  Streaming LT receiver daemon.  A tight capture loop routes each datagram to
--  its transfer by FILEID and accumulates it into a pre-allocated group decoder
--  state (never decoding inline, so the socket buffer does not overflow).  A
--  separate decode task reconstructs completed groups, writes them to that
--  transfer's output and, on its trailer, applies the whole-stream checksum
--  gate.  Up to Max_Inflight transfers decode concurrently, each finalizing
--  independently; a stalled transfer is evicted without disturbing the others.
--
--  Usage: receiver_stream [--pipe] [--progress] <port> <spool> <SEED> <loss%>
--    * file mode loops forever (a daemon); --pipe handles one transfer to stdout
--      then exits with the verdict as its exit code.
procedure Receiver_Stream is

   K            : constant := Lt_Types.K;
   Data_Len     : constant := Lt_Types.Data_Len;
   Group_Stride : constant := K * Data_Len;

   package Dec renames Lt_Decoder_Std;
   use type Lt_Types.Symbol;
   use type Interfaces.Unsigned_32;
   use type Interfaces.C.int;
   use type Interfaces.C.unsigned;
   use type GNAT.OS_Lib.File_Descriptor;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;
   subtype FD_Type is GNAT.OS_Lib.File_Descriptor;

   type Group_Ptr is access Lt_Types.Symbol_Array;
   type State_Ptr is access Dec.State;

   Max_Inflight : constant := 3;                 --  concurrent transfers
   Pool_N       : constant := 6;                 --  shared group-state pool
   Ring_N       : constant := Pool_N + 2;
   Evict_Ms     : constant := 10_000;            --  stalled-transfer eviction

   --  Hardened output open() flags.
   O_WRONLY   : constant := 1;
   O_CREAT    : constant := 8#100#;
   O_EXCL     : constant := 8#200#;
   O_NOFOLLOW : constant := 8#400000#;
   function C_Open (Path : Interfaces.C.char_array;
                    Flags, Mode : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "open";

   --  recvmmsg batching: drain up to Batch datagrams per syscall (the C
   --  reference's technique for keeping up with a line-rate blast).  The record
   --  layouts mirror <sys/socket.h> struct iovec / msghdr / mmsghdr exactly.
   Batch : constant := 64;

   type Iovec is record
      Base : System.Address    := System.Null_Address;
      Len  : Interfaces.C.size_t := 0;
   end record with Convention => C;

   type Msghdr is record
      Name       : System.Address       := System.Null_Address;
      Namelen    : Interfaces.C.unsigned := 0;
      Iov        : System.Address        := System.Null_Address;
      Iovlen     : Interfaces.C.size_t   := 0;
      Control    : System.Address        := System.Null_Address;
      Controllen : Interfaces.C.size_t   := 0;
      Flags      : Interfaces.C.int       := 0;
   end record with Convention => C;

   type Mmsghdr is record
      Hdr : Msghdr;
      Len : Interfaces.C.unsigned := 0;
   end record with Convention => C;

   function C_Recvmmsg (FD : Interfaces.C.int; Msgs : System.Address;
                        Vlen : Interfaces.C.unsigned; Flags : Interfaces.C.int;
                        Timeout : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "recvmmsg";

   function Errno_Loc return access Interfaces.C.int
     with Import, Convention => C, External_Name => "__errno_location";

   E_INTR : constant := 4;
   --  Return as soon as >= 1 datagram is in hand (then grab any others already
   --  queued, non-blocking).  Without it recvmmsg blocks until all `vlen`
   --  messages arrive or SO_RCVTIMEO expires -- disastrous latency at low rates.
   MSG_WAITFORONE : constant := 16#10000#;

   Pipe_Mode : Boolean := False;
   Progress  : Boolean := False;
   pragma Unreferenced (Progress);
   Seed      : U64 := 0;

   Epoch : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   function Now_Ms return U64 is
     (U64 (Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Epoch) * 1000.0));

   ---------------------------------------------------------------------------
   --  Decode job: one completed group handed from capture to the decode task.
   ---------------------------------------------------------------------------
   type Job is record
      Pool_Idx      : Natural := 0;              --  which pooled group state
      Xfer          : Natural := 0;              --  which transfer slot
      Group         : U32     := 0;
      Is_First      : Boolean := False;          --  first group of the transfer
      Is_Last       : Boolean := False;
      Corrupt       : Boolean := False;          --  forced corrupt (eviction)
      Total_Bytes   : U64     := 0;
      Trailer_Cksum : Lt_Types.Symbol := Lt_Types.Zero_Symbol;
      FD            : FD_Type := GNAT.OS_Lib.Invalid_FD;
      Pipe          : Boolean := False;
      Path          : Unbounded_String;
   end record;

   type Free_Array is array (1 .. Pool_N) of Natural;
   type Ring_Array is array (0 .. Ring_N - 1) of Job;

   --  Pool + job-queue scheduler.
   protected Sched is
      entry     Acquire (Idx : out Natural);
      procedure Release (Idx : Natural);
      procedure Post    (J : Job);
      entry     Take    (J : out Job);
      procedure Finish_Pipe (V : Integer);
      entry     Wait_Pipe   (V : out Integer);
   private
      Free_Stack : Free_Array;
      Free_Cnt   : Natural := 0;
      Ring       : Ring_Array;
      Head, Tail : Natural := 0;
      Count      : Natural := 0;
      Pipe_Done  : Boolean := False;
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

      entry Take (J : out Job) when Count > 0 is
      begin
         J := Ring (Head);
         Head := (Head + 1) mod Ring_N;
         Count := Count - 1;
      end Take;

      procedure Finish_Pipe (V : Integer) is
      begin
         Verdict := V;
         Pipe_Done := True;
      end Finish_Pipe;

      entry Wait_Pipe (V : out Integer) when Pipe_Done is
      begin
         V := Verdict;
      end Wait_Pipe;
   end Sched;

   ---------------------------------------------------------------------------
   --  Transfer table: route packets to a slot by FILEID.  A slot is Free,
   --  Active (receiving) or Draining (trailer seen, decode finalizing).  The
   --  decode task Frees a slot only after it finalizes, so capture never
   --  reuses a slot whose previous transfer is still being written.
   ---------------------------------------------------------------------------
   type Slot_Status is (Free, Active, Draining);
   type Status_Array is array (1 .. Max_Inflight) of Slot_Status;
   type Id_Array     is array (1 .. Max_Inflight) of Lt_Wire.Name_String;

   protected Slots is
      procedure Route (Raw : Lt_Wire.Name_String;
                       Slot : out Natural; Is_New : out Boolean);
      function  Find  (Raw : Lt_Wire.Name_String) return Natural;
      procedure Set_Draining (Slot : Natural);
      procedure Free_Slot    (Slot : Natural);
   private
      Status : Status_Array := (others => Free);
      Ids    : Id_Array;
   end Slots;

   protected body Slots is
      function Find (Raw : Lt_Wire.Name_String) return Natural is
      begin
         for S in Status'Range loop
            if Status (S) = Active and then Ids (S) = Raw then
               return S;
            end if;
         end loop;
         return 0;
      end Find;

      procedure Route (Raw : Lt_Wire.Name_String;
                       Slot : out Natural; Is_New : out Boolean) is
      begin
         Slot := Find (Raw);
         if Slot /= 0 then
            Is_New := False;
            return;
         end if;
         for S in Status'Range loop
            if Status (S) = Free then
               Status (S) := Active;
               Ids (S) := Raw;
               Slot := S;
               Is_New := True;
               return;
            end if;
         end loop;
         Slot := 0;                               --  table full: drop
         Is_New := False;
      end Route;

      procedure Set_Draining (Slot : Natural) is
      begin
         Status (Slot) := Draining;
      end Set_Draining;

      procedure Free_Slot (Slot : Natural) is
      begin
         Status (Slot) := Free;
      end Free_Slot;
   end Slots;

   ---------------------------------------------------------------------------
   --  Decode task: reconstruct each posted group, write it, run the gate.
   --  Per-transfer accumulation (checksum, bytes written, failure) lives in
   --  task-local arrays, so only this task touches them (no locking needed).
   ---------------------------------------------------------------------------
   type Cksum_Array is array (1 .. Max_Inflight) of Lt_Types.Symbol;
   type U64_Array   is array (1 .. Max_Inflight) of U64;
   type Bool_Array  is array (1 .. Max_Inflight) of Boolean;

   --  Shared group-state pool (allocated in the main body; the decode task
   --  blocks on the job queue until the first group is posted, long after).
   Pool_State : array (1 .. Pool_N) of State_Ptr;

   task Decode_Task with Storage_Size => 16 * 1024 * 1024;

   task body Decode_Task is
      J       : Job;
      Rec     : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
      Zeros   : constant Group_Ptr := new Lt_Types.Symbol_Array (0 .. K - 1);
      D_Cksum : Cksum_Array := (others => Lt_Types.Zero_Symbol);
      D_Wrote : U64_Array   := (others => 0);
      D_Fail  : Bool_Array  := (others => False);
      Ignore  : Integer;
      pragma Unreferenced (Ignore);

      procedure Emit (Buf : Group_Ptr; FD : FD_Type; N : Natural; Slot : Natural) is
      begin
         if N > 0 then
            Ignore := GNAT.OS_Lib.Write (FD, Buf.all'Address, N);
            D_Wrote (Slot) := D_Wrote (Slot) + U64 (N);
         end if;
      end Emit;
   begin
      Zeros.all := (others => Lt_Types.Zero_Symbol);
      loop
         Sched.Take (J);
         declare
            S       : constant Natural := J.Xfer;
            Success : Boolean := False;
            N_Bytes : Natural;
         begin
            if J.Is_First then
               D_Cksum (S) := Lt_Types.Zero_Symbol;
               D_Wrote (S) := 0;
               D_Fail  (S) := False;
            end if;

            N_Bytes := (if J.Is_Last
                        then Natural (U64'Min (U64 (Group_Stride),
                               (if J.Total_Bytes > D_Wrote (S)
                                then J.Total_Bytes - D_Wrote (S) else 0)))
                        else Group_Stride);

            if not J.Corrupt then
               Dec.Decode (Pool_State (J.Pool_Idx).all, Rec.all, Success);
            end if;

            if Success then
               Lt_Types.Xor_Into (D_Cksum (S), Lt_Checksum.Fold (Rec.all));
               Emit (Rec, J.FD, N_Bytes, S);
            else
               D_Fail (S) := True;
               Emit (Zeros, J.FD, N_Bytes, S);    --  keep the output aligned
            end if;

            Sched.Release (J.Pool_Idx);

            if J.Is_Last then
               declare
                  Ok : constant Boolean :=
                    not D_Fail (S) and then not J.Corrupt
                    and then D_Cksum (S) = J.Trailer_Cksum
                    and then D_Wrote (S) = J.Total_Bytes;
               begin
                  if not J.Pipe then
                     GNAT.OS_Lib.Close (J.FD);
                     declare
                        Marker : constant String :=
                          To_String (J.Path)
                          & (if Ok then ".finished" else ".corrupt");
                        MFD : constant FD_Type :=
                          GNAT.OS_Lib.Create_File (Marker, GNAT.OS_Lib.Binary);
                     begin
                        if MFD /= GNAT.OS_Lib.Invalid_FD then
                           GNAT.OS_Lib.Close (MFD);
                        end if;
                     end;
                  end if;
                  Put_Line (Standard_Error,
                    "[rs] transfer done (" & To_String (J.Path)
                    & "): bytes=" & J.Total_Bytes'Image
                    & (if Ok then "  VERIFIED" else "  CORRUPT"));
                  Slots.Free_Slot (S);
                  if J.Pipe then
                     Sched.Finish_Pipe (if Ok then 0 else 1);
                  end if;
               end;
            end if;
         end;
      end loop;
   exception
      when E : others =>
         Put_Line (Standard_Error,
           "[rs] decode task exception: " & Exception_Information (E));
         Sched.Finish_Pipe (1);
   end Decode_Task;

   ---------------------------------------------------------------------------
   --  FILEID sanitization and hardened output open (file mode).
   ---------------------------------------------------------------------------
   function Sanitize (Raw : Lt_Wire.Name_String) return String is
      B : String (1 .. Lt_Wire.File_Id_Len);
      N : Natural := 0;
      Base_Start : Natural := 1;
   begin
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

   procedure Open_Output (Spool, Name : String;
                          FD : out FD_Type; Path : out Unbounded_String) is
      Flags : constant Interfaces.C.int := O_WRONLY + O_CREAT + O_EXCL + O_NOFOLLOW;
   begin
      for N in 0 .. 4096 loop
         declare
            Cand : constant String :=
              (if N = 0 then Spool & "/" & Name
               else Spool & "/" & Name & "."
                    & Ada.Strings.Fixed.Trim (N'Image, Both));
            R : constant Interfaces.C.int :=
              C_Open (Interfaces.C.To_C (Cand), Flags, 8#640#);
         begin
            if R >= 0 then
               FD := FD_Type (R);
               Path := To_Unbounded_String (Cand);
               return;
            end if;
         end;
      end loop;
      FD := GNAT.OS_Lib.Invalid_FD;
      Path := Null_Unbounded_String;
   end Open_Output;

   ---------------------------------------------------------------------------
   --  Capture-owned per-slot accumulation state (only the main task touches it).
   ---------------------------------------------------------------------------
   type Grp_Array  is array (1 .. Max_Inflight) of U32;
   type Idx_Array  is array (1 .. Max_Inflight) of Natural;
   type CBool      is array (1 .. Max_Inflight) of Boolean;
   type CFD        is array (1 .. Max_Inflight) of FD_Type;
   type CU64       is array (1 .. Max_Inflight) of U64;
   type CPath      is array (1 .. Max_Inflight) of Unbounded_String;

   C_Group   : Grp_Array := (others => 0);
   C_Idx     : Idx_Array := (others => 0);
   C_Have    : CBool     := (others => False);   --  has an accumulating group
   C_First   : CBool     := (others => False);   --  next post is the first group
   C_FD      : CFD       := (others => GNAT.OS_Lib.Invalid_FD);
   C_Path    : CPath;
   C_Last_Ms : CU64      := (others => 0);

   Sock  : Socket_Type;
   Argi  : Natural := 1;
   A_Spool : Unbounded_String;

   --  recvmmsg receive batch: Batch packet buffers, each wired to a message.
   FD_C : Interfaces.C.int;
   type Buf_Pool is array (1 .. Batch) of aliased Lt_Wire.Packet_Buffer;
   type Iov_Pool is array (1 .. Batch) of aliased Iovec;
   type Msg_Pool is array (1 .. Batch) of aliased Mmsghdr;
   Bufs : Buf_Pool;
   Iovs : Iov_Pool;
   Msgs : Msg_Pool;

   procedure Post_Group (Slot : Natural; Last, Corrupt : Boolean;
                         Total : U64; Cksum : Lt_Types.Symbol) is
      J : Job;
   begin
      J := (Pool_Idx => C_Idx (Slot), Xfer => Slot, Group => C_Group (Slot),
            Is_First => C_First (Slot), Is_Last => Last, Corrupt => Corrupt,
            Total_Bytes => Total, Trailer_Cksum => Cksum,
            FD => C_FD (Slot), Pipe => Pipe_Mode, Path => C_Path (Slot));
      Sched.Post (J);
      C_First (Slot) := False;
      C_Have  (Slot) := False;
   end Post_Group;

   --  Evict transfers idle longer than Evict_Ms (their trailer was lost).
   procedure Sweep_Evictions is
      Now : constant U64 := Now_Ms;
   begin
      for S in 1 .. Max_Inflight loop
         if C_Have (S) and then Now - C_Last_Ms (S) > Evict_Ms then
            Put_Line (Standard_Error, "[rs] evicting stalled transfer slot"
                      & S'Image);
            Post_Group (S, Last => True, Corrupt => True,
                        Total => 0, Cksum => Lt_Types.Zero_Symbol);
            Slots.Set_Draining (S);
         end if;
      end loop;
   end Sweep_Evictions;

   --  Process one received datagram.  Stop is set when a --pipe transfer's
   --  trailer arrives (the single-shot pipe mode should then exit).
   procedure Handle (PB : Lt_Wire.Packet_Buffer; Stop : out Boolean) is
      Raw       : constant Lt_Wire.Name_String := Lt_Wire.Name_Field (PB);
      File_Size : U64;
      Group     : U32;
      Part      : U32;
      Payload   : Lt_Types.Symbol;
      Ok        : Boolean;
      Ids       : Lt_Types.Id_Array (1 .. K);
      Deg       : Lt_Types.Degree_Range;
      Slot      : Natural;
      Is_New    : Boolean;
   begin
      Stop := False;
      Lt_Wire.Parse (PB, File_Size, Group, Part, Payload);

      if Part = Lt_Wire.Part_Eot then
         Slot := Slots.Find (Raw);                --  trailer: route to existing
         if Slot /= 0 and then C_Have (Slot) then
            Post_Group (Slot, Last => True, Corrupt => False,
                        Total => File_Size, Cksum => Payload);
            Slots.Set_Draining (Slot);
            if Pipe_Mode then Stop := True; end if;
         end if;
         return;
      end if;

      Slots.Route (Raw, Slot, Is_New);
      if Slot = 0 then
         return;                                  --  table full: drop
      end if;

      if Is_New then
         declare
            Name : constant String := Sanitize (Raw);
            FD   : FD_Type;
            Path : Unbounded_String;
         begin
            if Name = "" then
               Put_Line (Standard_Error, "[rs] rejected unsafe FILEID");
               Slots.Free_Slot (Slot);
               return;
            end if;
            if Pipe_Mode then
               FD := GNAT.OS_Lib.Standout;
               Path := To_Unbounded_String (Name);
            else
               Open_Output (To_String (A_Spool), Name, FD, Path);
               if FD = GNAT.OS_Lib.Invalid_FD then
                  Put_Line (Standard_Error,
                    "[rs] cannot create output for " & Name);
                  Slots.Free_Slot (Slot);
                  return;
               end if;
               Put_Line (Standard_Error,
                 "[rs] new transfer -> " & To_String (Path));
            end if;
            C_FD (Slot) := FD;
            C_Path (Slot) := Path;
            C_Have (Slot) := False;
            C_First (Slot) := True;
         end;
      end if;

      if C_Have (Slot) and then Group /= C_Group (Slot) then
         Post_Group (Slot, Last => False, Corrupt => False,
                     Total => 0, Cksum => Lt_Types.Zero_Symbol);
      end if;

      if not C_Have (Slot) then
         Sched.Acquire (C_Idx (Slot));
         Dec.Reset (Pool_State (C_Idx (Slot)).all);
         C_Group (Slot) := Group;
         C_Have (Slot) := True;
      end if;

      if Part < U32 (K) then
         Ids (1) := Natural (Part);
         Dec.Add_Packet (Pool_State (C_Idx (Slot)).all, 1, Ids, Payload, Ok);
      else
         declare
            Idx   : constant Natural := Natural (Part) - K;
            CSeed : constant U64 :=
              Lt_Rng.Coding_Seed (Seed, U64 (Group), U64 (Idx));
         begin
            Lt_Sample.Sample_Indices (CSeed, Deg, Ids);
            Dec.Add_Packet (Pool_State (C_Idx (Slot)).all, Deg, Ids, Payload, Ok);
         end;
      end if;
      C_Last_Ms (Slot) := Now_Ms;
   end Handle;

begin
   --  Guard the hand-written recvmmsg ABI layout (Linux x86-64: 56 / 64 bytes).
   if Msghdr'Object_Size /= 448 or else Mmsghdr'Object_Size /= 512 then
      Put_Line (Standard_Error, "[rs] FATAL: mmsghdr ABI layout mismatch");
      GNAT.OS_Lib.OS_Exit (3);
   end if;

   for I in Pool_State'Range loop
      Pool_State (I) := new Dec.State;
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

   A_Spool := To_Unbounded_String (Argument (Argi + 1));
   Seed := U64'Value (Argument (Argi + 2));

   Create_Socket (Sock, Family_Inet, Socket_Datagram);
   Set_Socket_Option (Sock, Socket_Level, (Reuse_Address, True));
   Set_Socket_Option (Sock, Socket_Level, (Receive_Buffer, 67_108_864));
   Bind_Socket (Sock, (Family => Family_Inet, Addr => Any_Inet_Addr,
                       Port => Port_Type (Natural'Value (Argument (Argi)))));
   Set_Socket_Option (Sock, Socket_Level, (Receive_Timeout, Timeout => 2.0));

   Put_Line (Standard_Error,
     "[rs] listening on port " & Argument (Argi)
     & (if Pipe_Mode then "  (pipe mode)" else "  spool " & To_String (A_Spool))
     & "  max_inflight=" & Max_Inflight'Image & "  batch=" & Batch'Image);

   --  Wire each message in the batch to its own packet buffer (once).
   for I in 1 .. Batch loop
      Iovs (I) := (Base => Bufs (I)'Address, Len => Lt_Wire.Max_Buf_Len);
      Msgs (I) := (Hdr => (Name       => System.Null_Address,
                           Namelen    => 0,
                           Iov        => Iovs (I)'Address,
                           Iovlen     => 1,
                           Control    => System.Null_Address,
                           Controllen => 0,
                           Flags      => 0),
                   Len => 0);
   end loop;
   FD_C := Interfaces.C.int (GNAT.Sockets.To_C (Sock));

   Capture :
   loop
      declare
         --  Drain up to Batch datagrams in one syscall.  SO_RCVTIMEO bounds the
         --  idle wait so eviction still ticks; NULL timeout avoids recvmmsg's
         --  partial-batch timeout quirk.
         R    : constant Interfaces.C.int :=
           C_Recvmmsg (FD_C, Msgs'Address, Interfaces.C.unsigned (Batch),
                       MSG_WAITFORONE, System.Null_Address);
         Stop : Boolean;
      begin
         if R <= 0 then
            if not (R < 0 and then Errno_Loc.all = E_INTR) then
               Sweep_Evictions;                   --  timeout / no data: reap
            end if;
         else
            for I in 1 .. Natural (R) loop
               if Msgs (I).Len = Lt_Wire.Max_Buf_Len then
                  Handle (Bufs (I), Stop);
                  exit Capture when Stop;
               end if;
            end loop;
         end if;
      end;
   end loop Capture;

   if Pipe_Mode then
      declare
         Verdict : Integer;
      begin
         Sched.Wait_Pipe (Verdict);
         Close_Socket (Sock);
         GNAT.OS_Lib.OS_Exit (Verdict);
      end;
   end if;
end Receiver_Stream;
