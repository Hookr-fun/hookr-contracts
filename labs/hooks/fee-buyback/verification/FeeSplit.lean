/-
  FeeSplit.lean — the model behind `HookFeeSplit.sol`, and the generator for
  `test/FeeSplitParityCases.sol`, which `test/FeeSplitParity.t.sol` replays through the Solidity
  library.

  Build (Std only — no Mathlib, no `lake update`):

      lean verification/FeeSplit.lean          -- type-checks the model and every proof
      lean --run verification/FeeSplit.lean    -- regenerates test/FeeSplitParityCases.sol

  The model mirrors the contract exactly: `Nat` floor division is the contract's integer division
  on non-negative values, and every function below has a one-to-one counterpart in
  `src/HookFeeSplit.sol`. The theorems are the properties the contract's comments claim: the split
  is conservative (nothing is stranded), the owner's slice is bounded by its ceiling and the hook
  fee by a tenth of the specified amount (and by an int128), the slippage floor never exceeds the
  spot estimate, and the quadrant predicate the hook charges on is exactly "the quote is the
  specified currency".
-/
import Std

namespace FeeSplit

/-! ## Constants (mirroring `HookFeeSplit.sol`) -/

def BPS : Nat := 10000
def PIPS : Nat := 1000000
def MAX_HOOK_FEE_PIPS : Nat := 100000
def MAX_OWNER_BPS : Nat := 1000
def MAX_SLIPPAGE_BPS : Nat := 2000

/-! ## The model -/

/-- The hook fee, in pips of the swap's specified amount. -/
def hookFee (amount pips : Nat) : Nat := amount * pips / PIPS

/-- The owner's slice of a collected amount. -/
def ownerShare (amount ownerBps : Nat) : Nat := amount * ownerBps / BPS

/-- The LP slice: this is what the hook donates into the pool. -/
def lpShare (amount lpBps : Nat) : Nat := amount * lpBps / BPS

/-- The buyback slice. It takes the remainder, so it absorbs the integer dust. -/
def buybackShare (amount ownerBps lpBps : Nat) : Nat :=
  amount - ownerShare amount ownerBps - lpShare amount lpBps

/-- The floor on the buyback's output, from the pre-swap spot estimate. -/
def slippageFloor (spotOut slippageBps : Nat) : Nat := spotOut * (BPS - slippageBps) / BPS

/-- The quadrants the hook charges on: the specified leg is the quote. -/
def chargeable (isBuy exactInput : Bool) : Bool := isBuy == exactInput

/-- `isBuy` means "the trader pays the quote", i.e. the input currency is the quote. `zeroForOne`
    fixes the input currency; `quoteIsCurrency0` says which side the quote is. -/
def isBuyOf (zeroForOne quoteIsCurrency0 : Bool) : Bool := zeroForOne == quoteIsCurrency0

/-- The same question asked of the raw swap fields: is the *specified* currency the quote?
    `specified` is the input for an exact-input swap and the output for an exact-output swap. -/
def quoteIsSpecified (zeroForOne exactInput quoteIsCurrency0 : Bool) : Bool :=
  let inputIsQuote := isBuyOf zeroForOne quoteIsCurrency0
  if exactInput then inputIsQuote else !inputIsQuote

/-! ## Arithmetic lemmas -/

/-- Division is monotone on the numerator. (Core does not carry this one; `Nat.le_div_iff_mul_le`
    plus `Nat.div_mul_le_self` gives it.) -/
theorem div_le_div_right' {a b c : Nat} (h : a ≤ b) (hc : 0 < c) : a / c ≤ b / c :=
  (Nat.le_div_iff_mul_le hc).2 (Nat.le_trans (Nat.div_mul_le_self a c) h)

/-- Floors add: `x/c + y/c ≤ (x+y)/c`. -/
theorem div_add_div_le (x y c : Nat) (hc : 0 < c) : x / c + y / c ≤ (x + y) / c := by
  rw [Nat.le_div_iff_mul_le hc, Nat.add_mul]
  exact Nat.add_le_add (Nat.div_mul_le_self x c) (Nat.div_mul_le_self y c)

/-! ## Theorems -/

/-- The owner and LP slices together never exceed the collected amount. This is what makes the
    split conservative: the buyback leg's subtraction cannot underflow. -/
