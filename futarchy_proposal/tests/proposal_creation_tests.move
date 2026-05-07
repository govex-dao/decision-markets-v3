// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// End-to-end tests for the atomic proposal creation flow:
/// begin_proposal → add_outcome_coins → finalize_proposal
///
/// This tests the complete proposal creation lifecycle with real types
/// and validates that all invariants are maintained.
#[test_only]
module futarchy_proposal::proposal_creation_tests;

use account_protocol::account::{Self, Account};
use account_protocol::intents;
use account_protocol::package_registry::{Self, PackageRegistry};
use futarchy_core::dao_config::{Self, DaoConfig};
use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationRegistry};
use futarchy_core::futarchy_config;
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationRegistry};
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationRegistry};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use conditional_coin::conditional_0::{Self, CONDITIONAL_0};
use conditional_coin::conditional_1::{Self, CONDITIONAL_1};
use conditional_coin::conditional_2::{Self, CONDITIONAL_2};
use conditional_coin::conditional_3::{Self, CONDITIONAL_3};
use futarchy_proposal::not_conditional::{Self as not_conditional, NOT_CONDITIONAL};
use futarchy_one_shot_utils::test_coin_a::{Self, TEST_COIN_A};
use futarchy_one_shot_utils::test_coin_b::{Self, TEST_COIN_B};
use futarchy_proposal::proposal::{Self, Proposal, ProposalCreationTicket};
use std::ascii;
use std::string;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::{Self, Currency, MetadataCap};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;
use sui::url;

// === Constants ===

public struct TestAction has drop {}

const ADMIN: address = @0xAD;
const PROPOSER: address = @0xABC1;
const ORCHESTRATOR_ADDR: address = @0x60D;

// Initial liquidity amounts
const INITIAL_ASSET_LIQUIDITY: u64 = 10_000_000_000; // 10 tokens (9 decimals)
const INITIAL_STABLE_LIQUIDITY: u64 = 10_000_000_000; // 10 tokens

// === Test Helpers ===

/// Create a test clock at specific time
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

/// Create default DaoConfig for testing
fun create_test_dao_config(): DaoConfig {
    let trading_params = dao_config::default_trading_params();
    let twap_config = dao_config::default_twap_config();
    let governance_config = dao_config::default_governance_config();
    let metadata_config = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.dao/icon.png"),
        string::utf8(b"A test DAO for proposal creation tests"),
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

/// Create a test Account with FutarchyConfig
fun create_test_account(registry: &PackageRegistry, ctx: &mut TxContext): Account {
    let dao_config = create_test_dao_config();
    let futarchy_config = futarchy_config::new<TEST_COIN_A, TEST_COIN_B>(dao_config, option::none());
    futarchy_config::new_account_test(futarchy_config, registry, ctx)
}

/// Create a test UnifiedSpotPool with initial liquidity
fun create_test_spot_pool(
    ctx: &mut TxContext,
): UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A> {
    // Create LP coin treasury for testing
    let lp_treasury = coin::create_treasury_cap_for_testing<TEST_COIN_A>(ctx);

    // Use new_for_testing so aggregator_config exists, then seed reserves.
    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        lp_treasury,
        30, // fee_bps
        ctx,
    );
    let asset_balance = balance::create_for_testing<TEST_COIN_A>(INITIAL_ASSET_LIQUIDITY);
    let stable_balance = balance::create_for_testing<TEST_COIN_B>(INITIAL_STABLE_LIQUIDITY);
    unified_spot_pool::add_liquidity_for_testing(&mut pool, asset_balance, stable_balance);
    pool
}

/// Initialize conditional coin types and return caps + metadata caps
/// conditional_0 = outcome 0 asset, conditional_1 = outcome 0 stable
/// conditional_2 = outcome 1 asset, conditional_3 = outcome 1 stable
/// Uses Sui Currency standard - Currency<T> is shared, TreasuryCap + MetadataCap are owned
fun init_conditional_coins(
    scenario: &mut Scenario,
): (
    TreasuryCap<CONDITIONAL_0>,
    MetadataCap<CONDITIONAL_0>,
    TreasuryCap<CONDITIONAL_1>,
    MetadataCap<CONDITIONAL_1>,
    TreasuryCap<CONDITIONAL_2>,
    MetadataCap<CONDITIONAL_2>,
    TreasuryCap<CONDITIONAL_3>,
    MetadataCap<CONDITIONAL_3>,
) {
    // Switch to @0x0 to create CoinRegistry (required by create_coin_data_registry_for_testing)
    ts::next_tx(scenario, @0x0);

    // Create CoinRegistry for testing
    let mut coin_reg = coin_registry::create_coin_data_registry_for_testing(ts::ctx(scenario));

    // Initialize all 4 conditional coin types
    conditional_0::init_for_testing(&mut coin_reg, ts::ctx(scenario));
    conditional_1::init_for_testing(&mut coin_reg, ts::ctx(scenario));
    conditional_2::init_for_testing(&mut coin_reg, ts::ctx(scenario));
    conditional_3::init_for_testing(&mut coin_reg, ts::ctx(scenario));

    // Destroy registry (not needed after coin creation)
    destroy(coin_reg);

    // Advance transaction to retrieve created objects (from @0x0)
    ts::next_tx(scenario, @0x0);

    // Take all TreasuryCaps and MetadataCaps from sender (@0x0)
    // Note: Currency<T> objects are shared automatically
    let cond0_asset_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(scenario);
    let cond0_asset_mcap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(scenario);
    let cond0_stable_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_1>>(scenario);
    let cond0_stable_mcap = ts::take_from_sender<MetadataCap<CONDITIONAL_1>>(scenario);
    let cond1_asset_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_2>>(scenario);
    let cond1_asset_mcap = ts::take_from_sender<MetadataCap<CONDITIONAL_2>>(scenario);
    let cond1_stable_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_3>>(scenario);
    let cond1_stable_mcap = ts::take_from_sender<MetadataCap<CONDITIONAL_3>>(scenario);

    (
        cond0_asset_cap,
        cond0_asset_mcap,
        cond0_stable_cap,
        cond0_stable_mcap,
        cond1_asset_cap,
        cond1_asset_mcap,
        cond1_stable_cap,
        cond1_stable_mcap,
    )
}

/// Initialize base coin types - Currency<T> is shared, TreasuryCap + MetadataCap are owned
/// Returns nothing - caller should take_shared the Currency objects
fun init_base_coins(scenario: &mut Scenario) {
    // Switch to @0x0 to create CoinRegistry (required by create_coin_data_registry_for_testing)
    ts::next_tx(scenario, @0x0);

    // Create CoinRegistry for testing
    let mut coin_reg = coin_registry::create_coin_data_registry_for_testing(ts::ctx(scenario));

    // Initialize base coin types (creates Currency<T> as shared, TreasuryCap + MetadataCap as owned)
    test_coin_a::init_for_testing(&mut coin_reg, ts::ctx(scenario));
    test_coin_b::init_for_testing(&mut coin_reg, ts::ctx(scenario));

    // Destroy registry (not needed after coin creation)
    destroy(coin_reg);

    // Advance transaction to take the caps from @0x0
    ts::next_tx(scenario, @0x0);

    // Destroy the TreasuryCaps and MetadataCaps since we don't need them for base coins
    let asset_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_A>>(scenario);
    let asset_mcap = ts::take_from_sender<MetadataCap<TEST_COIN_A>>(scenario);
    let stable_cap = ts::take_from_sender<TreasuryCap<TEST_COIN_B>>(scenario);
    let stable_mcap = ts::take_from_sender<MetadataCap<TEST_COIN_B>>(scenario);

    destroy(asset_cap);
    destroy(asset_mcap);
    destroy(stable_cap);
    destroy(stable_mcap);
}

