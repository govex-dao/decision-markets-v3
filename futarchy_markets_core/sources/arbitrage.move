// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Unified arbitrage module that works for ANY outcome count
///
/// This module eliminates type explosion by using balance-based operations.
/// ONE arbitrage function works for 2, 3, 4, 5, or 200 outcomes.
///
/// Key innovation: Loops over outcomes using balance indices instead of
/// requiring N type parameters.

module futarchy_markets_core::arbitrage;

use std::option;
use std::vector;

use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationAuth, EscrowMutationRegistry};
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationAuth, MarketStateMutationRegistry};
use futarchy_markets_core::arbitrage_math;
use futarchy_markets_core::swap_core;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm;
use futarchy_markets_primitives::conditional_balance::{Self, ConditionalMarketBalance};
use futarchy_markets_primitives::market_state;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::object;

// === Witness for mutation authorization ===
public struct EscrowMutationWitness has drop {}
public struct MarketStateMutationWitness has drop {}

/// Create auth for this package's escrow mutations
fun create_auth(registry: &EscrowMutationRegistry): EscrowMutationAuth {
    escrow_mutation_auth::create(registry, EscrowMutationWitness {})
}

/// Create auth for this package's market state mutations
fun create_market_auth(registry: &MarketStateMutationRegistry): MarketStateMutationAuth {
    market_state_mutation_auth::create(registry, MarketStateMutationWitness {})
}

// === Error Codes ===

/// Balance's market ID doesn't match escrow's market ID
/// NOTE: Using 100+ to avoid conflicts with Sui system error codes (0-99)
const EMarketMismatch: u64 = 100;
/// AMM returned zero output - pathological reserve ratio would cause state drift
const EZeroOutput: u64 = 102;
/// Spot pool is not associated with this escrow's market
const ESpotPoolEscrowMismatch: u64 = 103;
/// Outcome count exceeds maximum supported value (255)
const EOutcomeCountOverflow: u64 = 104;
/// Input amount must be non-zero
const EZeroAmount: u64 = 105;
/// Escrow does not hold enough spot backing to settle the recombined route output
const EInsufficientEscrowBacking: u64 = 106;
/// Route output did not satisfy the caller's minimum output
const EMinAmountNotMet: u64 = 107;

// === Events ===

/// Emitted when system/LP inventory is rebalanced between spot and conditionals.
public struct SystemRebalanceExecuted has copy, drop {
    market_id: ID,
    is_cond_to_spot: bool,
    arb_amount_hint: u64,
    actual_input: u64,
    actual_output: u64,
    retained_system_dust_created: bool,
}

fun preview_system_rebalance_stable_to_asset(
    pools: &vector<conditional_amm::LiquidityPool>,
    stable_amount: u64,
): (u64, bool) {
    if (stable_amount == 0) return (0, false);
    let n = vector::length(pools);
    if (n == 0) return (0, false);

    let mut min_out = std::u64::max_value!();
    let mut has_excess = false;
    let mut i = 0;
    while (i < n) {
        let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(&pools[i]);
        let out = preview_constant_product_output(stable_amount, stable_reserve, asset_reserve);
        if (out == 0) return (0, false);
        if (min_out != std::u64::max_value!() && out != min_out) {
            has_excess = true;
        };
        if (out < min_out) {
            if (min_out != std::u64::max_value!()) {
                has_excess = true;
            };
            min_out = out;
        };
        i = i + 1;
    };

    if (min_out == std::u64::max_value!()) { (0, false) } else { (min_out, has_excess) }
}

fun preview_system_rebalance_asset_to_stable(
    pools: &vector<conditional_amm::LiquidityPool>,
    asset_amount: u64,
): (u64, bool) {
    if (asset_amount == 0) return (0, false);
    let n = vector::length(pools);
    if (n == 0) return (0, false);

    let mut min_out = std::u64::max_value!();
    let mut has_excess = false;
    let mut i = 0;
    while (i < n) {
        let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(&pools[i]);
        let out = preview_constant_product_output(asset_amount, asset_reserve, stable_reserve);
        if (out == 0) return (0, false);
        if (min_out != std::u64::max_value!() && out != min_out) {
            has_excess = true;
        };
        if (out < min_out) {
            if (min_out != std::u64::max_value!()) {
                has_excess = true;
            };
            min_out = out;
        };
        i = i + 1;
    };

    if (min_out == std::u64::max_value!()) { (0, false) } else { (min_out, has_excess) }
}

