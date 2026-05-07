#[test_only]
module futarchy_oracle::oracle_integration_tests;

use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::metadata;
use account_protocol::package_registry::{Self, PackageRegistry, PackageAdminCap};
use futarchy_core::dao_config;
use futarchy_core::futarchy_config;
use futarchy_one_shot_utils::constants;
use futarchy_oracle::oracle_actions::{Self, PriceBasedMintGrant};
use std::string;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;
use sui::url;

// === Test Coin Types ===

public struct TEST_ASSET has drop {}
public struct TEST_STABLE has drop {}

// === Test Constants ===

const OWNER: address = @0xCAFE;
const RECIPIENT1: address = @0xBEEF;
const RECIPIENT2: address = @0xDEAD;
const RECIPIENT3: address = @0xF00D;

// === Helper Functions ===

fun start(): (Scenario, PackageRegistry, Account, Clock) {
    let mut scenario = ts::begin(OWNER);
    package_registry::init_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);

    let mut registry = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();

    // Register packages with their actual addresses from Move.toml
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
    package_registry::add_for_testing(
        &mut registry,
        b"FutarchyOracle".to_string(),
        @futarchy_oracle,
        1,
    );

    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    // Create minimal DaoConfig for testing
    let metadata_config = dao_config::new_metadata_config(
        b"TestDAO".to_ascii_string(),
        url::new_unsafe_from_bytes(b"https://test.com"),
        string::utf8(b"Test DAO for oracle tests"),
    );

    let dao_config = dao_config::new_dao_config(
        dao_config::default_trading_params(),
        dao_config::default_twap_config(),
        dao_config::default_governance_config(),
        metadata_config,
        dao_config::default_conditional_coin_config(),
        dao_config::default_sponsorship_config(),
    );

    // Create futarchy config with launchpad price (write-once at construction)
    let config = futarchy_config::new<TEST_ASSET, TEST_STABLE>(
        dao_config,
        option::some(1_000_000_000_000u128), // 1.0 price
    );

    let mut account = account::new(
        config,
        metadata::empty(),
        deps,
        futarchy_config::witness_for_testing(),
        scenario.ctx(),
    );

    let clock = clock::create_for_testing(scenario.ctx());
    destroy(cap);
    (scenario, registry, account, clock)
}

fun end(scenario: Scenario, registry: PackageRegistry, account: Account, clock: Clock) {
    destroy(registry);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

fun create_grant_with_test_cap(
    account: &mut Account,
    registry: &PackageRegistry,
    tiers: vector<oracle_actions::PriceTier>,
    use_relative_pricing: bool,
    launchpad_multiplier: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    cancelable: bool,
    description: std::string::String,
    twap_window_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let dao_id = object::id(account);
    let mint_cap = account_actions::currency::create_mint_admin_cap_for_testing<TEST_ASSET>(
        dao_id,
        ctx,
    );
    oracle_actions::create_grant<TEST_ASSET, TEST_STABLE>(
        account,
        registry,
        tiers,
        use_relative_pricing,
        launchpad_multiplier,
        earliest_execution_offset_ms,
        expiry_years,
        cancelable,
        description,
        dao_id,
        mint_cap,
        twap_window_ms,
        clock,
        ctx,
    )
}

// === Integration Tests ===

#[test]
/// Test creating a grant with a single tier
fun test_create_grant_single_tier() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(1000);

    // Create tier with single recipient
    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 1000)];

    let tier_spec = oracle_actions::new_tier_spec(
        2_000_000_000_000u128, // 2.0 price
        true, // unlock above
        recipients,
        string::utf8(b"Tier 1"),
    );

    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier_spec]);

    // Create grant
    let dao_id = object::id(&account);
    let grant_id = create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers,
        false, // use_relative_pricing (absolute prices)
        0, // no launchpad multiplier
        0, // immediate execution
        0, // no expiry
        true, // cancelable
        string::utf8(b"Test Grant"),
        constants::thirty_days_ms(), // twap_window_ms
        &clock,
        scenario.ctx(),
    );

    // Verify grant was created
    assert!(grant_id != object::id_from_address(@0x0), 0);

    // Verify grant appears in registry
    let grant_ids = oracle_actions::get_all_grant_ids(
        &account,
        &registry,
    );
    assert!(grant_ids.length() == 1, 1);
    assert!(*grant_ids.borrow(0) == grant_id, 2);

    end(scenario, registry, account, clock);
}

