// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_markets_core::quantum_lp_manager_tests;

use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationRegistry};
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationRegistry};
use futarchy_markets_core::quantum_lp_manager;
use futarchy_markets_core::spot_pool_mutation_auth;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm;
use futarchy_markets_primitives::market_state;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario as ts;

// Test coins
public struct ASSET has drop {}
public struct STABLE has drop {}
public struct LP has drop {}

const ADMIN: address = @0xAD;
const ONE: u64 = 1_000_000_000; // 1 token with 9 decimals

// === Test Helpers ===

fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

fun create_spot_pool(
    asset_amount: u64,
    stable_amount: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<ASSET, STABLE, LP> {
    let lp_treasury = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool = unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(
        lp_treasury,
        30, // 0.3%
        ctx,
    );
    let asset_balance = balance::create_for_testing<ASSET>(asset_amount);
    let stable_balance = balance::create_for_testing<STABLE>(stable_amount);
    unified_spot_pool::add_liquidity_for_testing(&mut pool, asset_balance, stable_balance);
    pool
}

fun create_escrow_with_pools(num_outcomes: u64, ctx: &mut TxContext): TokenEscrow<ASSET, STABLE> {
    let mut ms = market_state::create_for_testing(num_outcomes, ctx);
    let market_id = object::id(&ms);
    let clock = create_test_clock(1000, ctx);
    let mut pools = vector::empty();
    let mut i = 0u64;
    while (i < num_outcomes) {
        let pool = conditional_amm::create_test_pool(
            market_id,
            i as u8,
            30,
            1000,
            1000,
            &clock,
            ctx,
        );
        pools.push_back(pool);
        i = i + 1;
    };
    market_state::set_amm_pools_for_testing(&mut ms, pools);
    clock::destroy_for_testing(clock);
    coin_escrow::create_test_escrow_with_market_state(num_outcomes, ms, ctx)
}

/// Create escrow with EMPTY AMM pools (zero reserves, zero lp_supply).
/// Mirrors the new proposal creation flow where pools start empty and are
/// funded by quantum split at advance-to-trading.
fun create_escrow_with_empty_pools(num_outcomes: u64, ctx: &mut TxContext): TokenEscrow<ASSET, STABLE> {
    let mut ms = market_state::create_for_testing(num_outcomes, ctx);
    let market_id = object::id(&ms);
    let clock = create_test_clock(1000, ctx);
    let auth = market_state_mutation_auth::create_for_testing();
    // 1e12 = price_precision_scale (1:1 price)
    let initial_price: u128 = 1_000_000_000_000;
    let mut pools = vector::empty();
    let mut i = 0u64;
    while (i < num_outcomes) {
        let pool = conditional_amm::new_empty_pool(
            market_id,
            i as u8,
            30, // fee_bps
            initial_price,
            0, // twap_start_delay
            1_000, // twap_cap_ppm (0.1%)
            &auth,
            &clock,
            ctx,
        );
        pools.push_back(pool);
        i = i + 1;
    };
    market_state::set_amm_pools_for_testing(&mut ms, pools);
    clock::destroy_for_testing(clock);
    coin_escrow::create_test_escrow_with_market_state(num_outcomes, ms, ctx)
}

fun create_escrow_registry(ctx: &mut TxContext): EscrowMutationRegistry {
    let mut registry = escrow_mutation_auth::create_registry_for_testing(ctx);
    escrow_mutation_auth::add_authorized_package_for_testing(&mut registry, @futarchy_markets_core);
    registry
}

fun create_market_state_registry(ctx: &mut TxContext): MarketStateMutationRegistry {
    let mut registry = market_state_mutation_auth::new_registry_for_testing(ctx);
    market_state_mutation_auth::add_authorized_package_for_testing(
        &mut registry,
        @futarchy_markets_core,
    );
    registry
}

fun bind_active_escrow(
    _spot_pool: &mut UnifiedSpotPool<ASSET, STABLE, LP>,
    _escrow: &TokenEscrow<ASSET, STABLE>,
) {
    // Active escrow now lives as a wrapped object in production flow.
    // These unit tests mutate escrow directly, so binding is not required.
}

fun escrow_proposal_id(escrow: &TokenEscrow<ASSET, STABLE>): ID {
    market_state::proposal_id(coin_escrow::get_market_state(escrow))
}

fun quantum_split(
    spot_pool: &mut UnifiedSpotPool<ASSET, STABLE, LP>,
    escrow: &mut TokenEscrow<ASSET, STABLE>,
    proposal_id: ID,
    ratio_percent: u64,
    escrow_registry: &EscrowMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let auth = spot_pool_mutation_auth::create_for_testing(object::id(spot_pool));
    quantum_lp_manager::auto_quantum_split_on_proposal_start(
        spot_pool,
        escrow,
        proposal_id,
        ratio_percent,
        escrow_registry,
        clock,
        ctx,
        auth,
    );
}

fun quantum_redeem(
    winning_outcome: u64,
    spot_pool: &mut UnifiedSpotPool<ASSET, STABLE, LP>,
    escrow: &mut TokenEscrow<ASSET, STABLE>,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let auth = spot_pool_mutation_auth::create_for_testing(object::id(spot_pool));
    quantum_lp_manager::auto_redeem_on_proposal_end_from_escrow(
        winning_outcome,
        spot_pool,
        escrow,
        escrow_registry,
        market_state_registry,
        clock,
        ctx,
        auth,
    );
}

fun finalize_market(escrow: &mut TokenEscrow<ASSET, STABLE>, winning_outcome: u64) {
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(escrow, &auth);
    market_state::test_set_winning_outcome(ms, winning_outcome);
    market_state::test_set_finalized(ms);
}

/// Modify AMM pool reserves after quantum_split to simulate post-trading state.
/// Empties the pool first, then sets desired reserves.
fun set_pool_reserves(
    escrow: &mut TokenEscrow<ASSET, STABLE>,
    pool_index: u64,
    asset_reserve: u64,
    stable_reserve: u64,
    ctx: &mut TxContext,
) {
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(escrow, &auth);
    let pools = market_state::borrow_amm_pools_mut(ms, &auth);
    let pool = &mut pools[pool_index];
    conditional_amm::empty_all_amm_liquidity_for_testing(pool, ctx);
    conditional_amm::add_reserves_for_testing(pool, asset_reserve, stable_reserve);
}

// === Tests ===

#[test]
#[expected_failure(abort_code = 3, location = futarchy_markets_core::quantum_lp_manager)] // ESpotPoolEscrowMismatch
fun test_split_fails_on_escrow_binding_mismatch() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);

    let fake_escrow = create_escrow_with_pools(2, ctx);
    unified_spot_pool::set_active_escrow_for_testing(&mut spot_pool, fake_escrow);
    let proposal_id = escrow_proposal_id(&escrow);

    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        50,
        &escrow_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 3, location = futarchy_markets_core::quantum_lp_manager)] // ESpotPoolEscrowMismatch