fun preview_constant_product_output(amount_in: u64, reserve_in: u64, reserve_out: u64): u64 {
    if (amount_in == 0 || reserve_in == 0 || reserve_out == 0) return 0;

    let numerator = (reserve_out as u256) * (amount_in as u256);
    let denominator = (reserve_in as u256) + (amount_in as u256);
    let output = numerator / denominator;
    if (output >= (reserve_out as u256)) {
        0
    } else {
        (output as u64)
    }
}

fun can_account_system_rebalance_stable_to_asset<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    stable_consumed: u64,
    asset_produced: u64,
): bool {
    if (coin_escrow::get_escrowed_stable_balance(escrow) > std::u64::max_value!() - stable_consumed) {
        return false
    };

    let mut i = 0u64;
    while (i < outcome_count) {
        if (coin_escrow::get_outcome_stable_supply(escrow, i) > std::u64::max_value!() - stable_consumed) {
            return false
        };
        if (coin_escrow::get_outcome_escrowed_stable(escrow, i) > std::u64::max_value!() - stable_consumed) {
            return false
        };
        if (coin_escrow::get_pool_claim_stable(escrow, i) > std::u64::max_value!() - stable_consumed) {
            return false
        };
        if (coin_escrow::get_outcome_asset_supply(escrow, i) > std::u64::max_value!() - asset_produced) {
            return false
        };
        if (coin_escrow::get_outcome_escrowed_asset(escrow, i) > std::u64::max_value!() - asset_produced) {
            return false
        };
        if (coin_escrow::get_pool_claim_asset(escrow, i) > std::u64::max_value!() - asset_produced) {
            return false
        };
        if (coin_escrow::get_outcome_wrapped_asset(escrow, i) > std::u64::max_value!() - asset_produced) {
            return false
        };
        i = i + 1;
    };

    true
}

fun can_account_system_rebalance_asset_to_stable<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    asset_consumed: u64,
    stable_produced: u64,
): bool {
    if (coin_escrow::get_escrowed_asset_balance(escrow) > std::u64::max_value!() - asset_consumed) {
        return false
    };

    let mut i = 0u64;
    while (i < outcome_count) {
        if (coin_escrow::get_outcome_asset_supply(escrow, i) > std::u64::max_value!() - asset_consumed) {
            return false
        };
        if (coin_escrow::get_outcome_escrowed_asset(escrow, i) > std::u64::max_value!() - asset_consumed) {
            return false
        };
        if (coin_escrow::get_pool_claim_asset(escrow, i) > std::u64::max_value!() - asset_consumed) {
            return false
        };
        if (coin_escrow::get_outcome_stable_supply(escrow, i) > std::u64::max_value!() - stable_produced) {
            return false
        };
        if (coin_escrow::get_outcome_escrowed_stable(escrow, i) > std::u64::max_value!() - stable_produced) {
            return false
        };
        if (coin_escrow::get_pool_claim_stable(escrow, i) > std::u64::max_value!() - stable_produced) {
            return false
        };
        if (coin_escrow::get_outcome_wrapped_stable(escrow, i) > std::u64::max_value!() - stable_produced) {
            return false
        };
        i = i + 1;
    };

    true
}

