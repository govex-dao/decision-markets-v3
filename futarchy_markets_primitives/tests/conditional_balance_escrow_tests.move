#[test_only]
module futarchy_markets_primitives::conditional_balance_escrow_tests;

use futarchy_markets_primitives::coin_escrow;
use futarchy_markets_primitives::conditional_0::{Self, CONDITIONAL_0};
use futarchy_markets_primitives::conditional_1::{Self, CONDITIONAL_1};
use futarchy_markets_primitives::conditional_2::{Self, CONDITIONAL_2};
use futarchy_markets_primitives::conditional_3::{Self, CONDITIONAL_3};
use futarchy_markets_primitives::conditional_balance;
use futarchy_markets_primitives::market_state;
use sui::coin::{Self, TreasuryCap};
use sui::coin_registry::{Self, MetadataCap};
use sui::object;
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::destroy;

// Test coin types
public struct USDC has drop {}

const ADMIN: address = @0xAD;

// === Test Helpers ===

fun start(): ts::Scenario {
    ts::begin(ADMIN)
}

fun end(scenario: ts::Scenario) {
    let effects = ts::end(scenario);
    destroy(effects);
}

// === Setup Helper ===

/// Creates escrow and registers conditional caps for 2-outcome market
/// Returns (market_id, escrow)
fun setup_escrow_with_caps(scenario: &mut ts::Scenario): (ID, coin_escrow::TokenEscrow<SUI, USDC>) {
    // Switch to @0x0 to create CoinRegistry (required by create_coin_data_registry_for_testing)
    ts::next_tx(scenario, @0x0);

    // Create CoinRegistry for testing
    let mut coin_registry = coin_registry::create_coin_data_registry_for_testing(ts::ctx(scenario));

    // Initialize conditional coin types (creates TreasuryCaps and transfers to sender @0x0)
    // conditional_0 = outcome 0 asset, conditional_1 = outcome 0 stable
    // conditional_2 = outcome 1 asset, conditional_3 = outcome 1 stable
    conditional_0::init_for_testing(&mut coin_registry, ts::ctx(scenario));
    conditional_1::init_for_testing(&mut coin_registry, ts::ctx(scenario));
    conditional_2::init_for_testing(&mut coin_registry, ts::ctx(scenario));
    conditional_3::init_for_testing(&mut coin_registry, ts::ctx(scenario));

    // Destroy registry (not needed after coin creation)
    destroy(coin_registry);

    // Advance transaction to retrieve created objects (switching to @0x0 where caps were transferred)
    ts::next_tx(scenario, @0x0);

    // Take TreasuryCaps and MetadataCaps from sender
    let cond0_asset_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(scenario);
    let cond0_asset_metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(scenario);
    let cond0_stable_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_1>>(scenario);
    let cond0_stable_metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_1>>(scenario);
    let cond1_asset_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_2>>(scenario);
    let cond1_asset_metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_2>>(scenario);
    let cond1_stable_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_3>>(scenario);
    let cond1_stable_metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_3>>(scenario);

    // Create market state for 2 outcomes
    let market_state = market_state::create_for_testing(2, ts::ctx(scenario));
    let market_id = market_state::market_id(&market_state);

    // Create escrow (consumes market_state)
    let mut escrow = coin_escrow::new<SUI, USDC>(market_state, ts::ctx(scenario));

    // Register conditional caps for outcome 0
    coin_escrow::register_conditional_caps<SUI, USDC, CONDITIONAL_0, CONDITIONAL_1>(
        &mut escrow,
        0,
        cond0_asset_cap,
        cond0_stable_cap,
    );

    // Register conditional caps for outcome 1
    coin_escrow::register_conditional_caps<SUI, USDC, CONDITIONAL_2, CONDITIONAL_3>(
        &mut escrow,
        1,
        cond1_asset_cap,
        cond1_stable_cap,
    );

    // Destroy MetadataCaps (not needed for these tests)
    destroy(cond0_asset_metadata_cap);
    destroy(cond0_stable_metadata_cap);
    destroy(cond1_asset_metadata_cap);
    destroy(cond1_stable_metadata_cap);

    (market_id, escrow)
}

// === unwrap_to_coin Tests ===

#[test]
fun test_unwrap_to_coin_basic() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance and set some amount
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 0, true, 1000);
    // Set wrapped balance tracking to match
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, true, 1000);

    // Unwrap to coin
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        0,
        true,
        1000, // amount to unwrap
        ts::ctx(&mut scenario),
    );

    // Verify coin amount
    assert!(coin.value() == 1000, 0);

    // Verify balance is now zero
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 1);

    // Cleanup
    coin::burn_for_testing(coin);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
