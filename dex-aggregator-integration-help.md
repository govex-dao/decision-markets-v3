# DEX Aggregator Integration — Govex (spot side)

Govex spot pools are constant-product (Uniswap V2 style) and are the swap surface aggregators integrate against. An aggregator only quotes and routes against the **spot** pool.

But spot pools wrap an aggregator-managed escrow that hosts decision-market proposals. When a proposal is live, **every swap triggers an auto-rebalance** that moves liquidity between the spot pool and the embedded conditional AMM pools to keep spot price inside the conditional price band. So spot depth and price during a live proposal depend on the **conditional pool reserves and fees**, not just the spot reserves alone.

This doc covers what an aggregator needs to track to maintain a correct view of **spot** liquidity, price, and depth, including during live proposals. The split routing of user swaps across spot+conditional legs is internal to `swap_entry` — aggregators do not need to replay it.

Authoritative source: every formula and field below is mirrored from the public Move source in `futarchy_markets_*` and `futarchy_actions`. Where this doc and the source disagree, the source wins.

---

## 1. Package IDs

| Name | ID |
| --- | --- |
| `futarchy_markets_core` | `0x9a470e2a272f1aa1f81f5cd2a3066f878fffd9ce9c8d22309ad62f81e5b77dd2` |
| `futarchy_markets_operations` | `0x7279de2610213cdc1da0945f41f7ef7a58abf343e88165fb443be60f066e00a2` |
| `futarchy_markets_primitives` | `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781` |
| `futarchy_core` | `0xd515e9008496dd209ffb71caf0e5783073385cde00083c8a1437a32093aab95c` |

## 2. Stable shared objects

These three mutation-auth registries plus the Sui clock are passed as shared objects to every swap. Their IDs are fixed at protocol deployment; cache them once.

| Name | ID | Type |
| --- | --- | --- |
| Spot pool mutation registry | `0xe7b10d3e9d0dd9241c6742c7b470bcad8a47725a532da141e565fc3f55f9feed` | `0x9a47…dd2::spot_pool_mutation_auth::SpotPoolMutationRegistry` |
| Escrow mutation registry | `0x66493dc8caccb6f301a5c73f3ea4ecd53657634e9ceae0a9d4fab37f4f8a7441` | `0xd515…b95c::escrow_mutation_auth::EscrowMutationRegistry` |
| Market state mutation registry | `0xe9c4f8839e047def9df9bc6589c5a6fa7d0f94a7494932fc8e7230255772c485` | `0xd515…b95c::market_state_mutation_auth::MarketStateMutationRegistry` |
| Sui clock | `0x6` | `0x2::clock::Clock` |

Aggregators do not need to interpret the registries — just pass the three IDs as `&SpotPoolMutationRegistry`, `&EscrowMutationRegistry`, `&MarketStateMutationRegistry` arguments to the swap entry functions.

---

## 3. Pool discovery

Subscribe to `DaoSpotPoolCreated` from `futarchy_actions::liquidity_init_actions`:

```move
public struct DaoSpotPoolCreated has copy, drop {
    dao_id: ID,
    pool_id: ID,
    asset_type: AsciiString,        // e.g. "0000…002::sui::SUI"
    stable_type: AsciiString,
    lp_type: AsciiString,
    initial_asset_reserve: u64,
    initial_stable_reserve: u64,
    fee_bps: u64,                   // steady-state LP fee
}
```

`asset_type`, `stable_type`, `lp_type` are full type strings — use them directly as the three generic type args (`AssetType`, `StableType`, `LPType`) in PTB construction and RPC reads.

---

## 4. Spot pool object: `UnifiedSpotPool`

