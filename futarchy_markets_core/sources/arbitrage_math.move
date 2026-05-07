// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Math helpers for spot/conditional routing.
///
/// Production has two objectives:
/// - trader split routing: maximize the user's fee-charged output
/// - system rebalance: maximize spot-pool K gain under the actual internal reserve transition

module futarchy_markets_core::arbitrage_math;

use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::math;
use sui::clock::Clock;

// === Errors ===
const ETooManyConditionals: u64 = 0;

// === Constants ===
const SMART_BOUND_MARGIN_NUM: u64 = 11; // 1.1x user swap
const SMART_BOUND_MARGIN_DENOM: u64 = 10;
const MIN_COARSE_THRESHOLD: u64 = 3; // Minimum safe ternary search threshold

// ============================================================================
// PRIMARY ENTRY POINTS
// ============================================================================

/// Compute the best system rebalance using the actual reserve transition that
/// `arbitrage.move` executes.
///
/// Returns `(amount, is_cond_to_spot, k_gain)`.
public fun compute_optimal_internal_rebalance<AssetType, StableType, LPType>(
    spot: &UnifiedSpotPool<AssetType, StableType, LPType>,
    conditionals: &vector<LiquidityPool>,
    user_swap_output: u64,
): (u64, bool, u128) {
    let outcome_count = vector::length(conditionals);
    if (outcome_count > 0) {
        assert!(outcome_count <= constants::protocol_max_outcomes(), ETooManyConditionals);
    };

    let (spot_above_all, spot_below_all) = classify_spot_position(spot, conditionals);
    if (!spot_above_all && !spot_below_all) {
        return (0, false, 0)
    };

    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot);
    if (spot_asset == 0 || spot_stable == 0) {
        return (0, false, 0)
    };

    if (spot_below_all) {
        let (amount, score) = compute_internal_spot_to_conditional(
            spot_asset,
            spot_stable,
            conditionals,
            user_swap_output,
        );
        if (score > 0) {
            return (amount, false, score)
        };
    };

    if (spot_above_all) {
        let (amount, score) = compute_internal_conditional_to_spot(
            spot_asset,
            spot_stable,
            conditionals,
            user_swap_output,
        );
        if (score > 0) {
            return (amount, true, score)
        };
    };

    (0, false, 0)
}

/// Classifies spot position relative to all conditionals.
/// Returns `(spot_above_all, spot_below_all)` where:
/// - `spot_above_all` is true only when spot_price > cond_price for every pool
/// - `spot_below_all` is true only when spot_price < cond_price for every pool
/// If either side contains equality, both will be false.
fun classify_spot_position<AssetType, StableType, LPType>(
    spot: &UnifiedSpotPool<AssetType, StableType, LPType>,
    conditionals: &vector<LiquidityPool>,
): (bool, bool) {
    let n = vector::length(conditionals);
    if (n == 0) return (false, false);

    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot);
    if (spot_asset == 0 || spot_stable == 0) return (false, false);

    let mut spot_above_all = true;
    let mut spot_below_all = true;

    let mut i = 0;
    while (i < n) {
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(
            vector::borrow(conditionals, i),
        );
        if (cond_asset == 0 || cond_stable == 0) {
            return (false, false)
        };

        // Cross-multiply to compare spot_stable/spot_asset with cond_stable/cond_asset.
        let lhs = (spot_stable as u256) * (cond_asset as u256);
        let rhs = (cond_stable as u256) * (spot_asset as u256);

        // If spot <= cond for any pool, spot is not above all.
        if (lhs <= rhs) {
            spot_above_all = false;
        };

        // If spot >= cond for any pool, spot is not below all.
        if (lhs >= rhs) {
            spot_below_all = false;
        };

        if (!spot_above_all && !spot_below_all) {
            return (false, false)
        };

        i = i + 1;
    };

    (spot_above_all, spot_below_all)
}

