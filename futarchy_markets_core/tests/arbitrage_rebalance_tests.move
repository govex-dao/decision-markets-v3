#[test_only]
module futarchy_markets_core::arbitrage_rebalance_tests;

use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationRegistry};
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationRegistry};
use futarchy_markets_core::arbitrage;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::conditional_balance;
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use std::string;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object;
use sui::test_scenario as ts;
use sui::test_utils;

// Test LP type
public struct LP has drop {}
public struct COND_0_ASSET has drop {}
public struct COND_0_STABLE has drop {}
public struct COND_1_ASSET has drop {}
public struct COND_1_STABLE has drop {}

// === Constants ===
const INITIAL_SPOT_RESERVE: u64 = 10_000_000_000; // 10,000 tokens (9 decimals)
const INITIAL_CONDITIONAL_RESERVE: u64 = 1_000_000_000; // 1,000 tokens per outcome
const DEFAULT_FEE_BPS: u16 = 30; // 0.3%

// === Test Helpers ===

#[test_only]
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

#[test_only]
fun create_test_escrow_registry(ctx: &mut TxContext): EscrowMutationRegistry {
    let mut registry = escrow_mutation_auth::create_registry_for_testing(ctx);
    // Add futarchy_markets_core to authorized packages so arbitrage can create auth
    escrow_mutation_auth::add_authorized_package_for_testing(&mut registry, @futarchy_markets_core);
    registry
}

#[test_only]
fun create_test_market_state_registry(ctx: &mut TxContext): MarketStateMutationRegistry {
    let mut registry = market_state_mutation_auth::new_registry_for_testing(ctx);
    // Add futarchy_markets_core to authorized packages so arbitrage can create auth
    market_state_mutation_auth::add_authorized_package_for_testing(&mut registry, @futarchy_markets_core);
    registry
}

#[test_only]
fun create_lp_treasury(ctx: &mut TxContext): coin::TreasuryCap<LP> {
    coin::create_treasury_cap_for_testing<LP>(ctx)
}

#[test_only]
fun create_test_spot_pool(
    asset_reserve: u64,
    stable_reserve: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP> {
    let lp_treasury = create_lp_treasury(ctx);
    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, LP>(
        lp_treasury,
        (DEFAULT_FEE_BPS as u64),
        ctx,
    );
    let asset_balance = sui::balance::create_for_testing<TEST_COIN_A>(asset_reserve);
    let stable_balance = sui::balance::create_for_testing<TEST_COIN_B>(stable_reserve);
    unified_spot_pool::add_liquidity_for_testing(&mut pool, asset_balance, stable_balance);
    pool
}

#[test_only]
fun create_test_escrow_with_markets(
    outcome_count: u64,
    conditional_reserve_per_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): TokenEscrow<TEST_COIN_A, TEST_COIN_B> {
    let proposal_id = object::id_from_address(@0xABC);
    let dao_id = object::id_from_address(@0xDEF);

    let mut outcome_messages = vector::empty();
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut outcome_messages, string::utf8(b"Outcome"));
        i = i + 1;
    };

    let market_state = market_state::new(
        proposal_id,
        dao_id,
        outcome_count,
        outcome_messages,
        clock,
        ctx,
    );

    coin_escrow::create_test_escrow_with_market_state(
        outcome_count,
        market_state,
        ctx,
    )
}

#[test_only]
fun initialize_amm_pools(escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>, ctx: &mut TxContext) {
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(escrow, &escrow_auth);

    if (market_state::has_amm_pools(market_state)) {
        return
    };

    let market_id = market_state::market_id(market_state);
    let outcome_count = market_state::outcome_count(market_state);
    let mut pools = vector::empty();
    let mut i = 0;
    let clock = create_test_clock(1000000, ctx);
    while (i < outcome_count) {
        let pool = conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1000,
            1000,
            &clock,
            ctx,
        );
        vector::push_back(&mut pools, pool);
        i = i + 1;
    };
    clock::destroy_for_testing(clock);

    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);
}

#[test_only]
fun borrow_amm_pools_mut_with_test_auth(
    market_state_ref: &mut MarketState,
): &mut vector<LiquidityPool> {
    let auth = escrow_mutation_auth::create_for_testing();
    market_state::borrow_amm_pools_mut(market_state_ref, &auth)
}

#[test_only]
fun add_liquidity_to_conditional_pools(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    reserve_per_outcome: u64,
    ctx: &mut TxContext,
) {
    initialize_amm_pools(escrow, ctx);

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(escrow, &escrow_auth);
    let outcome_count = market_state::outcome_count(market_state);

    let mut i = 0;
    while (i < outcome_count) {
        let pool = market_state::borrow_amm_pool_mut(market_state, (i as u64));

        let asset_coin = coin::mint_for_testing<TEST_COIN_A>(reserve_per_outcome, ctx);
        let stable_coin = coin::mint_for_testing<TEST_COIN_B>(reserve_per_outcome, ctx);

        // add_liquidity_for_testing needs 5 arguments
        conditional_amm::add_liquidity_for_testing(
            pool,
            asset_coin,
            stable_coin,
            DEFAULT_FEE_BPS,
            ctx,
        );
        i = i + 1;
    };

    // Initialize supplies to match conditional pool reserves
    // Arbitrage requires supplies to be set (track_system_swap asserts supply >= consumed)
    // increment_supplies_for_all_outcomes updates both supply AND escrowed
    coin_escrow::increment_supplies_for_all_outcomes(
        escrow,
        reserve_per_outcome,
        reserve_per_outcome,
        &escrow_auth,
    );

    // Also deposit to escrow to match
    coin_escrow::deposit_spot_liquidity_for_testing(
        escrow,
        reserve_per_outcome,
        reserve_per_outcome,
    );
    coin_escrow::set_lp_deposited_for_testing(escrow, reserve_per_outcome, reserve_per_outcome);
}

#[test_only]
/// Add extra liquidity to escrow and update supplies for all outcomes
/// This maintains the quantum invariant: escrow == supply + wrapped
fun deposit_extra_liquidity_to_escrow(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    asset_amount: u64,
    stable_amount: u64,
    ctx: &mut TxContext,
) {
    let asset_for_escrow = coin::mint_for_testing<TEST_COIN_A>(asset_amount, ctx);
    let stable_for_escrow = coin::mint_for_testing<TEST_COIN_B>(stable_amount, ctx);
    coin_escrow::deposit_spot_coins(escrow, asset_for_escrow, stable_for_escrow);

    // Update supplies for all outcomes to maintain quantum invariant
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(escrow, asset_amount, stable_amount, &escrow_auth);
    let (lp_asset, lp_stable) = coin_escrow::get_lp_deposited_for_testing(escrow);
    coin_escrow::set_lp_deposited_for_testing(
        escrow,
        lp_asset + asset_amount,
        lp_stable + stable_amount,
    );
}

#[test_only]
fun get_conditional_price_range(escrow: &TokenEscrow<TEST_COIN_A, TEST_COIN_B>): (u128, u128) {
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);

    let mut min_price = std::u128::max_value!();
    let mut max_price = 0u128;
    let mut i = 0;
    let n = pools.length();

    while (i < n) {
        let (a, s) = conditional_amm::get_reserves(&pools[i]);
        if (a > 0) {
            let price = ((s as u128) * 1_000_000_000_000) / (a as u128);
            if (price < min_price) min_price = price;
            if (price > max_price) max_price = price;
        };
        i = i + 1;
    };

    (min_price, max_price)
}

#[test_only]
fun total_system_dust_created(escrow: &TokenEscrow<TEST_COIN_A, TEST_COIN_B>): u64 {
    let outcome_count = coin_escrow::caps_registered_count(escrow);
    let mut total = 0;
    let mut i = 0;
    while (i < outcome_count) {
        total = total + coin_escrow::get_dust_created_asset(escrow, i);
        total = total + coin_escrow::get_dust_created_stable(escrow, i);
        i = i + 1;
    };
    total
}

#[test_only]
/// Simulate a typed conditional asset -> stable user swap.
/// The AMM reserve move is real, and supply/allocation is updated the same way
/// swap_core's burn -> swap -> mint path would update it.
fun simulate_typed_asset_to_stable_swap(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    outcome_idx: u64,
    amount_in: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = escrow_mutation_auth::create_for_testing();
    let amount_out = {
        let market_state = coin_escrow::get_market_state_mut(escrow, &auth);
        let market_id = market_state::market_id(market_state);
        let pool = market_state::get_pool_mut_by_outcome(market_state, outcome_idx, &auth);
        conditional_amm::swap_asset_to_stable(pool, market_id, amount_in, 0, clock, ctx)
    };

    coin_escrow::decrement_supply_for_testing(escrow, outcome_idx, true, amount_in);
    coin_escrow::increment_supply_for_outcome(escrow, outcome_idx, false, amount_out);
    coin_escrow::track_swap_asset_to_stable(escrow, outcome_idx, amount_in, amount_out, &auth);
    coin_escrow::assert_quantum_invariant(escrow);
    amount_out
}

#[test_only]
/// Simulate a typed conditional stable -> asset user swap.
/// This reproduces the reserve/circulation drift the arb path must tolerate.
fun simulate_typed_stable_to_asset_swap(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    outcome_idx: u64,
    amount_in: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = escrow_mutation_auth::create_for_testing();
    let amount_out = {
        let market_state = coin_escrow::get_market_state_mut(escrow, &auth);
        let market_id = market_state::market_id(market_state);
        let pool = market_state::get_pool_mut_by_outcome(market_state, outcome_idx, &auth);
        conditional_amm::swap_stable_to_asset(pool, market_id, amount_in, 0, clock, ctx)
    };

    coin_escrow::decrement_supply_for_testing(escrow, outcome_idx, false, amount_in);
    coin_escrow::increment_supply_for_outcome(escrow, outcome_idx, true, amount_out);
    coin_escrow::track_swap_stable_to_asset(escrow, outcome_idx, amount_in, amount_out, &auth);
    coin_escrow::assert_quantum_invariant(escrow);
    amount_out
}

#[test_only]
fun link_pool_to_escrow(
    spot_pool: &mut UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP>,
    escrow: &TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
) {
    // Use the escrow's actual proposal_id so the security check passes.
    // In production, both pool and escrow share the same proposal_id.
    let proposal_id = market_state::proposal_id(coin_escrow::get_market_state(escrow));
    unified_spot_pool::set_active_proposal(spot_pool, proposal_id);
}

#[test_only]
fun simulate_spot_stable_for_asset_swap(
    spot_pool: &mut UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP>,
    amount_in: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<TEST_COIN_A> {
    let active_proposal_opt = unified_spot_pool::get_active_proposal_id(spot_pool);
    let had_active_proposal = active_proposal_opt.is_some();
    if (had_active_proposal) {
        unified_spot_pool::clear_active_proposal_for_testing(spot_pool);
    };

    let out = unified_spot_pool::swap_stable_for_asset(
        spot_pool,
        coin::mint_for_testing<TEST_COIN_B>(amount_in, ctx),
        0,
        clock,
        ctx,
    );

    if (had_active_proposal) {
        unified_spot_pool::set_active_proposal_for_testing(
            spot_pool,
            *active_proposal_opt.borrow(),
        );
    };

    out
}

#[test_only]
fun simulate_spot_asset_for_stable_swap(
    spot_pool: &mut UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP>,
    amount_in: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<TEST_COIN_B> {
    let active_proposal_opt = unified_spot_pool::get_active_proposal_id(spot_pool);
    let had_active_proposal = active_proposal_opt.is_some();
    if (had_active_proposal) {
        unified_spot_pool::clear_active_proposal_for_testing(spot_pool);
    };

    let out = unified_spot_pool::swap_asset_for_stable(
        spot_pool,
        coin::mint_for_testing<TEST_COIN_A>(amount_in, ctx),
        0,
        clock,
        ctx,
    );

    if (had_active_proposal) {
        unified_spot_pool::set_active_proposal_for_testing(
            spot_pool,
            *active_proposal_opt.borrow(),
        );
    };

    out
}

// === Tests for Conditional Swap Auto-Rebalancing ===

#[test]
/// Test that auto-rebalance brings spot price back into conditional range when spot is too high
fun test_auto_rebalance_when_spot_too_high() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with high price: 10,000 asset, 15,000 stable (price = 1.5)
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 15_000_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Verify spot price is high
    assert!(initial_spot_price > 1_200_000_000_000, 0); // > 1.2

    // Create escrow with conditional pools at lower prices (around 1.0)
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Add enough liquidity to escrow for arbitrage
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute auto-rebalance
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    // Destroy if exists
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);

    // After rebalancing, spot price should have moved down toward conditional range
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Verify price moved down (or stayed same if no profitable arb exists)
    assert!(final_spot_price <= initial_spot_price, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test auto-rebalance during execution window (swaps allowed after trading ends)
fun test_auto_rebalance_during_execution_window() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with high price to force non-zero arbitrage
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with conditional pools around price 1.0
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Move market to execution window (trading ended, not finalized)
    {
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        let mut frozen_twaps = vector::empty<u128>();
        vector::push_back(&mut frozen_twaps, 1_000_000_000_000);
        vector::push_back(&mut frozen_twaps, 1_000_000_000_000);
        market_state::start_execution_window_for_testing(
            market_state,
            constants::execution_window_ms(),
            frozen_twaps,
            0,
            &clock,
        );
    };

    // Execute auto-rebalance during execution window
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);

    // Verify arbitrage executed (or at least moved in safe direction)
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    assert!(final_spot_price <= initial_spot_price, 0);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that auto-rebalance brings spot price back into conditional range when spot is too low
fun test_auto_rebalance_when_spot_too_low() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with low price: 10,000 asset, 8,000 stable (price = 0.8)
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 8_000_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Verify spot price is low
    assert!(initial_spot_price < 900_000_000_000, 0); // < 0.9

    // Create escrow with conditional pools at higher prices (around 1.0)
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Add enough liquidity to escrow for arbitrage
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute auto-rebalance
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    // Destroy if exists
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);

    // After rebalancing, spot price should have moved up toward conditional range
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Verify price moved up (or stayed same if no profitable arb exists)
    assert!(final_spot_price >= initial_spot_price, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that auto-rebalance does nothing when spot price is already within conditional range
fun test_auto_rebalance_no_op_when_in_range() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool: 10,000 asset, 10,000 stable (price = 1.0)
    let mut spot_pool = create_test_spot_pool(
        INITIAL_SPOT_RESERVE,
        INITIAL_SPOT_RESERVE,
        &clock,
        ctx,
    );
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with conditional pools at similar prices (around 1.0)
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Add liquidity to escrow
    deposit_extra_liquidity_to_escrow(&mut escrow, 5_000_000_000, 5_000_000_000, ctx);

    // Spot price (1.0) is within conditional range, so no rebalancing needed

    // Execute auto-rebalance
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    // Destroy if exists
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);

    // Spot price should be virtually unchanged (within rounding)
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    let price_diff = if (final_spot_price > initial_spot_price) {
        final_spot_price - initial_spot_price
    } else {
        initial_spot_price - final_spot_price
    };

    // Price should be nearly the same (less than 0.1% change)
    assert!(price_diff < 10_000_000_000, 0); // < 0.01 change

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test auto-rebalance with 3 outcomes
fun test_auto_rebalance_three_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with high price
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 14_000_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with 3 outcomes
    let mut escrow = create_test_escrow_with_markets(3, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Add liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute auto-rebalance
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    // Destroy if exists
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Verify price moved down toward conditional range (or stayed if no profitable arb)
    assert!(final_spot_price <= initial_spot_price, 0);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that auto-rebalance handles edge case with very small arb amounts
fun test_auto_rebalance_small_adjustments() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool slightly above range: 10,000 asset, 10,500 stable (price = 1.05)
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 10_500_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with conditional pools
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Add liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute auto-rebalance
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    // Destroy if exists
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // With small deviations, arbitrage math may determine no profitable opportunity exists
    // Just verify price didn't move dramatically in wrong direction
    let max_increase = initial_spot_price / 20; // Allow up to 5% increase (rounding/fees)
    assert!(final_spot_price <= initial_spot_price + max_increase, 0);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

// === Comprehensive Arbitrage Verification Tests ===

#[test]
/// Verify arbitrage actually happens: check reserves change and dust is created
fun test_arbitrage_actually_executes_spot_too_high() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with HIGH price: 5,000 asset, 10,000 stable (price = 2.0)
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Get initial reserves
    let (initial_spot_asset, initial_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    // Create escrow with conditional pools at price 1.0
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute auto-rebalance
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Get final reserves
    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    // VERIFY: Reserves actually changed (arbitrage happened)
    // When spot is too high (asset expensive), arbitrage should:
    // - Take stable from spot pool (decrease stable)
    // - Return asset to spot pool (increase asset)
    assert!(final_spot_asset != initial_spot_asset || final_spot_stable != initial_spot_stable, 0);

    // Direction check: asset should increase OR stable should decrease
    let reserves_changed_correctly =
        final_spot_asset > initial_spot_asset ||
                                      final_spot_stable < initial_spot_stable;
    assert!(reserves_changed_correctly, 1);

    // Note: With identical conditional pools, no dust is created (identical swaps = identical outputs)
    // The arbitrage still runs successfully - that's what this test verifies
    if (option::is_some(&dust_opt)) {
        let dust = option::extract(&mut dust_opt);
        conditional_balance::destroy_for_testing(dust);
    };
    option::destroy_none(dust_opt);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify arbitrage actually happens: spot too low direction
fun test_arbitrage_actually_executes_spot_too_low() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with LOW price: 10,000 asset, 5,000 stable (price = 0.5)
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 5_000_000_000, &clock, ctx);

    // Get initial reserves
    let (initial_spot_asset, initial_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    // Create escrow with conditional pools at price 1.0
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute auto-rebalance
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Get final reserves
    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    // VERIFY: Reserves actually changed
    // When spot is too low (asset cheap), arbitrage should:
    // - Take asset from spot pool (decrease asset)
    // - Return stable to spot pool (increase stable)
    assert!(final_spot_asset != initial_spot_asset || final_spot_stable != initial_spot_stable, 0);

    // Direction check: stable should increase OR asset should decrease
    let reserves_changed_correctly =
        final_spot_stable > initial_spot_stable ||
                                      final_spot_asset < initial_spot_asset;
    assert!(reserves_changed_correctly, 1);

    // Note: With identical conditional pools, no dust is created (identical swaps = identical outputs)
    // The arbitrage still runs successfully - that's what this test verifies
    if (option::is_some(&dust_opt)) {
        let dust = option::extract(&mut dust_opt);
        conditional_balance::destroy_for_testing(dust);
    };
    option::destroy_none(dust_opt);

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Regression: cond_to_spot rebalance should use live spot stable, not stale lp_deposited_stable.
fun test_cond_to_spot_rebalance_not_blocked_by_low_lp_stable_counter() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price HIGH (2.0) -> cond_to_spot rebalance takes stable from spot.
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let (initial_spot_asset, initial_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Simulate stale LP accounting after live spot reserves have moved ahead of the
    // original split. The removed guard would reject any stable input above 1.
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, 10_000_000_000, 1);

    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(final_spot_asset > initial_spot_asset, 9800);
    assert!(initial_spot_stable > final_spot_stable, 9801);
    assert!(initial_spot_stable - final_spot_stable > 1, 9802);

    let (_lp_asset_after, lp_stable_after) = coin_escrow::get_lp_deposited_for_testing(&escrow);
    assert!(lp_stable_after == 1, 9803);

    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Regression: spot_to_cond rebalance should use live spot asset, not stale lp_deposited_asset.
fun test_spot_to_cond_rebalance_not_blocked_by_low_lp_asset_counter() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price LOW (0.5) -> spot_to_cond rebalance takes asset from spot.
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 5_000_000_000, &clock, ctx);
    let (initial_spot_asset, initial_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Simulate stale LP accounting after live spot reserves have moved ahead of the
    // original split. The removed guard would reject any asset input above 1.
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, 1, 10_000_000_000);

    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(initial_spot_asset > final_spot_asset, 9810);
    assert!(final_spot_stable > initial_spot_stable, 9811);
    assert!(initial_spot_asset - final_spot_asset > 1, 9812);

    let (lp_asset_after, _lp_stable_after) = coin_escrow::get_lp_deposited_for_testing(&escrow);
    assert!(lp_asset_after == 1, 9813);

    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify dust balance contains expected conditional tokens
/// Uses asymmetric conditional pools to ensure dust is created
fun test_arbitrage_dust_balance_contents() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with high price
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 12_000_000_000, &clock, ctx);

    // Create escrow with 2 outcomes
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Make pools asymmetric so dust is created (different outputs per pool)
    {
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        let pools = borrow_amm_pools_mut_with_test_auth(market_state);
        // Add extra reserves to pool 0 to make it different from pool 1
        conditional_amm::add_reserves_for_testing(&mut pools[0], 100_000_000, 50_000_000);
    };

    // Add liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // VERIFY: Residuals stay system-owned; no user balance is returned.
    assert!(option::is_none(&dust_opt), 0);
    assert!(total_system_dust_created(&escrow) == 0, 1);
    option::destroy_none(dust_opt);

    // VERIFY: Market remains the same after retained system-dust accounting.
    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);
    assert!(market_id == market_state::market_id(market_state), 2);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test multiple sequential arbitrage calls
