--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

pragma SPARK_Mode (On);
with Interfaces;

--  Shared, protocol-level constants and the symbol type used throughout the
--  proven codec core.  Everything here is pure data: no I/O, no globals, no
--  heap.  A "symbol" is one payload-sized chunk (Data_Len bytes); a "group" is
--  always exactly K source symbols (the final group is zero-padded to K).
package Lt_Types is

   use type Interfaces.Unsigned_8;

   subtype Byte is Interfaces.Unsigned_8;

   ----------------------------------------------------------------------------
   --  Wire geometry (matches the C reference: DATALEN = 1356 payload bytes)
   ----------------------------------------------------------------------------
   Data_Len : constant := 1356;

   subtype Symbol_Offset is Natural range 0 .. Data_Len - 1;
   type Symbol is array (Symbol_Offset) of Byte;

   Zero_Symbol : constant Symbol := (others => 0);

   ----------------------------------------------------------------------------
   --  Robust-soliton group geometry (a group is always K source symbols).
   --  10 MB group / 1356 B  ->  K = 7375 source symbols, as in the C code.
   ----------------------------------------------------------------------------
   K : constant := 7375;

   subtype Source_Count is Natural range 0 .. K;
   subtype Source_Id    is Natural range 0 .. K - 1;   --  0-based symbol index

   --  Unconstrained so callers can size buffers for exactly one group (K) and
   --  pass them into the allocation-free core.
   type Symbol_Array is array (Natural range <>) of Symbol;

   --  A coding packet mixes between 1 and K distinct source symbols.
   subtype Degree_Range is Positive range 1 .. K;

   --  A list of (0-based) source-symbol ids; used for the index set of a packet.
   type Id_Array is array (Positive range <>) of Source_Id;

   --  In-place XOR: Acc := Acc xor X, byte by byte.  Proven to fold X into Acc.
   procedure Xor_Into (Acc : in out Symbol; X : Symbol) with
     Post => (for all I in Symbol_Offset => Acc (I) = (Acc'Old (I) xor X (I)));

end Lt_Types;