#[test]
/// Test creating multiple grants
fun test_create_multiple_grants() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(2000);

    // Create first grant
    let recipients1 = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 500)];
    let tier1 = oracle_actions::new_tier_spec(
        1_000_000_000_000u128,
        true,
        recipients1,
        string::utf8(b"Grant 1 Tier"),
    );
    let tiers1 = oracle_actions::convert_tier_specs_for_testing(vector[tier1]);

    let dao_id = object::id(&account);
    let grant_id1 = create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers1,
        false, // use_relative_pricing (absolute prices)
        0,
        0,
        0,
        true,
        string::utf8(b"Grant 1"),
        constants::thirty_days_ms(), // twap_window_ms
        &clock,
        scenario.ctx(),
    );

    // Create second grant
    let recipients2 = vector[oracle_actions::new_recipient_mint(RECIPIENT2, 1000)];
    let tier2 = oracle_actions::new_tier_spec(
        3_000_000_000_000u128,
        false,
        recipients2,
        string::utf8(b"Grant 2 Tier"),
    );
    let tiers2 = oracle_actions::convert_tier_specs_for_testing(vector[tier2]);

    let grant_id2 = create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers2,
        false, // use_relative_pricing (absolute prices)
        0,
        0,
        0,
        false,
        string::utf8(b"Grant 2"),
        constants::thirty_days_ms(), // twap_window_ms
        &clock,
        scenario.ctx(),
    );

    // Verify both grants exist in registry
    let grant_ids = oracle_actions::get_all_grant_ids(
        &account,
        &registry,
    );
    assert!(grant_ids.length() == 2, 0);
    assert!(*grant_ids.borrow(0) == grant_id1, 1);
    assert!(*grant_ids.borrow(1) == grant_id2, 2);

    end(scenario, registry, account, clock);
}

#[test]
/// Test creating grant with multiple tiers and recipients
fun test_create_grant_multi_tier() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(3000);

    // Tier 1: Multiple recipients
    let tier1_recipients = vector[
        oracle_actions::new_recipient_mint(RECIPIENT1, 100),
        oracle_actions::new_recipient_mint(RECIPIENT2, 200),
        oracle_actions::new_recipient_mint(RECIPIENT3, 300),
    ];
    let tier1 = oracle_actions::new_tier_spec(
        2_000_000_000_000u128,
        true,
        tier1_recipients,
        string::utf8(b"Low Tier"),
    );

    // Tier 2: Different recipients
    let tier2_recipients = vector[
        oracle_actions::new_recipient_mint(RECIPIENT1, 500),
        oracle_actions::new_recipient_mint(RECIPIENT3, 700),
    ];
    let tier2 = oracle_actions::new_tier_spec(
        5_000_000_000_000u128,
        true,
        tier2_recipients,
        string::utf8(b"High Tier"),
    );

    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier1, tier2]);

    let dao_id = object::id(&account);
    let grant_id = create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers,
        false, // use_relative_pricing (absolute prices)
        1_500_000_000_000, // 1.5x launchpad multiplier (1e12 scale)
        30 * 24 * 60 * 60 * 1000, // 30 days earliest
        2, // 2 year expiry
        false, // not cancelable
        string::utf8(b"Multi-Tier Grant"),
        constants::thirty_days_ms(), // twap_window_ms
        &clock,
        scenario.ctx(),
    );

    assert!(grant_id != object::id_from_address(@0x0), 0);

    end(scenario, registry, account, clock);
}

