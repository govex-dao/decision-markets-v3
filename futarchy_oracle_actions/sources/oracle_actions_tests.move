#[test_only]
module futarchy_oracle::oracle_actions_tests;

use account_actions::currency;
use account_protocol::package_registry;
use futarchy_core::dao_config;
use futarchy_core::futarchy_config;
use futarchy_one_shot_utils::constants;
use futarchy_oracle::oracle_actions;
use std::ascii;
use std::option;
use std::string;
use sui::clock;
use sui::test_utils::destroy;
use sui::url;

// === Test Constants ===

const RECIPIENT1: address = @0xBEEF;
const RECIPIENT2: address = @0xDEAD;

#[test_only]
public struct TEST_ORACLE_ASSET has drop, store {}

#[test_only]
public struct TEST_ORACLE_STABLE has drop, store {}

fun build_test_dao_config(): dao_config::DaoConfig {
    let trading_params = dao_config::default_trading_params();
    let twap_config = dao_config::default_twap_config();
    let governance_config = dao_config::default_governance_config();
    let metadata_config = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.dao/icon.png"),
        string::utf8(b""),
    );
    let conditional_coin_config = dao_config::default_conditional_coin_config();
    let sponsorship_config = dao_config::default_sponsorship_config();
    dao_config::new_dao_config(
        trading_params,
        twap_config,
        governance_config,
        metadata_config,
        conditional_coin_config,
        sponsorship_config,
    )
}

// === Tests ===

#[test]
/// Test helper function for relative to absolute price conversion
fun test_relative_to_absolute_threshold() {
    // Launchpad price: 1.5 (in 1e12 scale)
    let launchpad_price = 1_500_000_000_000u128;

    // 2x multiplier (in 1e12 scale)
    let multiplier_2x = 2_000_000_000_000u64;

    let result = oracle_actions::relative_to_absolute_threshold(
        launchpad_price,
        multiplier_2x,
    );

    // Expected: 1.5 * 2.0 = 3.0
    assert!(result == 3_000_000_000_000u128, 0);

    // Test 0.5x multiplier
    let multiplier_half = 500_000_000_000u64;
    let result2 = oracle_actions::relative_to_absolute_threshold(
        launchpad_price,
        multiplier_half,
    );

    // Expected: 1.5 * 0.5 = 0.75
    assert!(result2 == 750_000_000_000u128, 1);
}

#[test]
/// Test creating price conditions
fun test_create_price_conditions() {
    // Above condition
    let above = oracle_actions::absolute_price_condition(
        1_000_000_000_000,
        true,
    );

    // Below condition
    let below = oracle_actions::absolute_price_condition(
        500_000_000_000,
        false,
    );

    // Just verify they can be created
    destroy(above);
    destroy(below);
}

#[test]
/// Test creating recipient mint structs
fun test_create_recipient_mint() {
    let recipient1 = oracle_actions::new_recipient_mint(RECIPIENT1, 1000);
    let recipient2 = oracle_actions::new_recipient_mint(RECIPIENT2, 500);

    // Verify they can be created
    destroy(recipient1);
    destroy(recipient2);
}

#[test]
/// Test new_tier_spec construction with single recipient
fun test_new_tier_spec_single_recipient() {
    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 1000)];

    let tier_spec = oracle_actions::new_tier_spec(
        2_000_000_000_000u128, // 2.0 price threshold
        true, // unlock above
        recipients,
        string::utf8(b"Single Recipient Tier"),
    );

    destroy(tier_spec);
}

#[test]
/// Test new_tier_spec construction with multiple recipients
fun test_new_tier_spec_multi_recipient() {
    let recipients = vector[
        oracle_actions::new_recipient_mint(RECIPIENT1, 1000),
        oracle_actions::new_recipient_mint(RECIPIENT2, 500),
    ];

    let tier_spec = oracle_actions::new_tier_spec(
        5_000_000_000_000u128, // 5.0 price threshold
        false, // unlock below
        recipients,
        string::utf8(b"Multi Recipient Tier"),
    );

    destroy(tier_spec);
}

#[test]
/// Test new_cancel_grant action construction
fun test_new_cancel_grant_action() {
    let grant_id = object::id_from_address(@0x1234);
    let action = oracle_actions::new_cancel_grant(grant_id);

    destroy(action);
}