/// Create exact proposal fee coins for the account's current governance config.
fun create_fee_coins_for_proposal(
    account: &Account,
    outcome_count: u64,
    ctx: &mut TxContext,
): (Coin<TEST_COIN_B>, Coin<TEST_COIN_A>) {
    let futarchy_cfg = account::config<futarchy_config::FutarchyConfig>(account);
    let base_fee = futarchy_config::proposal_creation_fee(futarchy_cfg);
    let per_outcome_fee = futarchy_config::proposal_fee_per_outcome(futarchy_cfg);
    let additional_outcome_fee = if (outcome_count <= 2) {
        0
    } else {
        let fee_u128 = ((outcome_count - 2) as u128) * (per_outcome_fee as u128);
        assert!(fee_u128 <= 18446744073709551615u128, 0);
        fee_u128 as u64
    };
    let total_fee = base_fee + additional_outcome_fee;

    if (futarchy_config::fee_in_asset_token(futarchy_cfg)) {
        (
            coin::zero<TEST_COIN_B>(ctx),
            coin::mint_for_testing<TEST_COIN_A>(total_fee, ctx),
        )
    } else {
        (
            coin::mint_for_testing<TEST_COIN_B>(total_fee, ctx),
            coin::zero<TEST_COIN_A>(ctx),
        )
    }
}

// === Tests ===

#[test]
fun test_begin_proposal_accepts_action_from_package_added_to_global_registry() {
    let mut scenario = ts::begin(ADMIN);

    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);
    package_registry::add_for_testing(&mut registry, b"FutarchyGovernance".to_string(), ORCHESTRATOR_ADDR, 1);
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let clock = create_test_clock(1_000, ts::ctx(&mut scenario));

    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyProposal".to_string(),
        @futarchy_proposal,
        1,
    );

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let yes_intent_spec = option::some(vector[
        intents::new_action_spec(TestAction {}, vector[], 1),
    ]);

    let (_proposal, _escrow, _ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Future package proposal"),
        string::utf8(b"Package is globally registered"),
        string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN,
        false,
        stable_fee,
        asset_fee,
        yes_intent_spec,
        &clock,
        ts::ctx(&mut scenario),
    );

    proposal::destroy_for_testing(_proposal);
    coin_escrow::destroy_for_testing(_escrow);
    proposal::destroy_creation_ticket_for_testing(_ticket);
    destroy(account);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

#[test]
/// Test the complete atomic proposal creation flow:
/// 1. begin_proposal - creates unshared Proposal + TokenEscrow
/// 2. add_outcome_coins - registers conditional coin caps for each outcome
/// 3. finalize_proposal - validates completeness, creates AMM pools, shares objects
fun test_atomic_proposal_creation_two_outcomes() {
    let mut scenario = ts::begin(ADMIN);

    // 1. Setup: Create PackageRegistry
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);

    // Register required packages
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyCore".to_string(),
        @futarchy_core,
        1,
    );
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

    // 2. Create test Account with FutarchyConfig
    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));

    // 3. Create test clock
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // 4. Create test spot pool with liquidity
    let mut spot_pool = create_test_spot_pool(ts::ctx(&mut scenario));

    // Link spot pool to DAO config (required for finalize_proposal validation)
    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_spot_pool_id(config, object::id(&spot_pool));

    // 5. Initialize conditional coins (4 types for 2 outcomes)
    // Returns TreasuryCap + MetadataCap (Currency<T> is shared automatically)
    let (
        cond0_asset_cap,
        cond0_asset_mcap,
        cond0_stable_cap,
        cond0_stable_mcap,
        cond1_asset_cap,
        cond1_asset_mcap,
        cond1_stable_cap,
        cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);

    // 6. Initialize base coins (Currency<T> is shared automatically)
    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);

    // Advance transaction to make shared Currency objects available
    ts::next_tx(&mut scenario, ADMIN);

    // Take shared Currency<T> objects for base coins
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);

    // 7. Create fee coins
    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));

    // 8. Create outcome messages and details (2 outcomes)
    let outcome_messages = vector[
        string::utf8(b"Reject proposal"),
        string::utf8(b"Accept proposal"),
    ];
    let outcome_details = vector[
        string::utf8(b"Status quo - no changes"),
        string::utf8(b"Implement the proposed changes"),
    ];

    // 9. BEGIN PROPOSAL - creates unshared Proposal + TokenEscrow
    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Test Proposal"),
        string::utf8(b"This is a test proposal for atomic creation"),
        string::utf8(b"{}"), // metadata JSON
        outcome_messages,
        outcome_details,
        ADMIN,
        false, // used_feeless_quota
        stable_fee,
        asset_fee,
        option::none(), // no intent_spec_for_yes
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify proposal state after begin
    assert!(proposal::get_state(&proposal) == proposal::state_premarket(), 0);
    assert!(proposal::outcome_count(&proposal) == 2, 1);

    // Take shared Currency<T> objects for conditional coins
    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);
    let mut cond1_asset_currency = ts::take_shared<Currency<CONDITIONAL_2>>(&scenario);
    let mut cond1_stable_currency = ts::take_shared<Currency<CONDITIONAL_3>>(&scenario);

    // 10. ADD OUTCOME COINS - register caps for outcome 0
    // Pass account directly - function borrows config internally
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal,
        &mut escrow,
        0, // outcome_index
        cond0_asset_cap,
        &mut cond0_asset_currency,
        cond0_asset_mcap,
        cond0_stable_cap,
        &mut cond0_stable_currency,
        cond0_stable_mcap,
        &account,
        &base_asset_currency,
        &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    // 11. ADD OUTCOME COINS - register caps for outcome 1
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_2, CONDITIONAL_3>(
        &mut proposal,
        &mut escrow,
        1, // outcome_index
        cond1_asset_cap,
        &mut cond1_asset_currency,
        cond1_asset_mcap,
        cond1_stable_cap,
        &mut cond1_stable_currency,
        cond1_stable_mcap,
        &account,
        &base_asset_currency,
        &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    // Return shared Currency objects
    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(cond1_asset_currency);
    ts::return_shared(cond1_stable_currency);

    // Verify all caps are registered
    assert!(coin_escrow::caps_registered_count(&escrow) == 2, 2);

    // Create mutation registries for testing
    let mut market_state_registry = market_state_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    // Add futarchy_proposal to authorized packages so it can create auth
    market_state_mutation_auth::add_authorized_package_for_testing(&mut market_state_registry, @futarchy_proposal);
    let mut spot_pool_mutation_registry = spot_pool_mutation_auth::new_registry_for_testing(
        ts::ctx(&mut scenario),
    );
    let spot_pool_admin = spot_pool_mutation_auth::new_admin_cap_for_testing(
        &spot_pool_mutation_registry,
        ts::ctx(&mut scenario),
    );
    spot_pool_mutation_auth::add_authorized_package(
        &mut spot_pool_mutation_registry,
        &spot_pool_admin,
        @futarchy_proposal,
    );
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(spot_pool_admin);
    let mut escrow_registry = escrow_mutation_auth::create_registry_for_testing(ts::ctx(&mut scenario));
    // Add futarchy_proposal to authorized packages so liquidity_initialize can create auth
    escrow_mutation_auth::add_authorized_package_for_testing(&mut escrow_registry, @futarchy_proposal);

    // 12. FINALIZE PROPOSAL - validates completeness, shares proposal
    // AMM pools are created later during advance_state REVIEW->TRADING transition.
    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal,
        escrow,
        ticket,
        &account,
        &mut spot_pool,
        &spot_pool_mutation_registry,
        &clock,
        ts::ctx(&mut scenario),
    );

    // 13. Cleanup
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);
    destroy(account);
    destroy(spot_pool);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal::EDaoAccountMismatch)]
/// add_outcome_coins must reject a dao_account that doesn't match proposal.dao_id
fun test_add_outcome_coins_rejects_wrong_dao_account() {
    let mut scenario = ts::begin(ADMIN);

    // Setup: Create PackageRegistry
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);

    // Register required packages
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    // Two different accounts (same coin types) so IDs don't match.
    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let wrong_account = create_test_account(&registry, ts::ctx(&mut scenario));

    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // Conditional coin caps (only need outcome 0 in this test)
    let (
        cond0_asset_cap,
        cond0_asset_mcap,
        cond0_stable_cap,
        cond0_stable_mcap,
        cond1_asset_cap,
        cond1_asset_mcap,
        cond1_stable_cap,
        cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);

    // Base coin currencies for metadata reads
    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));

    let outcome_messages = vector[string::utf8(b"Reject"), string::utf8(b"Accept")];
    let outcome_details = vector[string::utf8(b"No"), string::utf8(b"Yes")];

    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Test"),
        string::utf8(b"Test"),
        string::utf8(b"{}"),
        outcome_messages,
        outcome_details,
        ADMIN,
        false,
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);

    // Must abort: wrong_account does not match proposal.dao_id
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal,
        &mut escrow,
        0,
        cond0_asset_cap,
        &mut cond0_asset_currency,
        cond0_asset_mcap,
        cond0_stable_cap,
        &mut cond0_stable_currency,
        cond0_stable_mcap,
        &wrong_account,
        &base_asset_currency,
        &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);
    destroy(cond1_asset_cap);
    destroy(cond1_asset_mcap);
    destroy(cond1_stable_cap);
    destroy(cond1_stable_mcap);
    destroy(proposal);
    destroy(escrow);
    proposal::destroy_creation_ticket_for_testing(ticket);
    destroy(account);
    destroy(wrong_account);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal::EInvalidConditionalCoinModule)]
