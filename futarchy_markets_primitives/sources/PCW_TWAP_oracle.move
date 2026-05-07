// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// ============================================================================
/// PERCENT-CAPPED WINDOWED TWAP ORACLE
/// ============================================================================
///
/// PURPOSE: Provide manipulation-resistant TWAP for oracle grants
///
/// KEY FEATURES:
/// - Fixed-size windows (1 minute default)
/// - TWAP movement capped as % of current window's TWAP
/// - O(1) gas - just arithmetic, no loops or exponentiation
/// - Cap recalculates between batches (grows with TWAP)
///
/// MANIPULATION RESISTANCE:
/// - Attacker spikes price $100 → $200 for 10 minutes
/// - Cap calculated ONCE: 1% of $100 = $1 per window
/// - Take 10 steps of $1 each (ARITHMETIC within batch)
/// - Result: $100 + ($1 × 10) = $110
/// - Next batch: Cap recalculates as 1% of $110 = $1.10
///
/// GAS EFFICIENCY:
/// - O(1) constant time - just multiplication and min()
/// - No loops, no binary search, no exponentiation
/// - Example: 10 missed windows = same cost as 1 window
/// - 10x+ faster than geometric approach with binary search
///
/// SECURITY PROPERTY:
/// - Cap grows with TWAP (percentage-based)
/// - Allows legitimate price movements over time
/// - Still prevents instant manipulation
/// - Example: $100 → $200 instant = capped to $101
/// - Example: $100 → $200 over 100 windows = reaches $200
///
/// USED BY:
/// - Oracle grants: get_twap() → capped 1-minute windowed TWAP
/// - External consumers: Choose based on use case
///
/// ============================================================================

module futarchy_markets_primitives::PCW_TWAP_oracle;

use futarchy_one_shot_utils::constants;
use sui::clock::Clock;
use sui::event;

// ============================================================================
// Errors
// ============================================================================

const EOverflow: u64 = 0;
const EInvalidConfig: u64 = 1;
const ETimestampRegression: u64 = 2;
const ENotInitialized: u64 = 3;
const EInvalidProjection: u64 = 4;

// ============================================================================
// Structs
// ============================================================================

/// Long-horizon checkpoint stored roughly once per week
public struct Checkpoint has copy, drop, store {
    timestamp: u64,
    cumulative: u256,
}

/// Simple TWAP with O(1) arithmetic percentage capping
public struct SimpleTWAP has store {
    /// Last finalized window's TWAP (returned by get_twap())
    last_window_twap: u128,
    /// Cumulative price * time for current (incomplete) window
    cumulative_price: u256,
    /// Start of current window (ms)
    window_start: u64,
    /// Last update timestamp (ms)
    last_update: u64,
    /// Window size (default: 1 minute)
    window_size_ms: u64,
    /// Maximum movement per window in PPM (default: 1% = 10,000 PPM)
    max_movement_ppm: u64,
    /// Whether at least one window has been finalized (TWAP is valid)
    initialized: bool,
    /// Capped cumulative price × time since initialization (for long-horizon TWAPs).
    /// Accumulates last_window_twap (capped) rather than raw spot price so that
    /// get_window_twap / get_ninety_day_twap inherit per-window manipulation resistance.
    cumulative_total: u256,
    /// Last observed spot price (used for projection and backfill)
    last_price: u128,
    /// Oracle initialization timestamp
    initialized_at: u64,
    /// Rolling checkpoints used to approximate long windows
    checkpoints: vector<Checkpoint>,
    /// Timestamp of the most recent checkpoint
    last_checkpoint_at: u64,
}

// ============================================================================
// Events
// ============================================================================

public struct WindowFinalized has copy, drop {
    timestamp: u64,
    raw_twap: u128,
    capped_twap: u128,
    num_windows: u64,
}

// ============================================================================
// Creation
// ============================================================================

/// Create TWAP oracle with default 1-minute windows and 1% cap
public fun new_default(initial_price: u128, clock: &Clock): SimpleTWAP {
    new(initial_price, constants::twap_price_cap_window(), constants::default_twap_max_movement_ppm(), clock)
}

