#[test_only]
module futarchy_markets_primitives::coin_escrow_tests;

use futarchy_core::escrow_mutation_auth;
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use sui::clock;
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
use sui::test_scenario as ts;
use sui::test_utils;

// === Test Coin Types for Conditional Coins ===
// We need unique types for each outcome's conditional coins

// Outcome 0 conditional coins
public struct COND_0_ASSET {}
public struct COND_0_STABLE {}

// Outcome 1 conditional coins
public struct COND_1_ASSET {}
public struct COND_1_STABLE {}

// Outcome 2 conditional coins (for 3-outcome tests)
public struct COND_2_ASSET {}
public struct COND_2_STABLE {}

// === Helper Functions ===

/// Create a test market state with specified outcome count
fun create_test_market_state(outcome_count: u64, ctx: &mut TxContext): MarketState {
    market_state::create_for_testing(outcome_count, ctx)
}

/// Create blank treasury cap for testing (no metadata needed for tests)
fun create_blank_treasury_cap_for_testing<T>(ctx: &mut TxContext): TreasuryCap<T> {
    coin::create_treasury_cap_for_testing<T>(ctx)
}

/// Test helper: deposit spot asset, mint conditional, and set outcome_escrowed.
/// Replaces the deleted deposit_asset_and_mint_conditional public function.
fun test_deposit_and_mint_asset<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    asset_coin: Coin<AssetType>,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    let amount = asset_coin.value();
    coin_escrow::deposit_spot_asset_for_balance(escrow, asset_coin);
    let cond = coin_escrow::mint_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow, outcome_index, amount, ctx,
    );
    let current = coin_escrow::get_outcome_escrowed_asset(escrow, outcome_index);
    coin_escrow::set_outcome_escrowed_for_testing(escrow, outcome_index, true, current + amount);
    cond
}

/// Test helper: deposit spot stable, mint conditional, and set outcome_escrowed.
/// Replaces the deleted deposit_stable_and_mint_conditional public function.
fun test_deposit_and_mint_stable<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    let amount = stable_coin.value();
    coin_escrow::deposit_spot_stable_for_balance(escrow, stable_coin);
    let cond = coin_escrow::mint_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow, outcome_index, amount, ctx,
    );
    let current = coin_escrow::get_outcome_escrowed_stable(escrow, outcome_index);
    coin_escrow::set_outcome_escrowed_for_testing(escrow, outcome_index, false, current + amount);
    cond
}

// === Stage 1: Basic Setup and Registration Tests ===

#[test]
fun test_create_empty_escrow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create market state with 2 outcomes
    let market_state = create_test_market_state(2, ctx);

    // Create escrow
    let escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Verify initial state
    assert!(coin_escrow::caps_registered_count(&escrow) == 0, 0);
    let (asset_bal, stable_bal) = coin_escrow::get_spot_balances(&escrow);
    assert!(asset_bal == 0, 1);
    assert!(stable_bal == 0, 2);

    // Verify market state is accessible
    let ms = coin_escrow::get_market_state(&escrow);
    assert!(market_state::outcome_count(ms) == 2, 3);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_register_single_outcome_caps() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create market state with 1 outcome
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Create conditional coin caps for outcome 0
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);

    // Register the caps
    coin_escrow::register_conditional_caps(
        &mut escrow,
        0, // outcome_idx
        asset_cap,
        stable_cap,
    );

    // Verify registration
    assert!(coin_escrow::caps_registered_count(&escrow) == 1, 0);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::ESupplyNotZero)]
fun test_register_rejects_preminted_asset_cap() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let mut asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    let preminted = coin::mint(&mut asset_cap, 1, ctx);

    coin_escrow::register_conditional_caps(
        &mut escrow,
        0,
        asset_cap,
        stable_cap,
    );

    transfer::public_transfer(preminted, @0x1);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::ESupplyNotZero)]
fun test_register_rejects_preminted_stable_cap() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let mut stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    let preminted = coin::mint(&mut stable_cap, 1, ctx);

    coin_escrow::register_conditional_caps(
        &mut escrow,
        0,
        asset_cap,
        stable_cap,
    );

    transfer::public_transfer(preminted, @0x1);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_register_multiple_outcome_caps_in_order() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create market state with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register outcome 0
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    // Verify count after first registration
    assert!(coin_escrow::caps_registered_count(&escrow) == 1, 0);

    // Register outcome 1
    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Verify count after second registration
    assert!(coin_escrow::caps_registered_count(&escrow) == 2, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_get_asset_and_stable_supply_after_registration() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create market state and escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps for outcome 0
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Check initial supplies (should be 0)
    let asset_supply = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &escrow,
        0,
    );
    let stable_supply = coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &escrow,
        0,
    );

    assert!(asset_supply == 0, 0);
    assert!(stable_supply == 0, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_market_state_accessors() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let outcome_count = 3;
    let market_state = create_test_market_state(outcome_count, ctx);
    let expected_market_id = market_state::market_id(&market_state);

    let escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Test get_market_state
    let ms = coin_escrow::get_market_state(&escrow);
    assert!(market_state::outcome_count(ms) == outcome_count, 0);

    // Test market_state_id
    let market_id = coin_escrow::market_state_id(&escrow);
    assert!(market_id == expected_market_id, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_get_spot_balances_initially_zero() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let (asset_balance, stable_balance) = coin_escrow::get_spot_balances(&escrow);
    assert!(asset_balance == 0, 0);
    assert!(stable_balance == 0, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// === Error Case Tests ===

#[test]
#[expected_failure(abort_code = coin_escrow::EOutcomeOutOfBounds)]
fun test_register_caps_outcome_out_of_bounds() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create market with 2 outcomes (indices 0 and 1)
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Try to register outcome 2 (out of bounds)
    let asset_cap = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);

    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap, stable_cap);

    // Should not reach here
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EIncorrectSequence)]
fun test_register_caps_incorrect_sequence() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create market with 3 outcomes
    let market_state = create_test_market_state(3, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register outcome 0 first (correct)
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    // Try to register outcome 2 (skipping 1) - should fail
    let asset_cap_2 = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap_2 = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap_2, stable_cap_2);

    // Should not reach here
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_three_outcome_market_registration() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create market with 3 outcomes
    let market_state = create_test_market_state(3, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register all three outcomes in order
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    let asset_cap_2 = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap_2 = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap_2, stable_cap_2);

    // Verify all registered
    assert!(coin_escrow::caps_registered_count(&escrow) == 3, 0);

    // Verify supplies for all outcomes
    let supply_0 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &escrow,
        0,
    );
    let supply_1 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &escrow,
        1,
    );
    let supply_2 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_2_ASSET>(
        &escrow,
        2,
    );

    assert!(supply_0 == 0, 1);
    assert!(supply_1 == 0, 2);
    assert!(supply_2 == 0, 3);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// === Stage 2: Minting Conditional Coins Tests ===

#[test]
fun test_mint_conditional_asset_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with registered caps
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint conditional asset coins
    let amount = 1000;
    let cond_coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0, // outcome_index
        amount,
        ctx,
    );

    // Verify minted coin
    assert!(cond_coin.value() == amount, 0);

    // Verify supply updated
    let supply = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0);
    assert!(supply == amount, 1);

    coin::burn_for_testing(cond_coin);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_mint_conditional_stable_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with registered caps
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint conditional stable coins
    let amount = 2000;
    let cond_coin = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0, // outcome_index
        amount,
        ctx,
    );

    // Verify minted coin
    assert!(cond_coin.value() == amount, 0);

    // Verify supply updated
    let supply = coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &escrow,
        0,
    );
    assert!(supply == amount, 1);

    coin::burn_for_testing(cond_coin);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_mint_multiple_times_accumulates_supply() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint first batch
    let coin1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        500,
        ctx,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 500,
        0,
    );

    // Mint second batch
    let coin2 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        300,
        ctx,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 800,
        1,
    );

    // Mint third batch
    let coin3 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        200,
        ctx,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 1000,
        2,
    );

    coin::burn_for_testing(coin1);
    coin::burn_for_testing(coin2);
    coin::burn_for_testing(coin3);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_mint_different_outcomes_independently() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup 2-outcome market
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps for both outcomes
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Mint for outcome 0
    let coin_0 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );

    // Mint for outcome 1
    let coin_1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &mut escrow,
        1,
        2000,
        ctx,
    );

    // Verify independent supplies
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 1000,
        0,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(&escrow, 1) == 2000,
        1,
    );

    coin::burn_for_testing(coin_0);
    coin::burn_for_testing(coin_1);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EOutcomeOutOfBounds)]
fun test_mint_conditional_asset_out_of_bounds() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup 1-outcome market (only index 0 valid)
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Try to mint for outcome 1 (out of bounds)
    let coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        1, // out of bounds
        1000,
        ctx,
    );

    // Should not reach here
    coin::burn_for_testing(coin);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_mint_conditional_asset_and_stable_for_same_outcome() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint both asset and stable for same outcome
    let asset_coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1500,
        ctx,
    );
    let stable_coin = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        2500,
        ctx,
    );

    // Verify independent supplies
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 1500,
        0,
    );
    assert!(
        coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(&escrow, 0) == 2500,
        1,
    );

    coin::burn_for_testing(asset_coin);
    coin::burn_for_testing(stable_coin);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_mint_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint zero amount (should be allowed)
    let coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        0,
        ctx,
    );

    assert!(coin.value() == 0, 0);
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        1,
    );

    coin::burn_for_testing(coin);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_mint_large_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint large amount
    let large_amount = 1_000_000_000_000; // 1 trillion
    let coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        large_amount,
        ctx,
    );

    assert!(coin.value() == large_amount, 0);
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == large_amount,
        1,
    );

    coin::burn_for_testing(coin);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

// === Stage 3: Burning Conditional Coins Tests ===

#[test]
fun test_burn_conditional_asset_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint and then burn
    let amount = 1000;
    let coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        amount,
        ctx,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == amount,
        0,
    );

    // Burn the coin
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        coin,
    );

    // Verify supply reduced to zero
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        1,
    );

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_burn_conditional_stable_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint and then burn
    let amount = 2000;
    let coin = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        amount,
        ctx,
    );
    assert!(
        coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(&escrow, 0) == amount,
        0,
    );

    // Burn the coin
    coin_escrow::burn_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        coin,
    );

    // Verify supply reduced to zero
    assert!(
        coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(&escrow, 0) == 0,
        1,
    );

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_burn_partial_supply() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint 1000
    let coin1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );
    // Mint another 500
    let coin2 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        500,
        ctx,
    );

    // Total supply should be 1500
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 1500,
        0,
    );

    // Burn first coin (1000)
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        coin1,
    );

    // Supply should be 500
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 500,
        1,
    );

    // Burn second coin (500)
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        coin2,
    );

    // Supply should be 0
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        2,
    );

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_burn_different_outcomes_independently() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup 2-outcome market
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Mint for both outcomes
    let coin_0 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );
    let coin_1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &mut escrow,
        1,
        2000,
        ctx,
    );

    // Burn outcome 0
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        coin_0,
    );

    // Verify outcome 0 supply is 0, outcome 1 unchanged
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        0,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(&escrow, 1) == 2000,
        1,
    );

    // Burn outcome 1
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &mut escrow,
        1,
        coin_1,
    );

    // Verify both supplies are 0
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        2,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(&escrow, 1) == 0,
        3,
    );

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_burn_asset_and_stable_independently() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint both
    let asset_coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1500,
        ctx,
    );
    let stable_coin = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        2500,
        ctx,
    );

    // Burn asset
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        asset_coin,
    );

    // Verify asset supply is 0, stable unchanged
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        0,
    );
    assert!(
        coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(&escrow, 0) == 2500,
        1,
    );

    // Burn stable
    coin_escrow::burn_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        stable_coin,
    );

    // Verify both supplies are 0
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        2,
    );
    assert!(
        coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(&escrow, 0) == 0,
        3,
    );

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EOutcomeOutOfBounds)]
fun test_burn_conditional_asset_out_of_bounds() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup 1-outcome market
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint for outcome 0
    let coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );

    // Try to burn with outcome 1 (out of bounds)
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        1,
        coin, // Wrong outcome index
    );

    // Should not reach here
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_mint_burn_cycle_maintains_zero_supply() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Initial supply is 0
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        0,
    );

    // Cycle 1: Mint and burn
    let coin1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        coin1,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        1,
    );

    // Cycle 2: Mint and burn different amount
    let coin2 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        5000,
        ctx,
    );
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        coin2,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        2,
    );

    // Cycle 3: Mint and burn again
    let coin3 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        100,
        ctx,
    );
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        coin3,
    );
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        3,
    );

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_burn_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint zero
    let coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        0,
        ctx,
    );

    // Burn zero
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        coin,
    );

    // Supply should still be 0
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        0,
    );

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_burn_large_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint large amount
    let large_amount = 1_000_000_000_000; // 1 trillion
    let coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        large_amount,
        ctx,
    );

    // Burn large amount
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        coin,
    );

    // Supply should be back to 0
    assert!(
        coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0) == 0,
        0,
    );

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// === Stage 4: Spot Deposits and Withdrawals Tests ===