/// Compute the best trader split for stable→asset execution.
///
/// Returns `(spot_stable_in, conditional_stable_in, expected_asset_out)`.
/// The conditional output cap is the escrow asset backing available for
/// recombination; splits whose conditional leg cannot be backed are ignored.
public fun compute_best_stable_to_asset_split<AssetType, StableType, LPType>(
    spot: &UnifiedSpotPool<AssetType, StableType, LPType>,
    conditionals: &vector<LiquidityPool>,
    stable_amount: u64,
    conditional_asset_output_cap: u64,
    clock: &Clock,
): (u64, u64, u64) {
    if (stable_amount == 0) return (0, 0, 0);
    let outcome_count = vector::length(conditionals);
    if (outcome_count > 0) {
        assert!(outcome_count <= constants::protocol_max_outcomes(), ETooManyConditionals);
    };

    if (outcome_count == 0 || conditional_asset_output_cap == 0) {
        return (
            stable_amount,
            0,
            unified_spot_pool::simulate_swap_stable_to_asset_accurate(spot, stable_amount, clock),
        )
    };

    ternary_search_stable_to_asset_split(
        spot,
        conditionals,
        stable_amount,
        conditional_asset_output_cap,
        clock,
    )
}

/// Compute the best trader split for asset→stable execution.
///
/// Returns `(spot_asset_in, conditional_asset_in, expected_stable_out)`.
/// The conditional output cap is the escrow stable backing available for
/// recombination; splits whose conditional leg cannot be backed are ignored.
public fun compute_best_asset_to_stable_split<AssetType, StableType, LPType>(
    spot: &UnifiedSpotPool<AssetType, StableType, LPType>,
    conditionals: &vector<LiquidityPool>,
    asset_amount: u64,
    conditional_stable_output_cap: u64,
    clock: &Clock,
): (u64, u64, u64) {
    if (asset_amount == 0) return (0, 0, 0);
    let outcome_count = vector::length(conditionals);
    if (outcome_count > 0) {
        assert!(outcome_count <= constants::protocol_max_outcomes(), ETooManyConditionals);
    };

    if (outcome_count == 0 || conditional_stable_output_cap == 0) {
        return (
            asset_amount,
            0,
            unified_spot_pool::simulate_swap_asset_to_stable_accurate(spot, asset_amount, clock),
        )
    };

    ternary_search_asset_to_stable_split(
        spot,
        conditionals,
        asset_amount,
        conditional_stable_output_cap,
        clock,
    )
}

// ============================================================================
// INTERNAL REBALANCE OBJECTIVE
// ============================================================================

fun compute_internal_spot_to_conditional(
    spot_asset: u64,
    spot_stable: u64,
    conditionals: &vector<LiquidityPool>,
    user_swap_output: u64,
): (u64, u128) {
    if (spot_asset < 2) return (0, 0);
    let global_ub = spot_asset - 1;
    let upper_bound = apply_smart_bound(global_ub, user_swap_output);
    ternary_search_internal_spot_to_cond(
        spot_asset,
        spot_stable,
        conditionals,
        upper_bound,
    )
}

fun ternary_search_internal_spot_to_cond(
    spot_asset: u64,
    spot_stable: u64,
    conditionals: &vector<LiquidityPool>,
    upper_bound: u64,
): (u64, u128) {
    if (upper_bound == 0) return (0, 0);

    let mut left = 0u64;
    let mut right = upper_bound;
    let mut best_b = 0u64;
    let mut best_score = 0u128;

    while (right - left > MIN_COARSE_THRESHOLD) {
        let gap = right - left;
        let third = gap / 3;
        let m1 = left + third;
        let m2 = right - third;

        let p1 = internal_score_spot_to_cond(spot_asset, spot_stable, conditionals, m1);
        let p2 = internal_score_spot_to_cond(spot_asset, spot_stable, conditionals, m2);

        if (p1 > best_score) { best_score = p1; best_b = m1; };
        if (p2 > best_score) { best_score = p2; best_b = m2; };

        if (p1 >= p2) { right = m2; } else { left = m1; };
    };

    let mut k = left;
    while (k <= right) {
        let pk = internal_score_spot_to_cond(spot_asset, spot_stable, conditionals, k);
        if (pk > best_score) { best_score = pk; best_b = k; };
        k = k + 1;
    };

    (best_b, best_score)
}

