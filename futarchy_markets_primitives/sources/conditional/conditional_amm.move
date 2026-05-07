// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_markets_primitives::conditional_amm;

use futarchy_core::market_state_mutation_auth::MarketStateMutationAuth;
use futarchy_markets_primitives::futarchy_twap_oracle::{Self, Oracle};
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::math;
use std::u64;
use sui::clock::Clock;
use sui::event;

// === Introduction ===
// This is a Uniswap V2-style XY=K AMM implementation for futarchy prediction markets.
//
// === Live-Flow Model Architecture ===
// This AMM is part of the "live-flow" liquidity model which allows dynamic liquidity
// management even while proposals are active. Key features:
//
// 1. **No Liquidity Locking**: Unlike traditional prediction markets, liquidity providers
//    can add or remove liquidity at any time, even during active proposals.
//
// 2. **Conditional Token Pools**: Each AMM pool trades conditional tokens (not spot tokens)
//    for a specific outcome. This allows the spot pool to remain liquid.
//
// 3. **Proportional Liquidity**: When LPs add/remove from the spot pool during active
//    proposals, liquidity is proportionally distributed/collected across all outcome AMMs.
//
// 4. **LP Token Architecture**: Each AMM pool has its own LP token type, but in the live-flow
//    model, these are managed internally. LPs only receive spot pool LP tokens.
//
// The flow works as follows:
// - Add liquidity: Spot tokens → Mint conditional tokens → Distribute to AMMs
// - Remove liquidity: Collect from AMMs → Redeem conditional tokens → Return spot tokens
//
// === Fee Model: Additive (Steady-State) ===
// Unlike the spot pool which uses proportional fee splitting with a launch fee schedule,
// the conditional AMM uses a simple additive fee model:
//
//   protocol_fee = amount_in * protocol_fee_bps / 10000  (0.5%)
//   lp_fee = amount_in * pool.fee_bps / 10000           (0.25%)
//   total_fee = protocol_fee + lp_fee                    (0.75%)
//
// This is mathematically equivalent to the spot pool's proportional model at steady state.
// The conditional AMM has NO fee schedule because:
// - Proposals only become tradeable after the spot pool's launch fee period ends
// - Anti-snipe protection is not needed for conditional markets
// - Simpler implementation with lower gas costs for high-frequency prediction market trading

// === Errors ===
const ELowLiquidity: u64 = 0; // Pool liquidity below minimum threshold
const EPoolEmpty: u64 = 1; // Attempting to swap/remove from empty pool
const EExcessiveSlippage: u64 = 2; // Output amount less than minimum specified
const EDivByZero: u64 = 3; // Division by zero in calculations
const EZeroLiquidity: u64 = 4; // Pool has zero liquidity
const EPriceTooHigh: u64 = 5; // Price exceeds maximum allowed value
const EZeroAmount: u64 = 6; // Input amount is zero
const EMarketIdMismatch: u64 = 7; // Market ID doesn't match expected value
const EInsufficientLPTokens: u64 = 8; // Not enough LP tokens to burn
const EOverflow: u64 = 10; // Arithmetic overflow detected
const EInvalidFeeRate: u64 = 11; // Fee rate is invalid (e.g., >= 100%)
const EKInvariantViolation: u64 = 12; // K-invariant violation (guards constant-product invariant)
const EImbalancedLiquidity: u64 = 13; // Liquidity deposit does not match the current pool ratio
const EAmountTooSmall: u64 = 14; // Input amount too small to cover fees
const EMarketMismatch: u64 = 15; // Market ID mismatch between pool and market state
const EInjectionMismatch: u64 = 16; // Reserve doesn't reflect expected injection
const EInjectionAlreadyPending: u64 = 17; // inject→swap→extract must complete before next inject
const ENoInjectionPending: u64 = 18; // swap/extract requires prior inject
const EOracleAdvancedPastDeadline: u64 = 19; // Oracle advanced past target_time — TWAP cannot be frozen retroactively
const EOracleStartTimeInFuture: u64 = 20; // Oracle start time must not exceed the current clock
const EInjectedSwapAlreadyDone: u64 = 21; // pending injection already has a calculated swap output
const EInjectedSwapNotDone: u64 = 22; // extract requires a calculated injected swap output

// === Structs ===

public struct LiquidityPool has key, store {
    id: UID,
    market_id: ID,
    outcome_idx: u8,
    asset_reserve: u64,
    stable_reserve: u64,
    fee_percent: u64,
    oracle: Oracle, // Futarchy oracle (for determining winner, internal use)
    protocol_fees_asset: u64, // Track accumulated asset token fees (overflow practically impossible: u64 max ~18.4e18)
    protocol_fees_stable: u64, // Track accumulated stable token fees (overflow practically impossible: u64 max ~18.4e18)
    lp_supply: u64, // Track total LP shares for this pool
    pending_injected_asset: u64, // Exact asset amount injected for an in-flight arbitrage reserve operation
    pending_injected_stable: u64, // Exact stable amount injected for an in-flight arbitrage reserve operation
    pending_asset_out: u64, // Exact asset output calculated by the in-flight injected swap
    pending_stable_out: u64, // Exact stable output calculated by the in-flight injected swap
    pending_swap_done: bool, // True after swap_from_injected_* and before extract_reserves_for_arbitrage
}

// === Events ===
public struct SwapEvent has copy, drop {
    market_id: ID,
    outcome: u8,
    is_buy: bool,
    amount_in: u64,
    amount_out: u64,
    price_impact: u128,
    price: u128,
    sender: address,
    asset_reserve: u64,
    stable_reserve: u64,
    timestamp: u64,
}

public struct LiquidityAdded has copy, drop {
    market_id: ID,
    outcome: u8,
    asset_amount: u64,
    stable_amount: u64,
    lp_amount: u64,
    sender: address,
    timestamp: u64,
}

public struct LiquidityRemoved has copy, drop {
    market_id: ID,
    outcome: u8,
    asset_amount: u64,
    stable_amount: u64,
    lp_amount: u64,
    sender: address,
    timestamp: u64,
}

/// Emitted when a new conditional AMM pool is created.
/// Maps pool_id and outcome_idx to oracle_id for debugging PriceEvents.
public struct PoolOracleCreated has copy, drop {
    /// The pool's object ID
    pool_id: ID,
    /// The market this pool belongs to
    market_id: ID,
    /// The outcome index (0 = REJECT, 1 = ACCEPT, etc.)
    outcome_idx: u8,
    /// The oracle's object ID (matches oracle_id in PriceEvent)
    oracle_id: ID,
}

fun has_pending_injection(pool: &LiquidityPool): bool {
    pool.pending_injected_asset > 0 ||
        pool.pending_injected_stable > 0 ||
        pool.pending_asset_out > 0 ||
        pool.pending_stable_out > 0 ||
        pool.pending_swap_done
}

fun assert_no_pending_injection(pool: &LiquidityPool) {
    assert!(!has_pending_injection(pool), EInjectionAlreadyPending);
}

fun assert_exactly_one_injected_side(asset_amount: u64, stable_amount: u64) {
    assert!(asset_amount > 0 || stable_amount > 0, EZeroAmount);
    assert!(
        (asset_amount == 0 && stable_amount > 0) ||
            (asset_amount > 0 && stable_amount == 0),
        EInjectionMismatch,
    );
}

fun assert_reserve_add_safe(pool: &LiquidityPool, asset_amount: u64, stable_amount: u64) {
    assert!(pool.asset_reserve <= u64::max_value!() - asset_amount, EOverflow);
    assert!(pool.stable_reserve <= u64::max_value!() - stable_amount, EOverflow);
}

fun clear_pending_injection(pool: &mut LiquidityPool) {
    pool.pending_injected_asset = 0;
    pool.pending_injected_stable = 0;
    pool.pending_asset_out = 0;
    pool.pending_stable_out = 0;
    pool.pending_swap_done = false;
}

/// Emitted when a new conditional AMM pool is created with initial liquidity.
/// Provides initial price data so indexers can show prices before any swaps occur.
public struct PoolCreated has copy, drop {
    pool_id: ID,
    market_id: ID,
    outcome_idx: u8,
    asset_reserve: u64,
    stable_reserve: u64,
    /// Initial price (stable/asset * 1e12)
    price: u128,
    /// LP fee in basis points (snapshot at creation)
    fee_bps: u64,
    timestamp: u64,
}

