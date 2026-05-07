#[test_only]
module futarchy_markets_primitives::market_state_tests;

use futarchy_core::market_state_mutation_auth;
use futarchy_one_shot_utils::constants;
use futarchy_markets_primitives::market_state;
use futarchy_markets_primitives::conditional_amm;
use std::string;
use sui::clock::{Self, Clock};
use sui::test_scenario as ts;
use sui::test_utils::destroy;

// === Test Helpers ===

fun start(): (ts::Scenario, Clock) {
    let mut scenario = ts::begin(@0x0);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    (scenario, clock)
}

fun end(scenario: ts::Scenario, clock: Clock) {
    destroy(clock);
    ts::end(scenario);
}

fun default_execution_window_ms(): u64 {
    constants::execution_window_ms()
}

// === Basic Test ===

// === Lifecycle Tests ===

#[test]
fun test_new_market_state() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let proposal_id = object::id_from_address(@0x1);
    let dao_id = object::id_from_address(@0x2);
    let outcome_messages = vector[string::utf8(b"Approve"), string::utf8(b"Reject")];

    let state = market_state::new(
        proposal_id,
        dao_id,
        2,
        outcome_messages,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify initial state
    // Note: market_id() returns the object UID, proposal_id() returns the stored proposal ID
    assert!(market_state::proposal_id(&state) == proposal_id, 0);
    assert!(market_state::dao_id(&state) == dao_id, 1);
    assert!(market_state::outcome_count(&state) == 2, 2);
    assert!(!market_state::is_trading_active(&state), 3);
    assert!(!market_state::is_finalized(&state), 4);
    assert!(market_state::get_creation_time(&state) == 1000, 5);
    assert!(!market_state::has_amm_pools(&state), 6);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_start_trading() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let dao_id = object::id_from_address(@0x2);
    let outcome_messages = vector[string::utf8(b"Yes"), string::utf8(b"No")];

    let mut state = market_state::new(
        market_id,
        dao_id,
        2,
        outcome_messages,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Start trading with 7 days duration
    let duration_ms = 7 * 24 * 60 * 60 * 1000; // 7 days
    market_state::start_trading_for_testing(&mut state, duration_ms, &clock);

    // Verify trading started
    assert!(market_state::is_trading_active(&state), 0);
    assert!(market_state::get_trading_start(&state) == 1000, 1);

    let end_time = market_state::get_trading_end_time(&state);
    assert!(end_time.is_some(), 2);
    assert!(*end_time.borrow() == 1000 + duration_ms, 3);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_start_trading_uses_supplied_start_time_when_called_late() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(10_000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"Yes"), string::utf8(b"No")],
        &clock,
        ts::ctx(&mut scenario),
    );

    let auth = market_state_mutation_auth::create_for_testing();
    let supplied_start = 4_000;
    let duration_ms = 60_000;
    market_state::start_trading(&mut state, duration_ms, supplied_start, &clock, &auth);

    assert!(market_state::get_trading_start(&state) == supplied_start, 0);
    let end_time = market_state::get_trading_end_time(&state);
    assert!(end_time.is_some(), 1);
    assert!(*end_time.borrow() == supplied_start + duration_ms, 2);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EStartTimeInFuture)]
fun test_start_trading_rejects_future_start_time() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1_000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"Yes"), string::utf8(b"No")],
        &clock,
        ts::ctx(&mut scenario),
    );

    let auth = market_state_mutation_auth::create_for_testing();
    market_state::start_trading(&mut state, 10_000, 2_000, &clock, &auth);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyStarted)]
fun test_start_trading_twice_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 1000, &clock);
    market_state::start_trading_for_testing(&mut state, 1000, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EInvalidDuration)]
fun test_start_trading_zero_duration_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 0, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EInvalidDuration)]
fun test_start_trading_excessive_duration_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Try to start with > 30 days
    let invalid_duration = 31 * 24 * 60 * 60 * 1000;
    market_state::start_trading_for_testing(&mut state, invalid_duration, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_end_trading() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);

    // Advance time and end trading
    clock.set_for_testing(12000);
    market_state::end_trading_for_testing(&mut state, &clock);

    // Trading should no longer be active
    assert!(!market_state::is_trading_active(&state), 0);
    assert!(!market_state::is_finalized(&state), 1);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingNotStarted)]
