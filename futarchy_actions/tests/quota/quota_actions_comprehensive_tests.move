// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_actions::quota_actions_comprehensive_tests;

use futarchy_actions::quota_actions;
use sui::test_utils::destroy;

// === Constants ===

const USER1: address = @0xBEEF;
const USER2: address = @0xDEAD;
const USER3: address = @0xCAFE;
const USER4: address = @0xFACE;

// === Constructor Tests ===

#[test]
/// Test creating a SetQuotas action with single user (feeless only)
fun test_new_set_quotas_single_user_feeless() {
    let users = vector[USER1];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64, // period_ms (30 days)
        5u64, // feeless_proposal_amount
        0u64, // sponsor_amount
    );

    assert!(quota_actions::users(&action).length() == 1, 0);
    assert!(quota_actions::period_ms(&action) == 2592000000, 1);
    assert!(quota_actions::feeless_proposal_amount(&action) == 5, 2);
    assert!(quota_actions::sponsor_amount(&action) == 0, 3);

    destroy(action);
}

#[test]
/// Test creating action with both quota types
fun test_new_set_quotas_both_types() {
    let users = vector[USER1];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64, // period_ms
        5u64, // feeless_proposal_amount
        3u64, // sponsor_amount
    );

    assert!(quota_actions::feeless_proposal_amount(&action) == 5, 0);
    assert!(quota_actions::sponsor_amount(&action) == 3, 1);

    destroy(action);
}

#[test]
/// Test creating action with multiple users
fun test_new_set_quotas_multiple_users() {
    let users = vector[USER1, USER2, USER3, USER4];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64, // period_ms
        10u64, // feeless_proposal_amount
        5u64, // sponsor_amount
    );

    assert!(quota_actions::users(&action).length() == 4, 0);
    assert!(*quota_actions::users(&action).borrow(0) == USER1, 1);
    assert!(*quota_actions::users(&action).borrow(1) == USER2, 2);
    assert!(*quota_actions::users(&action).borrow(2) == USER3, 3);
    assert!(*quota_actions::users(&action).borrow(3) == USER4, 4);

    destroy(action);
}

#[test]
/// Test quota removal (both amounts = 0)
fun test_new_set_quotas_removal() {
    let users = vector[USER1, USER2];
    let action = quota_actions::new_set_quotas(
        users,
        0u64, // period ignored when removing
        0u64, // feeless = 0 (removal)
        0u64, // sponsor = 0 (removal)
    );

    assert!(quota_actions::feeless_proposal_amount(&action) == 0, 0);
    assert!(quota_actions::sponsor_amount(&action) == 0, 1);
    assert!(quota_actions::users(&action).length() == 2, 2);

    destroy(action);
}

#[test]
/// Test with empty user list
fun test_new_set_quotas_empty_users() {
    let action = quota_actions::new_set_quotas(
        vector[], // empty users list
        2592000000u64,
        5u64,
        3u64,
    );

    assert!(quota_actions::users(&action).length() == 0, 0);

    destroy(action);
}

#[test]
/// Test with feeless only (no sponsor quota)
fun test_new_set_quotas_feeless_only() {
    let users = vector[USER1];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64,
        5u64, // feeless
        0u64, // no sponsor quota
    );

    assert!(quota_actions::feeless_proposal_amount(&action) == 5, 0);
    assert!(quota_actions::sponsor_amount(&action) == 0, 1);

    destroy(action);
}

#[test]
/// Test with sponsor only (no feeless quota)
fun test_new_set_quotas_sponsor_only() {
    let users = vector[USER1];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64,
        0u64, // no feeless quota
        3u64, // sponsor quota
    );

    assert!(quota_actions::feeless_proposal_amount(&action) == 0, 0);
    assert!(quota_actions::sponsor_amount(&action) == 3, 1);

    destroy(action);
}

// === Getter Tests ===

#[test]
/// Test all getters return correct values
fun test_getters_comprehensive() {
    let users = vector[USER1, USER2];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64,
        10u64,
        5u64,
    );

    // Test all getters
    let users_ref = quota_actions::users(&action);
    assert!(users_ref.length() == 2, 0);
    assert!(*users_ref.borrow(0) == USER1, 1);
    assert!(*users_ref.borrow(1) == USER2, 2);

    assert!(quota_actions::period_ms(&action) == 2592000000, 3);
    assert!(quota_actions::feeless_proposal_amount(&action) == 10, 4);
    assert!(quota_actions::sponsor_amount(&action) == 5, 5);

    destroy(action);
}

// === Various Quota Configurations ===

#[test]
/// Test with short quota period (1 day)
fun test_new_set_quotas_short_period() {
    let users = vector[USER1];
    let action = quota_actions::new_set_quotas(
        users,
        86400000u64, // 1 day
        3u64,
        1u64,
    );

    assert!(quota_actions::period_ms(&action) == 86400000, 0);

    destroy(action);
}

#[test]
/// Test with long quota period (90 days)
fun test_new_set_quotas_long_period() {
    let users = vector[USER1];
    let action = quota_actions::new_set_quotas(
        users,
        7776000000u64, // 90 days
        20u64,
        10u64,
    );

    assert!(quota_actions::period_ms(&action) == 7776000000, 0);
    assert!(quota_actions::feeless_proposal_amount(&action) == 20, 1);

    destroy(action);
}