/// Create TWAP oracle with custom configuration.
/// initial_price must be > 0 — oracle needs a valid anchor price for cap math.
/// Callers should compute the initial price from pool reserves before creating.
public fun new(
    initial_price: u128,
    window_size_ms: u64,
    max_movement_ppm: u64,
    clock: &Clock,
): SimpleTWAP {
    assert!(initial_price > 0, EInvalidConfig);
    assert!(window_size_ms > 0, EInvalidConfig);
    assert!(max_movement_ppm > 0 && max_movement_ppm < constants::ppm_denominator(), EInvalidConfig);

    let now = clock.timestamp_ms();

    let mut oracle = SimpleTWAP {
        last_window_twap: initial_price,
        cumulative_price: 0,
        window_start: now,
        last_update: now,
        window_size_ms,
        max_movement_ppm,
        initialized: true,
        cumulative_total: 0,
        last_price: initial_price,
        initialized_at: now,
        checkpoints: vector::empty(),
        last_checkpoint_at: now,
    };

    record_checkpoint(&mut oracle, now);

    oracle
}

// ============================================================================
// Core Update Logic
// ============================================================================

/// Update the oracle with a new price observation at the current clock time.
///
/// The interval [last_update, now] is treated as constant at the existing
/// last_price (left-Riemann: the new price only affects the accumulator from
/// `now` forward). Any completed windows are finalized via advance()'s
/// 3-stage decomposition before the new price is recorded.
///
/// SECURITY: `public` because it is called cross-package from
/// `futarchy_markets_core::unified_spot_pool`. Safe today because
/// `&mut SimpleTWAP` is only reachable via internal pool fields — no public
/// getter exposes it. Never expose `&mut SimpleTWAP` publicly.
public fun update(oracle: &mut SimpleTWAP, price: u128, clock: &Clock) {
    let now = clock.timestamp_ms();
    assert!(now >= oracle.last_update, ETimestampRegression);

    if (now == oracle.last_update) {
        oracle.last_price = price;
        return
    };

    let prev_price = oracle.last_price;
    advance(oracle, now, prev_price);
    oracle.last_price = price;
    maybe_commit_checkpoint(oracle, now);
}

/// Advance oracle state to `now`, treating [last_update, now] as constant at
/// `scalar_price`. Mirrors `futarchy_twap_oracle::twap_accumulate`'s 3-stage
/// decomposition so that each call to the PCW cap has a well-defined scalar
/// target (no averaging across regimes):
///
///   Stage 1: close the current partial window using its own accumulated
///            observations. Target = that window's raw average; one-step cap.
///   Stage 2: any remaining full windows are pure-quiet at `scalar_price`.
///            Target = `scalar_price`; N-step batched cap (same closed-form
///            ramp formula as multi_full_window_accumulation).
///   Stage 3: trailing partial window at `scalar_price` becomes the new
///            `cumulative_price` for the next call.
fun advance(oracle: &mut SimpleTWAP, now: u64, scalar_price: u128) {
    let window_size = oracle.window_size_ms;
    let time_in_window = oracle.last_update - oracle.window_start;
    let elapsed = now - oracle.last_update;

    // No boundary crossed: accumulate into the open window.
    if (time_in_window + elapsed < window_size) {
        oracle.cumulative_price = oracle.cumulative_price
            + (scalar_price as u256) * (elapsed as u256);
        oracle.cumulative_total = oracle.cumulative_total
            + (oracle.last_window_twap as u256) * (elapsed as u256);
        oracle.last_update = now;
        return
    };

    // PCW invariant: delta_m is pinned for this entire advance() call
    // ("cap calculated ONCE per batch"). Computed from the base at entry so
    // stage 1 and stage 2 step by the same fixed amount per window.
    let delta_m = compute_delta_m(oracle.last_window_twap, oracle.max_movement_ppm);

    // --- Stage 1: close the current partial window ---
    let time_to_boundary = window_size - time_in_window;
    oracle.cumulative_price = oracle.cumulative_price
        + (scalar_price as u256) * (time_to_boundary as u256);
    oracle.cumulative_total = oracle.cumulative_total
        + (oracle.last_window_twap as u256) * (time_to_boundary as u256);

    let raw_u256 = oracle.cumulative_price / (window_size as u256);
    let stage1_target = if (raw_u256 > (std::u128::max_value!() as u256)) {
        std::u128::max_value!()
    } else {
        raw_u256 as u128
    };
    apply_pcw_cap(oracle, stage1_target, 1, delta_m);
    oracle.cumulative_price = 0;
    oracle.last_update = oracle.last_update + time_to_boundary;

    // --- Stage 2: full pure-scalar windows ---
    let time_after_stage1 = now - oracle.last_update;
    let full_windows = time_after_stage1 / window_size;
    if (full_windows > 0) {
        // Pre-accumulate base * N * W; apply_pcw_cap adds the triangle correction.
        oracle.cumulative_total = oracle.cumulative_total
            + (oracle.last_window_twap as u256)
              * ((full_windows as u256) * (window_size as u256));
        apply_pcw_cap(oracle, scalar_price, full_windows, delta_m);
        oracle.last_update = oracle.last_update + full_windows * window_size;
    };

    // --- Stage 3: trailing partial window at scalar_price ---
    let trailing = now - oracle.last_update;
    if (trailing > 0) {
        oracle.cumulative_price = (scalar_price as u256) * (trailing as u256);
        oracle.cumulative_total = oracle.cumulative_total
            + (oracle.last_window_twap as u256) * (trailing as u256);
        oracle.last_update = now;
    };
}

