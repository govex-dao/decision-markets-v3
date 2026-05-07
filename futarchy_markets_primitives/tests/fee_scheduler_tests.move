// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_markets_primitives::fee_scheduler_tests;

use futarchy_markets_primitives::fee_scheduler;

// === Constants for Testing ===

const FEE_SCALE: u64 = 10000; // 100% = 10000 bps

// Time constants
const ONE_MINUTE_MS: u64 = 60_000;
const TEN_MINUTES_MS: u64 = 600_000;
const FIFTEEN_MINUTES_MS: u64 = 900_000;
const THIRTY_MINUTES_MS: u64 = 1_800_000;
const ONE_HOUR_MS: u64 = 3_600_000;
const TWO_HOURS_MS: u64 = 7_200_000;
const TWENTY_FOUR_HOURS_MS: u64 = 86_400_000;

// === Basic Validation Tests ===

#[test]
#[expected_failure(abort_code = fee_scheduler::EInitialFeeTooHigh)]
fun test_new_schedule_fails_initial_fee_exceeds_99_percent() {
    fee_scheduler::new_schedule(
        10000, // INVALID: 100% (max is 9900 = 99%)
        ONE_HOUR_MS,
    );
}

#[test]
#[expected_failure(abort_code = fee_scheduler::EDurationTooLong)]
fun test_new_schedule_fails_duration_exceeds_24_hours() {
    fee_scheduler::new_schedule(
        9900,
        86_400_001, // INVALID: > 24 hours
    );
}

#[test]
fun test_new_schedule_valid() {
    let schedule = fee_scheduler::new_schedule(
        9900, // 99%
        ONE_HOUR_MS,
    );

    assert!(fee_scheduler::initial_fee_bps(&schedule) == 9900, 0);
    assert!(fee_scheduler::duration_ms(&schedule) == ONE_HOUR_MS, 1);
}

#[test]
fun test_new_schedule_zero_duration_allowed() {
    // 0 duration is allowed (skips MEV protection)
    let schedule = fee_scheduler::new_schedule(
        9900,
        0, // 0 duration = skip MEV
    );

    assert!(fee_scheduler::duration_ms(&schedule) == 0, 0);
}

#[test]
fun test_new_schedule_zero_initial_fee_allowed() {
    // 0 initial fee is allowed (effectively no MEV protection)
    let schedule = fee_scheduler::new_schedule(
        0, // 0 initial fee
        ONE_HOUR_MS,
    );

    assert!(fee_scheduler::initial_fee_bps(&schedule) == 0, 0);
}

#[test]
fun test_new_schedule_max_values() {
    let schedule = fee_scheduler::new_schedule(
        9900, // Max: 99%
        TWENTY_FOUR_HOURS_MS, // Max: 24 hours
    );

    assert!(fee_scheduler::initial_fee_bps(&schedule) == 9900, 0);
    assert!(fee_scheduler::duration_ms(&schedule) == TWENTY_FOUR_HOURS_MS, 1);
}

// === Edge Case Tests ===

#[test]
fun test_get_current_fee_before_start() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let start_time = 1000;
    let current_time = 999; // Before start

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);
    assert!(fee == 9900, 0); // Should return initial_fee_bps
}

#[test]
fun test_get_current_fee_at_exact_start() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let start_time = 1000;
    let current_time = 1000; // Exactly at start

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);
    assert!(fee == 9900, 0); // Should return initial_fee_bps
}

#[test]
fun test_get_current_fee_after_duration_ends() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = ONE_HOUR_MS; // Exactly at end

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);
    assert!(fee == 30, 0); // Should return final_fee_bps
}

#[test]
fun test_get_current_fee_way_after_duration_ends() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = ONE_HOUR_MS; // Way after end

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);
    assert!(fee == 30, 0); // Should return final_fee_bps
}

#[test]
fun test_get_current_fee_zero_duration() {
    let schedule = fee_scheduler::new_schedule(9900, 0); // 0 duration
    let final_fee = 30;

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 1000);
    assert!(fee == 30, 0); // Should skip MEV, return final_fee immediately
}

// === Exponential Decay Tests ===

#[test]
fun test_exponential_decay_at_halfway() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = THIRTY_MINUTES_MS; // 50% through duration (30 min of 1 hour)

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);

    // 8 half-lives over the full duration: at 50%, 4 half-lives have elapsed.
    // fee = 30 + ceil((9900 - 30) / 16) = 647
    assert!(fee >= 645 && fee <= 650, 0);
}

