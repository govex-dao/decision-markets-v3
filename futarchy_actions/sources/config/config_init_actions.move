// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for configuration operations.
/// These can be staged in intents for proposals.
module futarchy_actions::futarchy_config_init_actions;

use account_actions::action_spec_builder;
use account_protocol::action_events;
use account_protocol::intents;
use futarchy_core::dao_config;
use std::ascii::String as AsciiString;
use std::option::Option;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::url::Url;

// === Layer 2: Spec Builder Functions ===

/// Add terminate DAO action to the spec builder
public fun add_terminate_dao_spec(
    builder: &mut action_spec_builder::Builder,
    reason: String,
    dissolution_unlock_delay_ms: u64,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::config_actions::new_terminate_dao_action(
        reason,
        dissolution_unlock_delay_ms,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::terminate_dao_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_string(&mut params, b"reason", reason);
    action_events::add_u64(
        &mut params,
        b"dissolution_unlock_delay_ms",
        dissolution_unlock_delay_ms,
    );
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::TerminateDao>().into_string().to_string(),
        action_index,
    );
}

/// Add update name action to the spec builder
public fun add_update_name_spec(builder: &mut action_spec_builder::Builder, new_name: String) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::config_actions::new_update_name_action(new_name);
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::update_name_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_string(&mut params, b"new_name", new_name);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::UpdateName>().into_string().to_string(),
        action_index,
    );
}

/// Add trading params update action to the spec builder
/// NOTE: asset_decimals and stable_decimals removed - decimals are immutable in Sui coins
public fun add_update_trading_params_spec(
    builder: &mut action_spec_builder::Builder,
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    amm_total_fee_bps: Option<u64>,
    conditional_liquidity_ratio_percent: Option<u64>,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::config_actions::new_trading_params_update_action(
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps,
        conditional_liquidity_ratio_percent,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::trading_params_update_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_option_u64(&mut params, b"min_asset_amount", min_asset_amount);
    action_events::add_option_u64(&mut params, b"min_stable_amount", min_stable_amount);
    action_events::add_option_u64(&mut params, b"review_period_ms", review_period_ms);
    action_events::add_option_u64(&mut params, b"trading_period_ms", trading_period_ms);
    action_events::add_option_u64(&mut params, b"amm_total_fee_bps", amm_total_fee_bps);
    action_events::add_option_u64(
        &mut params,
        b"conditional_liquidity_ratio_percent",
        conditional_liquidity_ratio_percent,
    );
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::TradingParamsUpdate>().into_string().to_string(),
        action_index,
    );
}

/// Add metadata update action to the spec builder
public fun add_update_metadata_spec(
    builder: &mut action_spec_builder::Builder,
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::config_actions::new_metadata_update_action(
        dao_name,
        icon_url,
        description,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::metadata_update_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    // Convert complex types to Option<String> for event emission
    let dao_name_str = if (dao_name.is_some()) {
        option::some(std::string::from_ascii(*dao_name.borrow()))
    } else {
        option::none()
    };
    let icon_url_str = if (icon_url.is_some()) {
        option::some(std::string::from_ascii(icon_url.borrow().inner_url()))
    } else {
        option::none()
    };
    let mut params = action_events::new_builder();
    action_events::add_option_string(&mut params, b"dao_name", &dao_name_str);
    action_events::add_option_string(&mut params, b"icon_url", &icon_url_str);
    action_events::add_option_string(&mut params, b"description", &description);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::MetadataUpdate>().into_string().to_string(),
        action_index,
    );
}

/// Add TWAP config update action to the spec builder
public fun add_update_twap_config_spec(
    builder: &mut action_spec_builder::Builder,
    start_delay: Option<u64>,
    cap_ppm: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u128>,
    sponsored_threshold: Option<u128>,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::config_actions::new_twap_config_update_action(
        start_delay,
        cap_ppm,
        initial_observation,
        threshold,
        sponsored_threshold,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::twap_config_update_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_option_u64(&mut params, b"start_delay", start_delay);
    action_events::add_option_u64(&mut params, b"cap_ppm", cap_ppm);
    action_events::add_option_u128(&mut params, b"initial_observation", initial_observation);
    action_events::add_option_u128(&mut params, b"threshold", threshold);
    action_events::add_option_u128(&mut params, b"sponsored_threshold", sponsored_threshold);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::TwapConfigUpdate>().into_string().to_string(),
        action_index,
    );
}