fun test_split_fails_when_proposal_id_mismatches_escrow() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);

    quantum_split(
        &mut spot_pool,
        &mut escrow,
        object::id_from_address(@0xBAD),
        50,
        &escrow_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 2, location = futarchy_markets_core::quantum_lp_manager)] // EProposalAlreadyActive
fun test_split_fails_when_proposal_already_active() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    unified_spot_pool::set_active_proposal(&mut spot_pool, object::id_from_address(@0x2));

    quantum_split(
        &mut spot_pool,
        &mut escrow,
        object::id_from_address(@0x3),
        50,
        &escrow_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 3, location = futarchy_markets_core::quantum_lp_manager)] // ESpotPoolEscrowMismatch
fun test_redeem_fails_without_active_binding() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);
    let market_state_registry = create_market_state_registry(ctx);

    finalize_market(&mut escrow, 0);
    quantum_redeem(
        0,
        &mut spot_pool,
        &mut escrow,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4, location = futarchy_markets_core::quantum_lp_manager)] // EMarketNotFinalized
fun test_redeem_fails_when_market_not_finalized() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);
    let market_state_registry = create_market_state_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    unified_spot_pool::set_active_proposal(&mut spot_pool, escrow_proposal_id(&escrow));

    quantum_redeem(
        0,
        &mut spot_pool,
        &mut escrow,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5, location = futarchy_markets_core::quantum_lp_manager)] // EWinningOutcomeMismatch
