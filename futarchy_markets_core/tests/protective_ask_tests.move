// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Protective Ask snapshot-based unit tests.
///
/// These tests exercise the buy flow using snapshot helpers that bypass
/// the full Account/Registry/Pool infrastructure.
///
/// Fixed-price model: stable_required = ceil(asset_amount * price_per_token / PRECISION)
/// where PRECISION = price_precision_scale() = 1e12

#[test_only]
module futarchy_markets_core::protective_ask_tests;

use account_actions::currency;
use futarchy_markets_core::protective_ask;
use futarchy_markets_core::spot_pool_mutation_auth;
use futarchy_one_shot_utils::constants;
use sui::clock;
use sui::coin;
use sui::object;
use sui::test_scenario::{Self as ts};
use sui::test_utils::destroy;

// === Dummy Coin Types ===

public struct ASSET has drop {}
public struct STABLE has drop {}

// ============================================================================
// 1. Basic buy
// ============================================================================

#[test]
fun test_buy_from_ask_basic() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 10 stable per token → 10 * 1e12 = 10_000_000_000_000
    let price_per_token = 10_000_000_000_000u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000_000,       // max_mint
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Buy 100 tokens, paying 1500 stable (overpay by 500)
    // stable_required = ceil(100 * 10_000_000_000_000 / 1_000_000_000_000) = 1000
    let payment = coin::mint_for_testing<STABLE>(1500, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask,
        payment,
        100,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(coin::value(&asset_out) == 100);
    assert!(coin::value(&change) == 500);
    assert!(protective_ask::minted_amount<ASSET, STABLE>(&ask) == 100);
    assert!(protective_ask::stable_collected_amount<ASSET, STABLE>(&ask) == 1000);
    assert!(protective_ask::seq_num<ASSET, STABLE>(&ask) == 1);
    assert!(protective_ask::remaining_mint_amount<ASSET, STABLE>(&ask) == 999_900);

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 2. Ceiling division
// ============================================================================

#[test]
fun test_buy_from_ask_ceiling_division() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 3.333... stable per token → 3_333_333_333_333
    let price_per_token = 3_333_333_333_333u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // stable_required = ceil(1 * 3_333_333_333_333 / 1_000_000_000_000) = ceil(3.333...) = 4
    let payment = coin::mint_for_testing<STABLE>(10, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask,
        payment,
        1,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(coin::value(&asset_out) == 1);
    assert!(coin::value(&change) == 6);

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 3. Multiple sequential buys (price stays fixed)
// ============================================================================

#[test]
fun test_buy_from_ask_multiple_sequential() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 1000 stable per token
    let price_per_token = 1_000_000_000_000_000u64; // 1000 * 1e12
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        500,            // max_mint
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // --- Buy 1: 100 tokens ---
    // stable_required = ceil(100 * 1000) = 100_000
    let payment1 = coin::mint_for_testing<STABLE>(100_000, ts::ctx(&mut scenario));
    let (asset_out1, change1) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment1, 100, &clock, ts::ctx(&mut scenario),
    );
    assert!(coin::value(&asset_out1) == 100);
    assert!(coin::value(&change1) == 0);
    assert!(protective_ask::minted_amount<ASSET, STABLE>(&ask) == 100);
    assert!(protective_ask::seq_num<ASSET, STABLE>(&ask) == 1);
    assert!(protective_ask::remaining_mint_amount<ASSET, STABLE>(&ask) == 400);

    coin::burn_for_testing(asset_out1);
    coin::burn_for_testing(change1);

    // --- Buy 2: 200 tokens ---
    // stable_required = ceil(200 * 1000) = 200_000
    let payment2 = coin::mint_for_testing<STABLE>(200_000, ts::ctx(&mut scenario));
    let (asset_out2, change2) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment2, 200, &clock, ts::ctx(&mut scenario),
    );
    assert!(coin::value(&asset_out2) == 200);
    assert!(coin::value(&change2) == 0);
    assert!(protective_ask::minted_amount<ASSET, STABLE>(&ask) == 300);
    assert!(protective_ask::seq_num<ASSET, STABLE>(&ask) == 2);
    assert!(protective_ask::remaining_mint_amount<ASSET, STABLE>(&ask) == 200);

    coin::burn_for_testing(asset_out2);
    coin::burn_for_testing(change2);

    // --- Buy 3: 200 tokens (hits exact max) ---
    let payment3 = coin::mint_for_testing<STABLE>(200_000, ts::ctx(&mut scenario));
    let (asset_out3, change3) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment3, 200, &clock, ts::ctx(&mut scenario),
    );
    assert!(coin::value(&asset_out3) == 200);
    assert!(coin::value(&change3) == 0);
    assert!(protective_ask::minted_amount<ASSET, STABLE>(&ask) == 500);
    assert!(protective_ask::seq_num<ASSET, STABLE>(&ask) == 3);
    assert!(protective_ask::remaining_mint_amount<ASSET, STABLE>(&ask) == 0);

    coin::burn_for_testing(asset_out3);
    coin::burn_for_testing(change3);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 4. Buy exact remaining amount
