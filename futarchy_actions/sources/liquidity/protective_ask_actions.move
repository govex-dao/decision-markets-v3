// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Protective Ask Actions for Governance
///
/// This module provides governance-controlled actions for protective ask management:
/// - CancelProtectiveAsk: Cancel ask wall
///
/// Flow:
/// 1. DAO passes proposal to cancel protective ask
/// 2. Ask proceeds are already in treasury (deposited on each buy)
/// 3. After 90 days: anyone can close permissionlessly
module futarchy_actions::protective_ask_actions;

public struct ExecutionProgressWitness has drop {}

use account_actions::action_spec_builder;
use account_protocol::account::{Self as account_mod, Account};
use account_protocol::action_events;
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use futarchy_actions::liquidity_actions;
use futarchy_markets_core::spot_pool_mutation_auth::SpotPoolMutationRegistry;
use futarchy_markets_core::protective_ask::{Self, ProtectiveAsk};
use std::type_name;
use sui::bcs;
use sui::coin;
use sui::event;

// === Errors ===

const EUnsupportedActionVersion: u64 = 1;
const EWrongAsk: u64 = 2;

// === Action Type Markers ===
// Token types are encoded in the marker to prevent executor from changing types

/// Cancel protective ask action marker
public struct CancelProtectiveAsk<phantom RaiseToken, phantom StableCoin> has drop {}

// === Events ===

/// Emitted when a protective ask is cancelled via governance
public struct ProtectiveAskCancelledViaGovernance has copy, drop {
    ask_id: ID,
    account_id: ID,
    total_minted: u64,
}

// === Action Structs for Proposal System ===

/// Action data for cancelling a protective ask
public struct CancelProtectiveAskAction has copy, drop, store {
    /// ID of the protective ask to cancel
    ask_id: ID,
}

// === Spec Builders (for proposal PTB construction) ===

/// Add CancelProtectiveAskAction to Builder
public fun add_cancel_protective_ask_spec<RaiseToken, StableCoin>(
    builder: &mut action_spec_builder::Builder,
    ask_id: ID,
) {
    let action_index = action_spec_builder::next_action_index(builder);

    let action = CancelProtectiveAskAction { ask_id };
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        CancelProtectiveAsk<RaiseToken, StableCoin> {},
        action_data,
        1, // version 1
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_id(&mut params, b"ask_id", ask_id);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<CancelProtectiveAsk<RaiseToken, StableCoin>>().into_string().to_string(),
        action_index,
    );
}

// === Execution Functions (for Proposal System) ===

/// Execute cancel protective ask action from proposal
public fun do_cancel_protective_ask<
    RaiseToken,
    StableCoin,
    Outcome: store,
    IW: drop,
>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    ask: &mut ProtectiveAsk<RaiseToken, StableCoin>,
    _witness: IW,
    ctx: &mut TxContext,
) {
    // 1. Assert account ownership and current execution context.
    account_mod::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    // 2. Get current ActionSpec from Executable
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<CancelProtectiveAsk<RaiseToken, StableCoin>>(action_spec);

    // 4. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 5. Deserialize action
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let staged_ask_id = object::id_from_address(bcs::peel_address(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    // 6. Verify ask matches staged ID and DAO
    assert!(object::id(ask) == staged_ask_id, EWrongAsk);
    assert!(protective_ask::account_id(ask) == object::id(account), EWrongAsk);

    let total_minted = protective_ask::minted_amount(ask);

    // 7. Create SpotPoolMutationAuth for authorized cancellation.
    let spot_auth = liquidity_actions::new_spot_pool_mutation_auth(
        spot_pool_mutation_registry,
        protective_ask::pool_id(ask),
    );

    // 8. Cancel ask.
    let stable_coin = protective_ask::cancel<RaiseToken, StableCoin>(
        ask,
        account,
        registry,
        spot_auth,
        ctx,
    );
    coin::destroy_zero(stable_coin);

    // 9. Emit event
    event::emit(ProtectiveAskCancelledViaGovernance {
        ask_id: object::id(ask),
        account_id: object::id(account),
        total_minted,
    });

    // 10. Increment action index
    executable::increment_action_idx<_, CancelProtectiveAsk<RaiseToken, StableCoin>, _>(executable, registry, ExecutionProgressWitness {});
}