fun test_unwrap_to_coin_stable() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with stable balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 1, false, 5000);
    // Set wrapped balance tracking to match
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 1, false, 5000);

    // Unwrap stable coin
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_3>(
        &mut balance,
        &mut escrow,
        1,
        false,
        5000, // amount to unwrap
        ts::ctx(&mut scenario),
    );

    // Verify
    assert!(coin.value() == 5000, 0);
    assert!(conditional_balance::get_balance(&mut balance, 1, false) == 0, 1);

    // Cleanup
    coin::burn_for_testing(coin);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EProposalMismatch)]
fun test_unwrap_wrong_market_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance for DIFFERENT market
    let wrong_market_id = object::id_from_address(@0x9999);
    let mut balance = conditional_balance::new<SUI, USDC>(
        wrong_market_id,
        2,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 0, true, 1000);

    // Try to unwrap - should fail with EProposalMismatch
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        0,
        true,
        1000, // amount to unwrap
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    coin::burn_for_testing(coin);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EOutcomeNotRegistered)]
fun test_unwrap_unregistered_outcome_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with 3 outcomes (but escrow only has 2 registered)
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        3,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 2, true, 1000);

    // Try to unwrap outcome 2 - should fail (only 0 and 1 registered)
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        2, // Unregistered outcome
        true,
        1000, // amount to unwrap
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    coin::burn_for_testing(coin);
    conditional_balance::set_balance(&mut balance, 2, true, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInsufficientBalance)]
fun test_unwrap_zero_balance_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with zero balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Balance is 0, unwrap should fail (trying to unwrap 1 from 0 balance)
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        0,
        true,
        1, // any non-zero amount should fail since balance is 0
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    coin::burn_for_testing(coin);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

// === wrap_coin Tests ===

#[test]
fun test_wrap_coin_basic() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with some amount
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );
    conditional_balance::set_balance(&mut balance, 0, true, 2000);
    // Set wrapped balance tracking to match
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, true, 2000);

    // Unwrap to get a properly minted coin
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        0,
        true,
        2000, // amount to unwrap
        ts::ctx(&mut scenario),
    );

    // Balance should now be zero
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 0);

    // Wrap coin back into balance
    conditional_balance::wrap_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        coin,
        0,
        true,
    );

    // Verify balance increased back to original
    assert!(conditional_balance::get_balance(&balance, 0, true) == 2000, 1);

    // Cleanup
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
fun test_wrap_coin_accumulates() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance with existing amount
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Start with 1000 (but we'll unwrap 500, so set wrapped to 500)
    conditional_balance::set_balance(&mut balance, 0, false, 500);
    // Set wrapped balance tracking to match what we'll unwrap
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, false, 500);

    // Unwrap 500 to get a properly minted coin
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_1>(
        &mut balance,
        &mut escrow,
        0,
        false,
        500, // amount to unwrap
        ts::ctx(&mut scenario),
    );

    // After unwrap, balance should be 0, set it back to 1000
    // wrapped_balance is now 0 after unwrap
    conditional_balance::set_balance(&mut balance, 0, false, 1000);
    // Set wrapped balance to 1000 so after wrap of 500, total is 1500
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, false, 1000);

    // Wrap coin - should add to existing balance
    conditional_balance::wrap_coin<SUI, USDC, CONDITIONAL_1>(
        &mut balance,
        &mut escrow,
        coin,
        0,
        false,
    );

    // Verify accumulated (1000 + 500 = 1500)
    assert!(conditional_balance::get_balance(&balance, 0, false) == 1500, 1);

    // Cleanup
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EProposalMismatch)]
fun test_wrap_coin_wrong_market_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance for DIFFERENT market
    let wrong_market_id = object::id_from_address(@0x9999);
    let mut balance = conditional_balance::new<SUI, USDC>(
        wrong_market_id,
        2,
        ts::ctx(&mut scenario),
    );

    let coin = coin::mint_for_testing<CONDITIONAL_0>(1000, ts::ctx(&mut scenario));

    // Try to wrap - should fail with EProposalMismatch
    conditional_balance::wrap_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        coin,
        0,
        true,
    );

    // Cleanup (won't reach here)
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidBalanceAccess)]
fun test_wrap_coin_zero_amount_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Create zero-value coin
    let coin = coin::mint_for_testing<CONDITIONAL_2>(0, ts::ctx(&mut scenario));

    // Try to wrap zero coin - should fail
    conditional_balance::wrap_coin<SUI, USDC, CONDITIONAL_2>(
        &mut balance,
        &mut escrow,
        coin,
        1,
        true,
    );

    // Cleanup (won't reach here)
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