#[test]
/// Absolute-price grants snapshot launchpad price but do not store inactive multiplier enforcement
fun test_absolute_grant_ignores_launchpad_multiplier_enforcement() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(3500);

    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 1000)];
    let tier = oracle_actions::new_tier_spec(
        2_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Absolute Tier"),
    );
    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier]);

    create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers,
        false,
        1_500_000_000_000,
        0,
        0,
        true,
        string::utf8(b"Absolute Grant"),
        constants::thirty_days_ms(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(OWNER);
    {
        let grant = scenario.take_shared<PriceBasedMintGrant<TEST_ASSET, TEST_STABLE>>();

        assert!(!oracle_actions::launchpad_enforcement_enabled_for_testing(&grant), 0);
        assert!(oracle_actions::launchpad_minimum_multiplier_for_testing(&grant) == 0, 1);
        assert!(
            oracle_actions::launchpad_price_for_testing(&grant) == 1_000_000_000_000u128,
            2,
        );

        ts::return_shared(grant);
    };

    end(scenario, registry, account, clock);
}

#[test]
/// Test grant view functions
fun test_grant_view_functions() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(4000);

    let recipients = vector[
        oracle_actions::new_recipient_mint(RECIPIENT1, 1000),
        oracle_actions::new_recipient_mint(RECIPIENT2, 500),
    ];
    let tier = oracle_actions::new_tier_spec(
        2_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Test Tier"),
    );
    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier]);

    let dao_id = object::id(&account);
    let _grant_id = create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers,
        false, // use_relative_pricing (absolute prices)
        0,
        0,
        0,
        true,
        string::utf8(b"View Test Grant"),
        constants::thirty_days_ms(), // twap_window_ms
        &clock,
        scenario.ctx(),
    );

    // Advance transaction to retrieve the shared grant
    scenario.next_tx(OWNER);
    {
        let grant = scenario.take_shared<PriceBasedMintGrant<TEST_ASSET, TEST_STABLE>>();

        // Test view functions
        let total = oracle_actions::total_amount(&grant);
        assert!(total == 1500, 0); // 1000 + 500

        let canceled = oracle_actions::is_canceled(&grant);
        assert!(!canceled, 1);

        let desc = oracle_actions::description(&grant);
        assert!(desc == &string::utf8(b"View Test Grant"), 2);

        let tier_count = oracle_actions::tier_count(&grant);
        assert!(tier_count == 1, 3);

        ts::return_shared(grant);
    };

    end(scenario, registry, account, clock);
}