/// Trader-owned stable→asset route through all conditional pools.
///
/// The trader supplies the stable input and receives the recombined asset output.
/// Any per-outcome residual asset stays in wrapped form and is returned in the
/// `ConditionalMarketBalance`. This is separate from system rebalance, which uses
/// spot-pool inventory for maintenance.
public fun swap_stable_to_asset_through_conditionals<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    escrow_registry: &EscrowMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<AssetType>, option::Option<ConditionalMarketBalance<AssetType, StableType>>) {
    let stable_amount = coin::value(&stable_in);
    assert!(stable_amount > 0, EZeroAmount);

    let (market_id, outcome_count, quoted_asset_out) = {
        let market_state = coin_escrow::get_market_state(escrow);
        market_state::assert_swaps_allowed(market_state, clock);
        let market_id = market_state::market_id(market_state);
        let outcome_count = market_state::outcome_count(market_state);
        let quoted_asset_out = arbitrage_math::quote_conditional_stable_to_asset(
            market_state::borrow_amm_pools(market_state),
            stable_amount,
        );

        if (option::is_some(&existing_balance_opt)) {
            let existing_market_id = conditional_balance::market_id(option::borrow(&existing_balance_opt));
            assert!(existing_market_id == market_id, EMarketMismatch);
        };
        assert!(outcome_count <= 255, EOutcomeCountOverflow);
        (market_id, outcome_count, quoted_asset_out)
    };
    assert!(
        coin_escrow::get_escrowed_asset_balance(escrow) >= quoted_asset_out,
        EInsufficientEscrowBacking,
    );

    let mut route_balance = conditional_balance::new<AssetType, StableType>(
        market_id,
        (outcome_count as u8),
        ctx,
    );
    conditional_balance::split_stable_to_balance(escrow, &mut route_balance, stable_in);

    let session = swap_core::begin_swap_session(escrow);
    let mut i = 0u64;
    while (i < outcome_count) {
        swap_core::swap_balance_stable_to_asset(
            &session,
            escrow,
            &mut route_balance,
            (i as u8),
            stable_amount,
            0,
            escrow_registry,
            clock,
            ctx,
        );
        i = i + 1;
    };
    swap_core::finalize_swap_session(session, escrow, escrow_registry);

    let min_asset = conditional_balance::find_min_balance(&route_balance, true);
    assert!(min_asset > 0, EZeroOutput);
    assert!(min_asset >= min_asset_out, EMinAmountNotMet);

    let asset_coin = conditional_balance::recombine_balance_to_asset(
        escrow,
        &mut route_balance,
        min_asset,
        ctx,
    );
    let dust_created = !conditional_balance::is_empty(&route_balance);
    let dust_balance_opt = if (dust_created) {
        option::some(route_balance)
    } else {
        conditional_balance::destroy_empty(route_balance);
        option::none()
    };
    let final_balance_opt = merge_balance_options(existing_balance_opt, dust_balance_opt);

    coin_escrow::assert_quantum_invariant(escrow);
    (asset_coin, final_balance_opt)
}

/// Trader-owned asset→stable route through all conditional pools.
public fun swap_asset_to_stable_through_conditionals<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    escrow_registry: &EscrowMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, option::Option<ConditionalMarketBalance<AssetType, StableType>>) {
    let asset_amount = coin::value(&asset_in);
    assert!(asset_amount > 0, EZeroAmount);

    let (market_id, outcome_count, quoted_stable_out) = {
        let market_state = coin_escrow::get_market_state(escrow);
        market_state::assert_swaps_allowed(market_state, clock);
        let market_id = market_state::market_id(market_state);
        let outcome_count = market_state::outcome_count(market_state);
        let quoted_stable_out = arbitrage_math::quote_conditional_asset_to_stable(
            market_state::borrow_amm_pools(market_state),
            asset_amount,
        );

        if (option::is_some(&existing_balance_opt)) {
            let existing_market_id = conditional_balance::market_id(option::borrow(&existing_balance_opt));
            assert!(existing_market_id == market_id, EMarketMismatch);
        };
        assert!(outcome_count <= 255, EOutcomeCountOverflow);
        (market_id, outcome_count, quoted_stable_out)
    };
    assert!(
        coin_escrow::get_escrowed_stable_balance(escrow) >= quoted_stable_out,
        EInsufficientEscrowBacking,
    );

    let mut route_balance = conditional_balance::new<AssetType, StableType>(
        market_id,
        (outcome_count as u8),
        ctx,
    );
    conditional_balance::split_asset_to_balance(escrow, &mut route_balance, asset_in);

    let session = swap_core::begin_swap_session(escrow);
    let mut i = 0u64;
    while (i < outcome_count) {
        swap_core::swap_balance_asset_to_stable(
            &session,
            escrow,
            &mut route_balance,
            (i as u8),
            asset_amount,
            0,
            escrow_registry,
            clock,
            ctx,
        );
        i = i + 1;
    };
    swap_core::finalize_swap_session(session, escrow, escrow_registry);

    let min_stable = conditional_balance::find_min_balance(&route_balance, false);
    assert!(min_stable > 0, EZeroOutput);
    assert!(min_stable >= min_stable_out, EMinAmountNotMet);

    let stable_coin = conditional_balance::recombine_balance_to_stable(
        escrow,
        &mut route_balance,
        min_stable,
        ctx,
    );
    let dust_created = !conditional_balance::is_empty(&route_balance);
    let dust_balance_opt = if (dust_created) {
        option::some(route_balance)
    } else {
        conditional_balance::destroy_empty(route_balance);
        option::none()
    };
    let final_balance_opt = merge_balance_options(existing_balance_opt, dust_balance_opt);

    coin_escrow::assert_quantum_invariant(escrow);
    (stable_coin, final_balance_opt)
}