/// add_outcome_coins must reject coins whose module name is not conditional_<digits>
fun test_add_outcome_coins_rejects_non_conditional_module_name() {
    let mut scenario = ts::begin(ADMIN);

    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    let (
        cond0_asset_cap,
        cond0_asset_mcap,
        cond0_stable_cap,
        cond0_stable_mcap,
        cond1_asset_cap,
        cond1_asset_mcap,
        cond1_stable_cap,
        cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);
    destroy(cond0_asset_cap);
    destroy(cond0_asset_mcap);
    destroy(cond1_asset_cap);
    destroy(cond1_asset_mcap);
    destroy(cond1_stable_cap);
    destroy(cond1_stable_mcap);

    let mut coin_reg = coin_registry::create_coin_data_registry_for_testing(ts::ctx(&mut scenario));
    not_conditional::init_for_testing_with_registry(&mut coin_reg, ts::ctx(&mut scenario));
    destroy(coin_reg);
    ts::next_tx(&mut scenario, @0x0);
    let bad_asset_cap = ts::take_from_sender<TreasuryCap<NOT_CONDITIONAL>>(&scenario);
    let bad_asset_mcap = ts::take_from_sender<MetadataCap<NOT_CONDITIONAL>>(&scenario);

    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);

    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);
    let mut bad_asset_currency = ts::take_shared<Currency<NOT_CONDITIONAL>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Test"),
        string::utf8(b"Test"),
        string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN,
        false,
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, NOT_CONDITIONAL, CONDITIONAL_1>(
        &mut proposal,
        &mut escrow,
        0,
        bad_asset_cap,
        &mut bad_asset_currency,
        bad_asset_mcap,
        cond0_stable_cap,
        &mut cond0_stable_currency,
        cond0_stable_mcap,
        &account,
        &base_asset_currency,
        &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    ts::return_shared(bad_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);
    destroy(proposal);
    destroy(escrow);
    proposal::destroy_creation_ticket_for_testing(ticket);
    destroy(account);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal::EProposalEscrowMismatch)]
/// add_outcome_coins must reject an escrow whose embedded MarketState was created for a different proposal
fun test_add_outcome_coins_rejects_wrong_escrow() {
    let mut scenario = ts::begin(ADMIN);

    // Setup: Create PackageRegistry
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);

    // Register required packages
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // Conditional coin caps (only need outcome 0 in this test)
    let (
        cond0_asset_cap,
        cond0_asset_mcap,
        cond0_stable_cap,
        cond0_stable_mcap,
        cond1_asset_cap,
        cond1_asset_mcap,
        cond1_stable_cap,
        cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);

    // Base coin currencies for metadata reads
    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);

    // Create two separate (proposal, escrow) pairs
    let (stable_fee_1, asset_fee_1) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let outcome_messages_1 = vector[string::utf8(b"Reject"), string::utf8(b"Accept")];
    let outcome_details_1 = vector[string::utf8(b"No"), string::utf8(b"Yes")];
    let (mut proposal_1, escrow_1, ticket_1) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Test1"),
        string::utf8(b"Test1"),
        string::utf8(b"{}"),
        outcome_messages_1,
        outcome_details_1,
        ADMIN,
        false,
        stable_fee_1,
        asset_fee_1,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    let (stable_fee_2, asset_fee_2) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let outcome_messages_2 = vector[string::utf8(b"Reject"), string::utf8(b"Accept")];
    let outcome_details_2 = vector[string::utf8(b"No"), string::utf8(b"Yes")];
    let (proposal_2, mut escrow_2, ticket_2) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Test2"),
        string::utf8(b"Test2"),
        string::utf8(b"{}"),
        outcome_messages_2,
        outcome_details_2,
        ADMIN,
        false,
        stable_fee_2,
        asset_fee_2,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);

    // Must abort: escrow_2 belongs to a different proposal than proposal_1.
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal_1,
        &mut escrow_2,
        0,
        cond0_asset_cap,
        &mut cond0_asset_currency,
        cond0_asset_mcap,
        cond0_stable_cap,
        &mut cond0_stable_currency,
        cond0_stable_mcap,
        &account,
        &base_asset_currency,
        &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);
    destroy(cond1_asset_cap);
    destroy(cond1_asset_mcap);
    destroy(cond1_stable_cap);
    destroy(cond1_stable_mcap);
    destroy(proposal_1);
    destroy(escrow_1);
    proposal::destroy_creation_ticket_for_testing(ticket_1);
    destroy(proposal_2);
    destroy(escrow_2);
    proposal::destroy_creation_ticket_for_testing(ticket_2);
    destroy(account);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal::EMissingConditionalCoins)]
/// Test that finalize_proposal fails if conditional coins are not registered
fun test_finalize_without_conditional_coins_fails() {
    let mut scenario = ts::begin(ADMIN);

    // Setup
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyCore".to_string(),
        @futarchy_core,
        1,
    );
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

    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));
    let mut spot_pool = create_test_spot_pool(ts::ctx(&mut scenario));
    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));

    // Link spot pool to DAO config (required for finalize_proposal validation)
    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_spot_pool_id(config, object::id(&spot_pool));

    let outcome_messages = vector[string::utf8(b"Reject"), string::utf8(b"Accept")];
    let outcome_details = vector[string::utf8(b"No"), string::utf8(b"Yes")];

    // Begin proposal but DON'T add conditional coins
    let (proposal, escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Test"),
        string::utf8(b"Test"),
        string::utf8(b"{}"),
        outcome_messages,
        outcome_details,
        ADMIN,
        false,
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Create mutation registries for testing
    let mut spot_pool_mutation_registry = spot_pool_mutation_auth::new_registry_for_testing(
        ts::ctx(&mut scenario),
    );
    let spot_pool_admin = spot_pool_mutation_auth::new_admin_cap_for_testing(
        &spot_pool_mutation_registry,
        ts::ctx(&mut scenario),
    );
    spot_pool_mutation_auth::add_authorized_package(
        &mut spot_pool_mutation_registry,
        &spot_pool_admin,
        @futarchy_proposal,
    );
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(spot_pool_admin);
    let market_state_registry = market_state_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    let escrow_registry = escrow_mutation_auth::create_registry_for_testing(ts::ctx(&mut scenario));

    // This should fail - no conditional coins registered
    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal,
        escrow,
        ticket,
        &account,
        &mut spot_pool,
        &spot_pool_mutation_registry,
        &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
/// Test that proposal creation with used_feeless_quota=true and feeless=true allows zero fee
fun test_proposal_creation_with_feeless_quota_zero_fee() {
    let mut scenario = ts::begin(ADMIN);

    // 1. Setup: Create PackageRegistry
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);

    // Register required packages
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyCore".to_string(),
        @futarchy_core,
        1,
    );
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

    // 2. Create test Account with FutarchyConfig
    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));

    // 3. Create test clock
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // 4. Set up feeless quota for ADMIN/sender (free proposals)
    let dao_id = object::id(&account);
    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_quota_for_testing(
        config,
        dao_id,
        ADMIN,
        86400000, // period_ms: 1 day
        5, // feeless_proposal_amount: 5 free proposals
        0, // sponsor_amount: no sponsorships
        &clock,
    );

    // 5. Create test spot pool with liquidity
    let spot_pool = create_test_spot_pool(ts::ctx(&mut scenario));

    // 6. Create ZERO fee coins (since feeless quota allows free proposals)
    let stable_fee = coin::zero<TEST_COIN_B>(ts::ctx(&mut scenario));
    let asset_fee = coin::zero<TEST_COIN_A>(ts::ctx(&mut scenario));

    // 7. Create outcome messages and details (2 outcomes)
    let outcome_messages = vector[
        string::utf8(b"Reject proposal"),
        string::utf8(b"Accept proposal"),
    ];
    let outcome_details = vector[
        string::utf8(b"Status quo - no changes"),
        string::utf8(b"Implement the proposed changes"),
    ];

    // 8. BEGIN PROPOSAL with used_feeless_quota=true (should succeed with zero fee)
    let (proposal, escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Quota Test Proposal"),
        string::utf8(b"Testing zero fee with feeless quota"),
        string::utf8(b"{}"),
        outcome_messages,
        outcome_details,
        ADMIN,
        true, // used_feeless_quota = TRUE
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify proposal was created
    assert!(proposal::get_state(&proposal) == proposal::state_premarket(), 0);
    assert!(proposal::outcome_count(&proposal) == 2, 1);
    assert!(proposal::used_feeless_quota(&proposal) == true, 2);

    // Cleanup
    proposal::destroy_for_testing(proposal);
    coin_escrow::destroy_for_testing(escrow);
    proposal::destroy_creation_ticket_for_testing(ticket);
    destroy(account);
    destroy(spot_pool);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal::ENoQuotaAvailable)]
