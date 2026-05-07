#[test_only]
module futarchy_one_shot_utils::blank_coins_tests;

use futarchy_one_shot_utils::blank_coins;
use conditional_coin::conditional_99::{Self, CONDITIONAL_0};
use sui::clock;
use sui::coin::{Self, TreasuryCap};
use sui::coin_registry::{Self, CoinRegistry as SuiCoinRegistry, Currency, MetadataCap};
use sui::sui::SUI;
use sui::test_scenario as ts;

/// Decimals for test coins (matches conditional_0)
const TEST_DECIMALS: u8 = 9;

/// Fixed protocol fee: 0.01 SUI = 10_000_000 MIST
const LISTING_FEE: u64 = 10_000_000;

// === Helper Functions ===

/// Create a SuiCoinRegistry for testing (requires @0x0 sender)
/// Call ts::next_tx(&mut scenario, @0x0) before using this
fun create_sui_registry(scenario: &mut ts::Scenario): SuiCoinRegistry {
    coin_registry::create_coin_data_registry_for_testing(ts::ctx(scenario))
}

/// Initialize test coin with registry - must be called with @0x0 sender
/// Creates SuiCoinRegistry and initializes CONDITIONAL_0 coin in one step
/// Currency<T> is shared directly via finalize (non-OTW path)
fun init_test_coin_with_registry(scenario: &mut ts::Scenario): SuiCoinRegistry {
    // Create registry (requires @0x0 sender)
    let mut sui_registry = create_sui_registry(scenario);

    // Initialize the coin with the registry - this shares Currency directly
    conditional_99::init_for_testing_with_registry(&mut sui_registry, ts::ctx(scenario));

    sui_registry
}

// === Basic Tests ===

#[test]
fun test_create_empty_registry() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create registry
    let registry = blank_coins::create_registry(ctx);

    // Verify it's empty
    assert!(blank_coins::total_sets(&registry) == 0, 0);

    // Verify sets_available_for_decimals returns 0 for all decimal buckets
    assert!(blank_coins::sets_available_for_decimals(&registry, 6) == 0, 1);
    assert!(blank_coins::sets_available_for_decimals(&registry, 9) == 0, 2);

    // Destroy empty registry
    sui::test_utils::destroy(registry);

    ts::end(scenario);
}

#[test]
fun test_share_registry() {
    let mut scenario = ts::begin(@0x1);

    // Create and share registry
    let registry = blank_coins::create_registry(ts::ctx(&mut scenario));
    blank_coins::share_registry(registry);

    ts::next_tx(&mut scenario, @0x1);

    // Registry should be shared now
    let registry = ts::take_shared<blank_coins::BlankCoinsRegistry>(&scenario);
    assert!(blank_coins::total_sets(&registry) == 0, 0);

    ts::return_shared(registry);
    ts::end(scenario);
}

#[test]
fun test_listing_fee() {
    assert!(blank_coins::listing_fee() == LISTING_FEE, 0);
}

// === Deposit Tests ===

