--  Lt_Dpdk -- STUB body, used when WITH_DPDK=no (the default build).
--
--  Pure Ada, no imports: a default build pulls in no DPDK header, compiles no
--  C, links no library, and keeps the trusted shell exactly as docs/ASSURANCE.md
--  §5 describes it.  `--with-dpdk` at run time sees Available = False and exits
--  with a clear message rather than failing obscurely.

package body Lt_Dpdk with SPARK_Mode => Off is

   function Available return Boolean is (False);

   procedure Init (Eal_Args : String; Ok : out Boolean) is
      pragma Unreferenced (Eal_Args);
   begin
      Ok := False;
   end Init;

   procedure Set_Dst (Mac : String; Ok : out Boolean) is
      pragma Unreferenced (Mac);
   begin
      Ok := False;
   end Set_Dst;

   procedure Wait_Link (Timeout_Ms : Natural; Up : out Boolean) is
      pragma Unreferenced (Timeout_Ms);
   begin
      Up := False;
   end Wait_Link;

   procedure Rx_Burst (Bufs : in out Packet_Array; Count : out Natural) is
      pragma Unreferenced (Bufs);
   begin
      Count := 0;
   end Rx_Burst;

   procedure Tx (Buf : Lt_Wire.Packet_Buffer) is
      pragma Unreferenced (Buf);
   begin
      null;
   end Tx;

   procedure Fini is
   begin
      null;
   end Fini;

end Lt_Dpdk;
