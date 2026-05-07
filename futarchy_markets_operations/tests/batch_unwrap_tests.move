// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Tests for split_asset_to_batch, split_stable_to_batch, and unwrap_from_batch.
///
/// These functions enable the "escrow spot coin -> get N conditional coins" flow,
/// allowing the SDK to return only typed coins (no ConditionalMarketBalance objects).
#[test_only]
module futarchy_markets_operations::batch_unwrap_tests;

use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationRegistry};
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationRegistry};
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationRegistry};
use futarchy_markets_core::swap_core;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_operations::swap_entry;
use futarchy_markets_primitives::coin_escrow;
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use futarchy_proposal::proposal::{Self, Proposal};
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario as ts;

// Test LP type
public struct LP has drop {}

// Conditional coin types for 2-outcome tests
public struct COND_0_ASSET {}
public struct COND_0_STABLE {}
public struct COND_1_ASSET {}
public struct COND_1_STABLE {}

// Conditional coin types for 3-outcome tests
public struct COND_2_ASSET {}
public struct COND_2_STABLE {}

// === Constants ===
const STATE_TRADING: u8 = 2;

// === Helpers ===

fun create_test_escrow_registry(ctx: &mut TxContext): EscrowMutationRegistry {
    let mut registry = escrow_mutation_auth::create_registry_for_testing(ctx);
    escrow_mutation_auth::add_authorized_package_for_testing(&mut registry, @futarchy_markets_core);
    registry
}

fun create_test_market_state_registry(ctx: &mut TxContext): MarketStateMutationRegistry {
    let mut registry = market_state_mutation_auth::new_registry_for_testing(ctx);
    market_state_mutation_auth::add_authorized_package_for_testing(&mut registry, @futarchy_markets_core);
    registry
}

fun create_test_spot_pool_mutation_registry(ctx: &mut TxContext): SpotPoolMutationRegistry {
    let mut registry = spot_pool_mutation_auth::new_registry_for_testing(ctx);
    let admin_cap = spot_pool_mutation_auth::new_admin_cap_for_testing(&registry, ctx);
    spot_pool_mutation_auth::add_authorized_package(
        &mut registry,
        &admin_cap,
        @futarchy_markets_operations,
    );
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(admin_cap);
    registry
}

fun create_test_spot_pool(
    asset_reserve: u64,
    stable_reserve: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP> {
    let lp_treasury = coin::create_treasury_cap_for_testing<LP>(ctx);
    unified_spot_pool::create_pool_for_testing(
        lp_treasury,
        asset_reserve,
        stable_reserve,
        fee_bps,
        ctx,
    )
}

/// Create a fully set up escrow with registered treasury caps for 2 outcomes.
fun create_escrow_with_caps_2(
    clock: &Clock,
    ctx: &mut TxContext,
): coin_escrow::TokenEscrow<TEST_COIN_A, TEST_COIN_B> {
    let proposal_id = sui::object::id_from_address(@0xABC);
    let dao_id = sui::object::id_from_address(@0xDEF);

    let mut outcome_messages = vector::empty();
    outcome_messages.push_back(std::string::utf8(b"Outcome 0"));
    outcome_messages.push_back(std::string::utf8(b"Outcome 1"));

    let market_state = market_state::new(proposal_id, dao_id, 2, outcome_messages, clock, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let ac0 = coin::create_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let sc0 = coin::create_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, ac0, sc0);

    let ac1 = coin::create_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let sc1 = coin::create_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, ac1, sc1);

    escrow
}

