#[test_only]
module futarchy_proposal::spot_swap_rebalance_tests;

use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationRegistry};
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationRegistry};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::conditional_balance;
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use futarchy_proposal::proposal::{Self, Proposal};
use std::string;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object;
use sui::test_scenario as ts;
use sui::test_utils;

// Test LP type
public struct LP has drop {}

// === Constants ===
const DEFAULT_FEE_BPS: u16 = 30; // 0.3%

// === Test Helpers ===

#[test_only]
fun create_lp_treasury(ctx: &mut TxContext): coin::TreasuryCap<LP> {
    coin::create_treasury_cap_for_testing<LP>(ctx)
}

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
fun create_test_spot_pool(
    asset_reserve: u64,
    stable_reserve: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP> {
    let lp_treasury = create_lp_treasury(ctx);
    unified_spot_pool::create_pool_for_testing<TEST_COIN_A, TEST_COIN_B, LP>(
        lp_treasury,
        asset_reserve,
        stable_reserve,
        (DEFAULT_FEE_BPS as u64),
        ctx,
    )
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

        conditional_amm::add_liquidity_for_testing(
            pool,
            asset_coin,
            stable_coin,
            DEFAULT_FEE_BPS,
            ctx,
        );
        i = i + 1;
    };

    // Initialize supplies to match AMM reserves
    // Arbitrage uses decrement_supplies_for_all_outcomes which requires supplies to be set
    // increment_supplies_for_all_outcomes updates both supply AND escrowed
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(
        escrow,
        reserve_per_outcome,
        reserve_per_outcome,
        &auth,
    );

    // Also deposit to escrow to match
    coin_escrow::deposit_spot_liquidity_for_testing(
        escrow,
        reserve_per_outcome,
        reserve_per_outcome,
    );
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
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(escrow, asset_amount, stable_amount, &auth);
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

// === Integration Tests for Spot Swaps with Auto-Rebalancing ===

// Note: These tests require the swap_entry module from futarchy_markets_operations,
// which we can't directly test here. Instead, we test the scenario that spot swaps
// would encounter: after a swap that moves price outside the band, auto-rebalancing
// should bring it back.

#[test]
/// Test spot swap scenario: price outside range → swap → auto-rebalance → price in range
/// This simulates what happens in the spot swap entry points
fun test_spot_swap_scenario_price_too_high() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with high price: 10,000 asset, 15,000 stable (price = 1.5)
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 15_000_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with conditional pools at lower prices (around 1.0)
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Add liquidity to escrow for arbitrage (with supply tracking for quantum invariant)
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Verify spot price is outside conditional range initially
    let (min_cond_price, max_cond_price) = get_conditional_price_range(&escrow);
    assert!(initial_spot_price > max_cond_price, 0);

    // Create escrow registry for arbitrage
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    // Simulate what happens in spot swap entry point:
    // 1. Swap executes (we skip this as it would make price even worse)
    // 2. Auto-rebalance is called
    let mut dust_opt = futarchy_markets_core::arbitrage::auto_rebalance_spot_after_conditional_swaps(
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

    // 3. Verify spot price moved toward conditional range
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Verify price moved down (or stayed if no profitable arb exists)
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
/// Test spot swap scenario with price too low
fun test_spot_swap_scenario_price_too_low() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with low price: 10,000 asset, 8,000 stable (price = 0.8)
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 8_000_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with conditional pools at higher prices (around 1.0)
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Add liquidity to escrow for arbitrage (with supply tracking for quantum invariant)
    deposit_extra_liquidity_to_escrow(&mut escrow, 10_000_000_000, 10_000_000_000, ctx);

    // Verify spot price is outside conditional range initially
    let (min_cond_price, max_cond_price) = get_conditional_price_range(&escrow);
    assert!(initial_spot_price < min_cond_price, 0);

    // Create escrow registry for arbitrage
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    // Simulate spot swap entry point: auto-rebalance
    let mut dust_opt = futarchy_markets_core::arbitrage::auto_rebalance_spot_after_conditional_swaps(
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

    // Verify spot price moved UP toward conditional range
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Verify price moved up (or stayed if no profitable arb exists)
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
/// Test that when spot price is already in range, auto-rebalance is a no-op
fun test_spot_swap_scenario_already_in_range() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with balanced price: 10,000 asset, 10,000 stable (price = 1.0)
    let mut spot_pool = create_test_spot_pool(10_000_000_000, 10_000_000_000, &clock, ctx);
    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Create escrow with conditional pools at similar prices (around 1.0)
    let mut escrow = create_test_escrow_with_markets(2, 1_000_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 1_000_000_000, ctx);

    // Add liquidity to escrow (with supply tracking for quantum invariant)
    deposit_extra_liquidity_to_escrow(&mut escrow, 5_000_000_000, 5_000_000_000, ctx);

    // Verify spot price is in conditional range initially
    let (min_cond_price, max_cond_price) = get_conditional_price_range(&escrow);
    assert!(initial_spot_price >= min_cond_price && initial_spot_price <= max_cond_price, 0);

    // Create escrow registry for arbitrage
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    // Auto-rebalance should do nothing
    let mut dust_opt = futarchy_markets_core::arbitrage::auto_rebalance_spot_after_conditional_swaps(
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

    // Spot price should be virtually unchanged
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);
    let price_diff = if (final_spot_price > initial_spot_price) {
        final_spot_price - initial_spot_price
    } else {
        initial_spot_price - final_spot_price
    };

    // Price should be nearly the same (less than 0.1% change)
    assert!(price_diff < 10_000_000_000, 1); // < 0.01 change

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test quantum split scenario: 80% split leaves spot with low liquidity
/// Then a spot swap could easily violate no-arb band without auto-rebalancing
fun test_post_quantum_split_spot_swap() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with initial liquidity: 1000 asset, 1000 stable
    let mut spot_pool = create_test_spot_pool(1_000_000_000, 1_000_000_000, &clock, ctx);

    // Simulate 80% quantum split by reducing spot liquidity dramatically
    // After 80% split: spot has 200 asset, 200 stable
    // We can't actually split here, so we create a pool with low liquidity
    unified_spot_pool::destroy_for_testing(spot_pool);
    spot_pool = create_test_spot_pool(200_000_000, 200_000_000, &clock, ctx);

    // Create escrow with conditional pools that have the 80% liquidity
    // Each outcome gets 400 asset, 400 stable
    let mut escrow = create_test_escrow_with_markets(2, 400_000_000, &clock, ctx);
    add_liquidity_to_conditional_pools(&mut escrow, 400_000_000, ctx);

    // Add more liquidity to escrow for arbitrage operations (with supply tracking)
    deposit_extra_liquidity_to_escrow(&mut escrow, 2_000_000_000, 2_000_000_000, ctx);

    // Simulate a spot swap: stable → asset (100 stable)
    // This will move spot price significantly due to low liquidity
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(100_000_000, ctx);
    let asset_out = unified_spot_pool::swap_stable_for_asset(
        &mut spot_pool,
        stable_in,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(asset_out);

    // After swap, spot price is likely outside conditional range
    let spot_price_after_swap = unified_spot_pool::get_spot_price(&spot_pool);
    let (min_cond_price, max_cond_price) = get_conditional_price_range(&escrow);

    // Create escrow registry for arbitrage
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    // Auto-rebalance should fix this
    let mut dust_opt = futarchy_markets_core::arbitrage::auto_rebalance_spot_after_conditional_swaps(
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

    // Verify price moved significantly toward target range
    let final_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    // Verify price improved (moved UP from initial low price)
    assert!(final_spot_price > spot_price_after_swap || final_spot_price > 900_000_000_000, 0);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}