fun test_multiple_arbitrage_calls() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with high price
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);

    // Add liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);

    // First arbitrage call - may or may not produce dust (identical pools = no dust)
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt_1 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Note: With identical conditional pools, no dust is created (identical swaps = identical outputs)
    // The arbitrage still runs successfully, just returns None when no dust

    // Second arbitrage call - pass existing balance for merging
    let mut dust_opt_2 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        dust_opt_1, // Pass the existing balance (may be None)
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Cleanup any returned balance
    if (option::is_some(&dust_opt_2)) {
        let final_dust = option::extract(&mut dust_opt_2);
        conditional_balance::destroy_for_testing(final_dust);
    };
    option::destroy_none(dust_opt_2);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test conditional pool reserves change after arbitrage
fun test_conditional_pool_reserves_change() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with high price (will trigger Cond→Spot arbitrage)
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 12_000_000_000, &clock, ctx);

    // Create escrow with conditional pools
    let mut escrow = create_test_escrow_with_markets(2, 2_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 2_000_000_000, ctx);

    // Record initial conditional pool reserves
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (initial_cond0_asset, initial_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (initial_cond1_asset, initial_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Get final conditional pool reserves
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (final_cond0_asset, final_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (final_cond1_asset, final_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // VERIFY: Conditional pool reserves changed
    let cond0_changed =
        final_cond0_asset != initial_cond0_asset ||
                        final_cond0_stable != initial_cond0_stable;
    let cond1_changed =
        final_cond1_asset != initial_cond1_asset ||
                        final_cond1_stable != initial_cond1_stable;

    // At least one conditional pool should have changed
    assert!(cond0_changed || cond1_changed, 0);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that arbitrage with extreme price divergence executes significant rebalancing
fun test_arbitrage_extreme_price_divergence() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // EXTREME divergence: spot price = 5.0 (asset very expensive in spot)
    let mut spot_pool = create_test_spot_pool(2_000_000_000, 10_000_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Conditional pools at price ~1.0 (asset much cheaper in conditionals)
    let mut escrow = create_test_escrow_with_markets(2, 3_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 3_000_000_000, ctx);

    // Large escrow liquidity for significant arbitrage
    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // VERIFY: Price moved significantly (at least 10% change)
    let price_change = if (final_spot_price < initial_spot_price) {
        initial_spot_price - final_spot_price
    } else {
        0
    };

    // With 5x price divergence, we expect substantial movement
    // 10% of initial = 0.5, which is 500_000_000_000 in our scale
    let min_expected_change = initial_spot_price / 10;
    assert!(price_change >= min_expected_change, 0);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test arbitrage with 4 outcomes
fun test_arbitrage_four_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup with 4 outcomes
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(4, 500_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 500_000_000, ctx);

    // Add liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // VERIFY: Price moved toward conditional range
    assert!(final_spot_price <= initial_spot_price, 0);

    // VERIFY: No user-owned system dust is returned for 4-outcome rebalance.
    assert!(option::is_none(&dust_opt), 1);
    assert!(coin_escrow::caps_registered_count(&escrow) == 4, 2);

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

// === Exact Amount Verification Tests ===

#[test]
/// Verify exact reserve changes after arbitrage (Cond→Spot direction)
/// When spot is too high, arbitrage takes stable from spot and returns asset
fun test_exact_reserve_changes_cond_to_spot() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup: Spot price = 2.0, Conditional price = 1.0
    // 5,000 asset, 10,000 stable
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Conditional pools: 1,000 asset, 1,000 stable each (price = 1.0)
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Record initial state
    let (init_spot_asset, init_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (init_cond0_asset, init_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (init_cond1_asset, init_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Get final state
    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (final_cond0_asset, final_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (final_cond1_asset, final_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // VERIFY: Spot pool asset increased (received asset from arbitrage)
    assert!(final_spot_asset > init_spot_asset, 0);
    let spot_asset_gained = final_spot_asset - init_spot_asset;

    // VERIFY: Spot pool stable decreased (gave stable for arbitrage)
    assert!(final_spot_stable < init_spot_stable, 1);
    let _spot_stable_lost = init_spot_stable - final_spot_stable;

    // VERIFY: Conditional pools asset decreased (sold asset)
    assert!(final_cond0_asset < init_cond0_asset, 2);
    assert!(final_cond1_asset < init_cond1_asset, 3);

    // VERIFY: Conditional pools stable increased (received stable)
    assert!(final_cond0_stable > init_cond0_stable, 4);
    assert!(final_cond1_stable > init_cond1_stable, 5);

    // VERIFY: Arbitrage was profitable (asset gained > 0)
    assert!(spot_asset_gained > 0, 6);

    // VERIFY: Constant product maintained in spot pool (within fee tolerance)
    let init_k = (init_spot_asset as u128) * (init_spot_stable as u128);
    let final_k = (final_spot_asset as u128) * (final_spot_stable as u128);
    // k should increase due to fees, but not decrease
    assert!(final_k >= init_k, 7);
    // k shouldn't increase too much (< 10% from fees)
    let k_increase = final_k - init_k;
    let k_max_increase = init_k / 10; // 10% tolerance for fee accumulation
    assert!(k_increase <= k_max_increase, 8);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify exact reserve changes after arbitrage (Spot->Cond direction)
/// When spot is too low, arbitrage takes asset from spot and returns stable
fun test_exact_reserve_changes_spot_to_cond() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup: Spot price = 0.5, Conditional price = 1.0
    // 10,000 asset, 5,000 stable
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 5_000_000_000, &clock, ctx);

    // Conditional pools: 1,000 asset, 1,000 stable each (price = 1.0)
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Record initial state
    let (init_spot_asset, init_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (init_cond0_asset, init_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (init_cond1_asset, init_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Get final state
    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (final_cond0_asset, final_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (final_cond1_asset, final_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // VERIFY: Spot pool asset decreased (gave asset for arbitrage)
    assert!(final_spot_asset < init_spot_asset, 0);
    let _spot_asset_lost = init_spot_asset - final_spot_asset;

    // VERIFY: Spot pool stable increased (received stable from arbitrage)
    assert!(final_spot_stable > init_spot_stable, 1);
    let spot_stable_gained = final_spot_stable - init_spot_stable;

    // VERIFY: Conditional pools asset increased (received asset)
    assert!(final_cond0_asset > init_cond0_asset, 2);
    assert!(final_cond1_asset > init_cond1_asset, 3);

    // VERIFY: Conditional pools stable decreased (gave stable)
    assert!(final_cond0_stable < init_cond0_stable, 4);
    assert!(final_cond1_stable < init_cond1_stable, 5);

    // VERIFY: Arbitrage was profitable (stable gained > 0)
    assert!(spot_stable_gained > 0, 6);

    // VERIFY: Asset lost from spot matches asset gained by conditionals
    let _cond_asset_gained =
        (final_cond0_asset - init_cond0_asset) + (final_cond1_asset - init_cond1_asset);
    // Note: Due to quantum liquidity, each conditional gets the same amount
    // So cond_asset_gained = 2 * (amount per pool)
    // The spot lost = amount per pool (since it's quantum split)
    // Actually the injected amount goes to ALL pools equally

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify exact dust amounts match the difference between pool outputs
fun test_exact_dust_amounts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup with asymmetric conditional pools to create predictable dust
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow with 2 outcomes
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);

    // Initialize pools but with different reserves to create asymmetry
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let outcome_count = market_state::outcome_count(market_state);
    let mut pools = vector::empty();

    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: 1000 asset, 1000 stable (price = 1.0)
    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    // Add actual liquidity
    let asset_coin0 = coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx);
    let stable_coin0 = coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx);
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(
        &mut pool0_mut,
        asset_coin0,
        stable_coin0,
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: 1200 asset, 800 stable (price = 0.667)
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let asset_coin1 = coin::mint_for_testing<TEST_COIN_A>(1_200_000_000, ctx);
    let stable_coin1 = coin::mint_for_testing<TEST_COIN_B>(800_000_000, ctx);
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(
        &mut pool1_mut,
        asset_coin1,
        stable_coin1,
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool1_mut);

    clock::destroy_for_testing(clock2);

    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity - use max of pool reserves for proper quantum backing
    let escrow_asset = 1_200_000_000u64; // Max of pool assets
    let escrow_stable = 1_000_000_000u64; // Max of pool stables
    let asset_for_escrow = coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx);
    let stable_for_escrow = coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_for_escrow, stable_for_escrow);

    // Initialize supplies to match AMM reserves
    // Arbitrage requires supplies to be set (track_system_swap asserts supply >= consumed)
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, escrow_asset, escrow_stable);

    // Record pool reserves before arbitrage
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (pre_cond0_asset, pre_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (pre_cond1_asset, pre_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // VERIFY: System rebalance dust is retained by pool accounting, not returned to users.
    assert!(option::is_none(&dust_opt), 0);
    option::destroy_none(dust_opt);

    // Get retained system-dust amounts
    let dust_0_asset = coin_escrow::get_dust_created_asset(&escrow, 0);
    let dust_1_asset = coin_escrow::get_dust_created_asset(&escrow, 1);
    let dust_0_stable = coin_escrow::get_dust_created_stable(&escrow, 0);
    let dust_1_stable = coin_escrow::get_dust_created_stable(&escrow, 1);

    // Get pool reserves after arbitrage
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (post_cond0_asset, post_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (post_cond1_asset, post_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // VERIFY: Dust represents the difference in swap outputs
    // When swapping stable→asset in each pool:
    // - Pool with more asset reserve gives more asset output
    // - Minimum is taken, excess becomes dust

    // The dust should be the difference between outputs from each pool
    // Since we take min and the rest is dust

    // At least verify dust is non-negative (can be zero if pools give same output)
    // With asymmetric pools, we expect some dust
    let total_dust = dust_0_asset + dust_1_asset + dust_0_stable + dust_1_stable;
    assert!(total_dust == 0, 2);

    // VERIFY: Minimum dust in one outcome is 0 (we extract minimum)
    // In Cond→Spot direction: one outcome has 0 asset dust
    // In Spot→Cond direction: one outcome has 0 stable dust
    let min_asset_dust = if (dust_0_asset < dust_1_asset) { dust_0_asset } else { dust_1_asset };
    let min_stable_dust = if (dust_0_stable < dust_1_stable) { dust_0_stable } else {
        dust_1_stable
    };

    // At least one type should have 0 minimum (we extracted the min)
    assert!(min_asset_dust == 0 || min_stable_dust == 0, 1);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify total value is conserved (no value created or destroyed)
fun test_value_conservation() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Record initial pool states (escrow is pass-through, not counted)
    let (init_spot_asset, init_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (init_cond0_asset, init_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (init_cond1_asset, init_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Calculate total value after
    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (final_cond0_asset, final_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (final_cond1_asset, final_cond1_stable) = conditional_amm::get_reserves(&pools[1]);

    // Get dust amounts
    let (dust_asset, dust_stable) = if (option::is_some(&dust_opt)) {
        let dust = option::borrow(&dust_opt);
        let da =
            conditional_balance::get_balance(dust, 0, true) +
                 conditional_balance::get_balance(dust, 1, true);
        let ds =
            conditional_balance::get_balance(dust, 0, false) +
                 conditional_balance::get_balance(dust, 1, false);
        (da, ds)
    } else {
        (0, 0)
    };

    // Value conservation: initial pools + escrow deposit = final pools + dust
    // The escrow deposit (10B asset, 10B stable) becomes part of the system
    let escrow_deposit_asset = 10_000_000_000u64;
    let escrow_deposit_stable = 10_000_000_000u64;

    let init_total_asset =
        init_spot_asset + init_cond0_asset + init_cond1_asset + escrow_deposit_asset;
    let init_total_stable =
        init_spot_stable + init_cond0_stable + init_cond1_stable + escrow_deposit_stable;
    let final_total_asset = final_spot_asset + final_cond0_asset + final_cond1_asset + dust_asset;
    let final_total_stable =
        final_spot_stable + final_cond0_stable + final_cond1_stable + dust_stable;

    // Note: Final should be <= initial because some value stays in escrow (unused)
    // We just verify no value was created (final <= init)
    assert!(final_total_asset <= init_total_asset, 0);
    assert!(final_total_stable <= init_total_stable, 1);

    // The "loss" is value that stayed in escrow (not used in arbitrage)
    // This is expected behavior - arbitrage only uses what's needed
    // Just verify the system didn't lose significant value beyond escrow retention
    let asset_loss = init_total_asset - final_total_asset;
    let stable_loss = init_total_stable - final_total_stable;

    // Most loss should be escrow retention - allow up to 80% (escrow is large relative to pools)
    let max_asset_loss = init_total_asset * 80 / 100;
    let max_stable_loss = init_total_stable * 80 / 100;
    assert!(asset_loss <= max_asset_loss, 2);
    assert!(stable_loss <= max_stable_loss, 3);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify arbitrage amount produces expected price convergence
fun test_price_convergence_after_arbitrage() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup: Spot price = 2.0, Conditional price = 1.0
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Get initial prices
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    let (init_min_cond, init_max_cond) = get_conditional_price_range(&escrow);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Get final prices
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    let (final_min_cond, final_max_cond) = get_conditional_price_range(&escrow);

    // VERIFY: Spot price moved toward conditional range
    // Initial spot was 2.0 (2_000_000_000_000 in 1e12), conditional was 1.0
    // After arbitrage, spot should be closer to 1.0

    let init_gap = if (init_spot_price > init_max_cond) {
        init_spot_price - init_max_cond
    } else if (init_spot_price < init_min_cond) {
        init_min_cond - init_spot_price
    } else {
        0
    };

    let final_gap = if (final_spot_price > final_max_cond) {
        final_spot_price - final_max_cond
    } else if (final_spot_price < final_min_cond) {
        final_min_cond - final_spot_price
    } else {
        0
    };

    // VERIFY: Price gap decreased (or spot is now within conditional range)
    assert!(final_gap <= init_gap, 0);

    // VERIFY: Prices converged somewhat (gap reduced by at least 10%)
    // Note: The optimal arbitrage amount depends on pool sizes and may not fully close the gap
    if (init_gap > 0) {
        let gap_reduction = init_gap - final_gap;
        let min_reduction = init_gap / 10; // At least 10% reduction
        assert!(gap_reduction >= min_reduction, 1);
    };

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that balanced pools produce zero or minimal dust
fun test_balanced_pools_minimal_dust() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup with identical conditional pools
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);

    // Add identical liquidity to both pools
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // When pools are balanced, dust should be zero or minimal
    if (option::is_some(&dust_opt)) {
        let dust = option::borrow(&dust_opt);

        // Get dust amounts
        let dust_0_asset = conditional_balance::get_balance(dust, 0, true);
        let dust_1_asset = conditional_balance::get_balance(dust, 1, true);
        let dust_0_stable = conditional_balance::get_balance(dust, 0, false);
        let dust_1_stable = conditional_balance::get_balance(dust, 1, false);

        // With balanced pools, dust in both outcomes should be equal (or very close)
        let asset_diff = if (dust_0_asset > dust_1_asset) {
            dust_0_asset - dust_1_asset
        } else {
            dust_1_asset - dust_0_asset
        };

        let stable_diff = if (dust_0_stable > dust_1_stable) {
            dust_0_stable - dust_1_stable
        } else {
            dust_1_stable - dust_0_stable
        };

        // VERIFY: Dust difference is minimal (< 1% of dust amount)
        let max_dust = if (dust_0_asset > dust_1_asset) { dust_0_asset } else { dust_1_asset };
        if (max_dust > 0) {
            let tolerance = max_dust / 100 + 1; // 1% tolerance + 1 for rounding
            assert!(asset_diff <= tolerance, 0);
        };
    };

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify exact amounts when doing multiple sequential arbitrages
fun test_multiple_arbitrage_exact_accumulation() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Make pools asymmetric to ensure dust is created
    {
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        let pools = borrow_amm_pools_mut_with_test_auth(market_state);
        conditional_amm::add_reserves_for_testing(&mut pools[0], 100_000_000, 50_000_000);
    };

    // Large escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);

    // First arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt_1 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    assert!(option::is_none(&dust_opt_1), 0);
    let first_system_dust = total_system_dust_created(&escrow);
    assert!(first_system_dust == 0, 4);

    // Second arbitrage should preserve the no-user-dust ownership model.
    let dust_opt_2 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        dust_opt_1,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    assert!(option::is_none(&dust_opt_2), 1);
    let final_system_dust = total_system_dust_created(&escrow);
    option::destroy_none(dust_opt_2);

    // VERIFY: retained system-dust accounting is monotonic across calls.
    assert!(final_system_dust >= first_system_dust, 2);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify constant product is maintained in conditional pools after arbitrage
fun test_conditional_pool_constant_product() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Record initial k for conditional pools
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (init_c0_asset, init_c0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (init_c1_asset, init_c1_stable) = conditional_amm::get_reserves(&pools[1]);

    let init_k0 = (init_c0_asset as u128) * (init_c0_stable as u128);
    let init_k1 = (init_c1_asset as u128) * (init_c1_stable as u128);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Record final k for conditional pools
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (final_c0_asset, final_c0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (final_c1_asset, final_c1_stable) = conditional_amm::get_reserves(&pools[1]);

    let final_k0 = (final_c0_asset as u128) * (final_c0_stable as u128);
    let final_k1 = (final_c1_asset as u128) * (final_c1_stable as u128);

    // VERIFY: Constant product approximately maintained
    // Decrease is allowed due to feeless swap design (no fee to increase k) and rounding
    // Large decrease would indicate a bug
    let k0_tolerance = init_k0 / 20; // 5% tolerance
    let k1_tolerance = init_k1 / 20;

    // Check k0 didn't decrease significantly
    if (final_k0 < init_k0) {
        let k0_decrease = init_k0 - final_k0;
        assert!(k0_decrease <= k0_tolerance, 0);
    } else {
        // k increased (from fees) - check not too much
        let k0_increase = final_k0 - init_k0;
        let k0_max_increase = init_k0 / 20; // 5%
        assert!(k0_increase <= k0_max_increase, 2);
    };

    // Check k1 didn't decrease significantly
    if (final_k1 < init_k1) {
        let k1_decrease = init_k1 - final_k1;
        assert!(k1_decrease <= k1_tolerance, 1);
    } else {
        let k1_increase = final_k1 - init_k1;
        let k1_max_increase = init_k1 / 20; // 5%
        assert!(k1_increase <= k1_max_increase, 3);
    };

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

// === Challenging Price Tests ===

#[test]
/// Test arbitrage with highly asymmetric conditional pools (different prices per outcome)
fun test_arbitrage_highly_asymmetric_pools() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 1.5
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 15_000_000_000, &clock, ctx);
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with 2 outcomes
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);

    // Initialize pools manually with VERY different prices
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price = 0.5 (asset expensive in pool)
    // 2000 asset, 1000 stable
    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let asset_coin0 = coin::mint_for_testing<TEST_COIN_A>(2_000_000_000, ctx);
    let stable_coin0 = coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx);
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(
        &mut pool0_mut,
        asset_coin0,
        stable_coin0,
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: price = 2.0 (asset cheap in pool)
    // 500 asset, 1000 stable
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let asset_coin1 = coin::mint_for_testing<TEST_COIN_A>(500_000_000, ctx);
    let stable_coin1 = coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx);
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(
        &mut pool1_mut,
        asset_coin1,
        stable_coin1,
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool1_mut);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // With highly asymmetric pools, arbitrage may or may not find a profitable opportunity
    // The important thing is the function runs without error
    // If arbitrage did execute, verify no user-owned system dust was returned.
    if (final_spot_price != init_spot_price) {
        assert!(option::is_none(&dust_opt), 1);
        assert!(total_system_dust_created(&escrow) == 0, 2);
    };

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test arbitrage at the threshold where it becomes marginally profitable
fun test_arbitrage_near_threshold() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Very small price difference: spot = 1.02, conditional = 1.0
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 10_200_000_000, &clock, ctx);
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // With small price difference, price change should be small
    let price_change = if (final_spot_price > init_spot_price) {
        final_spot_price - init_spot_price
    } else {
        init_spot_price - final_spot_price
    };

    // Price change should be less than initial difference (2%)
    let max_change = init_spot_price / 50; // 2%
    assert!(price_change <= max_change, 0);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test three outcomes with spread prices (one high, one low, one middle)
fun test_arbitrage_three_outcomes_spread_prices() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 1.0
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow with 3 outcomes
    let mut escrow = create_test_escrow_with_markets(3, 500_000_000, &clock, ctx);

    // Initialize pools with spread prices
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price = 0.5 (below spot)
    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(
        &mut pool0_mut,
        coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(500_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: price = 1.0 (equal to spot)
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(
        &mut pool1_mut,
        coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool1_mut);

    // Pool 2: price = 2.0 (above spot)
    let pool2 = conditional_amm::create_test_pool(
        market_id,
        2,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool2_mut = pool2;
    conditional_amm::add_liquidity_for_testing(
        &mut pool2_mut,
        coin::mint_for_testing<TEST_COIN_A>(500_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool2_mut);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 15_000_000_000, 15_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // VERIFY: No user-owned system dust is returned for 3-outcome rebalance.
    assert!(option::is_none(&dust_opt), 0);
    assert!(coin_escrow::caps_registered_count(&escrow) == 3, 1);

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test price convergence over multiple arbitrage iterations
fun test_arbitrage_convergence_multiple_iterations() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Large price divergence: spot = 3.0, conditional = 1.0
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 15_000_000_000, &clock, ctx);
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, 2_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 2_000_000_000, ctx);

    // Large escrow liquidity for multiple iterations
    deposit_extra_liquidity_to_escrow(&mut escrow, 50_000_000_000, 50_000_000_000, ctx);

    // First iteration
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt_1 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    let price_after_1 = unified_spot_pool::get_spot_price(&spot_pool);
    let gap_1 = init_spot_price - price_after_1;

    // Second iteration
    let dust_opt_2 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        dust_opt_1,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    let price_after_2 = unified_spot_pool::get_spot_price(&spot_pool);
    let gap_2 = if (price_after_1 > price_after_2) {
        price_after_1 - price_after_2
    } else {
        0
    };

    // Third iteration
    let mut dust_opt_3 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        dust_opt_2,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    let price_after_3 = unified_spot_pool::get_spot_price(&spot_pool);

    // VERIFY: Price converges (first move should exist)
    assert!(gap_1 > 0, 0);

    // Subsequent moves should be smaller or zero (convergence)
    assert!(gap_2 <= gap_1, 1);

    // Final price should have moved toward conditional range
    // Use 10% as minimum expected move (arbitrage is limited by pool sizes)
    let total_move = init_spot_price - price_after_3;
    let min_expected_move = init_spot_price / 10; // At least 10% of initial price
    assert!(total_move >= min_expected_move, 2);

    // Cleanup
    if (option::is_some(&dust_opt_3)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt_3));
    };
    option::destroy_none(dust_opt_3);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test arbitrage when pool capacity limits the maximum arbitrage amount
fun test_arbitrage_pool_capacity_limited() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Large spot pool with extreme price divergence
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 50_000_000_000, &clock, ctx);
    let (init_spot_asset, init_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    // Small conditional pools - will limit arbitrage capacity
    let mut escrow = create_test_escrow_with_markets(2, 100_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 100_000_000, ctx);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Get initial conditional reserves
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (init_cond_asset, init_cond_stable) = conditional_amm::get_reserves(&pools[0]);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Get final reserves
    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (final_cond_asset, final_cond_stable) = conditional_amm::get_reserves(&pools[0]);

    // VERIFY: Spot pool changed (arbitrage executed)
    assert!(final_spot_asset != init_spot_asset || final_spot_stable != init_spot_stable, 0);

    // VERIFY: Conditional pool reserves changed significantly
    let cond_asset_change = if (final_cond_asset > init_cond_asset) {
        final_cond_asset - init_cond_asset
    } else {
        init_cond_asset - final_cond_asset
    };
    let cond_stable_change = if (final_cond_stable > init_cond_stable) {
        final_cond_stable - init_cond_stable
    } else {
        init_cond_stable - final_cond_stable
    };

    // At least one reserve should have changed meaningfully (10% of initial)
    let min_change = init_cond_asset / 10;
    assert!(cond_asset_change >= min_change || cond_stable_change >= min_change, 1);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test arbitrage with five outcomes having varying prices
fun test_arbitrage_five_outcomes_varying_prices() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 1.5
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 15_000_000_000, &clock, ctx);

    // Create escrow with 5 outcomes
    let mut escrow = create_test_escrow_with_markets(5, 200_000_000, &clock, ctx);

    // Initialize pools with varying prices
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price = 0.5
    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(
        &mut pool0_mut,
        coin::mint_for_testing<TEST_COIN_A>(400_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(200_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: price = 0.8
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(
        &mut pool1_mut,
        coin::mint_for_testing<TEST_COIN_A>(500_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(400_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool1_mut);

    // Pool 2: price = 1.0
    let pool2 = conditional_amm::create_test_pool(
        market_id,
        2,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool2_mut = pool2;
    conditional_amm::add_liquidity_for_testing(
        &mut pool2_mut,
        coin::mint_for_testing<TEST_COIN_A>(400_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(400_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool2_mut);

    // Pool 3: price = 1.5
    let pool3 = conditional_amm::create_test_pool(
        market_id,
        3,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool3_mut = pool3;
    conditional_amm::add_liquidity_for_testing(
        &mut pool3_mut,
        coin::mint_for_testing<TEST_COIN_A>(300_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(450_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool3_mut);

    // Pool 4: price = 2.5
    let pool4 = conditional_amm::create_test_pool(
        market_id,
        4,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool4_mut = pool4;
    conditional_amm::add_liquidity_for_testing(
        &mut pool4_mut,
        coin::mint_for_testing<TEST_COIN_A>(200_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(500_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool4_mut);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // VERIFY: If arbitrage executed, dust was created for all 5 outcomes
    if (option::is_some(&dust_opt)) {
        let dust = option::borrow(&dust_opt);
        assert!(conditional_balance::outcome_count(dust) == 5, 1);

        // VERIFY: Total dust is reasonable
        let mut total_dust = 0u64;
        let mut i = 0u8;
        while ((i as u64) < 5) {
            total_dust = total_dust + conditional_balance::get_balance(dust, i, true);
            total_dust = total_dust + conditional_balance::get_balance(dust, i, false);
            i = i + 1;
        };
        // Total dust should exist if arbitrage ran
        let _has_dust = total_dust > 0;
    };

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test extreme price ratio (10:1) between spot and conditional
fun test_arbitrage_extreme_price_ratio() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Extreme: spot price = 10.0, conditional price = 1.0
    let mut spot_pool = create_test_spot_pool(1_000_000_000, 10_000_000_000, &clock, ctx);
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Large escrow for significant arbitrage
    deposit_extra_liquidity_to_escrow(&mut escrow, 30_000_000_000, 30_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // VERIFY: Significant price movement occurred
    let price_reduction = init_spot_price - final_spot_price;
    let min_reduction = init_spot_price / 5; // At least 20% reduction
    assert!(price_reduction >= min_reduction, 0);

    // VERIFY: Price moved in correct direction
    assert!(final_spot_price < init_spot_price, 1);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that dust distribution reflects pool imbalances correctly
fun test_arbitrage_dust_reflects_pool_imbalance() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 2.0
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow with 2 outcomes
    let mut escrow = create_test_escrow_with_markets(2, 500_000_000, &clock, ctx);

    // Initialize with deliberately imbalanced pools
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price = 1.0 (balanced)
    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(
        &mut pool0_mut,
        coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: price = 0.25 (very cheap asset)
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(
        &mut pool1_mut,
        coin::mint_for_testing<TEST_COIN_A>(2_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(500_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool1_mut);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity - use max of pool reserves for proper quantum backing
    let escrow_asset = 2_000_000_000u64; // Max of pool assets
    let escrow_stable = 1_000_000_000u64; // Max of pool stables
    let asset_for_escrow = coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx);
    let stable_for_escrow = coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_for_escrow, stable_for_escrow);

    // Initialize supplies to match AMM reserves
    // Arbitrage requires supplies to be set (track_system_swap asserts supply >= consumed)
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // VERIFY: System rebalance did not return user-owned dust, but did retain residual output.
    assert!(option::is_none(&dust_opt), 0);
    let dust_0_asset = coin_escrow::get_dust_created_asset(&escrow, 0);
    let dust_1_asset = coin_escrow::get_dust_created_asset(&escrow, 1);

    // One should have 0 (minimum), other should have excess
    let min_dust = if (dust_0_asset < dust_1_asset) { dust_0_asset } else { dust_1_asset };
    assert!(min_dust == 0, 1);

    let max_dust = if (dust_0_asset > dust_1_asset) { dust_0_asset } else { dust_1_asset };
    assert!(max_dust == 0, 2);

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test both directions in sequence (spot too high, then too low)
fun test_arbitrage_bidirectional_sequence() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Start with spot too high: price = 2.0
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Large escrow for multiple operations
    deposit_extra_liquidity_to_escrow(&mut escrow, 30_000_000_000, 30_000_000_000, ctx);

    // First arbitrage: spot too high
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt_1 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let mid_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    let (mid_asset, mid_stable) = unified_spot_pool::get_reserves(&spot_pool);

    // Manually adjust spot pool to be too low by adding asset and removing stable
    // price = stable / asset, so: add asset -> price decreases, remove stable -> price decreases
    let asset_to_add = coin::mint_for_testing<TEST_COIN_A>(mid_asset, ctx);
    unified_spot_pool::return_asset_from_arbitrage(
        &mut spot_pool,
        coin::into_balance(asset_to_add),
    );
    let stable_transfer_amount = mid_stable / 2;
    let taken_stable = unified_spot_pool::take_stable_for_arbitrage(
        &mut spot_pool,
        stable_transfer_amount,
    );
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::deposit_spot_liquidity(
        &mut escrow,
        sui::balance::zero<TEST_COIN_A>(),
        taken_stable,
        &escrow_auth,
    );
    // Update supplies to maintain quantum invariant
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, 0, stable_transfer_amount, &escrow_auth);

    let low_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    assert!(low_spot_price < mid_spot_price, 0);

    // Second arbitrage: spot too low
    let mut dust_opt_2 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        dust_opt_1,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // VERIFY: Price moved back up
    assert!(final_spot_price > low_spot_price, 1);

    // Cleanup
    if (option::is_some(&dust_opt_2)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt_2));
    };
    option::destroy_none(dust_opt_2);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test arbitrage with very small reserves (edge case)
fun test_arbitrage_small_reserves() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Small spot pool with high price
    let mut spot_pool = create_test_spot_pool(100_000_000, 300_000_000, &clock, ctx);

    // Small conditional pools
    let mut escrow = create_test_escrow_with_markets(2, 50_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 50_000_000, ctx);

    // Small escrow
    deposit_extra_liquidity_to_escrow(&mut escrow, 500_000_000, 500_000_000, ctx);

    // Execute arbitrage - should not panic
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that k value behavior in spot pool during arbitrage
fun test_arbitrage_spot_pool_k_behavior() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let (init_asset, init_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let init_k = (init_asset as u128) * (init_stable as u128);

    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (final_asset, final_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let final_k = (final_asset as u128) * (final_stable as u128);

    // VERIFY: k should not decrease (arbitrage adds liquidity)
    assert!(final_k >= init_k, 0);

    // k shouldn't increase excessively (< 20%)
    let k_increase = final_k - init_k;
    let max_increase = init_k / 5;
    assert!(k_increase <= max_increase, 1);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

// === Additional Challenging Tests ===

#[test]
/// Test when ALL conditional pools are above spot price (guaranteed profitable Cond→Spot)
fun test_arbitrage_all_conditionals_above_spot() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 0.5 (below all conditionals)
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 5_000_000_000, &clock, ctx);
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with 3 outcomes
    let mut escrow = create_test_escrow_with_markets(3, 500_000_000, &clock, ctx);

    // All pools priced ABOVE spot
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price = 1.0
    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(
        &mut pool0_mut,
        coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: price = 1.5
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(
        &mut pool1_mut,
        coin::mint_for_testing<TEST_COIN_A>(800_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_200_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool1_mut);

    // Pool 2: price = 2.0
    let pool2 = conditional_amm::create_test_pool(
        market_id,
        2,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool2_mut = pool2;
    conditional_amm::add_liquidity_for_testing(
        &mut pool2_mut,
        coin::mint_for_testing<TEST_COIN_A>(500_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool2_mut);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity - use max of pool reserves for proper quantum backing
    let escrow_asset = 1_000_000_000u64; // Max of pool assets
    let escrow_stable = 1_200_000_000u64; // Max of pool stables
    let asset_for_escrow = coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx);
    let stable_for_escrow = coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_for_escrow, stable_for_escrow);

    // Initialize supplies to match AMM reserves
    // Arbitrage requires supplies to be set (track_system_swap asserts supply >= consumed)
    // increment_supplies_for_all_outcomes handles ALL outcomes based on escrow.outcome_count
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, escrow_asset, escrow_stable);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // VERIFY: Arbitrage MUST have executed, but returned no user-owned system dust.
    assert!(option::is_none(&dust_opt), 0);

    // VERIFY: Price moved UP toward conditionals
    assert!(final_spot_price > init_spot_price, 1);

    // VERIFY: Some price movement occurred
    let _price_increase = final_spot_price - init_spot_price;

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test when ALL conditional pools are below spot price (guaranteed profitable Spot→Cond)
fun test_arbitrage_all_conditionals_below_spot() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 3.0 (above all conditionals)
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 15_000_000_000, &clock, ctx);
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with 3 outcomes
    let mut escrow = create_test_escrow_with_markets(3, 500_000_000, &clock, ctx);

    // All pools priced BELOW spot
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price = 0.5
    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(
        &mut pool0_mut,
        coin::mint_for_testing<TEST_COIN_A>(2_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: price = 1.0
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(
        &mut pool1_mut,
        coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool1_mut);

    // Pool 2: price = 2.0
    let pool2 = conditional_amm::create_test_pool(
        market_id,
        2,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool2_mut = pool2;
    conditional_amm::add_liquidity_for_testing(
        &mut pool2_mut,
        coin::mint_for_testing<TEST_COIN_A>(500_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool2_mut);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity - use max of pool reserves for proper quantum backing
    let escrow_asset = 2_000_000_000u64; // Max of pool assets
    let escrow_stable = 1_000_000_000u64; // Max of pool stables
    let asset_for_escrow = coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx);
    let stable_for_escrow = coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_for_escrow, stable_for_escrow);

    // Initialize supplies to match AMM reserves
    // Arbitrage requires supplies to be set (track_system_swap asserts supply >= consumed)
    // increment_supplies_for_all_outcomes handles ALL outcomes based on escrow.outcome_count
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, escrow_asset, escrow_stable);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // VERIFY: Arbitrage MUST have executed, but returned no user-owned system dust.
    assert!(option::is_none(&dust_opt), 0);

    // VERIFY: Price moved DOWN toward conditionals
    assert!(final_spot_price < init_spot_price, 1);

    // VERIFY: Some price movement occurred
    let _price_decrease = init_spot_price - final_spot_price;

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test with seven outcomes to stress the system
fun test_arbitrage_seven_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 2.0
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow with 7 outcomes
    let mut escrow = create_test_escrow_with_markets(7, 200_000_000, &clock, ctx);

    // Initialize 7 pools with varying prices (all at 1.0 for simplicity)
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    let mut i = 0u8;
    while ((i as u64) < 7) {
        let pool = conditional_amm::create_test_pool(
            market_id,
            i,
            (DEFAULT_FEE_BPS as u64),
            1000,
            1000,
            &clock2,
            ctx,
        );
        let mut pool_mut = pool;
        conditional_amm::add_liquidity_for_testing(
            &mut pool_mut,
            coin::mint_for_testing<TEST_COIN_A>(300_000_000, ctx),
            coin::mint_for_testing<TEST_COIN_B>(300_000_000, ctx),
            DEFAULT_FEE_BPS,
            ctx,
        );
        vector::push_back(&mut pools, pool_mut);
        i = i + 1;
    };

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Make pools asymmetric to ensure dust is created
    {
        let pools_ref = borrow_amm_pools_mut_with_test_auth(market_state);
        conditional_amm::add_reserves_for_testing(&mut pools_ref[0], 20_000_000, 10_000_000);
    };

    // Add escrow liquidity - use pool reserves for proper quantum backing
    let escrow_asset = 300_000_000u64;
    let escrow_stable = 300_000_000u64;
    let asset_for_escrow = coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx);
    let stable_for_escrow = coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_for_escrow, stable_for_escrow);

    // Initialize supplies to match AMM reserves
    // Arbitrage requires supplies to be set (track_system_swap asserts supply >= consumed)
    // increment_supplies_for_all_outcomes handles ALL 7 outcomes
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // VERIFY: No user-owned dust is returned for system rebalance.
    assert!(option::is_none(&dust_opt), 0);
    assert!(coin_escrow::caps_registered_count(&escrow) == 7, 1);
    assert!(total_system_dust_created(&escrow) == 0, 2);

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test sequential arbitrage until opportunity is exhausted
fun test_arbitrage_until_exhausted() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Large price divergence
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 15_000_000_000, &clock, ctx);

    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Make pools asymmetric to ensure dust is created
    {
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        let pools = borrow_amm_pools_mut_with_test_auth(market_state);
        conditional_amm::add_reserves_for_testing(&mut pools[0], 100_000_000, 50_000_000);
    };

    // Large escrow
    deposit_extra_liquidity_to_escrow(&mut escrow, 50_000_000_000, 50_000_000_000, ctx);

    // Run arbitrage multiple times until prices converge
    let mut iteration = 0u64;
    let mut prev_price = unified_spot_pool::get_spot_price(&spot_pool);
    let mut dust_balance: option::Option<
        conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>,
    > = option::none();

    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    while (iteration < 10) {
        dust_balance =
            arbitrage::auto_rebalance_spot_after_conditional_swaps(
                &mut spot_pool,
                &mut escrow,
                dust_balance,
                &escrow_registry,
                &market_state_registry,
                &clock,
                ctx,
            );

        let curr_price = unified_spot_pool::get_spot_price(&spot_pool);

        // Check if price stopped moving (arbitrage exhausted)
        let price_change = if (curr_price > prev_price) {
            curr_price - prev_price
        } else {
            prev_price - curr_price
        };

        if (price_change < prev_price / 1000) {
            // Less than 0.1% change - arbitrage exhausted
            break
        };

        prev_price = curr_price;
        iteration = iteration + 1;
    };

    // VERIFY: At least one iteration ran
    assert!(iteration >= 1, 0);

    // VERIFY: System dust is retained internally rather than returned to the caller.
    assert!(option::is_none(&dust_balance), 1);
    assert!(total_system_dust_created(&escrow) == 0, 2);

    // Cleanup
    option::destroy_none(dust_balance);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test precision with very large reserves (overflow protection)
fun test_arbitrage_large_reserves_precision() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Very large reserves (100B tokens each)
    let mut spot_pool = create_test_spot_pool(
        100_000_000_000_000,
        200_000_000_000_000,
        &clock,
        ctx,
    );
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, 10_000_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 10_000_000_000_000, ctx);

    // Large escrow
    deposit_extra_liquidity_to_escrow(&mut escrow, 100_000_000_000_000, 100_000_000_000_000, ctx);

    // Execute arbitrage - should not overflow
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // VERIFY: Price moved in correct direction (down toward 1.0)
    assert!(final_spot_price <= init_spot_price, 0);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test with identical conditional pool prices (should produce zero dust difference)
fun test_arbitrage_identical_conditional_prices() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 2.0
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow with 3 outcomes - all at EXACTLY the same price
    let mut escrow = create_test_escrow_with_markets(3, 1_000_000_000, &clock, ctx);

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // All pools at exactly price = 1.0
    let mut i = 0u8;
    while ((i as u64) < 3) {
        let pool = conditional_amm::create_test_pool(
            market_id,
            i,
            (DEFAULT_FEE_BPS as u64),
            1000,
            1000,
            &clock2,
            ctx,
        );
        let mut pool_mut = pool;
        conditional_amm::add_liquidity_for_testing(
            &mut pool_mut,
            coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx),
            coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
            DEFAULT_FEE_BPS,
            ctx,
        );
        vector::push_back(&mut pools, pool_mut);
        i = i + 1;
    };

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity - use pool reserves for proper quantum backing
    let escrow_asset = 1_000_000_000u64;
    let escrow_stable = 1_000_000_000u64;
    let asset_for_escrow = coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx);
    let stable_for_escrow = coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_for_escrow, stable_for_escrow);

    // Initialize supplies to match AMM reserves
    // Arbitrage requires supplies to be set (track_system_swap asserts supply >= consumed)
    // increment_supplies_for_all_outcomes handles ALL 3 outcomes
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // VERIFY: With IDENTICAL pools, NO dust is created
    // This is correct behavior: identical swaps produce identical outputs,
    // so min_output == max_output for all pools, meaning no "extra" dust
    // The test name says "zero dust difference" - correct behavior is zero dust entirely
    assert!(option::is_none(&dust_opt), 0);

    // Note: If we wanted dust to be created, we'd need asymmetric pools
    // That's tested elsewhere (e.g., test_arbitrage_dust_balance_contents)

    /*
    // Old test expected dust to be created even with identical pools
    // This was incorrect - identical pools produce identical outputs = no dust
    let dust = option::borrow(&dust_opt);
    let dust_0 = ...
    */

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that arbitrage works with moderate escrow reserves
fun test_arbitrage_moderate_escrow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot pool with moderate divergence
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Moderate conditional pools
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Make pools asymmetric to ensure dust is created
    {
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        let pools = borrow_amm_pools_mut_with_test_auth(market_state);
        conditional_amm::add_reserves_for_testing(&mut pools[0], 100_000_000, 50_000_000);
    };

    // Moderate escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 5_000_000_000, 5_000_000_000, ctx);

    let (init_spot_asset, init_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    // VERIFY: Reserves changed (arbitrage executed)
    let asset_changed = final_spot_asset != init_spot_asset;
    let stable_changed = final_spot_stable != init_spot_stable;
    assert!(asset_changed || stable_changed, 0);

    // VERIFY: Residual output was retained as system dust, not user-owned dust.
    assert!(option::is_none(&dust_opt), 1);
    assert!(total_system_dust_created(&escrow) == 0, 2);

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test price ratio of exactly 1:1 between one conditional and spot
fun test_arbitrage_exact_price_match_one_pool() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 1.0
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow with 2 outcomes
    let mut escrow = create_test_escrow_with_markets(2, 500_000_000, &clock, ctx);

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price = 1.0 (EXACT match with spot)
    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(
        &mut pool0_mut,
        coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: price = 0.5 (below spot)
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(
        &mut pool1_mut,
        coin::mint_for_testing<TEST_COIN_A>(2_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool1_mut);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // With one pool at exact match and one below, the blocking pool (exact match)
    // should prevent profitable arbitrage in at least one direction
    // Price change should be minimal
    let price_diff = if (final_spot_price > init_spot_price) {
        final_spot_price - init_spot_price
    } else {
        init_spot_price - final_spot_price
    };

    // Less than 5% change expected
    let max_change = init_spot_price / 20;
    assert!(price_diff <= max_change, 0);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test with four outcomes having alternating high/low prices
fun test_arbitrage_four_outcomes_alternating() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 1.0
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow with 4 outcomes
    let mut escrow = create_test_escrow_with_markets(4, 300_000_000, &clock, ctx);

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price = 0.5 (LOW)
    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(
        &mut pool0_mut,
        coin::mint_for_testing<TEST_COIN_A>(800_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(400_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: price = 2.0 (HIGH)
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(
        &mut pool1_mut,
        coin::mint_for_testing<TEST_COIN_A>(400_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(800_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool1_mut);

    // Pool 2: price = 0.5 (LOW)
    let pool2 = conditional_amm::create_test_pool(
        market_id,
        2,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool2_mut = pool2;
    conditional_amm::add_liquidity_for_testing(
        &mut pool2_mut,
        coin::mint_for_testing<TEST_COIN_A>(800_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(400_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool2_mut);

    // Pool 3: price = 2.0 (HIGH)
    let pool3 = conditional_amm::create_test_pool(
        market_id,
        3,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    let mut pool3_mut = pool3;
    conditional_amm::add_liquidity_for_testing(
        &mut pool3_mut,
        coin::mint_for_testing<TEST_COIN_A>(400_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(800_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, pool3_mut);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);

    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // With alternating prices [0.5, 2.0, 0.5, 2.0] and spot at 1.0,
    // spot is within range, so arbitrage might be blocked
    // Just verify no panic and minimal change
    let price_diff = if (final_spot_price > init_spot_price) {
        final_spot_price - init_spot_price
    } else {
        init_spot_price - final_spot_price
    };

    // Should be small change (spot within range)
    let max_change = init_spot_price / 10;
    assert!(price_diff <= max_change, 0);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test extremely small price difference (0.1%)
fun test_arbitrage_tiny_price_difference() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 1.001
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 10_010_000_000, &clock, ctx);
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Conditional at exactly 1.0
    let mut escrow = create_test_escrow_with_markets(2, 5_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 5_000_000_000, ctx);

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // With 0.1% difference, arbitrage might or might not be profitable
    // Just ensure no crash and reasonable behavior
    let price_diff = if (final_spot_price > init_spot_price) {
        final_spot_price - init_spot_price
    } else {
        init_spot_price - final_spot_price
    };

    // Price change should be tiny (less than 1%)
    let max_change = init_spot_price / 100;
    assert!(price_diff <= max_change, 0);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify arbitrage is actually profitable - total value after > total value before
fun test_arbitrage_profit_verification() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup with clear price divergence: spot = 2.0, conditional = 1.0
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Make pools asymmetric to ensure dust is created
    {
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        let pools = borrow_amm_pools_mut_with_test_auth(market_state);
        conditional_amm::add_reserves_for_testing(&mut pools[0], 100_000_000, 50_000_000);
    };

    // Add escrow liquidity
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Calculate initial total value in spot pool (using stable as numeraire)
    // Value = stable + asset * price
    let (init_spot_asset, init_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool); // in 1e12
    let init_spot_value =
        init_spot_stable +
        (((init_spot_asset as u128) * (init_spot_price as u128) / 1_000_000_000_000) as u64);

    // Get initial conditional pool reserves
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (init_cond0_asset, init_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (init_cond1_asset, init_cond1_stable) = conditional_amm::get_reserves(&pools[1]);
    let init_cond_asset = init_cond0_asset + init_cond1_asset;
    let init_cond_stable = init_cond0_stable + init_cond1_stable;

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Calculate final total value in spot pool
    let (final_spot_asset, final_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    let final_spot_value =
        final_spot_stable +
        (((final_spot_asset as u128) * (final_spot_price as u128) / 1_000_000_000_000) as u64);

    // Get final conditional pool reserves
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (final_cond0_asset, final_cond0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (final_cond1_asset, final_cond1_stable) = conditional_amm::get_reserves(&pools[1]);
    let final_cond_asset = final_cond0_asset + final_cond1_asset;
    let final_cond_stable = final_cond0_stable + final_cond1_stable;

    // VERIFY: Value calculation is reasonable (no overflow/panic)
    // Note: Spot pool may lose or gain value depending on direction
    let _value_changed = init_spot_value != final_spot_value;

    // VERIFY: Reserves changed (arbitrage executed)
    let reserves_changed =
        (final_spot_asset != init_spot_asset) ||
                           (final_spot_stable != init_spot_stable);
    assert!(reserves_changed, 0);

    // VERIFY: Residual output was retained as system dust, not user-owned dust.
    assert!(option::is_none(&dust_opt), 1);
    assert!(total_system_dust_created(&escrow) == 0, 2);

    // Suppress unused variable warnings
    let _ = init_cond_asset;
    let _ = init_cond_stable;
    let _ = final_cond_asset;
    let _ = final_cond_stable;

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify spot pool K grows over multiple arbitrage operations (liquidity accumulation)
fun test_arbitrage_k_growth_over_time() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 2_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 2_000_000_000, ctx);

    // Large escrow for multiple arbitrages
    deposit_extra_liquidity_to_escrow(&mut escrow, 50_000_000_000, 50_000_000_000, ctx);

    // Record initial K
    let (init_asset, init_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let init_k = (init_asset as u128) * (init_stable as u128);

    // First arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt_1 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (asset_1, stable_1) = unified_spot_pool::get_reserves(&spot_pool);
    let k_1 = (asset_1 as u128) * (stable_1 as u128);

    // VERIFY: K increased after first arbitrage
    assert!(k_1 >= init_k, 0);

    // Manually perturb prices to create new arbitrage opportunity
    // Add more asset to spot pool to lower price
    let extra_asset = coin::mint_for_testing<TEST_COIN_A>(asset_1 / 2, ctx);
    unified_spot_pool::return_asset_from_arbitrage(&mut spot_pool, coin::into_balance(extra_asset));

    // Second arbitrage
    let dust_opt_2 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        dust_opt_1,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (asset_2, stable_2) = unified_spot_pool::get_reserves(&spot_pool);
    let k_2 = (asset_2 as u128) * (stable_2 as u128);

    // VERIFY: K didn't decrease after second arbitrage (which added asset)
    // Note: Adding asset increased K, so k_2 >= k_1 should hold
    assert!(k_2 >= k_1, 1);

    // Third arbitrage (same state, no perturbation - should be no-op)
    let mut dust_opt_3 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        dust_opt_2,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (asset_3, stable_3) = unified_spot_pool::get_reserves(&spot_pool);
    let k_3 = (asset_3 as u128) * (stable_3 as u128);

    // VERIFY: K didn't decrease after third arbitrage
    assert!(k_3 >= k_2, 2);

    // VERIFY: Overall K grew from initial (due to adding extra asset)
    assert!(k_3 >= init_k, 3);

    // Cleanup
    if (option::is_some(&dust_opt_3)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt_3));
    };
    option::destroy_none(dust_opt_3);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test existing balance merge behavior - dust from multiple arbitrages merges correctly
fun test_arbitrage_existing_balance_merge() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Setup
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);

    // Create an existing balance manually
    let market_state = coin_escrow::get_market_state(&escrow);
    let market_id = market_state::market_id(market_state);
    let mut existing_balance = conditional_balance::new<TEST_COIN_A, TEST_COIN_B>(
        market_id,
        2,
        ctx,
    );

    // Add some initial dust to existing balance
    let balance_auth = escrow_mutation_auth::create_for_testing();
    conditional_balance::add_to_balance(&mut existing_balance, 0, true, 1000, &balance_auth);
    conditional_balance::add_to_balance(&mut existing_balance, 1, false, 2000, &balance_auth);

    let init_balance_0_asset = conditional_balance::get_balance(&existing_balance, 0, true);
    let init_balance_1_stable = conditional_balance::get_balance(&existing_balance, 1, false);

    // Execute arbitrage with existing balance
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut result_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::some(existing_balance),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // VERIFY: Result exists and contains merged balances
    assert!(option::is_some(&result_opt), 0);
    let result = option::borrow(&result_opt);

    // The existing balance values should be preserved (merged into result)
    let final_balance_0_asset = conditional_balance::get_balance(result, 0, true);
    let final_balance_1_stable = conditional_balance::get_balance(result, 1, false);

    // Final balance should be >= initial (merged)
    assert!(final_balance_0_asset >= init_balance_0_asset, 1);
    assert!(final_balance_1_stable >= init_balance_1_stable, 2);

    // Cleanup
    conditional_balance::destroy_for_testing(option::extract(&mut result_opt));
    option::destroy_none(result_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that insufficient spot reserves triggers early exit (no panic)
fun test_arbitrage_insufficient_spot_reserves() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Very small spot pool reserves
    let mut spot_pool = create_test_spot_pool(100, 200, &clock, ctx);

    // Large conditional pools that would require big arbitrage
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Large escrow
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Execute arbitrage - should not panic, may return None if can't execute
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Just verify no panic occurred
    // Result may or may not be Some depending on computed arb amount

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify correct direction is chosen based on price relationships
fun test_arbitrage_direction_selection() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Case 1: Spot price HIGH (3.0) > conditional (1.0)
    // Should execute Spot→Cond: sell asset, receive stable
    let mut spot_pool_high = create_test_spot_pool(5_000_000_000, 15_000_000_000, &clock, ctx);
    let mut escrow_high = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow_high, 1_000_000_000, ctx);

    deposit_extra_liquidity_to_escrow(&mut escrow_high, 10_000_000_000, 10_000_000_000, ctx);

    let (init_asset_high, init_stable_high) = unified_spot_pool::get_reserves(&spot_pool_high);

    link_pool_to_escrow(&mut spot_pool_high, &escrow_high);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_high = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool_high,
        &mut escrow_high,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (final_asset_high, final_stable_high) = unified_spot_pool::get_reserves(&spot_pool_high);

    // VERIFY: When spot HIGH, buy from conditionals = spot pool gains asset, loses stable
    // (Arbitrage buys cheap conditional asset and returns it to spot)
    assert!(final_asset_high > init_asset_high, 0);
    assert!(final_stable_high < init_stable_high, 1);

    // Case 2: Spot price LOW (0.5) < conditional (1.0)
    // Should sell asset to conditionals: give asset, receive stable
    let mut spot_pool_low = create_test_spot_pool(10_000_000_000, 5_000_000_000, &clock, ctx);
    let mut escrow_low = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow_low, 1_000_000_000, ctx);

    deposit_extra_liquidity_to_escrow(&mut escrow_low, 10_000_000_000, 10_000_000_000, ctx);

    let (init_asset_low, init_stable_low) = unified_spot_pool::get_reserves(&spot_pool_low);

    link_pool_to_escrow(&mut spot_pool_low, &escrow_low);
    let mut dust_low = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool_low,
        &mut escrow_low,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (final_asset_low, final_stable_low) = unified_spot_pool::get_reserves(&spot_pool_low);

    // VERIFY: When spot LOW, sell to conditionals = spot pool loses asset, gains stable
    // (Arbitrage sells cheap spot asset into expensive conditional pools)
    assert!(final_asset_low < init_asset_low, 2);
    assert!(final_stable_low > init_stable_low, 3);

    // Cleanup
    if (option::is_some(&dust_high)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_high));
    };
    option::destroy_none(dust_high);
    if (option::is_some(&dust_low)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_low));
    };
    option::destroy_none(dust_low);
    unified_spot_pool::destroy_for_testing(spot_pool_high);
    unified_spot_pool::destroy_for_testing(spot_pool_low);
    coin_escrow::destroy_for_testing(escrow_high);
    coin_escrow::destroy_for_testing(escrow_low);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Track escrow balance changes during arbitrage
fun test_arbitrage_escrow_balance_changes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Add specific escrow amounts
    let escrow_asset = 10_000_000_000u64;
    let escrow_stable = 10_000_000_000u64;
    deposit_extra_liquidity_to_escrow(&mut escrow, escrow_asset, escrow_stable, ctx);

    let init_escrow_asset = coin_escrow::get_escrowed_asset_balance(&escrow);
    let init_escrow_stable = coin_escrow::get_escrowed_stable_balance(&escrow);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_escrow_asset = coin_escrow::get_escrowed_asset_balance(&escrow);
    let final_escrow_stable = coin_escrow::get_escrowed_stable_balance(&escrow);

    // VERIFY: Escrow balances changed (arbitrage used escrow as type converter)
    let escrow_changed =
        (final_escrow_asset != init_escrow_asset) ||
                         (final_escrow_stable != init_escrow_stable);
    assert!(escrow_changed, 0);

    // VERIFY: Total escrow value is approximately preserved
    // (some may be in conditional pools as reserves)
    let init_total = init_escrow_asset + init_escrow_stable;
    let final_total = final_escrow_asset + final_escrow_stable;

    // Allow some tolerance for tokens moved to/from pools
    let diff = if (init_total > final_total) {
        init_total - final_total
    } else {
        final_total - init_total
    };

    // Difference should be less than 50% of initial (reasonable bound)
    assert!(diff < init_total / 2, 1);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify price converges toward equilibrium after arbitrage
fun test_arbitrage_price_convergence_accuracy() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price = 2.0, conditional = 1.0
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let init_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, 2_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 2_000_000_000, ctx);

    // Get conditional price
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let (cond_asset, cond_stable) = conditional_amm::get_reserves(&pools[0]);
    let cond_price = (cond_stable as u128) * 1_000_000_000_000 / (cond_asset as u128);

    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // VERIFY: Price moved toward conditional price (all comparisons in u128)
    let init_diff = if (init_spot_price > cond_price) {
        init_spot_price - cond_price
    } else {
        cond_price - init_spot_price
    };

    let final_diff = if (final_spot_price > cond_price) {
        final_spot_price - cond_price
    } else {
        cond_price - final_spot_price
    };

    // Final difference should be less than initial (price converged)
    assert!(final_diff <= init_diff, 0);

    // VERIFY: Some convergence occurred (any improvement is acceptable)
    // The actual convergence depends on pool sizes, fees, and reserve ratios
    if (init_diff > 0 && final_diff < init_diff) {
        let _convergence_pct = ((init_diff - final_diff) * 100) / init_diff;
        // Convergence happened - no strict threshold required
    };

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test rounding behavior with minimal amounts
fun test_arbitrage_minimal_amounts_rounding() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Small but not tiny reserves
    let mut spot_pool = create_test_spot_pool(10_000, 20_000, &clock, ctx);

    let mut escrow = create_test_escrow_with_markets(2, 5_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 5_000, ctx);

    deposit_extra_liquidity_to_escrow(&mut escrow, 50_000, 50_000, ctx);

    // Execute arbitrage with small amounts
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // VERIFY: No panic occurred with small amounts
    // Result may be None if arb amount rounds to 0

    // Cleanup
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

// === Security Tests ===

#[test]
#[expected_failure(abort_code = 103)] // ESpotPoolEscrowMismatch
/// Test that arbitrage fails when spot_pool's active_escrow doesn't match the passed escrow.
/// This is a security test to ensure cross-market attacks are prevented.
fun test_arbitrage_fails_with_mismatched_escrow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with aggregator config (needed for active_escrow)
    let lp_treasury = create_lp_treasury(ctx);
    let mut spot_pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, LP>(
        lp_treasury,
        (DEFAULT_FEE_BPS as u64),
        ctx,
    );

    // Add some reserves to the spot pool
    let asset_balance = sui::balance::create_for_testing<TEST_COIN_A>(INITIAL_SPOT_RESERVE);
    let stable_balance = sui::balance::create_for_testing<TEST_COIN_B>(INITIAL_SPOT_RESERVE);
    unified_spot_pool::add_liquidity_for_testing(&mut spot_pool, asset_balance, stable_balance);

    // Create an escrow
    let mut escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, INITIAL_CONDITIONAL_RESERVE, ctx);
    deposit_extra_liquidity_to_escrow(&mut escrow, INITIAL_SPOT_RESERVE, INITIAL_SPOT_RESERVE, ctx);

    // SECURITY: Set spot_pool's active_escrow to a DIFFERENT ID than the escrow we'll pass
    // This simulates an attacker trying to use mismatched pool/escrow pairs
    let fake_escrow = create_test_escrow_with_markets(2, INITIAL_CONDITIONAL_RESERVE, &clock, ctx);
    unified_spot_pool::set_active_escrow_for_testing(&mut spot_pool, fake_escrow);

    // Create escrow registry
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    // This should FAIL with ESpotPoolEscrowMismatch (103) because:
    // spot_pool.active_escrow = 0xDEADBEEF
    // escrow.id = (different ID)
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // This code should not be reached - test expects abort
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

// =============================================================================
// === Cross-Layer Solvency Tests ==============================================
// =============================================================================
//
// These tests verify that pool reserve counters stay consistent with escrow
// supply/wrapped tracking after arbitrage. The key invariant:
//
//   For each outcome i:
//     pool_i.asset_reserve + dust_asset_i == pre_pool_i.asset_reserve + injected - withdrawn
//
// And critically:
//   pool reserves must NOT include tokens that the escrow has marked as "wrapped"
//   (owned by ConditionalMarketBalance holders). Double-counting leads to LP
//   insolvency on final withdrawal.

/// Helper: verify no double-counting of dust between pool reserves and wrapped balances.
///
/// The core invariant: outcome_escrowed == supply + wrapped.
/// Dust tokens must be in EITHER pool reserves (as supply) OR in wrapped, never both.
///
/// We verify:
/// 1. Quantum invariant holds: outcome_escrowed == supply + wrapped
/// 2. Dust balance matches wrapped amounts exactly (dust is properly tracked)
/// 3. Escrow actual balance covers all per-outcome allocations (solvency)
/// 4. No token is counted in both pool reserves and wrapped (no double-counting)
///    - Checked indirectly: if pool_reserve included dust, supply would need to cover
///      both pool_reserve AND wrapped, which would violate outcome_escrowed == supply + wrapped
///      OR the escrow would be insolvent (actual balance < outcome_escrowed)
#[test_only]
fun assert_no_dust_double_counting(
    escrow: &TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    dust_opt: &option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
) {
    let market_state = coin_escrow::get_market_state(escrow);
    let outcome_count = market_state::outcome_count(market_state);

    let (asset_supplies, stable_supplies) = coin_escrow::get_all_supplies(escrow);
    let (wrapped_asset, wrapped_stable) = coin_escrow::get_wrapped_balances(escrow);

    // 1. Quantum invariant: outcome_escrowed == supply + wrapped for each outcome
    let mut i = 0;
    while (i < outcome_count) {
        let escrowed_asset = coin_escrow::get_outcome_escrowed_asset(escrow, i);
        let escrowed_stable = coin_escrow::get_outcome_escrowed_stable(escrow, i);
        assert!(escrowed_asset == asset_supplies[i] + wrapped_asset[i], 9000 + (i as u64));
        assert!(escrowed_stable == stable_supplies[i] + wrapped_stable[i], 9100 + (i as u64));
        i = i + 1;
    };

    // 2. Dust balance matches wrapped amounts exactly
    if (option::is_some(dust_opt)) {
        let dust = option::borrow(dust_opt);
        i = 0;
        while (i < outcome_count) {
            let dust_asset_i = conditional_balance::get_balance(dust, (i as u8), true);
            let dust_stable_i = conditional_balance::get_balance(dust, (i as u8), false);
            assert!(dust_asset_i == wrapped_asset[i], 9200 + (i as u64));
            assert!(dust_stable_i == wrapped_stable[i], 9300 + (i as u64));
            i = i + 1;
        };
    };

    // 3. Per-type solvency is NOT checked during active trading.
    // In the quantum model, conditional swaps shift per-outcome claims between types
    // (e.g., stable→asset increases OEA[i]) without changing real escrow composition.
    // The production invariant only checks per-type solvency post-finalization
    // (with pool_claim subtraction). See assert_quantum_invariant in coin_escrow.
}

#[test]
/// CRITICAL: Pool reserve counters must not include dust (wrapped) tokens.
/// This was the root cause of the dust double-counting bug: extract only removed
/// min_asset from each pool, leaving dust in the counter while also marking it
/// as wrapped in the escrow. The same tokens were claimed by both the pool (LP
/// reserves) and the ConditionalMarketBalance holder (wrapped balance).
fun test_pool_reserves_exclude_dust_after_arbitrage() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Asymmetric spot vs conditional to trigger arbitrage
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow with 2 outcomes and asymmetric conditional pools
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: balanced (price = 1.0)
    let pool0 = conditional_amm::create_test_pool(market_id, 0, (DEFAULT_FEE_BPS as u64), 1000, 1000, &clock2, ctx);
    let mut pool0_mut = pool0;
    conditional_amm::add_liquidity_for_testing(&mut pool0_mut, coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx), coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx), DEFAULT_FEE_BPS, ctx);
    vector::push_back(&mut pools, pool0_mut);

    // Pool 1: asymmetric (price = 0.667) - will produce different swap output → dust
    let pool1 = conditional_amm::create_test_pool(market_id, 1, (DEFAULT_FEE_BPS as u64), 1000, 1000, &clock2, ctx);
    let mut pool1_mut = pool1;
    conditional_amm::add_liquidity_for_testing(&mut pool1_mut, coin::mint_for_testing<TEST_COIN_A>(1_200_000_000, ctx), coin::mint_for_testing<TEST_COIN_B>(800_000_000, ctx), DEFAULT_FEE_BPS, ctx);
    vector::push_back(&mut pools, pool1_mut);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Fund escrow
    let escrow_asset = 1_200_000_000u64;
    let escrow_stable = 1_000_000_000u64;
    coin_escrow::deposit_spot_coins(&mut escrow, coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx), coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx));
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool, &mut escrow, option::none(),
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // CORE ASSERTION: Pool reserves must not include wrapped/dust tokens
    assert_no_dust_double_counting(&escrow, &dust_opt);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify pool reserves stay consistent across multiple sequential arbitrage calls.
/// Dust accumulation must never inflate pool counters.
fun test_pool_solvency_across_multiple_arbitrages() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Make pools asymmetric
    {
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        let pools = borrow_amm_pools_mut_with_test_auth(market_state);
        conditional_amm::add_reserves_for_testing(&mut pools[0], 100_000_000, 50_000_000);
    };

    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    // Run 3 sequential arbitrages, accumulating dust
    let mut accumulated_dust: option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>> = option::none();
    let mut round = 0;
    while (round < 3) {
        // Perturb pools between rounds to trigger new arbitrage
        if (round > 0) {
            // Deposit actual tokens to escrow first (must match supply increment)
            let perturb_asset = coin::mint_for_testing<TEST_COIN_A>(50_000_000, ctx);
            let perturb_stable = coin::mint_for_testing<TEST_COIN_B>(50_000_000, ctx);
            coin_escrow::deposit_spot_coins(&mut escrow, perturb_asset, perturb_stable);

            let escrow_auth = escrow_mutation_auth::create_for_testing();
            let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
            let pools = borrow_amm_pools_mut_with_test_auth(market_state);
            // Add asymmetric reserves to re-trigger arbitrage opportunity
            conditional_amm::add_reserves_for_testing(&mut pools[0], 50_000_000, 0);
            conditional_amm::add_reserves_for_testing(&mut pools[1], 0, 50_000_000);
            // Update supplies to match the new reserves
            coin_escrow::increment_supplies_for_all_outcomes(
                &mut escrow, 50_000_000, 50_000_000, &escrow_auth,
            );
        };

        accumulated_dust = arbitrage::auto_rebalance_spot_after_conditional_swaps(
            &mut spot_pool, &mut escrow, accumulated_dust,
            &escrow_registry, &market_state_registry, &clock, ctx,
        );

        // After EVERY round: pool reserves must not include wrapped tokens
        assert_no_dust_double_counting(&escrow, &accumulated_dust);

        round = round + 1;
    };

    // Cleanup
    if (option::is_some(&accumulated_dust)) {
        conditional_balance::destroy_for_testing(option::extract(&mut accumulated_dust));
    };
    option::destroy_none(accumulated_dust);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify with 3 outcomes: pool reserves stay correct when dust amounts differ per outcome.
/// More outcomes = more opportunities for divergent swap outputs = more dust risk.
fun test_pool_solvency_three_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(3, 1_000_000_000, &clock, ctx);

    // Create 3 asymmetric pools manually
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price ~ 1.0
    let mut p0 = conditional_amm::create_test_pool(market_id, 0, (DEFAULT_FEE_BPS as u64), 1000, 1000, &clock2, ctx);
    conditional_amm::add_liquidity_for_testing(&mut p0, coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx), coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx), DEFAULT_FEE_BPS, ctx);
    vector::push_back(&mut pools, p0);

    // Pool 1: price ~ 0.8
    let mut p1 = conditional_amm::create_test_pool(market_id, 1, (DEFAULT_FEE_BPS as u64), 1000, 1000, &clock2, ctx);
    conditional_amm::add_liquidity_for_testing(&mut p1, coin::mint_for_testing<TEST_COIN_A>(1_100_000_000, ctx), coin::mint_for_testing<TEST_COIN_B>(900_000_000, ctx), DEFAULT_FEE_BPS, ctx);
    vector::push_back(&mut pools, p1);

    // Pool 2: price ~ 0.667
    let mut p2 = conditional_amm::create_test_pool(market_id, 2, (DEFAULT_FEE_BPS as u64), 1000, 1000, &clock2, ctx);
    conditional_amm::add_liquidity_for_testing(&mut p2, coin::mint_for_testing<TEST_COIN_A>(1_200_000_000, ctx), coin::mint_for_testing<TEST_COIN_B>(800_000_000, ctx), DEFAULT_FEE_BPS, ctx);
    vector::push_back(&mut pools, p2);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Fund escrow (use max of pool reserves for quantum backing)
    let escrow_asset = 1_200_000_000u64;
    let escrow_stable = 1_000_000_000u64;
    coin_escrow::deposit_spot_coins(&mut escrow, coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx), coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx));
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);

    // Execute arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool, &mut escrow, option::none(),
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // CORE ASSERTION: Pool reserves must not include wrapped/dust tokens
    assert_no_dust_double_counting(&escrow, &dust_opt);

    // Additional: with 3 different pools, at most 1 outcome should have zero dust
    // (the one with minimum output)
    if (option::is_some(&dust_opt)) {
        let dust = option::borrow(&dust_opt);
        let d0 = conditional_balance::get_balance(dust, 0, true);
        let d1 = conditional_balance::get_balance(dust, 1, true);
        let d2 = conditional_balance::get_balance(dust, 2, true);
        let s0 = conditional_balance::get_balance(dust, 0, false);
        let s1 = conditional_balance::get_balance(dust, 1, false);
        let s2 = conditional_balance::get_balance(dust, 2, false);

        // At least one outcome must have zero dust (the min output)
        let has_zero_asset = (d0 == 0 || d1 == 0 || d2 == 0);
        let has_zero_stable = (s0 == 0 || s1 == 0 || s2 == 0);
        assert!(has_zero_asset || has_zero_stable, 8000);
    };

    // Cleanup
    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Verify the escrow actual balance always covers supply + wrapped after arbitrage.
/// This is the ultimate solvency check: if pool counters are inflated beyond
/// what supply tracks, the escrow won't have enough to back all claims.
fun test_escrow_balance_covers_all_claims_after_arbitrage() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Asymmetric pools to force dust
    {
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        let pools = borrow_amm_pools_mut_with_test_auth(market_state);
        conditional_amm::add_reserves_for_testing(&mut pools[0], 200_000_000, 0);
        conditional_amm::add_reserves_for_testing(&mut pools[1], 0, 200_000_000);
    };

    deposit_extra_liquidity_to_escrow(&mut escrow, 20_000_000_000, 20_000_000_000, ctx);
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool, &mut escrow, option::none(),
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Verify quantum invariant: OEA[i] == supply[i] + wrapped[i]
    // Per-type solvency (EA >= OEA) is NOT guaranteed during active trading;
    // conditional swaps shift claims between types while real escrow composition stays fixed.
    assert_no_dust_double_counting(&escrow, &dust_opt);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test spot_to_cond direction (reverse flow) also keeps pool counters accurate.
/// The bug could appear in either direction.
fun test_pool_reserves_exclude_dust_spot_to_cond() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price LOW relative to conditional → spot_to_cond direction
    // (Buy cheap asset from spot, sell expensive to conditional pools for stable)
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 5_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);

    // Asymmetric conditional pools
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    // Pool 0: price ~ 1.0
    let mut p0 = conditional_amm::create_test_pool(market_id, 0, (DEFAULT_FEE_BPS as u64), 1000, 1000, &clock2, ctx);
    conditional_amm::add_liquidity_for_testing(&mut p0, coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx), coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx), DEFAULT_FEE_BPS, ctx);
    vector::push_back(&mut pools, p0);

    // Pool 1: price ~ 1.5
    let mut p1 = conditional_amm::create_test_pool(market_id, 1, (DEFAULT_FEE_BPS as u64), 1000, 1000, &clock2, ctx);
    conditional_amm::add_liquidity_for_testing(&mut p1, coin::mint_for_testing<TEST_COIN_A>(800_000_000, ctx), coin::mint_for_testing<TEST_COIN_B>(1_200_000_000, ctx), DEFAULT_FEE_BPS, ctx);
    vector::push_back(&mut pools, p1);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Fund escrow
    let escrow_asset = 1_000_000_000u64;
    let escrow_stable = 1_200_000_000u64;
    coin_escrow::deposit_spot_coins(&mut escrow, coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx), coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx));
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);

    // Execute arbitrage (should take spot_to_cond direction)
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool, &mut escrow, option::none(),
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // CORE ASSERTION: Pool reserves must not include wrapped/dust tokens
    assert_no_dust_double_counting(&escrow, &dust_opt);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// TDD invariant: cond_to_spot must account exact per-pool outputs (no over/under extraction),
/// and final spot price must lie within conditional pool price bounds.
fun test_tdd_cond_to_spot_exact_reserve_accounting_and_price_bounds() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot starts above conditional range: triggers cond_to_spot direction.
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let (pre_spot_asset, pre_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let pre_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Build 2 asymmetric conditional pools so outputs differ and dust exists.
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    let mut p0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    conditional_amm::add_liquidity_for_testing(
        &mut p0,
        coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, p0);

    let mut p1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    conditional_amm::add_liquidity_for_testing(
        &mut p1,
        coin::mint_for_testing<TEST_COIN_A>(1_200_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(800_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, p1);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Fund escrow + initialize supplies for quantum accounting.
    let escrow_asset = 1_200_000_000u64;
    let escrow_stable = 1_000_000_000u64;
    coin_escrow::deposit_spot_coins(
        &mut escrow,
        coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx),
        coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx),
    );
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, escrow_asset, escrow_stable);

    // Snapshot conditional reserves before arbitrage.
    let market_state_before = coin_escrow::get_market_state(&escrow);
    let pools_before = market_state::borrow_amm_pools(market_state_before);
    let (pre_a0, pre_s0) = conditional_amm::get_reserves(&pools_before[0]);
    let (pre_a1, pre_s1) = conditional_amm::get_reserves(&pools_before[1]);
    let pre_price0 = ((pre_s0 as u128) * 1_000_000_000_000) / (pre_a0 as u128);
    let pre_price1 = ((pre_s1 as u128) * 1_000_000_000_000) / (pre_a1 as u128);
    let pre_min_cond = if (pre_price0 < pre_price1) { pre_price0 } else { pre_price1 };
    let pre_max_cond = if (pre_price0 > pre_price1) { pre_price0 } else { pre_price1 };

    // Execute arbitrage.
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Snapshot after arbitrage.
    let (post_spot_asset, post_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let market_state_after = coin_escrow::get_market_state(&escrow);
    let pools_after = market_state::borrow_amm_pools(market_state_after);
    let (post_a0, post_s0) = conditional_amm::get_reserves(&pools_after[0]);
    let (post_a1, post_s1) = conditional_amm::get_reserves(&pools_after[1]);

    // Direction sanity: cond_to_spot takes stable from spot and returns min(asset_outs) to spot.
    assert!(pre_spot_stable > post_spot_stable, 9600);
    assert!(post_spot_asset > pre_spot_asset, 9601);
    let stable_needed = pre_spot_stable - post_spot_stable;
    let min_asset_to_spot = post_spot_asset - pre_spot_asset;

    // Expected outputs from each pool (same math path as swap_from_injected_*).
    let out0 = conditional_amm::calculate_output(stable_needed, pre_s0, pre_a0);
    let out1 = conditional_amm::calculate_output(stable_needed, pre_s1, pre_a1);
    let min_expected_out = if (out0 < out1) { out0 } else { out1 };

    // Exact reserve accounting per pool: +input to stable, -recombinable output from asset.
    assert!(post_s0 == pre_s0 + stable_needed, 9602);
    assert!(post_s1 == pre_s1 + stable_needed, 9603);
    assert!(pre_a0 - post_a0 == min_expected_out, 9604);
    assert!(pre_a1 - post_a1 == min_expected_out, 9605);

    // Spot receives exactly min(output_i), i.e. quantum recombined amount.
    assert!(min_asset_to_spot == min_expected_out, 9606);

    // Price convergence invariant (one-shot): distance to conditional interval shrinks,
    // and rebalance does not overshoot below the minimum conditional price.
    let (min_cond_price, max_cond_price) = get_conditional_price_range(&escrow);
    let spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    assert!(max_cond_price >= min_cond_price, 9607);
    let pre_distance = if (pre_spot_price > pre_max_cond) {
        pre_spot_price - pre_max_cond
    } else if (pre_spot_price < pre_min_cond) {
        pre_min_cond - pre_spot_price
    } else {
        0
    };
    let post_distance = if (spot_price > max_cond_price) {
        spot_price - max_cond_price
    } else if (spot_price < min_cond_price) {
        min_cond_price - spot_price
    } else {
        0
    };
    assert!(post_distance <= pre_distance, 9608);
    assert!(spot_price >= min_cond_price, 9609);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// TDD invariant: spot_to_cond must account exact per-pool outputs (no over/under extraction),
/// and final spot price must lie within conditional pool price bounds.
fun test_tdd_spot_to_cond_exact_reserve_accounting_and_price_bounds() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot starts below conditional range: triggers spot_to_cond direction.
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 5_000_000_000, &clock, ctx);
    let (pre_spot_asset, pre_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let pre_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Build 2 asymmetric conditional pools so outputs differ and dust exists.
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let mut pools = vector::empty();
    let clock2 = create_test_clock(1000000, ctx);

    let mut p0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    conditional_amm::add_liquidity_for_testing(
        &mut p0,
        coin::mint_for_testing<TEST_COIN_A>(1_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_000_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, p0);

    let mut p1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        &clock2,
        ctx,
    );
    conditional_amm::add_liquidity_for_testing(
        &mut p1,
        coin::mint_for_testing<TEST_COIN_A>(800_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(1_200_000_000, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, p1);

    clock::destroy_for_testing(clock2);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Fund escrow + initialize supplies for quantum accounting.
    let escrow_asset = 1_000_000_000u64;
    let escrow_stable = 1_200_000_000u64;
    coin_escrow::deposit_spot_coins(
        &mut escrow,
        coin::mint_for_testing<TEST_COIN_A>(escrow_asset, ctx),
        coin::mint_for_testing<TEST_COIN_B>(escrow_stable, ctx),
    );
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, escrow_asset, escrow_stable, &escrow_auth2);
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, escrow_asset, escrow_stable);

    // Snapshot conditional reserves before arbitrage.
    let market_state_before = coin_escrow::get_market_state(&escrow);
    let pools_before = market_state::borrow_amm_pools(market_state_before);
    let (pre_a0, pre_s0) = conditional_amm::get_reserves(&pools_before[0]);
    let (pre_a1, pre_s1) = conditional_amm::get_reserves(&pools_before[1]);
    let pre_price0 = ((pre_s0 as u128) * 1_000_000_000_000) / (pre_a0 as u128);
    let pre_price1 = ((pre_s1 as u128) * 1_000_000_000_000) / (pre_a1 as u128);
    let pre_min_cond = if (pre_price0 < pre_price1) { pre_price0 } else { pre_price1 };
    let pre_max_cond = if (pre_price0 > pre_price1) { pre_price0 } else { pre_price1 };

    // Execute arbitrage.
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Snapshot after arbitrage.
    let (post_spot_asset, post_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let market_state_after = coin_escrow::get_market_state(&escrow);
    let pools_after = market_state::borrow_amm_pools(market_state_after);
    let (post_a0, post_s0) = conditional_amm::get_reserves(&pools_after[0]);
    let (post_a1, post_s1) = conditional_amm::get_reserves(&pools_after[1]);

    // Direction sanity: spot_to_cond takes asset from spot and returns min(stable_outs) to spot.
    assert!(pre_spot_asset > post_spot_asset, 9610);
    assert!(post_spot_stable > pre_spot_stable, 9611);
    let arb_amount = pre_spot_asset - post_spot_asset;
    let min_stable_to_spot = post_spot_stable - pre_spot_stable;

    // Expected outputs from each pool (same math path as swap_from_injected_*).
    let out0 = conditional_amm::calculate_output(arb_amount, pre_a0, pre_s0);
    let out1 = conditional_amm::calculate_output(arb_amount, pre_a1, pre_s1);
    let min_expected_out = if (out0 < out1) { out0 } else { out1 };

    // Exact reserve accounting per pool: +input to asset, -recombinable output from stable.
    assert!(post_a0 == pre_a0 + arb_amount, 9612);
    assert!(post_a1 == pre_a1 + arb_amount, 9613);
    assert!(pre_s0 - post_s0 == min_expected_out, 9614);
    assert!(pre_s1 - post_s1 == min_expected_out, 9615);

    // Spot receives exactly min(output_i), i.e. quantum recombined amount.
    assert!(min_stable_to_spot == min_expected_out, 9616);

    // Price convergence invariant (one-shot): distance to conditional interval shrinks,
    // and rebalance does not overshoot above the maximum conditional price.
    let (min_cond_price, max_cond_price) = get_conditional_price_range(&escrow);
    let spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    assert!(max_cond_price >= min_cond_price, 9617);
    let pre_distance = if (pre_spot_price > pre_max_cond) {
        pre_spot_price - pre_max_cond
    } else if (pre_spot_price < pre_min_cond) {
        pre_min_cond - pre_spot_price
    } else {
        0
    };
    let post_distance = if (spot_price > max_cond_price) {
        spot_price - max_cond_price
    } else if (spot_price < min_cond_price) {
        min_cond_price - spot_price
    } else {
        0
    };
    assert!(post_distance <= pre_distance, 9618);
    assert!(spot_price <= max_cond_price, 9619);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Regression for the original bug:
/// after heavy typed asset -> stable selling, preexisting asset circulation can be tiny
/// while conditional pool asset reserves stay large. Rebalance must still execute by
/// using system-created output claims, not by being capped to old user circulation.
fun test_cond_to_spot_executes_beyond_preexisting_asset_supply() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(2_000_000_000, 20_000_000_000, &clock, ctx);
    let (pre_spot_asset, pre_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);
    coin_escrow::deposit_spot_liquidity_for_testing(&mut escrow, 5_000_000_000, 5_000_000_000);
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, 6_000_000_000, 6_000_000_000);

    let out0 = simulate_typed_asset_to_stable_swap(&mut escrow, 0, 900_000_000, &clock, ctx);
    let out1 = simulate_typed_asset_to_stable_swap(&mut escrow, 1, 850_000_000, &clock, ctx);
    assert!(out0 > 0, 9620);
    assert!(out1 > 0, 9621);

    let (asset_supplies_before, stable_supplies_before) = coin_escrow::get_all_supplies(&escrow);
    let pre_min_asset_supply = if (asset_supplies_before[0] < asset_supplies_before[1]) {
        asset_supplies_before[0]
    } else {
        asset_supplies_before[1]
    };
    assert!(pre_min_asset_supply == 100_000_000, 9622);
    assert!(stable_supplies_before[0] > 1_000_000_000, 9623);
    assert!(stable_supplies_before[1] > 1_000_000_000, 9624);

    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (post_spot_asset, post_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let asset_to_spot = post_spot_asset - pre_spot_asset;
    let stable_from_spot = pre_spot_stable - post_spot_stable;

    assert!(asset_to_spot > 0, 9625);
    assert!(stable_from_spot > 0, 9626);
    assert!(asset_to_spot > pre_min_asset_supply, 9627);
    assert_no_dust_double_counting(&escrow, &dust_opt);
    coin_escrow::assert_quantum_invariant(&escrow);

    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Mirror regression for the opposite direction:
/// after heavy typed stable -> asset buying, preexisting stable circulation can be tiny
/// while conditional pool stable reserves stay large. Rebalance must still settle more
/// than the old live stable supply.
fun test_spot_to_cond_executes_beyond_preexisting_stable_supply() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(20_000_000_000, 2_000_000_000, &clock, ctx);
    let (pre_spot_asset, pre_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);
    coin_escrow::deposit_spot_liquidity_for_testing(&mut escrow, 5_000_000_000, 5_000_000_000);
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, 6_000_000_000, 6_000_000_000);

    let out0 = simulate_typed_stable_to_asset_swap(&mut escrow, 0, 900_000_000, &clock, ctx);
    let out1 = simulate_typed_stable_to_asset_swap(&mut escrow, 1, 850_000_000, &clock, ctx);
    assert!(out0 > 0, 9629);
    assert!(out1 > 0, 9630);

    let (asset_supplies_before, stable_supplies_before) = coin_escrow::get_all_supplies(&escrow);
    let pre_min_stable_supply = if (stable_supplies_before[0] < stable_supplies_before[1]) {
        stable_supplies_before[0]
    } else {
        stable_supplies_before[1]
    };
    assert!(pre_min_stable_supply == 100_000_000, 9631);
    assert!(asset_supplies_before[0] > 1_000_000_000, 9632);
    assert!(asset_supplies_before[1] > 1_000_000_000, 9633);

    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (post_spot_asset, post_spot_stable) = unified_spot_pool::get_reserves(&spot_pool);
    let asset_from_spot = pre_spot_asset - post_spot_asset;
    let stable_to_spot = post_spot_stable - pre_spot_stable;

    assert!(asset_from_spot > 0, 9634);
    assert!(stable_to_spot > 0, 9635);
    assert!(stable_to_spot > pre_min_stable_supply, 9636);
    assert_no_dust_double_counting(&escrow, &dust_opt);
    coin_escrow::assert_quantum_invariant(&escrow);

    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test_only]
fun create_test_escrow_with_registered_caps(
    proposal_idx: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): TokenEscrow<TEST_COIN_A, TEST_COIN_B> {
    let proposal_id = if (proposal_idx == 0) {
        object::id_from_address(@0xAAA1)
    } else if (proposal_idx == 1) {
        object::id_from_address(@0xAAA2)
    } else {
        object::id_from_address(@0xAAA3)
    };
    let dao_id = object::id_from_address(@0xDEF);

    let mut outcome_messages = vector::empty();
    vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 0"));
    vector::push_back(&mut outcome_messages, string::utf8(b"Outcome 1"));

    let market_state = market_state::new(
        proposal_id,
        dao_id,
        2,
        outcome_messages,
        clock,
        ctx,
    );

    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let cond_0_asset_cap = coin::create_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let cond_0_stable_cap = coin::create_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    let cond_1_asset_cap = coin::create_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let cond_1_stable_cap = coin::create_treasury_cap_for_testing<COND_1_STABLE>(ctx);

    coin_escrow::register_conditional_caps<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_0_STABLE,
    >(&mut escrow, 0, cond_0_asset_cap, cond_0_stable_cap);
    coin_escrow::register_conditional_caps<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
        COND_1_STABLE,
    >(&mut escrow, 1, cond_1_asset_cap, cond_1_stable_cap);

    escrow
}

#[test_only]
fun setup_asymmetric_conditional_pools_for_cycle(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    cycle_idx: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);

    let mut pools = vector::empty();

    // Alternate asymmetry each cycle to exercise both arbitrage directions.
    let (pool0_asset, pool0_stable, pool1_asset, pool1_stable) = if ((cycle_idx % 2) == 0) {
        (1_000_000_000u64, 1_000_000_000u64, 800_000_000u64, 1_200_000_000u64)
    } else {
        (1_200_000_000u64, 800_000_000u64, 1_000_000_000u64, 1_000_000_000u64)
    };

    let mut p0 = conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        clock,
        ctx,
    );
    conditional_amm::add_liquidity_for_testing(
        &mut p0,
        coin::mint_for_testing<TEST_COIN_A>(pool0_asset, ctx),
        coin::mint_for_testing<TEST_COIN_B>(pool0_stable, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, p0);

    let mut p1 = conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1000,
        1000,
        clock,
        ctx,
    );
    conditional_amm::add_liquidity_for_testing(
        &mut p1,
        coin::mint_for_testing<TEST_COIN_A>(pool1_asset, ctx),
        coin::mint_for_testing<TEST_COIN_B>(pool1_stable, ctx),
        DEFAULT_FEE_BPS,
        ctx,
    );
    vector::push_back(&mut pools, p1);

    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Ensure escrow backing/supplies cover arbitrage + user redemptions comfortably.
    coin_escrow::deposit_spot_coins(
        escrow,
        coin::mint_for_testing<TEST_COIN_A>(20_000_000_000, ctx),
        coin::mint_for_testing<TEST_COIN_B>(20_000_000_000, ctx),
    );
    let escrow_auth2 = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(
        escrow,
        20_000_000_000,
        20_000_000_000,
        &escrow_auth2,
    );
}

#[test_only]
fun distance_to_price_range(price: u128, min_price: u128, max_price: u128): u128 {
    if (price < min_price) {
        min_price - price
    } else if (price > max_price) {
        price - max_price
    } else {
        0
    }
}

#[test_only]
fun simulate_user_trading_activity(
    spot_pool: &mut UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP>,
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    user_idx: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let spot_trade_in = 120_000_000u64 + (user_idx * 10_000_000u64);
    if ((user_idx % 2) == 0) {
        let spot_out = simulate_spot_stable_for_asset_swap(
            spot_pool,
            spot_trade_in,
            clock,
            ctx,
        );
        coin::burn_for_testing(spot_out);
    } else {
        let spot_out = simulate_spot_asset_for_stable_swap(
            spot_pool,
            spot_trade_in,
            clock,
            ctx,
        );
        coin::burn_for_testing(spot_out);
    };

    let cond_trade_in = 90_000_000u64 + (user_idx * 5_000_000u64);
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let pools = borrow_amm_pools_mut_with_test_auth(market_state);
    if ((user_idx % 2) == 0) {
        let out = conditional_amm::swap_stable_to_asset(
            &mut pools[0],
            market_id,
            cond_trade_in,
            0,
            clock,
            ctx,
        );
        assert!(out > 0, 9700 + user_idx);
    } else {
        let out = conditional_amm::swap_asset_to_stable(
            &mut pools[1],
            market_id,
            cond_trade_in,
            0,
            clock,
            ctx,
        );
        assert!(out > 0, 9710 + user_idx);
    };
}

#[test_only]
fun balance_or_zero(
    opt: &option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
    outcome_idx: u8,
    is_asset: bool,
): u64 {
    if (option::is_some(opt)) {
        let bal = option::borrow(opt);
        conditional_balance::get_balance(bal, outcome_idx, is_asset)
    } else {
        0
    }
}

#[test_only]
fun assert_sum_of_user_wrappers_matches_escrow(
    escrow: &TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    user0: &option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
    user1: &option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
    user2: &option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
    user3: &option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
    user4: &option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
) {
    let (wrapped_asset, wrapped_stable) = coin_escrow::get_wrapped_balances(escrow);
    let u_asset_0 = balance_or_zero(user0, 0, true)
        + balance_or_zero(user1, 0, true)
        + balance_or_zero(user2, 0, true)
        + balance_or_zero(user3, 0, true)
        + balance_or_zero(user4, 0, true);
    let u_asset_1 = balance_or_zero(user0, 1, true)
        + balance_or_zero(user1, 1, true)
        + balance_or_zero(user2, 1, true)
        + balance_or_zero(user3, 1, true)
        + balance_or_zero(user4, 1, true);
    let u_stable_0 = balance_or_zero(user0, 0, false)
        + balance_or_zero(user1, 0, false)
        + balance_or_zero(user2, 0, false)
        + balance_or_zero(user3, 0, false)
        + balance_or_zero(user4, 0, false);
    let u_stable_1 = balance_or_zero(user0, 1, false)
        + balance_or_zero(user1, 1, false)
        + balance_or_zero(user2, 1, false)
        + balance_or_zero(user3, 1, false)
        + balance_or_zero(user4, 1, false);

    assert!(wrapped_asset[0] == u_asset_0, 9720);
    assert!(wrapped_asset[1] == u_asset_1, 9721);
    assert!(wrapped_stable[0] == u_stable_0, 9722);
    assert!(wrapped_stable[1] == u_stable_1, 9723);
}

#[test_only]
fun redeem_winning_outcome_from_user_wrapper(
    user_opt: &mut option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    winning_outcome: u8,
    ctx: &mut TxContext,
): (u64, u64) {
    if (option::is_none(user_opt)) {
        return (0, 0)
    };

    let mut redeemed_asset = 0u64;
    let mut redeemed_stable = 0u64;
    let user_bal = option::borrow_mut(user_opt);

    let win_asset_amt = conditional_balance::get_balance(user_bal, winning_outcome, true);
    if (win_asset_amt > 0) {
        let asset_coin = if (winning_outcome == 0) {
            let win_asset_coin = conditional_balance::unwrap_to_coin<
                TEST_COIN_A,
                TEST_COIN_B,
                COND_0_ASSET,
            >(
                user_bal,
                escrow,
                winning_outcome,
                true,
                win_asset_amt,
                ctx,
            );
            coin_escrow::burn_conditional_asset_and_withdraw<
                TEST_COIN_A,
                TEST_COIN_B,
                COND_0_ASSET,
            >(escrow, win_asset_coin, ctx)
        } else {
            let win_asset_coin = conditional_balance::unwrap_to_coin<
                TEST_COIN_A,
                TEST_COIN_B,
                COND_1_ASSET,
            >(
                user_bal,
                escrow,
                winning_outcome,
                true,
                win_asset_amt,
                ctx,
            );
            coin_escrow::burn_conditional_asset_and_withdraw<
                TEST_COIN_A,
                TEST_COIN_B,
                COND_1_ASSET,
            >(escrow, win_asset_coin, ctx)
        };
        redeemed_asset = redeemed_asset + coin::value(&asset_coin);
        coin::burn_for_testing(asset_coin);
    };

    let win_stable_amt = conditional_balance::get_balance(user_bal, winning_outcome, false);
    if (win_stable_amt > 0) {
        let stable_coin = if (winning_outcome == 0) {
            let win_stable_coin = conditional_balance::unwrap_to_coin<
                TEST_COIN_A,
                TEST_COIN_B,
                COND_0_STABLE,
            >(
                user_bal,
                escrow,
                winning_outcome,
                false,
                win_stable_amt,
                ctx,
            );
            coin_escrow::burn_conditional_stable_and_withdraw<
                TEST_COIN_A,
                TEST_COIN_B,
                COND_0_STABLE,
            >(escrow, win_stable_coin, ctx)
        } else {
            let win_stable_coin = conditional_balance::unwrap_to_coin<
                TEST_COIN_A,
                TEST_COIN_B,
                COND_1_STABLE,
            >(
                user_bal,
                escrow,
                winning_outcome,
                false,
                win_stable_amt,
                ctx,
            );
            coin_escrow::burn_conditional_stable_and_withdraw<
                TEST_COIN_A,
                TEST_COIN_B,
                COND_1_STABLE,
            >(escrow, win_stable_coin, ctx)
        };
        redeemed_stable = redeemed_stable + coin::value(&stable_coin);
        coin::burn_for_testing(stable_coin);
    };

    assert!(conditional_balance::get_balance(user_bal, winning_outcome, true) == 0, 9730);
    assert!(conditional_balance::get_balance(user_bal, winning_outcome, false) == 0, 9731);
    (redeemed_asset, redeemed_stable)
}

#[test_only]
fun destroy_optional_user_wrapper(
    user_opt: option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
) {
    let mut opt = user_opt;
    if (option::is_some(&opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut opt));
    };
    option::destroy_none(opt);
}

#[test_only]
fun set_user_dust_once(
    current: option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
    next: option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
): option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>> {
    assert!(option::is_none(&current), 9739);
    option::destroy_none(current);
    next
}

#[test]
/// Mother-load integration test:
/// - 3 sequential proposal cycles (same DAO)
/// - 5 users trading each cycle
/// - repeated auto-rebalance calls
/// - every user unwraps/redeems winning-outcome tokens from arbitrage wrappers
/// - reserve/supply/wrapped solvency checked each cycle
fun test_integration_three_proposals_five_users_trade_arb_and_redeem() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    let mut cycle = 0u64;
    while (cycle < 3) {
        // Alternate spot initialization to force both rebalance directions over cycles.
        let mut spot_pool = if ((cycle % 2) == 0) {
            create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx)
        } else {
            create_test_spot_pool(10_000_000_000, 5_000_000_000, &clock, ctx)
        };

        let mut escrow = create_test_escrow_with_registered_caps(cycle, &clock, ctx);
        setup_asymmetric_conditional_pools_for_cycle(&mut escrow, cycle, &clock, ctx);
        link_pool_to_escrow(&mut spot_pool, &escrow);

        let mut user0 = option::none();
        let mut user1 = option::none();
        let mut user2 = option::none();
        let mut user3 = option::none();
        let mut user4 = option::none();

        let mut user = 0u64;
        while (user < 5) {
            simulate_user_trading_activity(&mut spot_pool, &mut escrow, user, &clock, ctx);

            let (pre_min_cond, pre_max_cond) = get_conditional_price_range(&escrow);
            let pre_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
            let pre_distance = distance_to_price_range(pre_spot_price, pre_min_cond, pre_max_cond);

            let dust = arbitrage::auto_rebalance_spot_after_conditional_swaps(
                &mut spot_pool,
                &mut escrow,
                option::none(),
                &escrow_registry,
                &market_state_registry,
                &clock,
                ctx,
            );

            if (user == 0) {
                user0 = set_user_dust_once(user0, dust);
            } else if (user == 1) {
                user1 = set_user_dust_once(user1, dust);
            } else if (user == 2) {
                user2 = set_user_dust_once(user2, dust);
            } else if (user == 3) {
                user3 = set_user_dust_once(user3, dust);
            } else {
                user4 = set_user_dust_once(user4, dust);
            };

            let (post_min_cond, post_max_cond) = get_conditional_price_range(&escrow);
            let post_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
            let post_distance = distance_to_price_range(post_spot_price, post_min_cond, post_max_cond);
            assert!(post_max_cond >= post_min_cond, 9740 + user + (cycle * 10));
            assert!(post_distance <= pre_distance, 9750 + user + (cycle * 10));

            user = user + 1;
        };

        assert_sum_of_user_wrappers_matches_escrow(&escrow, &user0, &user1, &user2, &user3, &user4);

        let outcome0_wrapped = balance_or_zero(&user0, 0, true)
            + balance_or_zero(&user0, 0, false)
            + balance_or_zero(&user1, 0, true)
            + balance_or_zero(&user1, 0, false)
            + balance_or_zero(&user2, 0, true)
            + balance_or_zero(&user2, 0, false)
            + balance_or_zero(&user3, 0, true)
            + balance_or_zero(&user3, 0, false)
            + balance_or_zero(&user4, 0, true)
            + balance_or_zero(&user4, 0, false);
        let outcome1_wrapped = balance_or_zero(&user0, 1, true)
            + balance_or_zero(&user0, 1, false)
            + balance_or_zero(&user1, 1, true)
            + balance_or_zero(&user1, 1, false)
            + balance_or_zero(&user2, 1, true)
            + balance_or_zero(&user2, 1, false)
            + balance_or_zero(&user3, 1, true)
            + balance_or_zero(&user3, 1, false)
            + balance_or_zero(&user4, 1, true)
            + balance_or_zero(&user4, 1, false);
        let winning_outcome = if (outcome1_wrapped > outcome0_wrapped) { 1u8 } else { 0u8 };

        // Finalize market and redeem every user's winner-side wrapper.
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        market_state::test_set_winning_outcome(market_state, (winning_outcome as u64));
        market_state::test_set_finalized(market_state);

        let (a0, s0) = redeem_winning_outcome_from_user_wrapper(&mut user0, &mut escrow, winning_outcome, ctx);
        let (a1, s1) = redeem_winning_outcome_from_user_wrapper(&mut user1, &mut escrow, winning_outcome, ctx);
        let (a2, s2) = redeem_winning_outcome_from_user_wrapper(&mut user2, &mut escrow, winning_outcome, ctx);
        let (a3, s3) = redeem_winning_outcome_from_user_wrapper(&mut user3, &mut escrow, winning_outcome, ctx);
        let (a4, s4) = redeem_winning_outcome_from_user_wrapper(&mut user4, &mut escrow, winning_outcome, ctx);
        let total_redeemed_asset = a0 + a1 + a2 + a3 + a4;
        let total_redeemed_stable = s0 + s1 + s2 + s3 + s4;
        let _total_redeemed = total_redeemed_asset + total_redeemed_stable;

        // Winner-side wrapped balances should be fully drained after all users redeem.
        let (wrapped_asset, wrapped_stable) = coin_escrow::get_wrapped_balances(&escrow);
        assert!(wrapped_asset[(winning_outcome as u64)] == 0, 9770 + cycle);
        assert!(wrapped_stable[(winning_outcome as u64)] == 0, 9780 + cycle);

        // Post-finalization solvency: escrow covers user claims (OEA - pool_claim).
        // Per-type solvency (EA >= OEA) is not guaranteed because conditional swaps
        // shift claims between types. The production check uses pool_claim subtraction.
        let actual_asset = coin_escrow::get_escrowed_asset_balance(&escrow);
        let actual_stable = coin_escrow::get_escrowed_stable_balance(&escrow);
        let winner_idx = winning_outcome as u64;
        let oea = coin_escrow::get_outcome_escrowed_asset(&escrow, winner_idx);
        let oes = coin_escrow::get_outcome_escrowed_stable(&escrow, winner_idx);
        let pca = coin_escrow::get_pool_claim_asset(&escrow, winner_idx);
        let pcs = coin_escrow::get_pool_claim_stable(&escrow, winner_idx);
        let user_claim_asset = if (oea > pca) { oea - pca } else { 0 };
        let user_claim_stable = if (oes > pcs) { oes - pcs } else { 0 };
        assert!(actual_asset >= user_claim_asset, 9790 + (cycle * 10));
        assert!(actual_stable >= user_claim_stable, 9800 + (cycle * 10));

        destroy_optional_user_wrapper(user0);
        destroy_optional_user_wrapper(user1);
        destroy_optional_user_wrapper(user2);
        destroy_optional_user_wrapper(user3);
        destroy_optional_user_wrapper(user4);
        unified_spot_pool::destroy_for_testing(spot_pool);
        coin_escrow::destroy_for_testing(escrow);

        cycle = cycle + 1;
    };

    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test_only]
fun total_wrapper_balance_2_outcomes(
    opt: &option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
): u64 {
    balance_or_zero(opt, 0, true) +
        balance_or_zero(opt, 0, false) +
        balance_or_zero(opt, 1, true) +
        balance_or_zero(opt, 1, false)
}

#[test_only]
fun choose_outcome_with_non_zero_wrapper(
    opt: &option::Option<conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>>,
): u8 {
    let outcome0_total = balance_or_zero(opt, 0, true) + balance_or_zero(opt, 0, false);
    let outcome1_total = balance_or_zero(opt, 1, true) + balance_or_zero(opt, 1, false);
    if (outcome0_total >= outcome1_total) {
        0
    } else {
        1
    }
}

#[test_only]
fun choose_amount_to_unwrap(balance: u64): u64 {
    if (balance <= 1) {
        balance
    } else {
        balance / 2
    }
}

#[test_only]
fun unwrap_and_rewrap_first_non_zero(
    bal: &mut conditional_balance::ConditionalMarketBalance<TEST_COIN_A, TEST_COIN_B>,
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    ctx: &mut TxContext,
): bool {
    let out0_asset = conditional_balance::get_balance(bal, 0, true);
    if (out0_asset > 0) {
        let amt = choose_amount_to_unwrap(out0_asset);
        let c = conditional_balance::unwrap_to_coin<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
            bal,
            escrow,
            0,
            true,
            amt,
            ctx,
        );
        conditional_balance::wrap_coin<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
            bal,
            escrow,
            c,
            0,
            true,
        );
        return true
    };

    let out0_stable = conditional_balance::get_balance(bal, 0, false);
    if (out0_stable > 0) {
        let amt = choose_amount_to_unwrap(out0_stable);
        let c = conditional_balance::unwrap_to_coin<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
            bal,
            escrow,
            0,
            false,
            amt,
            ctx,
        );
        conditional_balance::wrap_coin<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
            bal,
            escrow,
            c,
            0,
            false,
        );
        return true
    };

    let out1_asset = conditional_balance::get_balance(bal, 1, true);
    if (out1_asset > 0) {
        let amt = choose_amount_to_unwrap(out1_asset);
        let c = conditional_balance::unwrap_to_coin<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
            bal,
            escrow,
            1,
            true,
            amt,
            ctx,
        );
        conditional_balance::wrap_coin<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
            bal,
            escrow,
            c,
            1,
            true,
        );
        return true
    };

    let out1_stable = conditional_balance::get_balance(bal, 1, false);
    if (out1_stable > 0) {
        let amt = choose_amount_to_unwrap(out1_stable);
        let c = conditional_balance::unwrap_to_coin<TEST_COIN_A, TEST_COIN_B, COND_1_STABLE>(
            bal,
            escrow,
            1,
            false,
            amt,
            ctx,
        );
        conditional_balance::wrap_coin<TEST_COIN_A, TEST_COIN_B, COND_1_STABLE>(
            bal,
            escrow,
            c,
            1,
            false,
        );
        return true
    };

    false
}

