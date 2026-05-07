// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_governance_actions::intent_janitor_tests;

use account_protocol::account::{Self, Account};
use account_protocol::executable;
use account_protocol::intents;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use futarchy_core::dao_config::{Self, DaoConfig};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_governance_actions::futarchy_governance_actions_version as version;
use futarchy_governance_actions::governance_intents;
use futarchy_governance_actions::intent_janitor;
use futarchy_one_shot_utils::constants;
use std::ascii;
use std::string::{Self as string, String};
use sui::clock::{Self as clock, Clock};
use std::unit_test::destroy;
use sui::url;

public struct ASSET has key { id: UID }
public struct STABLE has key { id: UID }
public struct ReaddedIntentAction has drop {}
public struct ExecutionProgressWitness has drop {}

fun create_test_dao_config(): DaoConfig {
    let trading_params = dao_config::default_trading_params();
    let twap_config = dao_config::default_twap_config();
    let governance_config = dao_config::default_governance_config();
    let metadata_config = dao_config::new_metadata_config(
        ascii::string(b"JanitorDAO"),
        url::new_unsafe_from_bytes(b"https://janitor.dao/icon.png"),
        string::utf8(b"Intent janitor test config"),
    );
    let conditional_coin_config = dao_config::default_conditional_coin_config();
    let sponsorship_config = dao_config::default_sponsorship_config();
    dao_config::new_dao_config(
        trading_params,
        twap_config,
        governance_config,
        metadata_config,
        conditional_coin_config,
        sponsorship_config,
    )
}

fun setup_registry(ctx: &mut TxContext): PackageRegistry {
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_full_for_testing(
        &mut registry,
        string::utf8(b"FutarchyGovernanceActions"),
        @futarchy_governance_actions,
        1,
        vector[],
        string::utf8(b"orchestrator"),
        string::utf8(b"futarchy governance actions test package"),
    );
    registry
}

fun new_test_account(registry: &PackageRegistry, ctx: &mut TxContext): Account {
    let config: FutarchyConfig = futarchy_config::new<ASSET, STABLE>(
        create_test_dao_config(),
        option::none(),
    );
    futarchy_config::new_account_test(config, registry, ctx)
}

fun test_intent_key(): String {
    string::utf8(b"janitor_expired_intent")
}

fun register_one_scan_window_of_live_entries(
    account: &mut Account,
    registry: &PackageRegistry,
    expires_at: u64,
    ctx: &mut TxContext,
): u64 {
    let mut keys = vector[
        string::utf8(b"future_00"),
        string::utf8(b"future_01"),
        string::utf8(b"future_02"),
        string::utf8(b"future_03"),
        string::utf8(b"future_04"),
        string::utf8(b"future_05"),
        string::utf8(b"future_06"),
        string::utf8(b"future_07"),
        string::utf8(b"future_08"),
        string::utf8(b"future_09"),
        string::utf8(b"future_10"),
        string::utf8(b"future_11"),
        string::utf8(b"future_12"),
        string::utf8(b"future_13"),
        string::utf8(b"future_14"),
        string::utf8(b"future_15"),
        string::utf8(b"future_16"),
        string::utf8(b"future_17"),
        string::utf8(b"future_18"),
        string::utf8(b"future_19"),
    ];

    let count = keys.length();
    assert!(count == constants::max_cleanup_scan_per_call(), 10);

    while (!keys.is_empty()) {
        intent_janitor::register_intent<futarchy_config::FutarchyOutcome>(
            account,
            registry,
            keys.pop_back(),
            expires_at,
            ctx,
        );
    };

    count
}