fun compute_delta_m(base: u128, max_movement_ppm: u64): u128 {
    let delta_m_u256 =
        (base as u256) * (max_movement_ppm as u256) / (constants::ppm_denominator() as u256);
    assert!(delta_m_u256 <= (std::u128::max_value!() as u256), EOverflow);
    std::u128::max(1, (delta_m_u256 as u128))
}

/// Apply the PCW cap over `n` windows toward a single scalar `target`,
/// using the caller-provided `delta_m` (pinned across the whole advance()
/// call — the spec's "cap calculated once per batch" invariant).
///
/// Moves `last_window_twap` by `min(n * delta_m, |target - base|)` in the
/// direction of `target`, advances `window_start`, applies the triangle
/// correction to `cumulative_total`, and emits `WindowFinalized`.
///
/// Pre-condition: the caller has already added `base * n * window_size_ms`
/// to `cumulative_total` for this batch. This function only adds the
/// triangle delta on top (so the final contribution equals the true
/// stepped-TWAP integral over the n windows).
fun apply_pcw_cap(oracle: &mut SimpleTWAP, target: u128, n: u64, delta_m: u128) {
    let base = oracle.last_window_twap;
    let w = oracle.window_size_ms;

    let g_abs: u128;
    let going_up: bool;
    if (target > base) {
        g_abs = target - base;
        going_up = true;
    } else {
        g_abs = base - target;
        going_up = false;
    };

    // deviation = min(n * delta_m, g_abs)
    let nw_times_delta_m: u128 = {
        let prod = (delta_m as u256) * (n as u256);
        if (prod > (std::u128::max_value!() as u256)) {
            std::u128::max_value!()
        } else {
            prod as u128
        }
    };
    let deviation = std::u128::min(nw_times_delta_m, g_abs);
    let capped_twap = if (going_up) { base + deviation } else { base - deviation };

    // Triangle correction for cumulative_total.
    // Window k ∈ [0, n-1] has TWAP-at-start = base + sign * min(k*delta_m, deviation).
    // Caller already accumulated base * n * w, so the correction is
    //   sign * w * sum_{k=0}^{n-1} min(k*delta_m, deviation)
    //   = sign * w * (s_ramp + s_flat)
    // with K = min(floor(deviation/delta_m), n-1).
    if (deviation > 0 && n > 0) {
        let k_u256 = (deviation as u256) / (delta_m as u256);
        let k: u64 = if (k_u256 >= ((n - 1) as u256)) { n - 1 } else { k_u256 as u64 };
        let s_ramp = (delta_m as u256) * (k as u256) * ((k + 1) as u256) / 2;
        let s_flat = if (n > k + 1) { (deviation as u256) * ((n - 1 - k) as u256) } else { 0 };
        let s = s_ramp + s_flat;
        let correction = (w as u256) * s;

        if (going_up) {
            oracle.cumulative_total = oracle.cumulative_total + correction;
        } else if (oracle.cumulative_total >= correction) {
            oracle.cumulative_total = oracle.cumulative_total - correction;
        } else {
            oracle.cumulative_total = 0;
        };
    };

    let new_window_start = oracle.window_start + n * w;
    event::emit(WindowFinalized {
        timestamp: new_window_start,
        raw_twap: target,
        capped_twap,
        num_windows: n,
    });

    oracle.last_window_twap = capped_twap;
    oracle.window_start = new_window_start;
}

// ============================================================================
// View Functions
// ============================================================================

/// Get current TWAP (last finalized window's capped TWAP)
///
/// NOTE: Oracle is initialized with valid TWAP from:
/// - Spot AMM: Initial pool ratio (e.g., reserve1/reserve0)
/// - Conditional AMM: Spot's TWAP at proposal creation time
///
/// This is O(1) - just returns a stored value
public fun get_twap(oracle: &SimpleTWAP): u128 {
    assert!(oracle.initialized, ENotInitialized);
    oracle.last_window_twap
}