#[test]
fun test_deposit_spot_coins_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Create spot coins
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(2000, ctx);

    // Deposit spot coins
    let (asset_amt, stable_amt) = coin_escrow::deposit_spot_coins(
        &mut escrow,
        asset_coin,
        stable_coin,
    );

    // Verify returned amounts
    assert!(asset_amt == 1000, 0);
    assert!(stable_amt == 2000, 1);

    // Verify balances
    let (bal_asset, bal_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 1000, 2);
    assert!(bal_stable == 2000, 3);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_deposit_spot_coins_multiple_times() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // First deposit
    let asset_coin_1 = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let stable_coin_1 = coin::mint_for_testing<TEST_COIN_B>(1000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin_1, stable_coin_1);

    let (bal1_asset, bal1_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal1_asset == 500, 0);
    assert!(bal1_stable == 1000, 1);

    // Second deposit
    let asset_coin_2 = coin::mint_for_testing<TEST_COIN_A>(300, ctx);
    let stable_coin_2 = coin::mint_for_testing<TEST_COIN_B>(700, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin_2, stable_coin_2);

    let (bal2_asset, bal2_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal2_asset == 800, 2);
    assert!(bal2_stable == 1700, 3);

    // Third deposit
    let asset_coin_3 = coin::mint_for_testing<TEST_COIN_A>(200, ctx);
    let stable_coin_3 = coin::mint_for_testing<TEST_COIN_B>(300, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin_3, stable_coin_3);

    let (bal3_asset, bal3_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal3_asset == 1000, 4);
    assert!(bal3_stable == 2000, 5);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_withdraw_from_escrow_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Deposit first
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(2000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin, stable_coin);

    // Withdraw
    let (withdrawn_asset, withdrawn_stable) = coin_escrow::withdraw_from_escrow(
        &mut escrow,
        500, // asset amount
        1000, // stable amount
        ctx,
    );

    // Verify withdrawn amounts
    assert!(withdrawn_asset.value() == 500, 0);
    assert!(withdrawn_stable.value() == 1000, 1);

    // Verify remaining balances
    let (bal_asset, bal_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 500, 2);
    assert!(bal_stable == 1000, 3);

    coin::burn_for_testing(withdrawn_asset);
    coin::burn_for_testing(withdrawn_stable);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_withdraw_all_from_escrow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Deposit
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(2000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin, stable_coin);

    // Withdraw all
    let (withdrawn_asset, withdrawn_stable) = coin_escrow::withdraw_from_escrow(
        &mut escrow,
        1000,
        2000,
        ctx,
    );

    // Verify amounts
    assert!(withdrawn_asset.value() == 1000, 0);
    assert!(withdrawn_stable.value() == 2000, 1);

    // Verify escrow is empty
    let (bal_asset, bal_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 0, 2);
    assert!(bal_stable == 0, 3);

    coin::burn_for_testing(withdrawn_asset);
    coin::burn_for_testing(withdrawn_stable);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_withdraw_asset_balance_only() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Deposit
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(2000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin, stable_coin);

    // Withdraw only asset
    let auth = escrow_mutation_auth::create_for_testing();
    let withdrawn_asset = coin_escrow::withdraw_asset_balance(
        &mut escrow,
        500,
        ctx,
        &auth,
    );

    assert!(withdrawn_asset.value() == 500, 0);

    // Verify balances (only asset reduced, stable unchanged)
    let (bal_asset, bal_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 500, 1);
    assert!(bal_stable == 2000, 2);

    coin::burn_for_testing(withdrawn_asset);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_withdraw_stable_balance_only() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Deposit
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(2000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin, stable_coin);

    // Withdraw only stable
    let auth = escrow_mutation_auth::create_for_testing();
    let withdrawn_stable = coin_escrow::withdraw_stable_balance(
        &mut escrow,
        1000,
        ctx,
        &auth,
    );

    assert!(withdrawn_stable.value() == 1000, 0);

    // Verify balances (only stable reduced, asset unchanged)
    let (bal_asset, bal_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 1000, 1);
    assert!(bal_stable == 1000, 2);

    coin::burn_for_testing(withdrawn_stable);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_deposit_withdraw_cycle() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Cycle 1: Deposit and withdraw
    let asset1 = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let stable1 = coin::mint_for_testing<TEST_COIN_B>(1000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset1, stable1);

    let (w_asset1, w_stable1) = coin_escrow::withdraw_from_escrow(&mut escrow, 500, 1000, ctx);
    coin::burn_for_testing(w_asset1);
    coin::burn_for_testing(w_stable1);

    let (bal1_a, bal1_s) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal1_a == 0 && bal1_s == 0, 0);

    // Cycle 2: Different amounts
    let asset2 = coin::mint_for_testing<TEST_COIN_A>(2000, ctx);
    let stable2 = coin::mint_for_testing<TEST_COIN_B>(3000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset2, stable2);

    let (w_asset2, w_stable2) = coin_escrow::withdraw_from_escrow(&mut escrow, 2000, 3000, ctx);
    coin::burn_for_testing(w_asset2);
    coin::burn_for_testing(w_stable2);

    let (bal2_a, bal2_s) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal2_a == 0 && bal2_s == 0, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EZeroAmount)]
fun test_deposit_zero_both_coins() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Try to deposit zero for both (should fail)
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(0, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(0, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin, stable_coin);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_deposit_zero_asset_nonzero_stable() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Deposit zero asset, non-zero stable (should succeed)
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(0, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1000, ctx);
    let (asset_amt, stable_amt) = coin_escrow::deposit_spot_coins(
        &mut escrow,
        asset_coin,
        stable_coin,
    );

    assert!(asset_amt == 0, 0);
    assert!(stable_amt == 1000, 1);

    let (bal_a, bal_s) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_a == 0, 2);
    assert!(bal_s == 1000, 3);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_deposit_nonzero_asset_zero_stable() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Deposit non-zero asset, zero stable (should succeed)
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(0, ctx);
    let (asset_amt, stable_amt) = coin_escrow::deposit_spot_coins(
        &mut escrow,
        asset_coin,
        stable_coin,
    );

    assert!(asset_amt == 1000, 0);
    assert!(stable_amt == 0, 1);

    let (bal_a, bal_s) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_a == 1000, 2);
    assert!(bal_s == 0, 3);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::ENotEnoughLiquidity)]
fun test_withdraw_insufficient_asset() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Deposit 500 asset
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin, stable_coin);

    // Try to withdraw 1000 asset (more than available)
    let (w_asset, w_stable) = coin_escrow::withdraw_from_escrow(&mut escrow, 1000, 500, ctx);

    // Should not reach here
    coin::burn_for_testing(w_asset);
    coin::burn_for_testing(w_stable);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::ENotEnoughLiquidity)]
