// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_markets_primitives::market_state;

use futarchy_core::escrow_mutation_auth::EscrowMutationAuth;
use futarchy_core::market_state_mutation_auth::MarketStateMutationAuth;
use futarchy_markets_primitives::conditional_amm::LiquidityPool;
use futarchy_one_shot_utils::constants;
use std::string::String;
use sui::clock::Clock;
use sui::event;
use sui::object;

// === Introduction ===
// This module tracks proposal life cycle and acts as a source of truth for proposal state

// === Errors ===
const ETradingAlreadyStarted: u64 = 0;
const EOutcomeOutOfBounds: u64 = 1;
const EAlreadyFinalized: u64 = 2;
const ETradingAlreadyEnded: u64 = 3;
const ETradingNotEnded: u64 = 4;
const ENotFinalized: u64 = 5;
const ETradingNotStarted: u64 = 6;
const EInvalidDuration: u64 = 7;
// EExecutionWindowNotStarted (8) removed - was unused
const EExecutionWindowAlreadyStarted: u64 = 9;
const EExecutionDeadlinePassed: u64 = 10;
const EExecutionDeadlineNotPassed: u64 = 11;
const ENotInExecutionWindow: u64 = 12;
const EInvalidExecutionWindowDuration: u64 = 13;
const EInvalidTwapVectorLength: u64 = 14;
const EAmmPoolsAlreadySet: u64 = 15;
const EInvalidOutcomeCount: u64 = 16;
const EOutcomeMessagesMismatch: u64 = 17;
const EPoolCountMismatch: u64 = 18;
const EAmmPoolsNotSet: u64 = 19;
const ETradingEndTimeNotReached: u64 = 20;
const ECannotFinalizeInExecutionWindow: u64 = 21;
const EPoolMarketMismatch: u64 = 22;
const ETradingEndTimePassed: u64 = 23;
const EPoolOutcomeMismatch: u64 = 24;
const EStartTimeInFuture: u64 = 25;


// === Structs ===
public struct MarketStatus has copy, drop, store {
    trading_started: bool,
    trading_ended: bool,
    /// True when TWAP measurement is complete and execution window is active
    in_execution_window: bool,
    finalized: bool,
}

public struct MarketState has key, store {
    id: UID,
    /// The ID of the proposal that created this market (for event linking)
    proposal_id: ID,
    dao_id: ID,
    outcome_count: u64,
    outcome_messages: vector<String>,
    // Market infrastructure - AMM pools for price discovery
    amm_pools: Option<vector<LiquidityPool>>,
    // Lifecycle state
    status: MarketStatus,
    winning_outcome: Option<u64>,
    creation_time: u64,
    trading_start: u64,
    trading_end: Option<u64>,
    finalization_time: Option<u64>,
    // Execution window state (for execution-required finalization)
    /// When the execution window expires (configurable between 5 min and 2 hours)
    execution_deadline: Option<u64>,
    /// TWAP values captured when execution window started
    frozen_twaps: Option<vector<u128>>,
    /// What TWAP said should win (before execution check)
    /// This is the "market winner" - the actual winner depends on execution success
    market_winner: Option<u64>,
}

// === Events ===
public struct TradingStartedEvent has copy, drop {
    proposal_id: ID,
    start_time: u64,
}

public struct TradingEndedEvent has copy, drop {
    proposal_id: ID,
    timestamp_ms: u64,
}

public struct MarketStateFinalizedEvent has copy, drop {
    proposal_id: ID,
    winning_outcome: u64,
    timestamp_ms: u64,
}

/// Emitted when the execution window starts (configurable between 5 min and 2 hours)
public struct ExecutionWindowStartedEvent has copy, drop {
    proposal_id: ID,
    market_winner: u64,
    execution_deadline: u64,
    timestamp_ms: u64,
}

/// Emitted when execution timeout occurs and REJECT wins
public struct ExecutionTimeoutEvent has copy, drop {
    proposal_id: ID,
    market_winner: u64, // What TWAP said should win
    actual_winner: u64, // REJECT (0) due to timeout
    timestamp_ms: u64,
}

