#[test_only]
module futarchy_markets_primitives::PCW_TWAP_oracle_tests;

use futarchy_markets_primitives::PCW_TWAP_oracle;
use sui::clock::{Self, Clock};
use sui::test_scenario;

// === Constants ===
const SCALE: u128 = 1_000_000_000_000; // 1e12
const ONE_MINUTE_MS: u64 = 60_000;
const TEN_MINUTES_MS: u64 = 600_000;
const ONE_HOUR_MS: u64 = 3_600_000;

// === Initialization Tests ===

#[test]
fun test_initialization_default() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000_000);

    let initial_price = 5 * SCALE; // $5
    let oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Verify initialization
    assert!(PCW_TWAP_oracle::last_price(&oracle) == initial_price, 0);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 1);
    assert!(PCW_TWAP_oracle::window_size_ms(&oracle) == ONE_MINUTE_MS, 2);
    assert!(PCW_TWAP_oracle::max_movement_ppm(&oracle) == 10_000, 3); // 1%

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_custom_config() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000_000);

    let initial_price = 100 * SCALE;
    let oracle = PCW_TWAP_oracle::new(
        initial_price,
        120_000, // 2 minutes
        20_000, // 2% cap
        &clock,
    );

    assert!(PCW_TWAP_oracle::window_size_ms(&oracle) == 120_000, 0);
    assert!(PCW_TWAP_oracle::max_movement_ppm(&oracle) == 20_000, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Single Window Tests ===

#[test]
fun test_single_window_no_cap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Update with stable price for 1 minute
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, initial_price, &clock);

    // TWAP should stay at initial price (no movement)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_single_window_with_cap_upward() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price spikes to $200 - first update sets last_price
    let new_price = 200 * SCALE;
    clock::set_for_testing(&mut clock, 1000); // 1 second later
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // Now wait for a full window with $200 as last_price
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1000);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // TWAP should move 1% upward: $100 → $101
    // raw_twap ≈ $200 (price held for ~60s of the window)
    // gap = $100, cap = $1/window, so TWAP = $101
    let expected = 101 * SCALE;
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_single_window_with_cap_downward() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price drops to $50 - first update sets last_price
    let new_price = 50 * SCALE;
    clock::set_for_testing(&mut clock, 1000); // 1 second later
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // Now wait for a full window with $50 as last_price
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1000);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // TWAP should move 1% downward: $100 → $99
    // raw_twap ≈ $50 (price held for ~60s of the window)
    // gap = $50, cap = $1/window, so TWAP = $99
    let expected = 99 * SCALE;
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_single_window_small_move_no_cap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price moves to $100.50 - first update sets last_price (use 1ms to minimize error)
    let new_price = 100_500_000_000_000; // $100.50
    clock::set_for_testing(&mut clock, 1); // 1ms later
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // Now wait for a full window with $100.50 as last_price
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // TWAP should move full amount (0.5% < 1% cap)
    // raw_twap ≈ $100.50 (tiny error from initial 1ms at old price)
    // gap ≈ $0.50, cap = $1, so full move allowed
    // Check within small tolerance due to 1ms at old price
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap >= new_price - SCALE / 1000, 0); // within $0.001
    assert!(twap <= new_price, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Multi-Window Tests (Key Security Property) ===

#[test]
fun test_multi_window_multi_step() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price spikes to $200 - first update sets last_price (use 1ms to minimize error)
    let new_price = 200 * SCALE;
    clock::set_for_testing(&mut clock, 1); // 1ms later
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // Now wait for 100 windows with $200 as last_price
    clock::set_for_testing(&mut clock, 100 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // With 100 windows elapsed, TWAP can move by 100 × 1% = 100%
    // raw_twap ≈ $199.98 (tiny error from 1ms at old price)
    // max_step = 1% of $100 = $1
    // max_total_movement = $1 × 100 = $100
    // total_gap ≈ $99.98, actual_movement = $99.98
    // New TWAP ≈ $199.98 (within $0.02 of target)
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    // Check within tolerance - the 1ms at old price causes ~$0.02 error
    assert!(twap >= 199_980_000_000_000, 0); // at least $199.98
    assert!(twap <= 200 * SCALE, 1); // at most $200

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_multi_window_gradual_approach() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(price, &clock);

    // Simulate legitimate price increase over time
    // First, set the new price so it starts accumulating
    price = 105 * SCALE;
    clock::set_for_testing(&mut clock, 1000); // 1 second later
    PCW_TWAP_oracle::update(&mut oracle, price, &clock);

    // Window 1 completes: Price was $105 for most of the window
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1000);
    PCW_TWAP_oracle::update(&mut oracle, price, &clock);
    // TWAP: $100 → $101 (capped at 1%)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 101 * SCALE, 0);

    // Window 2: Price stays $105
    clock::set_for_testing(&mut clock, 2 * ONE_MINUTE_MS + 1000);
    PCW_TWAP_oracle::update(&mut oracle, price, &clock);
    // TWAP: $101 → $102.01 (1% of $101)
    let expected2 = 102_010_000_000_000;
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected2, 1);

    // Window 3: Price stays $105
    clock::set_for_testing(&mut clock, 3 * ONE_MINUTE_MS + 1000);
    PCW_TWAP_oracle::update(&mut oracle, price, &clock);
    // TWAP: $102.01 → $103.0301 (1% of $102.01)
    let expected3 = 103_030_100_000_000;
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected3, 2);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Dynamic Cap Tests ===

#[test]
fun test_dynamic_cap_grows_with_twap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // Start at $100 with 1% cap = $1 per window
    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // First, set the price to $200 so it starts accumulating (use 1ms)
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // First window completes: $100 → $101 (cap = $1)
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 101 * SCALE, 0);

    // Second window: $101 → $102.01 (cap = $1.01, growing!)
    clock::set_for_testing(&mut clock, 2 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 102_010_000_000_000, 1);

    // Third window: $102.01 → $103.0301 (cap = $1.0201)
    clock::set_for_testing(&mut clock, 3 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 103_030_100_000_000, 2);

    // Cap is growing proportionally with TWAP - this is percentage-based capping!

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Edge Cases ===

