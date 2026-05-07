// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for oracle grant operations.
/// These can be staged in intents for proposals or launchpad initialization.
module futarchy_oracle::oracle_init_actions;

use account_actions::action_spec_builder;
use account_protocol::action_events;
use account_protocol::intents;
use futarchy_oracle::oracle_actions::{Self as oracle_actions, RecipientMint, TierSpec};
use futarchy_one_shot_utils::constants;
use std::string::String;
use std::type_name;
use sui::bcs;

// === Constants ===
const MAX_EXPIRY_YEARS: u64 = 10_000_000; // ~10M years, effectively no expiry
// Scaled by 1e12 (constants::price_precision_scale). 1_000_000x cap.
const MAX_RELATIVE_MULTIPLIER: u64 = 1_000_000_000_000_000_000;

// === Errors ===
const EEmptyTierSpecs: u64 = 1;
const EEmptyRecipients: u64 = 2;
const EZeroAmount: u64 = 3;
const ETooManyRecipients: u64 = 4;
const EExpiryTooLong: u64 = 5;
const ETooManyTiers: u64 = 6;
const EDuplicateRecipient: u64 = 7;
const EInvalidPriceThreshold: u64 = 8;
const EInvalidTwapWindow: u64 = 9;
const EInvalidExecutionOffset: u64 = 11;
const EInvalidRelativeMultiplier: u64 = 12;
const EInvalidExecutionWindow: u64 = 13;

// === Layer 2: Spec Builder Functions ===

/// Helper: Create a recipient mint allocation
public fun new_recipient_mint(recipient: address, amount: u64): RecipientMint {
    oracle_actions::new_recipient_mint(recipient, amount)
}

/// Helper: Create a tier specification
public fun new_tier_spec(
    price_threshold: u128,
    is_above: bool,
    recipients: vector<RecipientMint>,
    tier_description: String,
): TierSpec {
    oracle_actions::new_tier_spec(price_threshold, is_above, recipients, tier_description)
}

// === Getter Functions ===

/// Get recipient address from RecipientMint
public fun recipient_address(rm: &RecipientMint): address {
    oracle_actions::recipient_address(rm)
}

/// Get amount from RecipientMint
public fun recipient_amount(rm: &RecipientMint): u64 {
    oracle_actions::recipient_amount(rm)
}

/// Get price threshold from TierSpec
public fun tier_price_threshold(ts: &TierSpec): u128 {
    oracle_actions::tier_price_threshold(ts)
}

/// Get is_above flag from TierSpec
public fun tier_is_above(ts: &TierSpec): bool {
    oracle_actions::tier_is_above(ts)
}

/// Get recipients from TierSpec
public fun tier_recipients(ts: &TierSpec): &vector<RecipientMint> {
    oracle_actions::tier_recipients(ts)
}

/// Get description from TierSpec
public fun tier_description(ts: &TierSpec): &String {
    oracle_actions::tier_description(ts)
}