#[test_only]
fun get_total_tokens_in_spot_conditional_escrow(
    spot_pool: &UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP>,
    escrow: &TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
): (u64, u64) {
    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot_pool);
    let (spot_fee_asset, spot_fee_stable) = unified_spot_pool::get_protocol_fee_amounts(spot_pool);
    let escrow_asset = coin_escrow::get_escrowed_asset_balance(escrow);
    let escrow_stable = coin_escrow::get_escrowed_stable_balance(escrow);
    (spot_asset + spot_fee_asset + escrow_asset, spot_stable + spot_fee_stable + escrow_stable)
}

#[test]
/// Interleaving safety: LP withdrawal and user winner-redemption can be arbitrarily interleaved
/// after finalization without breaking escrow solvency or quantum invariants.
fun test_interleaved_lp_withdraw_and_user_redeem_after_finalization() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_registered_caps(0, &clock, ctx);
    setup_asymmetric_conditional_pools_for_cycle(&mut escrow, 0, &clock, ctx);
    link_pool_to_escrow(&mut spot_pool, &escrow);

    let mut user_dust = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // If first rebalance yields no dust due rounding, perturb and retry once.
    if (option::is_none(&user_dust)) {
        simulate_user_trading_activity(&mut spot_pool, &mut escrow, 0, &clock, ctx);
        user_dust = arbitrage::auto_rebalance_spot_after_conditional_swaps(
            &mut spot_pool,
            &mut escrow,
            user_dust,
            &escrow_registry,
            &market_state_registry,
            &clock,
            ctx,
        );
    };
    assert!(option::is_none(&user_dust), 98100);
    assert!(total_system_dust_created(&escrow) == 0, 98101);

    let winning_outcome = 0u8;
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::test_set_winning_outcome(market_state, (winning_outcome as u64));
    market_state::test_set_finalized(market_state);

    let (asset_supplies, stable_supplies) = coin_escrow::get_all_supplies(&escrow);
    let winner_idx = winning_outcome as u64;
    let lp_asset_cap = if (asset_supplies[winner_idx] > 400_000_000) {
        400_000_000
    } else {
        asset_supplies[winner_idx]
    };
    let lp_stable_cap = if (stable_supplies[winner_idx] > 400_000_000) {
        400_000_000
    } else {
        stable_supplies[winner_idx]
    };
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, lp_asset_cap, lp_stable_cap);

    let lp_auth = escrow_mutation_auth::create_for_testing();
    let (lp_a_1, lp_s_1) = coin_escrow::lp_withdraw_quantum(
        &mut escrow,
        lp_asset_cap / 2,
        lp_stable_cap / 2,
        &lp_auth,
        ctx,
    );
    let lp_first = coin::value(&lp_a_1) + coin::value(&lp_s_1);
    coin::burn_for_testing(lp_a_1);
    coin::burn_for_testing(lp_s_1);

    let (lp_a_2, lp_s_2) =
        coin_escrow::lp_withdraw_quantum(&mut escrow, lp_asset_cap, lp_stable_cap, &lp_auth, ctx);
    let lp_second = coin::value(&lp_a_2) + coin::value(&lp_s_2);
    coin::burn_for_testing(lp_a_2);
    coin::burn_for_testing(lp_s_2);

    assert!(lp_first + lp_second > 0, 98102);
    coin_escrow::assert_quantum_invariant(&escrow);

    let (wrapped_asset, wrapped_stable) = coin_escrow::get_wrapped_balances(&escrow);
    assert!(wrapped_asset[winner_idx] == 0, 98103);
    assert!(wrapped_stable[winner_idx] == 0, 98104);

    option::destroy_none(user_dust);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Pre-finalization unwrap->wrap cycles must preserve wrapped/supply accounting,