theorem owner_add_lp_le (amount ownerBps lpBps : Nat) (h : ownerBps + lpBps ≤ BPS) :
    ownerShare amount ownerBps + lpShare amount lpBps ≤ amount := by
  have hsum : amount * ownerBps + amount * lpBps ≤ amount * BPS := by
    rw [← Nat.mul_add]
    exact Nat.mul_le_mul_left amount h
  calc ownerShare amount ownerBps + lpShare amount lpBps
      ≤ (amount * ownerBps + amount * lpBps) / BPS := div_add_div_le _ _ BPS (by decide)
    _ ≤ (amount * BPS) / BPS := div_le_div_right' hsum (by decide)
    _ = amount := Nat.mul_div_left amount (by decide)

/-- Every wei is accounted for: the three legs sum to exactly the amount collected. -/
theorem split_conservation (amount ownerBps lpBps : Nat) (h : ownerBps + lpBps ≤ BPS) :
    ownerShare amount ownerBps + lpShare amount lpBps + buybackShare amount ownerBps lpBps = amount := by
  unfold buybackShare
  have := owner_add_lp_le amount ownerBps lpBps h
  omega

/-- The owner's slice is bounded by the ceiling, whatever weight is configured. -/
theorem owner_share_le_ceiling (amount ownerBps : Nat) (h : ownerBps ≤ MAX_OWNER_BPS) :
    ownerShare amount ownerBps ≤ amount * MAX_OWNER_BPS / BPS := by
  unfold ownerShare
  exact div_le_div_right' (Nat.mul_le_mul_left amount h) (by decide)

/-- At the ceiling the hook fee is exactly a tenth of the specified amount. -/
theorem hook_fee_at_ceiling (amount : Nat) : hookFee amount MAX_HOOK_FEE_PIPS = amount / 10 := by
  unfold hookFee MAX_HOOK_FEE_PIPS PIPS
  rw [show (1000000 : Nat) = 100000 * 10 by decide, Nat.mul_comm amount 100000]
  exact Nat.mul_div_mul_left amount 10 (by decide)

/-- Under the ceiling the hook fee never exceeds a tenth of the specified amount. -/
theorem hook_fee_le_tenth (amount pips : Nat) (h : pips ≤ MAX_HOOK_FEE_PIPS) :
    hookFee amount pips ≤ amount / 10 := by
  have hmono : hookFee amount pips ≤ hookFee amount MAX_HOOK_FEE_PIPS := by
    unfold hookFee
    exact div_le_div_right' (Nat.mul_le_mul_left amount h) (by decide)
  rw [hook_fee_at_ceiling] at hmono
  exact hmono

/-- The hook fee always fits the int128 the PoolManager accepts: it is at most a tenth of an
    amount that already fits an int128. -/
theorem hook_fee_fits_int128 (amount pips : Nat) (hamount : amount < 2 ^ 127)
    (hpips : pips ≤ MAX_HOOK_FEE_PIPS) : hookFee amount pips < 2 ^ 127 := by
  have h1 : hookFee amount pips ≤ amount / 10 := hook_fee_le_tenth amount pips hpips
  have h2 : amount / 10 ≤ amount := Nat.div_le_self amount 10
  omega

/-- A zero slippage allowance means the floor is the spot estimate itself. -/
theorem slippage_floor_zero (spotOut : Nat) : slippageFloor spotOut 0 = spotOut := by
  unfold slippageFloor BPS
  rw [Nat.sub_zero]
  exact Nat.mul_div_left spotOut (by decide)

/-- An allowance at most the ceiling never lets the floor exceed the spot estimate. -/
theorem slippage_floor_le (spotOut slippageBps : Nat) :
    slippageFloor spotOut slippageBps ≤ spotOut := by
  unfold slippageFloor
  calc spotOut * (BPS - slippageBps) / BPS ≤ spotOut * BPS / BPS :=
        div_le_div_right' (Nat.mul_le_mul_left spotOut (Nat.sub_le BPS slippageBps)) (by decide)
    _ = spotOut := Nat.mul_div_left spotOut (by decide)

/-- A larger allowance lowers the floor: the floor is antitone in the allowance. -/
theorem slippage_floor_mono (spotOut a b : Nat) (h : a ≤ b) :
    slippageFloor spotOut b ≤ slippageFloor spotOut a := by
  unfold slippageFloor
  exact div_le_div_right' (Nat.mul_le_mul_left spotOut (Nat.sub_le_sub_left h BPS)) (by decide)

/-- The predicate the hook charges on is exactly "the quote is the specified currency": the
    semantic reading (`isBuy == exactInput`) and the raw-field reading agree for every swap. -/
theorem chargeable_eq_quote_is_specified (zeroForOne exactInput quoteIsCurrency0 : Bool) :
    chargeable (isBuyOf zeroForOne quoteIsCurrency0) exactInput
      = quoteIsSpecified zeroForOne exactInput quoteIsCurrency0 := by
  unfold chargeable isBuyOf quoteIsSpecified
  cases zeroForOne <;> cases exactInput <;> cases quoteIsCurrency0 <;> rfl