// ============================================================================

#[test]
fun test_buy_from_ask_exact_remaining() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 1 stable per token
    let price_per_token = 1_000_000_000_000u64; // 1 * 1e12
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        50,     // max_mint
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // stable_required = ceil(50 * 1) = 50
    let payment = coin::mint_for_testing<STABLE>(50, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, 50, &clock, ts::ctx(&mut scenario),
    );

    assert!(coin::value(&asset_out) == 50);
    assert!(coin::value(&change) == 0);
    assert!(protective_ask::remaining_mint_amount<ASSET, STABLE>(&ask) == 0);
    assert!(protective_ask::minted_amount<ASSET, STABLE>(&ask) == 50);

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 5. Insufficient payment
// ============================================================================

#[test]
#[expected_failure(abort_code = protective_ask::EInsufficientPayment)]
fun test_buy_from_ask_insufficient_payment() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 1000 stable per token
    let price_per_token = 1_000_000_000_000_000u64; // 1000 * 1e12
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Buy 10 tokens: need 10 * 1000 = 10_000, only paying 5_000
    let payment = coin::mint_for_testing<STABLE>(5_000, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, 10, &clock, ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 6. Wall depleted (buy then buy again)
// ============================================================================

#[test]
#[expected_failure(abort_code = protective_ask::EAskWallDepleted)]
fun test_buy_from_ask_wall_depleted() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 1 stable per token
    let price_per_token = 1_000_000_000_000u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        100,    // max_mint
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Deplete entire wall
    let payment1 = coin::mint_for_testing<STABLE>(100, ts::ctx(&mut scenario));
    let (asset_out1, change1) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment1, 100, &clock, ts::ctx(&mut scenario),
    );
    coin::burn_for_testing(asset_out1);
    coin::burn_for_testing(change1);

    // Try to buy 1 more — should fail with EAskWallDepleted
    let payment2 = coin::mint_for_testing<STABLE>(100, ts::ctx(&mut scenario));
    let (asset_out2, change2) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment2, 1, &clock, ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(asset_out2);
    coin::burn_for_testing(change2);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 7. Exceeds remaining in one go
// ============================================================================