fun test_withdraw_insufficient_stable() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Deposit 1000 stable
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin, stable_coin);

    // Try to withdraw 2000 stable (more than available)
    let (w_asset, w_stable) = coin_escrow::withdraw_from_escrow(&mut escrow, 500, 2000, ctx);

    // Should not reach here
    coin::burn_for_testing(w_asset);
    coin::burn_for_testing(w_stable);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_deposit_large_amounts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Deposit large amounts
    let large_amt = 1_000_000_000_000;
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(large_amt, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(large_amt, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, asset_coin, stable_coin);

    let (bal_a, bal_s) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_a == large_amt, 0);
    assert!(bal_s == large_amt, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// === Stage 5: Deposit-Mint and Burn-Withdraw Tests ===


#[test]
fun test_burn_asset_and_withdraw_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // First, deposit spot tokens and mint conditional coins
    let spot_deposit = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let mut cond_asset = test_deposit_and_mint_asset<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        &mut escrow,
        0,
        spot_deposit,
        ctx,
    );

    // Split to get 500 for withdrawal
    let cond_to_burn = cond_asset.split(500, ctx);
    coin::burn_for_testing(cond_asset);

    // Finalize market for redemption
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Burn conditional and withdraw spot (this is for redemption scenario)
    let withdrawn_spot = coin_escrow::burn_conditional_asset_and_withdraw<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        &mut escrow,
        cond_to_burn,
        ctx,
    );

    // Verify withdrawn amount (1:1 ratio)
    assert!(withdrawn_spot.value() == 500, 0);

    // Verify escrow balance decreased
    let (bal_asset, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 500, 1); // 1000 - 500

    // Verify conditional supply (minted 1000, burned 500 through escrow)
    // Note: coin::burn_for_testing doesn't affect escrow supply tracking
    let supply = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0);
    assert!(supply == 500, 2); // 1000 minted - 500 burned via escrow

    coin::burn_for_testing(withdrawn_spot);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_burn_stable_and_withdraw_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit stable and mint conditional stable coins
    let spot_deposit = coin::mint_for_testing<TEST_COIN_B>(2000, ctx);
    let mut cond_stable = test_deposit_and_mint_stable<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_STABLE,
    >(
        &mut escrow,
        0,
        spot_deposit,
        ctx,
    );

    // Split to get 1000 for withdrawal
    let cond_to_burn = cond_stable.split(1000, ctx);
    coin::burn_for_testing(cond_stable);

    // Finalize market for redemption
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Burn conditional and withdraw spot
    let withdrawn_spot = coin_escrow::burn_conditional_stable_and_withdraw<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_STABLE,
    >(
        &mut escrow,
        cond_to_burn,
        ctx,
    );

    // Verify withdrawn amount
    assert!(withdrawn_spot.value() == 1000, 0);

    // Verify escrow balance decreased
    let (_, bal_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_stable == 1000, 1); // 2000 - 1000

    // Verify supply (minted 2000, burned 1000 through escrow)
    // Note: coin::burn_for_testing doesn't affect escrow supply tracking
    let supply = coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &escrow,
        0,
    );
    assert!(supply == 1000, 2); // 2000 minted - 1000 burned via escrow

    coin::burn_for_testing(withdrawn_spot);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_full_cycle_deposit_mint_burn_withdraw() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);
    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Initial state: zero balances
    let (bal0_a, bal0_s) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal0_a == 0 && bal0_s == 0, 0);

    // Step 1: Deposit and mint
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let mut cond_asset = test_deposit_and_mint_asset<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        &mut escrow,
        0,
        spot_asset,
        ctx,
    );
    assert!(cond_asset.value() == 1000, 1);

    // State after deposit: escrow has 1000, supply is 1000
    let (bal1_a, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal1_a == 1000, 2);
    let supply1 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0);
    assert!(supply1 == 1000, 3);

    // Step 2: Split and burn some conditional coins (manually, separate from withdraw)
    // NOTE: Raw burn doesn't update outcome_escrowed (by design - wrap_coin uses burn too).
    // In real flows, recombine progress functions handle allocation updates.
    // For this test, we simulate by also decrementing the allocation.
    let cond_to_withdraw = cond_asset.split(500, ctx);
    let burn_amount = cond_asset.value();
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        cond_asset,
    );
    // Manually adjust allocation to simulate proper recombine flow
    // (In real code, this happens in start_recombine_*_progress / recombine_*_progress_step)
    let current_alloc = coin_escrow::get_outcome_escrowed_asset(&escrow, 0);
    coin_escrow::set_outcome_escrowed_for_testing(
        &mut escrow,
        0,
        true,
        current_alloc - burn_amount,
    );

    // State after burn: escrow still has 1000, supply is 500 (burned 500)
    let (bal2_a, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal2_a == 1000, 4);
    let supply2 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0);
    assert!(supply2 == 500, 5);

    // Finalize market for redemption
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Step 3: Now use burn_and_withdraw to get spot back
    let withdrawn = coin_escrow::burn_conditional_asset_and_withdraw<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        &mut escrow,
        cond_to_withdraw,
        ctx,
    );
    assert!(withdrawn.value() == 500, 6);

    // Final state: escrow has 500, supply is 0
    let (bal3_a, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal3_a == 500, 7);
    let supply3 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(&escrow, 0);
    assert!(supply3 == 0, 8);

    coin::burn_for_testing(withdrawn);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_cross_outcome_operations() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup 2-outcome market
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Deposit and mint for outcome 0 (quantum model: same amount for all outcomes)
    let spot_0 = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let cond_0 = test_deposit_and_mint_asset<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        &mut escrow,
        0,
        spot_0,
        ctx,
    );

    // Deposit and mint for outcome 1 (same amount to maintain quantum invariant)
    let spot_1 = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let mut cond_1 = test_deposit_and_mint_asset<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        &mut escrow,
        1,
        spot_1,
        ctx,
    );

    // Escrow should have accumulated liquidity
    let (bal_asset, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 2000, 0); // 1000 + 1000

    // Burn outcome 0 conditionals
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        cond_0,
    );

    // Verify outcome 0 supply is 0, outcome 1 unchanged
    let supply_0 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &escrow,
        0,
    );
    let supply_1 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &escrow,
        1,
    );
    assert!(supply_0 == 0, 1);
    assert!(supply_1 == 1000, 2);

    // Finalize market for redemption with outcome 1 as winner
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);
    market_state::test_set_winning_outcome(ms, 1);

    // Split cond_1 to get 500 for withdrawal
    let cond_to_withdraw = cond_1.split(500, ctx);

    // Withdraw from shared liquidity using outcome 1's burn-withdraw
    let withdrawn = coin_escrow::burn_conditional_asset_and_withdraw<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        &mut escrow,
        cond_to_withdraw,
        ctx,
    );
    assert!(withdrawn.value() == 500, 3);

    // Escrow balance should decrease
    let (bal_asset2, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset2 == 1500, 4); // 2000 - 500

    coin::burn_for_testing(cond_1);
    coin::burn_for_testing(withdrawn);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

// === Stage 6: Complete Set Operations and Quantum Invariant Tests ===
// Validates the PTB progress helpers for complete set splits/recombines that
// frontends will chain together when constructing programmable transactions.

fun split_asset_complete_set_2_for_testing<AssetType, StableType, Cond0, Cond1>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_asset: Coin<AssetType>,
    ctx: &mut TxContext,
): (Coin<Cond0>, Coin<Cond1>) {
    let progress = coin_escrow::start_split_asset_progress(escrow, spot_asset);
    let (progress, cond_0) = coin_escrow::split_asset_progress_step<AssetType, StableType, Cond0>(
        progress,
        escrow,
        0,
        ctx,
    );
    let (progress, cond_1) = coin_escrow::split_asset_progress_step<AssetType, StableType, Cond1>(
        progress,
        escrow,
        1,
        ctx,
    );
    coin_escrow::finish_split_asset_progress(progress, escrow);
    (cond_0, cond_1)
}

fun split_stable_complete_set_2_for_testing<AssetType, StableType, Cond0, Cond1>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_stable: Coin<StableType>,
    ctx: &mut TxContext,
): (Coin<Cond0>, Coin<Cond1>) {
    let progress = coin_escrow::start_split_stable_progress(escrow, spot_stable);
    let (progress, cond_0) = coin_escrow::split_stable_progress_step<AssetType, StableType, Cond0>(
        progress,
        escrow,
        0,
        ctx,
    );
    let (progress, cond_1) = coin_escrow::split_stable_progress_step<AssetType, StableType, Cond1>(
        progress,
        escrow,
        1,
        ctx,
    );
    coin_escrow::finish_split_stable_progress(progress, escrow);
    (cond_0, cond_1)
}

fun split_asset_complete_set_3_for_testing<AssetType, StableType, Cond0, Cond1, Cond2>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_asset: Coin<AssetType>,
    ctx: &mut TxContext,
): (Coin<Cond0>, Coin<Cond1>, Coin<Cond2>) {
    let progress = coin_escrow::start_split_asset_progress(escrow, spot_asset);
    let (progress, cond_0) = coin_escrow::split_asset_progress_step<AssetType, StableType, Cond0>(
        progress,
        escrow,
        0,
        ctx,
    );
    let (progress, cond_1) = coin_escrow::split_asset_progress_step<AssetType, StableType, Cond1>(
        progress,
        escrow,
        1,
        ctx,
    );
    let (progress, cond_2) = coin_escrow::split_asset_progress_step<AssetType, StableType, Cond2>(
        progress,
        escrow,
        2,
        ctx,
    );
    coin_escrow::finish_split_asset_progress(progress, escrow);
    (cond_0, cond_1, cond_2)
}

fun recombine_asset_complete_set_2_for_testing<AssetType, StableType, Cond0, Cond1>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    cond_0: Coin<Cond0>,
    cond_1: Coin<Cond1>,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let progress = coin_escrow::start_recombine_asset_progress<AssetType, StableType, Cond0>(
        escrow,
        0,
        cond_0,
    );
    let progress = coin_escrow::recombine_asset_progress_step<AssetType, StableType, Cond1>(
        progress,
        escrow,
        1,
        cond_1,
    );
    coin_escrow::finish_recombine_asset_progress(progress, escrow, ctx)
}

fun recombine_stable_complete_set_2_for_testing<AssetType, StableType, Cond0, Cond1>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    cond_0: Coin<Cond0>,
    cond_1: Coin<Cond1>,
    ctx: &mut TxContext,
): Coin<StableType> {
    let progress = coin_escrow::start_recombine_stable_progress<AssetType, StableType, Cond0>(
        escrow,
        0,
        cond_0,
    );
    let progress = coin_escrow::recombine_stable_progress_step<AssetType, StableType, Cond1>(
        progress,
        escrow,
        1,
        cond_1,
    );
    coin_escrow::finish_recombine_stable_progress(progress, escrow, ctx)
}

fun recombine_asset_complete_set_3_for_testing<AssetType, StableType, Cond0, Cond1, Cond2>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    cond_0: Coin<Cond0>,
    cond_1: Coin<Cond1>,
    cond_2: Coin<Cond2>,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let progress = coin_escrow::start_recombine_asset_progress<AssetType, StableType, Cond0>(
        escrow,
        0,
        cond_0,
    );
    let progress = coin_escrow::recombine_asset_progress_step<AssetType, StableType, Cond1>(
        progress,
        escrow,
        1,
        cond_1,
    );
    let progress = coin_escrow::recombine_asset_progress_step<AssetType, StableType, Cond2>(
        progress,
        escrow,
        2,
        cond_2,
    );
    coin_escrow::finish_recombine_asset_progress(progress, escrow, ctx)
}

#[test]
fun test_split_asset_complete_set_2_basic() {
    let mut scenario = ts::begin(@0xBABE);
    let ctx = ts::ctx(&mut scenario);
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Create spot asset
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);

    // Split into complete set via PTB progress flow
    let (cond_0, cond_1) = split_asset_complete_set_2_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
    >(&mut escrow, spot_asset, ctx);

    // Verify escrow balance increased
    let (bal_asset, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 1000, 0);

    // Verify both outcomes have supply
    let supply_0 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &escrow,
        0,
    );
    let supply_1 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &escrow,
        1,
    );
    assert!(supply_0 == 1000, 1);
    assert!(supply_1 == 1000, 2);

    assert!(cond_0.value() == 1000, 3);
    assert!(cond_1.value() == 1000, 4);

    coin::burn_for_testing(cond_0);
    coin::burn_for_testing(cond_1);

    test_utils::destroy(escrow);

    ts::end(scenario);
}

#[test]
fun test_split_stable_complete_set_2_basic() {
    let mut scenario = ts::begin(@0xBABE);
    let ctx = ts::ctx(&mut scenario);
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Create spot stable
    let spot_stable = coin::mint_for_testing<TEST_COIN_B>(2000, ctx);

    // Split into complete set via progress helpers
    let (cond_0, cond_1) = split_stable_complete_set_2_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_STABLE,
        COND_1_STABLE,
    >(&mut escrow, spot_stable, ctx);

    // Verify escrow balance
    let (_, bal_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_stable == 2000, 0);

    // Verify supplies
    let supply_0 = coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &escrow,
        0,
    );
    let supply_1 = coin_escrow::get_stable_supply<TEST_COIN_A, TEST_COIN_B, COND_1_STABLE>(
        &escrow,
        1,
    );
    assert!(supply_0 == 2000, 1);
    assert!(supply_1 == 2000, 2);

    assert!(cond_0.value() == 2000, 3);
    assert!(cond_1.value() == 2000, 4);

    coin::burn_for_testing<COND_0_STABLE>(cond_0);
    coin::burn_for_testing<COND_1_STABLE>(cond_1);

    test_utils::destroy(escrow);

    ts::end(scenario);
}

#[test]
fun test_recombine_asset_complete_set_2_basic() {
    let mut scenario = ts::begin(@0xBABE);
    let ctx = ts::ctx(&mut scenario);
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // First, create complete set
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let (cond_0, cond_1) = split_asset_complete_set_2_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
    >(&mut escrow, spot_asset, ctx);

    // Verify supplies before recombination
    let supply_0_before = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &escrow,
        0,
    );
    let supply_1_before = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &escrow,
        1,
    );
    assert!(supply_0_before == 1000, 0);
    assert!(supply_1_before == 1000, 1);

    // Recombine and verify we receive spot asset
    let spot_back = recombine_asset_complete_set_2_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
    >(&mut escrow, cond_0, cond_1, ctx);

    assert!(spot_back.value() == 1000, 2);
    coin::burn_for_testing<TEST_COIN_A>(spot_back);

    // Supplies should now be zero and escrow balances restored
    let supply_0 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &escrow,
        0,
    );
    let supply_1 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &escrow,
        1,
    );
    assert!(supply_0 == 0, 3);
    assert!(supply_1 == 0, 4);

    let (bal_asset, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 0, 5);

    test_utils::destroy(escrow);

    ts::end(scenario);
}