/// Test that proposal creation with used_feeless_quota=true but sponsor-only quota fails
/// In the new model, sponsor quota is separate from feeless quota - having sponsor quota
/// doesn't give you free proposals
fun test_proposal_creation_with_sponsor_only_quota_fails_feeless() {
    let mut scenario = ts::begin(ADMIN);

    // 1. Setup: Create PackageRegistry
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);

    // Register required packages
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyCore".to_string(),
        @futarchy_core,
        1,
    );
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

    // 2. Create test Account with FutarchyConfig
    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));

    // 3. Create test clock
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // 4. Set up SPONSOR-ONLY quota for the sender (no feeless proposals)
    let dao_id = object::id(&account);
    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_quota_for_testing(
        config,
        dao_id,
        ADMIN,
        86400000, // period_ms: 1 day
        0, // feeless_proposal_amount: ZERO (no free proposals)
        5, // sponsor_amount: 5 sponsorships
        &clock,
    );

    // 5. Create test spot pool with liquidity
    let spot_pool = create_test_spot_pool(ts::ctx(&mut scenario));

    // 6. Create zero fee coins (expecting it to fail because no feeless quota)
    let stable_fee = coin::zero<TEST_COIN_B>(ts::ctx(&mut scenario));
    let asset_fee = coin::zero<TEST_COIN_A>(ts::ctx(&mut scenario));

    // 7. Create outcome messages and details (2 outcomes)
    let outcome_messages = vector[
        string::utf8(b"Reject proposal"),
        string::utf8(b"Accept proposal"),
    ];
    let outcome_details = vector[string::utf8(b"Status quo"), string::utf8(b"Accept changes")];

    // 8. BEGIN PROPOSAL with used_feeless_quota=true - should FAIL because sponsor quota
    // doesn't give you free proposals
    let (proposal, escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Sponsor Only Quota Test"),
        string::utf8(b"Testing that sponsor quota doesn't give free proposals"),
        string::utf8(b"{}"),
        outcome_messages,
        outcome_details,
        ADMIN,
        true, // used_feeless_quota = TRUE (should fail - no feeless quota)
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should not reach here - expected to fail
    proposal::destroy_for_testing(proposal);
    coin_escrow::destroy_for_testing(escrow);
    proposal::destroy_creation_ticket_for_testing(ticket);
    destroy(account);
    destroy(spot_pool);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal::ENoQuotaAvailable)]
/// Test that used_feeless_quota=true without quota configured fails
fun test_proposal_creation_with_feeless_quota_but_no_quota_set_fails() {
    let mut scenario = ts::begin(ADMIN);

    // 1. Setup: Create PackageRegistry
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);

    // Register required packages
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyCore".to_string(),
        @futarchy_core,
        1,
    );
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

    // 2. Create test Account with FutarchyConfig (NO QUOTA SET)
    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));

    // 3. Create test clock
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // 4. Create fee coins (doesn't matter what amount - will fail due to no quota)
    let stable_fee = coin::zero<TEST_COIN_B>(ts::ctx(&mut scenario));
    let asset_fee = coin::zero<TEST_COIN_A>(ts::ctx(&mut scenario));

    // 5. Create outcome messages
    let outcome_messages = vector[string::utf8(b"Reject"), string::utf8(b"Accept")];
    let outcome_details = vector[string::utf8(b"No"), string::utf8(b"Yes")];

    // 6. BEGIN PROPOSAL with used_feeless_quota=true (should FAIL - no quota set)
    let (proposal, escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Should Fail"),
        string::utf8(b"No feeless quota set"),
        string::utf8(b"{}"),
        outcome_messages,
        outcome_details,
        ADMIN,
        true, // used_feeless_quota = TRUE but no quota configured!
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    proposal::destroy_for_testing(proposal);
    coin_escrow::destroy_for_testing(escrow);
    proposal::destroy_creation_ticket_for_testing(ticket);
    destroy(account);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

// === finalize_proposal Tests ===

/// Shared helper: set up everything needed for a finalize_proposal call.
/// Returns all objects with conditional coins registered and ready to finalize.
fun setup_ready_to_finalize(
    scenario: &mut Scenario,
): (
    Proposal<TEST_COIN_A, TEST_COIN_B>,
    TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    ProposalCreationTicket<TEST_COIN_A, TEST_COIN_B>,
    Account,
    UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>,
    SpotPoolMutationRegistry,
    MarketStateMutationRegistry,
    EscrowMutationRegistry,
    Clock,
    PackageRegistry,
) {
    // Setup registry
    package_registry::init_for_testing(ts::ctx(scenario));
    ts::next_tx(scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(scenario);
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    // Account, clock, spot pool
    let mut account = create_test_account(&registry, ts::ctx(scenario));
    let clock = create_test_clock(1000000, ts::ctx(scenario));
    let mut spot_pool = create_test_spot_pool(ts::ctx(scenario));

    // Link spot pool to DAO config
    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_spot_pool_id(config, object::id(&spot_pool));

    // Conditional coins
    let (
        cond0_asset_cap, cond0_asset_mcap,
        cond0_stable_cap, cond0_stable_mcap,
        cond1_asset_cap, cond1_asset_mcap,
        cond1_stable_cap, cond1_stable_mcap,
    ) = init_conditional_coins(scenario);

    // Base coins
    ts::next_tx(scenario, ADMIN);
    init_base_coins(scenario);
    ts::next_tx(scenario, ADMIN);
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(scenario);

    // Fee coins and begin proposal
    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(scenario));
    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Test Proposal"),
        string::utf8(b"Test"),
        string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN,
        false,
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(scenario),
    );

    // Add conditional coins for both outcomes
    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(scenario);
    let mut cond1_asset_currency = ts::take_shared<Currency<CONDITIONAL_2>>(scenario);
    let mut cond1_stable_currency = ts::take_shared<Currency<CONDITIONAL_3>>(scenario);

    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal, &mut escrow, 0,
        cond0_asset_cap, &mut cond0_asset_currency, cond0_asset_mcap,
        cond0_stable_cap, &mut cond0_stable_currency, cond0_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(scenario),
    );
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_2, CONDITIONAL_3>(
        &mut proposal, &mut escrow, 1,
        cond1_asset_cap, &mut cond1_asset_currency, cond1_asset_mcap,
        cond1_stable_cap, &mut cond1_stable_currency, cond1_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(scenario),
    );

    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(cond1_asset_currency);
    ts::return_shared(cond1_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);

    // Mutation registries
    let mut market_state_registry = market_state_mutation_auth::new_registry_for_testing(ts::ctx(scenario));
    market_state_mutation_auth::add_authorized_package_for_testing(&mut market_state_registry, @futarchy_proposal);
    let mut spot_pool_mutation_registry = spot_pool_mutation_auth::new_registry_for_testing(ts::ctx(scenario));
    let spot_pool_admin = spot_pool_mutation_auth::new_admin_cap_for_testing(&spot_pool_mutation_registry, ts::ctx(scenario));
    spot_pool_mutation_auth::add_authorized_package(&mut spot_pool_mutation_registry, &spot_pool_admin, @futarchy_proposal);
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(spot_pool_admin);
    let mut escrow_registry = escrow_mutation_auth::create_registry_for_testing(ts::ctx(scenario));
    escrow_mutation_auth::add_authorized_package_for_testing(&mut escrow_registry, @futarchy_proposal);

    (proposal, escrow, ticket, account, spot_pool, spot_pool_mutation_registry, market_state_registry, escrow_registry, clock, registry)
}

