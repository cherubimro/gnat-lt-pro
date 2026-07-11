pragma SPARK_Mode (On);
with Interfaces;
with Lt_Types;

--  On-wire packet format, shared by the sender and receiver.  Fixed 1472-byte
--  datagrams (no IP fragmentation on a 1500-MTU link), all multi-byte integer
--  fields big-endian:
--
--     [ 0   .. 99 ]  file id      (transfer name, zero-padded)
--     [ 100 .. 107]  file_size    (u64)  0 in data packets; exact total in EOT
--     [ 108 .. 111]  group_no     (u32)  group index; total group count in EOT
--     [ 112 .. 115]  part_no      (u32)  role, see below
--     [ 116 ..1471]  data         (1356 payload bytes)
--
--  part_no roles (pure LT coding, single port):
--     0 .. Eot-1      coding packet -- part_no is the coding index; the seed is
--                     derived from (SEED, group_no, part_no)
--     Part_Eot        end-of-transfer trailer -- file_size = total bytes,
--                     group_no = total group count, data = whole-stream checksum
--
--  Serialize/Parse are pure buffer transforms (no I/O), proved free of run-time
--  errors so the receiver can parse untrusted datagrams safely.
package Lt_Wire is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   File_Id_Len : constant := 100;
   Total_Len   : constant := 8;
   Group_Len   : constant := 4;
   Part_Len    : constant := 4;
   Data_Len    : constant := Lt_Types.Data_Len;                  --  1356

   Header_Len  : constant := File_Id_Len + Total_Len + Group_Len + Part_Len;  -- 116
   Max_Buf_Len : constant := Header_Len + Data_Len;                           -- 1472

   Off_File_Id   : constant := 0;
   Off_File_Size : constant := File_Id_Len;                      --  100
   Off_Group     : constant := Off_File_Size + Total_Len;        --  108
   Off_Part      : constant := Off_Group + Group_Len;            --  112
   Off_Data      : constant := Off_Part + Part_Len;              --  116

   --  part_no sentinel for the end-of-transfer trailer.  Coding indices must
   --  stay below it: K + coding_index < Part_Eot (always true in practice).
   Part_Eot : constant U32 := 16#FFFF_FFFF#;

   subtype Buf_Index is Natural range 0 .. Max_Buf_Len - 1;
   type Packet_Buffer is array (Buf_Index) of Lt_Types.Byte;

   subtype Name_String is String (1 .. File_Id_Len);

   --  Encode one packet into Buf (zero-padded fileid, big-endian scalars).
   procedure Serialize
     (Name      : String;
      File_Size : U64;
      Group_No  : U32;
      Part_No   : U32;
      Payload   : Lt_Types.Symbol;
      Buf       : out Packet_Buffer)
   with Pre => Name'Length <= File_Id_Len;

   --  Decode the scalar fields and payload of a received packet.
   procedure Parse
     (Buf       : Packet_Buffer;
      File_Size : out U64;
      Group_No  : out U32;
      Part_No   : out U32;
      Payload   : out Lt_Types.Symbol);

   --  The fileid field as a fixed 100-char string (trailing NULs preserved).
   function Name_Field (Buf : Packet_Buffer) return Name_String;

end Lt_Wire;