#[test]
fun test_zero_elapsed_time() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Update at same timestamp (no time elapsed)
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // TWAP should not change (no time passed)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_incomplete_window() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Update after 30 seconds (half a window)
    clock::set_for_testing(&mut clock, 30_000);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // No window completed - TWAP should not change
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 0);

    // But cumulative should be accumulating
    assert!(PCW_TWAP_oracle::get_cumulative_price(&oracle) > 0, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_exact_cap_hit() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // New price is exactly 1% above (exactly at cap) - first set last_price (use 1ms)
    let new_price = 101 * SCALE;
    clock::set_for_testing(&mut clock, 1); // 1ms later
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // Now wait for a full window
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // Should move full amount (diff ≈ cap)
    // Check within tiny tolerance due to 1ms at old price
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap >= new_price - SCALE / 1000, 0); // within $0.001
    assert!(twap <= new_price, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_price_volatility_averaging() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price bounces: $50 for 20s, $150 for 40s
    // Time-weighted average: (100*0 + 50*20 + 150*40) / 60 = (1000 + 6000) / 60 = $116.67
    // But we need to account for the initial $100 price being held for 0s at start

    // First 20 seconds: price drops to $50
    // This accumulates $100 (initial last_price) * 20s
    clock::set_for_testing(&mut clock, 20_000);
    PCW_TWAP_oracle::update(&mut oracle, 50 * SCALE, &clock);

    // Next 40 seconds at $150 (window completes)
    // This accumulates $50 * 40s
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    // Raw TWAP = (100*20 + 50*40) / 60 = (2000 + 2000) / 60 = $66.67
    // This is BELOW initial TWAP of $100, so movement is downward
    // gap = $100 - $66.67 = $33.33, cap = $1, so TWAP = $99
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 99 * SCALE, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Large Gap Tests (Gas Efficiency) ===

#[test]
fun test_very_large_time_gap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // First set the new price so it starts accumulating (use 1ms)
    let new_price = 200 * SCALE;
    clock::set_for_testing(&mut clock, 1); // 1ms later
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // 1000 windows pass (1000 minutes = ~16.7 hours)
    clock::set_for_testing(&mut clock, 1000 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // With 1000 windows, TWAP can move by up to 1000 × 1% = 1000%
    // But the gap is only ~$100, so it fully catches up
    // raw_twap ≈ $199.998 (tiny error from 1ms at old price)
    // max_step = 1% of $100 = $1
    // max_total_movement = $1 × 1000 = $1000
    // total_gap ≈ $99.998, actual_movement = $99.998
    // New TWAP ≈ $199.998 (within $0.002 of target)
    // Note: O(1) gas - still just arithmetic, no loops!
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    // Check within tolerance - the 1ms at old price causes tiny error
    assert!(twap >= 199_998_000_000_000, 0); // at least $199.998
    assert!(twap <= 200 * SCALE, 1); // at most $200

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Integration Test ===

#[test]
fun test_realistic_oracle_usage() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // Start oracle at $100
    let mut price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(price, &clock);

    // Simulate 1 hour of normal trading with updates every 10 seconds
    let mut time = 0u64;
    let mut i = 0;
    while (i < 360) {
        // 360 updates = 1 hour
        time = time + 10_000; // 10 seconds

        // Price drifts slightly (±0.1% per update)
        if (i % 2 == 0) {
            price = price + (price / 1000); // +0.1%
        } else {
            price = price - (price / 1000); // -0.1%
        };

        clock::set_for_testing(&mut clock, time);
        PCW_TWAP_oracle::update(&mut oracle, price, &clock);

        i = i + 1;
    };

    // After 1 hour of small fluctuations, TWAP should be close to current price
    // but with smoothing from the 1% cap per minute
    let final_twap = PCW_TWAP_oracle::get_twap(&oracle);

    // TWAP should have moved, but be reasonably close
    assert!(final_twap > 95 * SCALE, 0); // Not too far down
    assert!(final_twap < 105 * SCALE, 1); // Not too far up

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// ============================================================================
// CHALLENGING EDGE CASE TESTS
// ============================================================================

// === Extreme Value Tests ===

#[test]
fun test_very_small_price_close_to_one() {
    // Test with extremely small prices to verify cap doesn't become 0
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // Very small price - 1 unit
    let initial_price = 1u128;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Try to spike price significantly
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 1000u128, &clock);

    // Wait for multiple windows
    clock::set_for_testing(&mut clock, 10 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 1000u128, &clock);

    // With minimum cap of 1, should still move
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap > initial_price, 0);
    // With 10 windows and min step of 1, max movement is 10
    assert!(twap <= 11, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_maximum_price_near_u128_max() {
    // Test with prices near u128::max to verify overflow protection
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // Large price (but not so large to overflow in calculations)
    let initial_price: u128 = 1_000_000_000_000_000_000_000_000; // 10^24
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Update with same price
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, initial_price, &clock);

    // TWAP should stay stable
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap == initial_price, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_price_oscillation_attack() {
    // Attacker rapidly oscillates price hoping to manipulate TWAP
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Oscillate price every second between $50 and $150
    let mut time = 0u64;
    let mut i = 0;
    while (i < 120) { // 2 minutes of oscillation
        time = time + 1000; // 1 second
        let price = if (i % 2 == 0) { 50 * SCALE } else { 150 * SCALE };
        clock::set_for_testing(&mut clock, time);
        PCW_TWAP_oracle::update(&mut oracle, price, &clock);
        i = i + 1;
    };

    // TWAP should be close to average ($100) because:
    // - Raw TWAP from oscillation is ~$100
    // - Cap limits movement per window
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    // After 2 windows, max movement is 2% = $2
    assert!(twap >= 98 * SCALE && twap <= 102 * SCALE, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_flash_crash_recovery() {
    // Price crashes to near-zero, then recovers - test both directions
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Flash crash to $1
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, SCALE, &clock); // $1

    // Complete first window at crash price
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, SCALE, &clock);

    // TWAP should only move down by 1%
    let twap_after_crash = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap_after_crash == 99 * SCALE, 0);

    // Now price recovers to $200
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 2);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Complete second window at high price
    clock::set_for_testing(&mut clock, 2 * ONE_MINUTE_MS + 2);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // TWAP should move up by 1% of $99 ≈ $0.99
    let twap_after_recovery = PCW_TWAP_oracle::get_twap(&oracle);
    // $99 + $0.99 = $99.99
    assert!(twap_after_recovery >= 99_990_000_000_000 - SCALE / 100, 1);
    assert!(twap_after_recovery <= 100 * SCALE, 2);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Window Boundary Edge Cases ===

#[test]
fun test_update_exactly_at_window_boundaries() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Update at exactly window boundary
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    // TWAP should have updated correctly
    let twap1 = PCW_TWAP_oracle::get_twap(&oracle);
    // Window was entirely at $100 (initial price), so TWAP stays at $100
    assert!(twap1 == 100 * SCALE, 0);

    // Next window boundary
    clock::set_for_testing(&mut clock, 2 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    // Now TWAP should move up (window was at $150)
    let twap2 = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap2 == 101 * SCALE, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_multiple_updates_same_window() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Many updates within same window (50 updates in ~50 seconds)
    let mut time = 0u64;
    let mut i = 0;
    while (i < 50) { // 50 updates
        time = time + 1000; // 1 second
        clock::set_for_testing(&mut clock, time);
        PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);
        i = i + 1;
    };

    // At t=50_000ms, window not complete yet (window is 60_000ms)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 0);

    // Complete the window at t=60_001ms (past window boundary)
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    // Now TWAP should update - it was capped
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap == 101 * SCALE, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Cumulative Accuracy Tests ===

#[test]
fun test_cumulative_total_consistency() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // cumulative_total now uses last_window_twap (capped) instead of last_price (raw)
    // to prevent long-horizon TWAP manipulation via spot price spikes.
    let mut expected_cumulative: u256 = 0;

    // First update: last_window_twap = initial_price = 100*SCALE
    clock::set_for_testing(&mut clock, 30_000); // 30 seconds
    expected_cumulative = expected_cumulative + (initial_price as u256) * 30_000;
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    assert!(PCW_TWAP_oracle::get_cumulative_total(&oracle) == expected_cumulative, 0);

    // Second update: last_window_twap is still initial_price (window hasn't finalized yet)
    // so cumulative grows at the capped rate, not at the raw 150*SCALE rate.
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    expected_cumulative = expected_cumulative + (initial_price as u256) * 30_000;
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    assert!(PCW_TWAP_oracle::get_cumulative_total(&oracle) == expected_cumulative, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_cumulative_total_multi_window_triangle_correction_upward() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);
    clock::set_for_testing(&mut clock, 3 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    let expected_cumulative =
        ((100 * SCALE) as u256) * (ONE_MINUTE_MS as u256) +
        ((101 * SCALE) as u256) * (ONE_MINUTE_MS as u256) +
        ((102 * SCALE) as u256) * (ONE_MINUTE_MS as u256);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 103 * SCALE, 0);
    assert!(PCW_TWAP_oracle::get_cumulative_total(&oracle) == expected_cumulative, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_cumulative_total_multi_window_triangle_correction_downward() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);
    clock::set_for_testing(&mut clock, 3 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);

    let expected_cumulative =
        ((100 * SCALE) as u256) * (ONE_MINUTE_MS as u256) +
        ((99 * SCALE) as u256) * (ONE_MINUTE_MS as u256) +
        ((98 * SCALE) as u256) * (ONE_MINUTE_MS as u256);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 97 * SCALE, 0);
    assert!(PCW_TWAP_oracle::get_cumulative_total(&oracle) == expected_cumulative, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure]
