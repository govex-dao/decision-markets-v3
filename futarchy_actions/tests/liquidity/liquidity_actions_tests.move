// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_actions::liquidity_actions_tests;

use futarchy_actions::liquidity_actions;
use std::string;
use sui::object;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Constants ===

const OWNER: address = @0xCAFE;

// Test IDs
const POOL_ID_BYTES: address = @0x1111111111111111111111111111111111111111111111111111111111111111;

// === Test Structs ===

public struct TestAsset has drop {}
public struct TestStable has drop {}
public struct TestLP has drop {}

// === Helper Functions ===

fun start(): Scenario {
    ts::begin(OWNER)
}

fun end(scenario: Scenario) {
    ts::end(scenario);
}

fun pool_id(): object::ID {
    object::id_from_address(POOL_ID_BYTES)
}

// === AddLiquidity Action Tests ===

#[test]
/// Test creating valid add liquidity action
fun test_new_add_liquidity_action() {
    let action = liquidity_actions::new_add_liquidity_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        1000u64, // asset_amount
        2000u64, // stable_amount
        500u64, // min_lp_out
        string::utf8(b"asset_coin"),
        string::utf8(b"stable_coin"),
    );

    // Verify getters
    assert!(liquidity_actions::get_pool_id(&action) == pool_id(), 0);
    assert!(liquidity_actions::get_asset_amount(&action) == 1000, 1);
    assert!(liquidity_actions::get_stable_amount(&action) == 2000, 2);
    assert!(liquidity_actions::get_min_lp_amount(&action) == 500, 3);

    destroy(action);
}

#[test]
#[expected_failure(abort_code = liquidity_actions::EInvalidAmount)]
/// Test fails with zero asset amount
fun test_new_add_liquidity_zero_asset_fails() {
    let action = liquidity_actions::new_add_liquidity_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        0u64, // zero asset
        2000u64,
        500u64,
        string::utf8(b"asset_coin"),
        string::utf8(b"stable_coin"),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = liquidity_actions::EInvalidAmount)]
/// Test fails with zero stable amount
fun test_new_add_liquidity_zero_stable_fails() {
    let action = liquidity_actions::new_add_liquidity_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        1000u64,
        0u64, // zero stable
        500u64,
        string::utf8(b"asset_coin"),
        string::utf8(b"stable_coin"),
    );
    destroy(action);
}

#[test]
/// Test add liquidity with extreme values
fun test_new_add_liquidity_extreme_values() {
    let action = liquidity_actions::new_add_liquidity_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        18446744073709551615u64, // max u64
        18446744073709551615u64, // max u64
        0u64, // min_lp_out can be 0
        string::utf8(b"asset_coin"),
        string::utf8(b"stable_coin"),
    );

    destroy(action);
}

// === RemoveLiquidityToResources Action Tests ===

#[test]
/// Test creating valid remove liquidity to resources action
fun test_new_remove_liquidity_to_resources_action() {
    let action = liquidity_actions::new_remove_liquidity_to_resources_action<
        TestAsset,
        TestStable,
        TestLP,
    >(
        pool_id(),
        1000u64, // lp_amount
        500u64, // min_asset_amount
        500u64, // min_stable_amount
        string::utf8(b"lp_coin"),
        string::utf8(b"asset_out"),
        string::utf8(b"stable_out"),
        false, // for_dissolution
    );

    destroy(action);
}

#[test]
#[expected_failure(abort_code = liquidity_actions::EInvalidAmount)]
/// Test fails with zero lp amount
fun test_new_remove_liquidity_to_resources_zero_lp_fails() {
    let action = liquidity_actions::new_remove_liquidity_to_resources_action<
        TestAsset,
        TestStable,
        TestLP,
    >(
        pool_id(),
        0u64, // zero lp_amount
        500u64,
        500u64,
        string::utf8(b"lp_coin"),
        string::utf8(b"asset_out"),
        string::utf8(b"stable_out"),
        false,
    );
    destroy(action);
}

#[test]
/// Test remove liquidity to resources with zero minimums (no slippage protection)
fun test_new_remove_liquidity_to_resources_zero_minimums() {
    let action = liquidity_actions::new_remove_liquidity_to_resources_action<
        TestAsset,
        TestStable,
        TestLP,
    >(
        pool_id(),
        1000u64,
        0u64, // zero min_asset_amount is allowed
        0u64, // zero min_stable_amount is allowed
        string::utf8(b"lp_coin"),
        string::utf8(b"asset_out"),
        string::utf8(b"stable_out"),
        false,
    );

    destroy(action);
}