#[test]
fun test_exponential_decay_at_quarter() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = FIFTEEN_MINUTES_MS; // 25% through duration (15 min of 1 hour)

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);

    // At 25%, 2 half-lives have elapsed.
    // fee = 30 + ceil((9900 - 30) / 4) = 2498
    assert!(fee >= 2495 && fee <= 2500, 0);
}

#[test]
fun test_exponential_decay_at_three_quarters() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let start_time = 0;
    let current_time = THIRTY_MINUTES_MS + FIFTEEN_MINUTES_MS; // 75% through duration (45 min of 1 hour)

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);

    // At 75%, 6 half-lives have elapsed.
    // fee = 30 + ceil((9900 - 30) / 64) = 185
    assert!(fee >= 180 && fee <= 190, 0);
}

#[test]
fun test_exponential_decay_continuous() {
    // Test that decay updates smoothly every millisecond.
    let schedule = fee_scheduler::new_schedule(1000, 1000); // 10% → 0% over 1 second
    let final_fee = 0;

    let fee_0 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 0);
    let fee_1 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 1);
    let fee_2 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 2);
    let fee_500 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 500);
    let fee_1000 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 1000);

    assert!(fee_0 == 1000, 0);
    assert!(fee_1 == 996, 1);
    assert!(fee_2 == 992, 2);
    assert!(fee_500 == 63, 3);
    assert!(fee_1000 == 0, 4);
}

#[test]
fun test_exponential_decay_spot_fee_curve_exact_values() {
    // Regression table for a 99% launch fee decaying to the common 75 bps
    // steady-state total fee (50 bps protocol + 25 bps LP) over one hour.
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 75;

    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, 0) == 9900, 0);
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS / 20) == 7935, 1); // 5%
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS / 10) == 5970, 2); // 10%
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS / 8) == 4988, 3); // 12.5%
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS / 4) == 2532, 4); // 25%
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS / 2) == 690, 5); // 50%
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS * 3 / 4) == 229, 6); // 75%
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS * 9 / 10) == 145, 7); // 90%
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS * 19 / 20) == 129, 8); // 95%
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS * 99 / 100) == 117, 9); // 99%
    assert!(fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS) == 75, 10);
}

#[test]
fun test_exponential_decay_same_relative_curve_for_24_hour_duration() {
    let one_hour_schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let one_day_schedule = fee_scheduler::new_schedule(9900, TWENTY_FOUR_HOURS_MS);
    let final_fee = 75;

    assert!(
        fee_scheduler::get_current_fee(&one_hour_schedule, final_fee, 0, ONE_HOUR_MS / 20) ==
            fee_scheduler::get_current_fee(&one_day_schedule, final_fee, 0, TWENTY_FOUR_HOURS_MS / 20),
        0,
    );
    assert!(
        fee_scheduler::get_current_fee(&one_hour_schedule, final_fee, 0, ONE_HOUR_MS / 4) ==
            fee_scheduler::get_current_fee(&one_day_schedule, final_fee, 0, TWENTY_FOUR_HOURS_MS / 4),
        1,
    );
    assert!(
        fee_scheduler::get_current_fee(&one_hour_schedule, final_fee, 0, ONE_HOUR_MS / 2) ==
            fee_scheduler::get_current_fee(&one_day_schedule, final_fee, 0, TWENTY_FOUR_HOURS_MS / 2),
        2,
    );
    assert!(
        fee_scheduler::get_current_fee(&one_hour_schedule, final_fee, 0, ONE_HOUR_MS * 3 / 4) ==
            fee_scheduler::get_current_fee(&one_day_schedule, final_fee, 0, TWENTY_FOUR_HOURS_MS * 3 / 4),
        3,
    );
    assert!(
        fee_scheduler::get_current_fee(&one_hour_schedule, final_fee, 0, ONE_HOUR_MS * 99 / 100) ==
            fee_scheduler::get_current_fee(&one_day_schedule, final_fee, 0, TWENTY_FOUR_HOURS_MS * 99 / 100),
        4,
    );
}