fun test_end_trading_before_start_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::end_trading_for_testing(&mut state, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyEnded)]
fun test_end_trading_twice_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    market_state::end_trading_for_testing(&mut state, &clock);
    market_state::end_trading_for_testing(&mut state, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_finalize() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    market_state::end_trading_for_testing(&mut state, &clock);

    clock.set_for_testing(15000);
    market_state::finalize_test(&mut state, 0, &clock);

    // Verify finalized
    assert!(market_state::is_finalized(&state), 0);
    assert!(market_state::get_winning_outcome(&state) == 0, 1);

    let fin_time = market_state::get_finalization_time(&state);
    assert!(fin_time.is_some(), 2);
    assert!(*fin_time.borrow() == 15000, 3);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingNotEnded)]
fun test_finalize_before_trading_ends_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    market_state::finalize_test(&mut state, 0, &clock); // Should fail - trading not ended

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EAlreadyFinalized)]
fun test_finalize_twice_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    market_state::end_trading_for_testing(&mut state, &clock);
    market_state::finalize_test(&mut state, 0, &clock);
    market_state::finalize_test(&mut state, 1, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EOutcomeOutOfBounds)]
fun test_finalize_invalid_outcome_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2, // Only 2 outcomes (0 and 1)
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    market_state::end_trading_for_testing(&mut state, &clock);
    market_state::finalize_test(&mut state, 2, &clock); // Should fail - outcome 2 doesn't exist

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === Full Lifecycle Test ===

#[test]
fun test_complete_lifecycle() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(0);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        3,
        vector[string::utf8(b"Outcome A"), string::utf8(b"Outcome B"), string::utf8(b"Outcome C")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Phase 1: Pre-trading
    assert!(!market_state::is_trading_active(&state), 0);
    assert!(!market_state::is_finalized(&state), 1);

    // Phase 2: Start trading
    let duration = 7 * 24 * 60 * 60 * 1000; // 7 days
    market_state::start_trading_for_testing(&mut state, duration, &clock);
    assert!(market_state::is_trading_active(&state), 2);

    // Phase 3: Trading period
    clock.set_for_testing(duration / 2); // Halfway through
    assert!(market_state::is_trading_active(&state), 3);

    // Phase 4: End trading
    clock.set_for_testing(duration + 1000);
    market_state::end_trading_for_testing(&mut state, &clock);
    assert!(!market_state::is_trading_active(&state), 4);

    // Phase 5: Finalize
    clock.set_for_testing(duration + 2000);
    market_state::finalize_test(&mut state, 1, &clock);
    assert!(market_state::is_finalized(&state), 5);
    assert!(market_state::get_winning_outcome(&state) == 1, 6);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === Assertion Function Tests ===

#[test]
fun test_assert_trading_active() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    market_state::assert_trading_active(&state); // Should not abort

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingNotStarted)]
fun test_assert_trading_active_before_start_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::assert_trading_active(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyEnded)]
fun test_assert_trading_active_after_end_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    market_state::end_trading_for_testing(&mut state, &clock);
    market_state::assert_trading_active(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_assert_in_trading_or_pre_trading() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should pass in pre-trading
    market_state::assert_in_trading_or_pre_trading(&state);

    // Should pass during trading
    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    market_state::assert_in_trading_or_pre_trading(&state);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyEnded)]