/// Check if oracle has at least one full window of observations
public fun is_ready(oracle: &SimpleTWAP, clock: &Clock): bool {
    if (!oracle.initialized) {
        return false
    };
    let now = clock.timestamp_ms();
    if (now <= oracle.initialized_at) {
        return false
    };
    let elapsed = now - oracle.initialized_at;
    elapsed >= oracle.window_size_ms
}

/// Get window configuration
public fun window_size_ms(oracle: &SimpleTWAP): u64 {
    oracle.window_size_ms
}

/// Get max movement in PPM
public fun max_movement_ppm(oracle: &SimpleTWAP): u64 {
    oracle.max_movement_ppm
}

/// Get last observed price
public fun last_price(oracle: &SimpleTWAP): u128 {
    oracle.last_price
}

/// Get last update timestamp
public fun last_update(oracle: &SimpleTWAP): u64 {
    oracle.last_update
}

/// Get oracle initialization timestamp
public fun initialized_at(oracle: &SimpleTWAP): u64 {
    oracle.initialized_at
}

/// Capped cumulative price × time since initialization (uses last_window_twap, not raw spot)
public fun cumulative_total(oracle: &SimpleTWAP): u256 {
    oracle.cumulative_total
}

/// Compute cumulative capped-price × time at `target_timestamp` (must be >= last_update).
/// Read-only simulation of `catch_up_to(target_timestamp)` — produces the same
/// `cumulative_total` the mutating path would land on, including the stage-1
/// partial-window closure and stage-2 batched quiet-window cap.
public fun cumulative_at(oracle: &SimpleTWAP, target_timestamp: u64): u256 {
    assert!(target_timestamp >= oracle.last_update, EInvalidProjection);
    let elapsed = target_timestamp - oracle.last_update;
    if (elapsed == 0) {
        return oracle.cumulative_total
    };

    let window_size = oracle.window_size_ms;
    let time_in_window = oracle.last_update - oracle.window_start;
    let scalar_price = oracle.last_price;

    // No boundary crossed — flat projection.
    if (time_in_window + elapsed < window_size) {
        return oracle.cumulative_total
            + (oracle.last_window_twap as u256) * (elapsed as u256)
    };

    let mut projected = oracle.cumulative_total;
    let mut base = oracle.last_window_twap;

    // Pin delta_m for the whole simulation, matching advance().
    let delta_m = compute_delta_m(base, oracle.max_movement_ppm);

    // --- Stage 1: close the partial window ---
    let time_to_boundary = window_size - time_in_window;
    let stage1_cum_price = oracle.cumulative_price
        + (scalar_price as u256) * (time_to_boundary as u256);
    projected = projected + (base as u256) * (time_to_boundary as u256);

    let raw_u256 = stage1_cum_price / (window_size as u256);
    let stage1_target = if (raw_u256 > (std::u128::max_value!() as u256)) {
        std::u128::max_value!()
    } else {
        raw_u256 as u128
    };
    let (new_base_s1, correction_s1, going_up_s1) =
        simulate_pcw_cap(base, stage1_target, 1, delta_m, window_size);
    projected = apply_signed_correction(projected, correction_s1, going_up_s1);
    base = new_base_s1;

    // --- Stage 2: full pure-scalar windows ---
    let time_after_stage1 = elapsed - time_to_boundary;
    let full_windows = time_after_stage1 / window_size;
    if (full_windows > 0) {
        projected = projected
            + (base as u256) * ((full_windows as u256) * (window_size as u256));
        let (new_base_s2, correction_s2, going_up_s2) =
            simulate_pcw_cap(base, scalar_price, full_windows, delta_m, window_size);
        projected = apply_signed_correction(projected, correction_s2, going_up_s2);
        base = new_base_s2;
    };

    // --- Stage 3: trailing partial window ---
    let trailing = time_after_stage1 - full_windows * window_size;
    if (trailing > 0) {
        projected = projected + (base as u256) * (trailing as u256);
    };

    projected
}

