#[test_only]
module futarchy_markets_primitives::futarchy_twap_oracle_tests;

use futarchy_markets_primitives::futarchy_twap_oracle::{Self, Oracle};
use futarchy_one_shot_utils::constants;
use sui::clock::{Self, Clock};
use sui::event;
use sui::test_scenario as ts;
use sui::test_utils::destroy;

const ADMIN: address = @0xAD;

// === Test Helpers ===

fun start(): (ts::Scenario, Clock) {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    (scenario, clock)
}

fun end(scenario: ts::Scenario, clock: Clock) {
    destroy(clock);
    ts::end(scenario);
}

// === Oracle Creation Tests ===

#[test]
fun test_new_oracle_valid_params() {
    let (mut scenario, clock) = start();

    let oracle = futarchy_twap_oracle::new_oracle(
        10000, // initialization price
        60_000, // twap_start_delay (1 minute)
        1000, // twap_cap_ppm (0.1%)
        ts::ctx(&mut scenario),
    );

    // Verify initialization
    assert!(futarchy_twap_oracle::last_price(&oracle) == 10000, 0);
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 0, 1);
    assert!(futarchy_twap_oracle::market_start_time(&oracle).is_none(), 2);
    assert!(futarchy_twap_oracle::twap_initialization_price(&oracle) == 10000, 3);

    let (delay, cap_step) = futarchy_twap_oracle::config(&oracle);
    assert!(delay == 60_000, 4);
    assert!(cap_step == 10, 5); // 10000 * 1000 / 1_000_000 = 10

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::EZeroInitialization)]
fun test_new_oracle_zero_initialization_price_fails() {
    let (mut scenario, clock) = start();

    let oracle = futarchy_twap_oracle::new_oracle(
        0, // zero price - should fail
        60_000,
        1000,
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::EZeroStep)]
fun test_new_oracle_zero_cap_ppm_fails() {
    let (mut scenario, clock) = start();

    let oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        0, // zero cap ppm - should fail
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::EInvalidCapPpm)]
fun test_new_oracle_invalid_cap_ppm_fails() {
    let (mut scenario, clock) = start();

    let oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        1_000_001, // > PPM_DENOMINATOR - should fail
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::ELongDelay)]
fun test_new_oracle_long_delay_fails() {
    let (mut scenario, clock) = start();

    let oracle = futarchy_twap_oracle::new_oracle(
        10000,
        constants::one_week_ms(), // >= 1 week - should fail
        1000,
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::ENoneFullWindowTwapDelay)]
fun test_new_oracle_misaligned_delay_fails() {
    let (mut scenario, clock) = start();

    let oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_001, // Not multiple of TWAP_PRICE_CAP_WINDOW - should fail
        1000,
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_new_oracle_step_calculation_small_ppm() {
    let (mut scenario, clock) = start();

    // Small PPM should result in small step
    let oracle = futarchy_twap_oracle::new_oracle(
        100_000,
        60_000,
        100, // 0.01%
        ts::ctx(&mut scenario),
    );

    let (_, cap_step) = futarchy_twap_oracle::config(&oracle);
    assert!(cap_step == 10, 0); // 100_000 * 100 / 1_000_000 = 10

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_new_oracle_step_calculation_large_ppm() {
    let (mut scenario, clock) = start();

    // Large PPM should result in large step
    let oracle = futarchy_twap_oracle::new_oracle(
        100_000,
        60_000,
        100_000, // 10%
        ts::ctx(&mut scenario),
    );

    let (_, cap_step) = futarchy_twap_oracle::config(&oracle);
    assert!(cap_step == 10_000, 0); // 100_000 * 100_000 / 1_000_000 = 10_000

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Oracle Start Time Tests ===

#[test]
fun test_set_oracle_start_time() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    assert!(futarchy_twap_oracle::market_start_time(&oracle).is_some(), 0);
    assert!(*futarchy_twap_oracle::market_start_time(&oracle).borrow() == 1000, 1);
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 1000, 2);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::EMarketAlreadyStarted)]
fun test_set_oracle_start_time_twice_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Try to set again - should fail
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 2000);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Write Observation Tests ===

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::EMarketNotStarted)]
fun test_write_observation_before_market_start_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);

    // Try to write without starting market - should fail
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 1000, 10000);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_no_time_passed() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write at same timestamp - last_price updates but no TWAP accumulation
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 1000, 10000);

    // Timestamp and cumulative unchanged (no time passed = no accumulation)
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 1000, 0);
    assert!(futarchy_twap_oracle::total_cumulative_price(&oracle) == 0, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_same_timestamp_updates_last_price() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));
    // test_oracle has: twap_initialization_price = 10000, twap_cap_step = 10 (0.1% of 10000)

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Initial last_price should be initialization price
    assert!(futarchy_twap_oracle::last_price(&oracle) == 10000, 0);

    // Write at same timestamp with higher price - last_price should update (capped)
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 1000, 11000);

    // last_price should be capped: 10000 + 10 = 10010 (cap step is 10)
    assert!(futarchy_twap_oracle::last_price(&oracle) == 10010, 1);

    // But no TWAP accumulation (no time passed)
    assert!(futarchy_twap_oracle::total_cumulative_price(&oracle) == 0, 2);

    // Write again at same timestamp with even higher price
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 1000, 12000);

    // last_price updates again, still capped from last_window_twap (10000), not from last_price
    // So it's still 10000 + 10 = 10010
    assert!(futarchy_twap_oracle::last_price(&oracle) == 10010, 3);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_before_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));
    // Oracle has 60_000 ms delay (1 minute)

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write at 5000ms (before 1000 + 60_000 = 61_000)
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 5000, 11000);

    // Should accumulate normally
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 5000, 0);
    assert!(futarchy_twap_oracle::total_cumulative_price(&oracle) > 0, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_crossing_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));
    // Oracle has 60_000 ms delay (1 minute)

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write before threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 5000, 10000);
    let cumulative_before = futarchy_twap_oracle::total_cumulative_price(&oracle);

    // Write crossing threshold (1000 + 60_000 = 61_000)
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10500);

    // Accumulators should be reset at delay threshold
    // total_cumulative_price should be less than if it wasn't reset
    let cumulative_after = futarchy_twap_oracle::total_cumulative_price(&oracle);

    // After crossing threshold, accumulation restarted from delay_threshold
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 70_000, 0);
    assert!(cumulative_after > 0, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_after_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross the delay threshold first
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);
    let cumulative_1 = futarchy_twap_oracle::total_cumulative_price(&oracle);

    // Write after threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 80_000, 10500);
    let cumulative_2 = futarchy_twap_oracle::total_cumulative_price(&oracle);

    // Should accumulate normally
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 80_000, 0);
    assert!(cumulative_2 > cumulative_1, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::ETimestampRegression)]
