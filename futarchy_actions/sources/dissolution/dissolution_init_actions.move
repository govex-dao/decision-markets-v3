// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for dissolution operations.
/// These can be staged in intents for proposals.
module futarchy_actions::dissolution_init_actions;

use account_actions::action_spec_builder;
use account_protocol::action_events;
use account_protocol::intents;
use std::type_name;
use sui::bcs;

// === Errors ===
const EEmptyResourceName: u64 = 1;
const EDuplicateResourceName: u64 = 2;

// === Layer 2: Spec Builder Functions ===

/// Add create dissolution capability action to the spec builder
/// Can be bundled with termination proposal for atomic dissolution setup
/// AssetType must match the DAO's asset type
public fun add_create_dissolution_capability_spec<AssetType>(
    builder: &mut action_spec_builder::Builder,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action_data = vector::empty();
    // AssetType encoded in marker to prevent type substitution
    let action_spec = intents::new_action_spec(
        futarchy_actions::dissolution_actions::create_dissolution_capability_marker<AssetType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    // No parameters for this action - struct is empty
    let params = action_events::new_builder();
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::dissolution_actions::CreateDissolutionCapability<AssetType>>().into_string().to_string(),
        action_index,
    );
}

/// Add create dissolution capability action to the spec builder, but do NOT share it.
///
/// This is intended for single-PTB termination + liquidation flows where the
/// capability must be passed by reference to later actions before sharing.
public fun add_create_dissolution_capability_unshared_spec<AssetType>(
    builder: &mut action_spec_builder::Builder,
) {
    let action_index = action_spec_builder::next_action_index(builder);

    let action_data = vector::empty();
    let action_spec = intents::new_action_spec(
        futarchy_actions::dissolution_actions::create_dissolution_capability_unshared_marker<AssetType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event (no params)
    let params = action_events::new_builder();
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<
            futarchy_actions::dissolution_actions::CreateDissolutionCapabilityUnshared<AssetType>,
        >().into_string().to_string(),
        action_index,
    );
}

/// Add share dissolution capability action to the spec builder.
///
/// Consumes an owned DissolutionCapability argument at execution time and shares it.
public fun add_share_dissolution_capability_spec(
    builder: &mut action_spec_builder::Builder,
) {
    let action_index = action_spec_builder::next_action_index(builder);

    let action_data = vector::empty();
    let action_spec = intents::new_action_spec(
        futarchy_actions::dissolution_actions::share_dissolution_capability_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event (no params)
    let params = action_events::new_builder();
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::dissolution_actions::ShareDissolutionCapability>()
            .into_string().to_string(),
        action_index,
    );
}

/// Add create redemption pool action to the spec builder
/// Requires prior VaultSpend/RemoveLiquidityToResources actions to put coins in resources
/// RedeemCoinType must match the coin type being redeemed
/// resource_names: names of all stable coin resources to merge into the pool
public fun add_create_redemption_pool_spec<RedeemCoinType>(
    builder: &mut action_spec_builder::Builder,
    capability_id: ID,
    resource_names: vector<std::string::String>,
) {
    validate_resource_names(&resource_names);

    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::dissolution_actions::new_create_redemption_pool(
        capability_id,
        resource_names,
    );
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        futarchy_actions::dissolution_actions::create_redemption_pool_marker<RedeemCoinType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_id(&mut params, b"capability_id", capability_id);
    action_events::add_vector_string(&mut params, b"resource_names", &resource_names);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::dissolution_actions::CreateRedemptionPool<RedeemCoinType>>().into_string().to_string(),
        action_index,
    );
}

/// Add create redemption pool action for a capability created earlier in the
/// same PTB. Its capability ID is unavailable at staging time, so execution must
/// pass the UnsharedDissolutionCapabilityTicket returned by capability creation.
public fun add_create_redemption_pool_from_unshared_capability_spec<RedeemCoinType>(
    builder: &mut action_spec_builder::Builder,
    resource_names: vector<std::string::String>,
) {
    validate_resource_names(&resource_names);

    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::dissolution_actions::new_create_redemption_pool_from_unshared_capability(
        resource_names,
    );
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        futarchy_actions::dissolution_actions::create_redemption_pool_marker<RedeemCoinType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_vector_string(&mut params, b"resource_names", &resource_names);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::dissolution_actions::CreateRedemptionPool<RedeemCoinType>>().into_string().to_string(),
        action_index,
    );
}

fun validate_resource_names(resource_names: &vector<std::string::String>) {
    assert!(resource_names.length() > 0);
    let mut i = 0;
    while (i < resource_names.length()) {
        assert!(resource_names[i].length() > 0, EEmptyResourceName);
        let mut j = i + 1;
        while (j < resource_names.length()) {
            assert!(resource_names[i] != resource_names[j], EDuplicateResourceName);
            j = j + 1;
        };
        i = i + 1;
    };
}

/// Add to existing redemption pool action
public fun add_add_to_redemption_pool_spec<RedeemCoinType>(
    builder: &mut action_spec_builder::Builder,
    resource_name: std::string::String,
    pool_id: ID,
) {
    assert!(resource_name.length() > 0, EEmptyResourceName);

    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::dissolution_actions::new_add_to_redemption_pool(resource_name, pool_id);
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        futarchy_actions::dissolution_actions::add_to_redemption_pool_marker<RedeemCoinType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_string(&mut params, b"resource_name", resource_name);
    action_events::add_id(&mut params, b"pool_id", pool_id);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::dissolution_actions::AddToRedemptionPool<RedeemCoinType>>().into_string().to_string(),
        action_index,
    );
}
