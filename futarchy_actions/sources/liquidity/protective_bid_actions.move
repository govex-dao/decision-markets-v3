// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Protective Bid Actions for Governance
///
/// - CancelProtectiveBid: Cancel bid wall (funds stay in vault, cap is destroyed)
///
/// Flow:
/// 1. DAO passes proposal to cancel protective bid
/// 2. CancelProtectiveBid deactivates bid and destroys VaultAdminCap
/// 3. Funds remain in DAO vault (no fund movement needed)
/// 4. After deadline: anyone can close permissionlessly (same effect)
///
/// For creation, see protective_bid_init_actions.move

module futarchy_actions::protective_bid_actions;

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
use futarchy_markets_core::protective_bid::{Self, ProtectiveBid};
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::event;

// === Errors ===

const EUnsupportedActionVersion: u64 = 1;
const EWrongBid: u64 = 2;

// === Action Type Markers ===

/// Cancel protective bid action marker
public struct CancelProtectiveBid<phantom RaiseToken, phantom StableCoin> has drop {}

// === Events ===

public struct ProtectiveBidCancelledViaGovernance has copy, drop {
    bid_id: ID,
    account_id: ID,
    final_reserved_amount: u64,
    tokens_burned: u64,
}

// === Action Structs for Proposal System ===

/// Action data for cancelling a protective bid.
/// No fund movement — funds stay in vault, cap is destroyed.
public struct CancelProtectiveBidAction has copy, drop, store {
    /// ID of the protective bid to cancel
    bid_id: ID,
}

// === Spec Builders (for proposal PTB construction) ===

public fun add_cancel_protective_bid_spec<RaiseToken, StableCoin>(
    builder: &mut action_spec_builder::Builder,
    bid_id: ID,
) {
    let action_index = action_spec_builder::next_action_index(builder);

    let action = CancelProtectiveBidAction { bid_id };

    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        CancelProtectiveBid<RaiseToken, StableCoin> {},
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_id(&mut params, b"bid_id", bid_id);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<CancelProtectiveBid<RaiseToken, StableCoin>>().into_string().to_string(),
        action_index,
    );
}

// === Execution Functions (for Proposal System) ===

/// Execute cancel protective bid action from proposal.
/// Deactivates bid and destroys VaultAdminCap. Funds stay in vault.
public fun do_cancel_protective_bid<
    RaiseToken,
    StableCoin,
    Outcome: store,
    IW: drop,
>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    bid: &mut ProtectiveBid<RaiseToken, StableCoin>,
    _witness: IW,
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
    account_protocol::action_validation::assert_action_type<CancelProtectiveBid<RaiseToken, StableCoin>>(action_spec);

    // 3. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 4. Deserialize action
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let staged_bid_id = object::id_from_address(bcs::peel_address(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    // 5. Verify bid matches staged ID
    assert!(object::id(bid) == staged_bid_id, EWrongBid);

    // 6. Verify bid belongs to this account
    assert!(protective_bid::account_id(bid) == object::id(account), EWrongBid);

    // Capture state before cancel
    let final_reserved = protective_bid::reserved_amount(bid);
    let tokens_bought = protective_bid::base_bought_amount(bid);

    // 7. Create SpotPoolMutationAuth for authorized cancellation.
    let spot_auth = liquidity_actions::new_spot_pool_mutation_auth(spot_pool_mutation_registry, protective_bid::pool_id(bid));

    // 8. Cancel the bid — deactivates, destroys cap, clears registry.
    // No funds returned (they stay in vault).
    protective_bid::cancel<RaiseToken, StableCoin>(
        bid,
        account,
        registry,
        spot_auth,
    );

    // 9. Emit event
    event::emit(ProtectiveBidCancelledViaGovernance {
        bid_id: object::id(bid),
        account_id: object::id(account),
        final_reserved_amount: final_reserved,
        tokens_burned: tokens_bought,
    });

    // 10. Increment action index
    executable::increment_action_idx<_, CancelProtectiveBid<RaiseToken, StableCoin>, _>(executable, registry, ExecutionProgressWitness {});
}