#[test]
/// Test canceling a cancelable grant
fun test_cancel_grant_success() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(5000);

    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 1000)];
    let tier = oracle_actions::new_tier_spec(
        2_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Cancel Test"),
    );
    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier]);

    let dao_id = object::id(&account);
    create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers,
        false, // use_relative_pricing (absolute prices)
        0,
        0,
        0,
        true, // cancelable = true
        string::utf8(b"Cancelable Grant"),
        constants::thirty_days_ms(), // twap_window_ms
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(OWNER);
    {
        let mut grant = scenario.take_shared<PriceBasedMintGrant<TEST_ASSET, TEST_STABLE>>();

        // Verify not canceled initially
        assert!(!oracle_actions::is_canceled(&grant), 0);

        // Cancel the grant
        oracle_actions::cancel_grant(&mut grant, &clock);

        // Verify now canceled
        assert!(oracle_actions::is_canceled(&grant), 1);

        ts::return_shared(grant);
    };

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = oracle_actions::EGrantNotCancelable)]
/// Test that canceling a non-cancelable grant fails
fun test_cancel_non_cancelable_grant_fails() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(6000);

    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 1000)];
    let tier = oracle_actions::new_tier_spec(
        2_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Non-Cancelable"),
    );
    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier]);

    let dao_id = object::id(&account);
    create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers,
        false, // use_relative_pricing (absolute prices)
        0,
        0,
        0,
        false, // cancelable = false
        string::utf8(b"Non-Cancelable Grant"),
        constants::thirty_days_ms(), // twap_window_ms
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(OWNER);
    {
        let mut grant = scenario.take_shared<PriceBasedMintGrant<TEST_ASSET, TEST_STABLE>>();

        // This should fail
        oracle_actions::cancel_grant(&mut grant, &clock);

        ts::return_shared(grant);
    };

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = oracle_actions::EAlreadyCanceled)]
/// Test that canceling an already-canceled grant fails
fun test_cancel_already_canceled_fails() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(7000);

    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 1000)];
    let tier = oracle_actions::new_tier_spec(
        2_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Double Cancel Test"),
    );
    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier]);

    let dao_id = object::id(&account);
    create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers,
        false, // use_relative_pricing (absolute prices)
        0,
        0,
        0,
        true,
        string::utf8(b"Grant"),
        constants::thirty_days_ms(), // twap_window_ms
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(OWNER);
    {
        let mut grant = scenario.take_shared<PriceBasedMintGrant<TEST_ASSET, TEST_STABLE>>();

        // First cancel succeeds
        oracle_actions::cancel_grant(&mut grant, &clock);

        // Second cancel should fail
        oracle_actions::cancel_grant(&mut grant, &clock);

        ts::return_shared(grant);
    };

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = oracle_actions::EEmptyTiers)]
/// Test that creating grant with empty tiers fails
fun test_create_grant_empty_tiers_fails() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(8000);

    let empty_tiers = vector[];

    // Should fail with EEmptyTiers
    let dao_id = object::id(&account);
    create_grant_with_test_cap(
        &mut account,
        &registry,
        empty_tiers,
        false, // use_relative_pricing (absolute prices)
        0,
        0,
        0,
        true,
        string::utf8(b"Empty Grant"),
        constants::thirty_days_ms(), // twap_window_ms
        &clock,
        scenario.ctx(),
    );

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = oracle_actions::EZeroAmount, location = futarchy_oracle::oracle_actions)]
fun test_create_grant_rejects_zero_recipient_amount() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(8100);

    let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 0)];
    let tier = oracle_actions::new_tier_spec(
        2_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Zero Amount Tier"),
    );
    let tiers = oracle_actions::convert_tier_specs_for_testing(vector[tier]);

    let dao_id = object::id(&account);
    create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers,
        false,
        0,
        0,
        0,
        true,
        string::utf8(b"Zero Amount Grant"),
        constants::thirty_days_ms(),
        &clock,
        scenario.ctx(),
    );

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = oracle_actions::ETooManyTiers, location = futarchy_oracle::oracle_actions)]
fun test_create_grant_rejects_too_many_tiers() {
    let (mut scenario, registry, mut account, mut clock) = start();
    clock.set_for_testing(8200);

    let mut tier_specs = vector[];
    let mut i = 0;
    while (i < constants::max_oracle_tiers() + 1) {
        let recipients = vector[oracle_actions::new_recipient_mint(RECIPIENT1, 1)];
        let tier = oracle_actions::new_tier_spec(
            2_000_000_000_000u128 + (i as u128),
            true,
            recipients,
            string::utf8(b"Overflow Tier"),
        );
        tier_specs.push_back(tier);
        i = i + 1;
    };

    let tiers = oracle_actions::convert_tier_specs_for_testing(tier_specs);

    let dao_id = object::id(&account);
    create_grant_with_test_cap(
        &mut account,
        &registry,
        tiers,
        false,
        0,
        0,
        0,
        true,
        string::utf8(b"Too Many Tiers"),
        constants::thirty_days_ms(),
        &clock,
        scenario.ctx(),
    );

    end(scenario, registry, account, clock);
}

