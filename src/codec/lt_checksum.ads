--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

pragma SPARK_Mode (On);
with Lt_Types;

--  Whole-group integrity gate: the XOR-fold of every source symbol.  The sender
--  transmits this fold; the receiver recomputes it over the decoded group and
--  refuses to promote a transfer whose fold does not match (the "checksum gate"
--  of the C receiver).
package Lt_Checksum is

   function Fold (Src : Lt_Types.Symbol_Array) return Lt_Types.Symbol;

end Lt_Checksum;