#[test]
/// Test relative threshold with edge cases
fun test_relative_threshold_edge_cases() {
    // Test 1x multiplier (should return same price)
    let price = 2_000_000_000_000u128;
    let multiplier_1x = 1_000_000_000_000u64;
    let result = oracle_actions::relative_to_absolute_threshold(price, multiplier_1x);
    assert!(result == 2_000_000_000_000u128, 0);

    // Test 0x multiplier (should return 0)
    let multiplier_0x = 0u64;
    let result2 = oracle_actions::relative_to_absolute_threshold(price, multiplier_0x);
    assert!(result2 == 0u128, 1);

    // Test 10x multiplier
    let multiplier_10x = 10_000_000_000_000u64;
    let result3 = oracle_actions::relative_to_absolute_threshold(price, multiplier_10x);
    assert!(result3 == 20_000_000_000_000u128, 2);
}

#[test]
/// Test new_create_oracle_grant action construction
fun test_new_create_oracle_grant_action() {
    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 100)];

    let tier_spec = oracle_actions::new_tier_spec(
        1_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Test Tier"),
    );

    let action = oracle_actions::new_create_oracle_grant<u64, u64>(
        string::utf8(b"mint_cap"),
        vector[tier_spec],
        false, // use_relative_pricing (absolute prices)
        1_500_000_000_000, // launchpad multiplier (1.5x in 1e12 scale)
        0, // earliest execution
        1, // expiry years
        true, // cancelable
        string::utf8(b"Test Grant"),
        constants::thirty_days_ms(), // twap_window_ms
    );

    destroy(action);
}

/// A CurrencyMintAdminCap is account-bound. Creating a grant with a cap that
/// was minted for a different account must abort with EMintCapAccountMismatch
/// (33) — otherwise a compromised or borrowed cap from another DAO could be
/// used to mint on this DAO's behalf via a permissionless grant.
#[test]
#[expected_failure(abort_code = 33, location = futarchy_oracle::oracle_actions)]
fun test_create_grant_rejects_mint_cap_bound_to_different_account() {
    let ctx = &mut sui::tx_context::dummy();
    let registry = package_registry::new_for_testing(ctx);

    let futarchy_cfg = futarchy_config::new<TEST_ORACLE_ASSET, TEST_ORACLE_STABLE>(
        build_test_dao_config(),
        option::some(1_500_000_000_000u128),
    );
    let mut account = futarchy_config::new_account_test(futarchy_cfg, &registry, ctx);
    let dao_id = object::id(&account);

    // Cap bound to a DIFFERENT account than the one we are creating the grant on.
    let other_account_id = object::id_from_address(@0xF0F0);
    let bad_cap = currency::create_mint_admin_cap_for_testing<TEST_ORACLE_ASSET>(
        other_account_id,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);
    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 1_000)];
    let tier_spec = oracle_actions::new_tier_spec(
        2_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Mismatch Tier"),
    );
    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier_spec]);

    let _grant_id = oracle_actions::create_grant<TEST_ORACLE_ASSET, TEST_ORACLE_STABLE>(
        &mut account,
        &registry,
        tiers,
        false, // absolute pricing
        0,     // launchpad_multiplier unused when use_relative_pricing=false
        0,     // earliest_execution_offset_ms
        1,     // expiry_years
        true,  // cancelable
        string::utf8(b"Bad Grant"),
        dao_id, // passes EDaoIdMismatch; fails on EMintCapAccountMismatch
        bad_cap,
        constants::thirty_days_ms(),
        &clock,
        ctx,
    );

    destroy(account);
    destroy(registry);
    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = 3, location = futarchy_oracle::oracle_actions)]
fun test_create_grant_requires_launchpad_price() {
    let ctx = &mut sui::tx_context::dummy();
    let registry = package_registry::new_for_testing(ctx);

    let futarchy_cfg = futarchy_config::new<TEST_ORACLE_ASSET, TEST_ORACLE_STABLE>(
        build_test_dao_config(),
        option::none(),
    );
    let mut account = futarchy_config::new_account_test(futarchy_cfg, &registry, ctx);
    let dao_id = object::id(&account);
    let mint_cap = currency::create_mint_admin_cap_for_testing<TEST_ORACLE_ASSET>(
        dao_id,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);
    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 1_000)];
    let tier_spec = oracle_actions::new_tier_spec(
        2_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Missing Launchpad Price Tier"),
    );
    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier_spec]);

    let _grant_id = oracle_actions::create_grant<TEST_ORACLE_ASSET, TEST_ORACLE_STABLE>(
        &mut account,
        &registry,
        tiers,
        false,
        0,
        0,
        1,
        true,
        string::utf8(b"Missing Launchpad Price Grant"),
        dao_id,
        mint_cap,
        constants::thirty_days_ms(),
        &clock,
        ctx,
    );

    destroy(account);
    destroy(registry);
    clock::destroy_for_testing(clock);
}