/// Shared cleanup for finalize tests that succeed (proposal is shared, not destroyable)
fun cleanup_finalize_success(
    account: Account,
    spot_pool: UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>,
    spot_pool_mutation_registry: SpotPoolMutationRegistry,
    market_state_registry: MarketStateMutationRegistry,
    escrow_registry: EscrowMutationRegistry,
    clock: Clock,
    registry: PackageRegistry,
) {
    destroy(account);
    destroy(spot_pool);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
}

// --- Tier 1: Security Guards ---

#[test]
#[expected_failure(abort_code = proposal::EInvalidState)]
/// finalize_proposal must reject a proposal not in STATE_PREMARKET
fun test_finalize_wrong_state_fails() {
    let mut scenario = ts::begin(ADMIN);
    let (mut proposal, escrow, ticket, account, mut spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    // Advance state past PREMARKET
    proposal::set_state_for_testing(&mut proposal, proposal::state_review());

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
#[expected_failure(abort_code = proposal::EDaoAccountMismatch)]
/// finalize_proposal must reject a dao_account that doesn't match proposal.dao_id
fun test_finalize_wrong_dao_account_fails() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, _account, mut spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    // Create a different account (different DAO ID)
    let wrong_account = create_test_account(&registry, ts::ctx(&mut scenario));

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &wrong_account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
#[expected_failure(abort_code = proposal::EProposalEscrowMismatch)]
/// finalize_proposal must reject an escrow created for a different proposal
fun test_finalize_wrong_escrow_fails() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, _escrow, ticket, mut account, mut spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    // Create a second (proposal, escrow) pair — use that escrow with the first proposal
    let (stable_fee2, asset_fee2) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (_proposal2, wrong_escrow, _ticket2) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Other Proposal"),
        string::utf8(b"Other"),
        string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN,
        false,
        stable_fee2,
        asset_fee2,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, wrong_escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
#[expected_failure(abort_code = proposal::ESpotPoolMismatch)]
/// finalize_proposal must reject a spot pool not linked in DAO config
fun test_finalize_wrong_spot_pool_fails() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, account, _spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    // Create a different spot pool (its ID won't match the one in DAO config)
    let mut wrong_pool = create_test_spot_pool(ts::ctx(&mut scenario));

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut wrong_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
#[expected_failure(abort_code = proposal::ENonAtomicProposalCreation)]
/// finalize_proposal must reject a creation ticket from a different proposal.
fun test_finalize_cross_ptb_fails() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, mut account, mut spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (other_proposal, other_escrow, wrong_ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Other Proposal"),
        string::utf8(b"Other"),
        string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN,
        false,
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );
    proposal::destroy_for_testing(other_proposal);
    coin_escrow::destroy_for_testing(other_escrow);
    proposal::destroy_creation_ticket_for_testing(ticket);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, wrong_ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
#[expected_failure(abort_code = 103, location = futarchy_core::futarchy_config)] // futarchy_config::EDAOTerminated
/// finalize_proposal must reject after the DAO transitions to TERMINATED.
/// Without this check, a proposer could begin a proposal while the DAO is active,
/// hold the unshared objects, and finalize post-shutdown to spawn a live market.
fun test_finalize_after_termination_fails() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, mut account, mut spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    // Terminate the DAO directly via the test-only state accessor.
    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    let dao_state = futarchy_config::dao_state_mut_test(config);
    futarchy_config::set_operational_state(dao_state, futarchy_config::state_terminated());

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
#[expected_failure(abort_code = proposal::ESpotPoolMismatch)]
/// finalize_proposal must reject when DAO config has no spot_pool_id set
fun test_finalize_spot_pool_not_configured_fails() {
    let mut scenario = ts::begin(ADMIN);

    // Manual setup without linking spot pool to DAO config
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));
    let mut spot_pool = create_test_spot_pool(ts::ctx(&mut scenario));
    // NOTE: NOT calling futarchy_config::set_spot_pool_id — spot_pool_id stays None

    let (
        cond0_asset_cap, cond0_asset_mcap,
        cond0_stable_cap, cond0_stable_mcap,
        cond1_asset_cap, cond1_asset_mcap,
        cond1_stable_cap, cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account, &registry,
        string::utf8(b"Test"), string::utf8(b"Test"), string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN, false, stable_fee, asset_fee, option::none(), &clock,
        ts::ctx(&mut scenario),
    );

    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);
    let mut cond1_asset_currency = ts::take_shared<Currency<CONDITIONAL_2>>(&scenario);
    let mut cond1_stable_currency = ts::take_shared<Currency<CONDITIONAL_3>>(&scenario);

    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal, &mut escrow, 0,
        cond0_asset_cap, &mut cond0_asset_currency, cond0_asset_mcap,
        cond0_stable_cap, &mut cond0_stable_currency, cond0_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_2, CONDITIONAL_3>(
        &mut proposal, &mut escrow, 1,
        cond1_asset_cap, &mut cond1_asset_currency, cond1_asset_mcap,
        cond1_stable_cap, &mut cond1_stable_currency, cond1_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(cond1_asset_currency);
    ts::return_shared(cond1_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);

    let mut market_state_registry = market_state_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    market_state_mutation_auth::add_authorized_package_for_testing(&mut market_state_registry, @futarchy_proposal);
    let mut spot_pool_mutation_registry = spot_pool_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    let spot_pool_admin = spot_pool_mutation_auth::new_admin_cap_for_testing(&spot_pool_mutation_registry, ts::ctx(&mut scenario));
    spot_pool_mutation_auth::add_authorized_package(&mut spot_pool_mutation_registry, &spot_pool_admin, @futarchy_proposal);
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(spot_pool_admin);
    let mut escrow_registry = escrow_mutation_auth::create_registry_for_testing(ts::ctx(&mut scenario));
    escrow_mutation_auth::add_authorized_package_for_testing(&mut escrow_registry, @futarchy_proposal);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mutation_registry, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

// --- Tier 2: Liquidity Validation ---

#[test]
#[expected_failure(abort_code = proposal::EAssetLiquidityTooLow)]
/// finalize_proposal must reject when spot pool asset reserves are below minimum
fun test_finalize_insufficient_asset_liquidity_fails() {
    let mut scenario = ts::begin(ADMIN);

    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // Create spot pool with asset reserve below min (default min = 1_000_000)
    let lp_treasury = coin::create_treasury_cap_for_testing<TEST_COIN_A>(ts::ctx(&mut scenario));
    let mut spot_pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        lp_treasury, 30, ts::ctx(&mut scenario),
    );
    // Only 100 asset (below 1_000_000 min), 10B stable
    let asset_bal = balance::create_for_testing<TEST_COIN_A>(100);
    let stable_bal = balance::create_for_testing<TEST_COIN_B>(INITIAL_STABLE_LIQUIDITY);
    unified_spot_pool::add_liquidity_for_testing(&mut spot_pool, asset_bal, stable_bal);

    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_spot_pool_id(config, object::id(&spot_pool));

    let (
        cond0_asset_cap, cond0_asset_mcap,
        cond0_stable_cap, cond0_stable_mcap,
        cond1_asset_cap, cond1_asset_mcap,
        cond1_stable_cap, cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account, &registry,
        string::utf8(b"Test"), string::utf8(b"Test"), string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN, false, stable_fee, asset_fee, option::none(), &clock,
        ts::ctx(&mut scenario),
    );

    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);
    let mut cond1_asset_currency = ts::take_shared<Currency<CONDITIONAL_2>>(&scenario);
    let mut cond1_stable_currency = ts::take_shared<Currency<CONDITIONAL_3>>(&scenario);

    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal, &mut escrow, 0,
        cond0_asset_cap, &mut cond0_asset_currency, cond0_asset_mcap,
        cond0_stable_cap, &mut cond0_stable_currency, cond0_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_2, CONDITIONAL_3>(
        &mut proposal, &mut escrow, 1,
        cond1_asset_cap, &mut cond1_asset_currency, cond1_asset_mcap,
        cond1_stable_cap, &mut cond1_stable_currency, cond1_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(cond1_asset_currency);
    ts::return_shared(cond1_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);

    let mut market_state_registry = market_state_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    market_state_mutation_auth::add_authorized_package_for_testing(&mut market_state_registry, @futarchy_proposal);
    let mut spot_pool_mutation_registry = spot_pool_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    let spot_pool_admin = spot_pool_mutation_auth::new_admin_cap_for_testing(&spot_pool_mutation_registry, ts::ctx(&mut scenario));
    spot_pool_mutation_auth::add_authorized_package(&mut spot_pool_mutation_registry, &spot_pool_admin, @futarchy_proposal);
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(spot_pool_admin);
    let mut escrow_registry = escrow_mutation_auth::create_registry_for_testing(ts::ctx(&mut scenario));
    escrow_mutation_auth::add_authorized_package_for_testing(&mut escrow_registry, @futarchy_proposal);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mutation_registry, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
#[expected_failure(abort_code = proposal::EStableLiquidityTooLow)]
/// finalize_proposal must reject when spot pool stable reserves are below minimum
fun test_finalize_insufficient_stable_liquidity_fails() {
    let mut scenario = ts::begin(ADMIN);

    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // Create spot pool with stable reserve below min (default min = 1_000_000)
    let lp_treasury = coin::create_treasury_cap_for_testing<TEST_COIN_A>(ts::ctx(&mut scenario));
    let mut spot_pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        lp_treasury, 30, ts::ctx(&mut scenario),
    );
    // 10B asset, only 100 stable (below min)
    let asset_bal = balance::create_for_testing<TEST_COIN_A>(INITIAL_ASSET_LIQUIDITY);
    let stable_bal = balance::create_for_testing<TEST_COIN_B>(100);
    unified_spot_pool::add_liquidity_for_testing(&mut spot_pool, asset_bal, stable_bal);

    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_spot_pool_id(config, object::id(&spot_pool));

    let (
        cond0_asset_cap, cond0_asset_mcap,
        cond0_stable_cap, cond0_stable_mcap,
        cond1_asset_cap, cond1_asset_mcap,
        cond1_stable_cap, cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account, &registry,
        string::utf8(b"Test"), string::utf8(b"Test"), string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN, false, stable_fee, asset_fee, option::none(), &clock,
        ts::ctx(&mut scenario),
    );

    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);
    let mut cond1_asset_currency = ts::take_shared<Currency<CONDITIONAL_2>>(&scenario);
    let mut cond1_stable_currency = ts::take_shared<Currency<CONDITIONAL_3>>(&scenario);

    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal, &mut escrow, 0,
        cond0_asset_cap, &mut cond0_asset_currency, cond0_asset_mcap,
        cond0_stable_cap, &mut cond0_stable_currency, cond0_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_2, CONDITIONAL_3>(
        &mut proposal, &mut escrow, 1,
        cond1_asset_cap, &mut cond1_asset_currency, cond1_asset_mcap,
        cond1_stable_cap, &mut cond1_stable_currency, cond1_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(cond1_asset_currency);
    ts::return_shared(cond1_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);

    let mut market_state_registry = market_state_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    market_state_mutation_auth::add_authorized_package_for_testing(&mut market_state_registry, @futarchy_proposal);
    let mut spot_pool_mutation_registry = spot_pool_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    let spot_pool_admin = spot_pool_mutation_auth::new_admin_cap_for_testing(&spot_pool_mutation_registry, ts::ctx(&mut scenario));
    spot_pool_mutation_auth::add_authorized_package(&mut spot_pool_mutation_registry, &spot_pool_admin, @futarchy_proposal);
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(spot_pool_admin);
    let mut escrow_registry = escrow_mutation_auth::create_registry_for_testing(ts::ctx(&mut scenario));
    escrow_mutation_auth::add_authorized_package_for_testing(&mut escrow_registry, @futarchy_proposal);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mutation_registry, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
/// finalize_proposal succeeds when spot pool reserves are exactly at minimum
fun test_finalize_exact_minimum_liquidity_succeeds() {
    let mut scenario = ts::begin(ADMIN);

    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // Create spot pool with exactly 1_000_000 in each reserve (default min_asset/stable_amount)
    let lp_treasury = coin::create_treasury_cap_for_testing<TEST_COIN_A>(ts::ctx(&mut scenario));
    let mut spot_pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        lp_treasury, 30, ts::ctx(&mut scenario),
    );
    let asset_bal = balance::create_for_testing<TEST_COIN_A>(1_000_000);
    let stable_bal = balance::create_for_testing<TEST_COIN_B>(1_000_000);
    unified_spot_pool::add_liquidity_for_testing(&mut spot_pool, asset_bal, stable_bal);

    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_spot_pool_id(config, object::id(&spot_pool));

    let (
        cond0_asset_cap, cond0_asset_mcap,
        cond0_stable_cap, cond0_stable_mcap,
        cond1_asset_cap, cond1_asset_mcap,
        cond1_stable_cap, cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account, &registry,
        string::utf8(b"Test"), string::utf8(b"Test"), string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN, false, stable_fee, asset_fee, option::none(), &clock,
        ts::ctx(&mut scenario),
    );

    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);
    let mut cond1_asset_currency = ts::take_shared<Currency<CONDITIONAL_2>>(&scenario);
    let mut cond1_stable_currency = ts::take_shared<Currency<CONDITIONAL_3>>(&scenario);

    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal, &mut escrow, 0,
        cond0_asset_cap, &mut cond0_asset_currency, cond0_asset_mcap,
        cond0_stable_cap, &mut cond0_stable_currency, cond0_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_2, CONDITIONAL_3>(
        &mut proposal, &mut escrow, 1,
        cond1_asset_cap, &mut cond1_asset_currency, cond1_asset_mcap,
        cond1_stable_cap, &mut cond1_stable_currency, cond1_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(cond1_asset_currency);
    ts::return_shared(cond1_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);

    let mut market_state_registry = market_state_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    market_state_mutation_auth::add_authorized_package_for_testing(&mut market_state_registry, @futarchy_proposal);
    let mut spot_pool_mutation_registry = spot_pool_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    let spot_pool_admin = spot_pool_mutation_auth::new_admin_cap_for_testing(&spot_pool_mutation_registry, ts::ctx(&mut scenario));
    spot_pool_mutation_auth::add_authorized_package(&mut spot_pool_mutation_registry, &spot_pool_admin, @futarchy_proposal);
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(spot_pool_admin);
    let mut escrow_registry = escrow_mutation_auth::create_registry_for_testing(ts::ctx(&mut scenario));
    escrow_mutation_auth::add_authorized_package_for_testing(&mut escrow_registry, @futarchy_proposal);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mutation_registry, &clock,
        ts::ctx(&mut scenario),
    );

    // Success — cleanup
    destroy(account);
    destroy(spot_pool);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