fun internal_score_spot_to_cond(
    spot_asset: u64,
    spot_stable: u64,
    conditionals: &vector<LiquidityPool>,
    asset_amount: u64,
): u128 {
    if (asset_amount == 0 || asset_amount >= spot_asset) return 0;

    let min_stable = min_conditional_stable_out(conditionals, asset_amount);
    if (min_stable == 0) return 0;

    let old_k = (spot_asset as u256) * (spot_stable as u256);
    let new_k = ((spot_asset - asset_amount) as u256) *
        ((spot_stable as u256) + (min_stable as u256));
    k_gain_to_u128(old_k, new_k)
}

fun compute_internal_conditional_to_spot(
    spot_asset: u64,
    spot_stable: u64,
    conditionals: &vector<LiquidityPool>,
    user_swap_output: u64,
): (u64, u128) {
    let n = vector::length(conditionals);
    if (n == 0) return (0, 0);

    let mut min_cond_asset = std::u64::max_value!();
    let mut i = 0;
    while (i < n) {
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(
            vector::borrow(conditionals, i),
        );
        if (cond_asset == 0 || cond_stable == 0) return (0, 0);
        if (cond_asset < min_cond_asset) { min_cond_asset = cond_asset; };
        i = i + 1;
    };

    if (min_cond_asset < 2) return (0, 0);
    let global_ub = min_cond_asset - 1;
    let upper_bound = apply_smart_bound(global_ub, user_swap_output);
    ternary_search_internal_cond_to_spot(
        spot_asset,
        spot_stable,
        conditionals,
        upper_bound,
    )
}

fun ternary_search_internal_cond_to_spot(
    spot_asset: u64,
    spot_stable: u64,
    conditionals: &vector<LiquidityPool>,
    upper_bound: u64,
): (u64, u128) {
    if (upper_bound == 0) return (0, 0);

    let mut left = 0u64;
    let mut right = upper_bound;
    let mut best_b = 0u64;
    let mut best_score = 0u128;

    while (right - left > MIN_COARSE_THRESHOLD) {
        let gap = right - left;
        let third = gap / 3;
        let m1 = left + third;
        let m2 = right - third;

        let p1 = internal_score_cond_to_spot(spot_asset, spot_stable, conditionals, m1);
        let p2 = internal_score_cond_to_spot(spot_asset, spot_stable, conditionals, m2);

        if (p1 > best_score) { best_score = p1; best_b = m1; };
        if (p2 > best_score) { best_score = p2; best_b = m2; };

        if (p1 >= p2) { right = m2; } else { left = m1; };
    };

    let mut k = left;
    while (k <= right) {
        let pk = internal_score_cond_to_spot(spot_asset, spot_stable, conditionals, k);
        if (pk > best_score) { best_score = pk; best_b = k; };
        k = k + 1;
    };

    (best_b, best_score)
}

/// Max stable cost across conditional pools to extract `asset_amount` from each.
/// Returns `u128::MAX` if any pool cannot support the requested asset amount.
public(package) fun max_conditional_stable_cost(
    conditionals: &vector<LiquidityPool>,
    asset_amount: u64,
): u128 {
    calculate_conditional_cost(conditionals, asset_amount)
}

fun calculate_conditional_cost(conditionals: &vector<LiquidityPool>, b: u64): u128 {
    let n = vector::length(conditionals);
    let mut max_cost = 0u128;
    let b_u128 = (b as u128);

    let mut i = 0;
    while (i < n) {
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(
            vector::borrow(conditionals, i),
        );
        if (b >= cond_asset) return std::u128::max_value!();

        let numerator = (cond_stable as u128) * b_u128;
        let denominator = (cond_asset as u128) - b_u128;
        if (denominator == 0) return std::u128::max_value!();

        let cost_i = (numerator + denominator - 1) / denominator;
        if (cost_i > max_cost) { max_cost = cost_i; };
        i = i + 1;
    };

    max_cost
}

