// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_actions::config_actions_comprehensive_tests;

use futarchy_actions::config_actions;
use std::ascii;
use std::string;
use sui::test_utils::destroy;
use sui::url;

// === Constants ===

const DEFAULT_TWAP_THRESHOLD: u128 = 50_000; // Must be <= twap_threshold_base() (100_000)

// === UpdateName Action Tests ===

#[test]
/// Test creating update name action with valid name
fun test_new_update_name_action_valid() {
    let name = string::utf8(b"New DAO Name");
    let action = config_actions::new_update_name_action(name);

    assert!(config_actions::get_new_name(&action) == string::utf8(b"New DAO Name"), 0);

    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EEmptyName)]
/// Test fails with empty name
fun test_new_update_name_action_empty_fails() {
    let name = string::utf8(b"");
    let action = config_actions::new_update_name_action(name);
    destroy(action);
}

#[test]
/// Test with very long name
fun test_new_update_name_action_long_name() {
    let long_name = string::utf8(
        b"This is a very long DAO name that exceeds normal expectations but should still be valid because we don't enforce a maximum length on the name field",
    );
    let action = config_actions::new_update_name_action(long_name);
    destroy(action);
}

// === TradingParamsUpdate Action Tests ===

#[test]
/// Test trading params with all fields specified
/// NOTE: asset_decimals and stable_decimals removed - decimals are immutable in Sui coins
fun test_trading_params_comprehensive() {
    let action = config_actions::new_trading_params_update_action(
        option::some(100_000u64), // min_asset_amount (>= protocol_min_liquidity_amount)
        option::some(200_000u64), // min_stable_amount (>= protocol_min_liquidity_amount)
        option::some(86400000u64), // review_period_ms (1 day)
        option::some(604800000u64), // trading_period_ms (7 days)
        option::some(30u64), // amm_total_fee_bps (0.3%)
        option::none(), // conditional_liquidity_ratio_percent
    );

    let (min_asset, min_stable, review, trading, fee, _ratio) = config_actions::get_trading_params_fields(
        &action,
    );

    assert!(min_asset.is_some(), 0);
    assert!(min_stable.is_some(), 1);
    assert!(review.is_some(), 2);
    assert!(trading.is_some(), 3);
    assert!(fee.is_some(), 4);

    assert!(*min_asset.borrow() == 100_000, 7);
    assert!(*min_stable.borrow() == 200_000, 8);

    destroy(action);
}