/// Read-only twin of `apply_pcw_cap`. Returns `(new_base, correction_magnitude, going_up)`.
/// Takes pinned `delta_m` from the surrounding simulation (same invariant as advance()).
fun simulate_pcw_cap(
    base: u128,
    target: u128,
    n: u64,
    delta_m: u128,
    window_size: u64,
): (u128, u256, bool) {
    let g_abs: u128;
    let going_up: bool;
    if (target > base) {
        g_abs = target - base;
        going_up = true;
    } else {
        g_abs = base - target;
        going_up = false;
    };

    let nw_times_delta_m: u128 = {
        let prod = (delta_m as u256) * (n as u256);
        if (prod > (std::u128::max_value!() as u256)) {
            std::u128::max_value!()
        } else {
            prod as u128
        }
    };
    let deviation = std::u128::min(nw_times_delta_m, g_abs);
    let new_base = if (going_up) { base + deviation } else { base - deviation };

    let correction: u256 = if (deviation > 0 && n > 0) {
        let k_u256 = (deviation as u256) / (delta_m as u256);
        let k: u64 = if (k_u256 >= ((n - 1) as u256)) { n - 1 } else { k_u256 as u64 };
        let s_ramp = (delta_m as u256) * (k as u256) * ((k + 1) as u256) / 2;
        let s_flat = if (n > k + 1) { (deviation as u256) * ((n - 1 - k) as u256) } else { 0 };
        (window_size as u256) * (s_ramp + s_flat)
    } else {
        0
    };

    (new_base, correction, going_up)
}

fun apply_signed_correction(projected: u256, correction: u256, going_up: bool): u256 {
    if (correction == 0) {
        projected
    } else if (going_up) {
        projected + correction
    } else if (projected >= correction) {
        projected - correction
    } else {
        0
    }
}

/// Attempt to commit a long-window checkpoint if interval elapsed
public fun try_commit_checkpoint(oracle: &mut SimpleTWAP, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    if (now >= oracle.last_checkpoint_at + constants::one_week_ms()) {
        catch_up_to(oracle, now);
        record_checkpoint(oracle, now);
        true
    } else {
        false
    }
}

/// Get long-window TWAP using checkpoints.
/// Returns None if not enough history (no checkpoint older than window_ms).
///
/// This is a heuristic oracle — best used over 90-day windows where
/// interpolation error is diluted across ~13 weekly checkpoints. Do not
/// assume sub-1% precision; for trending markets with sparse checkpoints
/// the error on a single checkpoint span can be several percent (for very
/// volatile tokens), though
/// it shrinks proportionally with longer windows.
///
/// Interpolates between checkpoints to estimate the cumulative value at
/// `target = now - window_ms`. The accuracy depends on checkpoint density:
/// when window_ms is much larger than the checkpoint interval (weekly), the
/// result closely approximates the true windowed average. When window_ms is
/// close to or smaller than the checkpoint interval, the interpolation
/// degrades toward the average over the full checkpoint span.
/// Callers must ensure window_ms >= checkpoint interval for meaningful results
/// (enforced by oracle_init_actions: twap_window_ms >= one_week_ms).
public fun get_window_twap(
    oracle: &SimpleTWAP,
    window_ms: u64,
    clock: &Clock,
): option::Option<u128> {
    let now = clock.timestamp_ms();
    if (now <= window_ms) {
        return option::none()
    };

    let target = now - window_ms;
    let len = vector::length(&oracle.checkpoints);
    if (len == 0) {
        return option::none()
    };

    // Find the latest checkpoint at or before `target`
    let mut idx_opt = option::none();
    let mut i = len;
    while (i > 0) {
        i = i - 1;
        let cp = vector::borrow(&oracle.checkpoints, i);
        if (cp.timestamp <= target) {
            idx_opt = option::some(i);
            break
        };
    };

    if (option::is_none(&idx_opt)) {
        return option::none()
    };

    let idx = option::destroy_some(idx_opt);
    let cp_before = vector::borrow(&oracle.checkpoints, idx);

    // If the checkpoint is exactly at target, no interpolation needed
    let target_cumulative = if (cp_before.timestamp == target) {
        cp_before.cumulative
    } else {
        // Interpolate: find the next reference point after target.
        // This is either the next checkpoint (idx+1) or the current projected
        // cumulative at `now`. Linear interpolation between two cumulative
        // integral values gives us the correct estimate assuming the capped
        // TWAP was roughly constant between checkpoints (which it is by
        // design -- the per-window cap limits how fast it can move).
        let (after_ts, after_cum) = if (idx + 1 < len) {
            let cp_after = vector::borrow(&oracle.checkpoints, idx + 1);
            (cp_after.timestamp, cp_after.cumulative)
        } else {
            // No later checkpoint; use projected current cumulative
            (now, cumulative_at(oracle, now))
        };

        let span = after_ts - cp_before.timestamp; // > 0 because cp_before.timestamp < target <= after_ts
        let offset = target - cp_before.timestamp;
        let cum_diff = after_cum - cp_before.cumulative;

        // interpolated = cp_before.cumulative + cum_diff * offset / span
        cp_before.cumulative + cum_diff * (offset as u256) / (span as u256)
    };

    if (window_ms == 0) {
        return option::none()
    };

    let current_cumulative = cumulative_at(oracle, now);
    if (current_cumulative < target_cumulative) {
        // Should not happen, but guard against underflow
        return option::none()
    };
    let diff = current_cumulative - target_cumulative;
    let avg_u256 = diff / (window_ms as u256);
    assert!(avg_u256 <= (std::u128::max_value!() as u256), EOverflow);

    option::some(avg_u256 as u128)
}