fun internal_score_cond_to_spot(
    spot_asset: u64,
    spot_stable: u64,
    conditionals: &vector<LiquidityPool>,
    asset_amount: u64,
): u128 {
    if (asset_amount == 0) return 0;

    let stable_needed = calculate_conditional_cost(conditionals, asset_amount);
    if (stable_needed == std::u128::max_value!()) return 0;
    if (stable_needed == 0 || stable_needed >= (spot_stable as u128)) return 0;
    if (stable_needed > (std::u64::max_value!() as u128)) return 0;

    let stable_in = (stable_needed as u64);
    let min_asset = min_conditional_asset_out(conditionals, stable_in);
    if (min_asset == 0) return 0;

    let old_k = (spot_asset as u256) * (spot_stable as u256);
    let new_k = ((spot_asset as u256) + (min_asset as u256)) *
        ((spot_stable - stable_in) as u256);
    k_gain_to_u128(old_k, new_k)
}

public(package) fun quote_conditional_stable_to_asset(
    conditionals: &vector<LiquidityPool>,
    stable_amount: u64,
): u64 {
    let out = min_conditional_asset_out_with_fees(conditionals, stable_amount);
    if (out > (std::u64::max_value!() as u128)) { 0 } else { (out as u64) }
}

public(package) fun quote_conditional_asset_to_stable(
    conditionals: &vector<LiquidityPool>,
    asset_amount: u64,
): u64 {
    let out = min_conditional_stable_out_with_fees(conditionals, asset_amount);
    if (out > (std::u64::max_value!() as u128)) { 0 } else { (out as u64) }
}

fun ternary_search_stable_to_asset_split<AssetType, StableType, LPType>(
    spot: &UnifiedSpotPool<AssetType, StableType, LPType>,
    conditionals: &vector<LiquidityPool>,
    total_stable_in: u64,
    conditional_asset_output_cap: u64,
    clock: &Clock,
): (u64, u64, u64) {
    ternary_search_split(spot, conditionals, total_stable_in, conditional_asset_output_cap, true, clock)
}

fun ternary_search_asset_to_stable_split<AssetType, StableType, LPType>(
    spot: &UnifiedSpotPool<AssetType, StableType, LPType>,
    conditionals: &vector<LiquidityPool>,
    total_asset_in: u64,
    conditional_stable_output_cap: u64,
    clock: &Clock,
): (u64, u64, u64) {
    ternary_search_split(spot, conditionals, total_asset_in, conditional_stable_output_cap, false, clock)
}

fun ternary_search_split<AssetType, StableType, LPType>(
    spot: &UnifiedSpotPool<AssetType, StableType, LPType>,
    conditionals: &vector<LiquidityPool>,
    total_in: u64,
    conditional_output_cap: u64,
    is_stable_to_asset: bool,
    clock: &Clock,
): (u64, u64, u64) {
    let mut left = 0u64;
    let mut right = total_in;
    let mut best_conditional_in = 0u64;
    let mut best_out = split_score(
        spot,
        conditionals,
        total_in,
        0,
        conditional_output_cap,
        is_stable_to_asset,
        clock,
    );

    let all_conditional_out = split_score(
        spot,
        conditionals,
        total_in,
        total_in,
        conditional_output_cap,
        is_stable_to_asset,
        clock,
    );
    if (all_conditional_out > best_out) {
        best_out = all_conditional_out;
        best_conditional_in = total_in;
    };

    // Real-valued UniV2 split output is concave. Integer fee/output floors can
    // add dust-sized teeth, so this targets near-optimal routing, not a formal
    // last-base-unit exhaustive optimum.
    while (right - left > MIN_COARSE_THRESHOLD) {
        let gap = right - left;
        let third = gap / 3;
        let m1 = left + third;
        let m2 = right - third;

        let p1 = split_score(
            spot,
            conditionals,
            total_in,
            m1,
            conditional_output_cap,
            is_stable_to_asset,
            clock,
        );
        let p2 = split_score(
            spot,
            conditionals,
            total_in,
            m2,
            conditional_output_cap,
            is_stable_to_asset,
            clock,
        );

        if (p1 > best_out) { best_out = p1; best_conditional_in = m1; };
        if (p2 > best_out) { best_out = p2; best_conditional_in = m2; };

        if (p1 >= p2) { right = m2; } else { left = m1; };
    };

    let mut k = left;
    while (k <= right) {
        let pk = split_score(
            spot,
            conditionals,
            total_in,
            k,
            conditional_output_cap,
            is_stable_to_asset,
            clock,
        );
        if (pk > best_out) {
            best_out = pk;
            best_conditional_in = k;
        };
        if (k == right) break;
        k = k + 1;
    };

    (total_in - best_conditional_in, best_conditional_in, u128_to_u64_quote(best_out))
}