// === Public Package Functions ===
public fun new(
    proposal_id: ID,
    dao_id: ID,
    outcome_count: u64,
    outcome_messages: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
): MarketState {
    assert!(outcome_count >= constants::min_outcomes(), EInvalidOutcomeCount);
    assert!(outcome_count <= constants::protocol_max_outcomes(), EInvalidOutcomeCount);
    assert!(outcome_messages.length() == outcome_count, EOutcomeMessagesMismatch);

    let timestamp = clock.timestamp_ms();

    MarketState {
        id: object::new(ctx),
        proposal_id,
        dao_id,
        outcome_count,
        outcome_messages,
        amm_pools: option::none(), // Pools added later during market initialization
        status: MarketStatus {
            trading_started: false,
            trading_ended: false,
            in_execution_window: false,
            finalized: false,
        },
        winning_outcome: option::none(),
        creation_time: timestamp,
        trading_start: 0,
        trading_end: option::none(),
        finalization_time: option::none(),
        // Execution window fields (initialized when window starts)
        execution_deadline: option::none(),
        frozen_twaps: option::none(),
        market_winner: option::none(),
    }
}

/// Start trading on the market.
/// SECURITY: Requires MarketStateMutationAuth from an authorized package.
/// Uses the caller-provided trading_start_time as the authoritative start.
/// The timestamp must not be in the future relative to Clock.
public fun start_trading(
    state: &mut MarketState,
    duration_ms: u64,
    trading_start_time: u64,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
) {
    assert!(!state.status.trading_started, ETradingAlreadyStarted);
    assert!(duration_ms > 0 && duration_ms <= constants::max_trading_duration_ms(), EInvalidDuration);
    assert!(clock.timestamp_ms() >= trading_start_time, EStartTimeInFuture);

    let end_time = trading_start_time + duration_ms;

    state.status.trading_started = true;
    state.trading_start = trading_start_time;
    state.trading_end = option::some(end_time);

    event::emit(TradingStartedEvent {
        proposal_id: state.proposal_id,
        start_time: trading_start_time,
    });
}

// === Public Functions ===
public fun assert_trading_active(state: &MarketState) {
    assert!(state.status.trading_started, ETradingNotStarted);
    assert!(!state.status.trading_ended, ETradingAlreadyEnded);
}

/// Assert that swaps are allowed on conditional AMMs.
/// Swaps are allowed during:
/// 1. Normal trading (trading_started && !trading_ended && before scheduled deadline)
/// 2. Execution window (in_execution_window && !finalized && before execution deadline)
///
/// SECURITY: Also checks the scheduled trading_end time against the clock.
/// This prevents post-deadline swaps between the scheduled trading_end and
/// when end_trading_and_start_execution_window is actually called
/// (which sets the trading_ended boolean flag), and blocks swaps after
/// execution timeout while waiting for timeout finalization.
public fun assert_swaps_allowed(state: &MarketState, clock: &Clock) {
    assert!(state.status.trading_started, ETradingNotStarted);
    assert!(!state.status.finalized, EAlreadyFinalized);
    // Allow if either: trading hasn't ended OR we're in execution window
    let trading_active = !state.status.trading_ended;
    let in_execution = state.status.in_execution_window;
    assert!(trading_active || in_execution, ETradingAlreadyEnded);
    // SECURITY: Even if the boolean flag hasn't been set yet, block swaps
    // after the scheduled trading_end time to prevent post-deadline manipulation
    if (trading_active && state.trading_end.is_some()) {
        let end_time = *state.trading_end.borrow();
        assert!(clock.timestamp_ms() < end_time, ETradingEndTimePassed);
    };
    // SECURITY: During execution window, swaps are only valid before deadline.
    if (in_execution) {
        assert!(state.execution_deadline.is_some(), ENotInExecutionWindow);
        let execution_deadline = *state.execution_deadline.borrow();
        assert!(clock.timestamp_ms() < execution_deadline, EExecutionDeadlinePassed);
    };
}

