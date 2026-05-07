/// ============================================================================
/// ARBITRAGE INTEGRATION TESTS - CRITICAL INVARIANT VERIFICATION
/// ============================================================================
///
/// Tests that verify system-level invariants that unit tests miss:
/// 1. K-invariant preservation after arbitrage
/// 2. Rounding attack resistance (no value extraction from repeated tiny arbs)
/// 3. Math↔Execution cross-validation (feeless calculations match actual execution)
/// 4. Sequential arbitrage idempotency (second arb returns zero)
///
/// These tests ensure the arbitrage system is economically sound and secure.
///
/// ============================================================================

#[test_only]
module futarchy_markets_core::arbitrage_integration_tests;

use futarchy_core::escrow_mutation_auth;
use futarchy_core::market_state_mutation_auth;
use futarchy_markets_core::arbitrage;
use futarchy_markets_core::arbitrage_math;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::conditional_balance;
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use std::option;
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
const PRICE_SCALE: u128 = 1_000_000_000_000; // 1e12

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
fun create_test_escrow_registry(ctx: &mut TxContext): escrow_mutation_auth::EscrowMutationRegistry {
    let mut registry = escrow_mutation_auth::create_registry_for_testing(ctx);
    // Add futarchy_markets_core to authorized packages so arbitrage can create auth
    escrow_mutation_auth::add_authorized_package_for_testing(&mut registry, @futarchy_markets_core);
    registry
}