// === Roundtrip Test ===

#[test]
fun test_unwrap_wrap_roundtrip() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);
    // market_id already available

    // Create balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Set initial balance
    conditional_balance::set_balance(&mut balance, 0, true, 3000);
    // Set wrapped balance tracking to match
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, true, 3000);

    // Unwrap to coin
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        0,
        true,
        3000, // amount to unwrap
        ts::ctx(&mut scenario),
    );

    // Verify balance is now zero
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 0);
    assert!(coin.value() == 3000, 1);

    // Wrap it back
    conditional_balance::wrap_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        coin,
        0,
        true,
    );

    // Verify back to original amount
    assert!(conditional_balance::get_balance(&balance, 0, true) == 3000, 2);

    // Cleanup
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
/// Test partial unwrap - unwrap only part of the balance, leaving the rest
fun test_partial_unwrap_to_coin() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance with 5000
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 0, true, 5000);
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, true, 5000);

    // Unwrap only 2000 (partial)
    let coin1 = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        0,
        true,
        2000, // partial amount
        ts::ctx(&mut scenario),
    );

    // Verify coin amount
    assert!(coin1.value() == 2000, 0);

    // Verify balance has 3000 remaining
    assert!(conditional_balance::get_balance(&balance, 0, true) == 3000, 1);

    // Unwrap another 1500
    let coin2 = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        0,
        true,
        1500, // another partial amount
        ts::ctx(&mut scenario),
    );

    assert!(coin2.value() == 1500, 2);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 1500, 3);

    // Unwrap the rest
    let coin3 = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        0,
        true,
        1500, // remaining amount
        ts::ctx(&mut scenario),
    );

    assert!(coin3.value() == 1500, 4);
    assert!(conditional_balance::get_balance(&balance, 0, true) == 0, 5);

    // Cleanup
    coin::burn_for_testing(coin1);
    coin::burn_for_testing(coin2);
    coin::burn_for_testing(coin3);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInsufficientBalance)]
/// Test that trying to unwrap more than available fails
fun test_partial_unwrap_exceeds_balance_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    conditional_balance::set_balance(&mut balance, 0, true, 1000);
    coin_escrow::set_wrapped_balance_for_testing(&mut escrow, 0, true, 1000);

    // Try to unwrap 2000 from a balance of 1000 - should fail
    let coin = conditional_balance::unwrap_to_coin<SUI, USDC, CONDITIONAL_0>(
        &mut balance,
        &mut escrow,
        0,
        true,
        2000, // more than available
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    coin::burn_for_testing(coin);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

// === Atomic Balance Operation Tests ===

#[test]
fun test_split_stable_to_balance_basic() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Create stable coin to split
    let stable_coin = coin::mint_for_testing<USDC>(5000, ts::ctx(&mut scenario));

    // Use atomic split_stable_to_balance (single call for all outcomes!)
    let amount = conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    // Verify amount returned
    assert!(amount == 5000, 0);

    // Verify balance updated for BOTH outcomes (quantum model)
    assert!(conditional_balance::get_balance(&balance, 0, false) == 5000, 1);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 5000, 2);

    // Verify escrow state
    let (_, stable_bal) = coin_escrow::get_spot_balances(&escrow);
    assert!(stable_bal == 5000, 3);

    // Cleanup
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
fun test_split_asset_to_balance_basic() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Create asset coin to split
    let asset_coin = coin::mint_for_testing<SUI>(3000, ts::ctx(&mut scenario));

    // Use atomic split_asset_to_balance
    let amount = conditional_balance::split_asset_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        asset_coin,
    );

    // Verify amount returned
    assert!(amount == 3000, 0);

    // Verify balance updated for BOTH outcomes
    assert!(conditional_balance::get_balance(&balance, 0, true) == 3000, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 3000, 2);

    // Verify escrow state
    let (asset_bal, _) = coin_escrow::get_spot_balances(&escrow);
    assert!(asset_bal == 3000, 3);

    // Cleanup
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
fun test_recombine_balance_to_stable_basic() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // First split to get balances
    let stable_coin = coin::mint_for_testing<USDC>(4000, ts::ctx(&mut scenario));
    conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    // Verify initial state
    assert!(conditional_balance::get_balance(&balance, 0, false) == 4000, 0);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 4000, 1);

    // Recombine 2000 back to spot
    let recombined = conditional_balance::recombine_balance_to_stable<SUI, USDC>(
        &mut escrow,
        &mut balance,
        2000,
        ts::ctx(&mut scenario),
    );

    // Verify recombined amount
    assert!(recombined.value() == 2000, 2);

    // Verify balance decreased for BOTH outcomes
    assert!(conditional_balance::get_balance(&balance, 0, false) == 2000, 3);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 2000, 4);

    // Cleanup
    coin::burn_for_testing(recombined);
    conditional_balance::set_balance(&mut balance, 0, false, 0);
    conditional_balance::set_balance(&mut balance, 1, false, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
fun test_recombine_balance_to_asset_basic() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // First split to get balances
    let asset_coin = coin::mint_for_testing<SUI>(6000, ts::ctx(&mut scenario));
    conditional_balance::split_asset_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        asset_coin,
    );

    // Recombine 3000 back to spot
    let recombined = conditional_balance::recombine_balance_to_asset<SUI, USDC>(
        &mut escrow,
        &mut balance,
        3000,
        ts::ctx(&mut scenario),
    );

    // Verify recombined amount
    assert!(recombined.value() == 3000, 0);

    // Verify balance decreased for BOTH outcomes
    assert!(conditional_balance::get_balance(&balance, 0, true) == 3000, 1);
    assert!(conditional_balance::get_balance(&balance, 1, true) == 3000, 2);

    // Cleanup
    coin::burn_for_testing(recombined);
    conditional_balance::set_balance(&mut balance, 0, true, 0);
    conditional_balance::set_balance(&mut balance, 1, true, 0);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
