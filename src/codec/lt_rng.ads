pragma SPARK_Mode (On);
with Interfaces;

--  Deterministic pseudo-random generator for reproducible block selection.
--
--  Design note (clean-slate both-ends port): the C reference reproduces glibc's
--  rand() bit-for-bit (rbsoliton.c: glibc_srand_r / glibc_rand_r) *only* so that
--  two independent processes agree on the LT block selection.  Since this port
--  owns BOTH the sender and the receiver, that fragile mimicry is deleted and
--  replaced with one clean, well-defined generator (SplitMix64) used identically
--  on both ends.  It is pure modular integer arithmetic, so SPARK proves it free
--  of run-time errors trivially, and it carries no global state -- every draw
--  threads the generator explicitly, resolving the unsynchronised-global-RNG
--  hazard flagged in the C rng.h.
--
--  NOT cryptographic: this exists solely for reproducible erasure-code sampling.
package Lt_Rng is

   use type Interfaces.Unsigned_64;

   subtype U64 is Interfaces.Unsigned_64;

   type Generator is record
      State : U64;
   end record;

   function Seeded (Seed : U64) return Generator with
     Post => Seeded'Result.State = Seed;

   --  Advance the state and emit the next 64-bit output (SplitMix64).
   procedure Next (G : in out Generator; Value : out U64);

   --  Uniform draw in [0.0, 1.0).  Uses the top 53 bits, so the mapping to a
   --  Long_Float is exact and identical on every IEEE-754 host.
   procedure Next_Unit (G : in out Generator; U : out Long_Float) with
     Post => U >= 0.0 and then U < 1.0;

   --  Uniform integer in [0, Bound).  (Modulo bias is < 2**-53 for the small
   --  bounds used here and is irrelevant to decode success.)
   procedure Next_Below (G : in out Generator; Bound : Positive; R : out Natural)
   with
     Post => R < Bound;

end Lt_Rng;