fun merge_balance_options<AssetType, StableType>(
    mut existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    mut result_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
): option::Option<ConditionalMarketBalance<AssetType, StableType>> {
    let final_balance_opt = if (option::is_some(&existing_balance_opt)) {
        let mut existing = option::extract(&mut existing_balance_opt);
        if (option::is_some(&result_balance_opt)) {
            let result_balance = option::extract(&mut result_balance_opt);
            conditional_balance::merge(&mut existing, result_balance);
        };
        option::destroy_none(result_balance_opt);
        option::some(existing)
    } else if (option::is_some(&result_balance_opt)) {
        result_balance_opt
    } else {
        option::destroy_none(result_balance_opt);
        option::none()
    };
    option::destroy_none(existing_balance_opt);
    final_balance_opt
}

// === Main Arbitrage Function ===

/// Best-effort system rebalance after conditional swaps.
/// Uses spot/LP inventory, keeps residual output pool-owned, and returns any
/// user balance passed in unchanged.
public fun auto_rebalance_spot_after_conditional_swaps<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): option::Option<ConditionalMarketBalance<AssetType, StableType>> {
    // Create auth for escrow mutations
    let auth = create_auth(escrow_registry);
    // Create auth for market state mutations (needed for conditional AMM operations)
    let market_auth = create_market_auth(market_state_registry);

    // SECURITY: Validate spot_pool is associated with this escrow
    // Prevents cross-market attacks where attacker passes mismatched pool/escrow pairs
    {
        let active_escrow_opt = unified_spot_pool::get_active_escrow_id(spot_pool);
        if (active_escrow_opt.is_some()) {
            let active_escrow_id = *option::borrow(&active_escrow_opt);
            assert!(active_escrow_id == object::id(escrow), ESpotPoolEscrowMismatch);
        } else {
            // Wrapped escrows are temporarily extracted during monolith swap/lifecycle flows.
            // In that case the pool remains proposal-locked and arbitrage is still valid.
            // If no escrow is active AND no proposal is active, skip arbitrage defensively.
            if (!unified_spot_pool::is_locked_for_proposal(spot_pool)) {
                return existing_balance_opt
            };
            // SECURITY: When escrow is extracted, validate via proposal_id binding
            // to prevent cross-market attacks with a foreign escrow.
            let pool_proposal_id = *option::borrow(&unified_spot_pool::get_active_proposal_id(spot_pool));
            let escrow_proposal_id = market_state::proposal_id(coin_escrow::get_market_state(escrow));
            assert!(pool_proposal_id == escrow_proposal_id, ESpotPoolEscrowMismatch);
        };
    };

    // Get market info and validate pass-through balances before touching AMM pools.
    // If conditional swaps are not allowed, rebalance is intentionally a no-op so
    // locked spot swaps can still use the pure spot route during proposal warmup,
    // after trading cutoff, or after finalization.
    let (market_id, outcome_count, swaps_allowed) = {
        let market_state = coin_escrow::get_market_state(escrow);
        let market_id = market_state::market_id(market_state);
        let outcome_count = market_state::outcome_count(market_state);
        let swaps_allowed = market_state::are_swaps_allowed(market_state, clock);

        // SECURITY: If a caller provides an existing balance, it must belong to this market.
        // This avoids silently returning/merging a balance from some other market with the same
        // AssetType/StableType (integration bug / confusing PTB chaining).
        if (option::is_some(&existing_balance_opt)) {
            let existing_market_id = conditional_balance::market_id(option::borrow(&existing_balance_opt));
            assert!(existing_market_id == market_id, EMarketMismatch);
        };

        // SECURITY: Guard against outcome_count > 255 before any u8 casts
        // This prevents silent truncation when creating ConditionalMarketBalance
        assert!(outcome_count <= 255, EOutcomeCountOverflow);

        (market_id, outcome_count, swaps_allowed)
    };

    if (!swaps_allowed) {
        return existing_balance_opt
    };

    // Compute optimal arbitrage only after lifecycle says conditional AMM access is valid.
    // (internal arbitrage doesn't charge fees - just moving liquidity between pools)
    let (arb_amount, is_cond_to_spot) = {
        let market_state = coin_escrow::get_market_state(escrow);
        let pools = market_state::borrow_amm_pools(market_state);
        let (arb_amount, is_cond_to_spot, _score) = arbitrage_math::compute_optimal_internal_rebalance(
            spot_pool,
            pools,
            0, // no hint
        );
        (arb_amount, is_cond_to_spot)
    };

    // If no profitable arbitrage found, return existing balance or None
    if (arb_amount == 0) {
        return existing_balance_opt
    };

    // Get spot pool reserves to check if we have enough
    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot_pool);

    // Execute arbitrage based on direction
    // is_cond_to_spot=true: Buy from conditional pools, recombine, sell to spot
    // is_cond_to_spot=false: Buy from spot, split, sell to conditional pools
    // Returns: (retained_system_dust_created, actual_input, actual_output)
    let (retained_system_dust_created, actual_input, actual_output) = if (is_cond_to_spot) {
        // Direction: Conditional price too LOW (cond asset is cheap)
        // Action: Buy asset from conditional pools using stable
        // Flow: spot stable → cond stable → cond asset → spot asset
        //
        // NOTE: arb_amount from arbitrage_math is optimal ASSET to buy
        // We need to calculate how much STABLE is required to buy that asset

        // Calculate stable needed to buy arb_amount asset from each pool.
        // Take max due to quantum model (same stable backs all outcomes).
        let stable_needed = {
            let market_state = coin_escrow::get_market_state(escrow);
            let pools = market_state::borrow_amm_pools(market_state);
            let cost = arbitrage_math::max_conditional_stable_cost(pools, arb_amount);
            if (cost == std::u128::max_value!() || cost > (std::u64::max_value!() as u128)) {
                return existing_balance_opt
            };
            (cost as u64)
        };

        // Safety check: spot pool needs enough stable
        if (spot_stable < stable_needed) {
            return existing_balance_opt
        };

        {
            let market_state = coin_escrow::get_market_state(escrow);
            let pools = market_state::borrow_amm_pools(market_state);
            let mut i = 0u64;
            while (i < outcome_count) {
                let (_cond_asset, cond_stable) = conditional_amm::get_reserves(&pools[i]);
                if (cond_stable > std::u64::max_value!() - stable_needed) {
                    return existing_balance_opt
                };
                i = i + 1;
            };
        };

        // If escrow cannot settle the recombined asset leg, skip maintenance rather
        // than bricking the user swap that triggered this best-effort rebalance.
        let (min_asset, has_dust) = {
            let market_state = coin_escrow::get_market_state(escrow);
            preview_system_rebalance_stable_to_asset(
                market_state::borrow_amm_pools(market_state),
                stable_needed,
            )
        };
        if (
                min_asset == 0 ||
                    coin_escrow::get_escrowed_asset_balance(escrow) < min_asset ||
                    coin_escrow::get_lp_deposited_stable(escrow) > std::u64::max_value!() - stable_needed ||
                    spot_asset > std::u64::max_value!() - min_asset ||
                    !can_account_system_rebalance_stable_to_asset(
                        escrow,
                    outcome_count,
                    stable_needed,
                    min_asset,
                )
        ) {
            return existing_balance_opt
        };

        // 1. Take stable from spot pool and deposit to escrow
        // CRITICAL: Must update supplies to maintain quantum invariant
        let stable_taken = unified_spot_pool::take_stable_for_arbitrage(spot_pool, stable_needed);
        coin_escrow::deposit_spot_liquidity(escrow, sui::balance::zero<AssetType>(), stable_taken, &auth);
        // Immediately decrement LP backing - arbitrage is internal, not LP deposit
        coin_escrow::decrement_lp_backing(escrow, 0, stable_needed, &auth);
        // Update supplies to maintain quantum invariant: OE[i] == supply[i] + wrapped[i]
        coin_escrow::increment_supplies_for_all_outcomes(escrow, 0, stable_needed, &auth);

        // 2-5. Do all pool operations in one block. We extract only the
        // recombinable tranche; any pool-specific excess stays in AMM reserves.
        {
            let market_state = coin_escrow::get_market_state_mut(escrow, &auth);

            // 2. Quantum split: inject stable into each conditional pool
            let mut i = 0u64;
            while (i < outcome_count) {
                let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
                conditional_amm::inject_reserves_for_arbitrage(pool, market_id, 0, stable_needed, &market_auth);
                i = i + 1;
            };

            // 3. Swap in each conditional pool: stable → asset
            // Use swap_from_injected to avoid double-counting (input already injected)
            i = 0;
            while (i < outcome_count) {
                let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
                conditional_amm::swap_from_injected_stable_to_asset(
                    pool,
                    market_id,
                    stable_needed,
                    min_asset,
                    clock,
                    &market_auth,
                );
                i = i + 1;
            };

            // 5. Quantum recombine: extract the same asset amount from each pool.
            i = 0;
            while (i < outcome_count) {
                let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
                conditional_amm::extract_reserves_for_arbitrage(pool, market_id, min_asset, 0, &market_auth);
                i = i + 1;
            };
        };

        // 6. Track per-outcome supply shift from conditional swaps.
        // The inject/swap/extract path only moves AMM reserve counters.
        // This applies the equivalent accounting for the recombinable tranche.
        {
            let mut i = 0u64;
            while (i < outcome_count) {
                coin_escrow::track_system_swap_stable_to_asset(
                    escrow, i, stable_needed, min_asset, &auth,
                );
                i = i + 1;
            };
        };

        // 7. Move the equal tranche into wrapped inventory for recombination.
        {
            let mut i = 0u64;
            while (i < outcome_count) {
                coin_escrow::decrement_supply_for_outcome(escrow, i, true, min_asset, &auth);
                coin_escrow::decrement_pool_claim(escrow, i, min_asset, 0, &auth);
                coin_escrow::increment_wrapped_balance(escrow, i, true, min_asset, &auth);
                i = i + 1;
            };
        };

        // 8. Recombine the equal tranche from wrapped inventory back to spot.
        {
            let mut i = 0u64;
            while (i < outcome_count) {
                coin_escrow::decrement_wrapped_balance(escrow, i, true, min_asset, &auth);
                coin_escrow::decrement_outcome_allocation(escrow, i, min_asset, 0, &auth);
                i = i + 1;
            };
        };
        let asset_coin = coin_escrow::withdraw_asset_balance(escrow, min_asset, ctx, &auth);
        unified_spot_pool::return_asset_from_arbitrage(spot_pool, coin::into_balance(asset_coin));

        (has_dust, stable_needed, min_asset)
    } else {
        // Direction: Spot price too LOW (spot asset is cheap)
        // Action: Sell asset from spot to conditional pools for stable
        // Flow: spot asset → cond asset → cond stable → spot stable

        // Safety check: spot pool needs enough asset
        if (spot_asset < arb_amount) {
            return existing_balance_opt
        };

        {
            let market_state = coin_escrow::get_market_state(escrow);
            let pools = market_state::borrow_amm_pools(market_state);
            let mut i = 0u64;
            while (i < outcome_count) {
                let (cond_asset, _cond_stable) = conditional_amm::get_reserves(&pools[i]);
                if (cond_asset > std::u64::max_value!() - arb_amount) {
                    return existing_balance_opt
                };
                i = i + 1;
            };
        };

        // If escrow cannot settle the recombined stable leg, skip maintenance rather
        // than bricking the user swap that triggered this best-effort rebalance.
        let (min_stable, has_dust) = {
            let market_state = coin_escrow::get_market_state(escrow);
            preview_system_rebalance_asset_to_stable(
                market_state::borrow_amm_pools(market_state),
                arb_amount,
            )
        };
        if (
                min_stable == 0 ||
                    coin_escrow::get_escrowed_stable_balance(escrow) < min_stable ||
                    coin_escrow::get_lp_deposited_asset(escrow) > std::u64::max_value!() - arb_amount ||
                    spot_stable > std::u64::max_value!() - min_stable ||
                    !can_account_system_rebalance_asset_to_stable(
                        escrow,
                    outcome_count,
                    arb_amount,
                    min_stable,
                )
        ) {
            return existing_balance_opt
        };

        // 1. Take asset from spot pool and deposit to escrow
        // CRITICAL: Must update supplies to maintain quantum invariant
        let asset_taken = unified_spot_pool::take_asset_for_arbitrage(spot_pool, arb_amount);
        coin_escrow::deposit_spot_liquidity(escrow, asset_taken, sui::balance::zero<StableType>(), &auth);
        // Immediately decrement LP backing - arbitrage is internal, not LP deposit
        coin_escrow::decrement_lp_backing(escrow, arb_amount, 0, &auth);
        // Update supplies to maintain quantum invariant: OE[i] == supply[i] + wrapped[i]
        coin_escrow::increment_supplies_for_all_outcomes(escrow, arb_amount, 0, &auth);

        // 2-5. Do all pool operations in one block. We extract only the
        // recombinable tranche; any pool-specific excess stays in AMM reserves.
        {
            let market_state = coin_escrow::get_market_state_mut(escrow, &auth);

            // 2. Quantum split: inject asset into each conditional pool
            let mut i = 0u64;
            while (i < outcome_count) {
                let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
                conditional_amm::inject_reserves_for_arbitrage(pool, market_id, arb_amount, 0, &market_auth);
                i = i + 1;
            };

            // 3. Swap in each conditional pool: asset → stable
            // Use swap_from_injected to avoid double-counting (input already injected)
            i = 0;
            while (i < outcome_count) {
                let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
                conditional_amm::swap_from_injected_asset_to_stable(
                    pool,
                    market_id,
                    arb_amount,
                    min_stable,
                    clock,
                    &market_auth,
                );
                i = i + 1;
            };

            // 5. Quantum recombine: extract the same stable amount from each pool.
            i = 0;
            while (i < outcome_count) {
                let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
                conditional_amm::extract_reserves_for_arbitrage(pool, market_id, 0, min_stable, &market_auth);
                i = i + 1;
            };
        };

        // 6. Track per-outcome supply shift from conditional swaps.
        // The inject/swap/extract path only moves AMM reserve counters.
        // This applies the equivalent accounting for the recombinable tranche.
        {
            let mut i = 0u64;
            while (i < outcome_count) {
                coin_escrow::track_system_swap_asset_to_stable(
                    escrow, i, arb_amount, min_stable, &auth,
                );
                i = i + 1;
            };
        };

        // 7. Move the equal tranche into wrapped inventory for recombination.
        {
            let mut i = 0u64;
            while (i < outcome_count) {
                coin_escrow::decrement_supply_for_outcome(escrow, i, false, min_stable, &auth);
                coin_escrow::decrement_pool_claim(escrow, i, 0, min_stable, &auth);
                coin_escrow::increment_wrapped_balance(escrow, i, false, min_stable, &auth);
                i = i + 1;
            };
        };

        // 8. Recombine the equal tranche from wrapped inventory back to spot.
        {
            let mut i = 0u64;
            while (i < outcome_count) {
                coin_escrow::decrement_wrapped_balance(escrow, i, false, min_stable, &auth);
                coin_escrow::decrement_outcome_allocation(escrow, i, 0, min_stable, &auth);
                i = i + 1;
            };
        };
        let stable_coin = coin_escrow::withdraw_stable_balance(escrow, min_stable, ctx, &auth);
        unified_spot_pool::return_stable_from_arbitrage(spot_pool, coin::into_balance(stable_coin));

        (has_dust, arb_amount, min_stable)
    };

    // Validate quantum invariant after arbitrage to catch any supply tracking errors
    coin_escrow::assert_quantum_invariant(escrow);

    // Update spot TWAP oracle so it reflects the new reserves after arbitrage.
    // Without this, the spot oracle stays stale until the next normal user swap.
    unified_spot_pool::update_twap_after_arbitrage(spot_pool, clock);

    // Emit event for indexers/debugging
    event::emit(SystemRebalanceExecuted {
        market_id,
        is_cond_to_spot,
        arb_amount_hint: arb_amount,
        actual_input,
        actual_output,
        retained_system_dust_created,
    });

    existing_balance_opt
}
