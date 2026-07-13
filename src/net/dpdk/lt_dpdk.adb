--  gnat-lt-pro — a formally-verified, fountain-coded data-diode transport.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later

--  Lt_Dpdk -- REAL body, used when WITH_DPDK=yes.
--
--  Thin Ada bindings to lt_dpdk_shim.c.  Every import here is a real symbol in
--  the shim, not in DPDK itself: DPDK's data-path API is `static inline` and
--  exports nothing to link against (see the header comment of the shim, and
--  docs/ASSURANCE.md §5.1).
--
--  The shim owns all mbufs.  This body only ever passes it plain byte buffers,
--  so no DPDK pointer is ever represented in Ada.

with Interfaces.C;
with System;

package body Lt_Dpdk with SPARK_Mode => Off is

   use type Interfaces.C.int;

   function C_Init (Argc : Interfaces.C.int;
                    Argv : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "lt_dpdk_init";

   function C_Set_Dst (Mac : Interfaces.C.char_array) return Interfaces.C.int
     with Import, Convention => C, External_Name => "lt_dpdk_set_dst";

   function C_Wait_Link (Timeout_Ms : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "lt_dpdk_wait_link";

   function C_Rx_Burst (Out_Buf  : System.Address;
                        Max_Pkts : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "lt_dpdk_rx_burst";

   function C_Tx (Pkt : System.Address) return Interfaces.C.int
     with Import, Convention => C, External_Name => "lt_dpdk_tx";

   procedure C_Fini
     with Import, Convention => C, External_Name => "lt_dpdk_fini";

   ---------------
   -- Available --
   ---------------

   function Available return Boolean is (True);

   ----------
   -- Init --
   ----------

   --  Split Eal_Args on whitespace into a C argv, prepending argv (0).  The
   --  EAL consumes these itself (--vdev, --no-huge, -l, --file-prefix, ...).

   procedure Init (Eal_Args : String; Ok : out Boolean) is
      use Interfaces.C;

      Max_Args : constant := 32;

      --  Storage for the argument strings plus the NUL terminators, and the
      --  pointer vector the EAL is handed.  Both live for the whole run: DPDK
      --  keeps referencing argv internally, so neither may be reclaimed.
      type Arg_Store is array (1 .. Max_Args) of aliased char_array (0 .. 255);
      type Ptr_Vec   is array (0 .. Max_Args) of aliased System.Address;

      Store : access Arg_Store := new Arg_Store'
        (others => (0 .. 255 => Interfaces.C.nul));
      Argv  : access Ptr_Vec   := new Ptr_Vec'(others => System.Null_Address);

      N : Natural := 0;                   --  argv entries filled so far
      I : Natural := Eal_Args'First;
      J : Natural;

      procedure Push (S : String) is
         T : constant char_array := To_C (S);
      begin
         if N >= Max_Args or else T'Length > 256 then
            return;
         end if;
         Store (N + 1) (0 .. T'Length - 1) := T;
         Argv (N) := Store (N + 1) (0)'Address;
         N := N + 1;
      end Push;

      R : Interfaces.C.int;
   begin
      Ok := False;

      Push ("lt-diode");                  --  argv (0)

      while I <= Eal_Args'Last loop
         while I <= Eal_Args'Last and then Eal_Args (I) = ' ' loop
            I := I + 1;
         end loop;
         exit when I > Eal_Args'Last;

         J := I;
         while J <= Eal_Args'Last and then Eal_Args (J) /= ' ' loop
            J := J + 1;
         end loop;

         Push (Eal_Args (I .. J - 1));
         I := J;
      end loop;

      R  := C_Init (Interfaces.C.int (N), Argv (0)'Address);
      Ok := R = 0;
   end Init;

   -------------
   -- Set_Dst --
   -------------

   procedure Set_Dst (Mac : String; Ok : out Boolean) is
   begin
      Ok := C_Set_Dst (Interfaces.C.To_C (Mac)) = 0;
   end Set_Dst;

   ---------------
   -- Wait_Link --
   ---------------

   procedure Wait_Link (Timeout_Ms : Natural; Up : out Boolean) is
   begin
      Up := C_Wait_Link (Interfaces.C.int (Timeout_Ms)) = 1;
   end Wait_Link;

   --------------
   -- Rx_Burst --
   --------------

   procedure Rx_Burst (Bufs : in out Packet_Array; Count : out Natural) is
      R : constant Interfaces.C.int :=
        C_Rx_Burst (Bufs (Bufs'First)'Address, Interfaces.C.int (Batch));
   begin
      --  The shim clamps to Batch itself; this is belt and braces.
      Count := (if R <= 0 then 0
                elsif Natural (R) > Batch then Batch
                else Natural (R));
   end Rx_Burst;

   --------
   -- Tx --
   --------

   procedure Tx (Buf : Lt_Wire.Packet_Buffer) is
      Local  : aliased constant Lt_Wire.Packet_Buffer := Buf;
      Ignore : Interfaces.C.int;
   begin
      --  A drop (link down / TX ring full) is deliberately silent: a diode has
      --  no return path and the fountain code is built to tolerate loss.
      Ignore := C_Tx (Local'Address);
   end Tx;

   ----------
   -- Fini --
   ----------

   procedure Fini is
   begin
      C_Fini;
   end Fini;

end Lt_Dpdk;