/// Create a fully set up escrow with registered treasury caps for 3 outcomes.
fun create_escrow_with_caps_3(
    clock: &Clock,
    ctx: &mut TxContext,
): coin_escrow::TokenEscrow<TEST_COIN_A, TEST_COIN_B> {
    let proposal_id = sui::object::id_from_address(@0xABC);
    let dao_id = sui::object::id_from_address(@0xDEF);

    let mut outcome_messages = vector::empty();
    outcome_messages.push_back(std::string::utf8(b"Outcome 0"));
    outcome_messages.push_back(std::string::utf8(b"Outcome 1"));
    outcome_messages.push_back(std::string::utf8(b"Outcome 2"));

    let market_state = market_state::new(proposal_id, dao_id, 3, outcome_messages, clock, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let ac0 = coin::create_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let sc0 = coin::create_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, ac0, sc0);

    let ac1 = coin::create_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let sc1 = coin::create_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, ac1, sc1);

    let ac2 = coin::create_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let sc2 = coin::create_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, ac2, sc2);

    escrow
}

fun setup_proposal(
    escrow: &coin_escrow::TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    outcome_count: u8,
    ctx: &mut TxContext,
): Proposal<TEST_COIN_A, TEST_COIN_B> {
    let escrow_id = sui::object::id(escrow);
    let market_state_id = sui::object::id(coin_escrow::get_market_state(escrow));
    let mut proposal = proposal::create_test_proposal<TEST_COIN_A, TEST_COIN_B>(
        outcome_count, 0, false, ctx,
    );
    proposal::set_state_for_testing(&mut proposal, STATE_TRADING);
    proposal::set_escrow_id_for_testing(&mut proposal, escrow_id);
    proposal::set_market_state_id_for_testing(&mut proposal, market_state_id);
    proposal
}

fun enable_trading(escrow: &mut coin_escrow::TokenEscrow<TEST_COIN_A, TEST_COIN_B>) {
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(escrow, &auth);
    market_state::init_trading_for_testing(ms);
}

/// Finalize a batch after all unwraps. The batch balance should be empty.
fun finalize_batch(
    batch: swap_entry::ConditionalSwapBatch<TEST_COIN_A, TEST_COIN_B>,
    escrow: &mut coin_escrow::TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    spot_pool: &mut UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP>,
    proposal: &Proposal<TEST_COIN_A, TEST_COIN_B>,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let session = swap_core::begin_swap_session(escrow);
    swap_entry::finalize_conditional_swaps(
        batch, spot_pool, proposal, escrow, session,
        @0x1, escrow_registry, market_state_registry, clock, ctx,
    );
}

// === Tests: split_asset_to_batch ===