Type: `0x9a47…dd2::unified_spot_pool::UnifiedSpotPool<AssetType, StableType, LPType>`.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | `UID` | object ID |
| `asset_reserve` | `Balance<AssetType>` | spot asset reserve |
| `stable_reserve` | `Balance<StableType>` | spot stable reserve |
| `initial_asset_reserve` | `Option<u64>` | snapshot at first liquidity add |
| `initial_stable_reserve` | `Option<u64>` | snapshot at first liquidity add |
| `fee_bps` | `u64` | **steady-state LP fee in bps**; capped at `max_amm_fee_bps() = 500` (5%) |
| `minimum_liquidity` | `u64` | locked LP shares (1 000) |
| `lp_treasury_cap` | `TreasuryCap<LPType>` | LP coin issuance |
| `fee_schedule` | `Option<FeeSchedule>` | optional launch-fee decay |
| `fee_schedule_activation_time` | `u64` | ms timestamp when the schedule began |
| `active_proposal_id` | `Option<ID>` | `Some` ⇒ pool is locked for a proposal lifecycle |
| `last_proposal_end_time` | `Option<u64>` | enforces 6-hour gap between proposals |
| `aggregator_config` | `Option<AggregatorConfig>` | conditional-market wrapping (see below) |
| `is_dissolved` | `bool` | dissolved pools refuse all ops |

### `AggregatorConfig<AssetType, StableType>` (embedded in `aggregator_config`)

The fields aggregators care about:

| Field | Type | Meaning |
| --- | --- | --- |
| `active_escrow` | `Option<TokenEscrow<…>>` | embedded escrow. `Some` from the moment the escrow is bound to the pool — this can be **before** trading starts (during the proposal REVIEW phase) and **after** trading ends (until finalization). Use `are_swaps_allowed(escrow.market_state, clock)` to determine whether swaps + auto-rebalance actually run, **not** `has_active_escrow` alone. |
| `archived_escrows` | `Table<ID, TokenEscrow<…>>` | finalized escrows kept for redemption |
| `simple_twap` | `Option<SimpleTWAP>` | post-swap TWAP oracle |
| `conditional_liquidity_ratio_percent` | `u64` | % of spot reserves moved into conditional pools when a proposal starts (0..99) |
| `protocol_fees_asset` | `Balance<AssetType>` | accrued 50-bps protocol fee |
| `protocol_fees_stable` | `Balance<StableType>` | accrued 50-bps protocol fee |

Other fields (`last_proposal_usage`, `oracle_conditional_threshold_bps`, `spot_cumulative_at_lock`) are not relevant to aggregators.

### Read-only getters

| Function | Returns |
| --- | --- |
| `unified_spot_pool::get_reserves(pool)` | `(u64 asset, u64 stable)` |
| `unified_spot_pool::get_pool_id(pool)` | `ID` |
| `unified_spot_pool::has_active_escrow(pool)` | `bool` — pool wraps an escrow (REVIEW, TRADING, or post-trading window). Does **not** by itself mean swaps/rebalance are running — also gate on `are_swaps_allowed`. |
| `unified_spot_pool::is_locked_for_proposal(pool)` | `bool` — `active_proposal_id.is_some()`; set at quantum split / trading start, cleared at finalization. **Not** equivalent to `has_active_escrow`. |
| `unified_spot_pool::is_aggregator_enabled(pool)` | `bool` — protocol fees + conditional routing enabled |
| `unified_spot_pool::current_fee_bps(pool, clock)` | `u64` — total bps right now (post-decay) |
| `unified_spot_pool::lp_fee_bps(pool)` / `get_fee_bps(pool)` | `u64` — steady-state LP component (`pool.fee_bps`) |
| `unified_spot_pool::get_spot_price(pool)` | `u128` — `stable_reserve · 10^12 / asset_reserve` (0 if either reserve is 0) |
| `unified_spot_pool::is_dissolved(pool)` | `bool` |
| `unified_spot_pool::simulate_swap_stable_to_asset_accurate(pool, in, clock)` | `u64` out (with fees, matches mutator path) |
| `unified_spot_pool::simulate_swap_asset_to_stable_accurate(pool, in, clock)` | `u64` out (with fees) |

The simulate functions are pure-spot — during a live proposal they return what a pure-spot leg would yield, **not** what `swap_entry` will actually return (which is ≥ the simulate output, see §6).

---

## 5. Quiescent-pool pricing (no active proposal)

When `has_active_escrow(pool) == false`, the pool is pure constant-product with a two-component fee.

### Total fee in bps

```
steady_protocol_bps = is_aggregator_enabled(pool) ? 50 : 0
steady_lp_bps       = pool.fee_bps                                 # 0..500
steady_total_bps    = steady_protocol_bps + steady_lp_bps          # e.g. 50 + 25 = 75

if pool.fee_schedule is Some:
    current_total_bps = fee_scheduler::get_current_fee(
        schedule          = pool.fee_schedule,
        final_fee_bps     = steady_total_bps,
        start_time        = pool.fee_schedule_activation_time,
        current_time      = clock.timestamp_ms())
else:
    current_total_bps = steady_total_bps
```