fun test_assert_in_trading_or_pre_trading_after_end_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    market_state::end_trading_for_testing(&mut state, &clock);
    market_state::assert_in_trading_or_pre_trading(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_assert_market_finalized() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    market_state::end_trading_for_testing(&mut state, &clock);
    market_state::finalize_test(&mut state, 0, &clock);

    market_state::assert_market_finalized(&state); // Should not abort

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ENotFinalized)]
fun test_assert_market_finalized_before_finalize_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::assert_market_finalized(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_validate_outcome() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        3, // 3 outcomes: 0, 1, 2
        vector[string::utf8(b"A"), string::utf8(b"B"), string::utf8(b"C")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::validate_outcome(&state, 0); // OK
    market_state::validate_outcome(&state, 1); // OK
    market_state::validate_outcome(&state, 2); // OK

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EOutcomeOutOfBounds)]
fun test_validate_outcome_out_of_bounds_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2, // Only outcomes 0 and 1
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::validate_outcome(&state, 2); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === Getter Tests ===

#[test]
fun test_get_outcome_message() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        3,
        vector[string::utf8(b"Option A"), string::utf8(b"Option B"), string::utf8(b"Option C")],
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(market_state::get_outcome_message(&state, 0) == string::utf8(b"Option A"), 0);
    assert!(market_state::get_outcome_message(&state, 1) == string::utf8(b"Option B"), 1);
    assert!(market_state::get_outcome_message(&state, 2) == string::utf8(b"Option C"), 2);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EOutcomeOutOfBounds)]
fun test_get_outcome_message_out_of_bounds_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    let _ = market_state::get_outcome_message(&state, 5); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ENotFinalized)]
fun test_get_winning_outcome_before_finalize_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    let _ = market_state::get_winning_outcome(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === Execution Window Tests ===

#[test]
fun test_start_execution_window() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Start trading
    market_state::start_trading_for_testing(&mut state, 10000, &clock);

    // Advance time and start execution window
    clock.set_for_testing(12000);
    let execution_window_ms = default_execution_window_ms();
    let frozen_twaps = vector[500000000000000000u128, 600000000000000000u128];
    let market_winner = 1u64; // Accept won

    market_state::start_execution_window_for_testing(
        &mut state,
        execution_window_ms,
        frozen_twaps,
        market_winner,
        &clock,
    );

    // Verify execution window state
    assert!(market_state::is_in_execution_window(&state), 0);
    assert!(!market_state::is_finalized(&state), 1);

    let deadline = market_state::get_execution_deadline(&state);
    assert!(deadline.is_some(), 2);
    assert!(*deadline.borrow() == 12000 + execution_window_ms, 3);

    let winner = market_state::get_market_winner(&state);
    assert!(winner.is_some(), 4);
    assert!(*winner.borrow() == 1, 5);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EInvalidExecutionWindowDuration)]
fun test_start_execution_window_too_short_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);

    // Try with execution window below the network minimum (should fail).
    let too_short = constants::min_execution_window_ms() - 1;
    market_state::start_execution_window_for_testing(
        &mut state,
        too_short,
        vector[500000000000000000u128, 500000000000000000u128],
        1,
        &clock,
    );

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EInvalidExecutionWindowDuration)]
fun test_start_execution_window_too_long_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);

    // Try with execution window above the network maximum (should fail).
    let too_long = constants::max_execution_window_ms() + 1;
    market_state::start_execution_window_for_testing(
        &mut state,
        too_long,
        vector[500000000000000000u128, 500000000000000000u128],
        1,
        &clock,
    );

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EExecutionWindowAlreadyStarted)]
fun test_start_execution_window_twice_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);

    let window_ms = default_execution_window_ms();
    // Use vector with 2 elements to match outcome_count
    market_state::start_execution_window_for_testing(
        &mut state,
        window_ms,
        vector[500u128, 500u128],
        1,
        &clock,
    );
    market_state::start_execution_window_for_testing(
        &mut state,
        window_ms,
        vector[500u128, 500u128],
        1,
        &clock,
    ); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_finalize_from_execution_success() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Setup: start trading, then execution window
    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    market_state::start_execution_window_for_testing(
        &mut state,
        default_execution_window_ms(),
        vector[500u128, 600u128],
        1,
        &clock,
    );

    // Finalize from success (within deadline)
    clock.set_for_testing(15000);
    market_state::finalize_from_execution_success_for_testing(&mut state, &clock);

    // Verify finalized with Accept (outcome 1) winning
    assert!(market_state::is_finalized(&state), 0);
    assert!(!market_state::is_in_execution_window(&state), 1);
    assert!(market_state::get_winning_outcome(&state) == 1, 2);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EExecutionDeadlinePassed)]