fun split_score<AssetType, StableType, LPType>(
    spot: &UnifiedSpotPool<AssetType, StableType, LPType>,
    conditionals: &vector<LiquidityPool>,
    total_in: u64,
    conditional_in: u64,
    conditional_output_cap: u64,
    is_stable_to_asset: bool,
    clock: &Clock,
): u128 {
    if (conditional_in > total_in) return 0;
    let spot_in = total_in - conditional_in;
    let spot_out = if (spot_in == 0) {
        0
    } else if (is_stable_to_asset) {
        unified_spot_pool::simulate_swap_stable_to_asset_accurate(spot, spot_in, clock)
    } else {
        unified_spot_pool::simulate_swap_asset_to_stable_accurate(spot, spot_in, clock)
    };
    if (spot_in > 0 && spot_out == 0) return 0;

    let conditional_out = if (conditional_in == 0) {
        0
    } else if (is_stable_to_asset) {
        quote_conditional_stable_to_asset(conditionals, conditional_in)
    } else {
        quote_conditional_asset_to_stable(conditionals, conditional_in)
    };
    if (conditional_in > 0 && conditional_out == 0) return 0;
    if (conditional_out > conditional_output_cap) return 0;

    let total_out = (spot_out as u128) + (conditional_out as u128);
    if (total_out > (std::u64::max_value!() as u128)) return 0;
    total_out
}

fun u128_to_u64_quote(value: u128): u64 {
    if (value > (std::u64::max_value!() as u128)) {
        std::u64::max_value!()
    } else {
        (value as u64)
    }
}

fun amount_after_conditional_fees(pool: &LiquidityPool, amount_in: u64): u64 {
    let protocol_fee = math::mul_div_to_64(
        amount_in,
        constants::protocol_fee_bps(),
        constants::total_fee_bps(),
    );
    let lp_fee = math::mul_div_to_64(
        amount_in,
        conditional_amm::get_fee_bps(pool),
        constants::total_fee_bps(),
    );
    let total_fee = protocol_fee + lp_fee;
    if (amount_in <= total_fee) { 0 } else { amount_in - total_fee }
}

fun min_conditional_asset_out_with_fees(
    conditionals: &vector<LiquidityPool>,
    stable_amount: u64,
): u128 {
    if (stable_amount == 0) return 0;
    let n = vector::length(conditionals);
    if (n == 0) return 0;

    let mut min_out = std::u128::max_value!();
    let mut i = 0;
    while (i < n) {
        let pool = vector::borrow(conditionals, i);
        let amount_after_fee = amount_after_conditional_fees(pool, stable_amount);
        if (amount_after_fee == 0) return 0;

        let (cond_asset, cond_stable) = conditional_amm::get_reserves(pool);
        if (cond_asset == 0 || cond_stable == 0) return 0;

        let numerator = (cond_asset as u128) * (amount_after_fee as u128);
        let denominator = (cond_stable as u128) + (amount_after_fee as u128);
        if (denominator == 0) return 0;
        let out = numerator / denominator;
        if (out < min_out) { min_out = out; };
        i = i + 1;
    };

    if (min_out == std::u128::max_value!()) { 0 } else { min_out }
}

