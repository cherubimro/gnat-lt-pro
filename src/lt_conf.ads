--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

pragma SPARK_Mode (Off);   --  trusted: file I/O + strings

--  Minimal `key = value` configuration reader (with `#` comments, whitespace
--  trimmed), used by the receiver daemon so it can start from a config file
--  instead of positional CLI arguments.  Precedence is enforced by the caller:
--  built-in defaults < config file < command line.
package Lt_Conf is

   Max_Keys : constant := 32;

   type Config is private;

   --  Parse Path.  Ok is False if the file cannot be opened (then Config is
   --  empty and every Get returns its default).
   procedure Load (C : out Config; Path : String; Ok : out Boolean);

   function Has (C : Config; Key : String) return Boolean;

   --  Value for Key, or Default if absent.
   function Get (C : Config; Key : String; Default : String := "") return String;

   --  Value for Key as an integer, or Default if absent / unparsable.
   function Get_Int (C : Config; Key : String; Default : Integer) return Integer;

private

   type Entry_T is record
      Key : String (1 .. 64) := (others => ' ');
      Klen : Natural := 0;
      Val : String (1 .. 512) := (others => ' ');
      Vlen : Natural := 0;
   end record;

   type Entry_Array is array (1 .. Max_Keys) of Entry_T;

   type Config is record
      Count : Natural := 0;
      Items : Entry_Array;
   end record;

end Lt_Conf;
