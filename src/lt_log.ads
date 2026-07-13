--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

pragma SPARK_Mode (Off);   --  trusted: I/O, syslog binding, tasking-safe emit

--  Small shared, thread-safe operational logger (mirrors the C reference's
--  ltlog): every line carries a timestamp and a level and is emitted under a
--  lock so lines from concurrent tasks never interleave.  Destinations: stderr
--  (the default; journald timestamps it under systemd), an append file, or
--  syslog(3).  Separate from the receiver's structured verify.log journal.
package Lt_Log is

   type Level_Type is (Debug, Info, Warn, Error);
   type Dest_Type  is (To_Stderr, To_File, To_Syslog);

   --  Configure once at start-up.  Tag prefixes stderr/file lines (e.g. "[rs]");
   --  Ident is the syslog ident.  Lines below Min_Level are dropped.
   procedure Init (Dest      : Dest_Type;
                   File_Path : String;
                   Tag       : String;
                   Ident     : String;
                   Min_Level : Level_Type);

   procedure Log (L : Level_Type; Text : String);

   --  Parse "debug|info|warn|error"; returns False if unrecognised.
   function Parse_Level (S : String; L : out Level_Type) return Boolean;

end Lt_Log;