/// Convenience wrapper for 90-day TWAP (returns None if insufficient history)
public fun get_ninety_day_twap(oracle: &SimpleTWAP, clock: &Clock): option::Option<u128> {
    get_window_twap(oracle, constants::ninety_days_ms(), clock)
}

/// Find checkpoint at or before target timestamp.
/// Returns None if no checkpoint exists before target.
public fun checkpoint_at_or_before(
    oracle: &SimpleTWAP,
    target_timestamp: u64,
): option::Option<Checkpoint> {
    let len = vector::length(&oracle.checkpoints);
    if (len == 0) {
        return option::none()
    };

    let mut i = len;
    while (i > 0) {
        i = i - 1;
        let cp = vector::borrow(&oracle.checkpoints, i);
        if (cp.timestamp <= target_timestamp) {
            return option::some(*cp)
        };
    };

    option::none()
}

// ============================================================================
// Internal Helpers
// ============================================================================

fun maybe_commit_checkpoint(oracle: &mut SimpleTWAP, now: u64) {
    if (now >= oracle.last_checkpoint_at + constants::one_week_ms()) {
        record_checkpoint(oracle, now);
    }
}

/// Advance oracle state to `now` using the last observed price (no new observation).
/// Reuses the same 3-stage logic as update() so that a silent checkpoint commit
/// produces byte-identical cumulative_total to an equivalent update() at `now`.
fun catch_up_to(oracle: &mut SimpleTWAP, now: u64) {
    if (now <= oracle.last_update) { return };
    let scalar_price = oracle.last_price;
    advance(oracle, now, scalar_price);
}

fun record_checkpoint(oracle: &mut SimpleTWAP, timestamp: u64) {
    // Project cumulative to the checkpoint timestamp to ensure consistency
    // This handles cases where checkpoint is recorded during quiet periods.
    // Uses last_window_twap (capped) for projection consistency with cumulative_total.
    let cumulative = if (timestamp >= oracle.last_update) {
        let elapsed = timestamp - oracle.last_update;
        oracle.cumulative_total + ((oracle.last_window_twap as u256) * (elapsed as u256))
    } else {
        // Should not happen, but fallback to stored value
        oracle.cumulative_total
    };
    let checkpoint = Checkpoint { timestamp, cumulative };

    if (vector::length(&oracle.checkpoints) >= constants::max_twap_checkpoints()) {
        let _ = vector::remove(&mut oracle.checkpoints, 0);
    };

    vector::push_back(&mut oracle.checkpoints, checkpoint);
    oracle.last_checkpoint_at = timestamp;
}

// ============================================================================
// Test Helpers
// ============================================================================

#[test_only]
public fun destroy_for_testing(oracle: SimpleTWAP) {
    let SimpleTWAP {
        last_window_twap: _,
        cumulative_price: _,
        window_start: _,
        last_update: _,
        window_size_ms: _,
        max_movement_ppm: _,
        initialized: _,
        cumulative_total: _,
        last_price: _,
        initialized_at: _,
        checkpoints: _,
        last_checkpoint_at: _,
    } = oracle;
}

#[test_only]
public fun get_cumulative_price(oracle: &SimpleTWAP): u256 {
    oracle.cumulative_price
}

#[test_only]
public fun get_window_start(oracle: &SimpleTWAP): u64 {
    oracle.window_start
}

#[test_only]
public fun get_last_update(oracle: &SimpleTWAP): u64 {
    oracle.last_update
}

#[test_only]
public fun get_cumulative_total(oracle: &SimpleTWAP): u256 {
    oracle.cumulative_total
}

#[test_only]
public fun get_initialized_at(oracle: &SimpleTWAP): u64 {
    oracle.initialized_at
}