### `fee_scheduler::get_current_fee` — closed form

`FeeSchedule { initial_fee_bps: u64, duration_ms: u64 }`, with `initial_fee_bps <= 9 900` and `duration_ms <= 86 400 000` (24 h).

```python
HALF_LIVES = 8                    # LAUNCH_DECAY_HALF_LIVES
PRECISION  = 100_000              # fee_precision_scale()

def get_current_fee(schedule, final_fee_bps, start_time, current_time):
    if schedule.duration_ms == 0:                  return final_fee_bps
    if final_fee_bps >= schedule.initial_fee_bps:  return final_fee_bps
    if current_time <= start_time:                 return schedule.initial_fee_bps

    elapsed = current_time - start_time
    if elapsed >= schedule.duration_ms:            return final_fee_bps

    fee_drop = schedule.initial_fee_bps - final_fee_bps

    scaled_pos          = elapsed * HALF_LIVES                       # 0 .. 8 · duration_ms
    complete_half_lives = scaled_pos // schedule.duration_ms         # 0..7
    half_life_remainder = scaled_pos %  schedule.duration_ms

    fee_drop_scaled = fee_drop * PRECISION
    fee_at_step     = fee_drop_scaled >> complete_half_lives
    fee_at_next     = fee_drop_scaled >> (complete_half_lives + 1)

    step_drop          = fee_at_step - fee_at_next
    interpolated_drop  = step_drop * half_life_remainder // schedule.duration_ms
    remaining_scaled   = fee_at_step - interpolated_drop

    remaining_fee_bps  = ceil_div(remaining_scaled, PRECISION)
    current_fee        = final_fee_bps + remaining_fee_bps
    return min(current_fee, schedule.initial_fee_bps)
```

The remaining premium halves at 8 anchor points across `duration_ms`, with linear interpolation between anchors. After `duration_ms`, the fee is exactly `final_fee_bps`. The default schedule is 99 % over 15 minutes.

### Constant-product math (per swap)

```
total_fee   = floor(amount_in * current_total_bps / 10_000)
if amount_in <= total_fee: return 0
effective   = amount_in - total_fee
out         = floor(reserve_out_u128 * effective_u128
                    / (reserve_in_u128 + effective_u128))
if out >= reserve_out: return 0
if out == 0:           return 0
```

`simulate_swap_*_accurate` returns 0 in any failure case. The mutator path aborts.

### Reserve update (for replay)

```
protocol_fee = floor(total_fee * steady_protocol_bps / steady_total_bps)
lp_fee       = total_fee - protocol_fee
```

After the swap:
- `protocol_fee` of the input is moved to `aggregator_config.protocol_fees_{asset|stable}` (only if aggregator is enabled).
- The remainder of the input (`amount_in − protocol_fee`, equal to `effective + lp_fee`) is added to the input-side reserve.
- `out` is removed from the output-side reserve.

So `k = asset_reserve · stable_reserve` is **non-decreasing** on every swap (LP fees grow `k`; with rounded-to-zero LP fees and exact division `k` can be unchanged).

---

## 6. Live-proposal mode — what happens to spot depth

When `has_active_escrow(pool) == true`, two things change for spot reserves:

**(a) Initial drain at proposal start (quantum split).** When a proposal transitions into trading, `conditional_liquidity_ratio_percent` of the spot reserves is moved into the embedded escrow as initial liquidity for the conditional AMM pools (one pool per outcome). After this, the spot pool's reserves are reduced by that fraction. The conditionals start at the same price as spot. **This step does not emit `SpotLiquidityAdded`/`SpotLiquidityRemoved`** — it goes through `quantum_lp_manager`, which mutates reserves directly.

**(b) Quantum redeem at proposal end.** When the proposal finalizes, the conditional liquidity unwinds and returns to the spot pool. **Also does not emit a `Spot*` liquidity event.**

