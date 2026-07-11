pragma SPARK_Mode (Off);

with Ada.Text_IO;        use Ada.Text_IO;
with Ada.Strings;        use Ada.Strings;
with Ada.Strings.Fixed;  use Ada.Strings.Fixed;

package body Lt_Conf is

   procedure Load (C : out Config; Path : String; Ok : out Boolean) is
      F : File_Type;
   begin
      C := (Count => 0, Items => (others => <>));
      Ok := False;
      begin
         Open (F, In_File, Path);
      exception
         when others => return;                     --  no file: leave empty
      end;
      Ok := True;

      while not End_Of_File (F) loop
         declare
            Raw : constant String := Get_Line (F);
            Hash : constant Natural := Index (Raw, "#");
            Line : constant String :=
              Trim ((if Hash = 0 then Raw else Raw (Raw'First .. Hash - 1)), Both);
            Eq   : constant Natural := Index (Line, "=");
         begin
            if Eq > Line'First and then C.Count < Max_Keys then
               declare
                  Key : constant String := Trim (Line (Line'First .. Eq - 1), Both);
                  Val : constant String := Trim (Line (Eq + 1 .. Line'Last), Both);
               begin
                  if Key'Length in 1 .. 64 and then Val'Length <= 512 then
                     C.Count := C.Count + 1;
                     C.Items (C.Count).Klen := Key'Length;
                     C.Items (C.Count).Key (1 .. Key'Length) := Key;
                     C.Items (C.Count).Vlen := Val'Length;
                     C.Items (C.Count).Val (1 .. Val'Length) := Val;
                  end if;
               end;
            end if;
         end;
      end loop;
      Close (F);
   exception
      when others =>
         if Is_Open (F) then Close (F); end if;
   end Load;

   function Has (C : Config; Key : String) return Boolean is
   begin
      for I in 1 .. C.Count loop
         if C.Items (I).Key (1 .. C.Items (I).Klen) = Key then
            return True;
         end if;
      end loop;
      return False;
   end Has;

   function Get (C : Config; Key : String; Default : String := "") return String is
   begin
      for I in 1 .. C.Count loop
         if C.Items (I).Key (1 .. C.Items (I).Klen) = Key then
            return C.Items (I).Val (1 .. C.Items (I).Vlen);
         end if;
      end loop;
      return Default;
   end Get;

   function Get_Int (C : Config; Key : String; Default : Integer) return Integer is
   begin
      if Has (C, Key) then
         return Integer'Value (Get (C, Key));
      else
         return Default;
      end if;
   exception
      when others => return Default;
   end Get_Int;

end Lt_Conf;