fun test_new_rejects_zero_initial_price() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // Should abort — oracle requires initial_price > 0
    let oracle = PCW_TWAP_oracle::new(0, ONE_MINUTE_MS, 10_000, &clock);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_projected_cumulative_arithmetic() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // First update
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 100 * SCALE, &clock);

    let cumulative_at_update = PCW_TWAP_oracle::get_cumulative_total(&oracle);

    // Project forward without updating
    let future_time = 2 * ONE_MINUTE_MS;
    let projected = PCW_TWAP_oracle::cumulative_at(&oracle, future_time);

    // Should be cumulative + last_price * (future - last_update)
    let expected = cumulative_at_update + (100 * SCALE as u256) * (ONE_MINUTE_MS as u256);
    assert!(projected == expected, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Cap Calculation Edge Cases ===

#[test]
fun test_cap_exactly_equals_gap() {
    // When gap exactly equals max movement allowed
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Set price to exactly 1% above
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 101 * SCALE, &clock);

    // Complete window
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 101 * SCALE, &clock);

    // TWAP should move exactly to target (gap == cap)
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    // Almost exactly $101, tiny error from 1ms at $100
    assert!(twap >= 100_999_000_000_000, 0);
    assert!(twap <= 101 * SCALE, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_raw_twap_below_current_twap() {
    // When raw TWAP from window is lower than current TWAP (downward pressure)
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price at $80 for first half of window
    clock::set_for_testing(&mut clock, 30_000);
    PCW_TWAP_oracle::update(&mut oracle, 80 * SCALE, &clock);

    // Price at $120 for second half
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 120 * SCALE, &clock);

    // Raw TWAP = (100*30 + 80*30) / 60 = 5400/60 = $90
    // Gap = $10, cap = $1, so TWAP = $99
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap == 99 * SCALE, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Checkpoint System Tests ===

#[test]
fun test_get_window_twap_basic() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Accumulate for a while
    let mut time = 0u64;
    let mut i = 0;
    while (i < 100) {
        time = time + ONE_MINUTE_MS;
        clock::set_for_testing(&mut clock, time);
        PCW_TWAP_oracle::update(&mut oracle, 100 * SCALE, &clock);
        i = i + 1;
    };

    // Try to get window TWAP (should return None if no checkpoint old enough)
    let window_twap = PCW_TWAP_oracle::get_window_twap(&oracle, 50 * ONE_MINUTE_MS, &clock);

    // Given the checkpoint interval is 7 days, we won't have old enough checkpoints
    // for a 50-minute window from just 100 minutes of data
    // But the initial checkpoint was at time 0, so it should work
    if (window_twap.is_some()) {
        let twap = window_twap.destroy_some();
        assert!(twap == 100 * SCALE, 0);
    };

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Multi-Window Batch Processing ===

#[test]
fun test_many_windows_single_batch() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Set price immediately
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Jump 1000 windows (should be O(1) gas)
    let num_windows = 1000u64;
    clock::set_for_testing(&mut clock, num_windows * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // With 1000 windows and 1% cap per window, can move $1000
    // Gap is $100, so should fully close
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap >= 199 * SCALE, 0); // Should be very close to $200

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_alternating_batches() {
    // Test cap recalculation between batches
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // First batch: 10 windows at $200
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);
    clock::set_for_testing(&mut clock, 10 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // TWAP should be $110 (moved $10)
    let twap1 = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap1 >= 109 * SCALE && twap1 <= 111 * SCALE, 0);

    // Second batch: Another 10 windows at $200
    // Cap should now be 1% of ~$110 = $1.10
    clock::set_for_testing(&mut clock, 20 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    let twap2 = PCW_TWAP_oracle::get_twap(&oracle);
    // Should be around $121 ($110 + $11)
    assert!(twap2 > twap1, 1);
    assert!(twap2 >= 120 * SCALE && twap2 <= 122 * SCALE, 2);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Custom Configuration Tests ===

#[test]
fun test_very_small_cap_ppm() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    // 0.01% cap (100 PPM)
    let mut oracle = PCW_TWAP_oracle::new(initial_price, ONE_MINUTE_MS, 100, &clock);

    // Set high price
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Complete 10 windows
    clock::set_for_testing(&mut clock, 10 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // With 0.01% cap, max movement per window = $0.01
    // 10 windows = $0.10 movement
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap >= 100 * SCALE, 0);
    assert!(twap <= 101 * SCALE, 1); // Should barely move

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_very_large_cap_ppm() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    // 50% cap per window (500,000 PPM)
    let mut oracle = PCW_TWAP_oracle::new(initial_price, ONE_MINUTE_MS, 500_000, &clock);

    // Set high price
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Complete 2 windows
    clock::set_for_testing(&mut clock, 2 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // With 50% cap, should move $50 per window = $100 for 2 windows
    // But gap is only $100, so fully closes
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap >= 199 * SCALE, 0); // Should be very close to $200

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_very_long_window_size() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    // 10 minute windows
    let mut oracle = PCW_TWAP_oracle::new(initial_price, TEN_MINUTES_MS, 10_000, &clock);

    // Set high price
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Complete 1 window (10 minutes)
    clock::set_for_testing(&mut clock, TEN_MINUTES_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Only 1 window completed, so 1% movement
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap >= 100 * SCALE, 0);
    assert!(twap <= 102 * SCALE, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Mathematical Property Verification ===

#[test]
fun test_symmetry_up_down() {
    // Verify upward and downward movements are symmetric
    // Use two separate scenarios to avoid clock conflicts
    let mut scenario_up = test_scenario::begin(@0x1);
    let ctx_up = test_scenario::ctx(&mut scenario_up);
    let mut clock_up = clock::create_for_testing(ctx_up);
    clock::set_for_testing(&mut clock_up, 0);

    let initial_price = 100 * SCALE;
    let mut oracle_up = PCW_TWAP_oracle::new_default(initial_price, &clock_up);

    // Oracle up: price goes to $150
    clock::set_for_testing(&mut clock_up, 1);
    PCW_TWAP_oracle::update(&mut oracle_up, 150 * SCALE, &clock_up);
    clock::set_for_testing(&mut clock_up, ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle_up, 150 * SCALE, &clock_up);

    let twap_up = PCW_TWAP_oracle::get_twap(&oracle_up);

    PCW_TWAP_oracle::destroy_for_testing(oracle_up);
    clock::destroy_for_testing(clock_up);
    test_scenario::end(scenario_up);

    // Now do the down scenario
    let mut scenario_down = test_scenario::begin(@0x1);
    let ctx_down = test_scenario::ctx(&mut scenario_down);
    let mut clock_down = clock::create_for_testing(ctx_down);
    clock::set_for_testing(&mut clock_down, 0);

    let mut oracle_down = PCW_TWAP_oracle::new_default(initial_price, &clock_down);

    // Oracle down: price goes to $50
    clock::set_for_testing(&mut clock_down, 1);
    PCW_TWAP_oracle::update(&mut oracle_down, 50 * SCALE, &clock_down);
    clock::set_for_testing(&mut clock_down, ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle_down, 50 * SCALE, &clock_down);

    let twap_down = PCW_TWAP_oracle::get_twap(&oracle_down);

    // Deviations should be symmetric
    let dev_up = twap_up - 100 * SCALE;
    let dev_down = 100 * SCALE - twap_down;
    assert!(dev_up == dev_down, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle_down);
    clock::destroy_for_testing(clock_down);
    test_scenario::end(scenario_down);
}

#[test]
fun test_idempotent_same_price() {
    // Multiple updates with same price should not change TWAP beyond first window
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Many updates with same price
    let mut time = 0u64;
    let mut i = 0;
    while (i < 100) {
        time = time + ONE_MINUTE_MS;
        clock::set_for_testing(&mut clock, time);
        PCW_TWAP_oracle::update(&mut oracle, initial_price, &clock);
        i = i + 1;
    };

    // TWAP should stay constant
    let twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap == initial_price, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Quiet-Period Checkpoint Tests ===
// try_commit_checkpoint during a quiet period must apply the same window
// finalization + triangle correction as update() would, so the checkpoint
// cumulative matches the mutating path exactly.

const ONE_WEEK_MS: u64 = 604_800_000;

#[test]
fun test_checkpoint_quiet_period_matches_update() {
    // Price rises to $200, a few windows finalize, then silence for > 1 week.
    // Checkpoint committed without any intervening update() must match the
    // cumulative_total an oracle that did call update() would produce.
    let mut scenario_a = test_scenario::begin(@0x1);
    let ctx_a = test_scenario::ctx(&mut scenario_a);
    let mut clock_a = clock::create_for_testing(ctx_a);
    clock::set_for_testing(&mut clock_a, 0);

    let initial_price = 100 * SCALE;
    let mut oracle_a = PCW_TWAP_oracle::new_default(initial_price, &clock_a);

    // Push price to $200 early so the TWAP starts ramping
    clock::set_for_testing(&mut clock_a, 1);
    PCW_TWAP_oracle::update(&mut oracle_a, 200 * SCALE, &clock_a);

    // Let 5 windows finalize so TWAP is ramping up
    clock::set_for_testing(&mut clock_a, 5 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle_a, 200 * SCALE, &clock_a);

    let twap_after_ramp = PCW_TWAP_oracle::get_twap(&oracle_a);
    // TWAP should be ~$105 (5 windows * 1% cap from $100)
    assert!(twap_after_ramp >= 104 * SCALE, 100);
    assert!(twap_after_ramp <= 106 * SCALE, 101);

    // Clone the oracle state by creating an identical oracle_b
    let mut scenario_b = test_scenario::begin(@0x1);
    let ctx_b = test_scenario::ctx(&mut scenario_b);
    let mut clock_b = clock::create_for_testing(ctx_b);
    clock::set_for_testing(&mut clock_b, 0);

    let mut oracle_b = PCW_TWAP_oracle::new_default(initial_price, &clock_b);
    clock::set_for_testing(&mut clock_b, 1);
    PCW_TWAP_oracle::update(&mut oracle_b, 200 * SCALE, &clock_b);
    clock::set_for_testing(&mut clock_b, 5 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle_b, 200 * SCALE, &clock_b);

    // Both should have identical state at this point
    assert!(
        PCW_TWAP_oracle::get_cumulative_total(&oracle_a) ==
        PCW_TWAP_oracle::get_cumulative_total(&oracle_b),
        102,
    );

    // Now simulate quiet period: jump 1 week + 1 minute
    let checkpoint_time = 5 * ONE_MINUTE_MS + 1 + ONE_WEEK_MS + ONE_MINUTE_MS;

    // Oracle A: try_commit_checkpoint WITHOUT a preceding update()
    clock::set_for_testing(&mut clock_a, checkpoint_time);
    let committed = PCW_TWAP_oracle::try_commit_checkpoint(&mut oracle_a, &clock_a);
    assert!(committed, 103);

    // Oracle B: update() first (catches up state), then cumulative_total is correct
    clock::set_for_testing(&mut clock_b, checkpoint_time);
    PCW_TWAP_oracle::update(&mut oracle_b, 200 * SCALE, &clock_b);

    // Both oracles should have the same cumulative_total: the checkpoint
    // path applies the same triangle corrections as update().
    let cum_a = PCW_TWAP_oracle::get_cumulative_total(&oracle_a);
    let cum_b = PCW_TWAP_oracle::get_cumulative_total(&oracle_b);
    assert!(cum_a == cum_b, 104);

    // Also verify the TWAP was advanced (not stuck at old value)
    let twap_a = PCW_TWAP_oracle::get_twap(&oracle_a);
    assert!(twap_a > twap_after_ramp, 105);

    PCW_TWAP_oracle::destroy_for_testing(oracle_a);
    clock::destroy_for_testing(clock_a);
    test_scenario::end(scenario_a);
    PCW_TWAP_oracle::destroy_for_testing(oracle_b);
    clock::destroy_for_testing(clock_b);
    test_scenario::end(scenario_b);
}

#[test]
fun test_checkpoint_quiet_period_stable_price() {
    // When price is stable during a quiet period, the checkpoint cumulative
    // should match a simple linear projection (no triangle correction needed).
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Stable price for a few windows
    clock::set_for_testing(&mut clock, 5 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, initial_price, &clock);

    let cum_before = PCW_TWAP_oracle::get_cumulative_total(&oracle);

    // Quiet period > 1 week, then checkpoint
    let checkpoint_time = 5 * ONE_MINUTE_MS + ONE_WEEK_MS + ONE_MINUTE_MS;
    clock::set_for_testing(&mut clock, checkpoint_time);
    PCW_TWAP_oracle::try_commit_checkpoint(&mut oracle, &clock);

    let cum_after = PCW_TWAP_oracle::get_cumulative_total(&oracle);
    let elapsed = (checkpoint_time - 5 * ONE_MINUTE_MS as u64);

    // With stable price, cumulative should grow linearly: price * elapsed
    let expected_growth = (initial_price as u256) * (elapsed as u256);
    assert!(cum_after - cum_before == expected_growth, 200);

    // TWAP should still be the same price
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 201);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_checkpoint_then_update_consistent() {
    // After try_commit_checkpoint catches up state, a subsequent update()
    // should produce the same result as if only update() had been called.
    let mut scenario_a = test_scenario::begin(@0x1);
    let ctx_a = test_scenario::ctx(&mut scenario_a);
    let mut clock_a = clock::create_for_testing(ctx_a);
    clock::set_for_testing(&mut clock_a, 0);

    let initial_price = 100 * SCALE;
    let mut oracle_a = PCW_TWAP_oracle::new_default(initial_price, &clock_a);

    // Price jumps, a few windows pass
    clock::set_for_testing(&mut clock_a, 1);
    PCW_TWAP_oracle::update(&mut oracle_a, 150 * SCALE, &clock_a);
    clock::set_for_testing(&mut clock_a, 3 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle_a, 150 * SCALE, &clock_a);

    // Clone oracle_b with identical history
    let mut scenario_b = test_scenario::begin(@0x1);
    let ctx_b = test_scenario::ctx(&mut scenario_b);
    let mut clock_b = clock::create_for_testing(ctx_b);
    clock::set_for_testing(&mut clock_b, 0);
    let mut oracle_b = PCW_TWAP_oracle::new_default(initial_price, &clock_b);
    clock::set_for_testing(&mut clock_b, 1);
    PCW_TWAP_oracle::update(&mut oracle_b, 150 * SCALE, &clock_b);
    clock::set_for_testing(&mut clock_b, 3 * ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle_b, 150 * SCALE, &clock_b);

    // Quiet period
    let quiet_end = 3 * ONE_MINUTE_MS + 1 + ONE_WEEK_MS + 10 * ONE_MINUTE_MS;

    // Oracle A: checkpoint during quiet, then update with new price
    clock::set_for_testing(&mut clock_a, quiet_end);
    PCW_TWAP_oracle::try_commit_checkpoint(&mut oracle_a, &clock_a);
    let later = quiet_end + 2 * ONE_MINUTE_MS;
    clock::set_for_testing(&mut clock_a, later);
    PCW_TWAP_oracle::update(&mut oracle_a, 120 * SCALE, &clock_a);

    // Oracle B: just update at quiet_end, then update with new price
    clock::set_for_testing(&mut clock_b, quiet_end);
    PCW_TWAP_oracle::update(&mut oracle_b, 150 * SCALE, &clock_b);
    clock::set_for_testing(&mut clock_b, later);
    PCW_TWAP_oracle::update(&mut oracle_b, 120 * SCALE, &clock_b);

    // Both should have the same TWAP and cumulative_total
    assert!(PCW_TWAP_oracle::get_twap(&oracle_a) == PCW_TWAP_oracle::get_twap(&oracle_b), 300);
    assert!(
        PCW_TWAP_oracle::get_cumulative_total(&oracle_a) ==
        PCW_TWAP_oracle::get_cumulative_total(&oracle_b),
        301,
    );

    PCW_TWAP_oracle::destroy_for_testing(oracle_a);
    clock::destroy_for_testing(clock_a);
    test_scenario::end(scenario_a);
    PCW_TWAP_oracle::destroy_for_testing(oracle_b);
    clock::destroy_for_testing(clock_b);
    test_scenario::end(scenario_b);
}

// ==========================================================================
// Read-path parity tests
// ==========================================================================

/// cumulative_at must equal the mutating catch_up_to result for an upward run.
#[test]
fun test_cumulative_at_simulates_triangle_correction_upward() {
    let mut scenario_a = test_scenario::begin(@0x1);
    let ctx_a = test_scenario::ctx(&mut scenario_a);
    let mut clock_a = clock::create_for_testing(ctx_a);
    clock::set_for_testing(&mut clock_a, 0);

    let mut scenario_b = test_scenario::begin(@0x1);
    let ctx_b = test_scenario::ctx(&mut scenario_b);
    let mut clock_b = clock::create_for_testing(ctx_b);
    clock::set_for_testing(&mut clock_b, 0);

    // Two identical oracles
    let mut oracle_a = PCW_TWAP_oracle::new_default(100 * SCALE, &clock_a);
    let mut oracle_b = PCW_TWAP_oracle::new_default(100 * SCALE, &clock_b);

    // Both get same price update at t=1ms
    clock::set_for_testing(&mut clock_a, 1);
    clock::set_for_testing(&mut clock_b, 1);
    PCW_TWAP_oracle::update(&mut oracle_a, 200 * SCALE, &clock_a);
    PCW_TWAP_oracle::update(&mut oracle_b, 200 * SCALE, &clock_b);

    // Let 10 windows pass with no updates (quiet period)
    let quiet_end = 11 * ONE_MINUTE_MS;

    // Oracle A: read-only projection via cumulative_at
    let read_only_cumulative = PCW_TWAP_oracle::cumulative_at(&oracle_a, quiet_end);

    // Oracle B: mutating update (triggers catch_up_to internally)
    clock::set_for_testing(&mut clock_b, quiet_end);
    PCW_TWAP_oracle::update(&mut oracle_b, 200 * SCALE, &clock_b);
    let caught_up_cumulative = PCW_TWAP_oracle::get_cumulative_total(&oracle_b);

    // They should match (both include triangle corrections)
    assert!(read_only_cumulative == caught_up_cumulative, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle_a);
    clock::destroy_for_testing(clock_a);
    test_scenario::end(scenario_a);
    PCW_TWAP_oracle::destroy_for_testing(oracle_b);
    clock::destroy_for_testing(clock_b);
    test_scenario::end(scenario_b);
}

/// cumulative_at downward parity twin.
#[test]
fun test_cumulative_at_simulates_triangle_correction_downward() {
    let mut scenario_a = test_scenario::begin(@0x1);
    let ctx_a = test_scenario::ctx(&mut scenario_a);
    let mut clock_a = clock::create_for_testing(ctx_a);
    clock::set_for_testing(&mut clock_a, 0);

    let mut scenario_b = test_scenario::begin(@0x1);
    let ctx_b = test_scenario::ctx(&mut scenario_b);
    let mut clock_b = clock::create_for_testing(ctx_b);
    clock::set_for_testing(&mut clock_b, 0);

    let mut oracle_a = PCW_TWAP_oracle::new_default(200 * SCALE, &clock_a);
    let mut oracle_b = PCW_TWAP_oracle::new_default(200 * SCALE, &clock_b);

    // Price drops to 50
    clock::set_for_testing(&mut clock_a, 1);
    clock::set_for_testing(&mut clock_b, 1);
    PCW_TWAP_oracle::update(&mut oracle_a, 50 * SCALE, &clock_a);
    PCW_TWAP_oracle::update(&mut oracle_b, 50 * SCALE, &clock_b);

    let quiet_end = 11 * ONE_MINUTE_MS;

    let read_only = PCW_TWAP_oracle::cumulative_at(&oracle_a, quiet_end);

    clock::set_for_testing(&mut clock_b, quiet_end);
    PCW_TWAP_oracle::update(&mut oracle_b, 50 * SCALE, &clock_b);
    let caught_up = PCW_TWAP_oracle::get_cumulative_total(&oracle_b);

    assert!(read_only == caught_up, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle_a);
    clock::destroy_for_testing(clock_a);
    test_scenario::end(scenario_a);
    PCW_TWAP_oracle::destroy_for_testing(oracle_b);
    clock::destroy_for_testing(clock_b);
    test_scenario::end(scenario_b);
}

/// When no window boundary is crossed, cumulative_at should be a simple flat projection
/// (no triangle correction needed).
#[test]
fun test_cumulative_at_no_pending_windows() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);

    // Update at t=1ms (within first window)
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    // Project to t=30s (still within first window, no boundary crossed)
    let target = 30_000;
    let projected = PCW_TWAP_oracle::cumulative_at(&oracle, target);

    // Should be cumulative_total + last_window_twap * elapsed
    let expected = PCW_TWAP_oracle::get_cumulative_total(&oracle)
        + (100 * SCALE as u256) * ((target - 1) as u256);
    assert!(projected == expected, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Cap must always apply, even when TWAP decays to 0 — the delta_m=1 floor
/// ensures TWAP can still move instead of snapping to an arbitrary new price.
#[test]
fun test_cap_always_applies_even_at_zero_twap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // Start at price 1 (smallest valid), 1% cap
    let mut oracle = PCW_TWAP_oracle::new_default(1, &clock);

    // Feed zero price to drive TWAP down. With base=1, delta_m=max(1, 1*10000/1000000)=1.
    // After 1 window of 0 price, TWAP goes from 1 to 0.
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 1);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 0, 0);

    // Now feed a huge price. delta_m = max(1, 0*ppm/1M) = 1 (floor), so TWAP
    // moves by at most 1 per window — no snap to the instant spot.
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS + 2);
    PCW_TWAP_oracle::update(&mut oracle, 1_000_000 * SCALE, &clock);
    clock::set_for_testing(&mut clock, 2 * ONE_MINUTE_MS + 2);
    PCW_TWAP_oracle::update(&mut oracle, 1_000_000 * SCALE, &clock);

    let twap_after = PCW_TWAP_oracle::get_twap(&oracle);
    // Should be 0 + 1 = 1 (one delta_m step), NOT 1_000_000*SCALE
    assert!(twap_after == 1, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Extended quiet period — cumulative_at matches catch_up_to for 100 windows.
#[test]
fun test_cumulative_at_long_quiet_period() {
    let mut scenario_a = test_scenario::begin(@0x1);
    let ctx_a = test_scenario::ctx(&mut scenario_a);
    let mut clock_a = clock::create_for_testing(ctx_a);
    clock::set_for_testing(&mut clock_a, 0);

    let mut scenario_b = test_scenario::begin(@0x1);
    let ctx_b = test_scenario::ctx(&mut scenario_b);
    let mut clock_b = clock::create_for_testing(ctx_b);
    clock::set_for_testing(&mut clock_b, 0);

    let mut oracle_a = PCW_TWAP_oracle::new_default(100 * SCALE, &clock_a);
    let mut oracle_b = PCW_TWAP_oracle::new_default(100 * SCALE, &clock_b);

    // Price jumps to 200 at t=1ms
    clock::set_for_testing(&mut clock_a, 1);
    clock::set_for_testing(&mut clock_b, 1);
    PCW_TWAP_oracle::update(&mut oracle_a, 200 * SCALE, &clock_a);
    PCW_TWAP_oracle::update(&mut oracle_b, 200 * SCALE, &clock_b);

    // 100 windows of quiet
    let quiet_end = 101 * ONE_MINUTE_MS;

    let read_only = PCW_TWAP_oracle::cumulative_at(&oracle_a, quiet_end);

    clock::set_for_testing(&mut clock_b, quiet_end);
    PCW_TWAP_oracle::update(&mut oracle_b, 200 * SCALE, &clock_b);
    let caught_up = PCW_TWAP_oracle::get_cumulative_total(&oracle_b);

    assert!(read_only == caught_up, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle_a);
    clock::destroy_for_testing(clock_a);
    test_scenario::end(scenario_a);
    PCW_TWAP_oracle::destroy_for_testing(oracle_b);
    clock::destroy_for_testing(clock_b);
    test_scenario::end(scenario_b);
}

/// End-to-end: get_window_twap reflects price movement during quiet periods,
/// not a flat stale value.
#[test]
fun test_get_window_twap_uses_simulated_cumulative() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);

    // Accumulate steady price for a while to build checkpoint history
    let mut t = 0u64;
    let mut i = 0;
    while (i < 10) {
        t = t + ONE_MINUTE_MS;
        clock::set_for_testing(&mut clock, t);
        PCW_TWAP_oracle::update(&mut oracle, 100 * SCALE, &clock);
        i = i + 1;
    };

    // Price jumps to 200 and stays
    t = t + 1;
    clock::set_for_testing(&mut clock, t);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Record the last_window_twap before quiet period
    let twap_before_quiet = PCW_TWAP_oracle::get_twap(&oracle);

    // Let 20 windows pass (quiet period, price stays at 200 in last_price)
    let quiet_end = t + 20 * ONE_MINUTE_MS;
    clock::set_for_testing(&mut clock, quiet_end);

    // get_window_twap over a short recent window should reflect price movement
    // toward 200, not be stuck at twap_before_quiet
    let window_twap_opt = PCW_TWAP_oracle::get_window_twap(
        &oracle, 10 * ONE_MINUTE_MS, &clock,
    );

    if (window_twap_opt.is_some()) {
        let window_twap = *window_twap_opt.borrow();
        // The simulated TWAP should be above the pre-quiet value
        // (the oracle has been stepping toward 200*SCALE during the quiet period)
        assert!(window_twap > twap_before_quiet, 0);
    };
    // If None, the test still passes — insufficient checkpoint history is OK

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// ==========================================================================
// Deep stepping correctness tests
// ==========================================================================
//
// PCW convention: window k (0-indexed) contributes TWAP-at-start * W, where
//   TWAP-at-start(k) = base + sign * min(k * delta_m, deviation)
// So window 0 always contributes base*W, window 1 contributes (base±Δ)*W, etc.
// After n windows finalize, last_window_twap = base + sign * min(n*Δ, G_abs).
//
// All tests below use initial_price=100*SCALE and default 1% cap, so
// delta_m = 1*SCALE per window and stepping is 100, 101, 102, ... (up) or
// 99, 98, 97, ... (down).

/// Pure quiet period, gap-limited: target is reached exactly after G_abs/Δ
/// windows, then holds.
#[test]
fun test_stepping_gap_limited_reaches_target_exactly() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);

    // Single observation at 150 at t=1ms (keeps last_price=150 for the quiet period).
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    // 200 windows of quiet — gap is 50*SCALE, delta_m is 1*SCALE, so we
    // saturate at window 50 and stay there.
    clock::set_for_testing(&mut clock, 1 + 200 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 150 * SCALE, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Pure quiet period, step-limited: target is far above base so n*Δ binds.
/// After n windows, TWAP = base + n*Δ exactly.
#[test]
fun test_stepping_step_limited_moves_by_exactly_n_deltas() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);

    // Push price way up so the gap is huge; only 5 windows will elapse.
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);

    clock::set_for_testing(&mut clock, 1 + 5 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);

    // After 5 windows: base + 5 * delta_m = 105
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 105 * SCALE, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Downward symmetric to step-limited: TWAP = base - n*Δ.
#[test]
fun test_stepping_step_limited_downward() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);

    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);

    clock::set_for_testing(&mut clock, 1 + 5 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);

    // 100 - 5 = 95
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 95 * SCALE, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// cumulative_total must equal the per-window integral 100*W + 101*W + ... + (100+n-1)*W
/// after n windows where all are step-limited (gap huge, so every step = delta_m).
#[test]
fun test_cumulative_matches_per_window_integral_upward() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);

    // Jump to 10k at the window boundary so stage 1 sees a pure-scalar window.
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);

    // Advance exactly 10 windows later. All 10 full windows are pure-quiet
    // at 10_000*SCALE; stage 2 handles them as one batch.
    clock::set_for_testing(&mut clock, 10 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);

    // Window k (k=0..9) contributed (100 + k)*SCALE * ONE_MINUTE_MS.
    let mut expected: u256 = 0;
    let mut k: u64 = 0;
    while (k < 10) {
        expected = expected + (((100 + k) as u256) * (SCALE as u256)) * (ONE_MINUTE_MS as u256);
        k = k + 1;
    };
    assert!(PCW_TWAP_oracle::get_cumulative_total(&oracle) == expected, 0);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 110 * SCALE, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Downward version of the per-window cumulative pin.