// --- Tier 3: Partial Conditional Coin Registration ---

#[test]
#[expected_failure(abort_code = proposal::EMissingConditionalCoins)]
/// finalize_proposal must reject when only some outcomes have conditional coins registered
fun test_finalize_partial_conditional_coins_fails() {
    let mut scenario = ts::begin(ADMIN);

    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));
    let mut spot_pool = create_test_spot_pool(ts::ctx(&mut scenario));

    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_spot_pool_id(config, object::id(&spot_pool));

    let (
        cond0_asset_cap, cond0_asset_mcap,
        cond0_stable_cap, cond0_stable_mcap,
        cond1_asset_cap, cond1_asset_mcap,
        cond1_stable_cap, cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account, &registry,
        string::utf8(b"Test"), string::utf8(b"Test"), string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN, false, stable_fee, asset_fee, option::none(), &clock,
        ts::ctx(&mut scenario),
    );

    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);

    // Only add coins for outcome 0 — skip outcome 1
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal, &mut escrow, 0,
        cond0_asset_cap, &mut cond0_asset_currency, cond0_asset_mcap,
        cond0_stable_cap, &mut cond0_stable_currency, cond0_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);

    // Destroy unused outcome 1 caps
    destroy(cond1_asset_cap);
    destroy(cond1_asset_mcap);
    destroy(cond1_stable_cap);
    destroy(cond1_stable_mcap);

    let mut market_state_registry = market_state_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    market_state_mutation_auth::add_authorized_package_for_testing(&mut market_state_registry, @futarchy_proposal);
    let mut spot_pool_mutation_registry = spot_pool_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    let spot_pool_admin = spot_pool_mutation_auth::new_admin_cap_for_testing(&spot_pool_mutation_registry, ts::ctx(&mut scenario));
    spot_pool_mutation_auth::add_authorized_package(&mut spot_pool_mutation_registry, &spot_pool_admin, @futarchy_proposal);
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(spot_pool_admin);
    let escrow_registry = escrow_mutation_auth::create_registry_for_testing(ts::ctx(&mut scenario));

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mutation_registry, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