#[test]
fun test_deposit_single_coin_set() {
    let mut scenario = ts::begin(@0x0);

    // Initialize test coin with registry (requires @0x0 sender)
    // This creates SuiCoinRegistry and initializes CONDITIONAL_0, sharing Currency directly
    let sui_registry = init_test_coin_with_registry(&mut scenario);

    // Get the created treasury cap and metadata cap (transferred to tx sender @0x0 in init)
    ts::next_tx(&mut scenario, @0x0);
    let treasury_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(&scenario);
    let metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    // Get the shared Currency<T> object and do the deposit as @0x1
    ts::next_tx(&mut scenario, @0x1);
    let mut currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = blank_coins::create_registry(ts::ctx(&mut scenario));

    // Deposit coin set (fee is now fixed protocol constant)
    blank_coins::deposit_coin_set(
        &mut registry,
        &mut currency,
        treasury_cap,
        metadata_cap,
        TEST_DECIMALS, // expected_decimals (validated against Currency<T>)
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify registry state
    assert!(blank_coins::total_sets(&registry) == 1, 0);
    assert!(blank_coins::has_coin_set(&registry, TEST_DECIMALS, cap_id), 1);
    assert!(blank_coins::get_owner<CONDITIONAL_0>(&registry, TEST_DECIMALS, cap_id) == @0x1, 3);
    assert!(
        blank_coins::get_decimals<CONDITIONAL_0>(&registry, TEST_DECIMALS, cap_id) == TEST_DECIMALS,
        4,
    );
    assert!(blank_coins::sets_available_for_decimals(&registry, TEST_DECIMALS) == 1, 5);
    assert!(
        blank_coins::get_currency_id<CONDITIONAL_0>(&registry, TEST_DECIMALS, cap_id) == object::id(&currency),
        6,
    );

    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(sui_registry);
    ts::return_shared(currency);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Take Tests ===

#[test]
fun test_take_coin_set() {
    let mut scenario = ts::begin(@0x0);

    // Initialize test coin with registry (requires @0x0 sender)
    let sui_registry = init_test_coin_with_registry(&mut scenario);

    // Get the created caps from @0x0
    ts::next_tx(&mut scenario, @0x0);
    let treasury_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(&scenario);
    let metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    // Get shared Currency and deposit as @0x1
    ts::next_tx(&mut scenario, @0x1);
    let mut currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = blank_coins::create_registry(ts::ctx(&mut scenario));

    // Deposit coin set
    blank_coins::deposit_coin_set(
        &mut registry,
        &mut currency,
        treasury_cap,
        metadata_cap,
        TEST_DECIMALS,
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, @0x2);

    // Take coin set with desired_decimals, paying fixed LISTING_FEE
    let payment = coin::mint_for_testing<SUI>(2 * LISTING_FEE, ts::ctx(&mut scenario));
    let remaining = blank_coins::take_coin_set<CONDITIONAL_0>(
        &mut registry,
        TEST_DECIMALS, // desired_decimals - routes to correct bucket
        cap_id,
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify registry updated
    assert!(blank_coins::total_sets(&registry) == 0, 0);
    assert!(!blank_coins::has_coin_set(&registry, TEST_DECIMALS, cap_id), 1);
    assert!(coin::value(&remaining) == LISTING_FEE, 2); // Got change back
    assert!(blank_coins::sets_available_for_decimals(&registry, TEST_DECIMALS) == 0, 3);

    coin::burn_for_testing(remaining);
    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(sui_registry);
    ts::return_shared(currency);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_take_exact_fee_amount() {
    let mut scenario = ts::begin(@0x0);

    // Initialize test coin with registry (requires @0x0 sender)
    let sui_registry = init_test_coin_with_registry(&mut scenario);

    // Get the created caps from @0x0
    ts::next_tx(&mut scenario, @0x0);
    let treasury_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(&scenario);
    let metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    // Get shared Currency
    ts::next_tx(&mut scenario, @0x1);
    let mut currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = blank_coins::create_registry(ts::ctx(&mut scenario));

    blank_coins::deposit_coin_set(
        &mut registry,
        &mut currency,
        treasury_cap,
        metadata_cap,
        TEST_DECIMALS,
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, @0x2);

    // Pay exact fee
    let payment = coin::mint_for_testing<SUI>(LISTING_FEE, ts::ctx(&mut scenario));
    let remaining = blank_coins::take_coin_set<CONDITIONAL_0>(
        &mut registry,
        TEST_DECIMALS,
        cap_id,
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should have zero remaining
    assert!(coin::value(&remaining) == 0, 0);

    coin::burn_for_testing(remaining);
    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(sui_registry);
    ts::return_shared(currency);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === View Functions Tests ===

#[test]
fun test_view_functions() {
    let mut scenario = ts::begin(@0x0);

    // Initialize test coin with registry (requires @0x0 sender)
    let sui_registry = init_test_coin_with_registry(&mut scenario);

    // Get the created caps from @0x0
    ts::next_tx(&mut scenario, @0x0);
    let treasury_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(&scenario);
    let metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    // Get shared Currency
    ts::next_tx(&mut scenario, @0x1);
    let mut currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = blank_coins::create_registry(ts::ctx(&mut scenario));

    // Initially empty
    assert!(blank_coins::total_sets(&registry) == 0, 0);

    let owner = @0x1;

    blank_coins::deposit_coin_set(
        &mut registry,
        &mut currency,
        treasury_cap,
        metadata_cap,
        TEST_DECIMALS,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Test view functions with decimals parameter
    assert!(blank_coins::total_sets(&registry) == 1, 1);
    assert!(blank_coins::has_coin_set(&registry, TEST_DECIMALS, cap_id), 2);
    assert!(blank_coins::get_owner<CONDITIONAL_0>(&registry, TEST_DECIMALS, cap_id) == owner, 4);
    assert!(
        blank_coins::get_decimals<CONDITIONAL_0>(&registry, TEST_DECIMALS, cap_id) == TEST_DECIMALS,
        6,
    );
    assert!(blank_coins::sets_available_for_decimals(&registry, TEST_DECIMALS) == 1, 7);
    assert!(
        blank_coins::get_currency_id<CONDITIONAL_0>(&registry, TEST_DECIMALS, cap_id) == object::id(&currency),
        8,
    );

    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(sui_registry);
    ts::return_shared(currency);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Error Case Tests ===

#[test]
#[expected_failure(abort_code = 1)] // EInsufficientFee
fun test_insufficient_fee() {
    let mut scenario = ts::begin(@0x0);

    // Initialize test coin with registry (requires @0x0 sender)
    let sui_registry = init_test_coin_with_registry(&mut scenario);

    // Get the created caps from @0x0
    ts::next_tx(&mut scenario, @0x0);
    let treasury_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(&scenario);
    let metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    // Get shared Currency
    ts::next_tx(&mut scenario, @0x1);
    let mut currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = blank_coins::create_registry(ts::ctx(&mut scenario));

    blank_coins::deposit_coin_set(
        &mut registry,
        &mut currency,
        treasury_cap,
        metadata_cap,
        TEST_DECIMALS,
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, @0x2);

    // Try to take with insufficient payment (less than LISTING_FEE)
    let payment = coin::mint_for_testing<SUI>(LISTING_FEE - 1, ts::ctx(&mut scenario));
    let remaining = blank_coins::take_coin_set<CONDITIONAL_0>(
        &mut registry,
        TEST_DECIMALS,
        cap_id,
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(remaining);
    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(sui_registry);
    ts::return_shared(currency);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 9)] // ENoCoinSetsAvailable
fun test_take_nonexistent_coin_set() {
    let mut scenario = ts::begin(@0x1);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    let mut registry = blank_coins::create_registry(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, @0x2);

    // Try to take nonexistent coin set (should fail)
    let payment = coin::mint_for_testing<SUI>(LISTING_FEE, ts::ctx(&mut scenario));
    let fake_id = object::id_from_address(@0x999);
    let remaining = blank_coins::take_coin_set<CONDITIONAL_0>(
        &mut registry,
        TEST_DECIMALS,
        fake_id,
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(remaining);
    sui::test_utils::destroy(registry);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 9)] // ENoCoinSetsAvailable - wrong decimals bucket
fun test_take_wrong_decimals_bucket() {
    let mut scenario = ts::begin(@0x0);

    // Initialize test coin with registry (requires @0x0 sender)
    let sui_registry = init_test_coin_with_registry(&mut scenario);

    // Get the created caps from @0x0
    ts::next_tx(&mut scenario, @0x0);
    let treasury_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(&scenario);
    let metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(&scenario);
    let cap_id = object::id(&treasury_cap);

    // Get shared Currency
    ts::next_tx(&mut scenario, @0x1);
    let mut currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = blank_coins::create_registry(ts::ctx(&mut scenario));

    // Deposit coin set with 9 decimals
    blank_coins::deposit_coin_set(
        &mut registry,
        &mut currency,
        treasury_cap,
        metadata_cap,
        TEST_DECIMALS, // 9 decimals
        &clock,
        ts::ctx(&mut scenario),
    );

    ts::next_tx(&mut scenario, @0x2);

    // Try to take from WRONG decimals bucket (6 instead of 9) - should fail
    let payment = coin::mint_for_testing<SUI>(2 * LISTING_FEE, ts::ctx(&mut scenario));
    let remaining = blank_coins::take_coin_set<CONDITIONAL_0>(
        &mut registry,
        6, // WRONG decimals bucket!
        cap_id,
        payment,
        &clock,
        ts::ctx(&mut scenario),
    );

    coin::burn_for_testing(remaining);
    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(sui_registry);
    ts::return_shared(currency);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Decimals Validation Tests ===

#[test]
#[expected_failure(abort_code = 12)] // EDecimalsMismatch
fun test_deposit_wrong_expected_decimals() {
    let mut scenario = ts::begin(@0x0);

    // Initialize test coin with registry (9 decimals)
    let sui_registry = init_test_coin_with_registry(&mut scenario);

    // Get the created caps from @0x0
    ts::next_tx(&mut scenario, @0x0);
    let treasury_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(&scenario);
    let metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(&scenario);

    // Get shared Currency
    ts::next_tx(&mut scenario, @0x1);
    let mut currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = blank_coins::create_registry(ts::ctx(&mut scenario));

    // Try to deposit with WRONG expected_decimals (6 instead of 9)
    // Should fail with EDecimalsMismatch
    blank_coins::deposit_coin_set(
        &mut registry,
        &mut currency,
        treasury_cap,
        metadata_cap,
        6, // WRONG - actual coin has 9 decimals
        &clock,
        ts::ctx(&mut scenario),
    );

    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(sui_registry);
    ts::return_shared(currency);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 13)] // EInvalidDecimals
fun test_deposit_invalid_decimals_value() {
    let mut scenario = ts::begin(@0x0);

    // Initialize test coin with registry
    let sui_registry = init_test_coin_with_registry(&mut scenario);

    // Get the created caps from @0x0
    ts::next_tx(&mut scenario, @0x0);
    let treasury_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(&scenario);
    let metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(&scenario);

    // Get shared Currency
    ts::next_tx(&mut scenario, @0x1);
    let mut currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = blank_coins::create_registry(ts::ctx(&mut scenario));

    // Try to deposit with invalid decimals (> 18)
    // Should fail with EInvalidDecimals
    blank_coins::deposit_coin_set(
        &mut registry,
        &mut currency,
        treasury_cap,
        metadata_cap,
        19, // INVALID - max is 18
        &clock,
        ts::ctx(&mut scenario),
    );

    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(sui_registry);
    ts::return_shared(currency);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Entry Function Tests ===

#[test]
fun test_deposit_coin_set_entry() {
    let mut scenario = ts::begin(@0x0);

    // Initialize test coin with registry (requires @0x0 sender)
    let sui_registry = init_test_coin_with_registry(&mut scenario);

    // Create and share blank coins registry
    let registry = blank_coins::create_registry(ts::ctx(&mut scenario));
    blank_coins::share_registry(registry);

    // Get the created caps from @0x0
    ts::next_tx(&mut scenario, @0x0);
    let treasury_cap = ts::take_from_sender<TreasuryCap<CONDITIONAL_0>>(&scenario);
    let metadata_cap = ts::take_from_sender<MetadataCap<CONDITIONAL_0>>(&scenario);

    // Get shared Currency and registry
    ts::next_tx(&mut scenario, @0x1);
    let mut currency = ts::take_shared<Currency<CONDITIONAL_0>>(&scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut registry = ts::take_shared<blank_coins::BlankCoinsRegistry>(&scenario);

    // Test the entry function
    blank_coins::deposit_coin_set_entry(
        &mut registry,
        &mut currency,
        treasury_cap,
        metadata_cap,
        TEST_DECIMALS,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify deposit succeeded
    assert!(blank_coins::total_sets(&registry) == 1, 0);

    ts::return_shared(registry);
    sui::test_utils::destroy(sui_registry);
    ts::return_shared(currency);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