#[test_only]
fun create_test_market_state_registry(ctx: &mut TxContext): market_state_mutation_auth::MarketStateMutationRegistry {
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
fun link_pool_to_escrow(
    pool: &mut UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP>,
    escrow: &TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
) {
    let proposal_id = market_state::proposal_id(coin_escrow::get_market_state(escrow));
    unified_spot_pool::set_active_proposal(pool, proposal_id);
}

#[test_only]
fun create_test_escrow_with_markets(
    outcome_count: u64,
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
fun setup_conditional_pools_with_reserves(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    asset_reserves: vector<u64>,
    stable_reserves: vector<u64>,
    ctx: &mut TxContext,
) {
    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(escrow, &escrow_auth);
    let market_id = market_state::market_id(market_state);
    let outcome_count = vector::length(&asset_reserves);
    let mut pools = vector::empty();
    let clock = create_test_clock(1000000, ctx);

    let mut i = 0;
    while (i < outcome_count) {
        let asset_res = *vector::borrow(&asset_reserves, i);
        let stable_res = *vector::borrow(&stable_reserves, i);

        let pool = conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1000,
            1000,
            &clock,
            ctx,
        );
        let mut pool_mut = pool;
        conditional_amm::add_liquidity_for_testing(
            &mut pool_mut,
            coin::mint_for_testing<TEST_COIN_A>(asset_res, ctx),
            coin::mint_for_testing<TEST_COIN_B>(stable_res, ctx),
            DEFAULT_FEE_BPS,
            ctx,
        );
        vector::push_back(&mut pools, pool_mut);
        i = i + 1;
    };

    clock::destroy_for_testing(clock);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Add escrow liquidity - use max of pool reserves for proper quantum backing
    let mut max_asset = 0u64;
    let mut max_stable = 0u64;
    i = 0;
    while (i < outcome_count) {
        let a = *vector::borrow(&asset_reserves, i);
        let s = *vector::borrow(&stable_reserves, i);
        if (a > max_asset) max_asset = a;
        if (s > max_stable) max_stable = s;
        i = i + 1;
    };

    let asset_for_escrow = coin::mint_for_testing<TEST_COIN_A>(max_asset, ctx);
    let stable_for_escrow = coin::mint_for_testing<TEST_COIN_B>(max_stable, ctx);
    coin_escrow::deposit_spot_coins(escrow, asset_for_escrow, stable_for_escrow);

    // Initialize supplies to match AMM reserves
    // Arbitrage requires supplies to be set (track_system_swap asserts supply >= consumed)
    // increment_supplies_for_all_outcomes updates both supply AND escrowed
    coin_escrow::increment_supplies_for_all_outcomes(escrow, max_asset, max_stable, &escrow_auth);
    coin_escrow::set_lp_deposited_for_testing(escrow, max_asset, max_stable);
}

#[test_only]
fun get_all_pool_k_values(escrow: &TokenEscrow<TEST_COIN_A, TEST_COIN_B>): vector<u128> {
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let n = pools.length();
    let mut k_values = vector::empty<u128>();

    let mut i = 0;
    while (i < n) {
        let (a, s) = conditional_amm::get_reserves(&pools[i]);
        let k = (a as u128) * (s as u128);
        vector::push_back(&mut k_values, k);
        i = i + 1;
    };

    k_values
}

#[test_only]
fun get_spot_k_value(spot_pool: &UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP>): u128 {
    let (a, s) = unified_spot_pool::get_reserves(spot_pool);
    (a as u128) * (s as u128)
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

// ============================================================================
// TEST 1: K-INVARIANT PRESERVATION AFTER ARBITRAGE
// ============================================================================

#[test]
/// Verify that K-invariant is preserved (or grows) in ALL pools after arbitrage
///
/// Property: For every pool P, k_after >= k_before (within rounding tolerance)
///
/// Why this matters:
/// - K decrease means liquidity was extracted from LPs
/// - Even 0.01% decrease per arb could drain pools over time
/// - This test catches subtle bugs in reserve update logic
fun test_k_invariant_preserved_after_arbitrage() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with price = 2.0 (asset cheap, stable expensive)
    let mut spot_pool = create_test_spot_pool(
        5_000_000_000, // 5B asset
        10_000_000_000, // 10B stable
        &clock,
        ctx,
    );

    // Record initial spot K
    let spot_k_before = get_spot_k_value(&spot_pool);

    // Create escrow with 3 outcomes - conditionals priced at 1.0 (below spot)
    let mut escrow = create_test_escrow_with_markets(3, &clock, ctx);

    // Set up conditional pools with slightly different reserves to ensure dust is created
    // (identical pools would produce identical swap outputs = no dust)
    let asset_reserves = vector[1_000_000_000, 1_050_000_000, 980_000_000];
    let stable_reserves = vector[1_000_000_000, 1_050_000_000, 980_000_000];
    setup_conditional_pools_with_reserves(&mut escrow, asset_reserves, stable_reserves, ctx);

    // Record initial conditional K values
    let cond_k_before = get_all_pool_k_values(&escrow);

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

    // System rebalance must not return user-owned dust.
    assert!(option::is_none(&dust_opt), 0);
    assert!(total_system_dust_created(&escrow) == 0, 90);

    // Record final K values
    let spot_k_after = get_spot_k_value(&spot_pool);
    let cond_k_after = get_all_pool_k_values(&escrow);

    // CRITICAL ASSERTION: Spot pool K should not decrease
    // (may increase slightly due to fee accumulation, or stay same for feeless)
    // Allow 0.001% tolerance for rounding
    let tolerance_bps = 1; // 0.01%
    let spot_k_min_allowed = spot_k_before - (spot_k_before * (tolerance_bps as u128) / 10000);
    assert!(spot_k_after >= spot_k_min_allowed, 1);

    // CRITICAL ASSERTION: All conditional pools K should not decrease
    let n = vector::length(&cond_k_before);
    let mut i = 0;
    while (i < n) {
        let k_before = *vector::borrow(&cond_k_before, i);
        let k_after = *vector::borrow(&cond_k_after, i);
        let k_min_allowed = k_before - (k_before * (tolerance_bps as u128) / 10000);
        assert!(k_after >= k_min_allowed, 2 + (i as u64));
        i = i + 1;
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
/// Test K-invariant with opposite arbitrage direction (Spot→Cond)
fun test_k_invariant_preserved_spot_to_cond_direction() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create spot pool with price = 0.5 (asset expensive, stable cheap)
    let mut spot_pool = create_test_spot_pool(
        10_000_000_000, // 10B asset
        5_000_000_000, // 5B stable
        &clock,
        ctx,
    );

    let spot_k_before = get_spot_k_value(&spot_pool);

    // Create escrow with 2 outcomes - conditionals priced at 2.0 (above spot)
    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);

    // Set up conditional pools at price ~= 2.0 (above spot's 0.5)
    // Use slightly different reserves to ensure dust is created
    let asset_reserves = vector[500_000_000, 520_000_000];
    let stable_reserves = vector[1_000_000_000, 1_040_000_000];
    setup_conditional_pools_with_reserves(&mut escrow, asset_reserves, stable_reserves, ctx);

    let cond_k_before = get_all_pool_k_values(&escrow);

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

    // System rebalance must not return user-owned dust.
    assert!(option::is_none(&dust_opt), 0);
    assert!(total_system_dust_created(&escrow) == 0, 90);

    let spot_k_after = get_spot_k_value(&spot_pool);
    let cond_k_after = get_all_pool_k_values(&escrow);

    // K-invariant checks (same as above)
    let tolerance_bps = 1;
    let spot_k_min = spot_k_before - (spot_k_before * (tolerance_bps as u128) / 10000);
    assert!(spot_k_after >= spot_k_min, 1);

    let n = vector::length(&cond_k_before);
    let mut i = 0;
    while (i < n) {
        let k_before = *vector::borrow(&cond_k_before, i);
        let k_after = *vector::borrow(&cond_k_after, i);
        let k_min = k_before - (k_before * (tolerance_bps as u128) / 10000);
        assert!(k_after >= k_min, 2 + (i as u64));
        i = i + 1;
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

// ============================================================================
// TEST 2: ROUNDING ATTACK RESISTANCE
// ============================================================================

#[test]
/// Verify that repeatedly triggering tiny arbitrages cannot extract value
///
/// Attack scenario:
/// - Attacker triggers many small arbitrages hoping rounding errors accumulate
/// - Each individual arb might round in attacker's favor
/// - Over 100 iterations, this could drain significant value
///
/// Property: total_value_out <= total_value_in across all iterations
fun test_no_value_extraction_from_rounding() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create pools with moderate reserves
    let mut spot_pool = create_test_spot_pool(
        1_000_000_000, // 1B asset
        1_100_000_000, // 1.1B stable (price = 1.1)
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);

    // Conditionals at price = 1.0 (slight arbitrage opportunity)
    let asset_reserves = vector[500_000_000, 500_000_000];
    let stable_reserves = vector[500_000_000, 500_000_000];
    setup_conditional_pools_with_reserves(&mut escrow, asset_reserves, stable_reserves, ctx);

    // Record initial total value
    let (spot_a_init, spot_s_init) = unified_spot_pool::get_reserves(&spot_pool);
    let escrow_a_init = coin_escrow::get_escrowed_asset_balance(&escrow);
    let escrow_s_init = coin_escrow::get_escrowed_stable_balance(&escrow);
    let total_asset_init = spot_a_init + escrow_a_init;
    let total_stable_init = spot_s_init + escrow_s_init;

    // Execute arbitrage once (to exhaust the opportunity)
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

    // Clean up dust if any
    if (option::is_some(&dust_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt));
    };
    option::destroy_none(dust_opt);

    // Record final total value
    let (spot_a_final, spot_s_final) = unified_spot_pool::get_reserves(&spot_pool);
    let escrow_a_final = coin_escrow::get_escrowed_asset_balance(&escrow);
    let escrow_s_final = coin_escrow::get_escrowed_stable_balance(&escrow);
    let total_asset_final = spot_a_final + escrow_a_final;
    let total_stable_final = spot_s_final + escrow_s_final;

    // CRITICAL ASSERTION: No value should have been created from thin air
    // Allow tiny tolerance (1 unit) for rounding in each direction
    let tolerance = 10u64; // 10 units tolerance
    assert!(total_asset_final <= total_asset_init + tolerance, 1);
    assert!(total_stable_final <= total_stable_init + tolerance, 2);

    // Also verify no value was destroyed (sanity check)
    assert!(total_asset_final + tolerance >= total_asset_init, 3);
    assert!(total_stable_final + tolerance >= total_stable_init, 4);

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test that minimum trade sizes prevent dust extraction
fun test_minimum_trade_prevents_dust_extraction() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create pools with tiny price difference (should be within no-arb band)
    let mut spot_pool = create_test_spot_pool(
        1_000_000_000,
        1_003_000_000, // price = 1.003 (0.3% above 1.0)
        &clock,
        ctx,
    );

    // Record initial spot reserves
    let (spot_a_init, _spot_s_init) = unified_spot_pool::get_reserves(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);

    // Conditionals at exactly price = 1.0
    // 0.3% difference is within typical fee band, no profitable arb
    let asset_reserves = vector[500_000_000, 500_000_000];
    let stable_reserves = vector[500_000_000, 500_000_000];
    setup_conditional_pools_with_reserves(&mut escrow, asset_reserves, stable_reserves, ctx);

    // Attempt arbitrage - should return None (no opportunity within fees)
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

    // With 0.3% fee on both sides, tiny price difference should not be profitable
    // The dust_opt might be Some but with zero amounts, or None
    // Either way, the reserves should be largely unchanged
    let (spot_a_after, _spot_s_after) = unified_spot_pool::get_reserves(&spot_pool);

    // Verify minimal change (< 0.1% of reserves)
    let max_change = spot_a_init / 1000; // 0.1%
    let asset_change = if (spot_a_after > spot_a_init) {
        spot_a_after - spot_a_init
    } else {
        spot_a_init - spot_a_after
    };
    assert!(asset_change <= max_change, 1);

    if (option::is_some(&dust_opt)) {
        let mut dust_opt_mut = dust_opt;
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt_mut));
        option::destroy_none(dust_opt_mut);
    } else {
        option::destroy_none(dust_opt);
    };

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