#[test]
fun test_split_recombine_cycle_maintains_balance() {
    let mut scenario = ts::begin(@0xBABE);
    let ctx = ts::ctx(&mut scenario);
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Split
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let (cond_0, cond_1) = split_asset_complete_set_2_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
    >(&mut escrow, spot_asset, ctx);

    // Immediately recombine
    let spot_back = recombine_asset_complete_set_2_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
    >(&mut escrow, cond_0, cond_1, ctx);

    // Verify complete cycle: balance should be back to zero
    let (bal_asset, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 0, 0);
    assert!(spot_back.value() == 500, 1);

    coin::burn_for_testing<TEST_COIN_A>(spot_back);
    test_utils::destroy(escrow);

    ts::end(scenario);
}

#[test]
fun test_split_asset_complete_set_3_outcomes() {
    let mut scenario = ts::begin(@0xBABE);
    let ctx = ts::ctx(&mut scenario);
    let market_state = create_test_market_state(3, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps for all 3 outcomes
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    let asset_cap_2 = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap_2 = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap_2, stable_cap_2);

    // Split into 3-outcome complete set
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1500, ctx);
    let (cond_0, cond_1, cond_2) = split_asset_complete_set_3_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
        COND_2_ASSET,
    >(&mut escrow, spot_asset, ctx);

    // Verify all 3 outcomes have equal supply (quantum liquidity)
    let supply_0 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &escrow,
        0,
    );
    let supply_1 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &escrow,
        1,
    );
    let supply_2 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_2_ASSET>(
        &escrow,
        2,
    );
    assert!(supply_0 == 1500, 0);
    assert!(supply_1 == 1500, 1);
    assert!(supply_2 == 1500, 2);

    assert!(cond_0.value() == 1500, 3);
    assert!(cond_1.value() == 1500, 4);
    assert!(cond_2.value() == 1500, 5);

    coin::burn_for_testing<COND_0_ASSET>(cond_0);
    coin::burn_for_testing<COND_1_ASSET>(cond_1);
    coin::burn_for_testing<COND_2_ASSET>(cond_2);

    test_utils::destroy(escrow);

    ts::end(scenario);
}

#[test]
fun test_recombine_asset_complete_set_3_outcomes() {
    let mut scenario = ts::begin(@0xBABE);
    let ctx = ts::ctx(&mut scenario);
    let market_state = create_test_market_state(3, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    let asset_cap_2 = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap_2 = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap_2, stable_cap_2);

    // Split
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1500, ctx);
    let (cond_0, cond_1, cond_2) = split_asset_complete_set_3_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
        COND_2_ASSET,
    >(&mut escrow, spot_asset, ctx);

    let spot = recombine_asset_complete_set_3_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
        COND_2_ASSET,
    >(&mut escrow, cond_0, cond_1, cond_2, ctx);

    assert!(spot.value() == 1500, 0);

    let supply_0 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &escrow,
        0,
    );
    let supply_1 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &escrow,
        1,
    );
    let supply_2 = coin_escrow::get_asset_supply<TEST_COIN_A, TEST_COIN_B, COND_2_ASSET>(
        &escrow,
        2,
    );
    assert!(supply_0 == 0, 1);
    assert!(supply_1 == 0, 2);
    assert!(supply_2 == 0, 3);

    let (bal_asset, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(bal_asset == 0, 4);

    coin::burn_for_testing<TEST_COIN_A>(spot);
    test_utils::destroy(escrow);

    ts::end(scenario);
}

// === Stage 8: Quantum Invariant Tracking Tests ===

#[test]
fun test_supply_vector_tracking_on_mint() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register caps for both outcomes
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Verify initial supplies are 0
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 0, 0);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 0, 1);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 0) == 0, 2);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 1) == 0, 3);

    // Mint to outcome 0
    let cond_asset_0 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );
    let cond_stable_0 = coin_escrow::mint_conditional_stable<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_STABLE,
    >(
        &mut escrow,
        0,
        2000,
        ctx,
    );

    // Verify outcome 0 supplies updated
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1000, 4);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 0) == 2000, 5);

    // Verify outcome 1 supplies unchanged
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 0, 6);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 1) == 0, 7);

    // Mint to outcome 1
    let cond_asset_1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &mut escrow,
        1,
        500,
        ctx,
    );

    // Verify outcome 1 updated, outcome 0 unchanged
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1000, 8);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 500, 9);

    coin::burn_for_testing(cond_asset_0);
    coin::burn_for_testing(cond_stable_0);
    coin::burn_for_testing(cond_asset_1);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_supply_vector_tracking_on_burn() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint coins
    let cond_asset = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );

    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1000, 0);

    // Burn coins
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        cond_asset,
    );

    // Verify supply decremented
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 0, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_get_all_supplies_vectors() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 3 outcomes
    let market_state = create_test_market_state(3, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    // Register all caps
    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    let asset_cap_2 = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap_2 = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap_2, stable_cap_2);

    // Mint different amounts to each outcome
    let c0 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        100,
        ctx,
    );
    let c1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &mut escrow,
        1,
        200,
        ctx,
    );
    let c2 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_2_ASSET>(
        &mut escrow,
        2,
        300,
        ctx,
    );

    // Verify get_all_asset_supplies returns correct vector
    let asset_supplies = coin_escrow::get_all_asset_supplies(&escrow);
    assert!(asset_supplies.length() == 3, 0);
    assert!(asset_supplies[0] == 100, 1);
    assert!(asset_supplies[1] == 200, 2);
    assert!(asset_supplies[2] == 300, 3);

    // Verify get_all_stable_supplies returns zeros (nothing minted)
    let stable_supplies = coin_escrow::get_all_stable_supplies(&escrow);
    assert!(stable_supplies.length() == 3, 4);
    assert!(stable_supplies[0] == 0, 5);
    assert!(stable_supplies[1] == 0, 6);
    assert!(stable_supplies[2] == 0, 7);

    coin::burn_for_testing(c0);
    coin::burn_for_testing(c1);
    coin::burn_for_testing(c2);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_assert_quantum_invariant_passes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Deposit spot tokens to escrow
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let spot_stable = coin::mint_for_testing<TEST_COIN_B>(2000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, spot_asset, spot_stable);

    // Mint conditional coins (equal to escrow balance for quantum invariant)
    // Quantum liquidity: escrow == supply[i] for ALL outcomes
    let c0 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );
    let c1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &mut escrow,
        1,
        1000,
        ctx,
    );
    // Also mint stable conditionals to match escrow
    let s0 = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        2000,
        ctx,
    );
    let s1 = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_1_STABLE>(
        &mut escrow,
        1,
        2000,
        ctx,
    );

    // Set outcome_escrowed to match supplies (simulating proper atomic deposit+mint)
    // New invariant: outcome_escrowed[i] == supply[i] + wrapped[i]
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000); // asset outcome 0
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, true, 1000); // asset outcome 1
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 2000); // stable outcome 0
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, false, 2000); // stable outcome 1

    // Invariant should pass (outcome_escrowed == supply for all outcomes)
    coin_escrow::assert_quantum_invariant(&escrow);

    coin::burn_for_testing(s0);
    coin::burn_for_testing(s1);

    coin::burn_for_testing(c0);
    coin::burn_for_testing(c1);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EQuantumInvariantViolation)]
fun test_assert_quantum_invariant_fails_insufficient_escrow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit only 100 spot tokens
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(100, ctx);
    let spot_stable = coin::mint_for_testing<TEST_COIN_B>(100, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, spot_asset, spot_stable);

    // Mint 500 conditional (more than escrow balance of 100)
    let c0 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        500,
        ctx,
    );

    // This should fail - escrow (100) < supply (500)
    coin_escrow::assert_quantum_invariant(&escrow);

    coin::burn_for_testing(c0);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_assert_all_invariants_passes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit via deposit_spot_liquidity (LP backing)
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let spot_stable = coin::mint_for_testing<TEST_COIN_B>(1000, ctx);
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::deposit_spot_liquidity(
        &mut escrow,
        coin::into_balance(spot_asset),
        coin::into_balance(spot_stable),
        &auth,
    );

    // Mint conditional coins (equal to escrow for quantum invariant)
    let c0 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );
    let s0 = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        1000,
        ctx,
    );

    // Set outcome_escrowed to match supplies (simulating proper atomic deposit+mint)
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000); // asset outcome 0
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 1000); // stable outcome 0

    // Both invariants should pass
    coin_escrow::assert_all_invariants(&escrow);

    coin::burn_for_testing(c0);
    coin::burn_for_testing(s0);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_supply_tracking_independent_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Mint/burn only to outcome 0
    let c0 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );

    // Outcome 1 should be unaffected
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 0, 0);

    // Burn from outcome 0
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        c0,
    );

    // Both should be 0 now
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 0, 1);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 0, 2);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EQuantumInvariantViolation)]
fun test_quantum_invariant_checks_all_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Deposit 500 spot
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let spot_stable = coin::mint_for_testing<TEST_COIN_B>(500, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, spot_asset, spot_stable);

    // Outcome 0: mint 300 (OK, 300 <= 500)
    let c0 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        300,
        ctx,
    );

    // Outcome 1: mint 600 (FAIL, 600 > 500)
    let c1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_1_ASSET>(
        &mut escrow,
        1,
        600,
        ctx,
    );

    // Should fail because outcome 1 violates invariant
    coin_escrow::assert_quantum_invariant(&escrow);

    coin::burn_for_testing(c0);
    coin::burn_for_testing(c1);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_supply_tracking_split_recombine() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Split complete set
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let (cond_0, cond_1) = split_asset_complete_set_2_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
    >(&mut escrow, spot_asset, ctx);

    // Both outcomes should have 1000 supply (quantum model)
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1000, 0);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 1000, 1);

    // Quantum invariant should pass
    coin_escrow::assert_quantum_invariant(&escrow);

    // Recombine
    let spot = recombine_asset_complete_set_2_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
        COND_1_ASSET,
    >(&mut escrow, cond_0, cond_1, ctx);

    // Both supplies should be 0
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 0, 2);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 0, 3);

    coin::burn_for_testing(spot);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_quantum_invariant_after_partial_burn_and_withdraw() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit 1000
    let spot = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, spot, coin::zero<TEST_COIN_B>(ctx));

    // Mint 1000
    let mut cond = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );

    // Set outcome_escrowed to match supply (since we used low-level deposit+mint)
    // In real flows, deposit_asset_and_mint_conditional does this atomically
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000);

    // Invariant passes (allocation 1000 == supply 1000)
    coin_escrow::assert_quantum_invariant(&escrow);

    // Split the coin and burn half
    let cond_half = coin::split(&mut cond, 500, ctx);
    coin_escrow::burn_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        cond_half,
    );

    // Also withdraw to maintain quantum invariant (escrow == supply)
    // Must also decrement outcome_escrowed (simulating proper recombine flow)
    let auth = escrow_mutation_auth::create_for_testing();
    let withdrawn = coin_escrow::withdraw_asset_balance(&mut escrow, 500, ctx, &auth);
    coin_escrow::decrement_user_backing(&mut escrow, 500, true, &auth);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 500); // allocation matches new supply
    coin::burn_for_testing(withdrawn);

    // Supply should be 500, escrow should be 500, allocation should be 500
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 500, 0);
    assert!(coin_escrow::get_escrowed_asset_balance(&escrow) == 500, 1);

    // Invariant still passes (allocation 500 == supply 500)
    coin_escrow::assert_quantum_invariant(&escrow);

    coin::burn_for_testing(cond);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_multiple_mints_accumulate_supply() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Multiple mints should accumulate
    let c1 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        100,
        ctx,
    );
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 100, 0);

    let c2 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        200,
        ctx,
    );
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 300, 1);

    let c3 = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        300,
        ctx,
    );
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 600, 2);

    coin::burn_for_testing(c1);
    coin::burn_for_testing(c2);
    coin::burn_for_testing(c3);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_supply_tracks_both_asset_and_stable_independently() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Mint different amounts of asset and stable
    let asset_coin = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );
    let stable_coin = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        5000,
        ctx,
    );

    // Verify independent tracking
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1000, 0);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 0) == 5000, 1);

    // Burn only stable
    coin_escrow::burn_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        stable_coin,
    );

    // Asset unchanged, stable decremented
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1000, 2);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 0) == 0, 3);

    coin::burn_for_testing(asset_coin);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