// === Public Functions ===
public fun new_pool(
    market_id: ID,
    outcome_idx: u8,
    fee_percent: u64,
    initial_asset: u64,
    initial_stable: u64,
    twap_initial_observation: Option<u128>,
    twap_start_delay: u64,
    twap_cap_ppm: u64,
    _auth: &MarketStateMutationAuth,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidityPool {
    assert!(initial_asset > 0 && initial_stable > 0, EZeroAmount);
    let k = math::mul_div_to_128(initial_asset, initial_stable, 1);
    assert!(fee_percent <= constants::max_amm_fee_bps(), EInvalidFeeRate);

    // Determine initial price for oracle:
    // - Some(price): Use previous proposal's winning TWAP (for cross-proposal continuity)
    // - None: Calculate from reserves (first proposal for this DAO)
    let initial_price = if (twap_initial_observation.is_some()) {
        *twap_initial_observation.borrow()
    } else {
        math::mul_div_to_128(
            initial_stable,
            constants::price_precision_scale(),
            initial_asset,
        )
    };

    check_price_under_max(initial_price);

    // Initialize futarchy oracle (for determining winner)
    let oracle = futarchy_twap_oracle::new_oracle(
        initial_price,
        twap_start_delay,
        twap_cap_ppm,
        ctx,
    );

    // Get oracle ID before moving it into the pool
    let oracle_id = futarchy_twap_oracle::oracle_id(&oracle);

    // Mint LP tokens for the seed reserves (Uniswap V2 style).
    // sqrt(initial_asset * initial_stable) LP tokens are locked — no one owns them.
    // This prevents the first add_liquidity_proportional caller from capturing
    // unowned seed value (the "first LP drain" vulnerability).
    let initial_lp = (k.sqrt() as u64);
    assert!(initial_lp > constants::minimum_liquidity(), ELowLiquidity);

    // Create pool object
    let pool = LiquidityPool {
        id: object::new(ctx),
        market_id,
        outcome_idx,
        asset_reserve: initial_asset,
        stable_reserve: initial_stable,
        fee_percent,
        oracle,
        protocol_fees_asset: 0,
        protocol_fees_stable: 0,
        lp_supply: initial_lp,
        pending_injected_asset: 0,
        pending_injected_stable: 0,
        pending_asset_out: 0,
        pending_stable_out: 0,
        pending_swap_done: false,
    };

    // Emit event to map pool/outcome to oracle ID (for debugging PriceEvents)
    event::emit(PoolOracleCreated {
        pool_id: object::id(&pool),
        market_id,
        outcome_idx,
        oracle_id,
    });

    // Emit PoolCreated with initial price so indexers can show prices before swaps
    event::emit(PoolCreated {
        pool_id: object::id(&pool),
        market_id,
        outcome_idx,
        asset_reserve: initial_asset,
        stable_reserve: initial_stable,
        price: initial_price,
        fee_bps: fee_percent,
        timestamp: sui::clock::timestamp_ms(clock),
    });

    pool
}

/// Create a pool with zero reserves and an explicit initial price.
/// Used when conditional AMM pools are created at proposal time with no backing;
/// liquidity is added later via `auto_quantum_split_on_proposal_start`.
/// When `add_liquidity_proportional` is later called on this pool, `lp_supply == 0`
/// triggers the first-provider bootstrap path.
public fun new_empty_pool(
    market_id: ID,
    outcome_idx: u8,
    fee_percent: u64,
    initial_price: u128,
    twap_start_delay: u64,
    twap_cap_ppm: u64,
    _auth: &MarketStateMutationAuth,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidityPool {
    assert!(fee_percent <= constants::max_amm_fee_bps(), EInvalidFeeRate);
    check_price_under_max(initial_price);

    let oracle = futarchy_twap_oracle::new_oracle(
        initial_price,
        twap_start_delay,
        twap_cap_ppm,
        ctx,
    );

    let oracle_id = futarchy_twap_oracle::oracle_id(&oracle);

    let pool = LiquidityPool {
        id: object::new(ctx),
        market_id,
        outcome_idx,
        asset_reserve: 0,
        stable_reserve: 0,
        fee_percent,
        oracle,
        protocol_fees_asset: 0,
        protocol_fees_stable: 0,
        lp_supply: 0,
        pending_injected_asset: 0,
        pending_injected_stable: 0,
        pending_asset_out: 0,
        pending_stable_out: 0,
        pending_swap_done: false,
    };

    event::emit(PoolOracleCreated {
        pool_id: object::id(&pool),
        market_id,
        outcome_idx,
        oracle_id,
    });

    event::emit(PoolCreated {
        pool_id: object::id(&pool),
        market_id,
        outcome_idx,
        asset_reserve: 0,
        stable_reserve: 0,
        price: initial_price,
        fee_bps: fee_percent,
        timestamp: sui::clock::timestamp_ms(clock),
    });

    pool
}

// === Core Swap Functions ===
// Note: These functions take generic references to allow inline arbitrage
// without creating circular dependencies between spot_amm and conditional_amm
//
// IMPORTANT: LIFECYCLE VALIDATION
// These swap functions do NOT enforce market lifecycle checks internally because
// the AMM module doesn't hold MarketState. CALLERS ARE RESPONSIBLE for ensuring:
// - Trading has started: market_state::assert_trading_active()
// - Market is not finalized: market_state::assert_not_finalized()
// Failure to validate lifecycle at the caller level can result in swaps during
// inappropriate market phases (pre-trading, post-finalization).

/// Swap asset tokens for stable tokens
///
/// CALLER RESPONSIBILITY: Validate market lifecycle before calling.
/// Use market_state::assert_trading_active() to ensure trading is active.
public fun swap_asset_to_stable(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(pool.market_id == market_id, EMarketIdMismatch);
    // SECURITY: Prevent regular swaps during inject→swap→extract cycle.
    // Injected reserves inflate the pool; a regular swap here would see inflated k.
    assert_no_pending_injection(pool);
    assert!(amount_in > 0, EZeroAmount);

    // K-GUARD: Capture reserves before swap to validate constant-product invariant
    // WHY: LP fees stay in pool, so k must GROW. Catches fee accounting bugs.
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // When selling outcome tokens (asset -> stable):
    // FEE MODEL: Two separate fees taken from input
    // 1. Protocol fee = fixed 0.5% of amount_in → goes to protocol treasury
    // 2. LP fee (configured per DAO) = pool.fee_percent of amount_in → stays with LPs (grows k)
    // 3. Total deducted = protocol_fee + lp_fee
    // 4. amount_in_after_fee used for swap calculation

    // Protocol fee: fixed 0.5% of swap amount (goes to protocol treasury)
    let protocol_fee = math::mul_div_to_64(
        amount_in,
        constants::protocol_fee_bps(),
        constants::total_fee_bps(),
    );

    // LP fee configured per DAO (stays with LPs, grows k)
    let lp_fee = calculate_fee(amount_in, pool.fee_percent);

    // Total fee taken from user
    let total_fee = protocol_fee + lp_fee;

    // Guard against underflow on small swaps
    assert!(amount_in > total_fee, EAmountTooSmall);

    // Amount used for the swap calculation (after removing both fees)
    let amount_in_after_fee = amount_in - total_fee;

    // Calculate output based on amount after fee
    let amount_out = calculate_output(
        amount_in_after_fee,
        pool.asset_reserve,
        pool.stable_reserve,
    );

    assert!(amount_out > 0, EAmountTooSmall);
    // Send protocol fee to the fee collector (asset token fee)
    pool.protocol_fees_asset = pool.protocol_fees_asset + protocol_fee;

    assert!(amount_out >= min_amount_out, EExcessiveSlippage);
    assert!(amount_out < pool.stable_reserve, EPoolEmpty);

    let price_impact = calculate_price_impact(
        amount_in_after_fee,
        pool.asset_reserve,
        amount_out,
        pool.stable_reserve,
    );

    // Capture previous reserve state before the update
    let old_asset = pool.asset_reserve;
    let old_stable = pool.stable_reserve;

    let timestamp = clock.timestamp_ms();
    let old_price = math::mul_div_to_128(old_stable, constants::price_precision_scale(), old_asset);
    // Oracle observation is recorded using the reserves *before* the swap.
    // This ensures that the TWAP accurately reflects the price at the beginning of the swap.
    write_observation(
        &mut pool.oracle,
        timestamp,
        old_price,
        clock,
    );

    // Update reserves. The amount added to the asset reserve is the portion used for the swap
    // PLUS the LP fee. The protocol fee was already removed.
    let new_asset_reserve = pool.asset_reserve + amount_in_after_fee + lp_fee;
    assert!(new_asset_reserve >= pool.asset_reserve, EOverflow);

    pool.asset_reserve = new_asset_reserve;
    pool.stable_reserve = pool.stable_reserve - amount_out;

    // K-GUARD: Validate k increased (LP fees stay in pool, so k must grow)
    // Formula: (asset + amount_in_after_fee + lp_fee) * (stable - amount_out) >= asset * stable
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    assert!(k_after >= k_before, EKInvariantViolation);

    let current_price = get_current_price(pool);
    check_price_under_max(current_price);

    event::emit(SwapEvent {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        is_buy: false,
        amount_in,
        amount_out, // Amount after fee for event logging
        price_impact,
        price: current_price,
        sender: ctx.sender(),
        asset_reserve: pool.asset_reserve,
        stable_reserve: pool.stable_reserve,
        timestamp,
    });

    amount_out
}

/// Swap stable tokens for asset tokens
///
/// CALLER RESPONSIBILITY: Validate market lifecycle before calling.
/// Use market_state::assert_trading_active() to ensure trading is active.
public fun swap_stable_to_asset(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(pool.market_id == market_id, EMarketIdMismatch);
    // SECURITY: Prevent regular swaps during inject→swap→extract cycle.
    // Injected reserves inflate the pool; a regular swap here would see inflated k.
    assert_no_pending_injection(pool);
    assert!(amount_in > 0, EZeroAmount);

    // K-GUARD: Capture reserves before swap to validate constant-product invariant
    // WHY: LP fees stay in pool, so k must GROW. Catches fee accounting bugs.
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // When buying outcome tokens (stable -> asset):
    // FEE MODEL: Two separate fees taken from input
    // 1. Protocol fee = fixed 0.5% of amount_in → goes to protocol treasury
    // 2. LP fee (configured per DAO) = pool.fee_percent of amount_in → stays with LPs (grows k)
    // 3. Total deducted = protocol_fee + lp_fee
    // 4. amount_in_after_fee used for swap calculation

    // Protocol fee: fixed 0.5% of swap amount (goes to protocol treasury)
    let protocol_fee = math::mul_div_to_64(
        amount_in,
        constants::protocol_fee_bps(),
        constants::total_fee_bps(),
    );

    // LP fee configured per DAO (stays with LPs, grows k)
    let lp_fee = calculate_fee(amount_in, pool.fee_percent);

    // Total fee taken from user
    let total_fee = protocol_fee + lp_fee;

    // Guard against underflow on small swaps
    assert!(amount_in > total_fee, EAmountTooSmall);

    // Amount used for the swap calculation (after removing both fees)
    let amount_in_after_fee = amount_in - total_fee;

    // Send protocol fee to the fee collector (stable token fee)
    pool.protocol_fees_stable = pool.protocol_fees_stable + protocol_fee;

    // Calculate output based on amount after fee
    let amount_out = calculate_output(
        amount_in_after_fee,
        pool.stable_reserve,
        pool.asset_reserve,
    );

    assert!(amount_out > 0, EAmountTooSmall);
    assert!(amount_out >= min_amount_out, EExcessiveSlippage);
    assert!(amount_out < pool.asset_reserve, EPoolEmpty);

    let price_impact = calculate_price_impact(
        amount_in_after_fee,
        pool.stable_reserve,
        amount_out,
        pool.asset_reserve,
    );

    // Capture previous reserve state before the update
    let old_asset = pool.asset_reserve;
    let old_stable = pool.stable_reserve;

    let timestamp = clock.timestamp_ms();
    let old_price = math::mul_div_to_128(old_stable, constants::price_precision_scale(), old_asset);
    // Oracle observation is recorded using the reserves *before* the swap.
    // This ensures that the TWAP accurately reflects the price at the beginning of the swap.
    write_observation(
        &mut pool.oracle,
        timestamp,
        old_price,
        clock,
    );

    // Update reserves. The amount added to the stable reserve is the portion used for the swap
    // PLUS the LP fee. The protocol fee was already removed.
    let new_stable_reserve = pool.stable_reserve + amount_in_after_fee + lp_fee;
    assert!(new_stable_reserve >= pool.stable_reserve, EOverflow);

    pool.stable_reserve = new_stable_reserve;
    pool.asset_reserve = pool.asset_reserve - amount_out;

    // K-GUARD: Validate k increased (LP fees stay in pool, so k must grow)
    // Formula: (asset - amount_out) * (stable + amount_in_after_fee + lp_fee) >= asset * stable
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    assert!(k_after >= k_before, EKInvariantViolation);

    let current_price = get_current_price(pool);
    check_price_under_max(current_price);

    event::emit(SwapEvent {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        is_buy: true,
        amount_in, // Original amount for event logging
        amount_out,
        price_impact,
        price: current_price,
        sender: ctx.sender(),
        asset_reserve: pool.asset_reserve,
        stable_reserve: pool.stable_reserve,
        timestamp,
    });

    amount_out
}

// === Liquidity Functions ===

/// Add liquidity proportionally to the AMM pool
/// Only handles calculations and reserve updates, no token operations
/// Returns the amount of LP tokens to mint
public fun add_liquidity_proportional(
    pool: &mut LiquidityPool,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert_no_pending_injection(pool);
    assert!(asset_amount > 0, EZeroAmount);
    assert!(stable_amount > 0, EZeroAmount);

    // Calculate LP tokens to mint based on current pool state
    let (lp_to_mint, new_lp_supply) = if (pool.lp_supply == 0) {
        // Truly empty pool (e.g., after empty_all_amm_liquidity + re-add).
        // new_pool always sets lp_supply > 0, so this branch only runs on
        // pools that were drained and are being re-bootstrapped.
        assert!(pool.asset_reserve == 0 && pool.stable_reserve == 0, EZeroLiquidity);
        let k_squared = math::mul_div_to_128(asset_amount, stable_amount, 1);
        let k = (k_squared.sqrt() as u64);
        assert!(k > constants::minimum_liquidity(), ELowLiquidity);
        // Lock minimum_liquidity LP tokens (standard Uniswap V2 practice)
        let locked = constants::minimum_liquidity();
        let minted = k - locked;
        (minted, k)
    } else {
        // Subsequent providers - mint proportionally
        let lp_from_asset = math::mul_div_to_64(asset_amount, pool.lp_supply, pool.asset_reserve);
        let lp_from_stable = math::mul_div_to_64(
            stable_amount,
            pool.lp_supply,
            pool.stable_reserve,
        );

        // SECURITY: Enforce exact-ratio liquidity so LP operations cannot move price.
        // Price movement must come from swaps, not from one-sided reserve donations.
        assert!(
            (asset_amount as u128) * (pool.stable_reserve as u128) ==
                (stable_amount as u128) * (pool.asset_reserve as u128),
            EImbalancedLiquidity,
        );

        // Use the conservative side after the ratio check passes.
        let minted = lp_from_asset.min(lp_from_stable);
        (minted, pool.lp_supply + minted)
    };

    // Slippage protection: ensure LP tokens minted meet minimum expectation
    assert!(lp_to_mint >= min_lp_out, EExcessiveSlippage);

    write_liquidity_observation(pool, clock);

    // K-GUARD: Capture k before adding liquidity
    // WHY: Adding liquidity MUST strictly increase k. If not, arithmetic bug or overflow.
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // Update reserves with overflow checks
    let new_asset_reserve = pool.asset_reserve + asset_amount;
    let new_stable_reserve = pool.stable_reserve + stable_amount;
    // Use the precomputed total supply

    // Check for overflow
    assert!(new_asset_reserve >= pool.asset_reserve, EOverflow);
    assert!(new_stable_reserve >= pool.stable_reserve, EOverflow);
    assert!(new_lp_supply >= pool.lp_supply, EOverflow);

    pool.asset_reserve = new_asset_reserve;
    pool.stable_reserve = new_stable_reserve;
    pool.lp_supply = new_lp_supply;

    // K-GUARD: Validate k strictly increased
    // Formula: (asset + asset_amount) * (stable + stable_amount) > asset * stable
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    assert!(k_after > k_before, EKInvariantViolation);

    event::emit(LiquidityAdded {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        asset_amount,
        stable_amount,
        lp_amount: lp_to_mint,
        sender: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    lp_to_mint
}

/// Remove liquidity proportionally from the AMM pool
/// Only handles calculations and reserve updates, no token operations
/// Returns the amounts of asset and stable tokens to mint
public fun remove_liquidity_proportional(
    pool: &mut LiquidityPool,
    lp_amount: u64,
    clock: &Clock,
    ctx: &TxContext,
): (u64, u64) {
    assert_no_pending_injection(pool);
    // Check for zero liquidity in the pool first to provide a more accurate error message
    assert!(pool.lp_supply > 0, EZeroLiquidity);
    assert!(lp_amount > 0, EZeroAmount);

    // K-GUARD: Capture k before removing liquidity
    // WHY: Removing liquidity MUST strictly decrease k (but stay ≥ minimum).
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // Calculate proportional share to remove from this AMM
    let asset_to_remove = math::mul_div_to_64(lp_amount, pool.asset_reserve, pool.lp_supply);
    let stable_to_remove = math::mul_div_to_64(lp_amount, pool.stable_reserve, pool.lp_supply);

    // DUST CHECK: If both amounts round to 0, fail early with clear error
    // This prevents confusing K-invariant errors when LP amount is too small
    assert!(asset_to_remove > 0 || stable_to_remove > 0, EAmountTooSmall);

    // Ensure minimum liquidity remains
    assert!(pool.asset_reserve > asset_to_remove, EPoolEmpty);
    assert!(pool.stable_reserve > stable_to_remove, EPoolEmpty);
    assert!(pool.lp_supply > lp_amount, EInsufficientLPTokens);

    // Ensure remaining liquidity is above minimum threshold
    // Compare K (product) against min_liq² to match the LP-unit invariant from pool creation:
    // new_pool asserts sqrt(K) > minimum_liquidity, so K must stay > minimum_liquidity².
    let remaining_asset = pool.asset_reserve - asset_to_remove;
    let remaining_stable = pool.stable_reserve - stable_to_remove;
    let remaining_k = math::mul_div_to_128(remaining_asset, remaining_stable, 1);
    let min_liq = (constants::minimum_liquidity() as u128);
    assert!(remaining_k >= min_liq * min_liq, ELowLiquidity);

    write_liquidity_observation(pool, clock);

    // Update pool state (underflow already checked by earlier asserts)
    pool.asset_reserve = pool.asset_reserve - asset_to_remove;
    pool.stable_reserve = pool.stable_reserve - stable_to_remove;
    pool.lp_supply = pool.lp_supply - lp_amount;

    // K-GUARD: Validate k strictly decreased but stays above minimum
    // Formula: (asset - asset_to_remove) * (stable - stable_to_remove) < asset * stable
    //          AND result >= minimum_liquidity²
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    assert!(k_after < k_before, EKInvariantViolation); // Must decrease
    assert!(k_after >= min_liq * min_liq, ELowLiquidity); // But stay above min²

    event::emit(LiquidityRemoved {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        asset_amount: asset_to_remove,
        stable_amount: stable_to_remove,
        lp_amount,
        sender: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    (asset_to_remove, stable_to_remove)
}

/// Empty all liquidity from AMM pool
///
/// RESTRICTED: Requires MarketStateMutationAuth.
/// Used during market finalization or emergency cleanup.
///
/// SECURITY: This function can drain pool reserves. Access control enforced via
/// MarketStateMutationAuth which requires the caller package to be registered
/// in MarketStateMutationRegistry.
public fun empty_all_amm_liquidity(
    pool: &mut LiquidityPool,
    _ctx: &mut TxContext,
    _auth: &MarketStateMutationAuth,
): (u64, u64) {
    assert_no_pending_injection(pool);
    // Capture full reserves before zeroing them out
    let asset_amount_out = pool.asset_reserve;
    let stable_amount_out = pool.stable_reserve;

    pool.asset_reserve = 0;
    pool.stable_reserve = 0;

    // Reset LP accounting so the next quantum split reboots cleanly
    pool.lp_supply = 0;

    (asset_amount_out, stable_amount_out)
}

// === Arbitrage Reserve Operations ===
// These functions directly modify reserves WITHOUT LP token accounting
// Used for auto-arbitrage quantum split/recombine that doesn't involve LP providers
//
// IMPORTANT: K-INVARIANT NOTE
// These functions intentionally bypass the constant-product invariant checks because they are
// designed for ATOMIC arbitrage flows where:
// 1. inject adds reserves from spot pool
// 2. swap_from_injected calculates output
// 3. extract removes the output
// The caller is responsible for ensuring the complete atomic flow maintains economic invariants.
// MarketStateMutationAuth ensures only registered internal packages can use these primitives.

/// Inject reserves into pool for arbitrage (quantum split effect)
/// Increases reserves without minting LP tokens
/// Used when arbitrage takes from spot and distributes to conditional pools
///
/// RESTRICTED: Requires MarketStateMutationAuth.
/// SECURITY: This function bypasses k-invariant validation. Access control enforced via
/// MarketStateMutationAuth which requires the caller package to be registered
/// in MarketStateMutationRegistry.
///
/// CALLER MUST validate swaps are allowed via market_state::assert_swaps_allowed()
/// before calling this function.
public fun inject_reserves_for_arbitrage(
    pool: &mut LiquidityPool,
    market_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    _auth: &MarketStateMutationAuth,
) {
    // Validate market ID matches pool to prevent cross-market attacks
    assert!(pool.market_id == market_id, EMarketMismatch);
    // Replay guard: prevent inject→swap→extract from being looped in a single PTB
    assert_no_pending_injection(pool);
    assert_exactly_one_injected_side(asset_amount, stable_amount);
    assert_reserve_add_safe(pool, asset_amount, stable_amount);
    pool.pending_injected_asset = asset_amount;
    pool.pending_injected_stable = stable_amount;

    pool.asset_reserve = pool.asset_reserve + asset_amount;
    pool.stable_reserve = pool.stable_reserve + stable_amount;
}

/// Extract reserves from pool for arbitrage (quantum recombine effect)
/// Decreases reserves without burning LP tokens
/// Used when arbitrage takes from conditional pools and returns to spot
///
/// RESTRICTED: Requires MarketStateMutationAuth.
/// SECURITY: This function bypasses k-invariant validation. Access control enforced via
/// MarketStateMutationAuth which requires the caller package to be registered
/// in MarketStateMutationRegistry.
///
/// CALLER MUST validate swaps are allowed via market_state::assert_swaps_allowed()
/// before calling this function.
public fun extract_reserves_for_arbitrage(
    pool: &mut LiquidityPool,
    market_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    _auth: &MarketStateMutationAuth,
) {
    // Validate market ID matches pool to prevent cross-market attacks
    assert!(pool.market_id == market_id, EMarketMismatch);
    // Enforce inject→swap→extract sequence: extract requires prior inject
    assert!(has_pending_injection(pool), ENoInjectionPending);
    assert!(pool.pending_swap_done, EInjectedSwapNotDone);
    assert!(asset_amount == pool.pending_asset_out, EInjectionMismatch);
    assert!(stable_amount == pool.pending_stable_out, EInjectionMismatch);

    assert!(pool.asset_reserve >= asset_amount, ELowLiquidity);
    assert!(pool.stable_reserve >= stable_amount, ELowLiquidity);
    pool.asset_reserve = pool.asset_reserve - asset_amount;
    pool.stable_reserve = pool.stable_reserve - stable_amount;
    // Clear replay guard — allows next inject→swap→extract cycle
    clear_pending_injection(pool);
}

/// Swap from already-injected stable reserves to asset (quantum operation)
///
/// Unlike regular swap, this function does NOT add to input reserves because
/// the stable was already injected via `inject_reserves_for_arbitrage`.
/// Only removes from asset reserves.
///
/// Used in quantum arbitrage flow:
/// 1. inject_reserves_for_arbitrage(pool, 0, stable_amount) - stable enters
/// 2. swap_from_injected_stable_to_asset(pool, stable_amount, max_asset_out) - swap using injected stable
/// 3. extract_reserves_for_arbitrage(pool, asset_out, 0) - asset exits
///
/// Feeless to maximize arbitrage efficiency (system rebalancing operation).
///
/// RESTRICTED: Requires MarketStateMutationAuth.
/// SECURITY: Requires market_id to validate pool belongs to expected market.
/// Bypasses k-invariant and fee collection. Access control enforced via
/// MarketStateMutationAuth which requires the caller package to be registered
/// in MarketStateMutationRegistry.
///
/// CALLER MUST validate swaps are allowed via market_state::assert_swaps_allowed()
/// before calling this function.
public fun swap_from_injected_stable_to_asset(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    max_asset_out: u64,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
): u64 {
    // Validate market ID matches pool to prevent cross-market attacks
    assert!(pool.market_id == market_id, EMarketMismatch);
    // Enforce inject→swap→extract sequence: swap requires prior inject
    assert!(has_pending_injection(pool), ENoInjectionPending);
    assert!(!pool.pending_swap_done, EInjectedSwapAlreadyDone);
    assert!(pool.pending_injected_asset == 0, EInjectionMismatch);
    assert!(pool.pending_injected_stable == amount_in, EInjectionMismatch);
    assert!(amount_in > 0, EZeroAmount);
    assert!(max_asset_out > 0, EZeroAmount);
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EPoolEmpty);
    // Validate that stable_reserve is at least amount_in (injection must have occurred)
    assert!(pool.stable_reserve >= amount_in, EInjectionMismatch);

    // Calculate original reserves (before injection) for oracle and swap calculation
    let original_stable = pool.stable_reserve - amount_in;
    // SECURITY: Prevent divide-by-zero and zero-price recording
    assert!(original_stable > 0, EPoolEmpty);

    // Record oracle observation using pre-injection reserves
    // This ensures TWAP captures the price change from arbitrage
    let timestamp = clock.timestamp_ms();
    let old_price = math::mul_div_to_128(original_stable, constants::price_precision_scale(), pool.asset_reserve);
    write_observation(&mut pool.oracle, timestamp, old_price, clock);

    // Input already in reserves from inject, so we need to use ORIGINAL reserves for calculation
    // Since inject already added amount_in to stable_reserve, we subtract it back for the formula
    // calculate_output will add it back: denominator = (stable - amount_in) + amount_in = stable
    let raw_asset_out = calculate_output(
        amount_in,
        original_stable, // Use original reserve before inject
        pool.asset_reserve,
    );
    let asset_out = if (raw_asset_out < max_asset_out) { raw_asset_out } else { max_asset_out };
    assert!(asset_out > 0, EZeroAmount);
    assert!(asset_out < pool.asset_reserve, EPoolEmpty);
    pool.pending_asset_out = asset_out;
    pool.pending_stable_out = 0;
    pool.pending_swap_done = true;

    // DO NOT update reserves here - extract_reserves_for_arbitrage will handle that
    // This function only calculates the output amount
    // The inject/extract pattern manages reserves: inject adds input, extract removes output

    // Emit swap event so indexer/frontend can track conditional market volume from arbitrage.
    // Post-swap reserves: stable already injected, asset will be extracted.
    let final_asset_reserve = pool.asset_reserve - asset_out;
    let final_stable_reserve = pool.stable_reserve; // stable already injected
    let price_impact = calculate_price_impact(amount_in, original_stable, asset_out, pool.asset_reserve);
    let price = math::mul_div_to_128(final_stable_reserve, constants::price_precision_scale(), final_asset_reserve);
    event::emit(SwapEvent {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        is_buy: true,
        amount_in,
        amount_out: asset_out,
        price_impact,
        price,
        sender: @0x0, // system arbitrage, not a user swap
        asset_reserve: final_asset_reserve,
        stable_reserve: final_stable_reserve,
        timestamp,
    });

    asset_out
}

/// Swap from already-injected asset reserves to stable (quantum operation)
///
/// Unlike regular swap, this function does NOT add to input reserves because
/// the asset was already injected via `inject_reserves_for_arbitrage`.
/// Only removes from stable reserves.
///
/// Used in quantum arbitrage flow:
/// 1. inject_reserves_for_arbitrage(pool, asset_amount, 0) - asset enters
/// 2. swap_from_injected_asset_to_stable(pool, asset_amount, max_stable_out) - swap using injected asset
/// 3. extract_reserves_for_arbitrage(pool, 0, stable_out) - stable exits
///
/// Feeless to maximize arbitrage efficiency (system rebalancing operation).
///
/// RESTRICTED: Requires MarketStateMutationAuth.
/// SECURITY: Requires market_id to validate pool belongs to expected market.
/// Bypasses k-invariant and fee collection. Access control enforced via
/// MarketStateMutationAuth which requires the caller package to be registered
/// in MarketStateMutationRegistry.
///
/// CALLER MUST validate swaps are allowed via market_state::assert_swaps_allowed()
/// before calling this function.
public fun swap_from_injected_asset_to_stable(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    max_stable_out: u64,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
): u64 {
    // Validate market ID matches pool to prevent cross-market attacks
    assert!(pool.market_id == market_id, EMarketMismatch);
    // Enforce inject→swap→extract sequence: swap requires prior inject
    assert!(has_pending_injection(pool), ENoInjectionPending);
    assert!(!pool.pending_swap_done, EInjectedSwapAlreadyDone);
    assert!(pool.pending_injected_asset == amount_in, EInjectionMismatch);
    assert!(pool.pending_injected_stable == 0, EInjectionMismatch);
    assert!(amount_in > 0, EZeroAmount);
    assert!(max_stable_out > 0, EZeroAmount);
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EPoolEmpty);
    // Validate that asset_reserve is at least amount_in (injection must have occurred)
    assert!(pool.asset_reserve >= amount_in, EInjectionMismatch);

    // Calculate original reserves (before injection) for oracle and swap calculation
    let original_asset = pool.asset_reserve - amount_in;
    // SECURITY: Prevent divide-by-zero in price calculation
    assert!(original_asset > 0, EPoolEmpty);

    // Record oracle observation using pre-injection reserves
    // This ensures TWAP captures the price change from arbitrage
    let timestamp = clock.timestamp_ms();
    let old_price = math::mul_div_to_128(pool.stable_reserve, constants::price_precision_scale(), original_asset);
    write_observation(&mut pool.oracle, timestamp, old_price, clock);

    // Input already in reserves from inject, so we need to use ORIGINAL reserves for calculation
    // Since inject already added amount_in to asset_reserve, we subtract it back for the formula
    // calculate_output will add it back: denominator = (asset - amount_in) + amount_in = asset
    let raw_stable_out = calculate_output(
        amount_in,
        original_asset, // Use original reserve before inject
        pool.stable_reserve,
    );
    let stable_out = if (raw_stable_out < max_stable_out) { raw_stable_out } else { max_stable_out };
    assert!(stable_out > 0, EZeroAmount);
    assert!(stable_out < pool.stable_reserve, EPoolEmpty);
    pool.pending_asset_out = 0;
    pool.pending_stable_out = stable_out;
    pool.pending_swap_done = true;

    // DO NOT update reserves here - extract_reserves_for_arbitrage will handle that
    // This function only calculates the output amount
    // The inject/extract pattern manages reserves: inject adds input, extract removes output

    // Emit swap event so indexer/frontend can track conditional market volume from arbitrage.
    // Post-swap reserves: asset already injected, stable will be extracted.
    let final_asset_reserve = pool.asset_reserve; // asset already injected
    let final_stable_reserve = pool.stable_reserve - stable_out;
    let price_impact = calculate_price_impact(amount_in, original_asset, stable_out, pool.stable_reserve);
    let price = math::mul_div_to_128(final_stable_reserve, constants::price_precision_scale(), final_asset_reserve);
    event::emit(SwapEvent {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        is_buy: false,
        amount_in,
        amount_out: stable_out,
        price_impact,
        price,
        sender: @0x0, // system arbitrage, not a user swap
        asset_reserve: final_asset_reserve,
        stable_reserve: final_stable_reserve,
        timestamp,
    });

    stable_out
}

// === Oracle Functions ===
fun write_observation(oracle: &mut Oracle, timestamp: u64, price: u128, clock: &Clock) {
    oracle.write_observation(timestamp, price, clock)
}

public fun get_oracle(pool: &LiquidityPool): &Oracle {
    &pool.oracle
}

/// Get full oracle state from a pool (read-only, for debugging/monitoring)
public fun get_oracle_full_state(pool: &LiquidityPool): (
    u128, // last_price
    u64, // last_timestamp
    u256, // total_cumulative_price
    u256, // last_window_end_cumulative_price
    u64, // last_window_end
    u128, // last_window_twap
    Option<u64>, // market_start_time
    u128, // twap_initialization_price
    u64, // twap_start_delay
    u64, // twap_cap_step
) {
    futarchy_twap_oracle::get_full_state(&pool.oracle)
}

// === View Functions ===

public fun get_reserves(pool: &LiquidityPool): (u64, u64) {
    (pool.asset_reserve, pool.stable_reserve)
}

public fun get_lp_supply(pool: &LiquidityPool): u64 {
    pool.lp_supply
}

/// Get pool fee in basis points
public fun get_fee_bps(pool: &LiquidityPool): u64 {
    pool.fee_percent
}

public fun get_price(pool: &LiquidityPool): u128 {
    pool.oracle.last_price()
}

/// RESTRICTED: Requires MarketStateMutationAuth.
/// SECURITY: Writes an oracle observation at clock.timestamp_ms().
/// Callers MUST ensure clock <= trading_end to prevent bricking finalization.
public fun get_twap(pool: &mut LiquidityPool, clock: &Clock, _auth: &MarketStateMutationAuth): u128 {
    update_twap_observation(pool, clock);
    pool.oracle.get_twap(clock)
}

/// Get TWAP frozen at a specific target time.
/// If oracle time has not reached target_time, writes a final observation there.
/// If oracle time already passed target_time, the TWAP is already frozen —
/// the caller must have frozen it at the deadline before any post-deadline swaps.
/// Used to freeze TWAP at the scheduled trading deadline for governance outcomes.
///
/// SECURITY: Aborts if oracle has advanced past target_time, because
/// total_cumulative_price would include post-deadline contributions,
/// making it impossible to compute the correct historical TWAP.
/// Callers must freeze the TWAP at the deadline before post-deadline swaps occur.
///
/// SECURITY: Requires &Clock to prevent future-timestamp attacks. Without this,
/// an attacker could pass u64::MAX as target_time, bricking the oracle permanently
/// (all future write_observation calls would fail with ETimestampRegression).
/// RESTRICTED: Requires MarketStateMutationAuth.
/// SECURITY: May write an oracle observation at target_time, freezing the TWAP.
/// Callers MUST ensure target_time == trading_end.
public fun get_twap_at(pool: &mut LiquidityPool, target_time: u64, clock: &Clock, _auth: &MarketStateMutationAuth): u128 {
    let last_timestamp = pool.oracle.last_timestamp();
    if (target_time > last_timestamp) {
        // Oracle hasn't reached target_time yet — write final observation and freeze
        let current_price = get_current_price(pool);
        pool.oracle.write_observation(target_time, current_price, clock);
        pool.oracle.get_twap_at(target_time)
    } else {
        // Oracle is exactly at target_time — TWAP was already frozen at the deadline.
        // Abort if oracle advanced past target_time: cumulative price includes
        // post-deadline data, so historical TWAP cannot be computed correctly.
        assert!(last_timestamp == target_time, EOracleAdvancedPastDeadline);
        pool.oracle.get_twap_at(target_time)
    }
}

public fun quote_swap_asset_to_stable(pool: &LiquidityPool, amount_in: u64): u64 {
    // Protocol fee: fixed 0.5% of swap amount (matches actual swap)
    let protocol_fee = math::mul_div_to_64(
        amount_in,
        constants::protocol_fee_bps(),
        constants::total_fee_bps(),
    );
    // LP fee configured per DAO
    let lp_fee = calculate_fee(amount_in, pool.fee_percent);
    let total_fee = protocol_fee + lp_fee;
    let amount_in_after_fee = if (amount_in > total_fee) {
        amount_in - total_fee
    } else {
        return 0
    };
    // Calculate output from after-fee amount
    calculate_output(
        amount_in_after_fee,
        pool.asset_reserve,
        pool.stable_reserve,
    )
}

public fun quote_swap_stable_to_asset(pool: &LiquidityPool, amount_in: u64): u64 {
    // Protocol fee: fixed 0.5% of swap amount (matches actual swap)
    let protocol_fee = math::mul_div_to_64(
        amount_in,
        constants::protocol_fee_bps(),
        constants::total_fee_bps(),
    );
    // LP fee configured per DAO
    let lp_fee = calculate_fee(amount_in, pool.fee_percent);
    let total_fee = protocol_fee + lp_fee;
    let amount_in_after_fee = if (amount_in > total_fee) {
        amount_in - total_fee
    } else {
        return 0
    };
    calculate_output(
        amount_in_after_fee,
        pool.stable_reserve,
        pool.asset_reserve,
    )
}

// === Arbitrage Helper Functions ===
//
// All arbitrage routes are FEELESS by design for internal system rebalancing.
// This maximizes arbitrage efficiency and ensures fair price discovery.
// External user swaps still pay both protocol and LP fees.

/// Feeless swap asset→stable (for internal arbitrage only)
/// No fees charged to maximize arbitrage efficiency
///
/// RESTRICTED: Requires MarketStateMutationAuth.
/// SECURITY: Requires market_id to validate pool belongs to expected market.
/// Access control enforced via MarketStateMutationAuth.
/// CALLER MUST validate swaps are allowed via market_state::assert_swaps_allowed()
/// before calling this function.
/// K-invariant is still checked (fees=0 means k stays constant, not decreases)
/// AUDIT FIX: Now MUTATES reserves (Q3: swaps should always update state)
/// AUDIT FIX: Now updates oracle to keep conditional TWAP fresh after arbitrage
public fun feeless_swap_asset_to_stable(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
): u64 {
    // Validate market ID matches pool to prevent cross-market attacks
    assert!(pool.market_id == market_id, EMarketMismatch);
    assert_no_pending_injection(pool);

    // Record oracle observation before swap to keep conditional TWAP fresh.
    // Without this, arbitrage rebalances silently change reserves and the oracle
    // retroactively applies the stale pre-swap price to the entire gap period.
    let timestamp = clock.timestamp_ms();
    let old_price = get_current_price(pool);
    write_observation(&mut pool.oracle, timestamp, old_price, clock);

    swap_asset_to_stable_internal(pool, amount_in, false /* apply_fees */)
}

/// Feeless swap stable→asset (for internal arbitrage only)
///
/// RESTRICTED: Requires MarketStateMutationAuth.
/// SECURITY: Requires market_id to validate pool belongs to expected market.
/// Access control enforced via MarketStateMutationAuth.
/// CALLER MUST validate swaps are allowed via market_state::assert_swaps_allowed()
/// before calling this function.
/// AUDIT FIX: Now MUTATES reserves (Q3: swaps should always update state)
/// AUDIT FIX: Now updates oracle to keep conditional TWAP fresh after arbitrage
public fun feeless_swap_stable_to_asset(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
): u64 {
    // Validate market ID matches pool to prevent cross-market attacks
    assert!(pool.market_id == market_id, EMarketMismatch);
    assert_no_pending_injection(pool);

    // Record oracle observation before swap to keep conditional TWAP fresh
    let timestamp = clock.timestamp_ms();
    let old_price = get_current_price(pool);
    write_observation(&mut pool.oracle, timestamp, old_price, clock);

    swap_stable_to_asset_internal(pool, amount_in, false /* apply_fees */)
}

/// Internal swap function with optional fee application
/// When apply_fees=true: Charges protocol fee (0.5%) + LP fee (configurable)
/// When apply_fees=false: Feeless swap for arbitrage (k preserved)
fun swap_asset_to_stable_internal(pool: &mut LiquidityPool, amount_in: u64, apply_fees: bool): u64 {
    assert!(amount_in > 0, EZeroAmount);
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EPoolEmpty);

    // K-GUARD: Capture reserves before swap
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    let (amount_in_after_fee, protocol_fee, lp_fee) = if (apply_fees) {
        // Protocol fee: fixed 0.5% of swap amount (goes to protocol treasury)
        let protocol_fee = math::mul_div_to_64(
            amount_in,
            constants::protocol_fee_bps(),
            constants::total_fee_bps(),
        );
        // LP fee configured per DAO (stays with LPs, grows k)
        let lp_fee = calculate_fee(amount_in, pool.fee_percent);
        let total_fee = protocol_fee + lp_fee;
        assert!(amount_in > total_fee, EAmountTooSmall);
        (amount_in - total_fee, protocol_fee, lp_fee)
    } else {
        // Feeless for arbitrage
        (amount_in, 0, 0)
    };

    // Calculate output based on amount after fee
    let stable_out = calculate_output(
        amount_in_after_fee,
        pool.asset_reserve,
        pool.stable_reserve,
    );
    assert!(stable_out > 0, EAmountTooSmall);
    assert!(stable_out < pool.stable_reserve, EPoolEmpty);

    // Track protocol fees if applicable
    if (protocol_fee > 0) {
        pool.protocol_fees_asset = pool.protocol_fees_asset + protocol_fee;
    };

    // Update reserves
    // With fees: input is amount_after_fee + lp_fee (protocol fee was removed)
    // Without fees: input is full amount_in
    let asset_to_add = if (apply_fees) { amount_in_after_fee + lp_fee } else { amount_in };
    pool.asset_reserve = pool.asset_reserve + asset_to_add;
    pool.stable_reserve = pool.stable_reserve - stable_out;

    // K-GUARD validation
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    // Both fee and feeless swaps: k must not decrease.
    // With fees: LP fees stay in pool, so k grows.
    // Feeless: floor division on output rounds down, so k >= k_before always holds.
    assert!(k_after >= k_before, EKInvariantViolation);

    stable_out
}

/// Internal swap function with optional fee application
/// When apply_fees=true: Charges protocol fee (0.5%) + LP fee (configurable)
/// When apply_fees=false: Feeless swap for arbitrage (k preserved)
fun swap_stable_to_asset_internal(pool: &mut LiquidityPool, amount_in: u64, apply_fees: bool): u64 {
    assert!(amount_in > 0, EZeroAmount);
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EPoolEmpty);

    // K-GUARD: Capture reserves before swap
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    let (amount_in_after_fee, protocol_fee, lp_fee) = if (apply_fees) {
        // Protocol fee: fixed 0.5% of swap amount (goes to protocol treasury)
        let protocol_fee = math::mul_div_to_64(
            amount_in,
            constants::protocol_fee_bps(),
            constants::total_fee_bps(),
        );
        // LP fee configured per DAO (stays with LPs, grows k)
        let lp_fee = calculate_fee(amount_in, pool.fee_percent);
        let total_fee = protocol_fee + lp_fee;
        assert!(amount_in > total_fee, EAmountTooSmall);
        (amount_in - total_fee, protocol_fee, lp_fee)
    } else {
        // Feeless for arbitrage
        (amount_in, 0, 0)
    };

    // Calculate output based on amount after fee
    let asset_out = calculate_output(
        amount_in_after_fee,
        pool.stable_reserve,
        pool.asset_reserve,
    );
    assert!(asset_out > 0, EAmountTooSmall);
    assert!(asset_out < pool.asset_reserve, EPoolEmpty);

    // Track protocol fees if applicable
    if (protocol_fee > 0) {
        pool.protocol_fees_stable = pool.protocol_fees_stable + protocol_fee;
    };

    // Update reserves
    // With fees: input is amount_after_fee + lp_fee (protocol fee was removed)
    // Without fees: input is full amount_in
    let stable_to_add = if (apply_fees) { amount_in_after_fee + lp_fee } else { amount_in };
    pool.stable_reserve = pool.stable_reserve + stable_to_add;
    pool.asset_reserve = pool.asset_reserve - asset_out;

    // K-GUARD validation
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    // Both fee and feeless swaps: k must not decrease.
    // With fees: LP fees stay in pool, so k grows.
    // Feeless: floor division on output rounds down, so k >= k_before always holds.
    assert!(k_after >= k_before, EKInvariantViolation);

    asset_out
}

/// Simulate asset→stable swap without executing
/// Pure function for arbitrage optimization
///
/// STANDARD UNISWAP V2 FEE MODEL: Fee charged on INPUT (consistent with swap execution)
/// Includes both protocol fee (0.5%) and LP fee to match actual swap behavior.
public fun simulate_swap_asset_to_stable(pool: &LiquidityPool, amount_in: u64): u64 {
    if (amount_in == 0) return 0;
    if (pool.asset_reserve == 0 || pool.stable_reserve == 0) return 0;

    // Protocol fee: fixed 0.5% of swap amount (matches actual swap)
    let protocol_fee = math::mul_div_to_64(
        amount_in,
        constants::protocol_fee_bps(),
        constants::total_fee_bps(),
    );
    // LP fee configured per DAO
    let lp_fee = calculate_fee(amount_in, pool.fee_percent);
    let total_fee = protocol_fee + lp_fee;
    let amount_in_after_fee = if (amount_in > total_fee) {
        amount_in - total_fee
    } else {
        return 0
    };

    let stable_out = calculate_output(
        amount_in_after_fee,
        pool.asset_reserve,
        pool.stable_reserve,
    );

    if (stable_out >= pool.stable_reserve) return 0;

    stable_out
}

/// Simulate stable→asset swap without executing
/// Includes both protocol fee (0.5%) and LP fee to match actual swap behavior.
public fun simulate_swap_stable_to_asset(pool: &LiquidityPool, amount_in: u64): u64 {
    if (amount_in == 0) return 0;
    if (pool.asset_reserve == 0 || pool.stable_reserve == 0) return 0;

    // Protocol fee: fixed 0.5% of swap amount (matches actual swap)
    let protocol_fee = math::mul_div_to_64(
        amount_in,
        constants::protocol_fee_bps(),
        constants::total_fee_bps(),
    );
    // LP fee configured per DAO
    let lp_fee = calculate_fee(amount_in, pool.fee_percent);
    let total_fee = protocol_fee + lp_fee;
    let amount_in_after_fee = if (amount_in > total_fee) {
        amount_in - total_fee
    } else {
        return 0
    };

    let asset_out = calculate_output(
        amount_in_after_fee,
        pool.stable_reserve,
        pool.asset_reserve,
    );

    if (asset_out >= pool.asset_reserve) return 0;

    asset_out
}

/// Feeless simulation: asset → stable swap using pure constant product
/// Used for arbitrage calculations where no fees apply
public fun simulate_swap_asset_to_stable_feeless(pool: &LiquidityPool, amount_in: u64): u64 {
    if (amount_in == 0) return 0;
    if (pool.asset_reserve == 0 || pool.stable_reserve == 0) return 0;

    // No fee deduction - pure constant product
    let stable_out = calculate_output(
        amount_in,
        pool.asset_reserve,
        pool.stable_reserve,
    );

    if (stable_out >= pool.stable_reserve) return 0;

    stable_out
}

/// Feeless simulation: stable → asset swap using pure constant product
/// Used for arbitrage calculations where no fees apply
public fun simulate_swap_stable_to_asset_feeless(pool: &LiquidityPool, amount_in: u64): u64 {
    if (amount_in == 0) return 0;
    if (pool.asset_reserve == 0 || pool.stable_reserve == 0) return 0;

    // No fee deduction - pure constant product
    let asset_out = calculate_output(
        amount_in,
        pool.stable_reserve,
        pool.asset_reserve,
    );

    if (asset_out >= pool.asset_reserve) return 0;

    asset_out
}

fun calculate_price_impact(
    amount_in: u64,
    reserve_in: u64,
    amount_out: u64,
    reserve_out: u64,
): u128 {
    // Use u256 for intermediate calculations to prevent overflow
    let amount_in_256 = (amount_in as u256);
    let reserve_out_256 = (reserve_out as u256);
    let reserve_in_256 = (reserve_in as u256);

    // Calculate ideal output with u256 to prevent overflow
    let ideal_out_256 = (amount_in_256 * reserve_out_256) / reserve_in_256;
    // Tiny trades in skewed pools can round ideal_out to 0 — treat as max impact
    if (ideal_out_256 == 0) return (constants::total_fee_bps() as u128);
    assert!(ideal_out_256 <= (std::u128::max_value!() as u256), EOverflow);
    let ideal_out = (ideal_out_256 as u128);

    // The assert below ensures that `ideal_out` is always greater than or equal to `amount_out`.
    // This prevents underflow when calculating `ideal_out - (amount_out as u128)`.
    assert!(ideal_out >= (amount_out as u128), EOverflow); // Ensure no underflow
    math::mul_div_mixed(ideal_out - (amount_out as u128), constants::total_fee_bps(), ideal_out)
}

// Update the LiquidityPool struct price calculation to use TWAP:
public fun get_current_price(pool: &LiquidityPool): u128 {
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EZeroLiquidity);

    let price = math::mul_div_to_128(
        pool.stable_reserve,
        constants::price_precision_scale(),
        pool.asset_reserve,
    );

    price
}

/// Update oracle observation with current price.
/// RESTRICTED: Private to prevent external callers from advancing the oracle
/// past the trading deadline, which would contaminate the TWAP used for
/// proposal resolution. Only called internally by get_twap().
fun update_twap_observation(pool: &mut LiquidityPool, clock: &Clock) {
    let timestamp = clock.timestamp_ms();
    let current_price = get_current_price(pool);
    pool.oracle.write_observation(timestamp, current_price, clock);
}

/// Checkpoint the oracle before liquidity changes reserves.
///
/// This prevents a later swap/read from backdating the post-liquidity price over
/// the idle interval since the previous oracle write.
fun write_liquidity_observation(pool: &mut LiquidityPool, clock: &Clock) {
    let market_start = pool.oracle.market_start_time();
    if (market_start.is_some()) {
        let timestamp = clock.timestamp_ms();
        let old_price = if (pool.asset_reserve > 0 && pool.stable_reserve > 0) {
            math::mul_div_to_128(pool.stable_reserve, constants::price_precision_scale(), pool.asset_reserve)
        } else {
            pool.oracle.last_price()
        };
        write_observation(&mut pool.oracle, timestamp, old_price, clock);
    };
}

/// Set the oracle start time (when trading begins).
/// RESTRICTED: Requires MarketStateMutationAuth.
/// SECURITY: Requires &Clock to prevent future-start attacks that would set
/// oracle.last_timestamp ahead of real time and brick subsequent observations.
public fun set_oracle_start_time(
    pool: &mut LiquidityPool,
    market_id: ID,
    trading_start_time: u64,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
) {
    assert!(get_ms_id(pool) == market_id, EMarketIdMismatch);
    assert!(trading_start_time <= clock.timestamp_ms(), EOracleStartTimeInFuture);
    pool.oracle.set_oracle_start_time(trading_start_time);
}

// === Private Functions ===
fun calculate_fee(amount: u64, fee_percent: u64): u64 {
    math::mul_div_to_64(amount, fee_percent, constants::total_fee_bps())
}

public fun calculate_output(amount_in_with_fee: u64, reserve_in: u64, reserve_out: u64): u64 {
    assert!(reserve_in > 0 && reserve_out > 0, EPoolEmpty);

    let denominator = (reserve_in as u256) + (amount_in_with_fee as u256);
    assert!(denominator > 0, EDivByZero);
    let numerator = (amount_in_with_fee as u256) * (reserve_out as u256);
    let output = numerator / denominator;
    assert!(output <= (u64::max_value!() as u256), EOverflow);
    (output as u64)
}

public fun get_outcome_idx(pool: &LiquidityPool): u8 {
    pool.outcome_idx
}

public fun get_id(pool: &LiquidityPool): ID {
    pool.id.to_inner()
}

public fun get_k(pool: &LiquidityPool): u128 {
    math::mul_div_to_128(pool.asset_reserve, pool.stable_reserve, 1)
}

public fun check_price_under_max(price: u128) {
    let max_price = (0xFFFFFFFFFFFFFFFFu64 as u128) * (constants::price_precision_scale() as u128);
    assert!(price <= max_price, EPriceTooHigh)
}

/// Get accumulated protocol fees in asset token
public fun get_protocol_fees_asset(pool: &LiquidityPool): u64 {
    pool.protocol_fees_asset
}

/// Get accumulated protocol fees in stable token
public fun get_protocol_fees_stable(pool: &LiquidityPool): u64 {
    pool.protocol_fees_stable
}

/// DEPRECATED: Use get_protocol_fees_stable() instead
/// Returns stable fees for backward compatibility
public fun get_protocol_fees(pool: &LiquidityPool): u64 {
    pool.protocol_fees_stable
}

public fun get_ms_id(pool: &LiquidityPool): ID {
    pool.market_id
}

/// Collect accumulated protocol fees (returns amounts AND resets counters)
///
/// RESTRICTED: Requires MarketStateMutationAuth.
/// This is the ONLY way to reset fees - ensures fees are collected atomically.
///
/// SECURITY: Resets fee counters, but fees are just accounting - the actual
/// token balances are tracked separately. Access control enforced via
/// MarketStateMutationAuth which requires the caller package to be registered
/// in MarketStateMutationRegistry.
///
/// Returns: (asset_fees, stable_fees) - the collected amounts
public fun collect_protocol_fees(
    pool: &mut LiquidityPool,
    _auth: &MarketStateMutationAuth,
): (u64, u64) {
    let asset_fees = pool.protocol_fees_asset;
    let stable_fees = pool.protocol_fees_stable;

    // Atomically reset after capturing values
    pool.protocol_fees_asset = 0;
    pool.protocol_fees_stable = 0;

    (asset_fees, stable_fees)
}

// === Test Functions ===

#[test_only]
/// Test helper: wrapper for new_pool() with simplified signature
public fun new<AssetType, StableType>(
    fee_percent: u64,
    twap_start_delay: u64,
    twap_initial_observation: Option<u128>,
    twap_cap_ppm: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidityPool {
    let auth = futarchy_core::market_state_mutation_auth::create_for_testing();
    new_pool(
        object::id_from_address(@0x0), // market_id
        0, // outcome_idx
        fee_percent,
        1_000, // initial_asset
        1_000, // initial_stable
        twap_initial_observation,
        twap_start_delay,
        twap_cap_ppm,
        &auth,
        clock,
        ctx,
    )
}

#[test_only]
/// Test helper: destroy a coin
public fun burn_for_testing<T>(coin: sui::coin::Coin<T>) {
    sui::test_utils::destroy(coin);
}

#[test_only]
/// Test helper: alias for get_lp_supply()
public fun lp_supply(pool: &LiquidityPool): u64 {
    get_lp_supply(pool)
}

#[test_only]
public fun create_test_pool(
    market_id: ID,
    outcome_idx: u8,
    fee_percent: u64,
    asset_reserve: u64,
    stable_reserve: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidityPool {
    let initial_price = math::mul_div_to_128(stable_reserve, 1_000_000_000_000, asset_reserve);

    let mut oracle_obj = futarchy_twap_oracle::new_oracle(
        initial_price,
        0, // Use 0 which is always a valid multiple of TWAP_PRICE_CAP_WINDOW
        1_000,
        ctx,
    );

    // Initialize oracle market start time for tests
    oracle_obj.set_oracle_start_time(clock.timestamp_ms());

    LiquidityPool {
        id: object::new(ctx),
        market_id,
        outcome_idx,
        asset_reserve,
        stable_reserve,
        fee_percent,
        oracle: oracle_obj,
        protocol_fees_asset: 0,
        protocol_fees_stable: 0,
        lp_supply: constants::minimum_liquidity(),
        pending_injected_asset: 0,
        pending_injected_stable: 0,
        pending_asset_out: 0,
        pending_stable_out: 0,
        pending_swap_done: false,
    }
}

#[test_only]
/// Create a pool with initial liquidity for testing arbitrage_math
public fun create_pool_for_testing(
    asset_amount: u64,
    stable_amount: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): LiquidityPool {
    use sui::clock;

    // Create a minimal oracle and simple_twap for testing
    let clock = clock::create_for_testing(ctx);
    let initial_price = if (asset_amount > 0 && stable_amount > 0) {
        ((stable_amount as u128) * (constants::price_precision_scale() as u128)) / (asset_amount as u128)
    } else {
        (constants::price_precision_scale() as u128)
    };

    let oracle_obj = futarchy_twap_oracle::new_oracle(
        initial_price,
        0, // twap_start_delay - Use 0 which is always a valid multiple of TWAP_PRICE_CAP_WINDOW
        100, // twap_cap_ppm
        ctx,
    );

    clock::destroy_for_testing(clock);

    LiquidityPool {
        id: object::new(ctx),
        market_id: object::id_from_address(@0x0),
        outcome_idx: 0,
        asset_reserve: asset_amount,
        stable_reserve: stable_amount,
        fee_percent: fee_bps,
        oracle: oracle_obj,
        protocol_fees_asset: 0,
        protocol_fees_stable: 0,
        lp_supply: constants::minimum_liquidity(),
        pending_injected_asset: 0,
        pending_injected_stable: 0,
        pending_asset_out: 0,
        pending_stable_out: 0,
        pending_swap_done: false,
    }
}

#[test_only]
public fun destroy_for_testing(pool: LiquidityPool) {
    let LiquidityPool {
        id,
        market_id: _,
        outcome_idx: _,
        asset_reserve: _,
        stable_reserve: _,
        fee_percent: _,
        oracle,
        protocol_fees_asset: _,
        protocol_fees_stable: _,
        lp_supply: _,
        pending_injected_asset: _,
        pending_injected_stable: _,
        pending_asset_out: _,
        pending_stable_out: _,
        pending_swap_done: _,
    } = pool;
    id.delete();
    oracle.destroy_for_testing();
}

#[test_only]
/// Add liquidity to a pool for testing (simplified version)
/// Takes coins directly, extracts values, updates reserves, and destroys coins
public fun add_liquidity_for_testing<AssetType, StableType>(
    pool: &mut LiquidityPool,
    asset_coin: sui::coin::Coin<AssetType>,
    stable_coin: sui::coin::Coin<StableType>,
    _fee_bps: u16, // Not used in test helper, kept for API compatibility
    _ctx: &mut TxContext,
) {
    // Extract amounts from coins
    let asset_amount = asset_coin.value();
    let stable_amount = stable_coin.value();

    // Destroy test coins (we just want to update reserves)
    sui::test_utils::destroy(asset_coin);
    sui::test_utils::destroy(stable_coin);

    // Update reserves directly (simplified for testing)
    pool.asset_reserve = pool.asset_reserve + asset_amount;
    pool.stable_reserve = pool.stable_reserve + stable_amount;

    // Update LP supply proportionally (simplified calculation for testing)
    if (pool.lp_supply == 0) {
        // First liquidity provider
        let k_squared = math::mul_div_to_128(asset_amount, stable_amount, 1);
        let k = (k_squared.sqrt() as u64);
        pool.lp_supply = k;
    } else {
        // Subsequent providers - mint proportionally
        let lp_from_asset = math::mul_div_to_64(
            asset_amount,
            pool.lp_supply,
            pool.asset_reserve - asset_amount,
        );
        let lp_from_stable = math::mul_div_to_64(
            stable_amount,
            pool.lp_supply,
            pool.stable_reserve - stable_amount,
        );
        let lp_to_mint = if (lp_from_asset < lp_from_stable) { lp_from_asset } else {
            lp_from_stable
        };
        pool.lp_supply = pool.lp_supply + lp_to_mint;
    };
}

#[test_only]
/// Set protocol fees for testing
public fun set_protocol_fees_for_testing(
    pool: &mut LiquidityPool,
    asset_fee: u64,
    stable_fee: u64,
) {
    pool.protocol_fees_asset = asset_fee;
    pool.protocol_fees_stable = stable_fee;
}

#[test_only]
/// Add to reserves for testing (simulates fee accumulation)
public fun add_reserves_for_testing(
    pool: &mut LiquidityPool,
    asset_amount: u64,
    stable_amount: u64,
) {
    pool.asset_reserve = pool.asset_reserve + asset_amount;
    pool.stable_reserve = pool.stable_reserve + stable_amount;
}

#[test_only]
/// Test-only version of empty_all_amm_liquidity (no auth required)
public fun empty_all_amm_liquidity_for_testing(
    pool: &mut LiquidityPool,
    _ctx: &mut TxContext,
): (u64, u64) {
    let asset_amount_out = pool.asset_reserve;
    let stable_amount_out = pool.stable_reserve;
    pool.asset_reserve = 0;
    pool.stable_reserve = 0;
    pool.lp_supply = 0;
    (asset_amount_out, stable_amount_out)
}

#[test_only]
/// Test-only version of collect_protocol_fees (no auth required)
public fun collect_protocol_fees_for_testing(
    pool: &mut LiquidityPool,
): (u64, u64) {
    let asset_fees = pool.protocol_fees_asset;
    let stable_fees = pool.protocol_fees_stable;
    pool.protocol_fees_asset = 0;
    pool.protocol_fees_stable = 0;
    (asset_fees, stable_fees)
}

#[test_only]
/// Test-only version of feeless_swap_asset_to_stable (no auth required)
public fun feeless_swap_asset_to_stable_for_testing(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
): u64 {
    assert!(pool.market_id == market_id, EMarketMismatch);
    swap_asset_to_stable_internal(pool, amount_in, false)
}

#[test_only]
/// Test-only version of feeless_swap_stable_to_asset (no auth required)
public fun feeless_swap_stable_to_asset_for_testing(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
): u64 {
    assert!(pool.market_id == market_id, EMarketMismatch);
    swap_stable_to_asset_internal(pool, amount_in, false)
}

#[test_only]
/// Test-only version of set_oracle_start_time (no auth required)
public fun set_oracle_start_time_for_testing(
    pool: &mut LiquidityPool,
    market_id: ID,
    trading_start_time: u64,
) {
    assert!(get_ms_id(pool) == market_id, EMarketIdMismatch);
    pool.oracle.set_oracle_start_time(trading_start_time);
}

#[test_only]
/// Test-only version of inject_reserves_for_arbitrage (no auth required)
public fun inject_reserves_for_arbitrage_for_testing(
    pool: &mut LiquidityPool,
    market_id: ID,
    asset_amount: u64,
    stable_amount: u64,
) {
    assert!(pool.market_id == market_id, EMarketMismatch);
    assert_no_pending_injection(pool);
    assert_exactly_one_injected_side(asset_amount, stable_amount);
    assert_reserve_add_safe(pool, asset_amount, stable_amount);
    pool.pending_injected_asset = asset_amount;
    pool.pending_injected_stable = stable_amount;
    pool.asset_reserve = pool.asset_reserve + asset_amount;
    pool.stable_reserve = pool.stable_reserve + stable_amount;
}

#[test_only]
/// Test-only version of extract_reserves_for_arbitrage (no auth required)
public fun extract_reserves_for_arbitrage_for_testing(
    pool: &mut LiquidityPool,
    market_id: ID,
    asset_amount: u64,
    stable_amount: u64,
) {
    assert!(pool.market_id == market_id, EMarketMismatch);
    assert!(has_pending_injection(pool), ENoInjectionPending);
    assert!(pool.pending_swap_done, EInjectedSwapNotDone);
    assert!(asset_amount == pool.pending_asset_out, EInjectionMismatch);
    assert!(stable_amount == pool.pending_stable_out, EInjectionMismatch);
    assert!(pool.asset_reserve >= asset_amount, ELowLiquidity);
    assert!(pool.stable_reserve >= stable_amount, ELowLiquidity);
    pool.asset_reserve = pool.asset_reserve - asset_amount;
    pool.stable_reserve = pool.stable_reserve - stable_amount;
    clear_pending_injection(pool);
}

#[test_only]
/// Test-only version of swap_from_injected_stable_to_asset (no auth required)
public fun swap_from_injected_stable_to_asset_for_testing(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    clock: &Clock,
): u64 {
    assert!(pool.market_id == market_id, EMarketMismatch);
    assert!(has_pending_injection(pool), ENoInjectionPending);
    assert!(!pool.pending_swap_done, EInjectedSwapAlreadyDone);
    assert!(pool.pending_injected_asset == 0, EInjectionMismatch);
    assert!(pool.pending_injected_stable == amount_in, EInjectionMismatch);
    assert!(amount_in > 0, EZeroAmount);
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EPoolEmpty);
    assert!(pool.stable_reserve >= amount_in, EInjectionMismatch);

    let original_stable = pool.stable_reserve - amount_in;
    assert!(original_stable > 0, EPoolEmpty);

    let timestamp = clock.timestamp_ms();
    let old_price = math::mul_div_to_128(original_stable, constants::price_precision_scale(), pool.asset_reserve);
    write_observation(&mut pool.oracle, timestamp, old_price, clock);

    let asset_out = calculate_output(amount_in, original_stable, pool.asset_reserve);
    assert!(asset_out > 0, EZeroAmount);
    assert!(asset_out < pool.asset_reserve, EPoolEmpty);
    pool.pending_asset_out = asset_out;
    pool.pending_stable_out = 0;
    pool.pending_swap_done = true;

    asset_out
}

#[test_only]
/// Test-only version of update_twap_observation (now private in production)
public fun update_twap_observation_for_testing(pool: &mut LiquidityPool, clock: &Clock) {
    update_twap_observation(pool, clock);
}

#[test_only]
/// Test-only version of swap_from_injected_asset_to_stable (no auth required)
public fun swap_from_injected_asset_to_stable_for_testing(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    clock: &Clock,
): u64 {
    assert!(pool.market_id == market_id, EMarketMismatch);
    assert!(has_pending_injection(pool), ENoInjectionPending);
    assert!(!pool.pending_swap_done, EInjectedSwapAlreadyDone);
    assert!(pool.pending_injected_asset == amount_in, EInjectionMismatch);
    assert!(pool.pending_injected_stable == 0, EInjectionMismatch);
    assert!(amount_in > 0, EZeroAmount);
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EPoolEmpty);
    assert!(pool.asset_reserve >= amount_in, EInjectionMismatch);

    let original_asset = pool.asset_reserve - amount_in;
    assert!(original_asset > 0, EPoolEmpty);

    let timestamp = clock.timestamp_ms();
    let old_price = math::mul_div_to_128(pool.stable_reserve, constants::price_precision_scale(), original_asset);
    write_observation(&mut pool.oracle, timestamp, old_price, clock);

    let stable_out = calculate_output(amount_in, original_asset, pool.stable_reserve);
    assert!(stable_out > 0, EZeroAmount);
    assert!(stable_out < pool.stable_reserve, EPoolEmpty);
    pool.pending_asset_out = 0;
    pool.pending_stable_out = stable_out;
    pool.pending_swap_done = true;

    stable_out
}