fun test_redeem_fails_when_winner_mismatch() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);
    let market_state_registry = create_market_state_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    unified_spot_pool::set_active_proposal(&mut spot_pool, escrow_proposal_id(&escrow));
    finalize_market(&mut escrow, 1);

    quantum_redeem(
        0,
        &mut spot_pool,
        &mut escrow,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_redeem_handles_wrapped_balances_without_dos() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);

    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);
    let market_state_registry = create_market_state_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        50,
        &escrow_registry,
        &clock,
        ctx,
    );

    let (mid_asset, mid_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(mid_asset == 500 * ONE, 0);
    assert!(mid_stable == 500 * ONE, 1);

    let remaining_supply = 10 * ONE;
    let wrapped_amount = 490 * ONE;
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, remaining_supply);
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, true, wrapped_amount);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, remaining_supply);
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, false, wrapped_amount);
    coin_escrow::assert_quantum_invariant(&escrow);

    finalize_market(&mut escrow, 0);
    quantum_redeem(
        0,
        &mut spot_pool,
        &mut escrow,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let (final_asset, final_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(final_asset == 510 * ONE, 2);
    assert!(final_stable == 510 * ONE, 3);
    assert!(!unified_spot_pool::is_locked_for_proposal(&spot_pool), 4);

    let (lp_asset, lp_stable) = coin_escrow::get_lp_deposited_for_testing(&escrow);
    assert!(lp_asset == wrapped_amount, 5);
    assert!(lp_stable == wrapped_amount, 6);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 0, 7);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 0) == 0, 8);
    assert!(coin_escrow::get_outcome_wrapped_asset(&escrow, 0) == wrapped_amount, 9);
    assert!(coin_escrow::get_outcome_wrapped_stable(&escrow, 0) == wrapped_amount, 10);
    coin_escrow::assert_quantum_invariant(&escrow);

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === LP Growth / Loss Tests ===