#[test]
fun test_cleanup_expired_futarchy_intent_removes_intent() {
    let ctx = &mut tx_context::dummy();
    let registry = setup_registry(ctx);
    let mut account = new_test_account(&registry, ctx);
    let mut test_clock: Clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut test_clock, 1_000);

    let now = test_clock.timestamp_ms();
    let expires_at = now + 10;

    let params = intents::new_params(
        test_intent_key(),
        string::utf8(b"janitor cleanup test"),
        vector[now],
        expires_at,
        &test_clock,
        ctx,
    );

    let outcome = futarchy_config::new_futarchy_outcome(test_intent_key(), now);
    let intent = account::create_intent(
        &account,
        &registry,
        params,
        outcome,
        version::current(),
        governance_intents::witness(),
        ctx,
    );

    account::insert_intent_unshared(
        &mut account,
        &registry,
        intent,
        version::current(),
        governance_intents::witness(),
    );

    intent_janitor::register_intent<futarchy_config::FutarchyOutcome>(
        &mut account,
        &registry,
        test_intent_key(),
        expires_at,
        ctx,
    );

    assert!(intents::contains(account::intents(&account), test_intent_key()), 0);

    clock::increment_for_testing(&mut test_clock, 11);
    intent_janitor::cleanup_expired_futarchy_intents(
        &mut account,
        &registry,
        1,
        &test_clock,
        ctx,
    );

    assert!(!intents::contains(account::intents(&account), test_intent_key()), 1);

    transfer::public_transfer(account, @0xA);
    clock::destroy_for_testing(test_clock);
    destroy(registry);
}

#[test]
fun test_cleanup_without_index_does_not_initialize_janitor_state() {
    let ctx = &mut tx_context::dummy();
    let registry = setup_registry(ctx);
    let mut account = new_test_account(&registry, ctx);
    let test_clock: Clock = clock::create_for_testing(ctx);

    assert!(!intent_janitor::has_intent_index_for_testing(&account), 0);
    let (
        has_index,
        indexed_count,
        scan_position,
        cleanup_scan_limit,
        next_cleanup_expired_count,
        preview_expired_count,
        cleanup_calls_to_first_expired,
    ) = intent_janitor::janitor_cleanup_status(&account, &registry, &test_clock);
    assert!(!has_index, 2);
    assert!(indexed_count == 0, 3);
    assert!(scan_position == 0, 4);
    assert!(cleanup_scan_limit == constants::max_cleanup_scan_per_call(), 5);
    assert!(next_cleanup_expired_count == 0, 6);
    assert!(preview_expired_count == 0, 7);
    assert!(cleanup_calls_to_first_expired == 0, 8);

    intent_janitor::cleanup_expired_futarchy_intents(
        &mut account,
        &registry,
        1,
        &test_clock,
        ctx,
    );

    assert!(!intent_janitor::has_intent_index_for_testing(&account), 1);

    transfer::public_transfer(account, @0xA);
    clock::destroy_for_testing(test_clock);
    destroy(registry);
}

#[test, expected_failure(abort_code = 2, location = futarchy_governance_actions::intent_janitor)]
fun test_automatic_cleanup_enforces_cleanup_limit() {
    let ctx = &mut tx_context::dummy();
    let registry = setup_registry(ctx);
    let mut account = new_test_account(&registry, ctx);
    let test_clock: Clock = clock::create_for_testing(ctx);

    intent_janitor::cleanup_expired_intents_automatic(
        &mut account,
        &registry,
        constants::max_cleanup_per_call() + 1,
        &test_clock,
        ctx,
    );

    transfer::public_transfer(account, @0xA);
    clock::destroy_for_testing(test_clock);
    destroy(registry);
}