**(c) Per-swap auto-rebalance.** Calls to `swap_entry::swap_spot_*` may trigger `arbitrage::auto_rebalance_spot_after_conditional_swaps` after the user's swap legs run. The rebalance is gated: it runs only when `are_swaps_allowed` is true (§6.3), and even then it can no-op when (i) spot is already in the conditional price band, (ii) no profitable arb amount is found, or (iii) safety checks (overflow, escrow backing) fail. When it does run, it pushes spot price toward the conditional price band by maximizing spot-pool `k`, and **mutates spot reserves**.

There is also a batch path (`extract_escrow_for_batch` / `store_escrow_after_batch` / `finalize_conditional_swaps` in `swap_entry`) used by some proposal flows. Its `store_escrow_after_batch` runs a mandatory rebalance that mutates spot reserves **without emitting a `SpotSwap` event** — only `SystemRebalanceExecuted`.

These mechanics tie spot depth/price to **conditional pool state**. To know spot's current liquidity and price during a live proposal, an aggregator must either read the spot pool object directly, or maintain a mirror that consumes the lifecycle and rebalance signals listed in §8.

User-side note: when a proposal is live, `swap_entry` may also route some of the user's input through the conditional pools directly (split routing) and then run the auto-rebalance. The user receives a normal coin output ≥ `min_*_out`, possibly accompanied by a small `ConditionalMarketBalance` dust object. **Aggregators do not need to model the user split routing** — quote against the current spot reserves with §5, set `min_*_out` to that quote, and the actual output will be ≥ the quote (split routing only ever improves user output relative to pure-spot). The dust object is auto-transferred to the recipient when `return_balance=false`.

The remaining sections (6.1–6.5) describe the conditional state aggregators need to read in order to predict auto-rebalance effects on spot reserves.

### 6.1 Tracked objects (during a live proposal)

| Name | Where to find | Type |
| --- | --- | --- |
| Active escrow | `pool.aggregator_config.active_escrow` (embedded) | `0x844f…3781::coin_escrow::TokenEscrow<AssetType, StableType>` |
| Market state | `escrow.market_state` (embedded) | `0x844f…3781::market_state::MarketState` |
| Conditional AMM pools | `MarketState.amm_pools[i]` (embedded vector, one per outcome) | `0x844f…3781::conditional_amm::LiquidityPool` |

Reading the spot pool object retrieves the entire tree.

### 6.2 `MarketState` (relevant fields)

| Field | Type | Meaning |
| --- | --- | --- |
| `amm_pools` | `Option<vector<LiquidityPool>>` | one per outcome; `None` until market initialization |
| `outcome_count` | `u64` | 2..50 |
| `status` | `MarketStatus { trading_started, trading_ended, in_execution_window, finalized }` | phase machine |
| `trading_end` | `Option<u64>` | scheduled end (set when trading starts) |
| `execution_deadline` | `Option<u64>` | execution-window expiry |

### 6.3 `are_swaps_allowed(market_state, clock)` — does auto-rebalance run?

Auto-rebalance runs only if this returns `true`. Otherwise `swap_entry` routes the user's input pure-spot and skips the rebalance entirely (spot reserves change only by the user's spot leg).

```
if !trading_started:                          return false
if finalized:                                 return false
if !(!trading_ended || in_execution_window):  return false   # one is enough

if !trading_ended and trading_end is Some:
    if !(now < trading_end):                  return false

if in_execution_window:
    if execution_deadline is None:            return false
    if !(now < execution_deadline):           return false

return true
```

There is a window where `has_active_escrow=true` but `are_swaps_allowed=false` (between trading-end and finalization, or after execution-deadline expiry). In that window the pool behaves like a quiescent pool — pure §5 math applies and reserves are unaffected by conditional state.

### 6.4 Conditional AMM pool: `LiquidityPool`

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | `UID` | |
| `market_id` | `ID` | back-link to the MarketState UID |
| `outcome_idx` | `u8` | |
| `asset_reserve` | `u64` | conditional reserves (bare `u64`, not `Balance`) |
| `stable_reserve` | `u64` | |
| `fee_percent` | `u64` | LP fee in bps; capped at 500 |
| `oracle` | `Oracle` | embedded futarchy TWAP |
| `protocol_fees_asset` / `_stable` | `u64` | accrued |
| `lp_supply` | `u64` | |
| `pending_*` | `u64` / `bool` | in-flight arbitrage state (transient, ignore) |