fun test_atomic_split_recombine_roundtrip() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Split 10000 stable
    let stable_coin = coin::mint_for_testing<USDC>(10000, ts::ctx(&mut scenario));
    conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    // Verify full amount in both outcomes
    assert!(conditional_balance::get_balance(&balance, 0, false) == 10000, 0);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 10000, 1);

    // Recombine full amount back
    let recombined = conditional_balance::recombine_balance_to_stable<SUI, USDC>(
        &mut escrow,
        &mut balance,
        10000,
        ts::ctx(&mut scenario),
    );

    // Verify full amount returned
    assert!(recombined.value() == 10000, 2);

    // Verify balance is now zero for both outcomes
    assert!(conditional_balance::get_balance(&balance, 0, false) == 0, 3);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 0, 4);

    // Cleanup
    coin::burn_for_testing(recombined);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = coin_escrow::EAllocationUnderflow)]
fun test_recombine_insufficient_balance_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance
    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Split 1000 stable
    let stable_coin = coin::mint_for_testing<USDC>(1000, ts::ctx(&mut scenario));
    conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    // Try to recombine more than available - should fail
    let recombined = conditional_balance::recombine_balance_to_stable<SUI, USDC>(
        &mut escrow,
        &mut balance,
        2000, // More than 1000 available
        ts::ctx(&mut scenario),
    );

    // Won't reach here
    coin::burn_for_testing(recombined);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EWrongMarket)]