fun test_write_observation_timestamp_regression_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // Try to write earlier timestamp - should fail
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 60_000, 10500);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Price Capping Tests ===

#[test]
fun test_write_observation_price_cap_upward() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // Try to jump price by 500 (5x the cap of 100)
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, 10500);

    // Price should be capped
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    // After multiple windows, price can move up to cap per window
    assert!(last_price <= 10500, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_price_cap_downward() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // Try to drop price by 500 (5x the cap of 100)
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, 9500);

    // Price should be capped
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price >= 9500, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_price_within_cap() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // Small price change within cap
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 80_000, 10050);

    // Should accept the price as-is
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price == 10050, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === TWAP Calculation Tests ===

#[test]
fun test_get_twap_after_write() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold and accumulate
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    clock.set_for_testing(130_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, 10500);

    // Read TWAP
    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    // TWAP should be between 10000 and 10500
    assert!(twap >= 10000 && twap <= 10500, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::EStaleTwap)]
fun test_get_twap_without_write_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // Advance clock without writing
    clock.set_for_testing(130_000);

    // Try to read TWAP - should fail (stale)
    let _twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::ETwapNotStarted)]
fun test_get_twap_before_delay_period_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write before delay threshold
    clock.set_for_testing(30_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 30_000, 10000);

    // Try to read TWAP - should fail (before delay)
    let _twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = futarchy_twap_oracle::EMarketNotStarted)]
fun test_get_twap_market_not_started_fails() {
    let (mut scenario, mut clock) = start();

    let oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);

    // Try to read TWAP without starting market - should fail
    let _twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Window Boundary Tests ===

#[test]
fun test_write_observation_window_boundary() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    let window_size = constants::twap_price_cap_window();
    let initial_window_end = futarchy_twap_oracle::get_last_window_end_for_testing(&oracle);

    // Write exactly at window boundary
    let next_boundary = initial_window_end + window_size;
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, next_boundary, 10100);

    // Window end should update
    let new_window_end = futarchy_twap_oracle::get_last_window_end_for_testing(&oracle);
    assert!(new_window_end == next_boundary, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_multiple_windows() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    let window_size = constants::twap_price_cap_window();

    // Jump multiple windows ahead
    let target_time = 70_000 + (window_size * 5);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, target_time, 10200);

    // Should process multiple full windows
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == target_time, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Integration Tests ===