/// Split a spot asset into the batch balance for all outcomes,
/// then unwrap each outcome as a typed coin.
#[test]
fun test_split_asset_to_batch_2_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 1000 asset into the batch (funds all outcomes)
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, asset_coin);

    // Unwrap asset from outcome 0
    let (batch, coin_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 1000, ctx,
    );
    assert!(coin_0.value() == 1000, 0);

    // Unwrap asset from outcome 1
    let (batch, coin_1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        batch, &mut escrow, 1, true, 1000, ctx,
    );
    assert!(coin_1.value() == 1000, 1);

    // Finalize (batch balance is empty -> destroyed)
    let proposal = setup_proposal(&escrow, 2, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(coin_0);
    coin::burn_for_testing(coin_1);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Split a spot stable into the batch balance for all outcomes.
#[test]
fun test_split_stable_to_batch_2_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 500 stable into the batch
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(500, ctx);
    let batch = swap_entry::split_stable_to_batch(batch, &mut escrow, stable_coin);

    // Unwrap stable from outcome 0
    let (batch, coin_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        batch, &mut escrow, 0, false, 500, ctx,
    );
    assert!(coin_0.value() == 500, 0);

    // Unwrap stable from outcome 1
    let (batch, coin_1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_STABLE>(
        batch, &mut escrow, 1, false, 500, ctx,
    );
    assert!(coin_1.value() == 500, 1);

    // Finalize
    let proposal = setup_proposal(&escrow, 2, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(coin_0);
    coin::burn_for_testing(coin_1);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Tests: N-outcome agnostic (3 outcomes) ===

/// Verify the functions work for 3 outcomes — not hardcoded to 2.
#[test]
fun test_split_and_unwrap_3_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_3(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 2000 asset into all 3 outcomes
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(2000, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, asset_coin);

    // Unwrap from all 3 outcomes
    let (batch, coin_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 2000, ctx,
    );
    assert!(coin_0.value() == 2000, 0);

    let (batch, coin_1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        batch, &mut escrow, 1, true, 2000, ctx,
    );
    assert!(coin_1.value() == 2000, 1);

    let (batch, coin_2) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_2_ASSET>(
        batch, &mut escrow, 2, true, 2000, ctx,
    );
    assert!(coin_2.value() == 2000, 2);

    // Finalize with 3-outcome proposal
    let proposal = setup_proposal(&escrow, 3, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(coin_0);
    coin::burn_for_testing(coin_1);
    coin::burn_for_testing(coin_2);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Tests: partial unwrap ===

/// Unwrap only a portion of the balance — verifying partial extraction works.
#[test]
fun test_partial_unwrap_from_batch() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 1000 asset
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, asset_coin);

    // Unwrap only 600 from outcome 0
    let (batch, coin_0a) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 600, ctx,
    );
    assert!(coin_0a.value() == 600, 0);

    // Unwrap remaining 400 from outcome 0
    let (batch, coin_0b) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 400, ctx,
    );
    assert!(coin_0b.value() == 400, 1);

    // Unwrap full 1000 from outcome 1
    let (batch, coin_1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        batch, &mut escrow, 1, true, 1000, ctx,
    );
    assert!(coin_1.value() == 1000, 2);

    // Finalize
    let proposal = setup_proposal(&escrow, 2, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(coin_0a);
    coin::burn_for_testing(coin_0b);
    coin::burn_for_testing(coin_1);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Tests: insufficient balance should abort ===

#[test]
#[expected_failure]
fun test_unwrap_from_batch_insufficient_balance_aborts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split only 100 asset
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(100, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, asset_coin);

    // Try to unwrap 200 — should abort
    let (_batch, _coin) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 200, ctx,
    );

    abort 999
}

// === Tests: mixed asset + stable split ===

/// Split both asset and stable into the same batch.
#[test]
fun test_split_both_asset_and_stable_to_batch() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 1000 asset + 500 stable
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, asset_coin);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(500, ctx);
    let batch = swap_entry::split_stable_to_batch(batch, &mut escrow, stable_coin);

    // Unwrap all 4 positions (2 outcomes x 2 types)
    let (batch, a0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 1000, ctx,
    );
    assert!(a0.value() == 1000, 0);

    let (batch, s0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        batch, &mut escrow, 0, false, 500, ctx,
    );
    assert!(s0.value() == 500, 1);

    let (batch, a1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        batch, &mut escrow, 1, true, 1000, ctx,
    );
    assert!(a1.value() == 1000, 2);

    let (batch, s1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_STABLE>(
        batch, &mut escrow, 1, false, 500, ctx,
    );
    assert!(s1.value() == 500, 3);

    // Finalize
    let proposal = setup_proposal(&escrow, 2, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(a0);
    coin::burn_for_testing(s0);
    coin::burn_for_testing(a1);
    coin::burn_for_testing(s1);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Tests: sequential splits accumulate ===

/// Splitting asset twice into the same batch should accumulate balances.
#[test]
fun test_sequential_asset_splits_accumulate() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 300, then 700 — total 1000 per outcome
    let coin_a = coin::mint_for_testing<TEST_COIN_A>(300, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, coin_a);
    let coin_b = coin::mint_for_testing<TEST_COIN_A>(700, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, coin_b);

    // Unwrap full 1000 from each outcome
    let (batch, coin_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 1000, ctx,
    );
    assert!(coin_0.value() == 1000, 0);

    let (batch, coin_1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        batch, &mut escrow, 1, true, 1000, ctx,
    );
    assert!(coin_1.value() == 1000, 1);

    // Finalize
    let proposal = setup_proposal(&escrow, 2, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(coin_0);
    coin::burn_for_testing(coin_1);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Splitting stable twice into the same batch should accumulate balances.
#[test]
fun test_sequential_stable_splits_accumulate() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 200, then 800 — total 1000 per outcome
    let coin_a = coin::mint_for_testing<TEST_COIN_B>(200, ctx);
    let batch = swap_entry::split_stable_to_batch(batch, &mut escrow, coin_a);
    let coin_b = coin::mint_for_testing<TEST_COIN_B>(800, ctx);
    let batch = swap_entry::split_stable_to_batch(batch, &mut escrow, coin_b);

    // Unwrap full 1000 from each outcome
    let (batch, coin_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        batch, &mut escrow, 0, false, 1000, ctx,
    );
    assert!(coin_0.value() == 1000, 0);

    let (batch, coin_1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_STABLE>(
        batch, &mut escrow, 1, false, 1000, ctx,
    );
    assert!(coin_1.value() == 1000, 1);

    // Finalize
    let proposal = setup_proposal(&escrow, 2, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(coin_0);
    coin::burn_for_testing(coin_1);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Tests: zero amount aborts ===

/// Splitting a zero-value asset coin should abort.
#[test]
#[expected_failure]
fun test_split_zero_amount_asset_aborts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Zero-value coin should abort
    let zero_coin = coin::mint_for_testing<TEST_COIN_A>(0, ctx);
    let _batch = swap_entry::split_asset_to_batch(batch, &mut escrow, zero_coin);

    abort 999
}

/// Splitting a zero-value stable coin should abort.
#[test]
#[expected_failure]
fun test_split_zero_amount_stable_aborts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Zero-value coin should abort
    let zero_coin = coin::mint_for_testing<TEST_COIN_B>(0, ctx);
    let _batch = swap_entry::split_stable_to_batch(batch, &mut escrow, zero_coin);

    abort 999
}

/// Unwrapping zero amount should abort.
#[test]
#[expected_failure]
fun test_unwrap_zero_amount_aborts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, asset_coin);

    // Zero amount unwrap should abort
    let (_batch, _coin) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 0, ctx,
    );

    abort 999
}