/// Check whether swaps are allowed on conditional AMMs (non-aborting).
/// Mirrors assert_swaps_allowed, but returns false instead of aborting.
public fun are_swaps_allowed(state: &MarketState, clock: &Clock): bool {
    if (!state.status.trading_started) {
        return false
    };
    if (state.status.finalized) {
        return false
    };

    // Allow if either: trading hasn't ended OR we're in execution window
    let trading_active = !state.status.trading_ended;
    let in_execution = state.status.in_execution_window;
    if (!(trading_active || in_execution)) {
        return false
    };

    // SECURITY: Even if the boolean flag hasn't been set yet, block swaps
    // after the scheduled trading_end time to prevent post-deadline manipulation
    if (trading_active && state.trading_end.is_some()) {
        let end_time = *state.trading_end.borrow();
        if (!(clock.timestamp_ms() < end_time)) {
            return false
        };
    };

    // SECURITY: During execution window, swaps are only valid before deadline.
    if (in_execution) {
        if (!state.execution_deadline.is_some()) {
            return false
        };
        let execution_deadline = *state.execution_deadline.borrow();
        if (!(clock.timestamp_ms() < execution_deadline)) {
            return false
        };
    };

    true
}

public fun assert_in_trading_or_pre_trading(state: &MarketState) {
    assert!(!state.status.trading_ended, ETradingAlreadyEnded);
    assert!(!state.status.finalized, EAlreadyFinalized);
}

// === Execution Window Functions ===

/// Start the execution window after TWAP measurement ends.
///
/// This captures the TWAP snapshot and determines the "market winner".
/// The actual winner depends on whether execution succeeds:
/// - If market_winner > 0 (accept) and execution succeeds -> accept wins
/// - If market_winner > 0 (accept) and execution fails/timeout -> REJECT wins
/// - If market_winner == 0 (reject) -> REJECT wins immediately
///
/// Trading continues during the execution window (conditional AMMs remain active).
/// SECURITY: Requires MarketStateMutationAuth from an authorized package.
public fun start_execution_window(
    state: &mut MarketState,
    execution_window_ms: u64,
    frozen_twaps: vector<u128>,
    market_winner: u64,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
) {
    assert!(state.status.trading_started, ETradingNotStarted);
    assert!(!state.status.trading_ended, ETradingAlreadyEnded);
    assert!(!state.status.in_execution_window, EExecutionWindowAlreadyStarted);
    assert!(!state.status.finalized, EAlreadyFinalized);
    assert!(market_winner < state.outcome_count, EOutcomeOutOfBounds);
    // Enforce trading end time if set (defense-in-depth; caller layer also checks)
    if (state.trading_end.is_some()) {
        let end_time = *state.trading_end.borrow();
        assert!(clock.timestamp_ms() >= end_time, ETradingEndTimeNotReached);
    };
    // Bounds check on execution window duration
    assert!(
        execution_window_ms >= constants::min_execution_window_ms() &&
        execution_window_ms <= constants::max_execution_window_ms(),
        EInvalidExecutionWindowDuration,
    );
    // Validate frozen_twaps vector length matches outcome_count
    assert!(frozen_twaps.length() == state.outcome_count, EInvalidTwapVectorLength);

    let timestamp = clock.timestamp_ms();
    let deadline = timestamp + execution_window_ms;

    // Mark trading as ended (TWAP measurement complete)
    state.status.trading_ended = true;
    // Enter execution window
    state.status.in_execution_window = true;

    // Store execution window state
    state.execution_deadline = option::some(deadline);
    state.frozen_twaps = option::some(frozen_twaps);
    state.market_winner = option::some(market_winner);

    // Emit TradingEndedEvent since trading is ending
    event::emit(TradingEndedEvent {
        proposal_id: state.proposal_id,
        timestamp_ms: timestamp,
    });

    event::emit(ExecutionWindowStartedEvent {
        proposal_id: state.proposal_id,
        market_winner,
        execution_deadline: deadline,
        timestamp_ms: timestamp,
    });
}

/// Finalize after successful execution during the execution window.
/// Called when the PTB with all actions completes successfully.
/// The actual winner is the market_winner since execution succeeded.
/// SECURITY: Requires MarketStateMutationAuth from an authorized package.
public fun finalize_from_execution_success(
    state: &mut MarketState,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
) {
    assert!(state.status.in_execution_window, ENotInExecutionWindow);
    assert!(!state.status.finalized, EAlreadyFinalized);

    let timestamp = clock.timestamp_ms();

    // Check we're still within the execution window
    // NOTE: Strict inequality (< deadline) ensures deterministic behavior at boundary:
    // - timestamp < deadline: execution can succeed
    // - timestamp >= deadline: only timeout finalization allowed
    // This is intentional - at exact deadline moment, timeout takes precedence
    assert!(state.execution_deadline.is_some(), ENotInExecutionWindow);
    let deadline = *state.execution_deadline.borrow();
    assert!(timestamp < deadline, EExecutionDeadlinePassed);

    // The actual winner is the market winner since execution succeeded
    assert!(state.market_winner.is_some(), ENotInExecutionWindow);
    let winner = *state.market_winner.borrow();

    state.status.finalized = true;
    state.status.in_execution_window = false;
    state.winning_outcome = option::some(winner);
    state.finalization_time = option::some(timestamp);

    event::emit(MarketStateFinalizedEvent {
        proposal_id: state.proposal_id,
        winning_outcome: winner,
        timestamp_ms: timestamp,
    });
}

