// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for package registry operations.
/// These can be staged in intents for proposals.
module futarchy_governance_actions::package_registry_init_actions;

use account_actions::action_spec_builder;
use account_protocol::action_events;
use account_protocol::constants as account_constants;
use account_protocol::intents;
use futarchy_one_shot_utils::constants;
use std::string::String;
use std::type_name;
use sui::bcs;

// === Errors ===

const ETooManyActionTypes: u64 = 1;
const EMetadataStringTooLong: u64 = 2;

fun assert_metadata_string_len(value: &String) {
    assert!(
        value.length() <= account_constants::max_action_data_size(),
        EMetadataStringTooLong,
    );
}

fun assert_action_types_len(action_types: &vector<String>) {
    assert!(
        action_types.length() <= constants::max_package_registry_action_types(),
        ETooManyActionTypes,
    );

    let mut i = 0;
    let len = action_types.length();
    while (i < len) {
        assert_metadata_string_len(action_types.borrow(i));
        i = i + 1;
    };
}

// === Layer 2: Spec Builder Functions ===

/// Add an add package action to the spec builder
public fun add_add_package_spec(
    builder: &mut action_spec_builder::Builder,
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
) {
    assert_metadata_string_len(&name);
    assert_action_types_len(&action_types);
    assert_metadata_string_len(&category);
    assert_metadata_string_len(&description);

    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_governance_actions::package_registry_actions::new_add_package_action(
        name,
        addr,
        version,
        action_types,
        category,
        description,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_governance_actions::package_registry_actions::add_package_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event (BCS order: name, addr, version, action_types, category, description)
    let mut params = action_events::new_builder();
    action_events::add_string(&mut params, b"name", name);
    action_events::add_address(&mut params, b"addr", addr);
    action_events::add_u64(&mut params, b"version", version);
    action_events::add_vector_string(&mut params, b"action_types", &action_types);
    action_events::add_string(&mut params, b"category", category);
    action_events::add_string(&mut params, b"description", description);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_governance_actions::package_registry_actions::AddPackage>()
            .into_string()
            .to_string(),
        action_index,
    );
}

/// Add an update package metadata action to the spec builder
public fun add_update_package_metadata_spec(
    builder: &mut action_spec_builder::Builder,
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
) {
    assert_metadata_string_len(&name);
    assert_action_types_len(&new_action_types);
    assert_metadata_string_len(&new_category);
    assert_metadata_string_len(&new_description);

    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_governance_actions::package_registry_actions::new_update_package_metadata_action(
        name,
        new_action_types,
        new_category,
        new_description,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_governance_actions::package_registry_actions::update_package_metadata_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event (BCS order: name, new_action_types, new_category, new_description)
    let mut params = action_events::new_builder();
    action_events::add_string(&mut params, b"name", name);
    action_events::add_vector_string(&mut params, b"new_action_types", &new_action_types);
    action_events::add_string(&mut params, b"new_category", new_category);
    action_events::add_string(&mut params, b"new_description", new_description);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<
            futarchy_governance_actions::package_registry_actions::UpdatePackageMetadata,
        >()
            .into_string()
            .to_string(),
        action_index,
    );
}