/// Add governance update action to the spec builder
public fun add_update_governance_spec(
    builder: &mut action_spec_builder::Builder,
    max_outcomes: Option<u64>,
    max_actions_per_outcome: Option<u64>,
    proposal_intent_expiry_ms: Option<u64>,
    proposal_creation_fee: Option<u64>,
    proposal_fee_per_outcome: Option<u64>,
    fee_in_asset_token: Option<bool>,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::config_actions::new_governance_update_action(
        max_outcomes,
        max_actions_per_outcome,
        proposal_intent_expiry_ms,
        proposal_creation_fee,
        proposal_fee_per_outcome,
        fee_in_asset_token,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::governance_update_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_option_u64(&mut params, b"max_outcomes", max_outcomes);
    action_events::add_option_u64(&mut params, b"max_actions_per_outcome", max_actions_per_outcome);
    action_events::add_option_u64(
        &mut params,
        b"proposal_intent_expiry_ms",
        proposal_intent_expiry_ms,
    );
    action_events::add_option_u64(&mut params, b"proposal_creation_fee", proposal_creation_fee);
    action_events::add_option_u64(
        &mut params,
        b"proposal_fee_per_outcome",
        proposal_fee_per_outcome,
    );
    action_events::add_option_bool(&mut params, b"fee_in_asset_token", fee_in_asset_token);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::GovernanceUpdate>().into_string().to_string(),
        action_index,
    );
}

/// Add metadata table update action to the spec builder
public fun add_update_metadata_table_spec(
    builder: &mut action_spec_builder::Builder,
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::config_actions::new_metadata_table_update_action(
        keys,
        values,
        keys_to_remove,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::metadata_table_update_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_vector_string(&mut params, b"keys", &keys);
    action_events::add_vector_string(&mut params, b"values", &values);
    action_events::add_vector_string(&mut params, b"keys_to_remove", &keys_to_remove);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::MetadataTableUpdate>().into_string().to_string(),
        action_index,
    );
}

/// Add conditional metadata update action to the spec builder
public fun add_update_conditional_metadata_spec(
    builder: &mut action_spec_builder::Builder,
    use_outcome_index: Option<bool>,
    conditional_metadata: Option<Option<dao_config::ConditionalMetadata>>,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::config_actions::new_conditional_metadata_update_action(
        use_outcome_index,
        conditional_metadata,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::update_conditional_metadata_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    // For conditional_metadata, we emit whether it's being set/cleared (complex struct details in BCS)
    let conditional_metadata_str = if (conditional_metadata.is_some()) {
        let inner = conditional_metadata.borrow();
        if (inner.is_some()) {
            option::some(std::string::utf8(b"<ConditionalMetadata>"))
        } else {
            option::some(std::string::utf8(b"null"))
        }
    } else {
        option::none()
    };
    let mut params = action_events::new_builder();
    action_events::add_option_bool(&mut params, b"use_outcome_index", use_outcome_index);
    action_events::add_option_string(
        &mut params,
        b"conditional_metadata",
        &conditional_metadata_str,
    );
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::UpdateConditionalMetadata>().into_string().to_string(),
        action_index,
    );
}

/// Add sponsorship config update action to the spec builder
public fun add_update_sponsorship_config_spec(
    builder: &mut action_spec_builder::Builder,
    enabled: Option<bool>,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::config_actions::new_sponsorship_config_update_action(enabled);
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::sponsorship_config_update_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_option_bool(&mut params, b"enabled", enabled);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::SponsorshipConfigUpdate>().into_string().to_string(),
        action_index,
    );
}

/// Add sync TWAP observation from proposal action to the spec builder
/// This action syncs the amm_twap_initial_observation to the winning outcome's TWAP
/// Use when a proposal passes to update the TWAP base to reflect market-discovered price
public fun add_sync_twap_observation_from_proposal_spec(
    builder: &mut action_spec_builder::Builder,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    // Empty action struct - all info comes from reading proposal TWAP at execution time
    let action = futarchy_actions::config_actions::new_sync_twap_observation_action();
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::config_actions::sync_twap_observation_from_proposal_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event (no parameters to emit)
    let params = action_events::new_builder();
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::config_actions::SyncTwapObservationFromProposal>().into_string().to_string(),
        action_index,
    );
}