// === Atomic Deposit+Mint Flow Tests ===
// These tests verify that the Progress pattern enforces the quantum invariant

#[test]
fun test_split_progress_maintains_quantum_invariant() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Perform atomic split via Progress pattern
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let progress = coin_escrow::start_split_asset_progress(&mut escrow, spot_asset);

    let (progress, c0) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        progress,
        &mut escrow,
        0,
        ctx,
    );
    let (progress, c1) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        progress,
        &mut escrow,
        1,
        ctx,
    );
    coin_escrow::finish_split_asset_progress(progress, &escrow);

    // Quantum invariant should hold: escrow == supply for all outcomes
    coin_escrow::assert_quantum_invariant(&escrow);

    // Verify values
    assert!(coin_escrow::get_escrowed_asset_balance(&escrow) == 1000, 0);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1000, 1);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 1000, 2);

    coin::burn_for_testing(c0);
    coin::burn_for_testing(c1);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_recombine_progress_maintains_quantum_invariant() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // First, split to create conditional tokens
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let progress = coin_escrow::start_split_asset_progress(&mut escrow, spot_asset);
    let (progress, c0) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        progress,
        &mut escrow,
        0,
        ctx,
    );
    let (progress, c1) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        progress,
        &mut escrow,
        1,
        ctx,
    );
    coin_escrow::finish_split_asset_progress(progress, &escrow);

    // Invariant holds after split
    coin_escrow::assert_quantum_invariant(&escrow);

    // Now recombine via Progress pattern
    let progress = coin_escrow::start_recombine_asset_progress<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        &mut escrow,
        0,
        c0,
    );
    let progress = coin_escrow::recombine_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        progress,
        &mut escrow,
        1,
        c1,
    );
    let withdrawn = coin_escrow::finish_recombine_asset_progress(progress, &mut escrow, ctx);

    // Quantum invariant should still hold: escrow == supply for all outcomes (both 0)
    coin_escrow::assert_quantum_invariant(&escrow);

    // Verify values are back to 0
    assert!(coin_escrow::get_escrowed_asset_balance(&escrow) == 0, 0);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 0, 1);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 0, 2);
    assert!(coin::value(&withdrawn) == 1000, 3);

    coin::burn_for_testing(withdrawn);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_split_recombine_round_trip_maintains_invariant() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 3 outcomes to test more complex case
    let market_state = create_test_market_state(3, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    let asset_cap_2 = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap_2 = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap_2, stable_cap_2);

    // Split 500 tokens
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let progress = coin_escrow::start_split_asset_progress(&mut escrow, spot_asset);
    let (progress, c0) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        progress,
        &mut escrow,
        0,
        ctx,
    );
    let (progress, c1) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        progress,
        &mut escrow,
        1,
        ctx,
    );
    let (progress, c2) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_2_ASSET,
    >(
        progress,
        &mut escrow,
        2,
        ctx,
    );
    coin_escrow::finish_split_asset_progress(progress, &escrow);

    // Check invariant after split
    coin_escrow::assert_quantum_invariant(&escrow);
    assert!(coin_escrow::get_escrowed_asset_balance(&escrow) == 500, 0);

    // Recombine back
    let progress = coin_escrow::start_recombine_asset_progress<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        &mut escrow,
        0,
        c0,
    );
    let progress = coin_escrow::recombine_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        progress,
        &mut escrow,
        1,
        c1,
    );
    let progress = coin_escrow::recombine_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_2_ASSET,
    >(
        progress,
        &mut escrow,
        2,
        c2,
    );
    let withdrawn = coin_escrow::finish_recombine_asset_progress(progress, &mut escrow, ctx);

    // Check invariant after recombine
    coin_escrow::assert_quantum_invariant(&escrow);
    assert!(coin_escrow::get_escrowed_asset_balance(&escrow) == 0, 1);
    assert!(coin::value(&withdrawn) == 500, 2);

    coin::burn_for_testing(withdrawn);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_multiple_splits_maintain_quantum_invariant() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // First split: 1000
    let spot1 = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let progress = coin_escrow::start_split_asset_progress(&mut escrow, spot1);
    let (progress, c0_1) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        progress,
        &mut escrow,
        0,
        ctx,
    );
    let (progress, c1_1) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        progress,
        &mut escrow,
        1,
        ctx,
    );
    coin_escrow::finish_split_asset_progress(progress, &escrow);

    coin_escrow::assert_quantum_invariant(&escrow);
    assert!(coin_escrow::get_escrowed_asset_balance(&escrow) == 1000, 0);

    // Second split: 500 more
    let spot2 = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let progress = coin_escrow::start_split_asset_progress(&mut escrow, spot2);
    let (progress, c0_2) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        progress,
        &mut escrow,
        0,
        ctx,
    );
    let (progress, c1_2) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        progress,
        &mut escrow,
        1,
        ctx,
    );
    coin_escrow::finish_split_asset_progress(progress, &escrow);

    // Invariant should hold with accumulated values
    coin_escrow::assert_quantum_invariant(&escrow);
    assert!(coin_escrow::get_escrowed_asset_balance(&escrow) == 1500, 1);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1500, 2);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 1500, 3);

    coin::burn_for_testing(c0_1);
    coin::burn_for_testing(c1_1);
    coin::burn_for_testing(c0_2);
    coin::burn_for_testing(c1_2);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

// =============================================================================
// === SWAP TRACKING TESTS ===
// =============================================================================
// Tests for track_swap_stable_to_asset and track_swap_asset_to_stable functions
// These are critical for the per-outcome allocation model

#[test]
fun test_track_swap_stable_to_asset_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Set initial allocations: outcome 0 has 500 stable, 500 asset
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 500); // asset
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 500); // stable

    // Track swap: stable_in=200, asset_out=180 (simulating AMM swap with fees)
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 200, 180, &auth);

    // Verify: stable decreased by 200, asset increased by 180
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 300, 0); // 500 - 200
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 680, 1); // 500 + 180

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_track_swap_asset_to_stable_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Set initial allocations: outcome 0 has 1000 asset, 500 stable
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000); // asset
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 500); // stable

    // Track swap: asset_in=300, stable_out=290
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_asset_to_stable(&mut escrow, 0, 300, 290, &auth);

    // Verify: asset decreased by 300, stable increased by 290
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 700, 0); // 1000 - 300
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 790, 1); // 500 + 290

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_track_swap_zero_sum_within_outcome() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Set initial allocations: 1000 each
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 1000);

    let initial_total =
        coin_escrow::get_outcome_escrowed_asset(&escrow, 0) +
                        coin_escrow::get_outcome_escrowed_stable(&escrow, 0);
    assert!(initial_total == 2000, 0);

    // Track 1:1 swap (no fees for simplicity)
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 100, 100, &auth);

    // Total allocation should remain the same (zero-sum)
    let after_total =
        coin_escrow::get_outcome_escrowed_asset(&escrow, 0) +
                      coin_escrow::get_outcome_escrowed_stable(&escrow, 0);
    assert!(after_total == 2000, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_track_swap_multiple_consecutive() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Start with 500 each
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 500);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 500);

    // Swap 1: stable→asset (100 stable for 95 asset)
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 100, 95, &auth);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 400, 0);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 595, 1);

    // Swap 2: asset→stable (200 asset for 190 stable)
    coin_escrow::track_swap_asset_to_stable(&mut escrow, 0, 200, 190, &auth);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 395, 2);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 590, 3);

    // Swap 3: stable→asset again (50 stable for 48 asset)
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 50, 48, &auth);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 540, 4);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 443, 5);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_track_swap_different_outcomes_isolated() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Set initial allocations for both outcomes
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, true, 500);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, false, 500);

    // Swap only in outcome 0
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 200, 190, &auth);

    // Outcome 0 should change
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 800, 0);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1190, 1);

    // Outcome 1 should be UNCHANGED
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 1) == 500, 2);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 500, 3);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EAllocationUnderflow)]
fun test_track_swap_underflow_fails() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Set low stable allocation
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 100); // Only 100 stable

    // Try to swap 200 stable (more than allocated) - should fail
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 200, 180, &auth);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EAllocationUnderflow)]
fun test_track_swap_asset_underflow_fails() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Set low asset allocation
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 50); // Only 50 asset
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 1000);

    // Try to swap 100 asset (more than allocated) - should fail
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_asset_to_stable(&mut escrow, 0, 100, 95, &auth);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_track_swap_with_invariant_check() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit spot tokens
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let spot_stable = coin::mint_for_testing<TEST_COIN_B>(1000, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, spot_asset, spot_stable);

    // Mint conditionals
    let c_asset = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        1000,
        ctx,
    );
    let c_stable = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        1000,
        ctx,
    );

    // Set allocations to match supplies
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 1000);

    // Invariant should pass before swap
    coin_escrow::assert_quantum_invariant(&escrow);

    // Simulate swap effect on wrapped balances (in real flow, swap burns/mints)
    // For this test, we just track the allocation change
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 200, 200, &auth);

    // Update supplies to match (simulating burn stable, mint asset)
    coin_escrow::decrement_supply_for_testing(&mut escrow, 0, false, 200);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, true, 200);

    // Invariant should still pass after swap
    coin_escrow::assert_quantum_invariant(&escrow);

    coin::burn_for_testing(c_asset);
    coin::burn_for_testing(c_stable);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_track_swap_3_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 3 outcomes
    let market_state = create_test_market_state(3, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    let asset_cap_2 = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap_2 = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap_2, stable_cap_2);

    // Set allocations for all 3 outcomes
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, true, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, false, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 2, true, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 2, false, 1000);

    // Swap in outcome 1 only
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_asset_to_stable(&mut escrow, 1, 300, 280, &auth);

    // Verify outcome 1 changed
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 700, 0);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 1) == 1280, 1);

    // Verify outcomes 0 and 2 unchanged
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1000, 2);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 1000, 3);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 2) == 1000, 4);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 2) == 1000, 5);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// =============================================================================
// === SYSTEM SWAP (ARBITRAGE) TRACKING TESTS ===
// =============================================================================