// --- Tier 4: TWAP Initial Observation ---

#[test]
/// finalize_proposal no longer computes twap_initial_observation (deferred to advance_state).
/// FIX #12: observation is computed from fresh spot reserves at REVIEW->TRADING transition.
fun test_finalize_twap_observation_deferred_to_advance_state() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, mut account, mut spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    // Before finalize: twap_initial_observation is None (default)
    assert!(proposal::get_twap_initial_observation(&proposal).is_none(), 0);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    // After finalize: observation should STILL be None — computed at advance_state time
    ts::next_tx(&mut scenario, ADMIN);
    let proposal = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);
    let twap_obs = proposal::get_twap_initial_observation(&proposal);
    assert!(twap_obs.is_none(), 1);

    ts::return_shared(proposal);
    cleanup_finalize_success(account, spot_pool, spot_pool_mr, market_state_mr, escrow_mr, clock, registry);
    ts::end(scenario);
}

#[test]
/// finalize_proposal preserves an existing twap_initial_observation when preset
fun test_finalize_twap_observation_preserved_when_preset() {
    let mut scenario = ts::begin(ADMIN);

    // Build a custom DaoConfig with a preset twap_initial_observation
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);
    package_registry::add_for_testing(&mut registry, b"FutarchyCore".to_string(), @futarchy_core, 1);
    package_registry::add_for_testing(&mut registry, b"AccountActions".to_string(), @account_actions, 1);
    package_registry::add_for_testing(&mut registry, b"AccountProtocol".to_string(), @account_protocol, 1);

    let preset_observation: u128 = 500_000_000_000; // 0.5 in 1e12 scale
    let trading_params = dao_config::default_trading_params();
    let twap_config = dao_config::new_twap_config(
        0, // start_delay
        dao_config::cap_ppm(&dao_config::default_twap_config()),
        option::some(preset_observation), // preset initial observation
        dao_config::threshold(&dao_config::default_twap_config()),
    );
    let governance_config = dao_config::default_governance_config();
    let metadata_config = dao_config::new_metadata_config(
        ascii::string(b"TestDAO"),
        url::new_unsafe_from_bytes(b"https://test.dao/icon.png"),
        string::utf8(b"A test DAO"),
    );
    let conditional_coin_config = dao_config::default_conditional_coin_config();
    let sponsorship_config = dao_config::default_sponsorship_config();

    let dao_config = dao_config::new_dao_config(
        trading_params, twap_config, governance_config,
        metadata_config, conditional_coin_config, sponsorship_config,
    );
    let futarchy_cfg = futarchy_config::new<TEST_COIN_A, TEST_COIN_B>(dao_config, option::none());
    let mut account = futarchy_config::new_account_test(futarchy_cfg, &registry, ts::ctx(&mut scenario));

    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));
    let mut spot_pool = create_test_spot_pool(ts::ctx(&mut scenario));

    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_spot_pool_id(config, object::id(&spot_pool));

    let (
        cond0_asset_cap, cond0_asset_mcap,
        cond0_stable_cap, cond0_stable_mcap,
        cond1_asset_cap, cond1_asset_mcap,
        cond1_stable_cap, cond1_stable_mcap,
    ) = init_conditional_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    init_base_coins(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let base_asset_currency = ts::take_shared<Currency<TEST_COIN_A>>(&scenario);
    let base_stable_currency = ts::take_shared<Currency<TEST_COIN_B>>(&scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (mut proposal, mut escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account, &registry,
        string::utf8(b"Test"), string::utf8(b"Test"), string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN, false, stable_fee, asset_fee, option::none(), &clock,
        ts::ctx(&mut scenario),
    );

    // Verify the preset observation was carried into the proposal
    let obs_before = proposal::get_twap_initial_observation(&proposal);
    assert!(obs_before.is_some(), 0);
    assert!(*obs_before.borrow() == preset_observation, 1);

    let mut cond0_asset_currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let mut cond0_stable_currency = ts::take_shared<Currency<CONDITIONAL_1>>(&scenario);
    let mut cond1_asset_currency = ts::take_shared<Currency<CONDITIONAL_2>>(&scenario);
    let mut cond1_stable_currency = ts::take_shared<Currency<CONDITIONAL_3>>(&scenario);

    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_0, CONDITIONAL_1>(
        &mut proposal, &mut escrow, 0,
        cond0_asset_cap, &mut cond0_asset_currency, cond0_asset_mcap,
        cond0_stable_cap, &mut cond0_stable_currency, cond0_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );
    proposal::add_outcome_coins<TEST_COIN_A, TEST_COIN_B, CONDITIONAL_2, CONDITIONAL_3>(
        &mut proposal, &mut escrow, 1,
        cond1_asset_cap, &mut cond1_asset_currency, cond1_asset_mcap,
        cond1_stable_cap, &mut cond1_stable_currency, cond1_stable_mcap,
        &account, &base_asset_currency, &base_stable_currency,
        ts::ctx(&mut scenario),
    );

    ts::return_shared(cond0_asset_currency);
    ts::return_shared(cond0_stable_currency);
    ts::return_shared(cond1_asset_currency);
    ts::return_shared(cond1_stable_currency);
    ts::return_shared(base_asset_currency);
    ts::return_shared(base_stable_currency);

    let mut market_state_registry = market_state_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    market_state_mutation_auth::add_authorized_package_for_testing(&mut market_state_registry, @futarchy_proposal);
    let mut spot_pool_mutation_registry = spot_pool_mutation_auth::new_registry_for_testing(ts::ctx(&mut scenario));
    let spot_pool_admin = spot_pool_mutation_auth::new_admin_cap_for_testing(&spot_pool_mutation_registry, ts::ctx(&mut scenario));
    spot_pool_mutation_auth::add_authorized_package(&mut spot_pool_mutation_registry, &spot_pool_admin, @futarchy_proposal);
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(spot_pool_admin);
    let mut escrow_registry = escrow_mutation_auth::create_registry_for_testing(ts::ctx(&mut scenario));
    escrow_mutation_auth::add_authorized_package_for_testing(&mut escrow_registry, @futarchy_proposal);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mutation_registry, &clock,
        ts::ctx(&mut scenario),
    );

    // After finalize: verify preset observation was preserved (not overwritten by spot reserves)
    ts::next_tx(&mut scenario, ADMIN);
    let finalized_proposal = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);
    let obs_after = proposal::get_twap_initial_observation(&finalized_proposal);
    assert!(obs_after.is_some(), 2);
    assert!(*obs_after.borrow() == preset_observation, 3);

    ts::return_shared(finalized_proposal);
    destroy(account);
    destroy(spot_pool);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

// --- Tier 5: Spot Pool State Machine ---

#[test]
#[expected_failure(abort_code = unified_spot_pool::EProposalActive)]
/// finalize_proposal must reject when spot pool already has a non-finalized active escrow
fun test_finalize_with_active_non_finalized_escrow_fails() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, mut account, mut spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    // Plant a non-finalized escrow in the spot pool
    let blocking_escrow = coin_escrow::create_for_testing<TEST_COIN_A, TEST_COIN_B>(
        2, // outcome_count
        30, // fee_bps
        ts::ctx(&mut scenario),
    );
    unified_spot_pool::set_active_escrow_for_testing(&mut spot_pool, blocking_escrow);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

// --- Tier 6: Post-Finalization State Assertions ---

#[test]
/// After finalize_proposal: verify state, escrow_id, market_state_id,
/// liquidity_provider, and market_initialized_at are all set correctly
fun test_finalize_sets_proposal_state_and_fields() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, account, mut spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    // After finalize, proposal is shared — take it and verify all fields
    ts::next_tx(&mut scenario, ADMIN);
    let proposal = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);

    // State transitions to REVIEW
    assert!(proposal::get_state(&proposal) == proposal::state_review(), 0);

    // escrow_id and market_state_id are set (non-None)
    // These accessors assert is_some internally, so calling them proves they're set
    let _escrow_id = proposal::escrow_id(&proposal);
    let _market_state_id = proposal::market_state_id(&proposal);

    // market_initialized_at is set to the clock time (1000000)
    assert!(proposal::get_market_initialized_at(&proposal) == 1000000, 1);

    // liquidity_provider is set to the original proposer.
    let lp = proposal::get_liquidity_provider(&proposal);
    assert!(lp.is_some(), 2);
    assert!(*lp.borrow() == ADMIN, 3);

    ts::return_shared(proposal);
    cleanup_finalize_success(account, spot_pool, spot_pool_mr, market_state_mr, escrow_mr, clock, registry);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal::ENoQuotaAvailable)]