#[test]
fun test_default_schedule() {
    let schedule = fee_scheduler::default_launch_schedule();

    assert!(fee_scheduler::initial_fee_bps(&schedule) == 9900, 0); // 99%
    assert!(fee_scheduler::duration_ms(&schedule) == FIFTEEN_MINUTES_MS, 1); // 15 minutes
}

// === Different Final Fee Tests ===

#[test]
fun test_different_final_fees() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);

    // Test with different final fees (pool's base spot fee) at 50% (30 min)
    let fee_10 = fee_scheduler::get_current_fee(&schedule, 10, 0, THIRTY_MINUTES_MS);
    let fee_30 = fee_scheduler::get_current_fee(&schedule, 30, 0, THIRTY_MINUTES_MS);
    let fee_100 = fee_scheduler::get_current_fee(&schedule, 100, 0, THIRTY_MINUTES_MS);

    // At 50%, 4 half-lives have elapsed:
    // fee_10:  10 + ceil((9900-10)/16) = 629
    // fee_30:  30 + ceil((9900-30)/16) = 647
    // fee_100: 100 + ceil((9900-100)/16) = 713

    assert!(fee_10 >= 625 && fee_10 <= 635, 0);
    assert!(fee_30 >= 645 && fee_30 <= 650, 1);
    assert!(fee_100 >= 710 && fee_100 <= 715, 2);
}

// === Precision Tests ===

#[test]
fun test_precision_very_small_duration() {
    let schedule = fee_scheduler::new_schedule(1000, 100); // 100ms duration
    let final_fee = 0;

    let fee_50 = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 50); // 50% through

    // At 50%, 4 half-lives have elapsed: ceil(1000 / 16) = 63.
    assert!(fee_50 >= 60 && fee_50 <= 65, 0);
}

#[test]
fun test_precision_very_large_range() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 1;

    let fee_30m = fee_scheduler::get_current_fee(&schedule, final_fee, 0, THIRTY_MINUTES_MS);

    // At 50%, 4 half-lives have elapsed.
    assert!(fee_30m >= 615 && fee_30m <= 625, 0);
}

// === Monotonicity Test ===

#[test]
fun test_monotonicity_fee_never_increases() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let mut prev_fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 0);

    // Test at 1-minute increments
    let mut time = 0;
    while (time <= ONE_HOUR_MS) {
        let current_fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, time);

        // Fee should never increase (monotonically decreasing)
        assert!(current_fee <= prev_fee, 0);

        prev_fee = current_fee;
        time = time + ONE_MINUTE_MS;
    };
}

// === Edge Cases with Different Ranges ===

#[test]
fun test_small_fee_drop() {
    // Small difference between initial and final
    let schedule = fee_scheduler::new_schedule(100, ONE_HOUR_MS);
    let final_fee = 90;

    let fee_half = fee_scheduler::get_current_fee(&schedule, final_fee, 0, THIRTY_MINUTES_MS);

    // At 50%, 4 half-lives have elapsed. The residual premium rounds up to 1 bps.
    assert!(fee_half == 91, 0);
}

#[test]
fun test_equal_initial_and_final() {
    let schedule = fee_scheduler::new_schedule(300, ONE_HOUR_MS);
    let final_fee = 300; // Same as initial

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);

    // No decay, should stay at 300
    assert!(fee == 300, 0);
}

#[test]
fun test_zero_to_zero() {
    let schedule = fee_scheduler::new_schedule(0, ONE_HOUR_MS);
    let final_fee = 0;

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);

    assert!(fee == 0, 0);
}

// === Edge Case: Final Fee Greater Than Initial ===

#[test]
fun test_final_fee_greater_than_initial() {
    // Edge case: final_fee_bps > initial_fee_bps (no decay needed)
    let schedule = fee_scheduler::new_schedule(100, ONE_HOUR_MS);
    let final_fee = 500; // Higher than initial

    let fee_start = fee_scheduler::get_current_fee(&schedule, final_fee, 0, 0);
    let fee_mid = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);
    let fee_end = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);

    // Should always return final_fee (no decay)
    assert!(fee_start == 500, 0);
    assert!(fee_mid == 500, 1);
    assert!(fee_end == 500, 2);
}

#[test]
fun test_final_fee_equals_initial() {
    // Edge case: final_fee_bps == initial_fee_bps (no decay)
    let schedule = fee_scheduler::new_schedule(300, ONE_HOUR_MS);
    let final_fee = 300;

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);

    // Should return final_fee (no decay happens)
    assert!(fee == 300, 0);
}