#[test]
/// Test empty registry returns empty grant list
fun test_empty_grant_registry() {
    let (scenario, registry, account, clock) = start();

    let grant_ids = oracle_actions::get_all_grant_ids(
        &account,
        &registry,
    );

    assert!(grant_ids.is_empty(), 0);

    end(scenario, registry, account, clock);
}

// === oracle_init_actions Getter Tests ===

#[test]
/// Test RecipientMint getter functions
fun test_recipient_mint_getters() {
    use futarchy_oracle::oracle_init_actions;

    let recipient = oracle_init_actions::new_recipient_mint(RECIPIENT1, 500);

    assert!(oracle_init_actions::recipient_address(&recipient) == RECIPIENT1, 0);
    assert!(oracle_init_actions::recipient_amount(&recipient) == 500, 1);
}

#[test]
/// Test TierSpec getter functions
fun test_tier_spec_getters() {
    use futarchy_oracle::oracle_init_actions;

    let recipients = vector[
        oracle_init_actions::new_recipient_mint(RECIPIENT1, 100),
        oracle_init_actions::new_recipient_mint(RECIPIENT2, 200),
    ];

    let tier = oracle_init_actions::new_tier_spec(
        5_000_000_000_000u128,
        true,
        recipients,
        string::utf8(b"Test Tier Description"),
    );

    assert!(oracle_init_actions::tier_price_threshold(&tier) == 5_000_000_000_000u128, 0);
    assert!(oracle_init_actions::tier_is_above(&tier) == true, 1);
    assert!(oracle_init_actions::tier_recipients(&tier).length() == 2, 2);
    assert!(
        *oracle_init_actions::tier_description(&tier) == string::utf8(b"Test Tier Description"),
        3,
    );
}

#[test]
/// Test TierSpec with is_above = false
fun test_tier_spec_is_below() {
    use futarchy_oracle::oracle_init_actions;

    let recipients = vector[oracle_init_actions::new_recipient_mint(RECIPIENT1, 100)];
    let tier = oracle_init_actions::new_tier_spec(
        1_000_000_000_000u128,
        false, // is_above = false means trigger when price is BELOW threshold
        recipients,
        string::utf8(b"Below Tier"),
    );

    assert!(oracle_init_actions::tier_is_above(&tier) == false, 0);
}

#[test]
#[expected_failure(abort_code = 8, location = futarchy_oracle::oracle_init_actions)]
/// Test that a relative downside tier with price_threshold < launchpad_multiplier is rejected
fun test_impossible_downside_tier_rejected() {
    use futarchy_oracle::oracle_init_actions;
    use account_actions::action_spec_builder;
    use account_actions::currency_init_actions;

    // Create a downside tier with threshold=50, which is below launchpad_multiplier=100
    let recipients = vector[oracle_init_actions::new_recipient_mint(RECIPIENT1, 1000)];
    let tier_spec = oracle_init_actions::new_tier_spec(
        50u128, // price_threshold below launchpad_multiplier
        false,  // is_above=false (downside tier)
        recipients,
        string::utf8(b"Impossible Downside Tier"),
    );

    let mut builder = action_spec_builder::new_for_testing();
    currency_init_actions::add_mint_currency_admin_cap_spec<TEST_ASSET>(
        &mut builder,
        string::utf8(b"grant_mint_cap"),
    );

    // use_relative_pricing=true, launchpad_multiplier=100
    // Since threshold (50) < launchpad_multiplier (100), this should abort
    oracle_init_actions::add_create_oracle_grant_spec<TEST_ASSET, TEST_STABLE>(
        &mut builder,
        string::utf8(b"grant_mint_cap"),
        vector[tier_spec],
        true,  // use_relative_pricing
        100,   // launchpad_multiplier
        0,     // earliest_execution_offset_ms
        0,     // expiry_years
        true,  // cancelable
        string::utf8(b"Impossible Grant"),
        constants::thirty_days_ms(), // twap_window_ms
    );
}