#[test]
/// Verify track_system_swap_stable_to_asset shifts supply, OE, and pool_claim correctly.
fun test_track_system_swap_stable_to_asset_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);
    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Initial state: supply=1000, OE=1000, pool_claim=800 per type per outcome
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 1000);  // asset supply[0]
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 1000); // stable supply[0]
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 0, 800, 800);

    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_system_swap_stable_to_asset(&mut escrow, 0, 200, 180, &auth);

    // Supply: stable decreased, asset increased
    let (asset_supplies, stable_supplies) = coin_escrow::get_all_supplies(&escrow);
    assert!(asset_supplies[0] == 1180, 0); // 1000 + 180
    assert!(stable_supplies[0] == 800, 1); // 1000 - 200

    // OE: stable decreased, asset increased
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1180, 2); // 1000 + 180
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 800, 3); // 1000 - 200

    // Pool claim: stable decreased, asset increased
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 980, 4); // 800 + 180
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 600, 5); // 800 - 200

    // Outcome 1 unchanged
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 0, 6);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 1) == 0, 7);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Verify track_system_swap_asset_to_stable shifts all 3 layers correctly (mirror direction).
fun test_track_system_swap_asset_to_stable_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);
    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 500);
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 0, 800, 400);

    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_system_swap_asset_to_stable(&mut escrow, 0, 300, 280, &auth);

    // Supply: asset decreased, stable increased
    let (asset_supplies, stable_supplies) = coin_escrow::get_all_supplies(&escrow);
    assert!(asset_supplies[0] == 700, 0); // 1000 - 300
    assert!(stable_supplies[0] == 780, 1); // 500 + 280

    // OE: asset decreased, stable increased
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 700, 2);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 780, 3);

    // Pool claim: asset decreased, stable increased
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 500, 4); // 800 - 300
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 680, 5); // 400 + 280

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Pool claim must saturate to 0 when consumed exceeds current claim.
/// This happens when user swaps have shifted pool_claim below the arb input amount.
fun test_track_system_swap_pool_claim_saturating() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    // Pool claim is much smaller than what arb will consume
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 1000);
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 0, 50, 50); // only 50

    let auth = escrow_mutation_auth::create_for_testing();
    // Consume 200 stable (> pool_claim_stable of 50)
    coin_escrow::track_system_swap_stable_to_asset(&mut escrow, 0, 200, 180, &auth);

    // Pool claim stable saturates to 0 (not underflow)
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 0, 0); // max(50-200, 0)
    // Pool claim asset still increases
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 230, 1); // 50 + 180

    // Mirror: consume asset with low pool_claim
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 2000);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 2000);
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 0, 30, 500);
    coin_escrow::track_system_swap_asset_to_stable(&mut escrow, 0, 500, 480, &auth);

    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 0, 2); // max(30-500, 0)
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 980, 3); // 500 + 480

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 103)] // EAllocationUnderflow
/// track_system_swap must abort if supply is insufficient.
fun test_track_system_swap_supply_underflow_aborts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    // Only 100 stable supply but we try to consume 200
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 100);
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 0, 500, 50);

    let auth = escrow_mutation_auth::create_for_testing();
    // This should abort: stable_supply=100 < stable_consumed=200
    coin_escrow::track_system_swap_stable_to_asset(&mut escrow, 0, 200, 180, &auth);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Quantum invariant (OE == supply + wrapped) must hold after track_system_swap.
fun test_track_system_swap_preserves_quantum_invariant() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);
    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Set initial state with some wrapped balances
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 800);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 900);
    coin_escrow::set_supply_for_testing(&mut escrow, 1, true, 700);
    coin_escrow::set_supply_for_testing(&mut escrow, 1, false, 600);
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, true, 100);
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, false, 50);
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 1, true, 200);
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 1, false, 150);

    // Deposit enough real tokens
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(2000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(2000);
    coin_escrow::deposit_spot_liquidity(&mut escrow, asset_bal, stable_bal, &escrow_mutation_auth::create_for_testing());
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 0, 500, 500);
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 1, 400, 400);

    // Before: verify invariant holds
    coin_escrow::assert_quantum_invariant(&escrow);

    // Apply system swaps to both outcomes
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_system_swap_stable_to_asset(&mut escrow, 0, 100, 90, &auth);
    coin_escrow::track_system_swap_asset_to_stable(&mut escrow, 1, 150, 140, &auth);

    // After: invariant must still hold
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// =============================================================================
// === LP QUANTUM DEPOSIT TESTS ===
// =============================================================================

#[test]
fun test_lp_deposit_quantum_basic() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // LP quantum deposit
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(500);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &escrow_mutation_auth::create_for_testing());

    // Verify escrow balances
    let (escrowed_asset, escrowed_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(escrowed_asset == 1000, 0);
    assert!(escrowed_stable == 500, 1);

    // Verify supplies for ALL outcomes (quantum model)
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1000, 2);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 1000, 3);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 0) == 500, 4);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 1) == 500, 5);

    // Verify allocations for ALL outcomes
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1000, 6);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 1000, 7);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 500, 8);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 1) == 500, 9);

    // Verify LP backing tracked
    assert!(coin_escrow::get_lp_deposited_asset(&escrow) == 1000, 10);
    assert!(coin_escrow::get_lp_deposited_stable(&escrow) == 500, 11);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_lp_deposit_quantum_multiple_deposits() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // First deposit
    let asset_bal1 = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal1 = sui::balance::create_for_testing<TEST_COIN_B>(500);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal1, stable_bal1, &escrow_mutation_auth::create_for_testing());

    // Second deposit
    let asset_bal2 = sui::balance::create_for_testing<TEST_COIN_A>(500);
    let stable_bal2 = sui::balance::create_for_testing<TEST_COIN_B>(250);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal2, stable_bal2, &escrow_mutation_auth::create_for_testing());

    // Verify cumulative amounts
    let (escrowed_asset, escrowed_stable) = coin_escrow::get_spot_balances(&escrow);
    assert!(escrowed_asset == 1500, 0);
    assert!(escrowed_stable == 750, 1);

    // Verify supplies accumulated for all outcomes
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1500, 2);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 1500, 3);

    // Verify allocations accumulated
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1500, 4);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 1500, 5);

    // Verify LP backing accumulated
    assert!(coin_escrow::get_lp_deposited_asset(&escrow) == 1500, 6);
    assert!(coin_escrow::get_lp_deposited_stable(&escrow) == 750, 7);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_lp_deposit_quantum_invariant_holds() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // LP deposit
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(1000);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &escrow_mutation_auth::create_for_testing());

    // Quantum invariant should pass immediately after LP deposit
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_lp_deposit_quantum_asset_only() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit asset only (zero stable)
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(0);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &escrow_mutation_auth::create_for_testing());

    // Verify
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 1000, 0);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 0) == 0, 1);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1000, 2);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 0, 3);

    // Invariant should still hold
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// =============================================================================
// === SOLVENCY EDGE CASE TESTS ===
// =============================================================================

#[test]
fun test_solvency_with_type_mismatch_after_swaps() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Deposit equal amounts
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let spot_stable = coin::mint_for_testing<TEST_COIN_B>(500, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, spot_asset, spot_stable);

    // Mint supplies
    let c0_a = coin_escrow::mint_conditional_asset<TEST_COIN_A, TEST_COIN_B, COND_0_ASSET>(
        &mut escrow,
        0,
        500,
        ctx,
    );
    let c0_s = coin_escrow::mint_conditional_stable<TEST_COIN_A, TEST_COIN_B, COND_0_STABLE>(
        &mut escrow,
        0,
        500,
        ctx,
    );

    // Set allocations: after swaps, outcome 0 has 800 asset, 200 stable
    // Global escrow is 500/500 but total = 1000 matches allocation total = 1000
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 800);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 200);

    // Also set supplies to match
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 800);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 200);

    // Set pool_claim to original LP deposit amounts (500/500).
    // Swaps shifted allocation types but pool_claim stays constant.
    // user_claim_asset = 800 - 500 = 300, user_claim_stable = 200 - 500 = 0 (saturating)
    // solvency: 500 >= 300 ✓, 500 >= 0 ✓
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 0, 500, 500);

    // Finalize with outcome 0 winning
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Solvency check should PASS because:
    // user_claim_asset = 800 - 500 = 300, escrow_asset = 500 >= 300 ✓
    // user_claim_stable = 200 - 500 = 0, escrow_stable = 500 >= 0 ✓
    coin_escrow::assert_quantum_invariant(&escrow);

    coin::burn_for_testing(c0_a);
    coin::burn_for_testing(c0_s);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::ESolvencyViolation)]
fun test_solvency_insufficient_fails() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit only 500 total
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(300, ctx);
    let spot_stable = coin::mint_for_testing<TEST_COIN_B>(200, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, spot_asset, spot_stable);

    // Set allocations higher than escrow (simulating a bug or attack)
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 600);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 600);

    // Set supplies to match allocations
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 600);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 600);

    // Finalize
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Solvency check should FAIL:
    // effective_escrow = 300 + 200 = 500
    // winning_allocation = 600 + 600 = 1200
    // 500 < 1200 ✗
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_solvency_with_protocol_fees() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit 1000 total
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(500, ctx);
    let spot_stable = coin::mint_for_testing<TEST_COIN_B>(500, ctx);
    coin_escrow::deposit_spot_coins(&mut escrow, spot_asset, spot_stable);

    // Set allocations = 1000 total
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 500);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 500);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 500);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 500);

    // Simulate fee collection: 100 fees collected (escrow reduced)
    // In real swap operations, fees reduce allocations (burn amount_in > mint amount_out).
    // Here we simulate: reduce allocations by fee amount, then withdraw fees from escrow.
    let auth = escrow_mutation_auth::create_for_testing();

    // Simulate swap-driven allocation reduction (fees = amount_in - amount_out)
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 450);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 450);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 450);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 450);

    // Withdraw fees from escrow
    let withdrawn = coin_escrow::withdraw_asset_balance(&mut escrow, 50, ctx, &auth);
    coin::burn_for_testing(withdrawn);
    let withdrawn2 = coin_escrow::withdraw_stable_balance(&mut escrow, 50, ctx, &auth);
    coin::burn_for_testing(withdrawn2);
    coin_escrow::track_collected_protocol_fees(&mut escrow, 50, 50, &auth);

    // Finalize
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Solvency should PASS because:
    // actual_escrow = 450 + 450 = 900
    // allocation = 450 + 450 = 900 (reduced by fees during swap operations)
    // 900 >= 900 ✓
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// =============================================================================
// === SUPPLIES INCREMENT/DECREMENT TESTS ===
// =============================================================================

#[test]
fun test_increment_supplies_all_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Increment supplies for all outcomes
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, 100, 50, &auth);

    // Verify both outcomes got the increment
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 100, 0);
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 1) == 100, 1);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 0) == 50, 2);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 1) == 50, 3);

    // Verify allocations also incremented
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 100, 4);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 100, 5);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 50, 6);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 1) == 50, 7);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_increment_asset_only() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Increment only asset (stable_amount = 0)
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::increment_supplies_for_all_outcomes(&mut escrow, 500, 0, &auth);

    // Verify
    assert!(coin_escrow::get_outcome_asset_supply(&escrow, 0) == 500, 0);
    assert!(coin_escrow::get_outcome_stable_supply(&escrow, 0) == 0, 1);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 500, 2);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 0, 3);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// =============================================================================
// === CROSS-FUNCTION INTEGRATION TESTS ===
// =============================================================================