#[test]
fun test_cleanup_scan_budget_advances_without_deleting_past_window() {
    let ctx = &mut tx_context::dummy();
    let registry = setup_registry(ctx);
    let mut account = new_test_account(&registry, ctx);
    let mut test_clock: Clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut test_clock, 1_000);

    let now = test_clock.timestamp_ms();
    let live_expiry = now + 100_000;
    let expired_key = string::utf8(b"expired_after_live_scan_window");
    let expired_at = now + 10;

    register_one_scan_window_of_live_entries(&mut account, &registry, live_expiry, ctx);

    let params = intents::new_params(
        expired_key,
        string::utf8(b"janitor bounded scan regression"),
        vector[now],
        expired_at,
        &test_clock,
        ctx,
    );

    let outcome = futarchy_config::new_futarchy_outcome(expired_key, now);
    let intent = account::create_intent(
        &account,
        &registry,
        params,
        outcome,
        version::current(),
        governance_intents::witness(),
        ctx,
    );

    account::insert_intent_unshared(
        &mut account,
        &registry,
        intent,
        version::current(),
        governance_intents::witness(),
    );

    intent_janitor::register_intent<futarchy_config::FutarchyOutcome>(
        &mut account,
        &registry,
        expired_key,
        expired_at,
        ctx,
    );

    clock::increment_for_testing(&mut test_clock, 11);

    let (
        has_index,
        indexed_count,
        scan_position,
        cleanup_scan_limit,
        next_cleanup_expired_count,
        preview_expired_count,
        cleanup_calls_to_first_expired,
    ) = intent_janitor::janitor_cleanup_status(&account, &registry, &test_clock);
    assert!(has_index, 2);
    assert!(indexed_count == constants::max_cleanup_scan_per_call() + 1, 3);
    assert!(scan_position == 0, 4);
    assert!(cleanup_scan_limit == constants::max_cleanup_scan_per_call(), 5);
    assert!(next_cleanup_expired_count == 0, 6);
    assert!(preview_expired_count == 1, 7);
    assert!(cleanup_calls_to_first_expired == 2, 8);

    intent_janitor::cleanup_expired_futarchy_intents(
        &mut account,
        &registry,
        1,
        &test_clock,
        ctx,
    );

    assert!(intents::contains(account::intents(&account), expired_key), 0);

    let (
        has_index,
        indexed_count,
        scan_position,
        cleanup_scan_limit,
        next_cleanup_expired_count,
        preview_expired_count,
        cleanup_calls_to_first_expired,
    ) = intent_janitor::janitor_cleanup_status(&account, &registry, &test_clock);
    assert!(has_index, 9);
    assert!(indexed_count == constants::max_cleanup_scan_per_call() + 1, 10);
    assert!(scan_position == constants::max_cleanup_scan_per_call(), 11);
    assert!(cleanup_scan_limit == constants::max_cleanup_scan_per_call(), 12);
    assert!(next_cleanup_expired_count == 1, 13);
    assert!(preview_expired_count == 1, 14);
    assert!(cleanup_calls_to_first_expired == 1, 15);

    intent_janitor::cleanup_expired_futarchy_intents(
        &mut account,
        &registry,
        1,
        &test_clock,
        ctx,
    );

    assert!(!intents::contains(account::intents(&account), expired_key), 1);

    transfer::public_transfer(account, @0xA);
    clock::destroy_for_testing(test_clock);
    destroy(registry);
}

#[test]
fun test_cleanup_expired_futarchy_intent_after_create_executable_confirm_cycle() {
    let ctx = &mut tx_context::dummy();
    let registry = setup_registry(ctx);
    let mut account = new_test_account(&registry, ctx);
    let mut test_clock: Clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut test_clock, 1_000);

    let now = test_clock.timestamp_ms();
    let expires_at = now + 10;
    let key = string::utf8(b"janitor_readded_intent");

    let params = intents::new_params(
        key,
        string::utf8(b"janitor readd regression"),
        vector[now],
        expires_at,
        &test_clock,
        ctx,
    );

    let mut outcome = futarchy_config::new_futarchy_outcome(key, now);
    futarchy_config::set_outcome_approved(&mut outcome, true);
    let mut intent = account::create_intent(
        &account,
        &registry,
        params,
        outcome,
        version::current(),
        governance_intents::witness(),
        ctx,
    );
    intents::add_typed_action(
        &mut intent,
        ReaddedIntentAction {},
        vector[],
        governance_intents::witness(),
    );
    futarchy_config::stage_intent(
        &mut account,
        &registry,
        intent,
        version::current(),
        governance_intents::witness(),
    );

    intent_janitor::register_intent<futarchy_config::FutarchyOutcome>(
        &mut account,
        &registry,
        key,
        expires_at,
        ctx,
    );

    let (_outcome, mut executable_obj) = futarchy_config::create_futarchy_executable(
        &mut account,
        &registry,
        key,
        version::current(),
        &test_clock,
        ctx,
    );
    executable::increment_action_idx<
        futarchy_config::FutarchyOutcome,
        ReaddedIntentAction,
        ExecutionProgressWitness
    >(
        &mut executable_obj,
        &registry,
        ExecutionProgressWitness {},
    );
    account::confirm_execution(&mut account, executable_obj);

    assert!(intents::contains(account::intents(&account), key), 0);

    clock::increment_for_testing(&mut test_clock, 11);
    intent_janitor::cleanup_expired_futarchy_intents(
        &mut account,
        &registry,
        1,
        &test_clock,
        ctx,
    );

    assert!(!intents::contains(account::intents(&account), key), 1);

    transfer::public_transfer(account, @0xA);
    clock::destroy_for_testing(test_clock);
    destroy(registry);
}