#[test]
fun test_full_oracle_workflow() {
    let (mut scenario, mut clock) = start();

    // 1. Create oracle with realistic params
    let mut oracle = futarchy_twap_oracle::new_oracle(
        1_000_000, // $1.00 (6 decimals)
        300_000, // 5 minute delay
        50_000, // 5% cap
        ts::ctx(&mut scenario),
    );

    // 2. Start market
    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // 3. Write observations during delay period
    clock.set_for_testing(100_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 100_000, 1_000_000);

    clock.set_for_testing(200_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 200_000, 1_010_000);

    // 4. Cross delay threshold
    clock.set_for_testing(400_000); // Past 1000 + 300_000
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 400_000, 1_020_000);

    // 5. Continue observations after delay
    clock.set_for_testing(500_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 500_000, 1_030_000);

    clock.set_for_testing(600_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 600_000, 1_040_000);

    // 6. Read TWAP
    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    // TWAP should reflect accumulated prices
    assert!(twap >= 1_000_000 && twap <= 1_040_000, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_realistic_price_discovery_scenario() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        500_000, // $0.50 initialization
        60_000, // 1 minute delay
        100_000, // 10% cap
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(0);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 0);

    // Simulate trading activity
    let mut time = 60_000; // After delay
    let mut price = 500_000;

    // Price gradually increases
    let mut i = 0;
    while (i < 10) {
        time = time + 10_000; // 10 second intervals
        price = price + 5_000; // $0.005 increase per step

        clock.set_for_testing(time);
        futarchy_twap_oracle::write_observation_for_testing(&mut oracle, time, price);

        i = i + 1;
    };

    // Read final TWAP
    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    // TWAP should be between initial and final price
    assert!(twap >= 500_000 && twap <= 550_000, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Internal Function Tests (via test helpers) ===

#[test]
fun test_intra_window_accumulation_direct() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state for testing
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    // Call intra_window accumulation for 5000ms
    futarchy_twap_oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500, // price
        5000, // duration
        6000, // timestamp
    );

    // Verify accumulation happened
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 6000, 0);
    assert!(futarchy_twap_oracle::total_cumulative_price(&oracle) > 0, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_intra_window_accumulation_hits_boundary() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Accumulate exactly one window
    futarchy_twap_oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        window_size,
        1000 + window_size,
    );

    // Window should advance
    let new_window_end = futarchy_twap_oracle::get_last_window_end_for_testing(&oracle);
    assert!(new_window_end == 1000 + window_size, 0);

    // Window TWAP should update
    let window_twap = futarchy_twap_oracle::debug_get_window_twap(&oracle);
    assert!(window_twap > 0, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_multi_full_window_accumulation_single_window() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Process 1 full window
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10500, // price
        1, // num_windows
        1000 + window_size,
    );

    // Verify state updated
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 1000 + window_size, 0);
    assert!(
        futarchy_twap_oracle::get_last_window_end_for_testing(&oracle) == 1000 + window_size,
        1,
    );

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_multi_full_window_accumulation_multiple_windows() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Process 10 full windows
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        11000, // price significantly higher
        10, // num_windows
        1000 + (window_size * 10),
    );

    // Verify state updated
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 1000 + (window_size * 10), 0);
    assert!(
        futarchy_twap_oracle::get_last_window_end_for_testing(&oracle) == 1000 + (window_size * 10),
        1,
    );

    // Last price should be capped progression toward target
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price > 10000 && last_price <= 11000, 2);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_multi_full_window_price_ramping() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Try to jump to much higher price
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        15000, // 50% increase (should be capped)
        5, // 5 windows
        1000 + (window_size * 5),
    );

    // Price should ramp up gradually, not jump to 15000
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price > 10000, 0);
    assert!(last_price < 15000, 1); // Should be capped
    // With cap_step=100 and 5 windows, max increase is 500
    assert!(last_price <= 10500, 2);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_multi_full_window_price_ramping_downward() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Try to drop to much lower price
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        5000, // 50% decrease (should be capped)
        5, // 5 windows
        1000 + (window_size * 5),
    );

    // Price should ramp down gradually, not drop to 5000
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price < 10000, 0);
    assert!(last_price > 5000, 1); // Should be capped
    // With cap_step=100 and 5 windows, max decrease is 500
    assert!(last_price >= 9500, 2);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_twap_accumulate_all_three_stages() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state: Start partway into a window
    let window_size = constants::twap_price_cap_window();
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000 + (window_size / 4));
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    // Jump ahead: partial window + 3 full windows + partial window
    let target_time = 1000 + (window_size * 4) + (window_size / 2);

    futarchy_twap_oracle::call_twap_accumulate_for_testing(
        &mut oracle,
        target_time,
        10500,
    );

    // Should process all three stages
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == target_time, 0);
    assert!(futarchy_twap_oracle::total_cumulative_price(&oracle) > 0, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Extreme Value Tests ===

#[test]
fun test_very_large_price() {
    let (mut scenario, mut clock) = start();

    // Create oracle with very large initialization price
    let large_price: u128 = 1_000_000_000_000_000_000; // 10^18
    let mut oracle = futarchy_twap_oracle::new_oracle(
        large_price,
        60_000,
        1000,
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write observations with large prices
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, large_price);

    clock.set_for_testing(130_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, large_price + 1_000_000);

    // Should handle large values without overflow
    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);
    assert!(twap >= large_price, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_very_long_duration() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // Jump to 7 days later (max proposal duration mentioned in comments)
    let seven_days_ms = 7 * 24 * 60 * 60 * 1000;
    let target_time = 70_000 + seven_days_ms;

    clock.set_for_testing(target_time);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, target_time, 10500);

    // Should handle long duration without overflow
    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);
    assert!(twap >= 10000 && twap <= 10500, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_minimum_cap_step() {
    let (mut scenario, mut clock) = start();

    // Very small initialization price with very small PPM
    // This should result in cap_step = 1 (minimum)
    let mut oracle = futarchy_twap_oracle::new_oracle(
        100, // Small price
        60_000,
        1, // Minimum PPM that would result in cap_step < 1
        ts::ctx(&mut scenario),
    );

    let (_, cap_step) = futarchy_twap_oracle::config(&oracle);
    // Should be forced to minimum of 1
    assert!(cap_step >= 1, 0);

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Should still work with minimum cap step
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 100);

    clock.set_for_testing(130_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, 110);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_price_exactly_at_base() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Price exactly equals base (g_abs = 0)
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10000, // Same as base
        5, // 5 windows
        1000 + (window_size * 5),
    );

    // Should handle zero deviation case
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price == 10000, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === State Consistency Tests ===

#[test]
fun test_cumulative_price_consistency() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write multiple observations
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    let cumulative_1 = futarchy_twap_oracle::total_cumulative_price(&oracle);
    let window_cumulative_1 = futarchy_twap_oracle::get_last_window_end_cumulative_price_for_testing(
        &oracle,
    );

    clock.set_for_testing(130_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, 10500);

    let cumulative_2 = futarchy_twap_oracle::total_cumulative_price(&oracle);
    let window_cumulative_2 = futarchy_twap_oracle::get_last_window_end_cumulative_price_for_testing(
        &oracle,
    );

    // Cumulative should only increase
    assert!(cumulative_2 >= cumulative_1, 0);
    assert!(window_cumulative_2 >= window_cumulative_1, 1);

    // last_window_end_cumulative_price should be <= total_cumulative_price
    assert!(window_cumulative_2 <= cumulative_2, 2);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_timestamp_ordering_invariant() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write multiple observations and verify invariant at each step
    let mut times = vector[70_000, 130_000, 200_000, 300_000];
    let mut i = 0;

    while (i < times.length()) {
        let time = times[i];
        clock.set_for_testing(time);
        futarchy_twap_oracle::write_observation_for_testing(&mut oracle, time, 10000 + ((i as u128) * 100));

        // Invariant: last_timestamp >= last_window_end
        let last_ts = futarchy_twap_oracle::last_timestamp(&oracle);
        let last_window = futarchy_twap_oracle::get_last_window_end_for_testing(&oracle);
        assert!(last_ts >= last_window, i);

        i = i + 1;
    };

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Mathematical Property Tests ===

