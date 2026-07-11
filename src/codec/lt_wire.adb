pragma SPARK_Mode (On);

package body Lt_Wire is

   use type Lt_Types.Byte;

   --  Big-endian scalar writers/readers, guarded so the offsets stay in range.

   procedure Put_U32_BE (Buf : in out Packet_Buffer; Off : Buf_Index; V : U32)
   with Pre => Off <= Max_Buf_Len - 4
   is
      use Interfaces;
   begin
      Buf (Off)     := Lt_Types.Byte'Mod (Shift_Right (V, 24));
      Buf (Off + 1) := Lt_Types.Byte'Mod (Shift_Right (V, 16));
      Buf (Off + 2) := Lt_Types.Byte'Mod (Shift_Right (V, 8));
      Buf (Off + 3) := Lt_Types.Byte'Mod (V);
   end Put_U32_BE;

   procedure Put_U64_BE (Buf : in out Packet_Buffer; Off : Buf_Index; V : U64)
   with Pre => Off <= Max_Buf_Len - 8
   is
      use Interfaces;
   begin
      for I in 0 .. 7 loop
         Buf (Off + I) := Lt_Types.Byte'Mod (Shift_Right (V, (7 - I) * 8));
      end loop;
   end Put_U64_BE;

   function Get_U32_BE (Buf : Packet_Buffer; Off : Buf_Index) return U32
   with Pre => Off <= Max_Buf_Len - 4
   is
      use Interfaces;
   begin
      return Shift_Left (U32 (Buf (Off)),     24)
           or Shift_Left (U32 (Buf (Off + 1)), 16)
           or Shift_Left (U32 (Buf (Off + 2)), 8)
           or            U32 (Buf (Off + 3));
   end Get_U32_BE;

   function Get_U64_BE (Buf : Packet_Buffer; Off : Buf_Index) return U64
   with Pre => Off <= Max_Buf_Len - 8
   is
      use Interfaces;
      R : U64 := 0;
   begin
      for I in 0 .. 7 loop
         R := Shift_Left (R, 8) or U64 (Buf (Off + I));
      end loop;
      return R;
   end Get_U64_BE;

   procedure Serialize
     (Name      : String;
      File_Size : U64;
      Group_No  : U32;
      Part_No   : U32;
      Payload   : Lt_Types.Symbol;
      Buf       : out Packet_Buffer)
   is
   begin
      Buf := (others => 0);

      --  fileid: copy Name into 0 .. Name'Length-1, the rest stays zero.
      for I in 0 .. Name'Length - 1 loop
         Buf (I) := Lt_Types.Byte (Character'Pos (Name (Name'First + I)));
      end loop;

      Put_U64_BE (Buf, Off_File_Size, File_Size);
      Put_U32_BE (Buf, Off_Group,     Group_No);
      Put_U32_BE (Buf, Off_Part,      Part_No);

      for I in Lt_Types.Symbol_Offset loop
         Buf (Off_Data + I) := Payload (I);
      end loop;
   end Serialize;

   procedure Parse
     (Buf       : Packet_Buffer;
      File_Size : out U64;
      Group_No  : out U32;
      Part_No   : out U32;
      Payload   : out Lt_Types.Symbol)
   is
   begin
      File_Size := Get_U64_BE (Buf, Off_File_Size);
      Group_No  := Get_U32_BE (Buf, Off_Group);
      Part_No   := Get_U32_BE (Buf, Off_Part);
      for I in Lt_Types.Symbol_Offset loop
         Payload (I) := Buf (Off_Data + I);
      end loop;
   end Parse;

   function Name_Field (Buf : Packet_Buffer) return Name_String is
      R : Name_String := (others => ' ');
   begin
      for I in 0 .. File_Id_Len - 1 loop
         R (R'First + I) := Character'Val (Buf (Off_File_Id + I));
      end loop;
      return R;
   end Name_Field;

end Lt_Wire;