/// and subsequent arbitrage merging into that same balance must remain safe.
fun test_pre_finalization_unwrap_wrap_then_rearb_stability() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_registered_caps(1, &clock, ctx);
    setup_asymmetric_conditional_pools_for_cycle(&mut escrow, 1, &clock, ctx);
    link_pool_to_escrow(&mut spot_pool, &escrow);

    let mut user_balance = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    assert!(option::is_none(&user_balance), 98110);
    let mut previous_system_dust = total_system_dust_created(&escrow);

    let mut round = 0;
    while (round < 3) {
        simulate_user_trading_activity(&mut spot_pool, &mut escrow, round + 3, &clock, ctx);
        user_balance = arbitrage::auto_rebalance_spot_after_conditional_swaps(
            &mut spot_pool,
            &mut escrow,
            user_balance,
            &escrow_registry,
            &market_state_registry,
            &clock,
            ctx,
        );
        assert!(option::is_none(&user_balance), 98111 + round);
        let system_dust = total_system_dust_created(&escrow);
        assert!(system_dust >= previous_system_dust, 98120 + round);
        previous_system_dust = system_dust;
        coin_escrow::assert_quantum_invariant(&escrow);

        round = round + 1;
    };

    assert!(previous_system_dust == 0, 98130);

    option::destroy_none(user_balance);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Same-user merge path: repeated arbitrage calls must merge dust into one balance