#[test]
/// Test with high quota amounts
fun test_new_set_quotas_high_quota() {
    let users = vector[USER1];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64,
        1000u64, // very high feeless quota
        500u64, // high sponsor quota
    );

    assert!(quota_actions::feeless_proposal_amount(&action) == 1000, 0);
    assert!(quota_actions::sponsor_amount(&action) == 500, 1);

    destroy(action);
}

// === Edge Cases ===

#[test]
/// Test with maximum u64 values
fun test_new_set_quotas_extreme_values() {
    let users = vector[USER1];
    let max_u64 = 18446744073709551615u64;

    let action = quota_actions::new_set_quotas(
        users,
        max_u64, // max period
        max_u64, // max feeless
        max_u64, // max sponsor
    );

    assert!(quota_actions::period_ms(&action) == max_u64, 0);
    assert!(quota_actions::feeless_proposal_amount(&action) == max_u64, 1);
    assert!(quota_actions::sponsor_amount(&action) == max_u64, 2);

    destroy(action);
}

#[test]
/// Test with minimum valid values
fun test_new_set_quotas_minimum_values() {
    let users = vector[USER1];

    let action = quota_actions::new_set_quotas(
        users,
        1u64, // minimum period
        1u64, // minimum feeless
        0u64, // no sponsor
    );

    assert!(quota_actions::period_ms(&action) == 1, 0);
    assert!(quota_actions::feeless_proposal_amount(&action) == 1, 1);

    destroy(action);
}

#[test]
/// Test with many users
fun test_new_set_quotas_many_users() {
    let mut users = vector[];
    // Add various predefined addresses
    users.push_back(@0x1);
    users.push_back(@0x2);
    users.push_back(@0x3);
    users.push_back(@0x4);
    users.push_back(@0x5);
    users.push_back(@0x6);
    users.push_back(@0x7);
    users.push_back(@0x8);
    users.push_back(@0x9);
    users.push_back(@0xa);
    users.push_back(@0xb);
    users.push_back(@0xc);
    users.push_back(@0xd);
    users.push_back(@0xe);
    users.push_back(@0xf);
    users.push_back(@0x10);
    users.push_back(@0x11);
    users.push_back(@0x12);
    users.push_back(@0x13);
    users.push_back(@0x14);
    users.push_back(@0x15);
    users.push_back(@0x16);
    users.push_back(@0x17);
    users.push_back(@0x18);
    users.push_back(@0x19);
    users.push_back(@0x1a);
    users.push_back(@0x1b);

    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64,
        5u64,
        3u64,
    );

    assert!(quota_actions::users(&action).length() == 27, 0);

    destroy(action);
}

// === Realistic Scenarios ===

#[test]
/// Scenario 1: Set up a VIP tier with both quotas
fun test_scenario_vip_tier() {
    let users = vector[USER1, USER2];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64, // 30 days
        20u64, // 20 feeless proposals per month
        10u64, // 10 sponsorships per month
    );

    assert!(quota_actions::feeless_proposal_amount(&action) == 20, 0);
    assert!(quota_actions::sponsor_amount(&action) == 10, 1);

    destroy(action);
}

#[test]
/// Scenario 2: Set up a regular tier (feeless only)
fun test_scenario_regular_tier() {
    let users = vector[USER1, USER2, USER3];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64, // 30 days
        5u64, // 5 feeless proposals per month
        0u64, // no sponsor quota
    );

    assert!(quota_actions::feeless_proposal_amount(&action) == 5, 0);
    assert!(quota_actions::sponsor_amount(&action) == 0, 1);

    destroy(action);
}

#[test]
/// Scenario 3: Set up a trial tier (short period)
fun test_scenario_trial_tier() {
    let users = vector[USER1];
    let action = quota_actions::new_set_quotas(
        users,
        604800000u64, // 7 days (trial period)
        3u64, // 3 feeless proposals during trial
        1u64, // 1 sponsorship during trial
    );

    assert!(quota_actions::period_ms(&action) == 604800000, 0);
    assert!(quota_actions::feeless_proposal_amount(&action) == 3, 1);
    assert!(quota_actions::sponsor_amount(&action) == 1, 2);

    destroy(action);
}

#[test]
/// Scenario 4: Remove quotas for users
fun test_scenario_remove_quotas() {
    let users = vector[USER1, USER2, USER3];
    let action = quota_actions::new_set_quotas(
        users,
        0u64, // ignored for removal
        0u64, // feeless = 0 (remove)
        0u64, // sponsor = 0 (remove)
    );

    assert!(quota_actions::feeless_proposal_amount(&action) == 0, 0);
    assert!(quota_actions::sponsor_amount(&action) == 0, 1);
    assert!(quota_actions::users(&action).length() == 3, 2);

    destroy(action);
}

#[test]
/// Scenario 5: Adjust quotas for existing users (increase)
fun test_scenario_increase_quotas() {
    let users = vector[USER1];
    let action = quota_actions::new_set_quotas(
        users,
        2592000000u64, // same period
        15u64, // increased from 5 to 15
        8u64, // increased sponsor quota
    );

    assert!(quota_actions::feeless_proposal_amount(&action) == 15, 0);
    assert!(quota_actions::sponsor_amount(&action) == 8, 1);

    destroy(action);
}