/// Finalize with REJECT due to execution timeout.
/// Anyone can call this after the execution deadline passes.
/// The actual winner is REJECT (0) regardless of what TWAP said.
/// SECURITY: Requires MarketStateMutationAuth from an authorized package.
public fun finalize_from_timeout(
    state: &mut MarketState,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
) {
    assert!(state.status.in_execution_window, ENotInExecutionWindow);
    assert!(!state.status.finalized, EAlreadyFinalized);

    let timestamp = clock.timestamp_ms();

    // Check that we're past the execution deadline
    assert!(state.execution_deadline.is_some(), ENotInExecutionWindow);
    let deadline = *state.execution_deadline.borrow();
    assert!(timestamp >= deadline, EExecutionDeadlineNotPassed);

    assert!(state.market_winner.is_some(), ENotInExecutionWindow);
    let market_winner = *state.market_winner.borrow();
    let actual_winner = 0u64; // REJECT wins on timeout

    state.status.finalized = true;
    state.status.in_execution_window = false;
    state.winning_outcome = option::some(actual_winner);
    state.finalization_time = option::some(timestamp);

    event::emit(MarketStateFinalizedEvent {
        proposal_id: state.proposal_id,
        winning_outcome: actual_winner,
        timestamp_ms: timestamp,
    });

    event::emit(ExecutionTimeoutEvent {
        proposal_id: state.proposal_id,
        market_winner, // What TWAP said should win
        actual_winner, // REJECT due to timeout
        timestamp_ms: timestamp,
    });
}

/// Finalize immediately with REJECT when TWAP shows REJECT won.
/// This is the fast path - no execution window needed since there are no actions.
/// Called directly from end_trading_and_start_execution_window when market_winner == 0.
/// SECURITY: Requires MarketStateMutationAuth from an authorized package.
public fun finalize_immediately_with_reject(
    state: &mut MarketState,
    frozen_twaps: vector<u128>,
    clock: &Clock,
    _auth: &MarketStateMutationAuth,
) {
    assert!(state.status.trading_started, ETradingNotStarted);
    assert!(!state.status.trading_ended, ETradingAlreadyEnded);
    assert!(!state.status.finalized, EAlreadyFinalized);
    assert!(!state.status.in_execution_window, EExecutionWindowAlreadyStarted);
    // Validate frozen_twaps vector length matches outcome_count
    assert!(frozen_twaps.length() == state.outcome_count, EInvalidTwapVectorLength);

    // Enforce trading end time (defense-in-depth, matching end_trading)
    if (state.trading_end.is_some()) {
        let end_time = *state.trading_end.borrow();
        assert!(clock.timestamp_ms() >= end_time, ETradingEndTimeNotReached);
    };

    let timestamp = clock.timestamp_ms();

    // Mark trading as ended and finalize directly (skip execution window)
    state.status.trading_ended = true;
    state.status.finalized = true;
    state.winning_outcome = option::some(0u64); // REJECT
    state.finalization_time = option::some(timestamp);

    // Store TWAPs for reference
    state.frozen_twaps = option::some(frozen_twaps);
    state.market_winner = option::some(0u64);

    // Emit TradingEndedEvent since trading is ending
    event::emit(TradingEndedEvent {
        proposal_id: state.proposal_id,
        timestamp_ms: timestamp,
    });

    event::emit(MarketStateFinalizedEvent {
        proposal_id: state.proposal_id,
        winning_outcome: 0,
        timestamp_ms: timestamp,
    });
}

/// Check if currently in execution window
public fun is_in_execution_window(state: &MarketState): bool {
    state.status.in_execution_window
}

