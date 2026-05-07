// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_markets_core::protective_bid_tests;

use account_actions::vault;
use account_protocol::account::{Self as account, Account};
use account_protocol::deps;
use account_protocol::metadata;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use futarchy_markets_core::protective_bid;
use futarchy_one_shot_utils::constants;
use sui::clock::{Self, Clock};
use sui::object;
use sui::test_utils::destroy;

public struct Witness() has drop;
public struct Config has copy, drop, store {}
public struct ASSET has drop {}
public struct STABLE has drop {}

fun setup(ctx: &mut TxContext): (PackageRegistry, Account, Clock) {
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountActions".to_string(),
        @account_actions,
        1,
    );
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyMarketsCore".to_string(),
        @futarchy_markets_core,
        1,
    );

    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));
    let account = account::new(Config {}, metadata::empty(), deps, Witness(), ctx);
    let clock = clock::create_for_testing(ctx);
    (registry, account, clock)
}

#[test]
fun test_close_succeeds_with_cap(ctx: &mut TxContext) {
    let (registry, mut account, mut clock) = setup(ctx);

    let account_id = object::id(&account);
    let cap = vault::create_vault_admin_cap_for_testing(
        b"bid_wall_funds".to_string(),
        account_id,
        ctx,
    );

    let mut bid = protective_bid::create<ASSET, STABLE>(
        account_id,
        object::id_from_address(@0x0),
        0, 0, 0,
        constants::ninety_days_ms(),
        cap,
        1_000_000,
        0,
        &clock,
        ctx,
    );

    clock::increment_for_testing(&mut clock, constants::ninety_days_ms());

    protective_bid::close<ASSET, STABLE>(
        &mut bid,
        &mut account,
        &registry,
        &clock,
    );

    assert!(!protective_bid::is_active(&bid), 0);

    protective_bid::destroy_for_testing(bid);
    account::destroy_for_testing<Config>(account);
    destroy(registry);
    clock::destroy_for_testing(clock);
}

#[test]
#[expected_failure(abort_code = protective_bid::ENoPermissionlessClose)]
fun test_close_fails_when_no_permissionless_close(ctx: &mut TxContext) {
    let (registry, mut account, mut clock) = setup(ctx);

    let account_id = object::id(&account);
    let cap = vault::create_vault_admin_cap_for_testing(
        b"bid_wall_funds".to_string(),
        account_id,
        ctx,
    );

    let mut bid = protective_bid::create<ASSET, STABLE>(
        account_id,
        object::id_from_address(@0x0),
        0, 0, 0,
        0, // release_duration_ms = 0 → no permissionless close
        cap,
        1_000_000,
        0,
        &clock,
        ctx,
    );

    clock::increment_for_testing(&mut clock, 365 * 24 * 60 * 60 * 1000);

    protective_bid::close<ASSET, STABLE>(
        &mut bid,
        &mut account,
        &registry,
        &clock,
    );

    protective_bid::destroy_for_testing(bid);
    account::destroy_for_testing<Config>(account);
    destroy(registry);
    clock::destroy_for_testing(clock);
}