fun test_finalize_from_execution_success_after_deadline_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);

    let window_ms = default_execution_window_ms();
    market_state::start_execution_window_for_testing(
        &mut state,
        window_ms,
        vector[500u128, 500u128],
        1,
        &clock,
    );

    // Advance past deadline
    clock.set_for_testing(12000 + window_ms + 1000);
    market_state::finalize_from_execution_success_for_testing(&mut state, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_finalize_from_timeout() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Setup: start trading, then execution window with Accept as market_winner
    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    let window_ms = default_execution_window_ms();
    market_state::start_execution_window_for_testing(
        &mut state,
        window_ms,
        vector[500u128, 600u128],
        1,
        &clock,
    );

    // Advance past deadline and finalize from timeout
    clock.set_for_testing(12000 + window_ms + 1000);
    market_state::finalize_from_timeout_for_testing(&mut state, &clock);

    // Verify finalized with REJECT (0) winning despite market_winner being 1
    assert!(market_state::is_finalized(&state), 0);
    assert!(!market_state::is_in_execution_window(&state), 1);
    assert!(market_state::get_winning_outcome(&state) == 0, 2); // REJECT wins on timeout

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EExecutionDeadlineNotPassed)]
fun test_finalize_from_timeout_before_deadline_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    market_state::start_execution_window_for_testing(
        &mut state,
        default_execution_window_ms(),
        vector[500u128, 500u128],
        1,
        &clock,
    );

    // Try to timeout before deadline (should fail)
    clock.set_for_testing(15000);
    market_state::finalize_from_timeout_for_testing(&mut state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_finalize_immediately_with_reject() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Start trading
    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);

    // REJECT fast path: finalize immediately without execution window
    let frozen_twaps = vector[600000000000000000u128, 400000000000000000u128]; // REJECT TWAP higher
    market_state::finalize_immediately_with_reject_for_testing(&mut state, frozen_twaps, &clock);

    // Verify finalized immediately with REJECT winning
    assert!(market_state::is_finalized(&state), 0);
    assert!(!market_state::is_in_execution_window(&state), 1);
    assert!(market_state::get_winning_outcome(&state) == 0, 2);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EExecutionWindowAlreadyStarted)]
fun test_finalize_immediately_with_reject_after_execution_window_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    market_state::start_execution_window_for_testing(
        &mut state,
        default_execution_window_ms(),
        vector[500u128, 500u128],
        1,
        &clock,
    );

    // Try to use REJECT fast path after execution window started (should fail)
    market_state::finalize_immediately_with_reject_for_testing(&mut state, vector[600u128], &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_assert_can_execute() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    market_state::start_execution_window_for_testing(
        &mut state,
        default_execution_window_ms(),
        vector[500u128, 500u128],
        1,
        &clock,
    );

    // Should pass within execution window
    clock.set_for_testing(15000);
    market_state::assert_can_execute(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ENotInExecutionWindow)]
fun test_assert_can_execute_before_execution_window_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);

    // Try before execution window starts (should fail)
    market_state::assert_can_execute(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EExecutionDeadlinePassed)]