/// Check if execution can be attempted (in window and not past deadline)
public fun can_execute(state: &MarketState, clock: &Clock): bool {
    if (!state.status.in_execution_window || state.status.finalized) {
        return false
    };

    if (state.execution_deadline.is_none()) {
        return false
    };
    let deadline = *state.execution_deadline.borrow();
    clock.timestamp_ms() < deadline
}

/// Check if execution has timed out
public fun is_execution_timed_out(state: &MarketState, clock: &Clock): bool {
    if (!state.status.in_execution_window || state.status.finalized) {
        return false
    };

    if (state.execution_deadline.is_none()) {
        return false
    };
    let deadline = *state.execution_deadline.borrow();
    clock.timestamp_ms() >= deadline
}

/// Get the execution deadline
public fun get_execution_deadline(state: &MarketState): Option<u64> {
    state.execution_deadline
}

/// Get the frozen TWAPs (captured when execution window started)
public fun get_frozen_twaps(state: &MarketState): &Option<vector<u128>> {
    &state.frozen_twaps
}

/// Get the market winner (what TWAP said should win, before execution check)
public fun get_market_winner(state: &MarketState): Option<u64> {
    state.market_winner
}

/// Assert that we're in the execution window and can execute
public fun assert_can_execute(state: &MarketState, clock: &Clock) {
    assert!(state.status.in_execution_window, ENotInExecutionWindow);
    assert!(!state.status.finalized, EAlreadyFinalized);
    assert!(state.execution_deadline.is_some(), ENotInExecutionWindow);
    let deadline = *state.execution_deadline.borrow();
    assert!(clock.timestamp_ms() < deadline, EExecutionDeadlinePassed);
}

// === Pool Management Functions ===

/// Initialize AMM pools for the market
/// Called once when market transitions to TRADING state
/// SECURITY: Requires MarketStateMutationAuth from an authorized package.
public fun set_amm_pools(
    state: &mut MarketState,
    pools: vector<LiquidityPool>,
    _auth: &MarketStateMutationAuth,
) {
    assert!(state.amm_pools.is_none(), EAmmPoolsAlreadySet);
    assert!(pools.length() == state.outcome_count, EPoolCountMismatch);
    let expected_market_id = object::id(state);
    let mut i = 0;
    while (i < pools.length()) {
        let pool_market_id = futarchy_markets_primitives::conditional_amm::get_ms_id(&pools[i]);
        assert!(pool_market_id == expected_market_id, EPoolMarketMismatch);
        assert!(
            (futarchy_markets_primitives::conditional_amm::get_outcome_idx(&pools[i]) as u64) == i,
            EPoolOutcomeMismatch,
        );
        i = i + 1;
    };
    option::fill(&mut state.amm_pools, pools);
}

/// Check if market has AMM pools initialized
public fun has_amm_pools(state: &MarketState): bool {
    state.amm_pools.is_some()
}

/// Borrow AMM pools immutably
public fun borrow_amm_pools(state: &MarketState): &vector<LiquidityPool> {
    assert!(state.amm_pools.is_some(), EAmmPoolsNotSet);
    state.amm_pools.borrow()
}

/// Borrow AMM pools mutably
/// SECURITY: Test-only. Production code must use get_pool_mut_by_outcome to avoid
/// exposing structural vector mutation (swap/pop/reorder) through EscrowMutationAuth.
#[test_only]
public fun borrow_amm_pools_mut(
    state: &mut MarketState,
    _escrow_auth: &EscrowMutationAuth,
): &mut vector<LiquidityPool> {
    assert!(state.amm_pools.is_some(), EAmmPoolsNotSet);
    state.amm_pools.borrow_mut()
}

/// Get a specific pool by outcome index
public fun get_pool_by_outcome(state: &MarketState, outcome_idx: u64): &LiquidityPool {
    assert!(outcome_idx < state.outcome_count, EOutcomeOutOfBounds);
    assert!(state.amm_pools.is_some(), EAmmPoolsNotSet);
    let pools = state.amm_pools.borrow();
    &pools[outcome_idx]
}

/// Get a specific pool mutably by outcome index
/// SECURITY: Requires EscrowMutationAuth to ensure only authorized packages can mutate pools.
public fun get_pool_mut_by_outcome(
    state: &mut MarketState,
    outcome_idx: u64,
    _escrow_auth: &EscrowMutationAuth,
): &mut LiquidityPool {
    assert!(outcome_idx < state.outcome_count, EOutcomeOutOfBounds);
    assert!(state.amm_pools.is_some(), EAmmPoolsNotSet);
    let pools = state.amm_pools.borrow_mut();
    &mut pools[outcome_idx]
}