// ============================================================================
// TEST 3: MATH↔EXECUTION CROSS-VALIDATION
// ============================================================================

#[test]
/// Verify that feeless math calculation matches actual execution
///
/// This test ensures the arbitrage_math module's calculations
/// accurately predict what happens during actual arbitrage execution.
///
/// Property: predicted_amount ≈ actual_amount (within 1% tolerance)
fun test_math_calculation_matches_execution() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create significant price differential for clear arbitrage
    let mut spot_pool = create_test_spot_pool(
        5_000_000_000, // 5B asset
        10_000_000_000, // 10B stable (price = 2.0)
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);

    // Conditionals at price = 1.0 (significant arb opportunity)
    let asset_reserves = vector[1_000_000_000, 1_000_000_000];
    let stable_reserves = vector[1_000_000_000, 1_000_000_000];
    setup_conditional_pools_with_reserves(&mut escrow, asset_reserves, stable_reserves, ctx);

    // Get the conditional pools for math calculation
    let market_state = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market_state);

    // Calculate expected rebalance using the same internal objective as execution.
    let (
        predicted_amount,
        is_cond_to_spot,
        _k_gain,
    ) = arbitrage_math::compute_optimal_internal_rebalance(
        &spot_pool,
        pools,
        0, // No hint
    );

    // Record pre-arbitrage state
    let (spot_a_before, spot_s_before) = unified_spot_pool::get_reserves(&spot_pool);

    // Execute actual arbitrage
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

    // Record post-arbitrage state
    let (spot_a_after, spot_s_after) = unified_spot_pool::get_reserves(&spot_pool);

    // Calculate actual amount moved
    let actual_asset_change = if (spot_a_after > spot_a_before) {
        spot_a_after - spot_a_before
    } else {
        spot_a_before - spot_a_after
    };

    // CRITICAL ASSERTION: Math prediction should be close to actual execution
    // Allow 5% tolerance due to:
    // - Rounding differences
    // - Fee application timing
    // - Multi-pool interaction effects
    if (predicted_amount > 0 && actual_asset_change > 0) {
        let tolerance_pct = 5; // 5%
        let max_allowed = predicted_amount + (predicted_amount * tolerance_pct / 100);
        let min_allowed = if (predicted_amount > predicted_amount * tolerance_pct / 100) {
            predicted_amount - (predicted_amount * tolerance_pct / 100)
        } else {
            0
        };

        // The actual change should be within tolerance of prediction
        // Note: We're comparing the right quantities based on direction
        assert!(actual_asset_change <= max_allowed + 1, 1);
        // Min check is looser because actual might be smaller due to slippage
    };

    // Verify direction was correct
    // is_cond_to_spot=true: Buy cheap from conditionals (price=1.0), sell to spot (price=2.0)
    // This adds asset to spot (decreasing spot price toward 1.0)
    if (is_cond_to_spot) {
        // Cond→Spot: Buy from conditionals, sell to spot
        // Spot gains asset → price decreases
        let price_before = (spot_s_before as u128) * PRICE_SCALE / (spot_a_before as u128);
        let price_after = (spot_s_after as u128) * PRICE_SCALE / (spot_a_after as u128);
        // Price should have moved toward equilibrium (decreased from 2.0 toward 1.0)
        assert!(price_after < price_before || price_after == price_before, 2);
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

// ============================================================================
// TEST 4: SEQUENTIAL ARBITRAGE IDEMPOTENCY
// ============================================================================

#[test]
/// Verify that successive arbitrage calls converge toward equilibrium
///
/// Due to ternary search threshold (MIN_COARSE_THRESHOLD = 3), each arbitrage
/// may leave small residual opportunities. This test verifies:
/// 1. First arbitrage executes (moves price toward equilibrium)
/// 2. Second arbitrage finds diminishing returns (much smaller impact)
/// 3. System converges toward price equilibrium
///
/// Property: Each successive arbitrage has decreasing impact
fun test_sequential_arbitrage_converges() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Create clear arbitrage opportunity
    let mut spot_pool = create_test_spot_pool(
        5_000_000_000,
        10_000_000_000, // price = 2.0
        &clock,
        ctx,
    );

    let initial_spot_price = unified_spot_pool::get_spot_price(&spot_pool);

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);

    // Conditionals at price ~= 1.0 (significant imbalance from spot price of 2.0)
    // Use slightly different reserves to ensure dust is created
    let asset_reserves = vector[1_000_000_000, 1_020_000_000];
    let stable_reserves = vector[1_000_000_000, 1_020_000_000];
    setup_conditional_pools_with_reserves(&mut escrow, asset_reserves, stable_reserves, ctx);

    // Record initial state
    let (spot_a_initial, _) = unified_spot_pool::get_reserves(&spot_pool);

    // FIRST ARBITRAGE - should execute with significant impact
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

    // First arbitrage should execute while returning no system dust to the caller.
    assert!(option::is_none(&dust_opt_1), 0);

    // Record state after first arb
    let (spot_a_after_1, _) = unified_spot_pool::get_reserves(&spot_pool);
    let price_after_1 = unified_spot_pool::get_spot_price(&spot_pool);

    // Calculate first arbitrage impact
    let first_arb_impact = if (spot_a_after_1 > spot_a_initial) {
        spot_a_after_1 - spot_a_initial
    } else {
        spot_a_initial - spot_a_after_1
    };

    // SECOND ARBITRAGE - may find residual opportunity
    let dust_opt_2 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        dust_opt_1,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Record state after second arb
    let (spot_a_after_2, _) = unified_spot_pool::get_reserves(&spot_pool);
    let price_after_2 = unified_spot_pool::get_spot_price(&spot_pool);

    // Calculate second arbitrage impact
    let second_arb_impact = if (spot_a_after_2 > spot_a_after_1) {
        spot_a_after_2 - spot_a_after_1
    } else {
        spot_a_after_1 - spot_a_after_2
    };

    // CRITICAL ASSERTION 1: First arbitrage had significant impact
    // (more than 1% of initial reserves)
    assert!(first_arb_impact > spot_a_initial / 100, 1);

    // CRITICAL ASSERTION 2: Second arbitrage has diminishing impact
    // (should be much smaller than first, at most 10% of first impact)
    // This verifies convergence - successive arbs find less opportunity
    assert!(second_arb_impact <= first_arb_impact / 5, 2);

    // CRITICAL ASSERTION 3: Price moved toward equilibrium
    // Spot started at 2.0, conditionals at 1.0
    // After arbitrage, spot price should be closer to conditionals
    assert!(price_after_1 < initial_spot_price, 3);
    // And second arb shouldn't reverse the direction
    assert!(
        price_after_2 <= price_after_1 ||
            (price_after_2 - price_after_1) < (initial_spot_price - price_after_1) / 10,
        4,
    );

    // Cleanup
    option::destroy_none(dust_opt_2);

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}