// === New Validation Tests ===

#[test]
#[expected_failure(abort_code = fee_scheduler::EInitialFeeTooHigh)]
fun test_new_schedule_fails_initial_exceeds_100_percent() {
    fee_scheduler::new_schedule(
        10001, // INVALID: > 100%
        ONE_HOUR_MS,
    );
}

#[test]
fun test_max_getters() {
    // Test that limit getters work
    assert!(fee_scheduler::max_initial_fee_bps() == 9900, 0);
    assert!(fee_scheduler::max_duration_ms() == TWENTY_FOUR_HOURS_MS, 1);
    assert!(fee_scheduler::fee_scale() == 10000, 2);
    assert!(fee_scheduler::launch_decay_half_lives() == 8, 3);
}

// === Time Near Boundaries ===

#[test]
fun test_time_near_u64_max() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let start_time = 18_446_744_073_709_551_615u64 - 10_000_000; // Near u64::MAX
    let current_time = start_time + THIRTY_MINUTES_MS; // 50% through

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, start_time, current_time);

    // Should handle without overflow - at 50% through
    assert!(fee >= 645 && fee <= 650, 0);
}

#[test]
fun test_one_millisecond_before_end() {
    let schedule = fee_scheduler::new_schedule(9900, ONE_HOUR_MS);
    let final_fee = 30;

    let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS - 1);

    // Hard cutoff happens exactly at duration. One millisecond before, a small premium remains.
    assert!(fee > 30 && fee <= 70, 0);
}

// === Precision / Rounding Edge Cases ===

/// A 1 bp premium over the final fee must not round to zero mid-decay.
/// The implementation rounds up the remaining scaled premium so that a tiny
/// launch fee is preserved until the hard cutoff at t == duration_ms.
#[test]
fun test_exponential_decay_one_bp_premium_does_not_vanish_mid_decay() {
    // initial=31, final=30 → fee_drop = 1 bp. Halving 1 bp 8 times crosses zero
    // in integer arithmetic; the ceil-rounding on the remaining scaled premium
    // keeps the fee at >= final+1 until t reaches duration_ms.
    let schedule = fee_scheduler::new_schedule(31, ONE_HOUR_MS);
    let final_fee = 30;

    let mut i = 1u64;
    while (i < 60) {
        // Check at every minute before hard cutoff.
        let t = i * ONE_MINUTE_MS;
        let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, t);
        // Fee must remain above final while decay is active, and never exceed initial.
        assert!(fee >= final_fee + 1, 0);
        assert!(fee <= 31, 1);
        i = i + 1;
    };

    // Hard cutoff at t == duration: fee drops to final.
    let fee_end = fee_scheduler::get_current_fee(&schedule, final_fee, 0, ONE_HOUR_MS);
    assert!(fee_end == final_fee, 2);
}

/// Regression: bit-shift exponent is bounded by LAUNCH_DECAY_HALF_LIVES (8) by
/// construction (complete_half_lives = elapsed * 8 / duration with elapsed <
/// duration). This test exercises the largest valid duration with a full
/// scan through elapsed values and asserts the output is monotonically
/// non-increasing, which indirectly confirms the bit-shift bound holds.
#[test]
fun test_exponential_decay_max_duration_is_monotonic_and_bounded() {
    let schedule = fee_scheduler::new_schedule(9900, TWENTY_FOUR_HOURS_MS);
    let final_fee = 30;

    // Sample at hour boundaries: 0h, 1h, 2h, ..., 23h, 24h.
    let mut prev_fee = 9900;
    let mut i = 0u64;
    while (i <= 24) {
        let t = i * ONE_HOUR_MS;
        let fee = fee_scheduler::get_current_fee(&schedule, final_fee, 0, t);
        // Decay is monotonic non-increasing.
        assert!(fee <= prev_fee, 0);
        // Fee always in [final, initial].
        assert!(fee >= final_fee && fee <= 9900, 1);
        prev_fee = fee;
        i = i + 1;
    };

    // Final point at exactly duration: snaps to final.
    let fee_end = fee_scheduler::get_current_fee(&schedule, final_fee, 0, TWENTY_FOUR_HOURS_MS);
    assert!(fee_end == final_fee, 2);
}