#[test]
/// Round-trip: no trading happens, LP gets back exactly what it deposited.
/// Spot pool should be fully restored after quantum split + redeem.
fun test_round_trip_no_trading_restores_spot_pool() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);

    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);
    let market_state_registry = create_market_state_registry(ctx);

    // Quantum split 50% — spot goes from 1000 to 500 per side
    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        50,
        &escrow_registry,
        &clock,
        ctx,
    );

    let (mid_asset, mid_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(mid_asset == 500 * ONE, 0);
    assert!(mid_stable == 500 * ONE, 1);

    // No trading — finalize and redeem immediately
    finalize_market(&mut escrow, 0);
    quantum_redeem(
        0,
        &mut spot_pool,
        &mut escrow,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Spot pool should be fully restored
    let (final_asset, final_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(final_asset == 1000 * ONE, 2);
    assert!(final_stable == 1000 * ONE, 3);
    assert!(!unified_spot_pool::is_locked_for_proposal(&spot_pool), 4);
    coin_escrow::assert_quantum_invariant(&escrow);

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// LP growth: user deposits + trading create excess escrow that sweeps to spot pool.
/// Simulates: user splits 100*ONE asset, typed-swaps 100*ONE pass_asset → 80*ONE pass_stable.
/// Net: LP profits from sweep of excess escrow (user's lost value from slippage).
fun test_lp_growth_from_user_trading_sweep() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);

    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);
    let market_state_registry = create_market_state_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        50,
        &escrow_registry,
        &clock,
        ctx,
    );

    // After split: escrow=500/500, OE[i]=500/500, supply[i]=500/500, pool_claim[i]=500/500
    // Simulate: user splits 100*ONE asset → +100 to escrow, +100 OE/supply for ALL outcomes
    // Then typed swap: burn 100 pass_asset, mint 80 pass_stable
    //   → pass OE_asset -100 (back to 500), pass OE_stable +80 (to 580)
    //   → AMM[pass] gets +100 asset, gives -80 stable → 600/420

    // 1. Extra real asset from user split
    coin_escrow::deposit_spot_liquidity_for_testing(&mut escrow, 100 * ONE, 0);

    // 2. Reject outcome: OE/supply_asset increased by user split (+100)
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, true, 600 * ONE);
    coin_escrow::set_supply_for_testing(&mut escrow, 1, true, 600 * ONE);

    // 3. Pass outcome: OE/supply_stable increased by typed swap mint (+80)
    //    (pass OE/supply_asset unchanged: +100 split, -100 swap cancel out)
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 580 * ONE);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 580 * ONE);

    // 4. AMM[pass] reserves: +100 asset from swap, -80 stable from swap
    set_pool_reserves(&mut escrow, 0, 600 * ONE, 420 * ONE, ctx);

    // Verify invariant holds after simulated trading
    coin_escrow::assert_quantum_invariant(&escrow);

    // Finalize: pass (outcome 0) wins
    finalize_market(&mut escrow, 0);
    quantum_redeem(
        0,
        &mut spot_pool,
        &mut escrow,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // LP GROWTH: spot pool should have MORE than original 1000*ONE total
    // LP withdrawal: 500 asset + 420 stable (pool_claim and AMM cap respectively)
    // Sweep: 100 asset (excess escrow beyond winning OE)
    // Total to spot: 600 asset + 420 stable
    let (final_asset, final_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(final_asset == 1100 * ONE, 2); // 500 (kept) + 600 (returned) = 1100
    assert!(final_stable == 920 * ONE, 3); // 500 (kept) + 420 (returned) = 920
    // Net: +100 asset, -80 stable → LP captured 20 from user's slippage
    assert!(final_asset > 1000 * ONE, 4); // Gained asset
    assert!(!unified_spot_pool::is_locked_for_proposal(&spot_pool), 5);
    coin_escrow::assert_quantum_invariant(&escrow);

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// LP loss: adverse price movement in the winning pool means LP gets less back.
/// Simulates: heavy typed swap of 200*ONE pass_asset → 200*ONE pass_stable.
/// The winning pool shifts heavily toward asset, depleting its stable reserves.
/// LP loses stable tokens (adverse selection from prediction market trading).
fun test_lp_loss_from_adverse_price_movement() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);

    let clock = create_test_clock(1000, ctx);
    let mut spot_pool = create_spot_pool(1000 * ONE, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);
    let market_state_registry = create_market_state_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        50,
        &escrow_registry,
        &clock,
        ctx,
    );

    // After split: escrow=500/500, OE[i]=500/500, supply[i]=500/500
    // Simulate: heavy typed swap in pass pool: 200*ONE pass_asset → 200*ONE pass_stable
    //   → burn 200 pass_asset: supply_asset[pass] = 300, OE_asset[pass] = 300
    //   → mint 200 pass_stable: supply_stable[pass] = 700, OE_stable[pass] = 700
    //   → AMM[pass]: +200 asset (700), -200 stable (300)
    // No extra escrow deposit (typed swaps don't change real balance)

    // 1. Pass outcome: asset supply/OE decreased (200 burned)
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 300 * ONE);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 300 * ONE);

    // 2. Pass outcome: stable supply/OE increased (200 minted)
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 700 * ONE);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 700 * ONE);

    // 3. AMM[pass] reserves shifted: +200 asset, -200 stable
    set_pool_reserves(&mut escrow, 0, 700 * ONE, 300 * ONE, ctx);

    // Verify invariant holds after simulated trading
    coin_escrow::assert_quantum_invariant(&escrow);

    // Finalize: pass (outcome 0) wins
    finalize_market(&mut escrow, 0);
    quantum_redeem(
        0,
        &mut spot_pool,
        &mut escrow,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // LP LOSS: winning pool shifted, LP gets less stable back
    // withdraw_asset = min(700, 500, 500, 300, 500, 500) = 300 (supply caps)
    // withdraw_stable = min(300, 500, 500, 700, 300, 500) = 300 (AMM and user_cap cap)
    // sweep_asset = 200 (excess escrow: 500-300 withdraw, 0 required)
    // sweep_stable = 0 (escrow 200, required 400 → no excess)
    // Total to spot: 500 asset + 300 stable
    let (final_asset, final_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(final_asset == 1000 * ONE, 2); // 500 (kept) + 500 (300 withdraw + 200 sweep) = 1000
    assert!(final_stable == 800 * ONE, 3); // 500 (kept) + 300 (withdraw) = 800
    // Net: LP lost 200*ONE stable from adverse trading
    assert!(final_stable < 1000 * ONE, 4); // Confirmed loss
    assert!(!unified_spot_pool::is_locked_for_proposal(&spot_pool), 5);
    coin_escrow::assert_quantum_invariant(&escrow);

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Zero-Split Security Tests ===
// These verify that zero-liquidity splits abort instead of silently creating
// zero-reserve conditional pools that would permanently brick the DAO.

#[test]
#[expected_failure(abort_code = 7, location = futarchy_markets_core::quantum_lp_manager)] // EZeroLiquiditySplit
/// Zero asset reserves → asset_to_split = 0 → must abort.
fun test_split_aborts_on_zero_asset_reserves() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    // Spot pool with 0 asset, nonzero stable
    let mut spot_pool = create_spot_pool(0, 1000 * ONE, ctx);
    let mut escrow = create_escrow_with_empty_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        50,
        &escrow_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 7, location = futarchy_markets_core::quantum_lp_manager)] // EZeroLiquiditySplit