/-! ## The parity fixture -/

/-- A single fixture row: inputs, and what the model says they produce. -/
structure Case where
  amount : Nat
  ownerBps : Nat
  lpBps : Nat
  hookFeePips : Nat
  spotOut : Nat
  slippageBps : Nat
  owner : Nat
  lp : Nat
  buyback : Nat
  fee : Nat
  floor : Nat

def mkCase (amount ownerBps lpBps hookFeePips spotOut slippageBps : Nat) : Case :=
  { amount, ownerBps, lpBps, hookFeePips, spotOut, slippageBps
  , owner := ownerShare amount ownerBps
  , lp := lpShare amount lpBps
  , buyback := buybackShare amount ownerBps lpBps
  , fee := hookFee amount hookFeePips
  , floor := slippageFloor spotOut slippageBps }

/-- The rows: a cross product of amounts, share weights, fee rates, spot estimates and slippage
    allowances. Every weight row is a config the contract would accept (`ownerBps ≤ 1_000`,
    `ownerBps + lpBps + buybackBps = 10_000`). -/
def cases : List Case :=
  let amounts := [0, 1, 9999, 10000, 1000000000000000000, 1000000000000000007,
                  123456789012345678901, 170141183460469231731687303715884105727]
  let splits := [(1000, 1000, 8000), (1000, 0, 9000), (0, 5000, 5000),
                 (500, 5000, 4500), (1000, 9000, 0), (0, 0, 10000)]
  let fees := [0, 1, 3000, 100000]
  let spots := [0, 1, 1000000000000000000, 1000000000000000003]
  let slips := [0, 1, 500, 2000]
  (amounts.flatMap fun a =>
    (splits.flatMap fun (ob, lb, _) =>
      (fees.map fun p => mkCase a ob lb p 0 0)
      ++ (spots.map fun s => mkCase a ob lb 3000 s 0))
    ++ slips.map fun sl => mkCase a 1000 1000 3000 1000000 sl)

def renderRow (c : Case) (i : Nat) : String :=
  s!"        c[{i}] = Case({c.amount}, {c.ownerBps}, {c.lpBps}, {c.hookFeePips}, \
  {c.spotOut}, {c.slippageBps}, {c.owner}, {c.lp}, {c.buyback}, {c.fee}, {c.floor});"

def render : String :=
  let cs := cases
  let n := cs.length
  let rows := String.intercalate "\n" (cs.enum.map fun (i, c) => renderRow c i)
  "// SPDX-License-Identifier: MIT\n"
  ++ "pragma solidity 0.8.26;\n\n"
  ++ "/// @notice GENERATED by verification/FeeSplit.lean -- do not edit by hand.\n"
  ++ "/// Regenerate with: `lean --run verification/FeeSplit.lean`\n"
  ++ "/// @dev Each row is (amount, ownerBps, lpBps, hookFeePips, spotOut, slippageBps) followed by the\n"
  ++ "///      model's (owner, lp, buyback, fee, floor). test/FeeSplitParity.t.sol replays every row\n"
  ++ "///      through HookFeeSplit and compares the results field by field.\n"
  ++ "library FeeSplitParityCases {\n"
  ++ "    struct Case {\n"
  ++ "        uint256 amount;\n"
  ++ "        uint256 ownerBps;\n"
  ++ "        uint256 lpBps;\n"
  ++ "        uint256 hookFeePips;\n"
  ++ "        uint256 spotOut;\n"
  ++ "        uint256 slippageBps;\n"
  ++ "        uint256 owner;\n"
  ++ "        uint256 lp;\n"
  ++ "        uint256 buyback;\n"
  ++ "        uint256 fee;\n"
  ++ "        uint256 floor;\n"
  ++ "    }\n\n"
  ++ "    function caseCount() internal pure returns (uint256) {\n"
  ++ "        return " ++ toString n ++ ";\n"
  ++ "    }\n\n"
  ++ "    function cases() internal pure returns (Case[] memory c) {\n"
  ++ "        c = new Case[](" ++ toString n ++ ");\n"
  ++ rows ++ "\n"
  ++ "    }\n"
  ++ "}\n"

def main : IO UInt32 := do
  IO.FS.writeFile "test/FeeSplitParityCases.sol" render
  IO.println s!"wrote test/FeeSplitParityCases.sol with {cases.length} cases"
  return 0

end FeeSplit

def main : IO UInt32 := FeeSplit.main