// === Assertion Functions ===
public fun assert_market_finalized(state: &MarketState) {
    assert!(state.status.finalized, ENotFinalized);
}

public fun assert_not_finalized(state: &MarketState) {
    assert!(!state.status.finalized, EAlreadyFinalized);
}

public fun validate_outcome(state: &MarketState, outcome: u64) {
    assert!(outcome < state.outcome_count, EOutcomeOutOfBounds);
}

// === View Functions (Getters) ===

/// Get the MarketState's object ID (its UID).
/// This is the canonical ID used for balance matching and escrow validation.
public fun market_id(state: &MarketState): ID {
    object::id(state)
}

/// Get the proposal ID that created this market.
/// This is stored for event linking and traceability.
public fun proposal_id(state: &MarketState): ID {
    state.proposal_id
}

public fun outcome_count(state: &MarketState): u64 {
    state.outcome_count
}

// === View Functions (Predicates) ===
public fun is_trading_started(state: &MarketState): bool {
    state.status.trading_started
}

public fun is_trading_active(state: &MarketState): bool {
    state.status.trading_started && !state.status.trading_ended
}

public fun is_finalized(state: &MarketState): bool {
    state.status.finalized
}

public fun dao_id(state: &MarketState): ID {
    state.dao_id
}

public fun get_winning_outcome(state: &MarketState): u64 {
    use std::option;
    assert!(state.status.finalized, ENotFinalized);
    let opt_ref = &state.winning_outcome;
    assert!(option::is_some(opt_ref), ENotFinalized);
    *option::borrow(opt_ref)
}

public fun get_outcome_message(state: &MarketState, outcome_idx: u64): String {
    assert!(outcome_idx < state.outcome_count, EOutcomeOutOfBounds);
    state.outcome_messages[outcome_idx]
}

public fun get_creation_time(state: &MarketState): u64 {
    state.creation_time
}

public fun get_trading_end_time(state: &MarketState): Option<u64> {
    state.trading_end
}

public fun get_trading_start(state: &MarketState): u64 {
    state.trading_start
}

public fun get_finalization_time(state: &MarketState): Option<u64> {
    state.finalization_time
}

// === Test Functions ===
#[test_only]
public fun create_for_testing(outcomes: u64, ctx: &mut TxContext): MarketState {
    let dummy_id = object::new(ctx);
    let proposal_id = dummy_id.uid_to_inner();
    dummy_id.delete();

    MarketState {
        id: object::new(ctx),
        proposal_id,
        dao_id: proposal_id,
        outcome_messages: vector[],
        outcome_count: outcomes,
        amm_pools: option::none(),
        status: MarketStatus {
            trading_started: false,
            trading_ended: false,
            in_execution_window: false,
            finalized: false,
        },
        winning_outcome: option::none(),
        creation_time: 0,
        trading_start: 0,
        trading_end: option::none(),
        finalization_time: option::none(),
        execution_deadline: option::none(),
        frozen_twaps: option::none(),
        market_winner: option::none(),
    }
}

#[test_only]
public fun init_trading_for_testing(state: &mut MarketState) {
    state.status.trading_started = true;
    state.trading_start = 0;
    state.trading_end = option::some(9999999999999);
}
#[test_only]
public fun reset_state_for_testing(state: &mut MarketState) {
    state.status.trading_started = false;
    state.trading_start = 0;
}

#[test_only]
public fun finalize_for_testing(state: &mut MarketState) {
    state.status.trading_ended = true;
    state.status.finalized = true;
    state.winning_outcome = option::some(0);
    state.finalization_time = option::some(0);
}

#[test_only]
public fun destroy_for_testing(state: MarketState) {
    sui::test_utils::destroy(state);
}

#[test_only]
public fun copy_proposal_id(state: &MarketState): ID {
    state.proposal_id
}

#[test_only]
public fun copy_status(state: &MarketState): MarketStatus {
    state.status
}

#[test_only]
public fun copy_winning_outcome(state: &MarketState): Option<u64> {
    state.winning_outcome
}