/// Regression test: feeless quota is consumed inside begin_proposal and cannot be reused.
fun test_feeless_quota_is_consumed_atomically_in_begin() {
    let mut scenario = ts::begin(ADMIN);

    // 1. Setup: Create PackageRegistry
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);

    // Register required packages
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyCore".to_string(),
        @futarchy_core,
        1,
    );
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

    // 2. Create test Account with FutarchyConfig
    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));

    // 3. Create test clock
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // 4. Give exactly one feeless proposal quota slot to ADMIN
    let dao_id = object::id(&account);
    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_quota_for_testing(
        config,
        dao_id,
        ADMIN,
        86400000, // period_ms: 1 day
        1, // feeless_proposal_amount: exactly one free proposal
        0, // sponsor_amount
        &clock,
    );

    // 5. First feeless begin_proposal should succeed and consume quota
    let stable_fee_one = coin::zero<TEST_COIN_B>(ts::ctx(&mut scenario));
    let asset_fee_one = coin::zero<TEST_COIN_A>(ts::ctx(&mut scenario));
    let (proposal_one, escrow_one, ticket_one) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"First Feeless Proposal"),
        string::utf8(b"This should consume the only quota slot"),
        string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN,
        true,
        stable_fee_one,
        asset_fee_one,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );
    proposal::destroy_for_testing(proposal_one);
    coin_escrow::destroy_for_testing(escrow_one);
    proposal::destroy_creation_ticket_for_testing(ticket_one);

    // 6. Second feeless begin_proposal must fail with ENoQuotaAvailable
    let stable_fee_two = coin::zero<TEST_COIN_B>(ts::ctx(&mut scenario));
    let asset_fee_two = coin::zero<TEST_COIN_A>(ts::ctx(&mut scenario));
    let (proposal_two, escrow_two, ticket_two) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Second Feeless Proposal"),
        string::utf8(b"Should fail because quota was already consumed"),
        string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN,
        true,
        stable_fee_two,
        asset_fee_two,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    proposal::destroy_for_testing(proposal_two);
    coin_escrow::destroy_for_testing(escrow_two);
    proposal::destroy_creation_ticket_for_testing(ticket_two);
    destroy(account);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = proposal::ENotProposer)]
/// Regression test: feeless quota usage requires sender == proposer.
fun test_feeless_quota_requires_sender_to_match_proposer() {
    let mut scenario = ts::begin(ADMIN);

    // 1. Setup: Create PackageRegistry
    package_registry::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<PackageRegistry>(&scenario);

    // Register required packages
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyCore".to_string(),
        @futarchy_core,
        1,
    );
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

    // 2. Create test Account with FutarchyConfig
    let mut account = create_test_account(&registry, ts::ctx(&mut scenario));

    // 3. Create test clock
    let clock = create_test_clock(1000000, ts::ctx(&mut scenario));

    // 4. Give one feeless proposal quota slot to PROPOSER
    let dao_id = object::id(&account);
    let config = futarchy_config::internal_config_mut_test(&mut account, &registry);
    futarchy_config::set_quota_for_testing(
        config,
        dao_id,
        PROPOSER,
        86400000, // period_ms: 1 day
        1, // feeless_proposal_amount
        0, // sponsor_amount
        &clock,
    );

    // 5. Sender is ADMIN, but proposer is PROPOSER. This must fail with ENotProposer.
    let stable_fee = coin::zero<TEST_COIN_B>(ts::ctx(&mut scenario));
    let asset_fee = coin::zero<TEST_COIN_A>(ts::ctx(&mut scenario));
    let (proposal, escrow, ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Mismatched Sender and Proposer"),
        string::utf8(b"Should fail due to sender/proposer mismatch"),
        string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        PROPOSER,
        true,
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    proposal::destroy_for_testing(proposal);
    coin_escrow::destroy_for_testing(escrow);
    proposal::destroy_creation_ticket_for_testing(ticket);
    destroy(account);
    clock::destroy_for_testing(clock);
    ts::return_shared(registry);
    ts::end(scenario);
}

// --- Atomic creation + termination guards on finalize_proposal ---

#[test]
#[expected_failure(abort_code = 55, location = futarchy_proposal::proposal)]
/// finalize_proposal must abort with ENonAtomicProposalCreation (55) when the
/// consumed creation ticket does not match the proposal.
fun test_finalize_rejects_non_atomic_proposal_creation() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, mut account, mut spot_pool,
        spot_pool_mr, _market_state_mr, _escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    let (stable_fee, asset_fee) = create_fee_coins_for_proposal(&account, 2, ts::ctx(&mut scenario));
    let (other_proposal, other_escrow, wrong_ticket) = proposal::begin_proposal<TEST_COIN_A, TEST_COIN_B>(
        &mut account,
        &registry,
        string::utf8(b"Other Proposal"),
        string::utf8(b"Other"),
        string::utf8(b"{}"),
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        vector[string::utf8(b"No"), string::utf8(b"Yes")],
        ADMIN,
        false,
        stable_fee,
        asset_fee,
        option::none(),
        &clock,
        ts::ctx(&mut scenario),
    );
    proposal::destroy_for_testing(other_proposal);
    coin_escrow::destroy_for_testing(other_escrow);
    proposal::destroy_creation_ticket_for_testing(ticket);

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, wrong_ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
#[expected_failure(abort_code = 103, location = futarchy_core::futarchy_config)] // EDAOTerminated
/// finalize_proposal must abort with EDAOTerminated when the DAO was terminated
/// between begin and finalize. begin_proposal already asserts not terminated, but
/// a proposer holding unshared objects could wait until the DAO terminates and then
/// finalize to spawn a live market post-shutdown. This mirrors the begin-time check.
fun test_finalize_rejects_after_dao_terminated() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, mut account, mut spot_pool,
        spot_pool_mr, _market_state_mr, _escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    // Terminate the DAO after the proposal is begun but before finalize.
    {
        let cfg = futarchy_config::internal_config_mut_test(&mut account, &registry);
        let dao_state = futarchy_config::dao_state_mut_test(cfg);
        futarchy_core::futarchy_config::set_operational_state(
            dao_state,
            futarchy_core::futarchy_config::state_terminated(),
        );
    };

    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    abort 0
}

#[test]
#[expected_failure(abort_code = 17, location = futarchy_proposal::proposal)]
/// set_withdraw_only_mode must reject a caller who is not the liquidity provider.
/// After finalize_proposal the LP is set to ADMIN, so PROPOSER
/// (a different tx sender) must be rejected with ENotLiquidityProvider.
fun test_set_withdraw_only_by_non_proposer_fails() {
    let mut scenario = ts::begin(ADMIN);
    let (proposal, escrow, ticket, account, mut spot_pool,
        spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    ) = setup_ready_to_finalize(&mut scenario);

    // Finalize — this sets liquidity_provider = ADMIN and shares the proposal
    proposal::finalize_proposal<TEST_COIN_A, TEST_COIN_B, TEST_COIN_A>(
        proposal, escrow, ticket, &account, &mut spot_pool,
        &spot_pool_mr, &clock,
        ts::ctx(&mut scenario),
    );

    // Advance tx to retrieve the now-shared proposal
    ts::next_tx(&mut scenario, PROPOSER);
    let mut shared_proposal = ts::take_shared<Proposal<TEST_COIN_A, TEST_COIN_B>>(&scenario);

    // PROPOSER (sender) != ADMIN (liquidity_provider) — must abort with ENotLiquidityProvider
    proposal::set_withdraw_only_mode<TEST_COIN_A, TEST_COIN_B>(
        &mut shared_proposal,
        true,
        ts::ctx(&mut scenario),
    );

    // Cleanup (won't reach here)
    ts::return_shared(shared_proposal);
    cleanup_finalize_success(
        account, spot_pool, spot_pool_mr, market_state_mr, escrow_mr, clock, registry,
    );
    ts::end(scenario);
}