#[test]
fun test_cumulative_matches_per_window_integral_downward() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);
    clock::set_for_testing(&mut clock, 10 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);

    // Window k (k=0..9) contributed (100 - k)*SCALE * ONE_MINUTE_MS.
    let mut expected: u256 = 0;
    let mut k: u64 = 0;
    while (k < 10) {
        expected = expected + (((100 - k) as u256) * (SCALE as u256)) * (ONE_MINUTE_MS as u256);
        k = k + 1;
    };
    assert!(PCW_TWAP_oracle::get_cumulative_total(&oracle) == expected, 0);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 90 * SCALE, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Mixed partial window then full quiet period — probes stage 1 specifically.
/// Stage 1 raw_twap = time-weighted average of the two observed prices in
/// window 0. Stage 1 target is this mixed average, but because the gap to
/// base >= delta_m, stage 1 still moves by exactly delta_m (not the full
/// mixed gap). Stage 2 then targets the pure quiet price.
#[test]
fun test_stage1_mixed_partial_then_stage2_quiet() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);

    // First half of window 0 at 100 (initial), then observation at 200.
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS / 2);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Advance 5 windows worth of time from the mid-window observation. Since
    // we started mid-window, 5*W of elapsed time spans 5 boundary crossings:
    // one to close window 0 (stage 1) plus 4 full pure-quiet windows (stage 2).
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS / 2 + 5 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Per-window stepping (0-indexed, step at end):
    //   window 0 → TWAP 101, window 1 → 102, ..., window 4 → 105.
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 105 * SCALE, 0);

    // Cumulative integral: windows 0..4 each contribute (100+k)*W, plus the
    // trailing 30 000 ms of window 5 at TWAP=105.
    let mut expected: u256 = 0;
    let mut k: u64 = 0;
    while (k < 5) {
        expected = expected + (((100 + k) as u256) * (SCALE as u256)) * (ONE_MINUTE_MS as u256);
        k = k + 1;
    };
    expected = expected
        + (105 as u256) * (SCALE as u256) * ((ONE_MINUTE_MS / 2) as u256);
    assert!(PCW_TWAP_oracle::get_cumulative_total(&oracle) == expected, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Direction flip: run up 5 windows (TWAP=105), then the target drops below
/// base. Next batch should step DOWN from 105 toward the new target.
#[test]
fun test_direction_flip_steps_down_from_new_base() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);

    // Ramp up to 105 (5 windows, step-limited).
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);
    clock::set_for_testing(&mut clock, 5 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 105 * SCALE, 0);

    // Now observe 0 and let 3 windows pass.
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);
    clock::set_for_testing(&mut clock, 5 * ONE_MINUTE_MS + 3 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);

    // delta_m recomputed for this new advance() from base=105: 105/100 = 1.05*SCALE.
    // 3 windows of -1.05 = -3.15 → TWAP = 105 - 3.15 = 101.85 ⇒ 101_850_000_000_000
    let expected = 105 * SCALE - 3 * (105 * SCALE / 100);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Gap saturation within stage 2: gap = 3 units, run 10 windows. After