#[test_only]
public fun set_proposal_id_for_testing(state: &mut MarketState, proposal_id: ID) {
    state.proposal_id = proposal_id;
}

#[test_only]
public fun set_dao_id_for_testing(state: &mut MarketState, dao_id: ID) {
    state.dao_id = dao_id;
}

#[test_only]
public fun test_set_winning_outcome(state: &mut MarketState, outcome: u64) {
    state.winning_outcome = option::some(outcome);
}

#[test_only]
public fun test_set_finalized(state: &mut MarketState) {
    state.status.finalized = true;
    state.status.trading_ended = true;
    state.finalization_time = option::some(0);
}

#[test_only]
/// Test helper to borrow AMM pool mutably by outcome index (u64 instead of u8)
public fun borrow_amm_pool_mut(state: &mut MarketState, outcome_idx: u64): &mut LiquidityPool {
    let pools = state.amm_pools.borrow_mut();
    &mut pools[outcome_idx]
}

#[test_only]
/// Test helper: start trading without auth (for tests only)
public fun start_trading_for_testing(state: &mut MarketState, duration_ms: u64, clock: &Clock) {
    assert!(!state.status.trading_started, ETradingAlreadyStarted);
    assert!(duration_ms > 0 && duration_ms <= constants::max_trading_duration_ms(), EInvalidDuration);

    let start_time = clock.timestamp_ms();
    let end_time = start_time + duration_ms;

    state.status.trading_started = true;
    state.trading_start = start_time;
    state.trading_end = option::some(end_time);

    event::emit(TradingStartedEvent {
        proposal_id: state.proposal_id,
        start_time,
    });
}

#[test_only]
/// Test helper: end trading without auth (for tests only)
public fun end_trading_for_testing(state: &mut MarketState, clock: &Clock) {
    assert!(state.status.trading_started, ETradingNotStarted);
    assert!(!state.status.trading_ended, ETradingAlreadyEnded);

    let timestamp = clock.timestamp_ms();
    state.status.trading_ended = true;

    event::emit(TradingEndedEvent {
        proposal_id: state.proposal_id,
        timestamp_ms: timestamp,
    });
}

#[test_only]
/// Test helper: finalize without auth (for tests only)
public fun finalize_test(state: &mut MarketState, winner: u64, clock: &Clock) {
    assert!(state.status.trading_ended, ETradingNotEnded);
    assert!(!state.status.finalized, EAlreadyFinalized);
    assert!(!state.status.in_execution_window, ECannotFinalizeInExecutionWindow);
    assert!(winner < state.outcome_count, EOutcomeOutOfBounds);

    let timestamp = clock.timestamp_ms();
    state.status.finalized = true;
    state.winning_outcome = option::some(winner);
    state.finalization_time = option::some(timestamp);

    event::emit(MarketStateFinalizedEvent {
        proposal_id: state.proposal_id,
        winning_outcome: winner,
        timestamp_ms: timestamp,
    });
}

#[test_only]
/// Test helper: set AMM pools without auth (for tests only)
public fun set_amm_pools_for_testing(state: &mut MarketState, pools: vector<LiquidityPool>) {
    assert!(state.amm_pools.is_none(), EAmmPoolsAlreadySet);
    assert!(pools.length() == state.outcome_count, EPoolCountMismatch);
    let expected_market_id = object::id(state);
    let mut i = 0;
    while (i < pools.length()) {
        let pool_market_id = futarchy_markets_primitives::conditional_amm::get_ms_id(&pools[i]);
        assert!(pool_market_id == expected_market_id, EPoolMarketMismatch);
        assert!(
            (futarchy_markets_primitives::conditional_amm::get_outcome_idx(&pools[i]) as u64) == i,
            EPoolOutcomeMismatch,
        );
        i = i + 1;
    };
    option::fill(&mut state.amm_pools, pools);
}

