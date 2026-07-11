pragma SPARK_Mode (On);

package body Lt_Decoder is

   procedure Reset (S : out State) is
   begin
      S := (Np   => 0,
            Ne   => 0,
            Edge => (others => 0),
            Off  => (others => 1),
            Dg   => (others => 1),
            Res  => (others => Lt_Types.Zero_Symbol));
   end Reset;

   function Packet_Count (S : State) return Natural is (S.Np);

   procedure Add_Packet
     (S       : in out State;
      Deg     : Lt_Types.Degree_Range;
      Ids     : Lt_Types.Id_Array;
      Payload : Lt_Types.Symbol;
      Ok      : out Boolean)
   is
      P    : Pkt_Count;
      Base : Edge_Pos;
   begin
      --  Drop (like a lost packet) if a capacity would be exceeded.
      if S.Np >= Max_Packets or else S.Ne > Max_Edges - Deg then
         Ok := False;
         return;
      end if;

      P    := S.Np + 1;
      Base := S.Ne + 1;                        --  Ne <= Max_Edges - Deg, Deg >= 1
      for J in 0 .. Deg - 1 loop
         S.Edge (Base + J) := Ids (J + 1);     --  Base + J <= Ne + Deg <= Max_Edges
      end loop;

      S.Off (P) := Base;
      S.Dg  (P) := Deg;
      S.Res (P) := Payload;
      S.Ne := S.Ne + Deg;
      S.Np := P;
      Ok := True;
   end Add_Packet;

   procedure Decode
     (S       : in out State;
      Value   : out Lt_Types.Symbol_Array;
      Success : out Boolean)
   is
      subtype Pkt_Index is Positive range 1 .. Max_Packets;

      --  Per-source recovery state.
      Known : array (Lt_Types.Source_Id) of Boolean := (others => False);

      --  Per-packet peeling state.
      Remn   : array (1 .. Max_Packets) of Natural  := (others => 0);
      Proc   : array (1 .. Max_Packets) of Boolean  := (others => False);
      Queued : array (1 .. Max_Packets) of Boolean  := (others => False);
      Ripple : array (1 .. Max_Packets) of Pkt_Index;
      Top    : Natural := 0;

      --  Incidence in CSR form: for source Sd, the packets referencing it are
      --  Inc (Start (Sd) .. Start (Sd) + Cnt (Sd) - 1).
      Cnt   : array (Lt_Types.Source_Id) of Natural := (others => 0);
      Start : array (Lt_Types.Source_Id) of Natural := (others => 1);
      Cur   : array (Lt_Types.Source_Id) of Natural := (others => 1);
      Inc   : array (1 .. Max_Edges) of Pkt_Index;

      Run   : Natural;
      P     : Pkt_Index;
      S_Unk : Lt_Types.Source_Id;
      Found : Boolean;
   begin
      Value  := (others => Lt_Types.Zero_Symbol);
      Ripple := (others => 1);
      Inc    := (others => 1);

      --  1. Remaining-unknown count starts at each packet's degree.
      for Q in 1 .. S.Np loop
         Remn (Q) := S.Dg (Q);
      end loop;

      --  2. Build the source -> packets incidence (counting sort).
      for E in 1 .. S.Ne loop
         Cnt (S.Edge (E)) := Cnt (S.Edge (E)) + 1;
      end loop;
      Run := 1;
      for Sd in Lt_Types.Source_Id loop
         Start (Sd) := Run;
         Cur   (Sd) := Run;
         Run := Run + Cnt (Sd);
      end loop;
      for Q in 1 .. S.Np loop
         for J in 0 .. S.Dg (Q) - 1 loop
            declare
               Sd : constant Lt_Types.Source_Id := S.Edge (S.Off (Q) + J);
            begin
               Inc (Cur (Sd)) := Q;
               Cur (Sd) := Cur (Sd) + 1;
            end;
         end loop;
      end loop;

      --  3. Seed the ripple with the degree-1 packets.
      for Q in 1 .. S.Np loop
         if Remn (Q) = 1 and then not Queued (Q) then
            Top := Top + 1;
            Ripple (Top) := Q;
            Queued (Q) := True;
         end if;
      end loop;

      --  4. Peel: recover the lone unknown of each ripple packet and cascade.
      while Top > 0 loop
         P   := Ripple (Top);
         Top := Top - 1;

         if not Proc (P) and then Remn (P) = 1 then
            --  Locate the single still-unknown source of packet P.
            Found := False;
            S_Unk := 0;
            for J in 0 .. S.Dg (P) - 1 loop
               declare
                  Sd : constant Lt_Types.Source_Id := S.Edge (S.Off (P) + J);
               begin
                  if not Known (Sd) then
                     S_Unk := Sd;
                     Found := True;
                  end if;
               end;
            end loop;

            if Found then
               Value (S_Unk) := S.Res (P);   --  residual is exactly that symbol
               Known (S_Unk) := True;
               Proc  (P)     := True;

               --  XOR the recovered symbol out of every other packet using it.
               if Cnt (S_Unk) > 0 then
                  for T in Start (S_Unk) .. Start (S_Unk) + Cnt (S_Unk) - 1 loop
                     declare
                        Q : constant Pkt_Index := Inc (T);
                     begin
                        if not Proc (Q) then
                           Lt_Types.Xor_Into (S.Res (Q), Value (S_Unk));
                           Remn (Q) := Remn (Q) - 1;
                           if Remn (Q) = 1 and then not Queued (Q) then
                              Top := Top + 1;
                              Ripple (Top) := Q;
                              Queued (Q) := True;
                           end if;
                        end if;
                     end;
                  end loop;
               end if;
            end if;
         end if;
      end loop;

      Success := (for all Sd in Lt_Types.Source_Id => Known (Sd));
   end Decode;

end Lt_Decoder;