#[test]
/// Test with all None (no changes)
fun test_trading_params_all_none() {
    let action = config_actions::new_trading_params_update_action(
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
    );

    let (min_asset, min_stable, review, trading, fee, _ratio) = config_actions::get_trading_params_fields(
        &action,
    );

    assert!(min_asset.is_none(), 0);
    assert!(min_stable.is_none(), 1);
    assert!(review.is_none(), 2);
    assert!(trading.is_none(), 3);
    assert!(fee.is_none(), 4);

    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
/// Test fails with zero min_asset_amount
fun test_trading_params_zero_min_asset_fails() {
    let action = config_actions::new_trading_params_update_action(
        option::some(0u64), // zero min_asset_amount
        option::some(2000u64),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_trading_params_min_asset_below_protocol_min_fails() {
    let below_min = futarchy_one_shot_utils::constants::protocol_min_liquidity_amount() - 1;
    let action = config_actions::new_trading_params_update_action(
        option::some(below_min),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_trading_params_min_stable_below_protocol_min_fails() {
    let below_min = futarchy_one_shot_utils::constants::protocol_min_liquidity_amount() - 1;
    let action = config_actions::new_trading_params_update_action(
        option::none(),
        option::some(below_min),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_trading_params_review_below_protocol_min_fails() {
    let below_min = futarchy_one_shot_utils::constants::min_review_period_ms() - 1;
    let action = config_actions::new_trading_params_update_action(
        option::none(),
        option::none(),
        option::some(below_min),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_trading_params_review_above_protocol_max_fails() {
    let above_max = futarchy_one_shot_utils::constants::max_trading_duration_ms() + 1;
    let action = config_actions::new_trading_params_update_action(
        option::none(),
        option::none(),
        option::some(above_max),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_trading_params_trading_above_protocol_max_fails() {
    let above_max = futarchy_one_shot_utils::constants::max_trading_duration_ms() + 1;
    let action = config_actions::new_trading_params_update_action(
        option::none(),
        option::none(),
        option::none(),
        option::some(above_max),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
/// Test fails with invalid fee_bps (> protocol max)
fun test_trading_params_invalid_fee_fails() {
    let action = config_actions::new_trading_params_update_action(
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::some(futarchy_one_shot_utils::constants::max_amm_fee_bps() + 1),
        option::none(),
    );
    destroy(action);
}

#[test]
/// Test with maximum valid fee_bps (protocol max)
fun test_trading_params_max_fee() {
    let action = config_actions::new_trading_params_update_action(
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::some(futarchy_one_shot_utils::constants::max_amm_fee_bps()),
        option::none(),
    );
    destroy(action);
}

// === MetadataUpdate Action Tests ===

#[test]
/// Test metadata update with all fields
fun test_metadata_update_comprehensive() {
    let action = config_actions::new_metadata_update_action(
        option::some(ascii::string(b"MyDAO")),
        option::some(url::new_unsafe_from_bytes(b"https://example.com/icon.png")),
        option::some(string::utf8(b"A decentralized autonomous organization")),
    );

    let (name, url, desc) = config_actions::get_metadata_fields(&action);

    assert!(name.is_some(), 0);
    assert!(url.is_some(), 1);
    assert!(desc.is_some(), 2);

    destroy(action);
}

#[test]
/// Test metadata update with partial fields
fun test_metadata_update_partial() {
    let action = config_actions::new_metadata_update_action(
        option::some(ascii::string(b"MyDAO")),
        option::none(), // no url
        option::none(), // no description
    );

    let (name, url, desc) = config_actions::get_metadata_fields(&action);

    assert!(name.is_some(), 0);
    assert!(url.is_none(), 1);
    assert!(desc.is_none(), 2);

    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EEmptyString)]
/// Test fails with empty name
fun test_metadata_update_empty_name_fails() {
    let action = config_actions::new_metadata_update_action(
        option::some(ascii::string(b"")), // empty name
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EEmptyString)]
/// Test fails with empty description
fun test_metadata_update_empty_description_fails() {
    let action = config_actions::new_metadata_update_action(
        option::none(),
        option::none(),
        option::some(string::utf8(b"")), // empty description
    );
    destroy(action);
}

// === TwapConfigUpdate Action Tests ===

#[test]
/// Test TWAP config update with all fields
fun test_twap_config_comprehensive() {
    let threshold = 50_000u128; // threshold must be <= twap_threshold_base() (100_000)

    let action = config_actions::new_twap_config_update_action(
        option::some(3600000u64), // start_delay (1 hour, divisible by twap_price_cap_window 60_000)
        option::some(100u64), // cap_ppm
        option::some(1000000000u128), // initial_observation
        option::some(threshold), // threshold
        option::some(3000u128), // sponsored_threshold (3%)
    );

    let (delay, step, obs, thresh, sponsored) = config_actions::get_twap_config_fields(&action);

    assert!(delay.is_some(), 0);
    assert!(step.is_some(), 1);
    assert!(obs.is_some(), 2);
    assert!(thresh.is_some(), 3);
    assert!(sponsored.is_some(), 4);

    destroy(action);
}

#[test]
/// Test with threshold only
fun test_twap_config_threshold_only() {
    let threshold = 50_000u128; // threshold must be <= twap_threshold_base() (100_000)

    let action = config_actions::new_twap_config_update_action(
        option::none(),
        option::none(),
        option::none(),
        option::some(threshold),
        option::none(), // sponsored_threshold
    );

    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
/// Test fails with zero cap_ppm
fun test_twap_config_zero_cap_ppm_fails() {
    let action = config_actions::new_twap_config_update_action(
        option::none(),
        option::some(0u64), // zero cap_ppm
        option::none(),
        option::none(),
        option::none(), // sponsored_threshold
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_twap_config_start_delay_not_window_aligned_fails() {
    let action = config_actions::new_twap_config_update_action(
        option::some(futarchy_one_shot_utils::constants::twap_price_cap_window() + 1),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_twap_config_cap_ppm_exceeds_ppm_denominator_fails() {
    let action = config_actions::new_twap_config_update_action(
        option::none(),
        option::some(futarchy_one_shot_utils::constants::ppm_denominator() + 1),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_twap_config_zero_initial_observation_fails() {
    let action = config_actions::new_twap_config_update_action(
        option::none(),
        option::none(),
        option::some(0),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_twap_config_threshold_above_base_fails() {
    let action = config_actions::new_twap_config_update_action(
        option::none(),
        option::none(),
        option::none(),
        option::some(futarchy_one_shot_utils::constants::twap_threshold_base() + 1),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
/// Test fails with sponsored_threshold exceeding max (10_000 = 10%)
fun test_twap_config_sponsored_threshold_exceeds_max_fails() {
    let action = config_actions::new_twap_config_update_action(
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::some(11000u128), // 11% exceeds max 10%
    );
    destroy(action);
}

// === GovernanceUpdate Action Tests ===

#[test]
/// Test governance update with all fields
fun test_governance_update_comprehensive() {
    let action = config_actions::new_governance_update_action(
        option::some(5u64), // max_outcomes
        option::some(15u64), // max_actions_per_outcome
        option::some(604800000u64), // proposal_intent_expiry_ms (7 days)
        option::some(500u64), // proposal_creation_fee
        option::some(100u64), // proposal_fee_per_outcome
        option::some(true), // fee_in_asset_token
    );

    let (outcomes, actions, expiry, creation_fee, per_outcome_fee, fee_in_asset) =
        config_actions::get_governance_fields(&action);

    assert!(outcomes.is_some(), 0);
    assert!(actions.is_some(), 1);
    assert!(expiry.is_some(), 2);
    assert!(creation_fee.is_some(), 3);
    assert!(per_outcome_fee.is_some(), 4);
    assert!(fee_in_asset.is_some(), 5);

    destroy(action);
}

#[test]
/// Test governance update with minimal fields
fun test_governance_update_minimal() {
    let action = config_actions::new_governance_update_action(
        option::some(3u64), // max_outcomes (just YES/NO/ABSTAIN)
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::none(), // fee_in_asset_token
    );

    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
/// Test fails with max_outcomes < 2
fun test_governance_update_max_outcomes_too_low_fails() {
    let action = config_actions::new_governance_update_action(
        option::some(1u64), // < 2 (need at least YES/NO)
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::none(), // fee_in_asset_token
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_governance_update_max_outcomes_above_protocol_max_fails() {
    let action = config_actions::new_governance_update_action(
        option::some(futarchy_one_shot_utils::constants::protocol_max_outcomes() + 1),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_governance_update_max_actions_per_outcome_above_protocol_max_fails() {
    let action = config_actions::new_governance_update_action(
        option::none(),
        option::some(futarchy_one_shot_utils::constants::protocol_max_actions_per_outcome() + 1),
        option::none(),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_governance_update_intent_expiry_below_protocol_min_fails() {
    let action = config_actions::new_governance_update_action(
        option::none(),
        option::none(),
        option::some(futarchy_one_shot_utils::constants::min_proposal_intent_expiry_ms() - 1),
        option::none(),
        option::none(),
        option::none(),
    );
    destroy(action);
}

// test_governance_update_creation_fee_above_protocol_max_fails removed — creation fee cap is now u64::MAX

#[test]
#[expected_failure(abort_code = config_actions::EInvalidParameter)]
fun test_governance_update_fee_per_outcome_above_protocol_max_fails() {
    let action = config_actions::new_governance_update_action(
        option::none(),
        option::none(),
        option::none(),
        option::none(),
        option::some(futarchy_one_shot_utils::constants::max_proposal_fee_per_outcome() + 1),
        option::none(),
    );
    destroy(action);
}

// === MetadataTableUpdate Action Tests ===

#[test]
/// Test metadata table update with keys and values
fun test_metadata_table_update() {
    let keys = vector[string::utf8(b"website"), string::utf8(b"twitter"), string::utf8(b"discord")];
    let values = vector[
        string::utf8(b"https://example.com"),
        string::utf8(b"@example"),
        string::utf8(b"discord.gg/example"),
    ];
    let keys_to_remove = vector[string::utf8(b"old_link")];

    let action = config_actions::new_metadata_table_update_action(
        keys,
        values,
        keys_to_remove,
    );

    let (k, v, r) = config_actions::get_metadata_table_fields(&action);

    assert!(k.length() == 3, 0);
    assert!(v.length() == 3, 1);
    assert!(r.length() == 1, 2);

    destroy(action);
}

#[test]
#[expected_failure(abort_code = config_actions::EMismatchedKeyValueLength)]
/// Test fails with mismatched key/value lengths
fun test_metadata_table_length_mismatch_fails() {
    let keys = vector[string::utf8(b"website"), string::utf8(b"twitter")];
    let values = vector[
        string::utf8(b"https://example.com"),
        // missing second value
    ];

    let action = config_actions::new_metadata_table_update_action(
        keys,
        values,
        vector[],
    );
    destroy(action);
}

#[test]
/// Test with empty keys and values
fun test_metadata_table_empty() {
    let action = config_actions::new_metadata_table_update_action(
        vector[],
        vector[],
        vector[],
    );

    let (k, v, r) = config_actions::get_metadata_table_fields(&action);

    assert!(k.length() == 0, 0);
    assert!(v.length() == 0, 1);
    assert!(r.length() == 0, 2);

    destroy(action);
}

// === SponsorshipConfigUpdate Action Tests ===

#[test]
/// Test sponsorship config update with all fields
fun test_sponsorship_config_comprehensive() {
    let action = config_actions::new_sponsorship_config_update_action(
        option::some(true), // enabled
    );

    destroy(action);
}

#[test]
/// Test with disabled sponsorship
fun test_sponsorship_config_disabled() {
    let action = config_actions::new_sponsorship_config_update_action(
        option::some(false), // disabled
    );

    destroy(action);
}

// === Edge Cases ===

#[test]
/// Test with extreme u64 values
fun test_extreme_u64_values() {
    let max_u64 = 18446744073709551615u64;

    let action = config_actions::new_trading_params_update_action(
        option::some(max_u64), // min_asset_amount (>= protocol_min)
        option::some(max_u64), // min_stable_amount (>= protocol_min)
        option::some(futarchy_one_shot_utils::constants::max_trading_duration_ms()), // review_period_ms (at max)
        option::some(futarchy_one_shot_utils::constants::max_trading_duration_ms()), // trading_period_ms (at max)
        option::some(futarchy_one_shot_utils::constants::max_amm_fee_bps()),
        option::none(),
    );

    destroy(action);
}

#[test]
/// Test with extreme u128 values for TWAP
fun test_extreme_u128_values() {
    let max_u128 = 340282366920938463463374607431768211455u128;

    let action = config_actions::new_twap_config_update_action(
        option::none(),
        option::none(),
        option::some(max_u128), // initial_observation (any positive u128 is valid)
        option::some(futarchy_one_shot_utils::constants::twap_threshold_base()), // threshold at max
        option::some(5000u128), // sponsored_threshold at max (5%)
    );

    destroy(action);
}