#[test_only]
/// Test helper: start execution window without auth (for tests only)
public fun start_execution_window_for_testing(
    state: &mut MarketState,
    execution_window_ms: u64,
    frozen_twaps: vector<u128>,
    market_winner: u64,
    clock: &Clock,
) {
    assert!(state.status.trading_started, ETradingNotStarted);
    assert!(!state.status.in_execution_window, EExecutionWindowAlreadyStarted);
    assert!(!state.status.finalized, EAlreadyFinalized);
    assert!(market_winner < state.outcome_count, EOutcomeOutOfBounds);
    assert!(
        execution_window_ms >= constants::min_execution_window_ms() &&
        execution_window_ms <= constants::max_execution_window_ms(),
        EInvalidExecutionWindowDuration,
    );
    assert!(frozen_twaps.length() == state.outcome_count, EInvalidTwapVectorLength);

    let timestamp = clock.timestamp_ms();
    let deadline = timestamp + execution_window_ms;

    state.status.trading_ended = true;
    state.status.in_execution_window = true;
    state.execution_deadline = option::some(deadline);
    state.frozen_twaps = option::some(frozen_twaps);
    state.market_winner = option::some(market_winner);

    event::emit(TradingEndedEvent {
        proposal_id: state.proposal_id,
        timestamp_ms: timestamp,
    });

    event::emit(ExecutionWindowStartedEvent {
        proposal_id: state.proposal_id,
        market_winner,
        execution_deadline: deadline,
        timestamp_ms: timestamp,
    });
}

#[test_only]
/// Test helper: finalize from execution success without auth (for tests only)
public fun finalize_from_execution_success_for_testing(state: &mut MarketState, clock: &Clock) {
    assert!(state.status.in_execution_window, ENotInExecutionWindow);
    assert!(!state.status.finalized, EAlreadyFinalized);

    let timestamp = clock.timestamp_ms();

    assert!(state.execution_deadline.is_some(), ENotInExecutionWindow);
    let deadline = *state.execution_deadline.borrow();
    assert!(timestamp < deadline, EExecutionDeadlinePassed);

    assert!(state.market_winner.is_some(), ENotInExecutionWindow);
    let winner = *state.market_winner.borrow();

    state.status.finalized = true;
    state.status.in_execution_window = false;
    state.winning_outcome = option::some(winner);
    state.finalization_time = option::some(timestamp);

    event::emit(MarketStateFinalizedEvent {
        proposal_id: state.proposal_id,
        winning_outcome: winner,
        timestamp_ms: timestamp,
    });
}

#[test_only]
/// Test helper: finalize from timeout without auth (for tests only)
public fun finalize_from_timeout_for_testing(state: &mut MarketState, clock: &Clock) {
    assert!(state.status.in_execution_window, ENotInExecutionWindow);
    assert!(!state.status.finalized, EAlreadyFinalized);

    let timestamp = clock.timestamp_ms();

    assert!(state.execution_deadline.is_some(), ENotInExecutionWindow);
    let deadline = *state.execution_deadline.borrow();
    assert!(timestamp >= deadline, EExecutionDeadlineNotPassed);

    assert!(state.market_winner.is_some(), ENotInExecutionWindow);
    let market_winner = *state.market_winner.borrow();
    let actual_winner = 0u64;

    state.status.finalized = true;
    state.status.in_execution_window = false;
    state.winning_outcome = option::some(actual_winner);
    state.finalization_time = option::some(timestamp);

    event::emit(ExecutionTimeoutEvent {
        proposal_id: state.proposal_id,
        market_winner,
        actual_winner,
        timestamp_ms: timestamp,
    });
}

#[test_only]
/// Test helper: finalize immediately with reject without auth (for tests only)
public fun finalize_immediately_with_reject_for_testing(
    state: &mut MarketState,
    frozen_twaps: vector<u128>,
    clock: &Clock,
) {
    assert!(state.status.trading_started, ETradingNotStarted);
    assert!(!state.status.finalized, EAlreadyFinalized);
    assert!(!state.status.in_execution_window, EExecutionWindowAlreadyStarted);
    assert!(frozen_twaps.length() == state.outcome_count, EInvalidTwapVectorLength);

    let timestamp = clock.timestamp_ms();

    state.status.trading_ended = true;
    state.status.finalized = true;
    state.winning_outcome = option::some(0u64);
    state.finalization_time = option::some(timestamp);
    state.frozen_twaps = option::some(frozen_twaps);
    state.market_winner = option::some(0u64);

    event::emit(TradingEndedEvent {
        proposal_id: state.proposal_id,
        timestamp_ms: timestamp,
    });

    event::emit(MarketStateFinalizedEvent {
        proposal_id: state.proposal_id,
        winning_outcome: 0,
        timestamp_ms: timestamp,
    });
}