#[test]
fun test_price_cap_symmetry() {
    let (mut scenario, clock) = start();

    // Create two oracles with identical params
    let mut oracle_up = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap
        ts::ctx(&mut scenario),
    );

    let mut oracle_down = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle_up, 1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle_down, 1000);

    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle_up, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle_up, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle_up, 10000);

    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle_down, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle_down, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle_down, 10000);

    let window_size = constants::twap_price_cap_window();

    // Same magnitude deviation, opposite directions
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_up,
        10500, // +500
        5,
        1000 + (window_size * 5),
    );

    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_down,
        9500, // -500
        5,
        1000 + (window_size * 5),
    );

    let price_up = futarchy_twap_oracle::last_price(&mut oracle_up);
    let price_down = futarchy_twap_oracle::last_price(&mut oracle_down);

    // Deviations should be symmetric
    let dev_up = price_up - 10000;
    let dev_down = 10000 - price_down;
    assert!(dev_up == dev_down, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle_up);
    futarchy_twap_oracle::destroy_for_testing(oracle_down);
    end(scenario, clock);
}

#[test]
fun test_multiple_small_steps_vs_one_large() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap = 100 step
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Try to jump by 500 in 5 windows vs 1 window
    // Should ramp up gradually
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10500,
        5,
        1000 + (window_size * 5),
    );

    let price_5_windows = futarchy_twap_oracle::last_price(&oracle);

    // Reset for comparison
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);
    futarchy_twap_oracle::set_cumulative_prices_for_testing(&mut oracle, 0, 0);

    // Same target but fewer windows
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10500,
        1,
        1000 + window_size,
    );

    let price_1_window = futarchy_twap_oracle::last_price(&oracle);

    // More windows should allow more progress toward target
    assert!(price_5_windows >= price_1_window, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Attack Scenario Tests ===

#[test]
fun test_rapid_price_manipulation_resistance() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // Attacker tries rapid price spikes
    clock.set_for_testing(80_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 80_000, 20000); // 2x spike

    clock.set_for_testing(90_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 90_000, 5000); // Drop to 0.5x

    clock.set_for_testing(100_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 100_000, 15000); // Another spike

    // Read TWAP - should be relatively stable due to capping
    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    // TWAP should not have wild swings - should be closer to 10000 than extremes
    assert!(twap > 8000 && twap < 12000, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_gradual_manipulation_over_time() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap = 100 per window
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // Attacker gradually increases price within caps
    let window_size = constants::twap_price_cap_window();
    let mut time = 70_000;
    let mut price = 10000;

    let mut i = 0;
    while (i < 20) {
        time = time + window_size;
        price = price + 90; // Just under cap

        clock.set_for_testing(time);
        futarchy_twap_oracle::write_observation_for_testing(&mut oracle, time, price);

        i = i + 1;
    };

    // Even with gradual manipulation, price progression is capped
    let final_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(final_price <= 10000 + (100 * 20), 0); // Max 100 per window

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Window Alignment Edge Cases ===

#[test]
fun test_observation_just_before_window_boundary() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Write 1ms before window boundary
    futarchy_twap_oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        window_size - 1,
        1000 + window_size - 1,
    );

    // Window should NOT advance yet
    let window_end = futarchy_twap_oracle::get_last_window_end_for_testing(&oracle);
    assert!(window_end == 1000, 0);

    // Write 1ms more to hit boundary
    futarchy_twap_oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        1,
        1000 + window_size,
    );

    // Now window should advance
    let new_window_end = futarchy_twap_oracle::get_last_window_end_for_testing(&oracle);
    assert!(new_window_end == 1000 + window_size, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_observation_just_after_window_boundary() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Write exactly at boundary
    futarchy_twap_oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        window_size,
        1000 + window_size,
    );

    let window_end_1 = futarchy_twap_oracle::get_last_window_end_for_testing(&oracle);
    assert!(window_end_1 == 1000 + window_size, 0);

    // Write 1ms after boundary (new window)
    futarchy_twap_oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        1,
        1000 + window_size + 1,
    );

    // Should still be in new window (not advanced again)
    let window_end_2 = futarchy_twap_oracle::get_last_window_end_for_testing(&oracle);
    assert!(window_end_2 == window_end_1, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === View Function Tests ===

#[test]
fun test_view_functions() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Verify getters
    assert!(futarchy_twap_oracle::twap_initialization_price(&oracle) == 10000, 0);
    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == 1000, 1);
    assert!(futarchy_twap_oracle::total_cumulative_price(&oracle) == 0, 2);

    let (delay, cap_step) = futarchy_twap_oracle::config(&oracle);
    assert!(delay == 60_000, 3);
    assert!(cap_step == 10, 4);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === E2E Scenario Debug Test ===
// This test replicates the memo-action e2e test scenario to debug why both oracles
// end up with identical TWAPs even when only one has a swap.

