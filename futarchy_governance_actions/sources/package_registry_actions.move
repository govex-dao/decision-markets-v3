// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Unified package registry governance actions
/// Manages both package whitelisting AND action type declarations in a single system
///
/// SECURITY: All registry modifications require PackageAdminCap.
/// The cap is borrowed and returned internally within each do_* call,
/// preventing any PTB interleaving from ever holding the cap.
/// The cap must be locked in the admin DAO account during initialization.
module futarchy_governance_actions::package_registry_actions;

public struct ExecutionProgressWitness has drop {}

use account_actions::access_control;
use account_protocol::account::{Self as account, Account};
use account_protocol::bcs_validation;
use account_protocol::constants as account_constants;
use account_protocol::executable::{Self, Executable};
use account_protocol::intents;
use account_protocol::package_registry::{Self, PackageRegistry, PackageAdminCap};
use futarchy_one_shot_utils::constants;
use std::string::String;
use sui::bcs;
use sui::event;

// === Action Type Markers ===

public struct AddPackage has drop {}
public struct UpdatePackageMetadata has drop {}

public struct AddPackageAction has copy, drop, store {
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
}

public struct UpdatePackageMetadataAction has copy, drop, store {
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
}

// === Marker Functions ===
/// SECURITY: Package-private to prevent external code from obtaining drop-typed values
/// that could bypass package-witness authorization checks.

public(package) fun add_package_marker(): AddPackage { AddPackage {} }

public(package) fun update_package_metadata_marker(): UpdatePackageMetadata { UpdatePackageMetadata {} }

public fun new_add_package_action(
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
): AddPackageAction {
    AddPackageAction { name, addr, version, action_types, category, description }
}

public fun new_update_package_metadata_action(
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
): UpdatePackageMetadataAction {
    UpdatePackageMetadataAction { name, new_action_types, new_category, new_description }
}

// === Events ===

public struct GovernancePackageAdded has copy, drop {
    account_id: ID,
    name: String,
    addr: address,
    version: u64,
}

public struct GovernancePackageMetadataUpdated has copy, drop {
    account_id: ID,
    name: String,
}

// === Errors ===

const EUnsupportedActionVersion: u64 = 1;
const ETooManyActionTypes: u64 = 2;
const EMetadataStringTooLong: u64 = 3;

fun assert_metadata_string_len(value: &String) {
    assert!(
        value.length() <= account_constants::max_action_data_size(),
        EMetadataStringTooLong,
    );
}

fun assert_execution_authority<Outcome: store>(
    executable: &Executable<Outcome>,
    account: &Account,
    registry: &PackageRegistry,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );
}

// === Execution Functions ===
//
// SECURITY: Each function internally borrows the PackageAdminCap from the account,
// uses it, then returns it - all within a single function call.
// The cap is never exposed to the PTB caller.

/// Execute add package action.
/// Cap is borrowed and returned internally - never exposed to PTB.
public fun do_add_package<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _witness: IW,
    registry: &mut PackageRegistry,
) {
    assert_execution_authority(executable, account, registry);

    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<AddPackage>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);

    let name = bcs::peel_vec_u8(&mut reader).to_string();
    assert_metadata_string_len(&name);
    let addr = bcs::peel_address(&mut reader);
    let version = bcs::peel_u64(&mut reader);

    // Deserialize action type strings
    let action_types_count = bcs::peel_vec_length(&mut reader);
    assert!(action_types_count <= constants::max_package_registry_action_types(), ETooManyActionTypes);
    let mut action_types = vector::empty();
    let mut i = 0;
    while (i < action_types_count) {
        let action_type = bcs::peel_vec_u8(&mut reader).to_string();
        assert_metadata_string_len(&action_type);
        action_types.push_back(action_type);
        i = i + 1;
    };

    let category = bcs::peel_vec_u8(&mut reader).to_string();
    assert_metadata_string_len(&category);
    let description = bcs::peel_vec_u8(&mut reader).to_string();
    assert_metadata_string_len(&description);

    bcs_validation::validate_all_bytes_consumed(reader);

    // Borrow cap internally from account (uses safe governance-gated helper)
    let (cap, cap_receipt): (
        PackageAdminCap,
        access_control::CapReceipt<PackageAdminCap>,
    ) = access_control::remove_cap(account, registry, executable, ExecutionProgressWitness {});

    let cap = package_registry::add_package_with_cap(
        registry,
        cap,
        name,
        addr,
        version,
        action_types,
        category,
        description,
    );

    // Return cap to account
    access_control::return_cap(
        account,
        registry,
        cap,
        cap_receipt,
        executable,
        ExecutionProgressWitness {},
    );

    event::emit(GovernancePackageAdded {
        account_id: object::id(account),
        name,
        addr,
        version,
    });

    // MUST be last - after all managed asset operations that check current action
    executable::increment_action_idx<_, AddPackage, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute update package metadata action.
/// Cap is borrowed and returned internally - never exposed to PTB.
public fun do_update_package_metadata<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _witness: IW,
    registry: &mut PackageRegistry,
) {
    assert_execution_authority(executable, account, registry);

    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<UpdatePackageMetadata>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);

    let name = bcs::peel_vec_u8(&mut reader).to_string();
    assert_metadata_string_len(&name);

    // Deserialize action type strings
    let action_types_count = bcs::peel_vec_length(&mut reader);
    assert!(action_types_count <= constants::max_package_registry_action_types(), ETooManyActionTypes);
    let mut action_types = vector::empty();
    let mut i = 0;
    while (i < action_types_count) {
        let action_type = bcs::peel_vec_u8(&mut reader).to_string();
        assert_metadata_string_len(&action_type);
        action_types.push_back(action_type);
        i = i + 1;
    };

    let category = bcs::peel_vec_u8(&mut reader).to_string();
    assert_metadata_string_len(&category);
    let description = bcs::peel_vec_u8(&mut reader).to_string();
    assert_metadata_string_len(&description);

    bcs_validation::validate_all_bytes_consumed(reader);

    // Borrow cap internally from account (uses safe governance-gated helper)
    let (cap, cap_receipt): (
        PackageAdminCap,
        access_control::CapReceipt<PackageAdminCap>,
    ) = access_control::remove_cap(account, registry, executable, ExecutionProgressWitness {});

    let cap = package_registry::update_package_metadata_with_cap(
        registry,
        cap,
        name,
        action_types,
        category,
        description,
    );

    // Return cap to account
    access_control::return_cap(
        account,
        registry,
        cap,
        cap_receipt,
        executable,
        ExecutionProgressWitness {},
    );

    event::emit(GovernancePackageMetadataUpdated {
        account_id: object::id(account),
        name,
    });

    // MUST be last - after all managed asset operations that check current action
    executable::increment_action_idx<_, UpdatePackageMetadata, _>(executable, registry, ExecutionProgressWitness {});
}