/// Zero stable reserves → stable_to_split = 0 → must abort.
fun test_split_aborts_on_zero_stable_reserves() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    // Spot pool with nonzero asset, 0 stable
    let mut spot_pool = create_spot_pool(1000 * ONE, 0, ctx);
    let mut escrow = create_escrow_with_empty_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        50,
        &escrow_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 7, location = futarchy_markets_core::quantum_lp_manager)] // EZeroLiquiditySplit
/// Tiny reserves + low ratio → floor(1 * 1 / 100) = 0 → must abort.
fun test_split_aborts_when_ratio_rounds_to_zero() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    // 1 unit of each, ratio 1% → floor(1 * 1 / 100) = 0
    let mut spot_pool = create_spot_pool(1, 1, ctx);
    let mut escrow = create_escrow_with_empty_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        1, // 1% of 1 = 0
        &escrow_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Empty Pool Regression Tests ===
// These test the new proposal creation flow where conditional AMM pools start
// empty (zero reserves) and are funded solely by quantum split at advance-to-trading.

#[test]
/// Regression: quantum split on empty pools populates them correctly.
/// Verifies: spot_reserves_after + conditional_pool_reserves == spot_reserves_before.
/// This is the core invariant for the "no proposer liquidity" flow.
fun test_quantum_split_on_empty_pools_conserves_total_liquidity() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);

    let clock = create_test_clock(1000, ctx);
    let initial_asset = 1000 * ONE;
    let initial_stable = 1000 * ONE;
    let mut spot_pool = create_spot_pool(initial_asset, initial_stable, ctx);
    let mut escrow = create_escrow_with_empty_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);

    // Quantum split 80% — the standard ratio
    let ratio = 80;
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        ratio,
        &escrow_registry,
        &clock,
        ctx,
    );

    // Spot pool should retain (100 - ratio)% = 20%
    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    let expected_spot_asset = initial_asset * (100 - ratio) / 100;
    let expected_spot_stable = initial_stable * (100 - ratio) / 100;
    assert!(spot_asset_after == expected_spot_asset, 0);
    assert!(spot_stable_after == expected_spot_stable, 1);

    // Each conditional pool should have ratio% of the original reserves
    let ms = coin_escrow::get_market_state(&escrow);
    let pool_0 = market_state::get_pool_by_outcome(ms, 0);
    let (pool_0_asset, pool_0_stable) = conditional_amm::get_reserves(pool_0);
    let expected_pool_asset = initial_asset * ratio / 100;
    let expected_pool_stable = initial_stable * ratio / 100;
    assert!(pool_0_asset == expected_pool_asset, 2);
    assert!(pool_0_stable == expected_pool_stable, 3);

    // Pool 1 should have the same reserves (quantum replication)
    let pool_1 = market_state::get_pool_by_outcome(ms, 1);
    let (pool_1_asset, pool_1_stable) = conditional_amm::get_reserves(pool_1);
    assert!(pool_1_asset == expected_pool_asset, 4);
    assert!(pool_1_stable == expected_pool_stable, 5);

    // Conservation: spot_after + one_pool == original (quantum backing is 1x, not Nx)
    assert!(spot_asset_after + pool_0_asset == initial_asset, 6);
    assert!(spot_stable_after + pool_0_stable == initial_stable, 7);

    // LP supply should be non-zero (pools were bootstrapped from empty)
    assert!(conditional_amm::get_lp_supply(pool_0) > 0, 8);
    assert!(conditional_amm::get_lp_supply(pool_1) > 0, 9);

    coin_escrow::assert_quantum_invariant(&escrow);

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Regression: round-trip with empty pools — split then redeem with no trading.
/// Spot pool should be fully restored after quantum split + redeem on empty pools.
fun test_round_trip_empty_pools_no_trading_restores_spot_pool() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);

    let clock = create_test_clock(1000, ctx);
    let initial_asset = 1000 * ONE;
    let initial_stable = 1000 * ONE;
    let mut spot_pool = create_spot_pool(initial_asset, initial_stable, ctx);
    let mut escrow = create_escrow_with_empty_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);
    let market_state_registry = create_market_state_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        80,
        &escrow_registry,
        &clock,
        ctx,
    );

    // Verify split happened
    let (mid_asset, mid_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(mid_asset == 200 * ONE, 0); // 20% retained
    assert!(mid_stable == 200 * ONE, 1);

    // Finalize and redeem winning outcome 0
    finalize_market(&mut escrow, 0);
    quantum_redeem(
        0,
        &mut spot_pool,
        &mut escrow,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Spot pool fully restored (no trading occurred = no loss)
    let (final_asset, final_stable) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(final_asset == initial_asset, 2);
    assert!(final_stable == initial_stable, 3);
    assert!(!unified_spot_pool::is_locked_for_proposal(&spot_pool), 4);
    coin_escrow::assert_quantum_invariant(&escrow);

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Reorder Regression Test ===
// Verifies the fix that moved set_active_proposal AFTER the zero-split assertion,
// so the spot pool is not left in a bricked locked state on abort.

#[test]
#[expected_failure(abort_code = 7, location = futarchy_markets_core::quantum_lp_manager)]
/// Small reserves with low ratio → both sides round to zero → must abort BEFORE
/// set_active_proposal so the spot pool is not left in a bricked locked state.
fun test_split_aborts_on_zero_liquidity_split() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000, ctx);
    // 50 units of each, ratio 1% → floor(50 * 1 / 100) = 0 for both sides
    let mut spot_pool = create_spot_pool(50, 50, ctx);
    let mut escrow = create_escrow_with_empty_pools(2, ctx);
    let escrow_registry = create_escrow_registry(ctx);

    bind_active_escrow(&mut spot_pool, &escrow);
    let proposal_id = escrow_proposal_id(&escrow);
    quantum_split(
        &mut spot_pool,
        &mut escrow,
        proposal_id,
        1, // 1% of 50 = 0
        &escrow_registry,
        &clock,
        ctx,
    );

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
