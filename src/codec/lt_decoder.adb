pragma SPARK_Mode (On);

package body Lt_Decoder is

   procedure Reset (S : out State) is
   begin
      S := (Np   => 0,
            Ne   => 0,
            Edge => (others => 0),
            EPkt => (others => 1),
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
      P    : Pkt_Index;
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
         S.EPkt (Base + J) := P;
         --  New edges name packet P; edges below Base are untouched, so they
         --  still satisfy the incoming predicate (<= old Np <= P).  Together
         --  these re-establish EPkt (E) <= Np after Np becomes P.
         pragma Loop_Invariant (for all E in Base .. Base + J => S.EPkt (E) = P);
         pragma Loop_Invariant
           (for all E in 1 .. Base - 1 => S.EPkt (E) <= S.Np);
      end loop;

      S.Off (P) := Base;
      S.Dg  (P) := Deg;
      S.Res (P) := Payload;
      S.Ne := S.Ne + Deg;
      S.Np := P;
      --  Bridge the loop invariants to Valid: the new edges are exactly
      --  Base .. S.Ne, all naming P (= Np); the rest are unchanged (<= old Np).
      pragma Assert (S.Ne = Base + Deg - 1);
      Ok := True;
   end Add_Packet;

   procedure Decode
     (S       : in out State;
      Value   : out Lt_Types.Symbol_Array;
      Success : out Boolean)
   is
      subtype Edge_Or_Zero is Natural range 0 .. Max_Edges;   --  edge index, 0 = none

      --  Per-source recovery state.
      Known : array (Lt_Types.Source_Id) of Boolean := (others => False);

      --  Per-packet peeling state.
      Remn   : array (1 .. Max_Packets) of Natural    := (others => 0);
      Proc   : array (1 .. Max_Packets) of Boolean    := (others => False);
      Queued : array (1 .. Max_Packets) of Boolean    := (others => False);
      Ripple : array (1 .. Max_Packets) of Pkt_Index;
      Top    : Pkt_Count := 0;

      --  Incidence as intrusive singly-linked lists over the edge slots: for
      --  source Sd, Head (Sd) is its first edge (0 = none) and Nxt chains to the
      --  next.  Built by prepending while scanning edges in increasing order, so
      --  every Nxt link points to a strictly smaller edge index.
      Head : array (Lt_Types.Source_Id) of Edge_Or_Zero := (others => 0);
      Nxt  : array (1 .. Max_Edges)     of Edge_Or_Zero := (others => 0);

      P     : Pkt_Index;
      S_Unk : Lt_Types.Source_Id;
      Found : Boolean;
      E     : Edge_Or_Zero;
   begin
      Value  := (others => Lt_Types.Zero_Symbol);
      Ripple := (others => 1);

      --  1. Remaining-unknown count starts at each packet's degree.
      for Q in 1 .. S.Np loop
         Remn (Q) := S.Dg (Q);
      end loop;

      --  2. Seed the ripple with the degree-1 packets.  The Top < Max_Packets
      --     guard can never actually block (at most Np <= Max_Packets distinct
      --     packets are ever queued); it just makes the bound manifest to SPARK.
      for Q in 1 .. S.Np loop
         if Remn (Q) = 1 and then not Queued (Q) and then Top < Max_Packets then
            Top := Top + 1;
            Ripple (Top) := Q;
            Queued (Q) := True;
         end if;
         pragma Loop_Invariant (for all I in 1 .. Top => Ripple (I) <= S.Np);
      end loop;

      --  3. Build the source -> edges incidence (prepend per source, scanning
      --     edges in increasing order).  Every link therefore points to a
      --     strictly smaller edge index, and all indices stay within 1 .. Ne.
      for Ed in 1 .. S.Ne loop
         declare
            Sd : constant Lt_Types.Source_Id := S.Edge (Ed);
         begin
            Nxt (Ed)  := Head (Sd);
            Head (Sd) := Ed;
         end;
         pragma Loop_Invariant (for all D in Lt_Types.Source_Id => Head (D) <= Ed);
         pragma Loop_Invariant (for all X in 1 .. Ed => Nxt (X) <= S.Ne);
      end loop;

      --  4. Peel: recover the lone unknown of each ripple packet and cascade.
      while Top > 0 loop
         pragma Loop_Invariant (for all I in 1 .. Top => Ripple (I) <= S.Np);
         pragma Loop_Invariant (for all D in Lt_Types.Source_Id => Head (D) <= S.Ne);
         pragma Loop_Invariant (for all X in 1 .. S.Ne => Nxt (X) <= S.Ne);

         P   := Ripple (Top);      --  <= Np (from the invariant), so predicate applies
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

               --  Walk S_Unk's incidence list, XOR it out of every other packet.
               E := Head (S_Unk);
               while E /= 0 loop
                  pragma Loop_Invariant (E <= S.Ne);
                  pragma Loop_Invariant (for all I in 1 .. Top => Ripple (I) <= S.Np);
                  pragma Loop_Invariant
                    (for all X in 1 .. S.Ne => Nxt (X) <= S.Ne);
                  declare
                     Q : constant Pkt_Index := S.EPkt (E);  --  <= Np by predicate
                  begin
                     if not Proc (Q) then
                        Lt_Types.Xor_Into (S.Res (Q), Value (S_Unk));
                        if Remn (Q) > 0 then
                           Remn (Q) := Remn (Q) - 1;
                           if Remn (Q) = 1 and then not Queued (Q)
                             and then Top < Max_Packets
                           then
                              Top := Top + 1;
                              Ripple (Top) := Q;
                              Queued (Q) := True;
                           end if;
                        end if;
                     end if;
                  end;
                  E := Nxt (E);   --  strictly smaller index, or 0
               end loop;
            end if;
         end if;
      end loop;

      Success := (for all Sd in Lt_Types.Source_Id => Known (Sd));
   end Decode;

end Lt_Decoder;
