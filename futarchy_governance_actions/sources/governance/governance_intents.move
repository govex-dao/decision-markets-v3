// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Governance module for creating and executing intents from approved proposals
/// This module provides a simplified interface for governance operations
module futarchy_governance_actions::governance_intents;

use account_protocol::account::{Self, Account};
use account_protocol::executable::Executable;
use account_protocol::intents::{Self, ActionSpec};
use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use account_protocol::version_witness::{Self, VersionWitness};
use futarchy_core::dao_config;
use futarchy_core::futarchy_config::{Self, FutarchyConfig, FutarchyOutcome};
use futarchy_governance_actions::futarchy_governance_actions_version as version;
use futarchy_core::proposal_mutation_auth::{Self, ProposalMutationRegistry};
use futarchy_governance_actions::intent_janitor;
use futarchy_proposal::proposal::{Self, Proposal};
use std::string::String;
use sui::clock::Clock;

// === Errors ===
const EIntentNotFound: u64 = 4;
const EEmptyActionSpecs: u64 = 5;
const EProposalDaoMismatch: u64 = 6;
const EInvalidProposalState: u64 = 7;
const EWinningOutcomeNotSet: u64 = 8;
const EOutcomeMismatch: u64 = 9;
const EOutcomeProposalMismatch: u64 = 10;
const EOutcomeMarketMismatch: u64 = 11;
const EOutcomeNotApproved: u64 = 12;
const EUnauthorizedTicketConsumer: u64 = 13;
const EProposalTicketMismatch: u64 = 14;

// === Witness ===
/// Single witness for governance intents
public struct GovernanceWitness has copy, drop {}

/// Module-local hot potato forcing callers through consume_governance_execution_ticket().
/// Prevents standalone callers of execute_proposal_intent() from silently
/// bypassing ptb_executor's finalization (fee refund, event emission, cleanup).
public struct GovernanceExecutionTicket {
    proposal_id: ID,
}

/// Get the governance witness.
/// SECURITY: Package-private to prevent external PTBs from minting an
/// authorized ProposalMutation witness.
public(package) fun witness(): GovernanceWitness {
    GovernanceWitness {}
}

// === Execution Functions ===

/// Execute a governance intent from an approved proposal
/// This creates an Intent just-in-time from the stored IntentSpec blueprint
/// and immediately converts it to an executable for execution
/// Returns the executable hot potato for action execution, plus a
/// GovernanceExecutionTicket that must be consumed via
/// consume_governance_execution_ticket()
public fun execute_proposal_intent<AssetType, StableType>(
    account: &mut Account,
    registry: &PackageRegistry,
    mutation_registry: &ProposalMutationRegistry,
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    outcome: FutarchyOutcome,
    clock: &Clock,
    ctx: &mut TxContext,
): (Executable<FutarchyOutcome>, GovernanceExecutionTicket) {
    let proposal_id = proposal::get_id(proposal);
    let market_id = proposal::market_state_id(proposal);
    let dao_id = object::id(account);

    // Defense in depth: this API is public, so it must enforce the same
    // proposal/account binding and lifecycle constraints as the PTB executor.
    assert!(proposal::get_dao_id(proposal) == dao_id, EProposalDaoMismatch);
    assert!(proposal::get_state(proposal) == proposal::state_finalized(), EInvalidProposalState);
    assert!(proposal::is_winning_outcome_set(proposal), EWinningOutcomeNotSet);
    assert!(proposal::get_winning_outcome(proposal) == outcome_index, EOutcomeMismatch);

    // Ensure caller-provided outcome metadata is bound to this finalized proposal.
    let outcome_proposal_id = futarchy_config::outcome_proposal_id(&outcome);
    let outcome_market_id = futarchy_config::outcome_market_id(&outcome);
    assert!(
        option::is_some(&outcome_proposal_id) && *option::borrow(&outcome_proposal_id) == proposal_id,
        EOutcomeProposalMismatch,
    );
    assert!(
        option::is_some(&outcome_market_id) && *option::borrow(&outcome_market_id) == market_id,
        EOutcomeMarketMismatch,
    );
    assert!(futarchy_config::outcome_approved(&outcome), EOutcomeNotApproved);

    // Create ProposalMutationAuth for taking intent spec
    let auth = proposal_mutation_auth::create(mutation_registry, GovernanceWitness {}, object::id(proposal));

    // Get the intent spec from the proposal for the specified outcome
    let mut intent_spec_opt = proposal::take_intent_spec_for_outcome(proposal, outcome_index, &auth);

    // Extract the intent spec - if no spec exists, this indicates no action was defined for this outcome
    assert!(option::is_some(&intent_spec_opt), EIntentNotFound);
    let intent_spec = option::extract(&mut intent_spec_opt);
    option::destroy_none(intent_spec_opt);

    // Get intent expiry from DAO config (instead of hardcoded value)
    let config: &FutarchyConfig = account::config(account);
    let dao_cfg = futarchy_config::dao_config(config);
    let gov_cfg = dao_config::governance_config(dao_cfg);
    let intent_expiry_ms = dao_config::proposal_intent_expiry_ms(gov_cfg);

    // Create and store Intent temporarily, then immediately create Executable
    let intent_key = create_and_store_intent_from_spec(
        account,
        registry,
        intent_spec,
        outcome,
        intent_expiry_ms,
        clock,
        ctx,
    );

    // Now create the executable from the stored intent
    // Uses wrapper function that keeps ConfigWitness private to the config module
    let (_, executable) = futarchy_config::create_futarchy_executable(
        account,
        registry,
        intent_key,
        version::current(),
        clock,
        ctx,
    );

    // NOTE: Do NOT unregister from janitor here. create_executable removes the
    // intent from account storage, but confirm_execution re-adds it. Without
    // a janitor entry, the re-added intent becomes an untracked zombie that
    // causes unbounded storage growth. Let the janitor clean it up on expiry.

    let ticket = GovernanceExecutionTicket { proposal_id };
    (executable, ticket)
}