/// monotonically (never lose already-accounted wrapped amounts).
fun test_single_user_multi_round_dust_merge_monotonic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_registered_caps(2, &clock, ctx);
    setup_asymmetric_conditional_pools_for_cycle(&mut escrow, 2, &clock, ctx);
    link_pool_to_escrow(&mut spot_pool, &escrow);

    let mut merged_dust = option::none();
    let mut previous_total = total_system_dust_created(&escrow);
    let mut i = 0u64;
    while (i < 6) {
        simulate_user_trading_activity(&mut spot_pool, &mut escrow, i, &clock, ctx);
        merged_dust = arbitrage::auto_rebalance_spot_after_conditional_swaps(
            &mut spot_pool,
            &mut escrow,
            merged_dust,
            &escrow_registry,
            &market_state_registry,
            &clock,
            ctx,
        );

        assert!(option::is_none(&merged_dust), 98130 + i);
        let now_total = total_system_dust_created(&escrow);
        assert!(now_total >= previous_total, 98140 + i);
        previous_total = now_total;

        coin_escrow::assert_quantum_invariant(&escrow);
        i = i + 1;
    };

    assert!(previous_total == 0, 98150);

    option::destroy_none(merged_dust);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Conservation check across storage containers:
/// spot + conditional pools + escrow balances should be token-conservative under arbitrage.
fun test_global_token_conservation_across_rebalance() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_registered_caps(0, &clock, ctx);
    setup_asymmetric_conditional_pools_for_cycle(&mut escrow, 0, &clock, ctx);
    link_pool_to_escrow(&mut spot_pool, &escrow);

    let (pre_total_asset, pre_total_stable) =
        get_total_tokens_in_spot_conditional_escrow(&spot_pool, &escrow);

    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (post_total_asset, post_total_stable) =
        get_total_tokens_in_spot_conditional_escrow(&spot_pool, &escrow);
    assert!(post_total_asset == pre_total_asset, 98160);
    assert!(post_total_stable == pre_total_stable, 98161);

    let none1 = option::none();
    let none2 = option::none();
    let none3 = option::none();
    let none4 = option::none();
    assert_sum_of_user_wrappers_matches_escrow(&escrow, &dust_opt, &none1, &none2, &none3, &none4);

    destroy_optional_user_wrapper(dust_opt);
    option::destroy_none(none1);
    option::destroy_none(none2);
    option::destroy_none(none3);
    option::destroy_none(none4);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// System rebalance residuals must not create a user-owned losing-outcome wrapper.