Getters: `conditional_amm::get_reserves(pool)`, `get_fee_bps(pool)` (returns `pool.fee_percent`), `get_current_price(pool) = stable_reserve · 10^12 / asset_reserve` (aborts on zero reserves — relevant before quantum liquidity is injected).

### 6.5 Conditional swap math

Constant product, two separate fees applied additively (no fee schedule on conditionals):

```
PROTOCOL_FEE_BPS = 50            # constants::protocol_fee_bps()
LP_FEE_BPS       = pool.fee_percent

protocol_fee = floor(amount_in * PROTOCOL_FEE_BPS / 10_000)
lp_fee       = floor(amount_in * LP_FEE_BPS       / 10_000)
total_fee    = protocol_fee + lp_fee
if amount_in <= total_fee: return 0
effective    = amount_in - total_fee
out          = floor(reserve_out_u128 * effective_u128
                     / (reserve_in_u128 + effective_u128))
if out >= reserve_out: return 0
if out == 0:           return 0
```

Aggregators only need this formula for **feeless** quotes inside the auto-rebalance optimizer (§6.6). User-leg quotes use it with fees, but aggregators don't need user-leg quotes — they can rely on `swap_entry` returning ≥ pure-spot output.

### 6.6 The auto-rebalance algorithm

After the user's swap legs run, `arbitrage::auto_rebalance_spot_after_conditional_swaps` runs **iff `are_swaps_allowed` is true**. It tries to push spot price toward the conditional price band by maximizing spot-pool `k`, arbitraging between the spot pool and the conditionals using **inject/swap/extract** on the conditional pools — which is **fee-free** (the dedicated reserve-mutation functions bypass the protocol+LP fee). It does not enforce a postcondition; it can no-op or only partially close the price gap.

Both directions act on **all** conditional pools simultaneously (quantum). `compute_optimal_internal_rebalance(spot, pools, hint=0)` returns `(arb_amount, is_cond_to_spot, k_gain)`:

```
classify_spot_position(spot, pools) -> (spot_above_all, spot_below_all)
  spot_price = stable_reserve / asset_reserve
  cross-multiply per pool to avoid division

if spot_below_all:                                       # spot price too LOW (asset cheap in spot)
    if spot_asset < 2: return (0, false, 0)
    pick arb_amount ∈ [0, spot_asset - 1]                # search bound = spot_asset - 1
    score = (spot_asset - x) * (spot_stable + min_cond_stable_out_feeless(pools, x)) - old_k
    if best score > 0: return (best_x, is_cond_to_spot=false, score)

if spot_above_all:                                       # spot price too HIGH (asset cheap in conds)
    let min_cond_asset = min over pools of cond_asset[i]
    if min_cond_asset < 2: return (0, false, 0)
    pick arb_amount ∈ [0, min_cond_asset - 1]            # search bound = min cond_asset - 1
    stable_needed = max_conditional_stable_cost(pools, x)
                  = max over pools of ceil((cond_stable * x) / (cond_asset - x))
    min_asset     = min_cond_asset_out_feeless(pools, stable_needed)
    score = (spot_asset + min_asset) * (spot_stable - stable_needed) - old_k
    if best score > 0: return (best_x, is_cond_to_spot=true, score)

else: return (0, false, 0)                               # already in band, no-op
```

Both inner ternary searches use `MIN_COARSE_THRESHOLD = 3` and a final brute-force sweep over the residual interval. A "smart bound" `apply_smart_bound(global_ub, user_swap_output)` is also applied — when called from `auto_rebalance_*`, `user_swap_output = 0` so the smart bound degrades to the global upper bound.

**Feeless conditional helpers** (used only by the rebalance optimizer):

```
min_conditional_asset_out(pools, stable_in) = min over pools of  cond_asset · stable_in / (cond_stable + stable_in)
min_conditional_stable_out(pools, asset_in) = min over pools of  cond_stable · asset_in / (cond_asset + asset_in)
max_conditional_stable_cost(pools, asset_x) = max over pools of  ceil(cond_stable · asset_x / (cond_asset - asset_x))
                                              (returns u128::MAX if any pool has cond_asset <= asset_x)
```

Execution effect on **spot reserves**:

```
if is_cond_to_spot:                                       # spot was too HIGH
    spot.stable_reserve  -= stable_needed
    spot.asset_reserve   += min_asset
    (escrow's escrowed_* and conditional pools' reserves are also mutated)

else:                                                     # spot was too LOW
    spot.asset_reserve   -= arb_amount
    spot.stable_reserve  += min_stable
    (escrow's escrowed_* and conditional pools' reserves are also mutated)

emit SystemRebalanceExecuted { market_id, is_cond_to_spot, arb_amount_hint, actual_input, actual_output, retained_system_dust_created }
```

Aggregator implementations have two viable strategies for keeping a fresh spot mirror:

1. **Event-driven mirror (recommended).** Subscribe to `SpotSwap` for the common path (its `asset_reserve` and `stable_reserve` fields are emitted **after** the user swap and the auto-rebalance), plus the lifecycle and rebalance signals in §8 to handle the paths that don't emit `SpotSwap`:
   - Quantum split at proposal start (no Spot* event) — re-read pool object on `TradingStartedEvent`.
   - Quantum redeem at proposal end (no Spot* event) — re-read pool object on `MarketStateFinalizedEvent`.
   - Batch-path rebalance (no `SpotSwap`, only `SystemRebalanceExecuted`) — re-read pool object on `SystemRebalanceExecuted` whose owning tx didn't also emit `SpotSwap`.
   - Governance fee changes — track `GovernancePoolFeeUpdated` and update mirrored `fee_bps`.
2. **Predictive mirror (advanced).** Maintain spot **and** conditional reserves locally and predict the post-swap state without waiting for events. Requires (a) the user-leg split routing — see `arbitrage_math::compute_best_stable_to_asset_split` / `compute_best_asset_to_stable_split` and the conditional fee model in §6.5; (b) the auto-rebalance algorithm in §6.6; (c) the escrow backing caps (`escrow.escrowed_asset` / `escrowed_stable`) used as `conditional_*_output_cap`. Use only if you need quote freshness between blocks.

Most aggregators will want strategy 1.

---

## 7. Swap entry functions (PTB construction)

Module: `0x7279…00a2::swap_entry`. These are the only public entry points aggregators should use; lower-level `unified_spot_pool::swap_*` aborts when a proposal is locked.

```move
public fun swap_spot_stable_to_asset<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    recipient: address,
    existing_balance_opt: Option<ConditionalMarketBalance<AssetType, StableType>>,
    return_balance: bool,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (Option<Coin<AssetType>>, Option<ConditionalMarketBalance<AssetType, StableType>>)

public fun swap_spot_asset_to_stable<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    recipient: address,
    existing_balance_opt: Option<ConditionalMarketBalance<AssetType, StableType>>,
    return_balance: bool,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (Option<Coin<StableType>>, Option<ConditionalMarketBalance<AssetType, StableType>>)
```

### Argument semantics

| Arg | Notes |
| --- | --- |
| `*_in` | input coin; aborts `EZeroAmount` if value is 0 |
| `min_*_out` | recombined-output gate; aborts `EMinAmountNotMet` if final output < this |
| `recipient` | address that receives the output coin and any non-empty dust balance, when `return_balance=false` |
| `existing_balance_opt` | aggregators normally pass `None`; only relevant for callers accumulating dust across multiple swaps |
| `return_balance` | aggregators normally pass `false` (auto-transfer everything to `recipient` and return `(None, None)`) |
| three registries | shared registry IDs from §2 |
| `clock` | `0x6` |

### Output for an aggregator