/// Consume the governance execution ticket.
/// Must be called after execute_proposal_intent() to complete the execution flow.
public fun consume_governance_execution_ticket(
    ticket: GovernanceExecutionTicket,
    registry: &PackageRegistry,
    mutation_registry: &ProposalMutationRegistry,
    caller_witness: VersionWitness,
    expected_proposal_id: ID,
) {
    let caller_pkg_addr = version_witness::package_addr(&caller_witness);
    assert!(package_registry::contains_package_addr(registry, caller_pkg_addr), EUnauthorizedTicketConsumer);
    // The mutation registry is the explicit allowlist for packages allowed to
    // drive proposal state.
    assert!(
        proposal_mutation_auth::is_authorized_package(mutation_registry, caller_pkg_addr),
        EUnauthorizedTicketConsumer,
    );
    let caller_pkg_name = package_registry::get_package_name(registry, caller_pkg_addr);
    assert!(caller_pkg_name == b"FutarchyGovernance".to_string(), EUnauthorizedTicketConsumer);
    let GovernanceExecutionTicket { proposal_id } = ticket;
    assert!(proposal_id == expected_proposal_id, EProposalTicketMismatch);
}

// === Helper Functions ===

/// Create and store an Intent from a vector of ActionSpecs
/// Returns the intent key for immediate execution
/// `intent_expiry_ms` - Duration in milliseconds before intent expires (read from DAO config)
fun create_and_store_intent_from_spec(
    account: &mut Account,
    registry: &PackageRegistry,
    specs: vector<ActionSpec>,
    outcome: FutarchyOutcome,
    intent_expiry_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): String {
    assert!(!specs.is_empty(), EEmptyActionSpecs);

    // Generate a guaranteed-unique key using Sui's native ID generation
    // This ensures uniqueness even when multiple proposals execute in the same block
    let intent_key = ctx.fresh_object_address().to_string();

    // Calculate expiration time from configurable duration
    let expiration_time = clock.timestamp_ms() + intent_expiry_ms;

    // Create intent parameters with immediate execution
    let params = intents::new_params(
        intent_key,
        b"Just-in-time Proposal Execution".to_string(),
        vector[clock.timestamp_ms()], // Execute immediately
        expiration_time,
        clock,
        ctx,
    );

    // Create the intent using the account module
    let mut intent = account::create_intent(
        account,
        registry,
        params,
        outcome,
        version::current(),
        witness(),
        ctx,
    );

    // Add all action specs to the intent (preserves version)
    let mut i = 0;
    while (i < specs.length()) {
        intents::add_existing_action_spec(&mut intent, specs[i], witness());
        i = i + 1;
    };

    // Store the intent in the account through the config module gate.
    futarchy_config::stage_intent(account, registry, intent, version::current(), witness());

    // Register the intent with the janitor for tracking and cleanup
    intent_janitor::register_intent<futarchy_config::FutarchyOutcome>(
        account,
        registry,
        intent_key,
        expiration_time,
        ctx,
    );

    intent_key
}