fun min_conditional_stable_out_with_fees(
    conditionals: &vector<LiquidityPool>,
    asset_amount: u64,
): u128 {
    if (asset_amount == 0) return 0;
    let n = vector::length(conditionals);
    if (n == 0) return 0;

    let mut min_out = std::u128::max_value!();
    let mut i = 0;
    while (i < n) {
        let pool = vector::borrow(conditionals, i);
        let amount_after_fee = amount_after_conditional_fees(pool, asset_amount);
        if (amount_after_fee == 0) return 0;

        let (cond_asset, cond_stable) = conditional_amm::get_reserves(pool);
        if (cond_asset == 0 || cond_stable == 0) return 0;

        let numerator = (cond_stable as u128) * (amount_after_fee as u128);
        let denominator = (cond_asset as u128) + (amount_after_fee as u128);
        if (denominator == 0) return 0;
        let out = numerator / denominator;
        if (out < min_out) { min_out = out; };
        i = i + 1;
    };

    if (min_out == std::u128::max_value!()) { 0 } else { min_out }
}

fun min_conditional_asset_out(conditionals: &vector<LiquidityPool>, stable_amount: u64): u128 {
    if (stable_amount == 0) return 0;
    let n = vector::length(conditionals);
    if (n == 0) return 0;

    let mut min_out = std::u128::max_value!();
    let mut i = 0;
    while (i < n) {
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(
            vector::borrow(conditionals, i),
        );
        if (cond_asset == 0 || cond_stable == 0) return 0;

        let numerator = (cond_asset as u128) * (stable_amount as u128);
        let denominator = (cond_stable as u128) + (stable_amount as u128);
        if (denominator == 0) return 0;
        let out = numerator / denominator;
        if (out < min_out) { min_out = out; };
        i = i + 1;
    };

    if (min_out == std::u128::max_value!()) { 0 } else { min_out }
}

fun min_conditional_stable_out(conditionals: &vector<LiquidityPool>, asset_amount: u64): u128 {
    if (asset_amount == 0) return 0;
    let n = vector::length(conditionals);
    if (n == 0) return 0;

    let mut min_out = std::u128::max_value!();
    let mut i = 0;
    while (i < n) {
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(
            vector::borrow(conditionals, i),
        );
        if (cond_asset == 0 || cond_stable == 0) return 0;

        let numerator = (cond_stable as u128) * (asset_amount as u128);
        let denominator = (cond_asset as u128) + (asset_amount as u128);
        if (denominator == 0) return 0;
        let out = numerator / denominator;
        if (out < min_out) { min_out = out; };
        i = i + 1;
    };

    if (min_out == std::u128::max_value!()) { 0 } else { min_out }
}

fun k_gain_to_u128(old_k: u256, new_k: u256): u128 {
    if (new_k <= old_k) return 0;
    let gain = new_k - old_k;
    if (gain > (std::u128::max_value!() as u256)) {
        std::u128::max_value!()
    } else {
        (gain as u128)
    }
}

// ============================================================================
// UTILITIES
// ============================================================================

fun apply_smart_bound(global_ub: u64, user_swap_output: u64): u64 {
    if (user_swap_output == 0) return global_ub;
    // SAFETY: Prevent overflow when user_swap_output is very large
    // Max safe value before overflow: u64::MAX / 11 = ~1.67e18
    let hint_bound = if (user_swap_output > std::u64::max_value!() / SMART_BOUND_MARGIN_NUM) {
        std::u64::max_value!()
    } else {
        (user_swap_output * SMART_BOUND_MARGIN_NUM) / SMART_BOUND_MARGIN_DENOM
    };
    if (hint_bound < global_ub) { hint_bound } else { global_ub }
}