// === Tests: 3-outcome stable split ===

/// Verify stable split + unwrap works for 3 outcomes.
#[test]
fun test_split_stable_and_unwrap_3_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_3(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 750 stable into all 3 outcomes
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(750, ctx);
    let batch = swap_entry::split_stable_to_batch(batch, &mut escrow, stable_coin);

    // Unwrap from all 3 outcomes
    let (batch, coin_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        batch, &mut escrow, 0, false, 750, ctx,
    );
    assert!(coin_0.value() == 750, 0);

    let (batch, coin_1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_STABLE>(
        batch, &mut escrow, 1, false, 750, ctx,
    );
    assert!(coin_1.value() == 750, 1);

    let (batch, coin_2) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_2_STABLE>(
        batch, &mut escrow, 2, false, 750, ctx,
    );
    assert!(coin_2.value() == 750, 2);

    // Finalize
    let proposal = setup_proposal(&escrow, 3, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(coin_0);
    coin::burn_for_testing(coin_1);
    coin::burn_for_testing(coin_2);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Tests: mixed splits with 3 outcomes ===

/// Split both asset and stable into a 3-outcome batch, then unwrap all 6 positions.
#[test]
fun test_mixed_split_and_unwrap_3_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_3(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 500 asset + 300 stable
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, asset_coin);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(300, ctx);
    let batch = swap_entry::split_stable_to_batch(batch, &mut escrow, stable_coin);

    // Unwrap all 6 positions (3 outcomes x 2 types)
    let (batch, a0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 500, ctx,
    );
    assert!(a0.value() == 500, 0);

    let (batch, s0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        batch, &mut escrow, 0, false, 300, ctx,
    );
    assert!(s0.value() == 300, 1);

    let (batch, a1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        batch, &mut escrow, 1, true, 500, ctx,
    );
    assert!(a1.value() == 500, 2);

    let (batch, s1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_STABLE>(
        batch, &mut escrow, 1, false, 300, ctx,
    );
    assert!(s1.value() == 300, 3);

    let (batch, a2) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_2_ASSET>(
        batch, &mut escrow, 2, true, 500, ctx,
    );
    assert!(a2.value() == 500, 4);

    let (batch, s2) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_2_STABLE>(
        batch, &mut escrow, 2, false, 300, ctx,
    );
    assert!(s2.value() == 300, 5);

    // Finalize
    let proposal = setup_proposal(&escrow, 3, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(a0);
    coin::burn_for_testing(s0);
    coin::burn_for_testing(a1);
    coin::burn_for_testing(s1);
    coin::burn_for_testing(a2);
    coin::burn_for_testing(s2);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Tests: interleaved split and unwrap ===

/// Split, partially unwrap, split more, unwrap the rest.
#[test]
fun test_interleaved_split_and_unwrap() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // First split: 400 asset
    let coin_a = coin::mint_for_testing<TEST_COIN_A>(400, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, coin_a);

    // Partial unwrap: 200 from outcome 0
    let (batch, partial_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 200, ctx,
    );
    assert!(partial_0.value() == 200, 0);

    // Second split: 600 more asset (now 800 remaining in outcome 0, 1000 in outcome 1)
    let coin_b = coin::mint_for_testing<TEST_COIN_A>(600, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, coin_b);

    // Unwrap remaining: 800 from outcome 0, 1000 from outcome 1
    let (batch, rest_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 800, ctx,
    );
    assert!(rest_0.value() == 800, 1);

    let (batch, rest_1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        batch, &mut escrow, 1, true, 1000, ctx,
    );
    assert!(rest_1.value() == 1000, 2);

    // Finalize
    let proposal = setup_proposal(&escrow, 2, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(partial_0);
    coin::burn_for_testing(rest_0);
    coin::burn_for_testing(rest_1);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Tests: unwrap only one outcome (asymmetric) ===

/// Unwrap from only one outcome, leaving the other in the balance.
/// Finalize should transfer the non-empty balance to recipient.
#[test]
fun test_unwrap_single_outcome_finalize_transfers_residual() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // Split 1000 asset
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, asset_coin);

    // Only unwrap outcome 0 — outcome 1 stays in balance
    let (batch, coin_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, 1000, ctx,
    );
    assert!(coin_0.value() == 1000, 0);

    // Finalize — residual balance (outcome 1 has 1000 asset) transferred to recipient
    let proposal = setup_proposal(&escrow, 2, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(coin_0);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Tests: large amounts (stress) ===

/// Verify split/unwrap works with large amounts near typical token supplies.
#[test]
fun test_large_amount_split_and_unwrap() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);

    let mut escrow = create_escrow_with_caps_2(&clock, ctx);
    enable_trading(&mut escrow);

    let batch = swap_entry::begin_conditional_swaps(&escrow, &clock, ctx);

    // 10 billion (typical token supply with 9 decimals)
    let large_amount = 10_000_000_000u64;
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(large_amount, ctx);
    let batch = swap_entry::split_asset_to_batch(batch, &mut escrow, asset_coin);

    // Unwrap full amount from both outcomes
    let (batch, coin_0) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        batch, &mut escrow, 0, true, large_amount, ctx,
    );
    assert!(coin_0.value() == large_amount, 0);

    let (batch, coin_1) = swap_entry::unwrap_from_batch<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        batch, &mut escrow, 1, true, large_amount, ctx,
    );
    assert!(coin_1.value() == large_amount, 1);

    // Finalize
    let proposal = setup_proposal(&escrow, 2, ctx);
    let mut spot_pool = create_test_spot_pool(100_000, 100_000, 30, ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    finalize_batch(
        batch, &mut escrow, &mut spot_pool, &proposal,
        &escrow_registry, &market_state_registry, &clock, ctx,
    );

    // Cleanup
    coin::burn_for_testing(coin_0);
    coin::burn_for_testing(coin_1);
    sui::test_utils::destroy(escrow);
    unified_spot_pool::destroy_for_testing(spot_pool);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    proposal::destroy_for_testing(proposal);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