#[test]
#[expected_failure(abort_code = liquidity_actions::EEmptyResourceName)]
/// Test fails with empty lp_resource_name
fun test_new_remove_liquidity_to_resources_empty_lp_name_fails() {
    let action = liquidity_actions::new_remove_liquidity_to_resources_action<
        TestAsset,
        TestStable,
        TestLP,
    >(
        pool_id(),
        1000u64,
        0u64,
        0u64,
        string::utf8(b""), // empty lp_resource_name
        string::utf8(b"asset_out"),
        string::utf8(b"stable_out"),
        false,
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = liquidity_actions::EEmptyResourceName)]
/// Test fails with empty asset_output_name
fun test_new_remove_liquidity_to_resources_empty_asset_name_fails() {
    let action = liquidity_actions::new_remove_liquidity_to_resources_action<
        TestAsset,
        TestStable,
        TestLP,
    >(
        pool_id(),
        1000u64,
        0u64,
        0u64,
        string::utf8(b"lp_coin"),
        string::utf8(b""), // empty asset_output_name
        string::utf8(b"stable_out"),
        false,
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = liquidity_actions::EEmptyResourceName)]
/// Test fails with empty stable_output_name
fun test_new_remove_liquidity_to_resources_empty_stable_name_fails() {
    let action = liquidity_actions::new_remove_liquidity_to_resources_action<
        TestAsset,
        TestStable,
        TestLP,
    >(
        pool_id(),
        1000u64,
        0u64,
        0u64,
        string::utf8(b"lp_coin"),
        string::utf8(b"asset_out"),
        string::utf8(b""), // empty stable_output_name
        false,
    );
    destroy(action);
}

// === Swap Action Tests ===

#[test]
/// Test creating valid swap action (asset to stable)
fun test_new_swap_action_asset_to_stable() {
    let action = liquidity_actions::new_swap_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        true, // swap_asset = true means asset -> stable
        1000u64, // amount_in
        500u64, // min_amount_out
        string::utf8(b"input_coin"),
    );

    destroy(action);
}

#[test]
/// Test creating valid swap action (stable to asset)
fun test_new_swap_action_stable_to_asset() {
    let action = liquidity_actions::new_swap_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        false, // swap_asset = false means stable -> asset
        2000u64, // amount_in
        1000u64, // min_amount_out
        string::utf8(b"input_coin"),
    );

    destroy(action);
}

#[test]
#[expected_failure(abort_code = liquidity_actions::EInvalidAmount)]
/// Test fails with zero amount_in
fun test_new_swap_action_zero_amount_fails() {
    let action = liquidity_actions::new_swap_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        true,
        0u64, // zero amount_in
        500u64,
        string::utf8(b"input_coin"),
    );
    destroy(action);
}

#[test]
/// Test swap with zero min_amount_out (no slippage protection)
fun test_new_swap_action_zero_min_out() {
    let action = liquidity_actions::new_swap_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        true,
        1000u64,
        0u64, // zero min_amount_out is allowed
        string::utf8(b"input_coin"),
    );

    destroy(action);
}

#[test]
/// Test swap with extreme values
fun test_new_swap_action_extreme_values() {
    let action = liquidity_actions::new_swap_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        true,
        18446744073709551615u64, // max u64
        18446744073709551615u64, // max u64
        string::utf8(b"input_coin"),
    );

    destroy(action);
}

// === UpdatePoolFee Action Tests ===

#[test]
/// Test creating valid update pool fee action
fun test_new_update_pool_fee_action() {
    let action = liquidity_actions::new_update_pool_fee_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        50u64, // new_fee_bps (0.5%)
    );

    // Verify getters
    assert!(liquidity_actions::get_update_fee_pool_id(&action) == pool_id(), 0);
    assert!(liquidity_actions::get_new_fee_bps(&action) == 50, 1);

    destroy(action);
}

#[test]
/// Test update pool fee with zero fee (no fee pool)
fun test_new_update_pool_fee_zero_fee() {
    let action = liquidity_actions::new_update_pool_fee_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        0u64, // zero fee is allowed
    );

    assert!(liquidity_actions::get_new_fee_bps(&action) == 0, 0);

    destroy(action);
}

#[test]
/// Test update pool fee with maximum fee
fun test_new_update_pool_fee_max_fee() {
    let max_fee_bps = futarchy_one_shot_utils::constants::max_amm_fee_bps();
    let action = liquidity_actions::new_update_pool_fee_action<TestAsset, TestStable, TestLP>(
        pool_id(),
        max_fee_bps,
    );

    assert!(liquidity_actions::get_new_fee_bps(&action) == max_fee_bps, 0);

    destroy(action);
}

// === Marker Function Tests ===

#[test]
/// Test marker functions
fun test_marker_functions() {
    let _add = liquidity_actions::add_liquidity_marker<TestAsset, TestStable, TestLP>();
    let _remove = liquidity_actions::remove_liquidity_to_resources_marker<
        TestAsset,
        TestStable,
        TestLP,
    >();
    let _swap = liquidity_actions::swap_marker<TestAsset, TestStable, TestLP>();
    let _update_fee = liquidity_actions::update_pool_fee_marker<TestAsset, TestStable, TestLP>();
}