#[test]
fun test_deposit_split_swap_recombine_flow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Step 1: User deposits and splits 1000 asset
    let spot_asset = coin::mint_for_testing<TEST_COIN_A>(1000, ctx);
    let progress = coin_escrow::start_split_asset_progress(&mut escrow, spot_asset);
    let (progress, c0) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_0_ASSET,
    >(
        progress,
        &mut escrow,
        0,
        ctx,
    );
    let (progress, c1) = coin_escrow::split_asset_progress_step<
        TEST_COIN_A,
        TEST_COIN_B,
        COND_1_ASSET,
    >(
        progress,
        &mut escrow,
        1,
        ctx,
    );
    coin_escrow::finish_split_asset_progress(progress, &escrow);

    // Verify after split: allocations = 1000 for each outcome
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1000, 0);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 1000, 1);

    // Step 2: Simulate swap in outcome 0 (convert 200 asset allocation to stable)
    // This simulates: user wraps asset, swaps for stable in AMM
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_asset_to_stable(&mut escrow, 0, 200, 190, &auth);

    // Verify after swap: outcome 0 has less asset, more stable
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 800, 2);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 190, 3);
    // Outcome 1 unchanged
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 1000, 4);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 1) == 0, 5);

    // Clean up
    coin::burn_for_testing(c0);
    coin::burn_for_testing(c1);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_lp_deposit_user_swap_lp_withdraw_flow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow with 2 outcomes
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Step 1: LP deposits quantum
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(1000);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &escrow_mutation_auth::create_for_testing());

    // Verify invariant after LP deposit
    coin_escrow::assert_quantum_invariant(&escrow);

    // Step 2: User performs swap in outcome 0
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 300, 290, &auth);

    // Update supplies to reflect the swap (burn stable, mint asset in outcome 0)
    coin_escrow::decrement_supply_for_testing(&mut escrow, 0, false, 300);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, true, 290);

    // Verify invariant still holds after swap
    coin_escrow::assert_quantum_invariant(&escrow);

    // Step 3: Market finalizes with outcome 0 winning
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Step 4: LP withdraws (would normally be via lp_withdraw_quantum)
    // For this test, just verify solvency check passes
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
fun test_allocation_getter_consistency() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Setup escrow
    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Initially all allocations should be 0
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 0, 0);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 0, 1);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 0, 2);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 1) == 0, 3);

    // Set specific values
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 12345);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, true, 67890);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 11111);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, false, 22222);

    // Verify getters return exactly what was set
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 12345, 4);
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 1) == 67890, 5);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 11111, 6);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 1) == 22222, 7);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

// === Challenging Invariant Tests ===

#[test]
#[expected_failure(abort_code = coin_escrow::EAccountingInvariantViolation)]
/// Test that accounting invariant fails when LP tracking exceeds actual escrow balance.
/// This simulates a bug where lp_deposited is incremented without corresponding escrow deposit.
fun test_accounting_invariant_fails_when_tracking_exceeds_escrow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit only 100 to escrow
    coin_escrow::deposit_spot_liquidity_for_testing(&mut escrow, 100, 100);

    // Artificially set LP tracking to 200 (more than escrow balance of 100)
    // This simulates a bug where tracking gets out of sync with actual balance
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, 200, 200);

    // This should fail - lp_deposited (200) > escrow_balance (100)
    coin_escrow::assert_accounting_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Stress test: 100 swap cycles to verify no tracking drift in quantum invariant.
/// Each swap converts between asset and stable within the same outcome.
fun test_invariants_after_100_swap_cycles() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Initial deposit via lp_deposit_quantum
    let asset_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_A>(10000, ctx));
    let stable_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_B>(10000, ctx));
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &escrow_mutation_auth::create_for_testing());

    // Verify initial state
    coin_escrow::assert_all_invariants(&escrow);

    // Perform 100 swap cycles: asset->stable then stable->asset
    let auth = escrow_mutation_auth::create_for_testing();
    let mut i = 0;
    while (i < 100) {
        // Swap 50 asset to 48 stable in outcome 0 (simulates 4% fee/slippage)
        coin_escrow::track_swap_asset_to_stable(&mut escrow, 0, 50, 48, &auth);
        coin_escrow::decrement_supply_for_testing(&mut escrow, 0, true, 50);
        coin_escrow::increment_supply_for_outcome(&mut escrow, 0, false, 48);

        // Swap 48 stable back to 46 asset (another 4% fee/slippage)
        coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 48, 46, &auth);
        coin_escrow::decrement_supply_for_testing(&mut escrow, 0, false, 48);
        coin_escrow::increment_supply_for_outcome(&mut escrow, 0, true, 46);

        i = i + 1;
    };

    // After 100 cycles, invariants should still hold
    coin_escrow::assert_all_invariants(&escrow);

    // Verify LP tracking hasn't drifted
    let (lp_asset, lp_stable) = coin_escrow::get_lp_deposited_for_testing(&escrow);
    assert!(lp_asset == 10000, 0);
    assert!(lp_stable == 10000, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Test solvency passes when escrow type composition differs 100% from allocation.
/// Example: Escrow has 1000 asset + 0 stable, but winning outcome needs 500 asset + 500 stable.
/// Solvency checks total value, not per-type matching.
fun test_solvency_passes_with_100_percent_type_mismatch() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Deposit 1000 asset, 0 stable to escrow
    coin_escrow::deposit_spot_liquidity_for_testing(&mut escrow, 1000, 0);
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, 1000, 0);

    // Set outcome 0 allocation to 500 asset + 500 stable (total 1000)
    // This represents a scenario where swaps converted types
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 500);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 500);

    // Set supplies to match allocations
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 500);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 500);

    // Set pool_claim = allocation (100% LP scenario, no user claims)
    // Swaps shifted types but all allocation belongs to LP
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 0, 500, 500);

    // Finalize with outcome 0 winning
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Solvency should pass: user_claim = 500-500 / 500-500 = 0/0
    // escrow 1000 >= 0 ✓, escrow 0 >= 0 ✓
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Test accounting invariant with asymmetric deposit (only asset, no stable).
fun test_accounting_asymmetric_asset_only_deposit() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit only asset, no stable
    let asset_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_A>(1000, ctx));
    let stable_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_B>(0, ctx));
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::deposit_spot_liquidity(&mut escrow, asset_bal, stable_bal, &auth);

    // Verify accounting invariant passes with asymmetric deposit
    coin_escrow::assert_accounting_invariant(&escrow);

    // Verify LP tracking is correct
    let (lp_asset, lp_stable) = coin_escrow::get_lp_deposited_for_testing(&escrow);
    assert!(lp_asset == 1000, 0);
    assert!(lp_stable == 0, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::ENotEnoughLiquidity)]
/// Test that withdrawing more than LP deposited fails.
/// This prevents extraction of unbacked funds.
fun test_withdraw_more_than_lp_deposited_fails() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit 100 via LP deposit
    let asset_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_A>(100, ctx));
    let stable_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_B>(100, ctx));
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::deposit_spot_liquidity(&mut escrow, asset_bal, stable_bal, &auth);

    // Also deposit 100 more directly to escrow (not tracked as LP)
    coin_escrow::deposit_spot_liquidity_for_testing(&mut escrow, 100, 100);

    // Now escrow has 200, but LP tracking only shows 100
    // Try to decrement LP backing by 150 (more than the 100 tracked)
    // This should fail with ENotEnoughLiquidity
    coin_escrow::decrement_lp_backing(&mut escrow, 150, 150, &auth);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Test that losing outcome can have mismatched allocation after finalization.
/// Only winning outcome's invariant is checked post-finalization.
fun test_losing_outcome_allocation_mismatch_after_finalization() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Setup winning outcome 0 with valid allocation
    coin_escrow::deposit_spot_liquidity_for_testing(&mut escrow, 1000, 1000);
    coin_escrow::set_lp_deposited_for_testing(&mut escrow, 1000, 1000);

    // Set outcome 0 (will win) with matching allocation/supply
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 500);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 500);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 500);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 500);

    // Set outcome 1 (will lose) with MISMATCHED allocation/supply
    // This simulates partial burns on losing outcome
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, true, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 1, false, 1000);
    // But supply is only 500 (mismatch!)
    coin_escrow::set_supply_for_testing(&mut escrow, 1, true, 500);
    coin_escrow::set_supply_for_testing(&mut escrow, 1, false, 500);

    // Finalize with outcome 0 winning
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Quantum invariant should PASS because only winning outcome is checked
    // Losing outcome's mismatch is ignored post-finalization
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Test invariants with 3 outcomes and different allocation patterns.
fun test_invariants_3_outcomes_different_allocations() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(3, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    let asset_cap_2 = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap_2 = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap_2, stable_cap_2);

    // Initial quantum deposit
    let asset_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_A>(3000, ctx));
    let stable_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_B>(3000, ctx));
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &escrow_mutation_auth::create_for_testing());

    // Perform different swaps on each outcome to create varied allocations
    // Outcome 0: swap 500 asset to stable
    let auth = escrow_mutation_auth::create_for_testing();
    coin_escrow::track_swap_asset_to_stable(&mut escrow, 0, 500, 480, &auth);
    coin_escrow::decrement_supply_for_testing(&mut escrow, 0, true, 500);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, false, 480);

    // Outcome 1: swap 1000 stable to asset
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 1, 1000, 950, &auth);
    coin_escrow::decrement_supply_for_testing(&mut escrow, 1, false, 1000);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 1, true, 950);

    // Outcome 2: no swaps (balanced allocation)

    // Verify all invariants hold with different allocation patterns
    coin_escrow::assert_all_invariants(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Test solvency with large accumulated protocol fees.
/// Verifies that collected fees are included in effective escrow total.
fun test_solvency_with_large_accumulated_fees() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // Deposit 1000 total
    let asset_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_A>(500, ctx));
    let stable_bal = coin::into_balance(coin::mint_for_testing<TEST_COIN_B>(500, ctx));
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &escrow_mutation_auth::create_for_testing());

    // Simulate fee collection: 200 asset fees collected (withdrawn from escrow)
    // In real swap operations, fees reduce allocations (burn amount_in > mint amount_out).
    let auth = escrow_mutation_auth::create_for_testing();

    // Simulate swap-driven allocation reduction (fees = 200 asset)
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 300);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 300);

    // Withdraw fees from escrow
    let fee_asset = coin_escrow::withdraw_asset_balance(&mut escrow, 200, ctx, &auth);
    coin_escrow::track_collected_protocol_fees(&mut escrow, 200, 0, &auth);

    // Now escrow has 300 asset + 500 stable = 800
    // Allocation is 300 asset + 500 stable = 800 (reduced by fees during swap operations)

    // Finalize
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Solvency passes: 800 >= 800 ✓
    coin_escrow::assert_quantum_invariant(&escrow);

    coin::burn_for_testing(fee_asset);
    test_utils::destroy(escrow);
    ts::end(scenario);
}

// =============================================================================
// === POOL CLAIM (DUAL-LEDGER) LIFECYCLE TESTS ===
// =============================================================================

