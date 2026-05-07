// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Quota management action - set recurring proposal quotas for addresses
/// Registry is embedded in FutarchyConfig (accessed via config)
module futarchy_actions::quota_actions;

public struct ExecutionProgressWitness has drop {}

use account_protocol::account::{Self, Account};
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::intents as protocol_intents;
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::futarchy_config;
use std::vector;
use sui::bcs;
use sui::clock::Clock;
use sui::event;
use sui::object::{Self, ID};

// === Action Type Markers ===

/// Set quotas for addresses
public struct SetQuotas has drop {}

// === Marker Functions ===

public(package) fun set_quotas_marker(): SetQuotas { SetQuotas {} }

// === Events ===

public struct GovernanceQuotasSet has copy, drop {
    account_id: ID,
    num_users: u64,
    period_ms: u64,
    feeless_proposal_amount: u64,
    sponsor_amount: u64,
}

// === Errors ===
const EUnsupportedActionVersion: u64 = 0;
const EInvalidPeriod: u64 = 1;
const ENotActive: u64 = 2;

// === Structs ===

/// Action to set quotas for multiple addresses (batch operation)
/// Two independent quota types: feeless proposals and TWAP sponsorships
/// Set both amounts to 0 to remove quotas entirely
public struct SetQuotasAction has drop, store {
    /// Addresses to set quota for
    users: vector<address>,
    /// Shared period in milliseconds for both quota types (e.g., 30 days = 2_592_000_000)
    period_ms: u64,
    /// N FREE proposals per period (0 = no feeless quota)
    feeless_proposal_amount: u64,
    /// N TWAP sponsorships per period (0 = no sponsor quota)
    sponsor_amount: u64,
}

fun assert_dao_active(account: &Account) {
    let dao_state = futarchy_config::dao_state(
        account::config<futarchy_config::FutarchyConfig>(account),
    );
    assert!(
        futarchy_config::operational_state(dao_state) == futarchy_config::state_active(),
        ENotActive,
    );
}

// === Public Functions ===

/// Execute set quotas action
/// Registry is accessed via dynamic field on Account
public fun do_set_quotas<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    package_registry: &PackageRegistry,
    _intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    account::assert_execution_authorized(
        account,
        package_registry,
        executable,
        ExecutionProgressWitness {},
    );
    assert_dao_active(account);
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<SetQuotas>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize action manually
    let mut reader = bcs::new(*action_data);

    // Deserialize vector<address>
    let users_count = reader.peel_vec_length();
    let mut users = vector::empty<address>();
    let mut i = 0;
    while (i < users_count) {
        users.push_back(reader.peel_address());
        i = i + 1;
    };

    // Deserialize quota parameters
    let period_ms = reader.peel_u64();
    let feeless_proposal_amount = reader.peel_u64();
    let sponsor_amount = reader.peel_u64();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate period_ms (defense-in-depth, also checked downstream in registry)
    let is_removal = feeless_proposal_amount == 0 && sponsor_amount == 0;
    if (!is_removal) {
        assert!(period_ms > 0, EInvalidPeriod);
    };

    // Create action struct
    let action = SetQuotasAction {
        users,
        period_ms,
        feeless_proposal_amount,
        sponsor_amount,
    };

    let num_users = action.users.length();

    futarchy_config::set_quotas_from_execution(
        account,
        package_registry,
        executable,
        ExecutionProgressWitness {},
        action.users,
        action.period_ms,
        action.feeless_proposal_amount,
        action.sponsor_amount,
        clock,
    );

    event::emit(GovernanceQuotasSet {
        account_id: object::id(account),
        num_users,
        period_ms: action.period_ms,
        feeless_proposal_amount: action.feeless_proposal_amount,
        sponsor_amount: action.sponsor_amount,
    });

    // Increment action index
    executable::increment_action_idx<_, SetQuotas, _>(executable, package_registry, ExecutionProgressWitness {});
}

// === Constructor Functions ===

/// Create a set quotas action
/// period_ms: shared period for both quota types
/// feeless_proposal_amount: N free proposals per period (0 = no feeless quota)
/// sponsor_amount: N TWAP sponsorships per period (0 = no sponsor quota)
public fun new_set_quotas(
    users: vector<address>,
    period_ms: u64,
    feeless_proposal_amount: u64,
    sponsor_amount: u64,
): SetQuotasAction {
    let is_removal = feeless_proposal_amount == 0 && sponsor_amount == 0;
    if (!is_removal) {
        assert!(period_ms > 0, EInvalidPeriod);
    };
    SetQuotasAction {
        users,
        period_ms,
        feeless_proposal_amount,
        sponsor_amount,
    }
}

// === Getter Functions ===

public fun users(action: &SetQuotasAction): &vector<address> { &action.users }

public fun period_ms(action: &SetQuotasAction): u64 { action.period_ms }

public fun feeless_proposal_amount(action: &SetQuotasAction): u64 { action.feeless_proposal_amount }

public fun sponsor_amount(action: &SetQuotasAction): u64 { action.sponsor_amount }