With `return_balance=false`:
- The output coin is `transfer::public_transfer`'d to `recipient` with value `≥ min_*_out`.
- If the swap was during a live proposal **and** produced per-outcome dust, a `ConditionalMarketBalance` object is also transferred to `recipient`. (If empty, it's destroyed instead.)
- The function returns `(None, None)`.

### Quote → swap pattern

```
1. Read current spot reserves (from your event mirror).
2. quote = simulate_*_accurate(spot, amount_in, now)        # apply §5 offchain
3. min_out = quote * (1 - slippage)
4. Submit swap_spot_stable_to_asset(..., min_out, recipient, None, false, …)
5. Actual output is ≥ quote (during a live proposal it can be higher because of split routing).
```

If you would rather skip pools during proposals, gate routing on `is_locked_for_proposal(pool) == false` (covers TRADING + execution-window phases, when the pool is bound to a live proposal). `has_active_escrow` is broader: it can be `true` during REVIEW or after finalization-but-before-archive, when the pool is effectively still tradeable as pure spot — gating on it is overly conservative.

---

## 8. Events to subscribe to

### Pool genesis

`futarchy_actions::liquidity_init_actions::DaoSpotPoolCreated` — see §3.

### Spot reserve state (`futarchy_markets_core::unified_spot_pool`)

```move
public struct SpotPoolInitialized {           // first liquidity add
    pool_id: ID, asset_reserve: u64, stable_reserve: u64,
    price: u128, fee_bps: u64,
}
public struct SpotLiquidityAdded {
    pool_id: ID, provider: address,
    asset_amount: u64, stable_amount: u64, lp_amount: u64,
    excess_asset_amount: u64, excess_stable_amount: u64,
    asset_reserve: u64, stable_reserve: u64,                  // post-add
    is_initial: bool,
}
public struct SpotLiquidityRemoved {
    pool_id: ID, provider: address,
    asset_amount: u64, stable_amount: u64, lp_amount: u64,
    asset_reserve: u64, stable_reserve: u64,                  // post-remove
}
```

### Spot swap (`futarchy_markets_operations::swap_entry`)

```move
public struct SpotSwap {
    pool_id: ID,
    is_buy: bool,                  // true = stable→asset
    amount_in: u64,
    amount_out: u64,               // recombined output (post conditional routing if any)
    sender: address,
    recipient: address,
    asset_reserve: u64,            // pool reserves AFTER swap and AFTER auto-rebalance
    stable_reserve: u64,
}
```

This is the single most important event for spot tracking. Reserves are **post-rebalance** — one event suffices to keep the spot mirror fresh, no separate handling for the rebalance is needed.

### Auto-rebalance (`futarchy_markets_core::arbitrage`)

```move
public struct SystemRebalanceExecuted {
    market_id: ID,
    is_cond_to_spot: bool,
    arb_amount_hint: u64,
    actual_input: u64,
    actual_output: u64,
    retained_system_dust_created: bool,
}
```

Most spot rebalances are paired with a `SpotSwap` in the same tx (post-rebalance reserves already captured there). But the batch path (`store_escrow_after_batch`, `finalize_conditional_swaps`) emits `SystemRebalanceExecuted` **without** a `SpotSwap` — when an indexer sees this event with no accompanying `SpotSwap`, it must re-read the spot pool object.

### Governance fee updates (`futarchy_actions::liquidity_actions`)

```move
public struct GovernancePoolFeeUpdated {
    account_id: ID,
    pool_id: ID,
    new_fee_bps: u64,
}
```

`pool.fee_bps` is mutable via `set_fee_bps` (capped at `max_amm_fee_bps()=500`). Subscribe to this event to keep the mirrored fee fresh.

### Market lifecycle (`futarchy_markets_primitives::market_state`)

```move
public struct TradingStartedEvent          { proposal_id, start_time }
public struct TradingEndedEvent            { proposal_id, timestamp_ms }
public struct ExecutionWindowStartedEvent  { proposal_id, market_winner, execution_deadline, timestamp_ms }
public struct ExecutionTimeoutEvent        { proposal_id, market_winner, actual_winner (=0), timestamp_ms }
public struct MarketStateFinalizedEvent    { proposal_id, winning_outcome, timestamp_ms }
```

**Use these as the trigger to re-read the spot pool object.** Quantum split (at trading start) and quantum redeem (at finalization) mutate spot reserves directly via `quantum_lp_manager` and **do not emit `SpotLiquidityAdded`/`SpotLiquidityRemoved`**. An event-only mirror without these triggers will desync at proposal start and end.

### Conditional pool events — only if running a predictive mirror

```move
// futarchy_markets_primitives::conditional_amm
public struct PoolCreated      { pool_id, market_id, outcome_idx, asset_reserve, stable_reserve, price, fee_bps, timestamp }
public struct SwapEvent        { market_id, outcome (u8), is_buy, amount_in, amount_out,
                                 price_impact, price, sender, asset_reserve, stable_reserve, timestamp }
public struct LiquidityAdded   { market_id, outcome, asset_amount, stable_amount, lp_amount, sender, timestamp }
public struct LiquidityRemoved { market_id, outcome, asset_amount, stable_amount, lp_amount, sender, timestamp }
```

Skip these if you're using the event-only spot mirror — `SpotSwap` already captures the net effect of every swap on spot reserves.

---

## 9. Worked example — quote during a live proposal, event-only mirror

State maintained by aggregator:

```
spot.asset_reserve  = 10_000_000_000      // updated from latest SpotSwap
spot.stable_reserve = 22_000_000_000      // updated from latest SpotSwap
spot.fee_bps        = 25
spot.fee_schedule   = None
aggregator_enabled  = true
has_active_escrow   = true                // this pool is in a live proposal right now
```

User wants to swap 1 000 000 stable in. Quote:

```
steady_total_bps = 50 + 25 = 75
current_total    = 75
total_fee        = floor(1_000_000 * 75 / 10_000)            = 7_500
effective        = 992_500
asset_out_quote  = floor(10_000_000_000 * 992_500
                         / (22_000_000_000 + 992_500))       = 432_… (floor, pure spot)
```

Submit swap with `min_asset_out = floor(asset_out_quote * 0.99)` (1 % slippage tolerance).

Actual onchain behaviour:
1. `swap_entry` extracts the escrow.
2. `compute_best_stable_to_asset_split` decides how much of the 1 000 000 to route through spot vs conditionals to maximize total output. The total output is **always ≥ pure-spot output** (the optimizer never does worse than `(amount_in, 0)`).
3. The user receives a coin with value `actual_out ≥ asset_out_quote`. They might also receive a small `ConditionalMarketBalance` dust object — auto-transferred to `recipient` since you passed `return_balance=false`.
4. Auto-rebalance runs, mutating spot reserves further.
5. `SpotSwap` is emitted with **final** reserves and `amount_out = actual_out`.

Aggregator action: consume the `SpotSwap` event, overwrite mirror `asset_reserve`/`stable_reserve`, and you're ready for the next quote. No special-casing needed.

---

## 10. Gotchas

- **Spot fee schedule can start at 99 %.** Pools with `fee_schedule = Some(...)` decay from `initial_fee_bps` (≤ 9 900) to `final_fee_bps = steady_total_bps` over `duration_ms` (≤ 24 h). Hard-coding any flat fee will mis-quote during a launch window.
- **Auto-rebalance is gated and best-effort.** It runs only when `are_swaps_allowed`, and even then it can no-op if spot is already in the conditional band, no profitable arb exists, or safety checks (overflow, escrow backing) fail. Don't rely on a postcondition that spot price is always in band.
- **`SpotSwap` reserves are post-rebalance for the user-swap path only.** The batch path (`store_escrow_after_batch`, `finalize_conditional_swaps`) and the quantum split/redeem paths mutate spot reserves without emitting `SpotSwap`. A correct mirror also needs to refresh on `SystemRebalanceExecuted` (when no `SpotSwap` is paired with it), `TradingStartedEvent`, and `MarketStateFinalizedEvent`.
- **`pool.fee_bps` is governance-mutable.** Track `GovernancePoolFeeUpdated` to keep mirrored fees fresh.
- **`has_active_escrow` ≠ "swaps + rebalance are running"** — it can be `Some` during REVIEW (before trading) and after trading-end. Use `are_swaps_allowed(escrow.market_state, clock)` to determine the actual swap/rebalance state.
- **There is a window where `has_active_escrow=true` but `are_swaps_allowed=false`** (post-trading-end or post-execution-deadline). In that window the pool is effectively quiescent — pure §5 math applies, no rebalance runs.
- **Spot pool refuses swaps when `is_dissolved=true`.**
- **Lower-level `unified_spot_pool::swap_*_for_*` abort during a live proposal.** Always go through `swap_entry`.
- **Three mutation-registry IDs are required arguments to every swap.** Stable shared objects; cache them.
- **All prices use `1e12` scaling** (`constants::price_scale() = 1_000_000_000_000`).
- **Aggregators may receive a `ConditionalMarketBalance` dust object on swaps during live proposals.** When `return_balance=false`, this is auto-transferred to `recipient` (or destroyed if empty). The recipient is whatever address you set.
- **Quotes via §5 are conservative during live proposals.** The actual output from `swap_entry` is `≥` the spot-only quote because the split optimizer maximizes total output. Setting `min_*_out` to the spot quote (minus slippage) is always safe.
