pragma SPARK_Mode (On);
with Lt_Types;

--  Robust Soliton Distribution over degrees 1 .. K, precomputed as a cumulative
--  (unnormalised) weight table and sampled by inverse-CDF.
--
--  Determinism (design decision: bit-identical distribution on every host):
--  the only transcendental inputs to the classic RSD formula are three scalars
--  -- R = c*ln(k/delta)*sqrt(k), and ln(R/delta).  They are FROZEN here as
--  reviewed constants (computed once with GNAT's libm), so the whole table is
--  built from exact IEEE arithmetic with no run-time call to log/sqrt.  Two
--  hosts therefore build the *identical* table, which is what lets an independent
--  sender and receiver agree on block selection with no feedback.
--
--  We keep the weights UNNORMALISED and compare against U * Total in the sampler,
--  which removes the normalisation division (and its div-by-zero proof burden)
--  from the core entirely.
package Lt_Soliton is

   subtype Degree is Lt_Types.Degree_Range;

   --  Sample a degree from the distribution given a uniform draw U in [0, 1).
   function Sample_Degree (U : Long_Float) return Degree with
     Pre => U >= 0.0 and then U < 1.0;

end Lt_Soliton;
