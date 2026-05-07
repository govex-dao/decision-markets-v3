#[test_only]
module futarchy_proposal::proposal_tests;

use account_protocol::intents::ActionSpec;
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::LiquidityPool;
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use futarchy_proposal::proposal;
use std::option;
use std::string::{Self, String};
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils;

// === Test Constants ===

const DAO_ADDR: address = @0xDA0;
const PROPOSER_ADDR: address = @0xABCD;
const TREASURY_ADDR: address = @0xFEE;

const REVIEW_PERIOD_MS: u64 = 24 * 60 * 60 * 1000; // 24 hours
const TRADING_PERIOD_MS: u64 = 7 * 24 * 60 * 60 * 1000; // 7 days
const MIN_ASSET_LIQUIDITY: u64 = 1_000_000_000; // 1 token (9 decimals)
const MIN_STABLE_LIQUIDITY: u64 = 10_000_000; // 10 USDC (6 decimals)
const TWAP_START_DELAY: u64 = 60 * 1000; // 1 minute
const TWAP_INITIAL_OBSERVATION: u128 = 1_000_000_000_000_000_000u128; // 1.0 in Q64.64
const TWAP_STEP_MAX: u64 = 100;
const TWAP_THRESHOLD_VALUE: u128 = 500_000_000_000_000_000u128; // 0.5 in Q64.64
const AMM_TOTAL_FEE_BPS: u64 = 30; // 0.3%
const CONDITIONAL_LIQUIDITY_RATIO_PERCENT: u64 = 50; // 50% (base 100, not BPS!)
const MAX_OUTCOMES: u64 = 10;

// Error codes from proposal.move
const EInvalidAmount: u64 = 1;
const EInvalidState: u64 = 2;
const EAssetLiquidityTooLow: u64 = 4;
const EStableLiquidityTooLow: u64 = 5;
const EPoolNotFound: u64 = 6;
const EOutcomeOutOfBounds: u64 = 7;
const EInvalidOutcomeVectors: u64 = 8;
const ETooManyOutcomes: u64 = 10;
const EInvalidOutcome: u64 = 11;
const ENotFinalized: u64 = 12;
const ETwapNotSet: u64 = 13;

// State constants
const STATE_PREMARKET: u8 = 0;
const STATE_REVIEW: u8 = 1;
const STATE_TRADING: u8 = 2;
const STATE_FINALIZED: u8 = 3;

// Outcome constants
// NOTE: These must match the constants in proposal.move and proposal_lifecycle.move
const OUTCOME_REJECTED: u64 = 0; // Reject is ALWAYS outcome 0 (baseline/status quo)
const OUTCOME_ACCEPTED: u64 = 1; // Accept is ALWAYS outcome 1+ (proposed actions)

// === Test Helpers ===

/// Create a test clock at specific time
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

/// Helper to create outcome messages
fun create_outcome_messages(count: u64): vector<String> {
    let mut messages = vector::empty<String>();
    let mut i = 0;
    while (i < count) {
        let mut msg = string::utf8(b"Outcome ");
        string::append(&mut msg, string::utf8(b""));
        messages.push_back(msg);
        i = i + 1;
    };
    messages
}

/// Helper to create outcome details
fun create_outcome_details(count: u64): vector<String> {
    let mut details = vector::empty<String>();
    let mut i = 0;
    while (i < count) {
        let mut detail = string::utf8(b"Detail ");
        string::append(&mut detail, string::utf8(b""));
        details.push_back(detail);
        i = i + 1;
    };
    details
}

/// Helper to create test proposal ID
fun create_test_proposal_id(ctx: &mut TxContext): ID {
    object::id_from_address(@0x1234)
}

// === Proposal Creation Tests ===

// === State Constant Getter Tests ===

#[test]
fun test_state_premarket_constant() {
    assert!(proposal::state_premarket() == 0, 0);
}

#[test]
fun test_state_review_constant() {
    assert!(proposal::state_review() == 1, 0);
}

#[test]
fun test_state_trading_constant() {
    assert!(proposal::state_trading() == 2, 0);
}

#[test]
fun test_state_awaiting_execution_constant() {
    assert!(proposal::state_awaiting_execution() == 3, 0);
}

#[test]
fun test_state_finalized_constant() {
    assert!(proposal::state_finalized() == 4, 0);
}

#[test]
fun test_state_constants_are_sequential() {
    // Verify state constants are sequential and in expected order
    assert!(proposal::state_premarket() == 0, 0);
    assert!(proposal::state_review() == proposal::state_premarket() + 1, 1);
    assert!(proposal::state_trading() == proposal::state_review() + 1, 2);
    assert!(proposal::state_awaiting_execution() == proposal::state_trading() + 1, 3);
    assert!(proposal::state_finalized() == proposal::state_awaiting_execution() + 1, 4);
}

#[test]
fun test_execution_window_ms_constant() {
    let window_ms = proposal::execution_window_ms();
    let default_window_ms = 30 * 60 * 1000;
    let min_window_ms = constants::min_execution_window_ms();
    let expected_window_ms = if (default_window_ms > min_window_ms) {
        default_window_ms
    } else {
        min_window_ms
    };
    assert!(window_ms == expected_window_ms, 0);
}