#[test]
fun test_consume_governance_execution_ticket_accepts_exact_package_name() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    let mut mutation_registry = proposal_mutation_auth::new_registry_for_testing(ctx);
    let mutation_cap = proposal_mutation_auth::new_admin_cap_for_testing(object::id(&mutation_registry), ctx);
    let caller_pkg_addr = @0x600D;
    let proposal_id = object::id_from_address(@0xA11CE);

    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyGovernance".to_string(),
        caller_pkg_addr,
        1,
    );
    proposal_mutation_auth::add_authorized_package(&mut mutation_registry, &mutation_cap, caller_pkg_addr);

    consume_governance_execution_ticket(
        GovernanceExecutionTicket { proposal_id },
        &registry,
        &mutation_registry,
        version_witness::new_for_testing(caller_pkg_addr),
        proposal_id,
    );

    proposal_mutation_auth::destroy_admin_cap_for_testing(mutation_cap);
    proposal_mutation_auth::destroy_registry_for_testing(mutation_registry);
    std::unit_test::destroy(registry);
}

/// The ProposalMutationRegistry is the second half of the dual-check gating
/// proposal state mutation. Even a package that is registered in the global
/// PackageRegistry under the exact name "FutarchyGovernance" must be absent
/// from the mutation allowlist if the DAO has not opted it in — consuming a
/// ticket must then abort.
#[test]
#[expected_failure(abort_code = EUnauthorizedTicketConsumer)]
fun test_consume_governance_execution_ticket_rejects_package_absent_from_mutation_registry() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    let mutation_registry = proposal_mutation_auth::new_registry_for_testing(ctx);
    let caller_pkg_addr = @0x600D;
    let proposal_id = object::id_from_address(@0xA11CE);

    // Name + global registry match — but intentionally do NOT add to
    // mutation_registry. The dual-check must catch this.
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyGovernance".to_string(),
        caller_pkg_addr,
        1,
    );

    consume_governance_execution_ticket(
        GovernanceExecutionTicket { proposal_id },
        &registry,
        &mutation_registry,
        version_witness::new_for_testing(caller_pkg_addr),
        proposal_id,
    );

    proposal_mutation_auth::destroy_registry_for_testing(mutation_registry);
    std::unit_test::destroy(registry);
}

#[test]
#[expected_failure(abort_code = EUnauthorizedTicketConsumer)]
fun test_consume_governance_execution_ticket_rejects_lowercase_package_name() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    let mut mutation_registry = proposal_mutation_auth::new_registry_for_testing(ctx);
    let mutation_cap = proposal_mutation_auth::new_admin_cap_for_testing(object::id(&mutation_registry), ctx);
    let caller_pkg_addr = @0x600D;
    let proposal_id = object::id_from_address(@0xA11CE);

    package_registry::add_for_testing(
        &mut registry,
        b"futarchy_governance".to_string(),
        caller_pkg_addr,
        1,
    );
    proposal_mutation_auth::add_authorized_package(&mut mutation_registry, &mutation_cap, caller_pkg_addr);

    consume_governance_execution_ticket(
        GovernanceExecutionTicket { proposal_id },
        &registry,
        &mutation_registry,
        version_witness::new_for_testing(caller_pkg_addr),
        proposal_id,
    );

    proposal_mutation_auth::destroy_admin_cap_for_testing(mutation_cap);
    proposal_mutation_auth::destroy_registry_for_testing(mutation_registry);
    std::unit_test::destroy(registry);
}