fun test_split_wrong_market_fails() {
    let mut scenario = start();

    let (_market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    // Create balance for DIFFERENT market
    let wrong_market_id = object::id_from_address(@0x9999);
    let mut balance = conditional_balance::new<SUI, USDC>(
        wrong_market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Try to split - should fail with wrong market
    let stable_coin = coin::mint_for_testing<USDC>(1000, ts::ctx(&mut scenario));
    conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    // Won't reach here
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
/// Verify that atomic split only increments wrapped, NOT supply.
/// This is critical: atomic functions go directly to balance form, bypassing typed coins.
fun test_atomic_split_supply_remains_zero() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Split 1000 stable to balance
    let stable_coin = coin::mint_for_testing<USDC>(1000, ts::ctx(&mut scenario));
    conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    // Verify balance is updated
    assert!(conditional_balance::get_balance(&balance, 0, false) == 1000);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 1000);

    // CRITICAL: Verify supply is still 0 (atomic functions don't touch supply)
    let (asset_supplies, stable_supplies) = coin_escrow::get_all_supplies(&escrow);
    assert!(asset_supplies[0] == 0, 0);
    assert!(asset_supplies[1] == 0, 0);
    assert!(stable_supplies[0] == 0, 0);
    assert!(stable_supplies[1] == 0, 0);

    // Verify wrapped balance is incremented
    let (wrapped_asset, wrapped_stable) = coin_escrow::get_wrapped_balances(&escrow);
    assert!(wrapped_asset[0] == 0, 0);
    assert!(wrapped_asset[1] == 0, 0);
    assert!(wrapped_stable[0] == 1000, 0);
    assert!(wrapped_stable[1] == 1000, 0);

    // Cleanup: recombine to get back the stable
    let recombined = conditional_balance::recombine_balance_to_stable<SUI, USDC>(
        &mut escrow,
        &mut balance,
        1000,
        ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(recombined);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
/// Verify that atomic recombine only decrements wrapped, NOT supply.
fun test_atomic_recombine_supply_remains_zero() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Split and then recombine
    let stable_coin = coin::mint_for_testing<USDC>(1000, ts::ctx(&mut scenario));
    conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    let recombined = conditional_balance::recombine_balance_to_stable<SUI, USDC>(
        &mut escrow,
        &mut balance,
        1000,
        ts::ctx(&mut scenario),
    );

    // CRITICAL: Verify supply is still 0 after recombine
    let (asset_supplies, stable_supplies) = coin_escrow::get_all_supplies(&escrow);
    assert!(asset_supplies[0] == 0, 0);
    assert!(asset_supplies[1] == 0, 0);
    assert!(stable_supplies[0] == 0, 0);
    assert!(stable_supplies[1] == 0, 0);

    // Verify wrapped balance is back to 0
    let (wrapped_asset, wrapped_stable) = coin_escrow::get_wrapped_balances(&escrow);
    assert!(wrapped_asset[0] == 0, 0);
    assert!(wrapped_asset[1] == 0, 0);
    assert!(wrapped_stable[0] == 0, 0);
    assert!(wrapped_stable[1] == 0, 0);

    coin::burn_for_testing(recombined);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
/// Test partial recombine - recombine only part of the balance.
fun test_atomic_partial_recombine() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Split 1000 stable to balance
    let stable_coin = coin::mint_for_testing<USDC>(1000, ts::ctx(&mut scenario));
    conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    // Recombine only 300
    let recombined = conditional_balance::recombine_balance_to_stable<SUI, USDC>(
        &mut escrow,
        &mut balance,
        300,
        ts::ctx(&mut scenario),
    );

    assert!(recombined.value() == 300);

    // Verify 700 remains in balance
    assert!(conditional_balance::get_balance(&balance, 0, false) == 700);
    assert!(conditional_balance::get_balance(&balance, 1, false) == 700);

    // Verify 700 remains in wrapped
    let (_wrapped_asset, wrapped_stable) = coin_escrow::get_wrapped_balances(&escrow);
    assert!(wrapped_stable[0] == 700, 0);
    assert!(wrapped_stable[1] == 700, 0);

    // Recombine the rest
    let recombined2 = conditional_balance::recombine_balance_to_stable<SUI, USDC>(
        &mut escrow,
        &mut balance,
        700,
        ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(recombined);
    coin::burn_for_testing(recombined2);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidBalanceAccess)]
/// Test that splitting zero amount fails.
fun test_atomic_split_zero_amount_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Try to split 0 - should fail
    let stable_coin = coin::mint_for_testing<USDC>(0, ts::ctx(&mut scenario));
    conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    // Won't reach here
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}

#[test]
#[expected_failure(abort_code = conditional_balance::EInvalidBalanceAccess)]
/// Test that recombining zero amount fails.
fun test_atomic_recombine_zero_amount_fails() {
    let mut scenario = start();

    let (market_id, mut escrow) = setup_escrow_with_caps(&mut scenario);

    let mut balance = conditional_balance::new<SUI, USDC>(
        market_id,
        2,
        ts::ctx(&mut scenario),
    );

    // Split some first
    let stable_coin = coin::mint_for_testing<USDC>(1000, ts::ctx(&mut scenario));
    conditional_balance::split_stable_to_balance<SUI, USDC>(
        &mut escrow,
        &mut balance,
        stable_coin,
    );

    // Try to recombine 0 - should fail
    let recombined = conditional_balance::recombine_balance_to_stable<SUI, USDC>(
        &mut escrow,
        &mut balance,
        0,
        ts::ctx(&mut scenario),
    );

    // Won't reach here
    coin::burn_for_testing(recombined);
    conditional_balance::destroy_empty(balance);
    coin_escrow::destroy_for_testing(escrow);

    end(scenario);
}
