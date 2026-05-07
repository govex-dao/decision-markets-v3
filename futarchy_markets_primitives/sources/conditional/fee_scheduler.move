// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Fee scheduling module for dynamic AMM fees.
/// Supports exponential launch-fee decay from high launch fees (99%) to standard spot fees.
/// After the decay period ends, the pool uses the final_fee_bps as the permanent spot fee.
module futarchy_markets_primitives::fee_scheduler;

use futarchy_one_shot_utils::constants;

// === Errors ===
const EInitialFeeTooHigh: u64 = 0;
const EDurationTooLong: u64 = 1;
/// Number of half-lives compressed into one configured launch duration.
/// A 15 minute schedule therefore halves roughly every 1.875 minutes.
const LAUNCH_DECAY_HALF_LIVES: u64 = 8;

// === Structs ===

/// Fee schedule configuration for exponential decay from high launch fee to spot fee.
/// Final fee comes from the pool's base spot_amm_fee_bps (set in pool, not here).
public struct FeeSchedule has copy, drop, store {
    /// Initial MEV protection fee in basis points (0-9900, e.g., 9900 = 99%)
    initial_fee_bps: u64,
    /// Total duration of fee decay in milliseconds (0-86400000 = 0-24 hours)
    /// If 0, MEV protection is skipped (use base pool fee immediately)
    duration_ms: u64,
}

// === Public Functions ===

/// Create a new fee schedule with exponential decay.
///
/// Schedules exponential decay from high initial MEV fee (0-99%) to the pool's base spot fee.
/// After the decay period ends, the pool permanently uses its base spot_amm_fee_bps.
///
/// # Parameters
/// - initial_fee_bps: Initial MEV protection fee (0-9900 bps = 0%-99%)
/// - duration_ms: Duration of decay period (0-86400000 ms = 0-24 hours)
///
/// # Constraints
/// - initial_fee_bps must be <= 9900 (99% maximum - DAO policy)
/// - duration_ms must be <= 86_400_000 (24 hours maximum)
/// - If duration_ms is 0, MEV protection is skipped entirely
/// - If initial_fee_bps is 0, effectively no MEV protection
///
/// # Decay Formula
/// The remaining fee premium halves LAUNCH_DECAY_HALF_LIVES times over duration_ms.
/// The implementation uses deterministic piecewise-linear interpolation between
/// half-life anchor points and snaps to final_fee_bps at t >= duration_ms.
public fun new_schedule(initial_fee_bps: u64, duration_ms: u64): FeeSchedule {
    // Validate parameters (99% max is DAO policy, also ensures < 100%)
    assert!(initial_fee_bps <= constants::max_launch_fee_bps(), EInitialFeeTooHigh);
    assert!(duration_ms <= constants::one_day_ms(), EDurationTooLong);

    FeeSchedule {
        initial_fee_bps,
        duration_ms,
    }
}

/// Calculate current fee based on elapsed time and pool's base fee.
/// Uses exponential decay with a hard cutoff at duration_ms.
///
/// # Edge cases (hard-coded):
/// - t = 0: return initial_fee_bps (max MEV protection)
/// - t >= duration: return final_fee_bps (spot fee)
/// - duration = 0: skip MEV, always return final_fee_bps
///
/// # Exponential decay (0 < t < duration):
/// - N = LAUNCH_DECAY_HALF_LIVES
/// - Exact at each half-life anchor
/// - Piecewise-linear between anchors for deterministic integer math
/// - Guaranteed to reach final_fee exactly at duration end
public fun get_current_fee(
    schedule: &FeeSchedule,
    final_fee_bps: u64,
    start_time: u64,
    current_time: u64,
): u64 {
    // Edge case: duration = 0, skip MEV protection
    if (schedule.duration_ms == 0) {
        return final_fee_bps
    };

    // Edge case: if final fee >= initial fee, no decay needed
    if (final_fee_bps >= schedule.initial_fee_bps) {
        return final_fee_bps
    };

    // Edge case: before start, return initial fee (max protection)
    if (current_time <= start_time) {
        return schedule.initial_fee_bps
    };

    let elapsed = current_time - start_time;

    // Edge case: after duration ends, return final fee (spot fee)
    if (elapsed >= schedule.duration_ms) {
        return final_fee_bps
    };

    let fee_drop = schedule.initial_fee_bps - final_fee_bps;
    let precision = constants::fee_precision_scale();

    // Exponential half-life interpolation:
    // scaled_position maps elapsed time to [0, LAUNCH_DECAY_HALF_LIVES).
    let scaled_position = (elapsed as u128) * (LAUNCH_DECAY_HALF_LIVES as u128);
    let complete_half_lives = scaled_position / (schedule.duration_ms as u128);
    let half_life_remainder = scaled_position % (schedule.duration_ms as u128);

    let fee_drop_scaled = (fee_drop as u128) * precision;
    let fee_at_step = fee_drop_scaled >> (complete_half_lives as u8);
    let fee_at_next = fee_drop_scaled >> ((complete_half_lives + 1) as u8);
    let step_drop = fee_at_step - fee_at_next;
    let interpolated_drop = step_drop * half_life_remainder / (schedule.duration_ms as u128);
    let remaining_fee_scaled = fee_at_step - interpolated_drop;

    // Round up so a tiny remaining premium does not disappear before the hard cutoff.
    let remaining_fee_bps = ((remaining_fee_scaled + precision - 1) / precision) as u64;
    let current_fee = final_fee_bps + remaining_fee_bps;

    // Clamp defensively for unusual final_fee inputs and integer rounding.
    if (current_fee > schedule.initial_fee_bps) { schedule.initial_fee_bps } else { current_fee }
}

/// Create default launch protection schedule: 99% -> spot fee over 15 minutes.
public fun default_launch_schedule(): FeeSchedule {
    FeeSchedule {
        initial_fee_bps: constants::max_launch_fee_bps(), // 99% MEV protection fee
        duration_ms: constants::fifteen_minutes_ms(), // 15 minutes
    }
}

// === Getters ===

public fun initial_fee_bps(schedule: &FeeSchedule): u64 {
    schedule.initial_fee_bps
}

public fun duration_ms(schedule: &FeeSchedule): u64 {
    schedule.duration_ms
}

/// Get maximum allowed initial fee (DAO policy)
public fun max_initial_fee_bps(): u64 {
    constants::max_launch_fee_bps()
}

/// Get maximum allowed duration
public fun max_duration_ms(): u64 {
    constants::one_day_ms()
}

/// Get fee scale (100% in basis points)
public fun fee_scale(): u64 {
    constants::total_fee_bps()
}

/// Get the number of half-lives used over one launch-fee duration.
public fun launch_decay_half_lives(): u64 {
    LAUNCH_DECAY_HALF_LIVES
}

// === Test Helpers ===

#[test_only]
public fun new_schedule_for_testing(initial: u64, duration: u64): FeeSchedule {
    new_schedule(initial, duration)
}