fun test_assert_can_execute_after_deadline_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    let window_ms = default_execution_window_ms();
    market_state::start_execution_window_for_testing(
        &mut state,
        window_ms,
        vector[500u128, 500u128],
        1,
        &clock,
    );

    // Advance past deadline (should fail)
    clock.set_for_testing(12000 + window_ms + 1000);
    market_state::assert_can_execute(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_can_execute_helper() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Before trading: can't execute
    assert!(!market_state::can_execute(&state, &clock), 0);

    market_state::start_trading_for_testing(&mut state, 10000, &clock);

    // During trading but no execution window: can't execute
    assert!(!market_state::can_execute(&state, &clock), 1);

    clock.set_for_testing(12000);
    let window_ms = default_execution_window_ms();
    market_state::start_execution_window_for_testing(
        &mut state,
        window_ms,
        vector[500u128, 500u128],
        1,
        &clock,
    );

    // In execution window: can execute
    assert!(market_state::can_execute(&state, &clock), 2);

    // After deadline: can't execute
    clock.set_for_testing(12000 + window_ms + 1000);
    assert!(!market_state::can_execute(&state, &clock), 3);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_is_execution_timed_out() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    let window_ms = default_execution_window_ms();
    market_state::start_execution_window_for_testing(
        &mut state,
        window_ms,
        vector[500u128, 500u128],
        1,
        &clock,
    );

    // Before deadline: not timed out
    clock.set_for_testing(15000);
    assert!(!market_state::is_execution_timed_out(&state, &clock), 0);

    // At deadline: timed out
    clock.set_for_testing(12000 + window_ms);
    assert!(market_state::is_execution_timed_out(&state, &clock), 1);

    // After deadline: timed out
    clock.set_for_testing(12000 + window_ms + 1000);
    assert!(market_state::is_execution_timed_out(&state, &clock), 2);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === Full Execution Flow Tests ===

#[test]
fun test_complete_execution_success_flow() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(0);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Phase 1: Start trading
    let trading_duration = 7 * 24 * 60 * 60 * 1000; // 7 days
    market_state::start_trading_for_testing(&mut state, trading_duration, &clock);
    assert!(market_state::is_trading_active(&state), 0);

    // Phase 2: End trading, start execution window (Accept won)
    clock.set_for_testing(trading_duration + 1000);
    let execution_window_ms = default_execution_window_ms();
    let frozen_twaps = vector[400u128, 600u128]; // Accept has higher TWAP
    market_state::start_execution_window_for_testing(&mut state, execution_window_ms, frozen_twaps, 1, &clock);
    assert!(market_state::is_in_execution_window(&state), 1);
    assert!(!market_state::is_finalized(&state), 2);

    // Phase 3: Execute successfully within window
    clock.set_for_testing(trading_duration + 1000 + 1000); // 1 second after window starts
    market_state::finalize_from_execution_success_for_testing(&mut state, &clock);

    // Verify final state: Accept (1) wins
    assert!(market_state::is_finalized(&state), 3);
    assert!(!market_state::is_in_execution_window(&state), 4);
    assert!(market_state::get_winning_outcome(&state) == 1, 5);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_complete_timeout_flow() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(0);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Phase 1: Start trading
    let trading_duration = 7 * 24 * 60 * 60 * 1000;
    market_state::start_trading_for_testing(&mut state, trading_duration, &clock);

    // Phase 2: End trading, start execution window (Accept won according to TWAP)
    clock.set_for_testing(trading_duration + 1000);
    let execution_window_ms = default_execution_window_ms();
    market_state::start_execution_window_for_testing(
        &mut state,
        execution_window_ms,
        vector[400u128, 600u128],
        1,
        &clock,
    );

    // Phase 3: Execution fails to happen, timeout occurs
    clock.set_for_testing(trading_duration + 1000 + execution_window_ms + 1000);
    market_state::finalize_from_timeout_for_testing(&mut state, &clock);

    // Verify final state: REJECT (0) wins despite TWAP saying Accept
    assert!(market_state::is_finalized(&state), 0);
    assert!(market_state::get_winning_outcome(&state) == 0, 1);

    // market_winner was Accept (1), but winning_outcome is REJECT (0)
    assert!(*market_state::get_market_winner(&state).borrow() == 1, 2);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_reject_fast_path_flow() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(0);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"Reject"), string::utf8(b"Accept")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Phase 1: Start trading
    let trading_duration = 7 * 24 * 60 * 60 * 1000;
    market_state::start_trading_for_testing(&mut state, trading_duration, &clock);

    // Phase 2: TWAP shows REJECT won - use fast path (no execution window)
    clock.set_for_testing(trading_duration + 1000);
    let frozen_twaps = vector[600u128, 400u128]; // REJECT has higher TWAP
    market_state::finalize_immediately_with_reject_for_testing(&mut state, frozen_twaps, &clock);

    // Verify: Finalized immediately without execution window
    assert!(market_state::is_finalized(&state), 0);
    assert!(!market_state::is_in_execution_window(&state), 1);
    assert!(market_state::get_winning_outcome(&state) == 0, 2);

    // No execution deadline was set (fast path)
    assert!(market_state::get_execution_deadline(&state).is_none(), 3);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === assert_swaps_allowed Tests ===
