// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Protective Ask Registry - Enforce Max Active Ask Walls Per DAO
///
/// We store a vector of active ask records as managed data on the DAO `Account`,
/// capped at `constants::max_protective_asks_per_dao()`.
module futarchy_markets_core::protective_ask_registry;

use account_protocol::account::{Self as account, Account};
use account_protocol::executable::{Self as executable_mod, Executable};
use account_protocol::package_registry::PackageRegistry;
use futarchy_markets_core::markets_core_version as version;
use futarchy_one_shot_utils::constants;

// === Errors ===

const EProtectiveAskCapReached: u64 = 1;
const EExecutableAccountMismatch: u64 = 2;

// === Types ===

/// Key for Account managed-data.
public struct ProtectiveAskKey has copy, drop, store {}

/// Container stored on the DAO Account as managed data.
public struct ProtectiveAskRegistry has copy, drop, store {
    records: vector<ProtectiveAskRecord>,
}

/// Individual ask record.
public struct ProtectiveAskRecord has copy, drop, store {
    ask_id: ID,
    pool_id: ID,
}

// === View ===

public fun has_registry(account: &Account): bool {
    account::has_managed_data(account, ProtectiveAskKey {})
}

public fun ask_count(account: &Account, registry: &PackageRegistry): u64 {
    if (!has_registry(account)) return 0;
    let reg: &ProtectiveAskRegistry = account::borrow_managed_data_with_package_witness(
        account,
        registry,
        ProtectiveAskKey {},
        version::current(),
    );
    reg.records.length()
}

public fun ask_ids(account: &Account, registry: &PackageRegistry): vector<ID> {
    if (!has_registry(account)) return vector[];
    let reg: &ProtectiveAskRegistry = account::borrow_managed_data_with_package_witness(
        account,
        registry,
        ProtectiveAskKey {},
        version::current(),
    );
    let mut ids = vector[];
    let mut i = 0;
    while (i < reg.records.length()) {
        ids.push_back(reg.records[i].ask_id);
        i = i + 1;
    };
    ids
}

// === Mutation ===

/// Register a new active ask for this DAO. Enforces per-DAO cap.
/// Validates that the executable is bound to this account.
public fun set_from_execution<Outcome: store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    executable: &Executable<Outcome>,
    action_witness: W,
    ask_id: ID,
    pool_id: ID,
) {
    assert!(
        executable.intent().account() == account::addr(account),
        EExecutableAccountMismatch,
    );
    executable_mod::assert_current_action_witness(executable, registry, action_witness);
    set_internal(account, registry, ask_id, pool_id);
}

/// Remove a specific ask record from a non-executable flow.
/// Intended for permissionless `protective_ask::close`.
public(package) fun clear_with_package_witness(
    account: &mut Account,
    registry: &PackageRegistry,
    ask_id: ID,
) {
    clear_internal(account, registry, ask_id);
}

// === Internal ===

fun set_internal(
    account: &mut Account,
    registry: &PackageRegistry,
    ask_id: ID,
    pool_id: ID,
) {
    if (!has_registry(account)) {
        let reg = ProtectiveAskRegistry {
            records: vector[ProtectiveAskRecord { ask_id, pool_id }],
        };
        account::add_managed_data_with_package_witness(
            account,
            registry,
            ProtectiveAskKey {},
            reg,
            version::current(),
        );
    } else {
        let reg: &mut ProtectiveAskRegistry =
            account::borrow_managed_data_mut_with_package_witness(
                account,
                registry,
                ProtectiveAskKey {},
                version::current(),
            );
        assert!(
            reg.records.length() < constants::max_protective_asks_per_dao(),
            EProtectiveAskCapReached,
        );
        reg.records.push_back(ProtectiveAskRecord { ask_id, pool_id });
    };
}

fun clear_internal(
    account: &mut Account,
    registry: &PackageRegistry,
    ask_id: ID,
) {
    if (!has_registry(account)) return;

    let reg: &mut ProtectiveAskRegistry =
        account::borrow_managed_data_mut_with_package_witness(
            account,
            registry,
            ProtectiveAskKey {},
            version::current(),
        );

    let mut i = 0;
    let len = reg.records.length();
    while (i < len) {
        if (reg.records[i].ask_id == ask_id) {
            reg.records.swap_remove(i);
            return
        };
        i = i + 1;
    };
}

// === Test Helpers ===

#[test_only]
public fun set_for_testing(
    account: &mut Account,
    registry: &PackageRegistry,
    ask_id: ID,
    pool_id: ID,
) {
    set_internal(account, registry, ask_id, pool_id);
}

#[test_only]
fun new_registry_and_account_for_testing(ctx: &mut TxContext): (PackageRegistry, Account) {
    use account_protocol::package_registry;
    use account_protocol::version_witness;

    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyMarketsCore".to_string(),
        version_witness::package_addr(&version::current()),
        1,
    );

    let account = account::new_for_testing_with_registry(&registry, ctx);
    (registry, account)
}

#[test]
#[expected_failure(abort_code = executable_mod::E_UNAUTHORIZED_INCREMENT, location = account_protocol::executable)]
fun test_set_from_execution_rejects_wrong_action_witness() {
    use account_protocol::executable;
    use sui::clock;
    use sui::object;
    use sui::test_utils;
    use sui::tx_context;

    let ctx = &mut tx_context::dummy();
    let (registry, mut account) = new_registry_and_account_for_testing(ctx);
    let test_clock = clock::create_for_testing(ctx);
    let executable = executable::new_single_action_for_testing(account::addr(&account), &test_clock, ctx);

    let ask_uid = object::new(ctx);
    let ask_id = object::uid_to_inner(&ask_uid);
    object::delete(ask_uid);
    let pool_uid = object::new(ctx);
    let pool_id = object::uid_to_inner(&pool_uid);
    object::delete(pool_uid);

    set_from_execution(
        &mut account,
        &registry,
        &executable,
        false,
        ask_id,
        pool_id,
    );

    test_utils::destroy(executable);
    clock::destroy_for_testing(test_clock);
    account::destroy_for_testing<account::TestConfig>(account);
    test_utils::destroy(registry);
}

#[test]
fun test_set_from_execution_accepts_current_action_witness() {
    use account_protocol::executable;
    use sui::clock;
    use sui::object;
    use sui::test_utils;
    use sui::tx_context;

    let ctx = &mut tx_context::dummy();
    let (registry, mut account) = new_registry_and_account_for_testing(ctx);
    let test_clock = clock::create_for_testing(ctx);
    let executable = executable::new_single_action_for_testing(account::addr(&account), &test_clock, ctx);

    let ask_uid = object::new(ctx);
    let ask_id = object::uid_to_inner(&ask_uid);
    object::delete(ask_uid);
    let pool_uid = object::new(ctx);
    let pool_id = object::uid_to_inner(&pool_uid);
    object::delete(pool_uid);

    set_from_execution(
        &mut account,
        &registry,
        &executable,
        executable::new_execution_progress_witness_for_testing(),
        ask_id,
        pool_id,
    );

    assert!(ask_count(&account, &registry) == 1, 0);

    test_utils::destroy(executable);
    clock::destroy_for_testing(test_clock);
    account::destroy_for_testing<account::TestConfig>(account);
    test_utils::destroy(registry);
}