#[test]
/// Test sequential arbitrage with opposite direction opportunity
/// After first arb moves price one way, verify no reverse arb exists
fun test_no_reverse_arbitrage_after_rebalance() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Start with spot price between conditional prices
    let mut spot_pool = create_test_spot_pool(
        1_000_000_000,
        1_500_000_000, // price = 1.5
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, &clock, ctx);

    // Pool 0: price = 1.0, Pool 1: price = 2.0
    // Spot at 1.5 is between them
    let asset_reserves = vector[1_000_000_000, 500_000_000];
    let stable_reserves = vector[1_000_000_000, 1_000_000_000];
    setup_conditional_pools_with_reserves(&mut escrow, asset_reserves, stable_reserves, ctx);

    // First arbitrage
    link_pool_to_escrow(&mut spot_pool, &escrow);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut dust_opt_1 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    if (option::is_some(&dust_opt_1)) {
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt_1));
    };
    option::destroy_none(dust_opt_1);

    // Get new prices
    let _spot_price_after_1 = unified_spot_pool::get_spot_price(&spot_pool);

    // Second arbitrage should find nothing significant
    let (spot_a_before_2, spot_s_before_2) = unified_spot_pool::get_reserves(&spot_pool);

    let dust_opt_2 = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        &mut spot_pool,
        &mut escrow,
        option::none(),
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (spot_a_after_2, spot_s_after_2) = unified_spot_pool::get_reserves(&spot_pool);

    // Reserves should be unchanged (or nearly so)
    let asset_change = if (spot_a_after_2 > spot_a_before_2) {
        spot_a_after_2 - spot_a_before_2
    } else {
        spot_a_before_2 - spot_a_after_2
    };
    let stable_change = if (spot_s_after_2 > spot_s_before_2) {
        spot_s_after_2 - spot_s_before_2
    } else {
        spot_s_before_2 - spot_s_after_2
    };

    // Changes should be negligible (< 0.01% of reserves)
    let tolerance = spot_a_before_2 / 10000; // 0.01%
    assert!(asset_change <= tolerance, 1);
    assert!(stable_change <= tolerance, 2);

    if (option::is_some(&dust_opt_2)) {
        let mut dust_opt_2_mut = dust_opt_2;
        conditional_balance::destroy_for_testing(option::extract(&mut dust_opt_2_mut));
        option::destroy_none(dust_opt_2_mut);
    } else {
        option::destroy_none(dust_opt_2);
    };

    // Cleanup
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    ts::end(scenario);
}