#[test]
/// Pool claim is set during quantum split and matches outcome_escrowed initially.
fun test_pool_claim_set_at_quantum_split() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Initially pool_claim should be 0
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 0, 0);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 0, 1);
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 1) == 0, 2);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 1) == 0, 3);

    // LP quantum deposit
    let auth = escrow_mutation_auth::create_for_testing();
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(500);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &auth);

    // After quantum split, pool_claim == outcome_escrowed for ALL outcomes
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 1000, 4);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 500, 5);
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 1) == 1000, 6);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 1) == 500, 7);

    // pool_claim should match outcome_escrowed at this point
    assert!(
        coin_escrow::get_pool_claim_asset(&escrow, 0) ==
        coin_escrow::get_outcome_escrowed_asset(&escrow, 0),
        8,
    );
    assert!(
        coin_escrow::get_pool_claim_stable(&escrow, 0) ==
        coin_escrow::get_outcome_escrowed_stable(&escrow, 0),
        9,
    );

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Pool claim stays constant during trading (track_swap does NOT touch it).
fun test_pool_claim_constant_during_swaps() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // LP quantum deposit
    let auth = escrow_mutation_auth::create_for_testing();
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(1000);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &auth);

    // Perform swaps in outcome 0
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 300, 290, &auth);
    coin_escrow::decrement_supply_for_testing(&mut escrow, 0, false, 300);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, true, 290);

    // outcome_escrowed changed (now 1290 asset, 700 stable for outcome 0)
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1290, 0);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 700, 1);

    // But pool_claim stayed constant at original deposit amounts
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 1000, 2);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 1000, 3);

    // Outcome 1 unchanged
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 1) == 1000, 4);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 1) == 1000, 5);

    // user_claim = OE - pool_claim: 1290 - 1000 = 290 asset, 700 - 1000 = 0 stable
    // solvency: escrow 1000 >= 290 ✓, escrow 1000 >= 0 ✓
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Pool claim is decremented during LP unwind via decrement_pool_claim.
fun test_pool_claim_decremented_at_unwind() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // LP quantum deposit
    let auth = escrow_mutation_auth::create_for_testing();
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(1000);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &auth);

    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 1000, 0);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 1000, 1);

    // Simulate LP unwind: decrement pool_claim for outcome 0
    coin_escrow::decrement_pool_claim(&mut escrow, 0, 600, 400, &auth);

    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 400, 2);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 600, 3);

    // Outcome 1 unchanged
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 1) == 1000, 4);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 1) == 1000, 5);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Decrementing pool_claim beyond current value saturates at 0.
fun test_pool_claim_saturating_decrement() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(1, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap, stable_cap);

    // LP quantum deposit 500/500
    let auth = escrow_mutation_auth::create_for_testing();
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(500);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(500);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &auth);

    // Decrement more than pool_claim → saturates at 0
    coin_escrow::decrement_pool_claim(&mut escrow, 0, 600, 500, &auth);

    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 0, 0);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 0, 1);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Full lifecycle: quantum split → swaps → finalize → solvency passes.
/// Demonstrates that pool_claim makes solvency immune to type shifts from trading.
fun test_pool_claim_full_lifecycle_with_solvency() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Step 1: LP quantum deposit
    let auth = escrow_mutation_auth::create_for_testing();
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(1000);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &auth);

    // Invariant holds after deposit
    coin_escrow::assert_quantum_invariant(&escrow);

    // Step 2: Multiple swaps shift types heavily
    // Swap 1: 500 stable → 480 asset in outcome 0
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 500, 480, &auth);
    coin_escrow::decrement_supply_for_testing(&mut escrow, 0, false, 500);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, true, 480);

    // Swap 2: 200 stable → 190 asset in outcome 0
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 200, 190, &auth);
    coin_escrow::decrement_supply_for_testing(&mut escrow, 0, false, 200);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, true, 190);

    // outcome 0 now: 1670 asset, 300 stable (heavily asset-skewed)
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1670, 0);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 300, 1);

    // pool_claim unchanged at 1000/1000
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 1000, 2);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 1000, 3);

    // Invariant holds during active trading
    coin_escrow::assert_quantum_invariant(&escrow);

    // Step 3: Finalize with outcome 0 winning
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // Step 4: Solvency check with dual-ledger
    // user_claim_asset = 1670 - 1000 = 670, user_claim_stable = 300 - 1000 = 0
    // escrow: 1000 asset >= 670 ✓, 1000 stable >= 0 ✓
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Pool claim stays constant during asset→stable swaps (reverse direction).
fun test_pool_claim_constant_during_asset_to_stable_swaps() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // LP quantum deposit
    let auth = escrow_mutation_auth::create_for_testing();
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(1000);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &auth);

    // Perform asset→stable swap in outcome 0
    coin_escrow::track_swap_asset_to_stable(&mut escrow, 0, 400, 390, &auth);
    coin_escrow::decrement_supply_for_testing(&mut escrow, 0, true, 400);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, false, 390);

    // outcome_escrowed changed (now 600 asset, 1390 stable for outcome 0)
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 600, 0);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 1390, 1);

    // pool_claim stayed constant at original deposit amounts
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 1000, 2);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 1000, 3);

    // Invariant holds during trading
    coin_escrow::assert_quantum_invariant(&escrow);

    // Finalize with outcome 0 winning
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // user_claim_asset = 600 - 1000 = 0 (saturating), user_claim_stable = 1390 - 1000 = 390
    // solvency: 1000 >= 0 ✓, 1000 >= 390 ✓
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::ESolvencyViolation)]
/// Solvency correctly fails when user claims genuinely exceed escrow,
/// even with pool_claim set. pool_claim only exempts the LP portion.
fun test_solvency_fails_with_pool_claim_when_user_claims_exceed_escrow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Escrow: 500 asset, 200 stable
    coin_escrow::deposit_spot_liquidity_for_testing(&mut escrow, 500, 200);

    // Outcome 0 allocation: 1000 asset, 800 stable (after LP + user deposits + swaps)
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_outcome_escrowed_for_testing(&mut escrow, 0, false, 800);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, true, 1000);
    coin_escrow::set_supply_for_testing(&mut escrow, 0, false, 800);

    // LP portion (pool_claim): 400 asset, 400 stable
    coin_escrow::set_pool_claim_for_testing(&mut escrow, 0, 400, 400);

    // user_claim_asset = 1000 - 400 = 600, user_claim_stable = 800 - 400 = 400
    // solvency: 500 >= 600? NO → should fail
    let auth = escrow_mutation_auth::create_for_testing();
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Mixed user + LP deposits: user_claim = OE - pool_claim correctly reflects
/// only the user portion. LP's pool_claim is immune to type shifts from swaps.
fun test_mixed_user_and_lp_deposits_solvency() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    // Step 1: LP quantum deposit 800/800
    let auth = escrow_mutation_auth::create_for_testing();
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(800);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(800);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &auth);

    // pool_claim = 800/800 for each outcome
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 800, 0);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 800, 1);

    // Step 2: Simulate user deposit of 200/200 into all outcomes
    // (In real flow this happens via split progress; here we use test helpers)
    coin_escrow::deposit_spot_liquidity_for_testing(&mut escrow, 200, 200);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, true, 200);
    coin_escrow::increment_escrowed_for_testing(&mut escrow, 0, true, 200);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, false, 200);
    coin_escrow::increment_escrowed_for_testing(&mut escrow, 0, false, 200);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 1, true, 200);
    coin_escrow::increment_escrowed_for_testing(&mut escrow, 1, true, 200);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 1, false, 200);
    coin_escrow::increment_escrowed_for_testing(&mut escrow, 1, false, 200);

    // Now: escrow = 1000/1000, OE[0] = 1000/1000, pool_claim[0] = 800/800
    // user_claim[0] = 200/200

    // Step 3: Swaps shift outcome 0 types heavily (500 stable → 480 asset)
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 500, 480, &auth);
    coin_escrow::decrement_supply_for_testing(&mut escrow, 0, false, 500);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, true, 480);

    // After swap: OE[0] = 1480/500, pool_claim[0] = 800/800 (unchanged)
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1480, 2);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 500, 3);
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 800, 4);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 800, 5);

    // Invariant holds during trading
    coin_escrow::assert_quantum_invariant(&escrow);

    // Step 4: Finalize with outcome 0 winning
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);

    // user_claim_asset = 1480 - 800 = 680, user_claim_stable = 500 - 800 = 0 (saturating)
    // solvency: 1000 >= 680 ✓, 1000 >= 0 ✓
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// Multiple quantum deposits accumulate pool_claim correctly.
fun test_multiple_quantum_deposits_accumulate_pool_claim() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(2, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    let auth = escrow_mutation_auth::create_for_testing();

    // First quantum deposit: 500/300
    let asset_bal1 = sui::balance::create_for_testing<TEST_COIN_A>(500);
    let stable_bal1 = sui::balance::create_for_testing<TEST_COIN_B>(300);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal1, stable_bal1, &auth);

    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 500, 0);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 300, 1);

    // Second quantum deposit: 700/400
    let asset_bal2 = sui::balance::create_for_testing<TEST_COIN_A>(700);
    let stable_bal2 = sui::balance::create_for_testing<TEST_COIN_B>(400);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal2, stable_bal2, &auth);

    // pool_claim accumulated: 500+700=1200 / 300+400=700
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 1200, 2);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 700, 3);
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 1) == 1200, 4);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 1) == 700, 5);

    // OE should also have accumulated
    assert!(coin_escrow::get_outcome_escrowed_asset(&escrow, 0) == 1200, 6);
    assert!(coin_escrow::get_outcome_escrowed_stable(&escrow, 0) == 700, 7);

    // Invariant holds
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}

#[test]
/// 3-outcome scenario: pool_claim set for all outcomes, swaps in different
/// outcomes with different directions, solvency holds after finalization.
fun test_pool_claim_three_outcomes() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let market_state = create_test_market_state(3, ctx);
    let mut escrow = coin_escrow::new<TEST_COIN_A, TEST_COIN_B>(market_state, ctx);

    let asset_cap_0 = create_blank_treasury_cap_for_testing<COND_0_ASSET>(ctx);
    let stable_cap_0 = create_blank_treasury_cap_for_testing<COND_0_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 0, asset_cap_0, stable_cap_0);

    let asset_cap_1 = create_blank_treasury_cap_for_testing<COND_1_ASSET>(ctx);
    let stable_cap_1 = create_blank_treasury_cap_for_testing<COND_1_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 1, asset_cap_1, stable_cap_1);

    let asset_cap_2 = create_blank_treasury_cap_for_testing<COND_2_ASSET>(ctx);
    let stable_cap_2 = create_blank_treasury_cap_for_testing<COND_2_STABLE>(ctx);
    coin_escrow::register_conditional_caps(&mut escrow, 2, asset_cap_2, stable_cap_2);

    // LP quantum deposit
    let auth = escrow_mutation_auth::create_for_testing();
    let asset_bal = sui::balance::create_for_testing<TEST_COIN_A>(1000);
    let stable_bal = sui::balance::create_for_testing<TEST_COIN_B>(1000);
    coin_escrow::lp_deposit_quantum(&mut escrow, asset_bal, stable_bal, &auth);

    // pool_claim set for all 3 outcomes
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 1000, 0);
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 1) == 1000, 1);
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 2) == 1000, 2);

    // Swaps in different outcomes, different directions
    // Outcome 0: stable→asset (heavy)
    coin_escrow::track_swap_stable_to_asset(&mut escrow, 0, 600, 580, &auth);
    coin_escrow::decrement_supply_for_testing(&mut escrow, 0, false, 600);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 0, true, 580);

    // Outcome 1: asset→stable (moderate)
    coin_escrow::track_swap_asset_to_stable(&mut escrow, 1, 300, 290, &auth);
    coin_escrow::decrement_supply_for_testing(&mut escrow, 1, true, 300);
    coin_escrow::increment_supply_for_outcome(&mut escrow, 1, false, 290);

    // Outcome 2: no swaps (stays balanced)

    // pool_claim unchanged for all outcomes
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 0) == 1000, 3);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 0) == 1000, 4);
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 1) == 1000, 5);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 1) == 1000, 6);
    assert!(coin_escrow::get_pool_claim_asset(&escrow, 2) == 1000, 7);
    assert!(coin_escrow::get_pool_claim_stable(&escrow, 2) == 1000, 8);

    // Invariant holds during trading
    coin_escrow::assert_quantum_invariant(&escrow);

    // Finalize with outcome 1 winning (the one with asset→stable swap)
    let ms = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(ms);
    market_state::test_set_winning_outcome(ms, 1);

    // outcome 1: OE = 700 asset, 1290 stable; pool_claim = 1000/1000
    // user_claim_asset = 700 - 1000 = 0, user_claim_stable = 1290 - 1000 = 290
    // solvency: 1000 >= 0 ✓, 1000 >= 290 ✓
    coin_escrow::assert_quantum_invariant(&escrow);

    test_utils::destroy(escrow);
    ts::end(scenario);
}