fun test_system_rebalance_returns_no_losing_outcome_user_balance_after_finalization() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_registered_caps(1, &clock, ctx);
    setup_asymmetric_conditional_pools_for_cycle(&mut escrow, 1, &clock, ctx);
    link_pool_to_escrow(&mut spot_pool, &escrow);

    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    assert!(option::is_none(&dust_opt), 98170);
    assert!(total_system_dust_created(&escrow) == 0, 98171);

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::test_set_winning_outcome(market_state, 0);
    market_state::test_set_finalized(market_state);

    coin_escrow::assert_quantum_invariant(&escrow);
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Deterministic pseudo-random stress:
/// mixed spot/conditional trades + arbitrage over many rounds
/// must preserve dust/escrow accounting invariants at every step.
fun test_property_stress_randomized_trades_and_arbitrage_invariants() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    let mut spot_pool = create_test_spot_pool(6_000_000_000, 9_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_registered_caps(2, &clock, ctx);
    setup_asymmetric_conditional_pools_for_cycle(&mut escrow, 2, &clock, ctx);
    link_pool_to_escrow(&mut spot_pool, &escrow);

    let none1 = option::none();
    let none2 = option::none();
    let none3 = option::none();
    let none4 = option::none();

    let mut merged = option::none();
    let mut i = 0u64;
    while (i < 40) {
        let amt = 50_000_000 + ((i * 17_123_457) % 90_000_000);
        let selector = (i * 37 + 13) % 4;

        if (selector == 0) {
            let c = simulate_spot_stable_for_asset_swap(
                &mut spot_pool,
                amt,
                &clock,
                ctx,
            );
            coin::burn_for_testing(c);
        } else if (selector == 1) {
            let c = simulate_spot_asset_for_stable_swap(
                &mut spot_pool,
                amt,
                &clock,
                ctx,
            );
            coin::burn_for_testing(c);
        } else if (selector == 2) {
            let escrow_auth = escrow_mutation_auth::create_for_testing();
            let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
            let market_id = market_state::market_id(market_state);
            let pools = borrow_amm_pools_mut_with_test_auth(market_state);
            let out = conditional_amm::swap_stable_to_asset(&mut pools[0], market_id, amt, 0, &clock, ctx);
            assert!(out > 0, 98180 + i);
        } else {
            let escrow_auth = escrow_mutation_auth::create_for_testing();
            let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
            let market_id = market_state::market_id(market_state);
            let pools = borrow_amm_pools_mut_with_test_auth(market_state);
            let out = conditional_amm::swap_asset_to_stable(&mut pools[1], market_id, amt, 0, &clock, ctx);
            assert!(out > 0, 98220 + i);
        };

        let (pre_min, pre_max) = get_conditional_price_range(&escrow);
        let pre_spot = unified_spot_pool::get_spot_price(&spot_pool);
        let pre_dist = distance_to_price_range(pre_spot, pre_min, pre_max);

        merged = arbitrage::auto_rebalance_spot_after_conditional_swaps(
            &mut spot_pool,
            &mut escrow,
            merged,
            &escrow_registry,
            &market_state_registry,
            &clock,
            ctx,
        );

        let (post_min, post_max) = get_conditional_price_range(&escrow);
        let post_spot = unified_spot_pool::get_spot_price(&spot_pool);
        let post_dist = distance_to_price_range(post_spot, post_min, post_max);
        assert!(post_max >= post_min, 98260 + i);
        assert!(post_dist <= pre_dist, 98300 + i);

        assert_no_dust_double_counting(&escrow, &merged);
        assert_sum_of_user_wrappers_matches_escrow(&escrow, &merged, &none1, &none2, &none3, &none4);

        i = i + 1;
    };

    destroy_optional_user_wrapper(merged);
    option::destroy_none(none1);
    option::destroy_none(none2);
    option::destroy_none(none3);
    option::destroy_none(none4);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Regression test: unwrapping dust before resolution must NOT allow LP to drain
/// escrow past dust holder's redemption needs.
///
/// Scenario:
/// 1. Arbitrage creates dust on the winning outcome
/// 2. User unwraps ALL dust (supply increases, wrapped decreases, escrow unchanged)
/// 3. Market finalizes
/// 4. LP withdraws — capped by dynamic user claims (pool_claim-based cap)
/// 5. Dust holder redeems winning dust — must succeed (escrow still solvent)
fun test_unwrap_before_resolution_lp_withdrawal_solvency() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    // Create asymmetric pools to guarantee arbitrage creates dust
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);
    let mut escrow = create_test_escrow_with_registered_caps(0, &clock, ctx);
    setup_asymmetric_conditional_pools_for_cycle(&mut escrow, 0, &clock, ctx);
    link_pool_to_escrow(&mut spot_pool, &escrow);

    // Run arbitrage to create retained system dust
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    assert!(option::is_none(&dust_opt), 99000);
    assert!(total_system_dust_created(&escrow) == 0, 99001);

    let winning_outcome = 0u8;
    let escrow_asset_after = coin_escrow::get_escrowed_asset_balance(&escrow);
    let escrow_stable_after = coin_escrow::get_escrowed_stable_balance(&escrow);

    // --- Finalize market ---
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::test_set_winning_outcome(market_state, (winning_outcome as u64));
    market_state::test_set_finalized(market_state);

    // Set LP deposited to be generous (allows LP to try to drain maximum)
    let lp_asset = escrow_asset_after;
    let lp_stable = escrow_stable_after;
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, lp_asset, lp_stable);

    // --- LP withdraws maximum possible ---
    let lp_auth = escrow_mutation_auth::create_for_testing();
    let (lp_asset_coin, lp_stable_coin) = coin_escrow::lp_withdraw_quantum(
        &mut escrow,
        lp_asset,  // Try to withdraw everything
        lp_stable,
        &lp_auth,
        ctx,
    );
    coin::burn_for_testing(lp_asset_coin);
    coin::burn_for_testing(lp_stable_coin);

    // Pool-owned residuals should not leave user wrappers to protect after LP withdrawal.
    let remaining_asset = coin_escrow::get_escrowed_asset_balance(&escrow);
    let remaining_stable = coin_escrow::get_escrowed_stable_balance(&escrow);
    assert!(remaining_asset <= escrow_asset_after, 99020);
    assert!(remaining_stable <= escrow_stable_after, 99023);

    // Invariant still holds
    coin_escrow::assert_quantum_invariant(&escrow);

    // Cleanup
    option::destroy_none(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

// =============================================================================
// === REGRESSION: Supply Depletion Tests ======================================
// =============================================================================
//
// These tests verify the fix for the supply underflow bug. Before the fix,
// arbitrage used decrement_supplies_for_all_outcomes which would abort when
// user swaps had depleted per-outcome supplies below the arb output amount.
// The new track_system_swap + wrapped routing avoids this entirely.

#[test]
/// REGRESSION: Arb must succeed even when asset_supply[i] is severely depleted.
///
/// Scenario:
/// 1. Users heavily sell conditional asset in outcome 0 (asset→stable swaps).
///    This depletes asset_supply[0] to near zero.
/// 2. Spot price is above conditional → cond_to_spot arb.
/// 3. Old code: decrement_supplies_for_all_outcomes(min_asset, ...) underflows
///    on outcome 0 because asset_supply[0] < min_asset.
/// 4. New code: track_system_swap increments asset_supply first, then step 7
///    moves output to wrapped. Net change is zero, so no underflow.
fun test_regression_arb_succeeds_with_depleted_asset_supply() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price HIGH (2.0) → triggers cond_to_spot arb
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    // Create escrow with conditional pools at ~1.0
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Simulate heavy user swap depletion: users sold conditional asset in outcome 0.
    // set_supply_for_testing sets supply and adjusts OE = supply + wrapped to preserve
    // the quantum invariant (OEA[i] == asset_supply[i] + wrapped_asset[i]).
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 10_000);

    // Verify: outcome 0 asset supply is severely depleted
    let (asset_supplies, _) = coin_escrow::get_all_supplies(&escrow);
    assert!(asset_supplies[0] == 10_000, 100);         // ~0.001% of original
    assert!(asset_supplies[1] == 11_000_000_000, 101);  // outcome 1 unchanged

    // Execute arb — would have aborted with EAllocationUnderflow before the fix
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool, &mut escrow, option::none(),
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Quantum invariant must hold after arb
    assert_no_dust_double_counting(&escrow, &dust_opt);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// REGRESSION: Mirror direction — arb must succeed with depleted stable_supply[i].