#[test]
#[expected_failure(abort_code = protective_ask::EAskWallDepleted)]
fun test_buy_from_ask_exceeds_remaining() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 1 stable per token
    let price_per_token = 1_000_000_000_000u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        100,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Try to buy 101 when max is 100
    let payment = coin::mint_for_testing<STABLE>(200, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, 101, &clock, ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 8. Expired ask (past 90-day deadline)
// ============================================================================

#[test]
#[expected_failure(abort_code = protective_ask::EAskWallExpired)]
fun test_buy_from_ask_after_deadline() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    let price_per_token = 1_000_000_000_000u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Advance clock past 90 days
    clock::increment_for_testing(&mut clock, constants::ninety_days_ms());

    let payment = coin::mint_for_testing<STABLE>(100, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, 1, &clock, ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 9. Inactive ask
// ============================================================================

#[test]
#[expected_failure(abort_code = protective_ask::EAskInactive)]
fun test_buy_from_ask_inactive() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    let price_per_token = 1_000_000_000_000u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    protective_ask::deactivate_for_testing(&mut ask);

    let payment = coin::mint_for_testing<STABLE>(100, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, 1, &clock, ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 10. Zero amount
// ============================================================================

#[test]
#[expected_failure(abort_code = protective_ask::EZeroAmount)]
fun test_buy_from_ask_zero_amount() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    let price_per_token = 1_000_000_000_000u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    let payment = coin::mint_for_testing<STABLE>(100, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, 0, &clock, ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 11. Quote buy snapshot
// ============================================================================

#[test]
fun test_quote_buy_snapshot() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 10 stable per token
    let price_per_token = 10_000_000_000_000u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Quote 100 tokens: ceil(100 * 10_000_000_000_000 / 1_000_000_000_000) = 1000
    let quote = protective_ask::quote_buy_snapshot<ASSET, STABLE>(&ask, 100, &clock);
    assert!(quote == 1000);

    // Quote 0 tokens => 0
    let quote_zero = protective_ask::quote_buy_snapshot<ASSET, STABLE>(&ask, 0, &clock);
    assert!(quote_zero == 0);

    // After deactivating => 0
    protective_ask::deactivate_for_testing(&mut ask);
    let quote_inactive = protective_ask::quote_buy_snapshot<ASSET, STABLE>(&ask, 100, &clock);
    assert!(quote_inactive == 0);

    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 12. Price per token accessor
// ============================================================================

#[test]
fun test_price_per_token_accessor() {
    let mut scenario = ts::begin(@0x0);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    let price_per_token = 2_500_000_000_000u64; // 2.5 stable per token
    let ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(protective_ask::price_per_token<ASSET, STABLE>(&ask) == price_per_token);

    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// 13. Fixed price stays constant after buys
// ============================================================================

#[test]
fun test_price_stays_constant_after_buy() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 10 stable per token
    let price_per_token = 10_000_000_000_000u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        500,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    let price_before = protective_ask::price_per_token<ASSET, STABLE>(&ask);

    // Buy 7 tokens: stable_required = ceil(7 * 10) = 70
    let payment = coin::mint_for_testing<STABLE>(100, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, 7, &clock, ts::ctx(&mut scenario),
    );

    let price_after = protective_ask::price_per_token<ASSET, STABLE>(&ask);
    assert!(price_after == price_before);

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);

    // Second buy
    let payment2 = coin::mint_for_testing<STABLE>(50, ts::ctx(&mut scenario));
    let (asset_out2, change2) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment2, 3, &clock, ts::ctx(&mut scenario),
    );

    let price_after2 = protective_ask::price_per_token<ASSET, STABLE>(&ask);
    assert!(price_after2 == price_before);

    coin::burn_for_testing(asset_out2);
    coin::burn_for_testing(change2);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_buy_succeeds_with_no_expiry() {
    let account_id = object::id_from_address(@0xBEEF);
    let mut scenario = ts::begin(@0x1);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Price = 10 stable per token
    let price_per_token = 10_000_000_000_000u64;
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000_000,
        0, // release_duration_ms = 0 → no permissionless close
        &clock,
        ts::ctx(&mut scenario),
    );

    // Advance clock well past 90 days — buy should still succeed
    clock::increment_for_testing(&mut clock, constants::ninety_days_ms() + 1);

    let payment = coin::mint_for_testing<STABLE>(100_000_000, ts::ctx(&mut scenario));
    let (tokens, change) = protective_ask::buy_from_ask_snapshot(
        &mut ask,
        payment,
        50,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert!(coin::value(&tokens) > 0, 0);

    coin::burn_for_testing(tokens);
    coin::burn_for_testing(change);
    clock::destroy_for_testing(clock);
    protective_ask::destroy_for_testing(ask);
    ts::end(scenario);
}

// ============================================================================
// Higher price tests
// ============================================================================

#[test]
fun test_high_price_doubles_cost() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 2000 stable per token
    let price_per_token = 2_000_000_000_000_000u64; // 2000 * 1e12
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Buy 10 tokens: stable_required = ceil(10 * 2000) = 20_000
    let payment = coin::mint_for_testing<STABLE>(20_000, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, 10, &clock, ts::ctx(&mut scenario),
    );

    assert!(coin::value(&asset_out) == 10);
    assert!(coin::value(&change) == 0);
    assert!(protective_ask::stable_collected_amount<ASSET, STABLE>(&ask) == 20_000);

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_quote_matches_buy() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 30 stable per token
    let price_per_token = 30_000_000_000_000u64; // 30 * 1e12
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    let asset_amount = 100u64;
    let quoted = protective_ask::quote_buy_snapshot<ASSET, STABLE>(&ask, asset_amount, &clock);

    // quote = ceil(100 * 30) = 3000
    assert!(quoted == 3000);

    let payment = coin::mint_for_testing<STABLE>(quoted, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, asset_amount, &clock, ts::ctx(&mut scenario),
    );

    assert!(coin::value(&asset_out) == asset_amount);
    assert!(coin::value(&change) == 0);

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = protective_ask::EZeroPrice)]
fun test_zero_price_fails() {
    let mut scenario = ts::begin(@0x0);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // price_per_token = 0 → should fail
    let ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        0,   // zero price
        1_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_large_price() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let dummy_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&dummy_uid);
    object::delete(dummy_uid);

    // Price = 1000 stable per token
    let price_per_token = 1_000_000_000_000_000u64; // 1000 * 1e12
    let mut ask = protective_ask::create_for_testing<ASSET, STABLE>(
        account_id,
        price_per_token,
        1_000,
        constants::ninety_days_ms(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Buy 1 token: stable_required = ceil(1 * 1000) = 1000
    let payment = coin::mint_for_testing<STABLE>(1000, ts::ctx(&mut scenario));
    let (asset_out, change) = protective_ask::buy_from_ask_snapshot<ASSET, STABLE>(
        &mut ask, payment, 1, &clock, ts::ctx(&mut scenario),
    );

    assert!(coin::value(&asset_out) == 1);
    assert!(coin::value(&change) == 0);

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(change);
    protective_ask::destroy_for_testing(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ============================================================================
// Mint cap binding — EMintCapAccountMismatch
// ============================================================================

/// `create()` must reject a CurrencyMintAdminCap that was minted for a different
/// account. Without this check, a DAO could be coerced into a protective-ask
/// flow backed by another DAO's mint authority.
#[test]
#[expected_failure(abort_code = protective_ask::EMintCapAccountMismatch)]
fun test_create_rejects_mint_cap_bound_to_different_account() {
    let mut scenario = ts::begin(@0x0);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let account_uid = object::new(ts::ctx(&mut scenario));
    let account_id = object::uid_to_inner(&account_uid);
    object::delete(account_uid);

    let pool_uid = object::new(ts::ctx(&mut scenario));
    let pool_id = object::uid_to_inner(&pool_uid);
    object::delete(pool_uid);

    // Cap bound to a different account than the one we're creating the ask for.
    let other_uid = object::new(ts::ctx(&mut scenario));
    let other_account_id = object::uid_to_inner(&other_uid);
    object::delete(other_uid);
    let bad_cap = currency::create_mint_admin_cap_for_testing<ASSET>(
        other_account_id,
        ts::ctx(&mut scenario),
    );

    let auth = spot_pool_mutation_auth::create_for_testing(pool_id);

    // Expected abort: EMintCapAccountMismatch (20) in protective_ask.
    let ask = protective_ask::create<ASSET, STABLE>(
        account_id,
        pool_id,
        1_000_000_000_000u64, // price > 0
        1_000,                 // max_mint > 0
        constants::ninety_days_ms(),
        bad_cap,
        auth,
        &clock,
        ts::ctx(&mut scenario),
    );

    destroy(ask);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
