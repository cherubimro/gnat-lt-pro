--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

pragma SPARK_Mode (Off);

with Ada.Text_IO;               use Ada.Text_IO;
with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Strings;               use Ada.Strings;
with Ada.Strings.Fixed;         use Ada.Strings.Fixed;
with Ada.Strings.Maps.Constants; use Ada.Strings.Maps.Constants;
with Ada.Strings.Unbounded;     use Ada.Strings.Unbounded;
with Interfaces.C;
with Interfaces.C.Strings;    use Interfaces.C.Strings;
with GNAT.OS_Lib;

package body Lt_Log is

   use type Interfaces.C.int;
   use type GNAT.OS_Lib.File_Descriptor;

   --  ---- syslog(3) binding --------------------------------------------------
   LOG_PID    : constant := 1;
   LOG_DAEMON : constant := 3 * 8;                 --  facility 3, shifted << 3

   function Prio (L : Level_Type) return Interfaces.C.int is
     (case L is                                    --  LOG_ERR/WARNING/INFO/DEBUG
        when Error => 3, when Warn => 4, when Info => 6, when Debug => 7);

   procedure C_Openlog (Ident : chars_ptr; Option, Facility : Interfaces.C.int)
     with Import, Convention => C, External_Name => "openlog";
   procedure C_Syslog (Priority : Interfaces.C.int; Fmt, Arg : chars_ptr)
     with Import, Convention => C, External_Name => "syslog";

   --  ---- shared, serialized state -------------------------------------------
   O_WRONLY : constant := 1;
   O_CREAT  : constant := 8#100#;
   O_APPEND : constant := 8#2000#;
   function C_Open (Path : Interfaces.C.char_array; Flags, Mode : Interfaces.C.int)
                    return Interfaces.C.int
     with Import, Convention => C, External_Name => "open";

   function Level_Str (L : Level_Type) return String is
     (case L is when Debug => "DEBUG", when Info => "INFO",
        when Warn => "WARN", when Error => "ERROR");

   protected Logger is
      procedure Setup (D : Dest_Type; File_Path, Tag : String; Min : Level_Type);
      procedure Emit (L : Level_Type; Text : String);
   private
      Where   : Dest_Type := To_Stderr;
      Prefix  : Unbounded_String := Null_Unbounded_String;
      Min_Lvl : Level_Type := Info;
      FD      : GNAT.OS_Lib.File_Descriptor := GNAT.OS_Lib.Invalid_FD;
   end Logger;


   protected body Logger is
      procedure Setup (D : Dest_Type; File_Path, Tag : String; Min : Level_Type)
      is
      begin
         Where := D;
         Prefix := To_Unbounded_String (Tag);
         Min_Lvl := Min;
         if D = To_File and then File_Path /= "" then
            declare
               R : constant Interfaces.C.int :=
                 C_Open (Interfaces.C.To_C (File_Path),
                         O_WRONLY + O_CREAT + O_APPEND, 8#644#);
            begin
               if R >= 0 then
                  FD := GNAT.OS_Lib.File_Descriptor (R);
               else
                  Where := To_Stderr;             --  fall back
               end if;
            end;
         end if;
      end Setup;

      procedure Emit (L : Level_Type; Text : String) is
      begin
         if L < Min_Lvl then
            return;
         end if;
         case Where is
            when To_Syslog =>
               declare
                  M : chars_ptr := New_String (Text);
                  F : chars_ptr := New_String ("%s");
               begin
                  C_Syslog (Prio (L), F, M);
                  Free (M); Free (F);
               end;
            when To_Stderr | To_File =>
               declare
                  Line : constant String :=
                    Ada.Calendar.Formatting.Image (Ada.Calendar.Clock)
                    & " " & Level_Str (L) & " " & To_String (Prefix)
                    & " " & Text;
                  N : Integer;
                  pragma Unreferenced (N);
               begin
                  if Where = To_File
                    and then FD /= GNAT.OS_Lib.Invalid_FD
                  then
                     declare
                        Buf : constant String := Line & ASCII.LF;
                     begin
                        N := GNAT.OS_Lib.Write (FD, Buf'Address, Buf'Length);
                     end;
                  else
                     Put_Line (Standard_Error, Line);
                  end if;
               end;
         end case;
      end Emit;
   end Logger;

   Ident_Held : chars_ptr := Null_Ptr;             --  openlog keeps this pointer

   procedure Init (Dest      : Dest_Type;
                   File_Path : String;
                   Tag       : String;
                   Ident     : String;
                   Min_Level : Level_Type) is
   begin
      if Dest = To_Syslog then
         Ident_Held := New_String (Ident);
         C_Openlog (Ident_Held, LOG_PID, LOG_DAEMON);
      end if;
      Logger.Setup (Dest, File_Path, Tag, Min_Level);
   end Init;

   procedure Log (L : Level_Type; Text : String) is
   begin
      Logger.Emit (L, Text);
   end Log;

   function Parse_Level (S : String; L : out Level_Type) return Boolean is
      T : constant String := Translate (Trim (S, Both), Lower_Case_Map);
   begin
      L := Info;
      if    T = "debug" then L := Debug;
      elsif T = "info"  then L := Info;
      elsif T = "warn"  then L := Warn;
      elsif T = "error" then L := Error;
      else return False;
      end if;
      return True;
   end Parse_Level;

end Lt_Log;