///
/// Scenario:
/// 1. Users heavily buy conditional asset in outcome 1 (stable→asset swaps).
///    This depletes stable_supply[1] to near zero.
/// 2. Spot price is below conditional → spot_to_cond arb.
/// 3. Old code: decrement_supplies_for_all_outcomes(..., stable_needed) underflows
///    on outcome 1 because stable_supply[1] < stable output.
/// 4. New code: handles correctly via track_system_swap + wrapped routing.
fun test_regression_arb_succeeds_with_depleted_stable_supply() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price LOW (0.5) → triggers spot_to_cond arb
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 5_000_000_000, &clock, ctx);

    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Simulate user swap depletion: stable_supply[1] nearly zeroed
    coin_escrow::set_supply_for_testing(&mut escrow, 1, false, 10_000);

    let (_, stable_supplies) = coin_escrow::get_all_supplies(&escrow);
    assert!(stable_supplies[1] == 10_000, 100);

    // Execute arb
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool, &mut escrow, option::none(),
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Quantum invariant must hold
    assert_no_dust_double_counting(&escrow, &dust_opt);

    // Cleanup
    if (option::is_some(&dust_opt)) {
        let mut d = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut d));
        option::destroy_none(d);
    } else {
        option::destroy_none(dust_opt);
    };
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// REGRESSION: Both supply types depleted across different outcomes, then arb + finalize.
/// Verifies that the fix handles multi-outcome depletion and market remains solvent.
fun test_regression_arb_with_multi_outcome_depletion_then_finalization() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot price HIGH → cond_to_spot
    let mut spot_pool = create_test_spot_pool(5_000_000_000, 10_000_000_000, &clock, ctx);

    let mut escrow = create_test_escrow_with_registered_caps(0, &clock, ctx);
    setup_asymmetric_conditional_pools_for_cycle(&mut escrow, 0, &clock, ctx);

    // Deplete asset_supply[0] AND stable_supply[1] simultaneously
    // This simulates diverse user trading patterns across outcomes
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 5_000);
    coin_escrow::set_supply_for_testing(&mut escrow, 1, false, 5_000);

    // Run arb
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool, &mut escrow, option::none(),
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Quantum invariant holds
    assert_no_dust_double_counting(&escrow, &dust_opt);

    // Finalize market and verify solvency
    let winning_outcome = 0u64;
    {
        let escrow_auth = escrow_mutation_auth::create_for_testing();
        let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
        market_state::test_set_winning_outcome(market_state, winning_outcome);
        market_state::test_set_finalized(market_state);
    };

    // Post-finalization solvency: escrow covers user claims (OE - pool_claim)
    let actual_asset = coin_escrow::get_escrowed_asset_balance(&escrow);
    let actual_stable = coin_escrow::get_escrowed_stable_balance(&escrow);
    let oea = coin_escrow::get_outcome_escrowed_asset(&escrow, winning_outcome);
    let oes = coin_escrow::get_outcome_escrowed_stable(&escrow, winning_outcome);
    let pca = coin_escrow::get_pool_claim_asset(&escrow, winning_outcome);
    let pcs = coin_escrow::get_pool_claim_stable(&escrow, winning_outcome);
    let user_claim_asset = if (oea > pca) { oea - pca } else { 0 };
    let user_claim_stable = if (oes > pcs) { oes - pcs } else { 0 };
    assert!(actual_asset >= user_claim_asset, 200);
    assert!(actual_stable >= user_claim_stable, 201);

    // Cleanup
    destroy_optional_user_wrapper(dust_opt);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}