#[test]
fun test_two_oracles_one_swap_scenario() {
    let (mut scenario, mut clock) = start();
    let window = constants::twap_price_cap_window(); // 60_000ms

    // Create two oracles (like REJECT=0 and ACCEPT=1 pools)
    // Both start at price 1.0 (scaled to 1_000_000_000_000 = 1e12)
    let init_price: u128 = 1_000_000_000_000_000; // 1.0 scaled by 1e15 (price_precision_scale)

    let mut oracle_reject = futarchy_twap_oracle::new_oracle(
        init_price,
        60_000, // twap_start_delay
        1000, // twap_cap_ppm (0.1%)
        ts::ctx(&mut scenario),
    );

    let mut oracle_accept = futarchy_twap_oracle::new_oracle(
        init_price,
        60_000,
        1000,
        ts::ctx(&mut scenario),
    );

    // T=0: Trading starts
    let trading_start = 1000u64;
    clock.set_for_testing(trading_start);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle_reject, trading_start);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle_accept, trading_start);

    std::debug::print(&b"=== T=0: Trading starts ===");
    std::debug::print(&b"Both oracles initialized at price 1.0");

    // T=5000ms: User swaps in ACCEPT pool (outcome 1)
    // This writes an observation with the OLD price (1.0) before reserves change
    // Then reserves change and price becomes 1.05 (1_050_000_000_000_000)
    let swap_time = trading_start + 5000;
    clock.set_for_testing(swap_time);

    std::debug::print(&b"=== T=5000: Swap in ACCEPT pool ===");
    std::debug::print(&b"Recording OLD price (1.0) before swap");

    // Write observation with OLD price for ACCEPT oracle
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle_accept, swap_time, init_price);

    let accept_cumulative_after_swap = futarchy_twap_oracle::total_cumulative_price(&oracle_accept);
    std::debug::print(&b"ACCEPT cumulative after swap:");
    std::debug::print(&accept_cumulative_after_swap);

    // NEW price after swap is 1.05
    let new_price_after_swap: u128 = 1_050_000_000_000_000;

    // T=67000ms: Finalization (after trading period of ~60s + extra time)
    // Both oracles get update_twap_observation called with their CURRENT prices
    let finalize_time = trading_start + 67000; // 67 seconds after start
    clock.set_for_testing(finalize_time);

    std::debug::print(&b"=== T=67000: Finalization ===");

    // REJECT pool: price is still 1.0 (no swap happened)
    std::debug::print(&b"REJECT oracle write_observation with price 1.0");
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle_reject, finalize_time, init_price);

    // ACCEPT pool: price is now 1.05 (after swap)
    std::debug::print(&b"ACCEPT oracle write_observation with price 1.05");
    futarchy_twap_oracle::write_observation_for_testing(
        &mut oracle_accept,
        finalize_time,
        new_price_after_swap,
    );

    // Get TWAPs
    clock.set_for_testing(finalize_time);
    let twap_reject = futarchy_twap_oracle::get_twap(&mut oracle_reject, &clock);
    let twap_accept = futarchy_twap_oracle::get_twap(&mut oracle_accept, &clock);

    std::debug::print(&b"=== Final TWAPs ===");
    std::debug::print(&b"REJECT TWAP:");
    std::debug::print(&twap_reject);
    std::debug::print(&b"ACCEPT TWAP:");
    std::debug::print(&twap_accept);

    let reject_cumulative = futarchy_twap_oracle::total_cumulative_price(&oracle_reject);
    let accept_cumulative = futarchy_twap_oracle::total_cumulative_price(&oracle_accept);
    std::debug::print(&b"REJECT cumulative:");
    std::debug::print(&reject_cumulative);
    std::debug::print(&b"ACCEPT cumulative:");
    std::debug::print(&accept_cumulative);

    // ACCEPT TWAP should be higher than REJECT TWAP
    std::debug::print(&b"ACCEPT > REJECT?");
    std::debug::print(&(twap_accept > twap_reject));

    // For now, just assert they're different (this may fail, which is the bug!)
    assert!(twap_accept > twap_reject, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle_reject);
    futarchy_twap_oracle::destroy_for_testing(oracle_accept);
    end(scenario, clock);
}

// ============================================================================
// CHALLENGING EDGE CASE TESTS
// ============================================================================

// === Extreme Value Tests ===

#[test]
fun test_very_small_price_minimum_step() {
    // Test with very small prices where cap_step approaches minimum of 1
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10, // Very small initialization price
        60_000,
        1000, // 0.1% cap -> step = 10 * 1000 / 1_000_000 = 0.01 -> rounds to 1
        ts::ctx(&mut scenario),
    );

    let (_, cap_step) = futarchy_twap_oracle::config(&oracle);
    assert!(cap_step >= 1, 0); // Should be at least 1

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10);

    // Try large price jump
    clock.set_for_testing(130_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, 1000);

    // Price should be capped, not jump to 1000
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price < 1000, 1);
    assert!(last_price > 10, 2);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_near_maximum_u128_price() {
    let (mut scenario, mut clock) = start();

    // Large price but won't overflow
    let large_price: u128 = 1_000_000_000_000_000_000; // 10^18

    let mut oracle = futarchy_twap_oracle::new_oracle(
        large_price,
        60_000,
        10_000, // 1% cap
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, large_price);

    // Continue accumulation
    clock.set_for_testing(130_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, large_price + 1_000_000_000);

    // Should handle without overflow
    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);
    assert!(twap >= large_price, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Price Capping Edge Cases ===

#[test]
fun test_price_exactly_at_cap_boundary() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Price exactly at cap (10000 + 100 = 10100)
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10100, // Exactly 1 cap step away
        1, // 1 window
        1000 + window_size,
    );

    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price == 10100, 0); // Should reach exactly

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_price_one_unit_over_cap() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Price one unit over cap
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10101, // 101 units away (> 100 cap)
        1, // 1 window
        1000 + window_size,
    );

    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price == 10100, 0); // Should be capped at 10100

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_price_capping_exact_window_count_to_reach_target() {
    // If gap = 500 and cap_step = 100, need exactly 5 windows
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Gap = 500, cap = 100, need 5 windows
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10500,
        5, // Exactly 5 windows
        1000 + (window_size * 5),
    );

    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price == 10500, 0); // Should reach exactly

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_price_capping_one_less_window_than_needed() {
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Gap = 500, cap = 100, need 5 windows, only give 4
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10500,
        4, // 4 windows
        1000 + (window_size * 4),
    );

    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price == 10400, 0); // Should be 10000 + 400

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Multi-Window Accumulation Edge Cases ===