/// Add create oracle grant action to the spec builder
/// Creates a grant with N tiers, each with price conditions and recipient allocations
/// Performs early validation to fail fast before proposal submission
public fun add_create_oracle_grant_spec<AssetType, StableType>(
    builder: &mut action_spec_builder::Builder,
    mint_cap_resource_name: String,
    tier_specs: vector<TierSpec>,
    use_relative_pricing: bool,
    launchpad_multiplier: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    cancelable: bool,
    description: String,
    twap_window_ms: u64,
) {
    let action_index = action_spec_builder::next_action_index(builder);

    // Early validation to fail fast
    assert!(vector::length(&tier_specs) > 0, EEmptyTierSpecs);
    assert!(vector::length(&tier_specs) <= constants::max_oracle_tiers(), ETooManyTiers);
    assert!(expiry_years <= MAX_EXPIRY_YEARS, EExpiryTooLong);
    // 0 means immediate execution; positive offsets are bounded.
    assert!(earliest_execution_offset_ms <= constants::ten_years_ms(), EInvalidExecutionOffset);
    assert!(
        twap_window_ms >= constants::one_week_ms() && twap_window_ms <= constants::ninety_days_ms(),
        EInvalidTwapWindow,
    );
    if (use_relative_pricing) {
        assert!(launchpad_multiplier <= MAX_RELATIVE_MULTIPLIER, EInvalidRelativeMultiplier);
    };
    // Validate earliest_execution < expiry when both are set, to prevent proposals that
    // pass governance but abort at execution with EInvalidExecutionWindow
    if (earliest_execution_offset_ms > 0 && expiry_years > 0) {
        let expiry_ms = expiry_years * 365 * 24 * 60 * 60 * 1000;
        assert!(earliest_execution_offset_ms < expiry_ms, EInvalidExecutionWindow);
    };

    // Validate each tier's recipients
    let mut i = 0;
    while (i < vector::length(&tier_specs)) {
        let tier = vector::borrow(&tier_specs, i);
        let recipients = oracle_actions::tier_recipients(tier);
        assert!(vector::length(recipients) > 0, EEmptyRecipients);
        assert!(vector::length(recipients) <= constants::max_recipients_per_tier(), ETooManyRecipients);

        // Check no zero amounts and no duplicate recipients
        let mut seen_addrs = vector::empty<address>();
        let mut j = 0;
        while (j < vector::length(recipients)) {
            let rm = vector::borrow(recipients, j);
            assert!(oracle_actions::recipient_amount(rm) > 0, EZeroAmount);
            // Check for duplicate recipients
            let mut k = 0;
            while (k < vector::length(&seen_addrs)) {
                assert!(*vector::borrow(&seen_addrs, k) != oracle_actions::recipient_address(rm), EDuplicateRecipient);
                k = k + 1;
            };
            vector::push_back(&mut seen_addrs, oracle_actions::recipient_address(rm));
            j = j + 1;
        };

        // If is_above=false, threshold must be > 0 (price <= 0 is never true for unsigned)
        if (!oracle_actions::tier_is_above(tier)) {
            assert!(oracle_actions::tier_price_threshold(tier) > 0, EInvalidPriceThreshold);
        };
        if (use_relative_pricing) {
            assert!(
                oracle_actions::tier_price_threshold(tier) <= (MAX_RELATIVE_MULTIPLIER as u128),
                EInvalidPriceThreshold,
            );
            // SECURITY: Reject relative downside tiers where threshold < launchpad_multiplier.
            // In relative mode with launchpad enforcement, claim requires BOTH:
            //   price <= threshold (downside condition) AND price >= floor (launchpad minimum).
            // When threshold < floor, no price can satisfy both → funds permanently locked.
            if (!oracle_actions::tier_is_above(tier) && launchpad_multiplier > 0) {
                assert!(
                    oracle_actions::tier_price_threshold(tier) >= (launchpad_multiplier as u128),
                    EInvalidPriceThreshold,
                );
            };
        };

        i = i + 1;
    };

    let action = oracle_actions::new_create_oracle_grant<AssetType, StableType>(
        mint_cap_resource_name,
        tier_specs,
        use_relative_pricing,
        launchpad_multiplier,
        earliest_execution_offset_ms,
        expiry_years,
        cancelable,
        description,
        twap_window_ms,
    );
    let action_data = bcs::to_bytes(&action);
    // Asset and stable types encoded in marker to prevent type substitution
    let action_spec = intents::new_action_spec(
        oracle_actions::create_oracle_grant_marker<AssetType, StableType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    // Note: tier_specs is complex, we emit simplified params for indexer display
    let mut params = action_events::new_builder();
    action_events::add_string(&mut params, b"mint_cap_resource_name", mint_cap_resource_name);
    action_events::add_u64(&mut params, b"tier_count", vector::length(&tier_specs));
    action_events::add_bool(&mut params, b"use_relative_pricing", use_relative_pricing);
    action_events::add_u64(&mut params, b"launchpad_multiplier", launchpad_multiplier);
    action_events::add_u64(
        &mut params,
        b"earliest_execution_offset_ms",
        earliest_execution_offset_ms,
    );
    action_events::add_u64(&mut params, b"expiry_years", expiry_years);
    action_events::add_bool(&mut params, b"cancelable", cancelable);
    action_events::add_string(&mut params, b"description", description);
    action_events::add_u64(&mut params, b"twap_window_ms", twap_window_ms);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<
            futarchy_oracle::oracle_actions::CreateOracleGrant<AssetType, StableType>,
        >()
            .into_string()
            .to_string(),
        action_index,
    );
}

/// Add cancel grant action to the spec builder
/// Cancels an existing oracle grant (must be cancelable)
/// AssetType and StableType must match the grant's types
public fun add_cancel_grant_spec<AssetType, StableType>(
    builder: &mut action_spec_builder::Builder,
    grant_id: ID,
) {
    let action_index = action_spec_builder::next_action_index(builder);

    let action = oracle_actions::new_cancel_grant(grant_id);
    let action_data = bcs::to_bytes(&action);
    // Asset and stable types encoded in marker to prevent type substitution
    let action_spec = intents::new_action_spec(
        oracle_actions::cancel_grant_marker<AssetType, StableType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_id(&mut params, b"grant_id", grant_id);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_oracle::oracle_actions::CancelGrant<AssetType, StableType>>()
            .into_string()
            .to_string(),
        action_index,
    );
}