// This function allows swaps during trading AND during execution window
// (unlike assert_trading_active which only works during trading)

#[test]
fun test_assert_swaps_allowed_during_trading() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);

    // Should pass during active trading
    market_state::assert_swaps_allowed(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingEndTimePassed)]
fun test_assert_swaps_allowed_after_scheduled_trading_end_before_execution_window_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);

    // Trading has not been formally ended yet, but the scheduled trading_end has passed.
    // This is the gap the audit report described; swaps must still be blocked here.
    clock.set_for_testing(11001);
    market_state::assert_swaps_allowed(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_assert_swaps_allowed_during_execution_window() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Start trading
    market_state::start_trading_for_testing(&mut state, 10000, &clock);

    // Advance time past trading end
    clock.set_for_testing(12000);

    // Start execution window
    let window_ms = default_execution_window_ms();
    market_state::start_execution_window_for_testing(
        &mut state,
        window_ms,
        vector[500u128, 600u128],
        1,
        &clock,
    );

    // Swaps should still be allowed during execution window
    market_state::assert_swaps_allowed(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EExecutionDeadlinePassed)]
fun test_assert_swaps_allowed_after_execution_deadline_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);

    let window_ms = default_execution_window_ms();
    market_state::start_execution_window_for_testing(
        &mut state,
        window_ms,
        vector[500u128, 600u128],
        1,
        &clock,
    );

    clock.set_for_testing(12000 + window_ms + 1);
    market_state::assert_swaps_allowed(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingNotStarted)]
fun test_assert_swaps_allowed_before_trading_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Should fail before trading starts
    market_state::assert_swaps_allowed(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyEnded)]
fun test_assert_swaps_allowed_after_trading_without_execution_window_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Start and end trading WITHOUT entering execution window
    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    market_state::end_trading_for_testing(&mut state, &clock);

    // Should fail - trading ended and not in execution window
    market_state::assert_swaps_allowed(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EAlreadyFinalized)]
fun test_assert_swaps_allowed_after_finalization_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );

    // Complete full lifecycle including finalization
    market_state::start_trading_for_testing(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    market_state::start_execution_window_for_testing(
        &mut state,
        default_execution_window_ms(),
        vector[500u128, 600u128],
        1,
        &clock,
    );
    market_state::finalize_from_execution_success_for_testing(&mut state, &clock);

    // Should fail after finalization
    market_state::assert_swaps_allowed(&state, &clock);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_set_amm_pools_for_testing_with_matching_market_id_succeeds() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );
    let market_id = market_state::market_id(&state);

    let pool0 = conditional_amm::create_test_pool(
        market_id,
        0,
        30,
        1_000,
        1_000,
        &clock,
        ts::ctx(&mut scenario),
    );
    let pool1 = conditional_amm::create_test_pool(
        market_id,
        1,
        30,
        1_000,
        1_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::set_amm_pools_for_testing(&mut state, vector[pool0, pool1]);
    assert!(market_state::has_amm_pools(&state), 0);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EPoolMarketMismatch)]
fun test_set_amm_pools_for_testing_with_foreign_market_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario),
    );
    let foreign_market_id = object::id_from_address(@0x999);

    let pool0 = conditional_amm::create_test_pool(
        foreign_market_id,
        0,
        30,
        1_000,
        1_000,
        &clock,
        ts::ctx(&mut scenario),
    );
    let pool1 = conditional_amm::create_test_pool(
        foreign_market_id,
        1,
        30,
        1_000,
        1_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    market_state::set_amm_pools_for_testing(&mut state, vector[pool0, pool1]);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}