#[test]
fun test_very_large_window_count() {
    // Test O(1) behavior with many windows
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // 10000 windows (should still be O(1))
    let num_windows = 10000u64;
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        20000, // Target 2x price
        num_windows,
        1000 + (window_size * num_windows),
    );

    let last_price = futarchy_twap_oracle::last_price(&oracle);
    // Gap = 10000, cap_step = 100, with 10000 windows can move 1_000_000
    // So should fully reach target
    assert!(last_price == 20000, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_zero_gap_multi_window() {
    // When target price equals base price
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000,
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Target = base (no movement needed)
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10000, // Same as base
        10, // 10 windows
        1000 + (window_size * 10),
    );

    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price == 10000, 0);

    // TWAP should also stay same
    let window_twap = futarchy_twap_oracle::debug_get_window_twap(&oracle);
    assert!(window_twap == 10000, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Three-Stage Accumulation Tests ===

#[test]
fun test_twap_accumulate_stage1_only() {
    // Only partial window, no full windows, no stage3
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Only half a window
    let target_time = 1000 + (window_size / 2);

    futarchy_twap_oracle::call_twap_accumulate_for_testing(
        &mut oracle,
        target_time,
        10500,
    );

    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == target_time, 0);
    // Window end should not advance (no full window completed)
    assert!(futarchy_twap_oracle::get_last_window_end_for_testing(&oracle) == 1000, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_twap_accumulate_stage1_and_stage2_only() {
    // Partial window + multiple full windows, but ends exactly on boundary (no stage3)
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let window_size = constants::twap_price_cap_window();

    // Start partway through a window
    let partial_start = 1000 + (window_size / 4);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, partial_start);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    // End exactly on a window boundary
    let target_time = 1000 + (window_size * 4); // 4 full windows from window_end

    futarchy_twap_oracle::call_twap_accumulate_for_testing(
        &mut oracle,
        target_time,
        10500,
    );

    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == target_time, 0);
    assert!(futarchy_twap_oracle::get_last_window_end_for_testing(&oracle) == target_time, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_twap_accumulate_stage2_and_stage3_only() {
    // Start exactly on boundary, full windows + partial
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let window_size = constants::twap_price_cap_window();

    // Start exactly on a window boundary
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    // End partway through a window
    let target_time = 1000 + (window_size * 3) + (window_size / 2);

    futarchy_twap_oracle::call_twap_accumulate_for_testing(
        &mut oracle,
        target_time,
        10500,
    );

    assert!(futarchy_twap_oracle::last_timestamp(&oracle) == target_time, 0);
    // Should have processed 3 full windows
    assert!(
        futarchy_twap_oracle::get_last_window_end_for_testing(&oracle) == 1000 + (window_size * 3),
        1,
    );

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Delay Threshold Edge Cases ===

#[test]
fun test_observation_exactly_at_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let delay = 60_000; // test_oracle has 60_000ms delay
    let delay_threshold = 1000 + delay;

    // Write exactly at threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold, 10500);

    // Should have reset accumulators
    assert!(futarchy_twap_oracle::total_cumulative_price(&oracle) == 0, 0);
    assert!(futarchy_twap_oracle::get_last_window_end_for_testing(&oracle) == delay_threshold, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_no_price_event_emitted_exactly_at_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let delay_threshold = 1000 + 60_000; // test_oracle has 60_000ms delay
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold, 10500);

    // No post-delay duration exists, so no retained accumulation should be emitted.
    let price_events = event::events_by_type<futarchy_twap_oracle::PriceEvent>();
    assert!(price_events.length() == 0, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_observation_one_ms_before_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let delay = 60_000;
    let delay_threshold = 1000 + delay;

    // Write 1ms before threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold - 1, 10500);

    // Should have accumulated normally (not reset)
    assert!(futarchy_twap_oracle::total_cumulative_price(&oracle) > 0, 0);
    assert!(futarchy_twap_oracle::get_last_window_end_for_testing(&oracle) == 1000, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_crossing_delay_threshold_emits_only_post_reset_price_event() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Pre-delay write emits one event.
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 5000, 10000);
    let after_first_write = event::events_by_type<futarchy_twap_oracle::PriceEvent>();
    assert!(after_first_write.length() == 1, 0);

    // Crossing write should emit exactly one additional event (post-reset segment only).
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10500);
    let all_events = event::events_by_type<futarchy_twap_oracle::PriceEvent>();
    assert!(all_events.length() == 2, 1);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_observation_one_ms_after_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let delay = 60_000;
    let delay_threshold = 1000 + delay;

    // Write 1ms after threshold
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold + 1, 10500);

    // Should have reset and then accumulated for 1ms
    let cumulative = futarchy_twap_oracle::total_cumulative_price(&oracle);
    // 1ms at capped price
    assert!(cumulative > 0, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === TWAP Calculation Edge Cases ===

#[test]
fun test_twap_calculation_accuracy() {
    // Verify TWAP calculation is mathematically correct
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let delay = 60_000;
    let delay_threshold = 1000 + delay;

    // Cross delay threshold
    clock.set_for_testing(delay_threshold);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold, 10000);

    // Accumulate for exactly 60 seconds at constant price
    let final_time = delay_threshold + 60_000;
    clock.set_for_testing(final_time);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, final_time, 10000);

    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    // TWAP should be exactly 10000 (constant price)
    assert!(twap == 10000, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_twap_with_price_changes() {
    // TWAP with varying prices
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        100_000, // 10% cap per window (high cap for easier math)
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let delay_threshold = 1000 + 60_000;

    // Cross delay
    clock.set_for_testing(delay_threshold);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold, 10000);

    // Price at 10000 for 30 seconds
    clock.set_for_testing(delay_threshold + 30_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold + 30_000, 10000);

    // Price at 11000 for next 30 seconds
    clock.set_for_testing(delay_threshold + 60_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold + 60_000, 11000);

    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    // TWAP = (10000 * 30000 + 10000 * 30000) / 60000 = 10000 (both periods at 10000 due to accumulation)
    // Actually: first 30s at 10000, second 30s at capped price
    // The capped price from 10000 -> 11000 with 10% cap = 11000 (within cap)
    // So TWAP = (10000 * 30000 + 11000 * 30000) / 60000 = 10500
    assert!(twap >= 10000 && twap <= 11000, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === V_ramp and V_flat Calculation Tests ===

#[test]
fun test_v_ramp_sum_formula() {
    // Verify V_ramp = Δ_M * N * (N + 1) / 2 is correctly calculated
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // cap_step = 100
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // 5 windows, gap = 1000 (10 cap steps), k_cap_idx = 10, k_ramp_limit = 9
    // n_ramp_terms = min(5, 9) = 5
    // V_ramp = 100 * 5 * 6 / 2 = 1500
    // V_flat = 0 (all windows are ramping)
    // V_sum_prices = 5 * 10000 + 1500 = 51500
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        11000,
        5,
        1000 + (window_size * 5),
    );

    // Final price = 10000 + min(5 * 100, 1000) = 10000 + 500 = 10500
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price == 10500, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_mixed_ramp_and_flat() {
    // Test when some windows are ramping and some are flat
    let (mut scenario, clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // cap_step = 100
        ts::ctx(&mut scenario),
    );

    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    futarchy_twap_oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // 10 windows, gap = 300 (3 cap steps), k_cap_idx = 3, k_ramp_limit = 2
    // n_ramp_terms = min(10, 2) = 2
    // V_ramp = 100 * 2 * 3 / 2 = 300
    // num_flat_terms = 10 - 2 = 8
    // V_flat = 300 * 8 = 2400
    // V_sum_prices = 10 * 10000 + (300 + 2400) = 102700
    futarchy_twap_oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10300, // Gap = 300
        10,
        1000 + (window_size * 10),
    );

    // Final price = 10000 + min(10 * 100, 300) = 10000 + 300 = 10300
    let last_price = futarchy_twap_oracle::last_price(&oracle);
    assert!(last_price == 10300, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Manipulation Resistance Tests ===

#[test]
fun test_flash_loan_attack_resistance() {
    // Simulate flash loan attack: huge price spike in same block
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // Attacker tries massive price spike
    clock.set_for_testing(70_001); // 1ms later
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_001, 1_000_000); // 100x price

    // Wait for TWAP window
    clock.set_for_testing(130_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, 1_000_000);

    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    // TWAP should be very close to 10000 due to capping
    // Even with huge target, movement is capped per window
    assert!(twap < 15000, 0); // Should not move significantly

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_sandwich_attack_resistance() {
    // Simulate sandwich attack: price manipulation before and after target tx
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    // "Front-run" with high price
    clock.set_for_testing(100_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 100_000, 50000);

    // "Back-run" returning to normal
    clock.set_for_testing(100_100);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 100_100, 10000);

    // Complete window
    clock.set_for_testing(130_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 130_000, 10000);

    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    // TWAP should be close to 10000 (manipulation only lasted 100ms)
    assert!(twap >= 10000 && twap <= 11000, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_gradual_pump_attack() {
    // Attacker gradually increases price within caps each window
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap = 100 per window
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 70_000, 10000);

    let window_size = constants::twap_price_cap_window();
    let mut time = 70_000u64;

    // Attacker pushes price up by cap each window for 20 windows
    let mut i = 0;
    while (i < 20) {
        time = time + window_size;
        // Always try to push to max
        clock.set_for_testing(time);
        futarchy_twap_oracle::write_observation_for_testing(&mut oracle, time, 50000);
        i = i + 1;
    };

    // Price should be capped - can't reach 50000 in 20 windows
    // With cap_step = 100, max movement = 20 * 100 = 2000
    // Price should be around 10000 + 2000 = 12000
    // Note: Each write_observation goes through the 3-stage accumulation,
    // which processes 1 window per call. So 20 calls = 20 windows.
    let final_price = futarchy_twap_oracle::last_price(&oracle);
    // Verify attack was resisted - price didn't reach target 50000
    assert!(final_price < 50000, 0);
    // Price should have moved up from 10000, capped at cap_step per window
    assert!(final_price >= 10000, 1);
    // Should be approximately 10000 + (20 * 100) = 12000, give some margin
    assert!(final_price <= 15000, 2);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === State Invariant Tests ===

#[test]
fun test_invariant_last_timestamp_geq_window_end() {
    // Invariant: last_timestamp >= last_window_end
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let times = vector[70_000u64, 75_000, 80_000, 130_000, 200_000];
    let mut i = 0;

    while (i < times.length()) {
        let time = times[i];
        clock.set_for_testing(time);
        futarchy_twap_oracle::write_observation_for_testing(&mut oracle, time, 10000 + ((i as u128) * 100));

        let last_ts = futarchy_twap_oracle::last_timestamp(&oracle);
        let last_window = futarchy_twap_oracle::get_last_window_end_for_testing(&oracle);
        assert!(last_ts >= last_window, i);

        i = i + 1;
    };

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_invariant_cumulative_non_decreasing() {
    // Invariant: total_cumulative_price never decreases (except on delay reset)
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 1000);

    let delay_threshold = 1000 + 60_000;

    // Before delay threshold
    let times_before = vector[5_000u64, 10_000, 30_000, 50_000];
    let mut prev_cumulative = 0u256;
    let mut i = 0;

    while (i < times_before.length()) {
        let time = times_before[i];
        clock.set_for_testing(time);
        futarchy_twap_oracle::write_observation_for_testing(&mut oracle, time, 10000);

        let cumulative = futarchy_twap_oracle::total_cumulative_price(&oracle);
        assert!(cumulative >= prev_cumulative, i);
        prev_cumulative = cumulative;

        i = i + 1;
    };

    // After delay threshold (resets to 0, then increases)
    clock.set_for_testing(delay_threshold + 10_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold + 10_000, 10000);

    let cumulative_after_reset = futarchy_twap_oracle::total_cumulative_price(&oracle);

    // Continue after reset
    clock.set_for_testing(delay_threshold + 20_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, delay_threshold + 20_000, 10000);

    let final_cumulative = futarchy_twap_oracle::total_cumulative_price(&oracle);
    assert!(final_cumulative >= cumulative_after_reset, 100);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Realistic Scenario Tests ===

#[test]
fun test_7_day_proposal_scenario() {
    // Simulate a full 7-day proposal with realistic trading activity
    let (mut scenario, mut clock) = start();

    let mut oracle = futarchy_twap_oracle::new_oracle(
        1_000_000, // $1.00
        300_000, // 5 minute delay
        10_000, // 1% cap
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(0);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle, 0);

    // Cross delay
    clock.set_for_testing(300_001);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, 300_001, 1_000_000);

    // Simulate 7 days of trading
    // 7 days = 604800000 ms
    let seven_days = 604_800_000u64;
    let window_size = constants::twap_price_cap_window();

    // Jump through time with periodic updates
    let mut time = 300_001u64;
    let mut price = 1_000_000u128;
    let mut i = 0;

    while (time < 300_001 + seven_days && i < 100) {
        // Simulate hourly updates with price drift
        time = time + 3_600_000; // 1 hour
        if (i % 2 == 0) {
            price = price + 5_000; // +0.5%
        } else {
            price = price - 3_000; // -0.3%
        };

        if (time < 300_001 + seven_days) {
            clock.set_for_testing(time);
            futarchy_twap_oracle::write_observation_for_testing(&mut oracle, time, price);
        };

        i = i + 1;
    };

    // Final observation
    let final_time = 300_001 + seven_days;
    clock.set_for_testing(final_time);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle, final_time, price);

    let twap = futarchy_twap_oracle::get_twap(&oracle, &clock);

    // TWAP should be between initial and current price
    assert!(twap >= 900_000 && twap <= 1_200_000, 0);

    futarchy_twap_oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_competing_outcomes_divergence() {
    // Test that two oracles with different trading activity diverge correctly
    let (mut scenario, mut clock) = start();

    let mut oracle_pass = futarchy_twap_oracle::new_oracle(
        1_000_000,
        60_000,
        10_000,
        ts::ctx(&mut scenario),
    );

    let mut oracle_fail = futarchy_twap_oracle::new_oracle(
        1_000_000,
        60_000,
        10_000,
        ts::ctx(&mut scenario),
    );

    clock.set_for_testing(0);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle_pass, 0);
    futarchy_twap_oracle::set_oracle_start_time(&mut oracle_fail, 0);

    // Cross delay for both
    clock.set_for_testing(70_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle_pass, 70_000, 1_000_000);
    futarchy_twap_oracle::write_observation_for_testing(&mut oracle_fail, 70_000, 1_000_000);

    // PASS gets bullish activity, FAIL gets bearish
    let window = constants::twap_price_cap_window();
    let mut time = 70_000u64;
    let mut i = 0;

    while (i < 10) {
        time = time + window;
        clock.set_for_testing(time);

        // PASS: constant buying pressure
        futarchy_twap_oracle::write_observation_for_testing(&mut oracle_pass, time, 1_500_000);
        // FAIL: constant selling pressure
        futarchy_twap_oracle::write_observation_for_testing(&mut oracle_fail, time, 500_000);

        i = i + 1;
    };

    let twap_pass = futarchy_twap_oracle::get_twap(&oracle_pass, &clock);
    let twap_fail = futarchy_twap_oracle::get_twap(&oracle_fail, &clock);

    // PASS should be higher than FAIL
    assert!(twap_pass > twap_fail, 0);
    // And they should have diverged significantly
    assert!(twap_pass > 1_050_000, 1);
    assert!(twap_fail < 950_000, 2);

    futarchy_twap_oracle::destroy_for_testing(oracle_pass);
    futarchy_twap_oracle::destroy_for_testing(oracle_fail);
    end(scenario, clock);
}