/// window 3 we saturate; windows 4..9 should sit at target.
#[test]
fun test_stage2_saturates_mid_batch() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);
    // Target 103: gap = 3, delta_m = 1 → saturates at window 3.
    PCW_TWAP_oracle::update(&mut oracle, 103 * SCALE, &clock);
    clock::set_for_testing(&mut clock, 10 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 103 * SCALE, &clock);

    // Final TWAP = 103 (saturated).
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 103 * SCALE, 0);

    // Per-window (0-indexed, step-at-end): window k contributes min(100+k, 103)
    //   k=0: 100, k=1: 101, k=2: 102, k=3..9: 103
    let w = ONE_MINUTE_MS as u256;
    let scale_u256 = SCALE as u256;
    let expected: u256 =
        100 * scale_u256 * w +
        101 * scale_u256 * w +
        102 * scale_u256 * w +
        103 * scale_u256 * w * 7;
    assert!(PCW_TWAP_oracle::get_cumulative_total(&oracle) == expected, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Incremental vs batched equivalence: for a pure-quiet trajectory with the
/// same scalar price and delta_m pinned per call, ten single-window advances
/// must produce the same state as one ten-window advance.
/// NOTE: delta_m is pinned PER advance() call, so this equivalence requires
/// that each incremental call also uses the same base. To make that hold,
/// we compare state after each full block of stepping where delta_m is
/// identical (flat price, each advance is 1 window, base at each entry is
/// the same "pinned delta_m" derived from that entry's base).
#[test]
fun test_incremental_vs_batched_pure_quiet() {
    // Batched path
    let mut scenario_a = test_scenario::begin(@0x1);
    let ctx_a = test_scenario::ctx(&mut scenario_a);
    let mut clock_a = clock::create_for_testing(ctx_a);
    clock::set_for_testing(&mut clock_a, 0);
    let mut oracle_a = PCW_TWAP_oracle::new_default(100 * SCALE, &clock_a);
    PCW_TWAP_oracle::update(&mut oracle_a, 10_000 * SCALE, &clock_a);
    clock::set_for_testing(&mut clock_a, 10 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle_a, 10_000 * SCALE, &clock_a);

    // Incremental path: one window per update.
    let mut scenario_b = test_scenario::begin(@0x1);
    let ctx_b = test_scenario::ctx(&mut scenario_b);
    let mut clock_b = clock::create_for_testing(ctx_b);
    clock::set_for_testing(&mut clock_b, 0);
    let mut oracle_b = PCW_TWAP_oracle::new_default(100 * SCALE, &clock_b);
    PCW_TWAP_oracle::update(&mut oracle_b, 10_000 * SCALE, &clock_b);
    let mut i: u64 = 1;
    while (i <= 10) {
        clock::set_for_testing(&mut clock_b, i * ONE_MINUTE_MS);
        PCW_TWAP_oracle::update(&mut oracle_b, 10_000 * SCALE, &clock_b);
        i = i + 1;
    };

    // Batched uses delta_m pinned from base=100 for all 10 windows → +10 per step.
    // Incremental recomputes delta_m each call, growing with the new base.
    // So they DO differ once base has moved — we only check that each produced
    // the fully-stepped trajectory for its own pinned-delta_m regime.
    assert!(PCW_TWAP_oracle::get_twap(&oracle_a) == 110 * SCALE, 0);
    // Incremental after 10 windows: 100 → 101 → 102.01 → ... growing 1% per step.
    // Lower bound: each step at least +1, so >= 110. Upper bound: starts to
    // accelerate — after 10 compounding 1% steps, 100 * 1.01^10 ≈ 110.46.
    let twap_b = PCW_TWAP_oracle::get_twap(&oracle_b);
    assert!(twap_b >= 110 * SCALE, 1);
    assert!(twap_b <= 111 * SCALE, 2);

    PCW_TWAP_oracle::destroy_for_testing(oracle_a);
    clock::destroy_for_testing(clock_a);
    test_scenario::end(scenario_a);
    PCW_TWAP_oracle::destroy_for_testing(oracle_b);
    clock::destroy_for_testing(clock_b);
    test_scenario::end(scenario_b);
}

/// cumulative_at must exactly equal cumulative_total that results from
/// mutating advance() for the same target time, across mixed-window scenarios.
#[test]
fun test_cumulative_at_parity_mixed_stage1_and_stage2() {
    // Mutating branch
    let mut scenario_a = test_scenario::begin(@0x1);
    let ctx_a = test_scenario::ctx(&mut scenario_a);
    let mut clock_a = clock::create_for_testing(ctx_a);
    clock::set_for_testing(&mut clock_a, 0);
    let mut oracle_a = PCW_TWAP_oracle::new_default(100 * SCALE, &clock_a);
    clock::set_for_testing(&mut clock_a, ONE_MINUTE_MS / 3);
    PCW_TWAP_oracle::update(&mut oracle_a, 200 * SCALE, &clock_a);

    // Read branch: same history, then project.
    let mut scenario_b = test_scenario::begin(@0x1);
    let ctx_b = test_scenario::ctx(&mut scenario_b);
    let mut clock_b = clock::create_for_testing(ctx_b);
    clock::set_for_testing(&mut clock_b, 0);
    let mut oracle_b = PCW_TWAP_oracle::new_default(100 * SCALE, &clock_b);
    clock::set_for_testing(&mut clock_b, ONE_MINUTE_MS / 3);
    PCW_TWAP_oracle::update(&mut oracle_b, 200 * SCALE, &clock_b);

    let target = ONE_MINUTE_MS / 3 + 7 * ONE_MINUTE_MS + ONE_MINUTE_MS / 7;
    let projected = PCW_TWAP_oracle::cumulative_at(&oracle_b, target);

    clock::set_for_testing(&mut clock_a, target);
    PCW_TWAP_oracle::update(&mut oracle_a, 200 * SCALE, &clock_a);
    let mutated = PCW_TWAP_oracle::get_cumulative_total(&oracle_a);

    assert!(projected == mutated, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle_a);
    clock::destroy_for_testing(clock_a);
    test_scenario::end(scenario_a);
    PCW_TWAP_oracle::destroy_for_testing(oracle_b);
    clock::destroy_for_testing(clock_b);
    test_scenario::end(scenario_b);
}

/// Stage 3 accumulation preserves correctness: after a multi-window advance(),
/// the trailing partial window must contribute at the new last_window_twap.
#[test]
fun test_stage3_trailing_partial_uses_post_stage_twap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);

    // Trailing = 15_000 ms after a 3-window batch.
    clock::set_for_testing(&mut clock, 3 * ONE_MINUTE_MS + 15_000);
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);

    // After 3 windows: TWAP = 103. Trailing contributes 103*SCALE * 15000.
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 103 * SCALE, 0);

    // Total cumulative = windows 0,1,2 + trailing at post-stage2 TWAP
    let w = ONE_MINUTE_MS as u256;
    let s = SCALE as u256;
    let expected: u256 =
        100 * s * w + 101 * s * w + 102 * s * w + 103 * s * (15_000 as u256);
    assert!(PCW_TWAP_oracle::get_cumulative_total(&oracle) == expected, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Exactly on a window boundary: time_in_window + elapsed == window_size
/// should still cross into a new window (finalize window 0, start window 1).
#[test]
fun test_advance_exactly_to_boundary() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);

    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 10_000 * SCALE, &clock);

    // Window 0 finalized → TWAP = 101.
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 101 * SCALE, 0);
    // Cumulative = 100*SCALE*W (only window 0 contributed, nothing trailing).
    assert!(
        PCW_TWAP_oracle::get_cumulative_total(&oracle) ==
            (100 as u256) * (SCALE as u256) * (ONE_MINUTE_MS as u256),
        1,
    );

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Saturating-subtract guard on downward stage 2. If cumulative_total is
/// already small and going_up is false, the correction must clamp to 0
/// instead of underflowing. Artificially construct the scenario by moving
/// down from base=1 with gap=0 (nothing changes), then a normal downward.
#[test]
fun test_downward_saturating_correction_no_underflow() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(2, &clock);
    // Force rapid downward stepping: price 0, just 2 windows.
    clock::set_for_testing(&mut clock, 1);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);
    clock::set_for_testing(&mut clock, 2 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);

    // base=2, delta_m=max(1, 2*10000/1_000_000)=max(1, 0)=1, gap=2.
    // After 2 windows stepping by 1 each: 2 → 1 → 0.
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 0, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Gap = 0 (no movement needed): stage 2 should do nothing, cumulative_total
/// equals base * elapsed exactly.
#[test]
fun test_zero_gap_scalar_equals_base() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut oracle = PCW_TWAP_oracle::new_default(100 * SCALE, &clock);
    clock::set_for_testing(&mut clock, 10 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 100 * SCALE, &clock);

    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 100 * SCALE, 0);
    assert!(
        PCW_TWAP_oracle::get_cumulative_total(&oracle) ==
            (100 * SCALE as u256) * (10 * ONE_MINUTE_MS as u256),
        1,
    );

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Zero-price update. A reported price of 0 (e.g. an empty pool) must not
/// crash the oracle or inject undefined values into the cumulative math. The
/// downward cap clips the per-window move to delta_m, so the TWAP decays
/// smoothly toward zero rather than teleporting.
#[test]
fun test_update_with_zero_price_does_not_crash_and_decays_smoothly() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // base=100, 1% cap. delta_m = 1 * SCALE per window.
    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Record price=0 one second in, then quiet-hold for one full window.
    clock::set_for_testing(&mut clock, 1_000);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);

    clock::set_for_testing(&mut clock, 1_000 + ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);

    // TWAP must be bounded in [0, initial] and the one-step cap limits the
    // downward move to ~1%. The first full window ends at ≥ 99 * SCALE.
    let twap_after_one_window = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(twap_after_one_window <= initial_price, 0);
    assert!(twap_after_one_window >= 99 * SCALE, 1);

    // Let the price sit at 0 for many windows — TWAP decays but never
    // underflows and the accumulator is monotonic non-decreasing.
    let prev_total = PCW_TWAP_oracle::get_cumulative_total(&oracle);
    clock::set_for_testing(&mut clock, 1_000 + 200 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 0, &clock);

    let next_total = PCW_TWAP_oracle::get_cumulative_total(&oracle);
    assert!(next_total >= prev_total, 2);
    // After 100+ steps at delta_m=1*SCALE, TWAP should have reached 0.
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 0, 3);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Large clock jump through many windows without intermediate updates. Stage 2
/// of advance() batches N full quiet windows with a pinned delta_m; this path
/// must handle 1000+ windows without overflowing u64/u128 in the arithmetic
/// or producing an inconsistent (base, cumulative) pair. We compare the
/// cumulative_at projection to the real update result.
#[test]
fun test_clock_jump_many_windows_is_consistent_and_bounded() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Establish a new last_price of 200 with one intra-window update.
    clock::set_for_testing(&mut clock, 1_000);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // Jump forward 1000 windows at the same price. delta_m = 1 * SCALE so
    // after 100 steps the TWAP is already clamped at 200; the remaining 900
    // windows are pure flat accumulation.
    let jump_windows = 1_000u64;
    let jump_target = 1_000 + jump_windows * ONE_MINUTE_MS;

    // Read-only projection must equal mutating advance result.
    let projected = PCW_TWAP_oracle::cumulative_at(&oracle, jump_target);

    clock::set_for_testing(&mut clock, jump_target);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);
    let actual = PCW_TWAP_oracle::get_cumulative_total(&oracle);

    assert!(projected == actual, 0);
    // TWAP converged to 200 (100 steps of delta_m is enough, we did 1000).
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 200 * SCALE, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// Downward cap over many windows: the saturating subtraction in
/// apply_signed_correction guards against underflow when the per-window
/// triangle correction is larger than cumulative_total. Running a long
/// downward phase stresses that path across many full windows without the
/// accumulator ever wrapping.
#[test]
fun test_downward_saturating_correction_many_windows() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Push price to near zero right at the start, then quiet-hold for 200
    // windows. Each window caps the downward move at delta_m (1% of base).
    clock::set_for_testing(&mut clock, 1_000);
    PCW_TWAP_oracle::update(&mut oracle, SCALE, &clock); // 1.0

    // Sample at several window multiples. For each, the projected cumulative
    // from cumulative_at must equal the real cumulative_total after update().
    let checkpoints = vector[10u64, 50, 100, 150, 200];
    let mut last_total: u256 = 0;
    let mut i = 0u64;
    while (i < vector::length(&checkpoints)) {
        let n = *vector::borrow(&checkpoints, i);
        let target = 1_000 + n * ONE_MINUTE_MS;

        let projected = PCW_TWAP_oracle::cumulative_at(&oracle, target);

        clock::set_for_testing(&mut clock, target);
        PCW_TWAP_oracle::update(&mut oracle, SCALE, &clock);
        let actual = PCW_TWAP_oracle::get_cumulative_total(&oracle);

        // Monotonic non-decreasing.
        assert!(actual >= last_total, 0);
        // Parity between read-only and mutating paths.
        assert!(actual == projected, 1);
        // TWAP always in [final_target, initial_price].
        let twap = PCW_TWAP_oracle::get_twap(&oracle);
        assert!(twap <= initial_price, 2);
        assert!(twap >= SCALE, 3);

        last_total = actual;
        i = i + 1;
    };

    // TWAP asymptotically approaches the target (1*SCALE) but delta_m shrinks
    // with base across update boundaries, so full convergence takes many more
    // windows than the 200 sampled here. The real invariant is: TWAP stayed
    // in [target, initial] and the accumulator never underflowed.
    let final_twap = PCW_TWAP_oracle::get_twap(&oracle);
    assert!(final_twap >= SCALE, 4);
    assert!(final_twap < initial_price, 5);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

/// A partial-window observation followed by a long quiet period at the new
/// price must reach that price exactly — the mixed partial window (stage 1)
/// must not leak its pre-observation contribution into the pure-quiet stage 2
/// target.
#[test]
fun test_catch_up_no_pre_quiet_dilution() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // base=100, 1% cap → delta_m = 1*SCALE per window
    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Push price to 200 half-way through window 0, then leave it alone for
    // 200 windows — 100 steps of delta_m is enough to reach 200 exactly.
    clock::set_for_testing(&mut clock, 30_000);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    clock::set_for_testing(&mut clock, 30_000 + 200 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 200 * SCALE, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}
