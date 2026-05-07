// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_proposal::proposal;

use account_actions::action_spec_builder::{Self, Builder};
use account_protocol::account::{Self, Account};
use account_protocol::action_events;
use account_protocol::deps;
use account_protocol::intents::{Self, ActionSpec};
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::dao_config;
use futarchy_core::emergency_cap::{Self, EmergencyCap};
use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationRegistry, EscrowMutationAuth};
use futarchy_core::futarchy_config;
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::math;
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationRegistry};
use futarchy_core::proposal_quota_registry;
use futarchy_core::proposal_mutation_auth::{Self, ProposalMutationAuth};
use futarchy_core::sponsorship_auth::{Self, SponsorshipAuth};
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationRegistry};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::market_state;
use futarchy_proposal::conditional_coin_utils;
use futarchy_proposal::liquidity_initialize;
use std::ascii::{Self, String as AsciiString};
use std::option;
use std::string::{Self, String};
use std::type_name::{Self, TypeName};
use std::vector;
use sui::address;
use sui::bag::{Self, Bag};
use sui::balance::{Self as balance, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::{Self, Currency, MetadataCap};
use sui::event;
use sui::hex;

// === Introduction ===
// This defines the core proposal logic and details

// === Errors ===

const EInvalidState: u64 = 2;
const EAssetLiquidityTooLow: u64 = 4;
const EStableLiquidityTooLow: u64 = 5;
const EPoolNotFound: u64 = 6;
const EOutcomeOutOfBounds: u64 = 7;
const ETooManyOutcomes: u64 = 10;
const EInvalidOutcome: u64 = 11;
const ENotFinalized: u64 = 12;
const ETwapNotSet: u64 = 13;
const ETooManyActions: u64 = 14;
const ENotLiquidityProvider: u64 = 17;
const EInvalidSponsorshipType: u64 = 18; // Repurposed from EAlreadySponsored (now idempotent)
const ESupplyNotZero: u64 = 19;
const EPriceVerificationFailed: u64 = 21;
const ECannotSetActionsForRejectOutcome: u64 = 22;
const EInvalidAssetType: u64 = 23;
const EInvalidStableType: u64 = 24;
const EInsufficientFee: u64 = 25;
const ECannotSponsorReject: u64 = 26;
const EActionPackageNotAuthorized: u64 = 27;
const EMetadataNameNotEmpty: u64 = 28;
const EMetadataIconNotEmpty: u64 = 30;
const EMetadataDescriptionNotEmpty: u64 = 31;
const EMissingConditionalCoins: u64 = 32;
const EOutcomeCountMismatch: u64 = 33;
const EWrongFeeType: u64 = 34;
const EInvalidSymbol: u64 = 35;
const ENoQuotaAvailable: u64 = 36;
const EProposalEscrowMismatch: u64 = 37;
const EInvalidLifecycleState: u64 = 38;
const ENoFeeEscrowed: u64 = 39;
const EFeeCalculationOverflow: u64 = 41;
const ENotProposer: u64 = 42;
const EDaoAccountMismatch: u64 = 43;
const ESpotPoolMismatch: u64 = 44;
const ERegistryMismatch: u64 = 45;
// Error 48 removed (emergency delay moved to EmergencyCap)
const EInvalidTwapTiming: u64 = 49; // twap_start_delay must be strictly less than trading_period_ms
const EAuthTargetMismatch: u64 = 50;
const EInvalidStateTransition: u64 = 51; // set_state: transition must be forward and to a valid state
const ERegulatedCoin: u64 = 52; // conditional coin must not be regulated (depositor could retain DenyCapV2)
const EOracleUpdatePastTradingEnd: u64 = 53; // oracle update would advance past scheduled trading_end, bricking finalization
const EInvalidTwapTarget: u64 = 54; // frozen TWAP target must match the market's scheduled trading_end
const ENonAtomicProposalCreation: u64 = 55; // finalize_proposal must run in the same PTB as begin_proposal
const EInvalidConditionalCoinModule: u64 = 56; // conditional coin module must be conditional_<digits>

// === Constants ===

const CONDITIONAL_MODULE_PREFIX: vector<u8> = b"conditional_";

const STATE_PREMARKET: u8 = 0; // Proposal exists, outcomes can be added/mutated. No market yet.
const STATE_REVIEW: u8 = 1; // Market is initialized and locked for review. Not yet trading.
const STATE_TRADING: u8 = 2; // Market is live and trading.
const STATE_AWAITING_EXECUTION: u8 = 3; // TWAP measured, 30-min execution window active.
const STATE_FINALIZED: u8 = 4; // Market has resolved (execution succeeded or timeout).


// Outcome constants for TWAP calculation
// NOTE: Reject is ALWAYS outcome 0 (baseline/status quo)
// Accept is ALWAYS outcome 1+ (proposed actions)
const OUTCOME_REJECTED: u64 = 0;
const OUTCOME_ACCEPTED: u64 = 1;

// Sponsorship types
const SPONSORSHIP_NONE: u8 = 0; // Not sponsored (needs TWAP > reject + threshold)
const SPONSORSHIP_ZERO_THRESHOLD: u8 = 1; // Sponsored to zero threshold (needs TWAP >= reject)
const SPONSORSHIP_NEGATIVE_DISCOUNT: u8 = 2; // Sponsored with negative discount (needs TWAP >= reject - sponsored_threshold%)

// === Witness for MarketStateMutationAuth ===
/// Witness type for creating MarketStateMutationAuth.
/// This package must be registered in the MarketStateMutationRegistry.
public struct MarketStateMutationWitness has drop {}

/// Witness type for creating EscrowMutationAuth.
/// This package must be registered in the EscrowMutationRegistry.
public struct EscrowMutationWitness has drop {}

/// Witness type for creating SpotPoolMutationAuth.
/// This package must be registered in the SpotPoolMutationRegistry.
public struct SpotPoolMutationWitness has drop {}

// === Structs ===

/// Key for storing conditional coin caps in Bag
/// Each outcome has 2 coins: asset-conditional and stable-conditional
public struct ConditionalCoinKey has copy, drop, store {
    outcome_index: u64,
    is_asset: bool, // true for asset, false for stable
}

/// Key for storing fee balance in Bag (supports both AssetType and StableType)
public struct FeeBalanceKey has copy, drop, store {}

/// Configuration for proposal timing and periods
public struct ProposalTiming has store {
    created_at: u64,
    market_initialized_at: Option<u64>,
    trading_started_at: Option<u64>,
    review_period_ms: u64,
    trading_period_ms: u64,
    last_twap_update: u64,
    twap_start_delay: u64,
}

/// Configuration for liquidity requirements
public struct LiquidityConfig has store {
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    asset_amounts: vector<u64>,
    stable_amounts: vector<u64>,
}

/// TWAP (Time-Weighted Average Price) configuration
public struct TwapConfig has store {
    twap_prices: vector<u128>,
    /// Optional: Previous proposal's winning TWAP (None for first proposal, Some for subsequent)
    /// When None, conditional AMM will derive initial price from reserves
    twap_initial_observation: Option<u128>,
    twap_cap_ppm: u64,
    twap_threshold: u128, // Base threshold (numerator with base 100,000) for unsponsored outcomes
    sponsored_threshold: u128, // Threshold reduction for sponsored outcomes (numerator with base 100,000)
}

/// Outcome-related data
public struct OutcomeData has store {
    outcome_count: u64,
    outcome_messages: vector<String>,
    outcome_creators: vector<address>,
    intent_specs: vector<Option<vector<ActionSpec>>>, // Direct use of protocol ActionSpec
    actions_per_outcome: vector<u64>,
    winning_outcome: Option<u64>,
}

/// Core proposal object that owns AMM pools
public struct Proposal<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    state: u8,
    dao_id: ID,
    proposer: address, // The original proposer.
    liquidity_provider: Option<address>,
    withdraw_only_mode: bool, // When true, return liquidity to provider instead of auto-reinvesting
    /// Track if proposal used feeless quota (excludes from creator rewards)
    used_feeless_quota: bool,
    /// Track sponsorship type per outcome:
    /// 0 = SPONSORSHIP_NONE (not sponsored, needs TWAP > reject + threshold)
    /// 1 = SPONSORSHIP_ZERO_THRESHOLD (just needs TWAP >= reject_twap)
    /// 2 = SPONSORSHIP_NEGATIVE_DISCOUNT (can pass with TWAP >= reject - sponsored_threshold%)
    outcome_sponsorship: vector<u8>,
    /// Track if sponsor quota was already used for this proposal (one use sponsors all outcomes)
    sponsor_quota_used_for_proposal: bool,
    /// Track who used the sponsor quota (for refunds on eviction)
    sponsor_quota_user: Option<address>,
    // Market-related fields (pools now live in MarketState)
    escrow_id: Option<ID>,
    market_state_id: Option<ID>,
    // Conditional coin capabilities (stored dynamically per outcome)
    conditional_treasury_caps: Bag, // Stores TreasuryCap<ConditionalCoinType> per outcome
    conditional_metadata_caps: Bag, // Stores MetadataCap<ConditionalCoinType> per outcome (for future metadata updates)
    // Conditional coin type names for indexing (stored during add_outcome_coins)
    conditional_asset_types: vector<AsciiString>, // [outcome_0_asset_type, outcome_1_asset_type, ...]
    conditional_stable_types: vector<AsciiString>, // [outcome_0_stable_type, outcome_1_stable_type, ...]
    // Proposal content
    title: String,
    introduction_details: String,
    details: vector<String>,
    metadata: String,
    // Grouped configurations
    timing: ProposalTiming,
    liquidity_config: LiquidityConfig,
    twap_config: TwapConfig,
    outcome_data: OutcomeData,
    // Fee-related fields
    amm_total_fee_bps: u64,
    conditional_liquidity_ratio_percent: u64, // Ratio of spot liquidity to split to conditional markets (base 100, not bps!)
    fee_escrow: Bag, // Proposal fees held in Bag (Balance<AssetType> or Balance<StableType>)
    fee_paid_in_asset: bool, // true if fee was paid in AssetType, false if StableType
    total_fee_paid: u64, // Total fee paid by proposer (for refund calculation)
    // Governance parameters (read from DAO config during creation)
    max_outcomes: u64, // Maximum number of outcomes allowed
}

/// Hot potato tying `begin_proposal` and `finalize_proposal` to the same PTB.
/// No abilities: callers cannot store, transfer, copy, or drop this ticket.
public struct ProposalCreationTicket<phantom AssetType, phantom StableType> {
    proposal_id: ID,
}

/// A scoped witness proving that a particular (proposal, outcome) had an IntentSpec.
/// Only mintable by the module that has &mut Proposal and consumes the slot.
/// This prevents cross-proposal cancellation attacks.
///
/// After IntentSpec refactor: This witness proves ownership of a proposal outcome slot,
/// used for cleanup and lifecycle management.
public struct CancelWitness has drop {
    proposal: address,
    outcome_index: u64,
}

// Getter functions for CancelWitness
public fun cancel_witness_proposal(witness: &CancelWitness): address {
    witness.proposal
}

public fun cancel_witness_outcome_index(witness: &CancelWitness): u64 {
    witness.outcome_index
}

// === Events ===

public struct ProposalCreated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    proposer: address,
    outcome_count: u64,
    outcome_messages: vector<String>,
    created_at: u64,
    asset_type: AsciiString,
    stable_type: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    title: String,
    metadata: String,
}

public struct ProposalMarketInitialized has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    market_state_id: ID,
    escrow_id: ID,
    timestamp: u64,
    /// Conditional coin types for each outcome (asset coins)
    /// Index order: [outcome_0_asset, outcome_1_asset, ...]
    conditional_asset_types: vector<AsciiString>,
    /// Conditional coin types for each outcome (stable coins)
    /// Index order: [outcome_0_stable, outcome_1_stable, ...]
    conditional_stable_types: vector<AsciiString>,
}

public struct ProposalActionsStaged has copy, drop {
    proposal_id: ID,
    outcome_index: u64,
    action_types: vector<String>,
    action_versions: vector<u8>,
    action_data: vector<vector<u8>>,
}

/// Emitted after bulk sponsorship mutation is processed.
/// Includes resulting sponsorship vector and number of newly applied outcomes.
public struct ProposalSponsorshipsUpdated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    applied_count: u64,
    sponsorship_types: vector<u8>,
}

/// Emitted when sponsor quota is marked as used for a proposal.
public struct ProposalSponsorQuotaMarked has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    sponsor: address,
}

/// Emitted when sponsorships are cleared.
public struct ProposalSponsorshipsCleared has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    cleared_count: u64,
}

// === Public Functions ===

/// Check if the proposal has a fee balance escrowed.
/// Returns true if a fee was paid and stored, false for feeless proposals.
/// Always call this before take_fee_escrow_* to avoid abort on feeless proposals.
public fun has_fee_escrow<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    bag::contains(&proposal.fee_escrow, FeeBalanceKey {})
}

/// Takes the escrowed fee balance out of the proposal (StableType version)
/// Used for refunding fees to proposer if any accept wins
/// Call this when fee_paid_in_asset() returns false
/// IMPORTANT: Call has_fee_escrow() first to check if a fee exists, or this will abort
/// SECURITY: Requires ProposalMutationAuth to prevent unauthorized fee extraction.
public fun take_fee_escrow_stable<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    auth: &ProposalMutationAuth,
): Balance<StableType> {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    assert!(!proposal.fee_paid_in_asset, EWrongFeeType);
    assert!(bag::contains(&proposal.fee_escrow, FeeBalanceKey {}), ENoFeeEscrowed);
    bag::remove(&mut proposal.fee_escrow, FeeBalanceKey {})
}

/// Takes the escrowed fee balance out of the proposal (AssetType version)
/// Used for refunding fees to proposer if any accept wins
/// Call this when fee_paid_in_asset() returns true
/// IMPORTANT: Call has_fee_escrow() first to check if a fee exists, or this will abort
/// SECURITY: Requires ProposalMutationAuth to prevent unauthorized fee extraction.
public fun take_fee_escrow_asset<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    auth: &ProposalMutationAuth,
): Balance<AssetType> {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    assert!(proposal.fee_paid_in_asset, EWrongFeeType);
    assert!(bag::contains(&proposal.fee_escrow, FeeBalanceKey {}), ENoFeeEscrowed);
    bag::remove(&mut proposal.fee_escrow, FeeBalanceKey {})
}

/// Emergency fallback: EmergencyCap holder can directly recover the proposal fee escrow.
/// Requires an armed EmergencyCap with 7-day delay elapsed.
/// This bypasses ProposalMutationAuth on purpose as a last-resort rescue path.
/// Sends funds to ctx.sender() (the EmergencyCap holder).
public entry fun emergency_withdraw_fee_escrow<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &mut TxContext,
) {
    emergency_cap::assert_ready(cap, clock);

    assert!(bag::contains(&proposal.fee_escrow, FeeBalanceKey {}), ENoFeeEscrowed);

    if (proposal.fee_paid_in_asset) {
        let fee_balance: Balance<AssetType> = bag::remove(&mut proposal.fee_escrow, FeeBalanceKey {});
        let fee_coin = coin::from_balance(fee_balance, ctx);
        transfer::public_transfer(fee_coin, ctx.sender());
    } else {
        let fee_balance: Balance<StableType> = bag::remove(&mut proposal.fee_escrow, FeeBalanceKey {});
        let fee_coin = coin::from_balance(fee_balance, ctx);
        transfer::public_transfer(fee_coin, ctx.sender());
    };
}

/// Emergency fallback: once the EmergencyCap is ready, recover a conditional coin MetadataCap
/// stored on the proposal (per outcome, asset/stable) to sender.
public entry fun emergency_take_conditional_metadata_cap_to_sender<
    AssetType,
    StableType,
    ConditionalCoinType,
>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &mut TxContext,
) {
    emergency_cap::assert_ready(cap, clock);

    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);

    let key = ConditionalCoinKey { outcome_index, is_asset };
    let metadata_cap: MetadataCap<ConditionalCoinType> = bag::remove(&mut proposal.conditional_metadata_caps, key);
    transfer::public_transfer(metadata_cap, ctx.sender());
}

/// Emergency fallback: "burn" a conditional coin MetadataCap
/// by sending it to @0x0 (black hole address).
/// Requires an armed EmergencyCap with 7-day delay elapsed.
public entry fun emergency_burn_conditional_metadata_cap<
    AssetType,
    StableType,
    ConditionalCoinType,
>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    clock: &Clock,
    cap: &EmergencyCap,
    _ctx: &mut TxContext,
) {
    emergency_cap::assert_ready(cap, clock);

    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);

    let key = ConditionalCoinKey { outcome_index, is_asset };
    let metadata_cap: MetadataCap<ConditionalCoinType> = bag::remove(&mut proposal.conditional_metadata_caps, key);
    transfer::public_transfer(metadata_cap, @0x0);
}

/// Check if fee was paid in AssetType (true) or StableType (false)
public fun fee_paid_in_asset<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    proposal.fee_paid_in_asset
}

/// Get TWAPs from all pools via the spot pool's active escrow.
/// The escrow is wrapped inside the pool — this function borrows it.
/// SECURITY: Lifecycle-gated — only callable during live trading
/// and before the scheduled trading deadline.
public fun get_twaps_for_proposal<AssetType, StableType, LPType>(
    proposal: &mut Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
): vector<u128> {
    assert!(is_live(proposal), EInvalidState);

    let spot_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    let escrow = unified_spot_pool::borrow_active_escrow_mut(spot_pool, &spot_auth);
    assert_escrow_matches_proposal(proposal, escrow);

    let auth = escrow_mutation_auth::create(escrow_registry, EscrowMutationWitness {});
    let ms_auth = market_state_mutation_auth::create(
        market_state_registry,
        MarketStateMutationWitness {},
    );
    let market_state = coin_escrow::get_market_state_mut(escrow, &auth);

    // SECURITY: Prevent oracle advancement past trading_end.
    // get_twap(clock) writes an observation at clock.timestamp_ms(). If that exceeds
    // trading_end, subsequent finalization via get_twap_at(trading_end) would abort
    // with EOracleAdvancedPastDeadline, permanently bricking the proposal.
    let trading_end_opt = market_state::get_trading_end_time(market_state);
    assert!(trading_end_opt.is_some(), EInvalidLifecycleState);
    assert!(clock.timestamp_ms() <= *trading_end_opt.borrow(), EOracleUpdatePastTradingEnd);

    let mut twaps = vector[];
    let outcome_count = market_state::outcome_count(market_state);
    let mut i = 0;
    while (i < outcome_count) {
        let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
        let twap = pool.get_twap(clock, &ms_auth);
        twaps.push_back(twap);
        i = i + 1;
    };
    twaps
}

/// Get TWAPs frozen at a specific target time (the scheduled trading deadline).
/// Like get_twaps_for_proposal but accumulates observations up to target_time
/// and computes TWAP as of that moment, preventing post-deadline time extension.
///
/// SECURITY: Requires &Clock which is passed to the oracle to prevent future-timestamp
/// attacks that would brick the oracle (see conditional_amm::get_twap_at).
/// SECURITY: Lifecycle-gated — only callable during live trading.
/// SECURITY: target_time must equal the market's scheduled trading_end.
public fun get_twaps_for_proposal_at<AssetType, StableType, LPType>(
    proposal: &mut Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    target_time: u64,
    clock: &Clock,
): vector<u128> {
    assert!(is_live(proposal), EInvalidState);

    let spot_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    let escrow = unified_spot_pool::borrow_active_escrow_mut(spot_pool, &spot_auth);
    assert_escrow_matches_proposal(proposal, escrow);

    let auth = escrow_mutation_auth::create(escrow_registry, EscrowMutationWitness {});
    let ms_auth = market_state_mutation_auth::create(
        market_state_registry,
        MarketStateMutationWitness {},
    );
    let market_state = coin_escrow::get_market_state_mut(escrow, &auth);

    // SECURITY: The frozen TWAP API exists only for the scheduled trading_end.
    // Allowing arbitrary target_time values creates an unnecessary public state
    // mutation surface on the oracle and can desynchronize callers from the
    // lifecycle's single source of truth for finalization.
    let trading_end_opt = market_state::get_trading_end_time(market_state);
    assert!(trading_end_opt.is_some(), EInvalidLifecycleState);
    assert!(target_time == *trading_end_opt.borrow(), EInvalidTwapTarget);

    let mut twaps = vector[];
    let outcome_count = market_state::outcome_count(market_state);
    let mut i = 0;
    while (i < outcome_count) {
        let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
        let twap = pool.get_twap_at(target_time, clock, &ms_auth);
        twaps.push_back(twap);
        i = i + 1;
    };
    twaps
}

// === Private Functions ===

/// Helper function to validate proposal-escrow relationship.
/// Prevents cross-market attacks by ensuring the escrow belongs to this proposal.
/// Uses bidirectional validation: proposal→escrow AND escrow→proposal.
fun assert_escrow_matches_proposal<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    // Forward check: proposal's stored market_state_id matches escrow's embedded MarketState
    assert!(
        coin_escrow::market_state_id(escrow) == market_state_id(proposal),
        EProposalEscrowMismatch,
    );
    // Reverse check: MarketState's proposal_id and dao_id point back to this proposal
    let ms = coin_escrow::get_market_state(escrow);
    assert!(market_state::proposal_id(ms) == object::id(proposal), EProposalEscrowMismatch);
    assert!(market_state::dao_id(ms) == proposal.dao_id, EProposalEscrowMismatch);
}

// === View Functions ===

public fun is_finalized<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    proposal.state == STATE_FINALIZED
}

public fun get_twap_prices<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &vector<u128> {
    &proposal.twap_config.twap_prices
}

public fun get_last_twap_update<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.timing.last_twap_update
}

/// Get TWAP for a specific outcome by index
public fun get_twap_by_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): u128 {
    // Add defensive checks
    assert!(proposal.state == STATE_FINALIZED, ENotFinalized);
    let twap_prices = &proposal.twap_config.twap_prices;
    assert!(!twap_prices.is_empty(), ETwapNotSet);
    assert!(outcome_index < twap_prices.length(), EOutcomeOutOfBounds);
    *twap_prices.borrow(outcome_index)
}

/// Get the TWAP of the winning outcome
public fun get_winning_twap<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u128 {
    // Add defensive checks
    assert!(proposal.state == STATE_FINALIZED, ENotFinalized);
    assert!(proposal.outcome_data.winning_outcome.is_some(), EInvalidState);
    assert!(!proposal.twap_config.twap_prices.is_empty(), ETwapNotSet);
    let winning_outcome = *proposal.outcome_data.winning_outcome.borrow();
    get_twap_by_outcome(proposal, winning_outcome)
}

/// NOTE: `get_state()` is an equivalent getter used by governance sources;
/// `state()` is the canonical name used by tests and integration_tests.
public fun state<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u8 {
    proposal.state
}

/// Check if proposal is currently live (trading active)
/// Trading remains active during both TRADING and AWAITING_EXECUTION states
public fun is_live<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    proposal.state == STATE_TRADING || proposal.state == STATE_AWAITING_EXECUTION
}

/// Check if proposal is in the execution window
public fun is_awaiting_execution<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    proposal.state == STATE_AWAITING_EXECUTION
}

/// Get the execution window duration in milliseconds (30 minutes)
public fun execution_window_ms(): u64 {
    constants::execution_window_ms()
}

/// Get state constant for PREMARKET
public fun state_premarket(): u8 {
    STATE_PREMARKET
}

/// Get state constant for REVIEW
public fun state_review(): u8 {
    STATE_REVIEW
}

/// Get state constant for TRADING
public fun state_trading(): u8 {
    STATE_TRADING
}

/// Get state constant for AWAITING_EXECUTION
public fun state_awaiting_execution(): u8 {
    STATE_AWAITING_EXECUTION
}

/// Get state constant for FINALIZED
public fun state_finalized(): u8 {
    STATE_FINALIZED
}

/// Get sponsorship type constant for NONE (not sponsored)
public fun sponsorship_none(): u8 {
    SPONSORSHIP_NONE
}

/// Get sponsorship type constant for ZERO_THRESHOLD (just needs TWAP >= reject)
public fun sponsorship_zero_threshold(): u8 {
    SPONSORSHIP_ZERO_THRESHOLD
}

/// Get sponsorship type constant for NEGATIVE_DISCOUNT (can be below reject by sponsored_threshold%)
public fun sponsorship_negative_discount(): u8 {
    SPONSORSHIP_NEGATIVE_DISCOUNT
}

public fun get_winning_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    assert!(proposal.outcome_data.winning_outcome.is_some(), EInvalidState);
    *proposal.outcome_data.winning_outcome.borrow()
}

/// Checks if winning outcome has been set
public fun is_winning_outcome_set<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    proposal.outcome_data.winning_outcome.is_some()
}

public fun get_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.id.to_inner()
}

public fun escrow_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    assert!(proposal.escrow_id.is_some(), EInvalidState);
    *proposal.escrow_id.borrow()
}

public fun market_state_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    assert!(proposal.market_state_id.is_some(), EInvalidState);
    *proposal.market_state_id.borrow()
}

public fun get_market_initialized_at<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    assert!(proposal.timing.market_initialized_at.is_some(), EInvalidState);
    *proposal.timing.market_initialized_at.borrow()
}

public fun get_trading_started_at<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    assert!(proposal.timing.trading_started_at.is_some(), EInvalidState);
    *proposal.timing.trading_started_at.borrow()
}

public fun outcome_count<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.outcome_data.outcome_count
}

/// Alias for outcome_count for better readability
public fun get_num_outcomes<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.outcome_data.outcome_count
}

public fun get_metadata<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &String {
    &proposal.metadata
}

public fun get_introduction_details<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &String {
    &proposal.introduction_details
}

public fun get_amm_pool_ids<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
): vector<ID> {
    assert_escrow_matches_proposal(proposal, escrow);
    let mut ids = vector[];
    let mut i = 0;
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let len = pools.length();
    while (i < len) {
        let pool = &pools[i];
        ids.push_back(pool.get_id());
        i = i + 1;
    };
    ids
}

public fun get_pool_by_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
): &LiquidityPool {
    assert_escrow_matches_proposal(proposal, escrow);
    assert!((outcome_idx as u64) < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let mut i = 0;
    let len = pools.length();
    while (i < len) {
        let pool = &pools[i];
        if (pool.get_outcome_idx() == outcome_idx) {
            return pool
        };
        i = i + 1;
    };
    abort EPoolNotFound
}

public fun get_state<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u8 {
    proposal.state
}

public fun get_dao_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.dao_id
}

public fun used_feeless_quota<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    proposal.used_feeless_quota
}

public fun proposal_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.id.to_inner()
}

public fun get_amm_pools<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
): &vector<LiquidityPool> {
    assert_escrow_matches_proposal(proposal, escrow);
    let market_state = coin_escrow::get_market_state(escrow);
    market_state::borrow_amm_pools(market_state)
}

public fun get_created_at<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.timing.created_at
}

public fun get_review_period_ms<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.timing.review_period_ms
}

public fun get_trading_period_ms<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.timing.trading_period_ms
}

public fun get_twap_threshold<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u128 {
    proposal.twap_config.twap_threshold
}

public fun get_sponsored_threshold<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u128 {
    proposal.twap_config.sponsored_threshold
}

public fun get_twap_start_delay<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.timing.twap_start_delay
}

public fun get_twap_initial_observation<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): Option<u128> {
    proposal.twap_config.twap_initial_observation
}

public fun get_twap_cap_ppm<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.twap_config.twap_cap_ppm
}

/// Get full oracle state for a specific outcome by index (read-only, for debugging/monitoring)
/// outcome_idx: 0 = REJECT, 1 = ACCEPT
/// Returns: (last_price, last_timestamp, total_cumulative_price, last_window_end_cumulative_price,
///   last_window_end, last_window_twap, market_start_time, twap_initialization_price,
///   twap_start_delay, twap_cap_step, asset_reserve, stable_reserve)
public fun get_oracle_state_by_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
): (
    u128, // last_price
    u64,  // last_timestamp
    u256, // total_cumulative_price
    u256, // last_window_end_cumulative_price
    u64,  // last_window_end
    u128, // last_window_twap
    Option<u64>, // market_start_time
    u128, // twap_initialization_price
    u64,  // twap_start_delay
    u64,  // twap_cap_step
    u64,  // asset_reserve
    u64,  // stable_reserve
) {
    assert_escrow_matches_proposal(proposal, escrow);
    assert!((outcome_idx as u64) < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);

    let pool = &pools[outcome_idx as u64];
    let (
        last_price,
        last_timestamp,
        total_cumulative_price,
        last_window_end_cumulative_price,
        last_window_end,
        last_window_twap,
        market_start_time,
        twap_initialization_price,
        twap_start_delay,
        twap_cap_step,
    ) = conditional_amm::get_oracle_full_state(pool);
    let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(pool);

    (
        last_price,
        last_timestamp,
        total_cumulative_price,
        last_window_end_cumulative_price,
        last_window_end,
        last_window_twap,
        market_start_time,
        twap_initialization_price,
        twap_start_delay,
        twap_cap_step,
        asset_reserve,
        stable_reserve,
    )
}

public fun get_amm_total_fee_bps<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.amm_total_fee_bps
}

fun derive_twap_initial_observation_from_spot_pool<AssetType, StableType, LPType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): Option<u128> {
    let (initial_asset_opt, initial_stable_opt) = unified_spot_pool::get_initial_reserves(spot_pool);
    if (initial_asset_opt.is_some() && initial_stable_opt.is_some()) {
        let initial_asset = *initial_asset_opt.borrow();
        let initial_stable = *initial_stable_opt.borrow();
        if (initial_asset > 0 && initial_stable > 0) {
            option::some(math::mul_div_to_128(
                initial_stable,
                constants::price_precision_scale(),
                initial_asset,
            ))
        } else {
            option::none()
        }
    } else {
        option::none()
    }
}


// === Package Functions ===

/// Advances the proposal state based on elapsed time
/// Transitions from REVIEW to TRADING when review period ends
/// Returns true if state was changed OR if trading period has ended (signaling readiness for execution)
/// SECURITY: Requires ProposalMutationAuth so only lifecycle wrappers can trigger
/// this transition and its oracle/market setup side effects.
/// SECURITY: Requires MarketStateMutationRegistry and EscrowMutationRegistry for authorized state changes.
/// SECURITY: Validates spot pool identity against expected DAO pool ID.
public fun advance_state<AssetType, StableType, LPType>(
    proposal: &mut Proposal<AssetType, StableType>,
    auth: &ProposalMutationAuth,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    market_state_registry: &MarketStateMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    spot_pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    expected_spot_pool_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    // SECURITY: Validate the spot pool is the one registered for this DAO.
    // Prevents callers from passing a different pool to manipulate the TWAP seed.
    assert!(object::id(spot_pool) == expected_spot_pool_id, ESpotPoolMismatch);
    // Validate escrow belongs to this proposal (prevents cross-market attacks)
    assert_escrow_matches_proposal(proposal, escrow);

    let current_time = clock.timestamp_ms();
    // Use market_initialized_at for timing calculations instead of created_at
    // This ensures premarket proposals get proper review/trading periods after initialization
    let base_timestamp = if (proposal.timing.market_initialized_at.is_some()) {
        *proposal.timing.market_initialized_at.borrow()
    } else {
        // Fallback to created_at if market not initialized (shouldn't happen in normal flow)
        proposal.timing.created_at
    };

    // Check if we should transition from REVIEW to TRADING
    if (proposal.state == STATE_REVIEW) {
        let review_end = base_timestamp + proposal.timing.review_period_ms;
        if (current_time >= review_end) {
            proposal.state = STATE_TRADING;
            // Use actual crank time so cranker downtime does not shrink or erase
            // the configured trading/TWAP window.
            let trading_start = current_time;
            proposal.timing.trading_started_at = option::some(trading_start);

            // Create auth for market state mutation
            let market_auth = market_state_mutation_auth::create(
                market_state_registry,
                MarketStateMutationWitness {},
            );

            // Create auth for escrow mutation
            let escrow_auth = escrow_mutation_auth::create(escrow_registry, EscrowMutationWitness {});

            // Use the DAO config's TWAP initial observation:
            // - First proposal: set at DAO creation (initialization price)
            // - Subsequent proposals: previous winning outcome's TWAP
            //   (written back to config via set_twap_initial_observation_from_execution)
            // This avoids using instantaneous spot reserves which are vulnerable
            // to flash loan / sandwich manipulation in the same PTB.
            let mut twap_initial_observation = proposal.twap_config.twap_initial_observation;
            if (twap_initial_observation.is_none()) {
                // Legacy/default DAOs may not have an explicit seed. Fall back to the spot
                // pool's immutable initial reserves rather than live reserves.
                twap_initial_observation = derive_twap_initial_observation_from_spot_pool(spot_pool);
                if (twap_initial_observation.is_some()) {
                    proposal.twap_config.twap_initial_observation = twap_initial_observation;
                };
            };

            // Create empty conditional AMM pools and store them in MarketState
            let amm_pools = liquidity_initialize::create_outcome_markets<AssetType, StableType>(
                escrow,
                proposal.outcome_data.outcome_count,
                proposal.timing.twap_start_delay,
                twap_initial_observation,
                proposal.twap_config.twap_cap_ppm,
                proposal.amm_total_fee_bps,
                &market_auth,
                clock,
                ctx,
            );
            let market = coin_escrow::get_market_state_mut(escrow, &escrow_auth);
            market_state::set_amm_pools(market, amm_pools, &market_auth);

            market_state::start_trading(
                market,
                proposal.timing.trading_period_ms,
                trading_start,
                clock,
                &market_auth,
            );

            // Keep oracle timing aligned with MarketState.
            let market_id = market_state::market_id(market);
            let outcome_count = market_state::outcome_count(market);
            let mut i = 0;
            while (i < outcome_count) {
                let pool = market_state::get_pool_mut_by_outcome(market, i, &escrow_auth);
                conditional_amm::set_oracle_start_time(
                    pool,
                    market_id,
                    trading_start,
                    clock,
                    &market_auth,
                );
                i = i + 1;
            };

            // NOTE: Quantum split and registration happens in proposal_lifecycle

            return true
        };
    };

    // Check if trading period has ended (for execution-required finalization)
    // NOTE: We do NOT call end_trading() here anymore. The transition from TRADING to
    // AWAITING_EXECUTION must go through end_trading_and_start_execution_window()
    // which atomically ends trading AND starts the execution window. This ensures
    // there's no gap where swaps are blocked (trading ended but execution not started).
    if (proposal.state == STATE_TRADING) {
        let trading_start = *proposal.timing.trading_started_at.borrow();
        let trading_end = trading_start + proposal.timing.trading_period_ms;
        if (current_time >= trading_end) {
            // Signal that trading period has ended and execution window can be started.
            // The actual transition happens via end_trading_and_start_execution_window()
            // in proposal_lifecycle.move.
            return true
        };
    };

    false
}

/// Set the proposal state.
/// SECURITY: Requires ProposalMutationAuth from an authorized package.
/// Defense-in-depth: enforces sequential state transitions with one allowed skip
/// (TRADING → FINALIZED for market rejection).
public fun set_state<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    new_state: u8,
    auth: ProposalMutationAuth,
) {
    assert!(proposal_mutation_auth::target_id(&auth) == object::id(proposal), EAuthTargetMismatch);
    assert!(new_state <= STATE_FINALIZED, EInvalidStateTransition);
    assert!(
        new_state == proposal.state + 1 ||
        (proposal.state == STATE_TRADING && new_state == STATE_FINALIZED),
        EInvalidStateTransition,
    );
    proposal.state = new_state;
}

/// Set the TWAP prices after trading ends.
/// SECURITY: Requires ProposalMutationAuth from an authorized package.
public fun set_twap_prices<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    twap_prices: vector<u128>,
    auth: &ProposalMutationAuth,
) {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    // Validate TWAP prices vector length matches outcome count
    assert!(
        vector::length(&twap_prices) == proposal.outcome_data.outcome_count,
        EOutcomeCountMismatch,
    );
    proposal.twap_config.twap_prices = twap_prices;
}

/// Set the last TWAP update timestamp.
/// SECURITY: Requires ProposalMutationAuth from an authorized package.
public fun set_last_twap_update<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    timestamp: u64,
    auth: &ProposalMutationAuth,
) {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    proposal.timing.last_twap_update = timestamp;
}

/// Set the winning outcome after TWAP resolution.
/// SECURITY: Requires ProposalMutationAuth from an authorized package.
public fun set_winning_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome: u64,
    auth: &ProposalMutationAuth,
) {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    // Validate outcome is within bounds
    assert!(outcome < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    proposal.outcome_data.winning_outcome = option::some(outcome);
}

/// Finalize the proposal with the winning outcome computed on-chain (test helper)
/// This combines computing the winner from TWAP, setting the winning outcome and updating state atomically
///
/// THRESHOLD LOGIC:
/// - threshold_config is a numerator with base 100,000
/// - required_threshold = reject_twap + (threshold_config * reject_twap / 100,000)
/// - Example: threshold_config = 1000 means 1% above reject TWAP
///
/// SPONSORSHIP LOGIC:
/// - Sponsored outcomes: passes if TWAP >= reject TWAP
/// - Unsponsored outcomes: passes if TWAP > required_threshold
///
/// MULTI-OUTCOME:
/// - Winner = outcome with highest TWAP among those that pass
/// - If no outcome passes, REJECT (0) wins by default
#[test_only]
public fun test_finalize_with_winner<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
) {
    // Ensure we're in a state that can be finalized
    assert!(proposal.state == STATE_TRADING || proposal.state == STATE_REVIEW, EInvalidState);

    // If in review, promote to trading so lifecycle-gated TWAP functions work
    if (proposal.state == STATE_REVIEW) {
        proposal.state = STATE_TRADING;
    };

    // End trading if still active
    {
        let auth = escrow_mutation_auth::create(escrow_registry, EscrowMutationWitness {});
        let market = coin_escrow::get_market_state_mut(escrow, &auth);
        if (market_state::is_trading_active(market)) {
            market_state::end_trading_for_testing(market, clock);
        };
    };

    // Get TWAP prices from all pools (inline for test — production uses spot pool path)
    let twap_prices = {
        let auth = escrow_mutation_auth::create(escrow_registry, EscrowMutationWitness {});
        let ms_auth = market_state_mutation_auth::create(
            market_state_registry,
            MarketStateMutationWitness {},
        );
        let market_state = coin_escrow::get_market_state_mut(escrow, &auth);
        let trading_end_opt = market_state::get_trading_end_time(market_state);
        assert!(trading_end_opt.is_some(), EInvalidLifecycleState);
        assert!(clock.timestamp_ms() <= *trading_end_opt.borrow(), EOracleUpdatePastTradingEnd);
        let mut twaps = vector[];
        let outcome_count = market_state::outcome_count(market_state);
        let mut i = 0;
        while (i < outcome_count) {
            let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
            let twap = pool.get_twap(clock, &ms_auth);
            twaps.push_back(twap);
            i = i + 1;
        };
        twaps
    };
    let num_outcomes = twap_prices.length();

    // Store TWAP prices in proposal for later access via get_twap_by_outcome/get_winning_twap
    proposal.twap_config.twap_prices = twap_prices;

    // Get threshold config (numerator with base 100,000)
    let threshold_config = proposal.twap_config.twap_threshold;
    let sponsored_threshold = proposal.twap_config.sponsored_threshold;

    // Get reject TWAP (outcome 0) - used as reference for all outcomes
    let reject_twap = if (num_outcomes > 0) {
        *proposal.twap_config.twap_prices.borrow(0)
    } else {
        0u128
    };

    // Calculate required threshold for unsponsored: reject_twap + (threshold_config * reject_twap / 100,000)
    let required_threshold = reject_twap + (threshold_config * reject_twap / constants::twap_threshold_base());

    // Calculate negative discount threshold: reject_twap - (sponsored_threshold * reject_twap / 100,000)
    let negative_discount_threshold = if (sponsored_threshold * reject_twap / constants::twap_threshold_base() > reject_twap) {
        0u128 // Prevent underflow
    } else {
        reject_twap - (sponsored_threshold * reject_twap / constants::twap_threshold_base())
    };

    // Find the winning outcome among all outcomes (except REJECT)
    let mut winning_outcome = OUTCOME_REJECTED; // Default to reject
    let mut highest_twap = 0u128;

    // Start from outcome 1 (skip REJECT which is outcome 0)
    let mut i = 1u64;
    while (i < num_outcomes) {
        let outcome_twap = *proposal.twap_config.twap_prices.borrow(i);

        // Determine if this outcome passes based on sponsorship type
        let sponsorship_type = get_outcome_sponsorship_type(proposal, i);
        let passes = if (sponsorship_type == SPONSORSHIP_ZERO_THRESHOLD) {
            // Zero threshold: just needs to beat or equal reject TWAP
            outcome_twap >= reject_twap
        } else if (sponsorship_type == SPONSORSHIP_NEGATIVE_DISCOUNT) {
            // Negative discount: can pass with TWAP >= reject - sponsored_threshold%
            outcome_twap >= negative_discount_threshold
        } else {
            // Unsponsored (SPONSORSHIP_NONE): needs to strictly beat reject TWAP + threshold margin
            outcome_twap > required_threshold
        };

        // Check if this outcome passes and has the highest TWAP
        if (passes && outcome_twap > highest_twap) {
            highest_twap = outcome_twap;
            winning_outcome = i;
        };

        i = i + 1;
    };

    // Set the winning outcome
    proposal.outcome_data.winning_outcome = option::some(winning_outcome);

    // Update state to finalized
    proposal.state = STATE_FINALIZED;

    // Finalize the market state (using test helper since this is test-only)
    let auth = escrow_mutation_auth::create(escrow_registry, EscrowMutationWitness {});
    let market = coin_escrow::get_market_state_mut(escrow, &auth);
    market_state::finalize_test(market, winning_outcome, clock);
}

public fun get_outcome_creators<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &vector<address> {
    &proposal.outcome_data.outcome_creators
}

/// Get the address of the creator for a specific outcome
public fun get_outcome_creator<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): address {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    *vector::borrow(&proposal.outcome_data.outcome_creators, outcome_index)
}

/// Get the total fee paid by proposer (for refunds)
public fun get_total_fee_paid<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.total_fee_paid
}

/// Check if the trading period has ended based on current time
/// Returns true if current_time >= trading_end
public fun is_trading_period_ended<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    clock: &Clock,
): bool {
    // Trading cannot have ended if it never started
    if (proposal.timing.trading_started_at.is_none()) {
        return false
    };
    let current_time = clock.timestamp_ms();
    let trading_start = *proposal.timing.trading_started_at.borrow();
    let trading_end = trading_start + proposal.timing.trading_period_ms;
    current_time >= trading_end
}

public fun get_liquidity_provider<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): Option<address> {
    proposal.liquidity_provider
}

public fun get_proposer<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): address {
    proposal.proposer
}

/// Check if this proposal used feeless quota (excludes from creator rewards)
public fun get_used_feeless_quota<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    proposal.used_feeless_quota
}

/// Check if this proposal's liquidity is in withdraw-only mode
public fun is_withdraw_only<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    proposal.withdraw_only_mode
}

/// Set withdraw-only mode - prevents auto-reinvestment in next proposal
/// Only callable by the liquidity provider
public entry fun set_withdraw_only_mode<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    withdraw_only: bool,
    ctx: &TxContext,
) {
    // Only callable during REVIEW (after finalize_proposal sets the liquidity_provider).
    // PREMARKET is excluded because liquidity_provider is None until finalize_proposal.
    assert!(proposal.state == STATE_REVIEW, EInvalidLifecycleState);
    assert!(proposal.liquidity_provider.is_some(), ENotLiquidityProvider);
    let provider = *proposal.liquidity_provider.borrow();
    assert!(tx_context::sender(ctx) == provider, ENotLiquidityProvider);
    proposal.withdraw_only_mode = withdraw_only;
}

public fun get_outcome_messages<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &vector<String> {
    &proposal.outcome_data.outcome_messages
}

/// Get the intent spec for a specific outcome
public fun get_intent_spec_for_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): &Option<vector<ActionSpec>> {
    vector::borrow(&proposal.outcome_data.intent_specs, outcome_index)
}

fun can_take_intent_spec_in_state(state: u8): bool {
    state == STATE_AWAITING_EXECUTION || state == STATE_FINALIZED
}

/// Take (move out) the intent spec for a specific outcome and clear the slot.
/// SECURITY: Requires ProposalMutationAuth from an authorized package.
/// Allowed in AWAITING_EXECUTION or FINALIZED states.
/// Also resets actions_per_outcome to 0 for consistency with cleared slot.
public fun take_intent_spec_for_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    auth: &ProposalMutationAuth,
): Option<vector<ActionSpec>> {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    // Do not allow this while markets are actively trading. REJECT fast-path cleanup
    // must finalize the proposal first, then clear losing intent specs.
    assert!(can_take_intent_spec_in_state(proposal.state), EInvalidLifecycleState);
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    let slot = vector::borrow_mut(&mut proposal.outcome_data.intent_specs, outcome_index);
    let old_value = *slot;
    *slot = option::none();
    // Reset action count to 0 for consistency (prevents dirty state where counter claims
    // actions exist but Option is None)
    let action_count_slot = vector::borrow_mut(
        &mut proposal.outcome_data.actions_per_outcome,
        outcome_index,
    );
    *action_count_slot = 0;
    old_value
}

/// Mint a scoped cancel witness by taking (moving) the spec out of the slot.
/// Returns None if no spec was set for that outcome.
/// This witness can only be created once per (proposal, outcome) pair.
/// SECURITY: Requires ProposalMutationAuth from an authorized package.
/// Allowed in AWAITING_EXECUTION or FINALIZED states.
public fun make_cancel_witness<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    auth: &ProposalMutationAuth,
): option::Option<CancelWitness> {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    // Lifecycle check is enforced by take_intent_spec_for_outcome
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    let addr = object::uid_to_address(&proposal.id);
    // take_intent_spec_for_outcome already resets action count to 0
    let spec_opt = take_intent_spec_for_outcome(proposal, outcome_index, auth);
    if (option::is_some(&spec_opt)) {
        option::destroy_some(spec_opt);
        option::some(CancelWitness {
            proposal: addr,
            outcome_index,
        })
    } else {
        option::none<CancelWitness>()
    }
}

/// Create a new action spec builder for this proposal outcome.
/// Used by PTBs to build action specs with correct event context.
/// The builder carries source_type (proposal), source_id (proposal ID), and outcome_index.
public fun new_action_builder<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): Builder {
    action_spec_builder::new(
        action_events::source_proposal(),
        object::id(proposal),
        outcome_index,
    )
}

/// Set the intent spec for a specific outcome and track action count
/// This function:
/// 1. Validates proposal is in PREMARKET state
/// 2. Validates ALL action types are from authorized packages (STAGING-TIME CHECK)
/// 3. Validates the IntentSpec action count
/// 4. Stores the IntentSpec in the outcome slot
/// NOTE: Outcome 0 (REJECT) cannot have actions - it represents "do nothing" / status quo
///
/// SECURITY: Requires ProposalMutationAuth from an authorized package.
/// SECURITY: The staging-time whitelist check prevents the attack where:
/// - Action 1: ToggleUnverifiedAllowed (enables unregistered packages)
/// - Action 2: MaliciousAction from unregistered package
/// By checking at staging time, the CURRENT unverified_allowed value is used,
/// so Action 1 hasn't executed yet and can't help the attacker.
public fun set_intent_spec_for_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    intent_spec: vector<ActionSpec>,
    max_actions_per_outcome: u64,
    // Whitelist validation parameters
    account: &Account,
    registry: &PackageRegistry,
    auth: &ProposalMutationAuth,
) {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    // Enforce the DAO config's max_actions_per_outcome as upper bound,
    // regardless of what the caller passes.
    let futarchy_cfg: &futarchy_config::FutarchyConfig = account::config(account);
    let config_max = futarchy_config::max_actions_per_outcome(futarchy_cfg);
    let effective_max = if (max_actions_per_outcome < config_max) {
        max_actions_per_outcome
    } else {
        config_max
    };
    set_intent_spec_for_outcome_internal<AssetType, StableType>(
        proposal,
        outcome_index,
        intent_spec,
        effective_max,
        account,
        registry,
    );
}

/// Internal implementation for setting an intent spec.
/// This is shared by both staged-action updates and atomic proposal creation.
fun set_intent_spec_for_outcome_internal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    intent_spec: vector<ActionSpec>,
    max_actions_per_outcome: u64,
    account: &Account,
    registry: &PackageRegistry,
) {
    // Only allow during premarket (before trading starts)
    assert!(proposal.state == STATE_PREMARKET, EInvalidLifecycleState);
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);

    // SECURITY: Validate account belongs to the proposal's DAO.
    // Without this, an attacker could pass a different DAO's account with a more
    // permissive package whitelist to bypass action authorization checks.
    assert!(object::id(account) == proposal.dao_id, EDaoAccountMismatch);

    // SECURITY: Validate registry belongs to this DAO account.
    // Without this, an attacker could pass a registry from a different DAO
    // with different whitelist rules, bypassing package authorization.
    // (Mirrors the check in begin_proposal_internal.)
    assert!(
        deps::registry_id(account::deps(account)) == object::id(registry),
        ERegistryMismatch,
    );

    // Outcome 0 (REJECT) cannot have actions - it represents the status quo / "do nothing"
    assert!(outcome_index > 0, ECannotSetActionsForRejectOutcome);

    // SECURITY: Validate ALL action types are from authorized packages at STAGING time
    // This uses the CURRENT value of unverified_allowed, not a future value that
    // might be toggled by an action in this same proposal.
    let deps = account.deps();
    let account_deps = account.account_deps();
    let num_actions = vector::length(&intent_spec);

    let mut i = 0;
    while (i < num_actions) {
        let action_spec = vector::borrow(&intent_spec, i);
        let action_type = intents::action_spec_type(action_spec);
        // Extract package address from TypeName (format: "0xABCD::module::Type")
        let package_addr = address::from_bytes(
            hex::decode(action_type.address_string().into_bytes()),
        );
        // Check package is authorized (global registry OR per-account deps)
        assert!(
            deps::is_package_authorized(
                deps,
                registry,
                account_deps,
                package_addr,
                object::id(account),
            ),
            EActionPackageNotAuthorized,
        );
        i = i + 1;
    };

    let spec_slot = vector::borrow_mut(&mut proposal.outcome_data.intent_specs, outcome_index);
    let action_count = vector::borrow_mut(
        &mut proposal.outcome_data.actions_per_outcome,
        outcome_index,
    );

    // Check outcome limit only
    assert!(num_actions <= max_actions_per_outcome, ETooManyActions);

    // Set the intent spec and update count
    let (action_types, action_versions, action_data) = action_events::collect_action_spec_fields(&intent_spec);
    *spec_slot = option::some(intent_spec);
    *action_count = num_actions;

    event::emit(ProposalActionsStaged {
        proposal_id: object::id(proposal),
        outcome_index,
        action_types,
        action_versions,
        action_data,
    });
}

/// Check if an outcome has an intent spec
public fun has_intent_spec<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): bool {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    option::is_some(vector::borrow(&proposal.outcome_data.intent_specs, outcome_index))
}

/// Get the number of actions for a specific outcome
public fun get_actions_for_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    *vector::borrow(&proposal.outcome_data.actions_per_outcome, outcome_index)
}

/// Clear the intent spec for an outcome and reset action count.
/// SECURITY: Requires ProposalMutationAuth from an authorized package.
/// Only allowed in PREMARKET state (before market initialization).
public fun clear_intent_spec_for_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    auth: &ProposalMutationAuth,
) {
    assert!(proposal_mutation_auth::target_id(auth) == object::id(proposal), EAuthTargetMismatch);
    // Only allow during premarket (before trading starts)
    assert!(proposal.state == STATE_PREMARKET, EInvalidLifecycleState);
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);

    let spec_slot = vector::borrow_mut(&mut proposal.outcome_data.intent_specs, outcome_index);
    let action_count = vector::borrow_mut(
        &mut proposal.outcome_data.actions_per_outcome,
        outcome_index,
    );

    if (option::is_some(spec_slot)) {
        // Clear the intent spec
        *spec_slot = option::none();

        // Reset this outcome's action count
        *action_count = 0;
    };
}

// === Test Functions ===

#[test_only]
/// Create a minimal proposal for testing
public fun new_for_testing<AssetType, StableType>(
    dao_id: address,
    proposer: address,
    liquidity_provider: Option<address>,
    title: String,
    introduction_details: String,
    metadata: String,
    outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    outcome_creators: vector<address>,
    outcome_count: u8,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    twap_start_delay: u64,
    twap_initial_observation: Option<u128>,
    twap_cap_ppm: u64,
    twap_threshold: u128,
    amm_total_fee_bps: u64,
    max_outcomes: u64,
    winning_outcome: Option<u64>,
    intent_specs: vector<Option<vector<ActionSpec>>>,
    ctx: &mut TxContext,
): Proposal<AssetType, StableType> {
    Proposal {
        id: object::new(ctx),
        dao_id: object::id_from_address(dao_id),
        state: STATE_PREMARKET,
        proposer,
        liquidity_provider,
        withdraw_only_mode: false,
        used_feeless_quota: false, // Default to false for testing
        outcome_sponsorship: vector::tabulate!(outcome_count as u64, |_| SPONSORSHIP_NONE),
        sponsor_quota_used_for_proposal: false,
        sponsor_quota_user: option::none(),
        escrow_id: option::none(),
        market_state_id: option::none(),
        conditional_treasury_caps: bag::new(ctx),
        conditional_metadata_caps: bag::new(ctx),
        conditional_asset_types: vector::tabulate!(outcome_count as u64, |_| ascii::string(b"")),
        conditional_stable_types: vector::tabulate!(outcome_count as u64, |_| ascii::string(b"")),
        title,
        introduction_details,
        details: initial_outcome_details,
        metadata,
        timing: ProposalTiming {
            created_at: 0,
            market_initialized_at: option::none(),
            trading_started_at: option::none(),
            review_period_ms,
            trading_period_ms,
            last_twap_update: 0,
            twap_start_delay,
        },
        liquidity_config: LiquidityConfig {
            min_asset_liquidity,
            min_stable_liquidity,
            asset_amounts: vector::empty(),
            stable_amounts: vector::empty(),
        },
        twap_config: TwapConfig {
            twap_prices: vector::empty(),
            twap_initial_observation,
            twap_cap_ppm,
            twap_threshold,
            sponsored_threshold: 0, // Default: no discount for sponsored outcomes in tests
        },
        outcome_data: OutcomeData {
            outcome_count: outcome_count as u64,
            outcome_messages,
            outcome_creators,
            intent_specs,
            actions_per_outcome: vector::tabulate!(outcome_count as u64, |_| 0),
            winning_outcome,
        },
        amm_total_fee_bps,
        conditional_liquidity_ratio_percent: 50, // 50% (base 100, not bps!)
        fee_escrow: bag::new(ctx), // Empty bag for test proposals (no fees)
        fee_paid_in_asset: false, // Default to stable type for testing
        total_fee_paid: 0, // No fees for test proposals
        max_outcomes,
    }
}

#[test_only]
/// Set the state of a proposal for testing
public fun set_state_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    new_state: u8,
) {
    proposal.state = new_state;
}

#[test_only]
/// Set the escrow_id of a proposal for testing
public fun set_escrow_id_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow_id: ID,
) {
    proposal.escrow_id = option::some(escrow_id);
}

#[test_only]
/// Set the market_state_id of a proposal for testing
public fun set_market_state_id_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    market_state_id: ID,
) {
    proposal.market_state_id = option::some(market_state_id);
}

#[test_only]
/// Set the created_at timestamp of a proposal for testing.
public fun set_created_at_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    created_at_ms: u64,
) {
    proposal.timing.created_at = created_at_ms;
}

#[test_only]
/// Set the market initialization timestamp for testing.
public fun set_market_initialized_at_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    initialized_at_ms: u64,
) {
    proposal.timing.market_initialized_at = option::some(initialized_at_ms);
}

#[test_only]
/// Set the trading started timestamp for testing.
public fun set_trading_started_at_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    trading_started_at_ms: u64,
) {
    proposal.timing.trading_started_at = option::some(trading_started_at_ms);
}

#[test_only]
public fun set_twap_start_delay_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    twap_start_delay_ms: u64,
) {
    proposal.timing.twap_start_delay = twap_start_delay_ms;
}

#[test_only]
/// Set TWAP initial observation for testing (simulates DAO config value).
public fun set_twap_initial_observation_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    obs: Option<u128>,
) {
    proposal.twap_config.twap_initial_observation = obs;
}

#[test_only]
/// Set withdraw-only mode directly for cross-package regression tests.
public fun set_withdraw_only_mode_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    withdraw_only: bool,
) {
    proposal.withdraw_only_mode = withdraw_only;
}

#[test_only]
/// Put a stable fee balance into the proposal's fee escrow for testing.
public fun put_fee_escrow_stable_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    fee_balance: Balance<StableType>,
) {
    // Remove any existing stable fee escrow (tests should keep types consistent).
    if (bag::contains(&proposal.fee_escrow, FeeBalanceKey {})) {
        let old: Balance<StableType> = bag::remove(&mut proposal.fee_escrow, FeeBalanceKey {});
        balance::destroy_for_testing(old);
    };
    proposal.fee_paid_in_asset = false;
    bag::add(&mut proposal.fee_escrow, FeeBalanceKey {}, fee_balance);
}

#[test_only]
/// Put an asset fee balance into the proposal's fee escrow for testing.
public fun put_fee_escrow_asset_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    fee_balance: Balance<AssetType>,
) {
    // Remove any existing asset fee escrow (tests should keep types consistent).
    if (bag::contains(&proposal.fee_escrow, FeeBalanceKey {})) {
        let old: Balance<AssetType> = bag::remove(&mut proposal.fee_escrow, FeeBalanceKey {});
        balance::destroy_for_testing(old);
    };
    proposal.fee_paid_in_asset = true;
    bag::add(&mut proposal.fee_escrow, FeeBalanceKey {}, fee_balance);
}

#[test_only]
/// Gets a mutable reference to the token escrow of the proposal
public fun test_get_coin_escrow<AssetType, StableType>(
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
): &mut coin_escrow::TokenEscrow<AssetType, StableType> {
    escrow
}

#[test_only]
/// Gets the market state through the token escrow
public fun test_get_market_state<AssetType, StableType>(
    escrow: &coin_escrow::TokenEscrow<AssetType, StableType>,
): &market_state::MarketState {
    escrow.get_market_state()
}

#[test_only]
/// Set TWAP prices for testing (bypasses auth requirement)
public fun set_twap_prices_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    twap_prices: vector<u128>,
) {
    proposal.twap_config.twap_prices = twap_prices;
}

#[test_only]
/// Set winning outcome for testing (bypasses auth requirement)
public fun set_winning_outcome_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome: u64,
) {
    proposal.outcome_data.winning_outcome = option::some(outcome);
}

#[test_only]
/// Create a cancel witness for testing (bypasses auth requirement)
public fun make_cancel_witness_for_testing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
): option::Option<CancelWitness> {
    if (outcome_index >= proposal.outcome_data.outcome_count) {
        return option::none()
    };
    let spec_slot = vector::borrow_mut(
        &mut proposal.outcome_data.intent_specs,
        outcome_index,
    );
    if (option::is_none(spec_slot)) {
        return option::none()
    };
    // Clear the spec
    let _spec = option::extract(spec_slot);
    // Return a cancel witness
    option::some(CancelWitness {
        proposal: object::uid_to_address(&proposal.id),
        outcome_index,
    })
}

// === Additional View Functions ===

/// Get proposal address (for testing)
public fun id_address<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): address {
    object::uid_to_address(&proposal.id)
}

// =============================================================================
// === ATOMIC PROPOSAL CREATION PATTERN ===
// =============================================================================
//
// This pattern ensures proposals are created atomically with all conditional coins.
// The proposal is NOT shared until finalize_proposal is called, preventing incomplete proposals.
//
// Flow:
// 1. begin_proposal() → (Proposal, TokenEscrow, ProposalCreationTicket) - all unshared
// 2. add_outcome_coins() or add_outcome_coins_10() → registers coins with escrow
// 3. finalize_proposal() → consumes ticket, validates completeness, creates AMM pools, shares both
//
// Example PTB for 10 outcomes:
//   begin_proposal()
//   add_outcome_coins_10(...outcomes 0-9...)
//   finalize_proposal()
//
// Example PTB for 15 outcomes:
//   begin_proposal()
//   add_outcome_coins_10(...outcomes 0-9...)
//   add_outcome_coins(...outcome 10...)
//   add_outcome_coins(...outcome 11...)
//   ... etc
//   finalize_proposal()

/// Begin creating a proposal atomically. Returns UNSHARED proposal, escrow, and a
/// non-droppable creation ticket.
/// Must call add_outcome_coins/add_outcome_coins_10 to register all conditional coins,
/// then finalize_proposal in the same PTB to validate and share.
///
/// Feeless quota is consumed atomically in this function when `used_feeless_quota=true`.
/// Callers do not need a separate quota-consumption step.
///
/// Fee type is determined by DAO config (fee_in_asset_token):
/// - If fee_in_asset_token = false: pass stable_fee, asset_fee should be zero coin
/// - If fee_in_asset_token = true: pass asset_fee, stable_fee should be zero coin
public fun begin_proposal<AssetType, StableType>(
    dao_account: &mut account::Account,
    package_registry: &PackageRegistry,
    title: String,
    introduction_details: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    proposer: address,
    used_feeless_quota: bool,
    stable_fee: Coin<StableType>,
    asset_fee: Coin<AssetType>,
    intent_spec_for_yes: Option<vector<ActionSpec>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (
    Proposal<AssetType, StableType>,
    TokenEscrow<AssetType, StableType>,
    ProposalCreationTicket<AssetType, StableType>,
) {
    // SECURITY: Sender must match proposer. Prevents (a) draining another user's
    // feeless quota and (b) spoofing the on-chain proposer/liquidity_provider/
    // outcome_creators fields by paying the fee on someone else's behalf.
    assert!(tx_context::sender(ctx) == proposer, ENotProposer);

    // Check DAO config for which fee type is expected
    let futarchy_cfg = account::config<futarchy_config::FutarchyConfig>(dao_account);
    let fee_in_asset = futarchy_config::fee_in_asset_token(futarchy_cfg);

    let mut fee_escrow = bag::new(ctx);
    let (total_fee_paid, fee_paid_in_asset) = if (fee_in_asset) {
        // DAO expects asset fee - stable_fee should be zero
        assert!(stable_fee.value() == 0, EWrongFeeType);
        stable_fee.destroy_zero();

        let total = asset_fee.value();
        // Only store fee balance if non-zero (feeless quota = no storage needed)
        if (total > 0) {
            let fee_balance = asset_fee.into_balance();
            bag::add(&mut fee_escrow, FeeBalanceKey {}, fee_balance);
        } else {
            asset_fee.destroy_zero();
        };
        (total, true)
    } else {
        // DAO expects stable fee - asset_fee should be zero
        assert!(asset_fee.value() == 0, EWrongFeeType);
        asset_fee.destroy_zero();

        let total = stable_fee.value();
        // Only store fee balance if non-zero (feeless quota = no storage needed)
        if (total > 0) {
            let fee_balance = stable_fee.into_balance();
            bag::add(&mut fee_escrow, FeeBalanceKey {}, fee_balance);
        } else {
            stable_fee.destroy_zero();
        };
        (total, false)
    };

    let (proposal, escrow) = begin_proposal_internal<AssetType, StableType>(
        dao_account,
        package_registry,
        title,
        introduction_details,
        metadata,
        outcome_messages,
        outcome_details,
        proposer,
        used_feeless_quota,
        fee_escrow,
        fee_paid_in_asset,
        total_fee_paid,
        intent_spec_for_yes,
        clock,
        ctx,
    );

    // Consume feeless quota atomically with proposal creation so it cannot be skipped.
    if (used_feeless_quota) {
        futarchy_config::consume_feeless_quota(
            dao_account,
            package_registry,
            proposer,
            clock,
            ctx,
        );
    };

    let ticket = ProposalCreationTicket {
        proposal_id: object::id(&proposal),
    };

    (proposal, escrow, ticket)
}

/// Internal helper for begin_proposal variants
fun begin_proposal_internal<AssetType, StableType>(
    dao_account: &account::Account,
    package_registry: &PackageRegistry,
    title: String,
    introduction_details: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    proposer: address,
    used_feeless_quota: bool,
    fee_escrow: Bag,
    fee_paid_in_asset: bool,
    total_fee_paid: u64,
    intent_spec_for_yes: Option<vector<ActionSpec>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Proposal<AssetType, StableType>, TokenEscrow<AssetType, StableType>) {
    let id = object::new(ctx);
    let actual_proposal_id = object::uid_to_inner(&id);
    let outcome_count = outcome_messages.length();

    // SECURITY: Validate package_registry belongs to this DAO account.
    // Without this, an attacker could pass a registry from a different DAO
    // with different whitelist rules, bypassing package authorization.
    assert!(
        deps::registry_id(account::deps(dao_account)) == object::id(package_registry),
        ERegistryMismatch,
    );

    // Read ALL parameters from DAO config
    let futarchy_cfg = account::config<futarchy_config::FutarchyConfig>(dao_account);

    // Block proposal creation after DAO termination
    futarchy_config::assert_not_terminated(futarchy_config::dao_state(futarchy_cfg));

    // Validate types match DAO config
    let expected_asset_type = futarchy_config::asset_type(futarchy_cfg);
    let expected_stable_type = futarchy_config::stable_type(futarchy_cfg);
    let actual_asset_type = type_name::with_original_ids<AssetType>().into_string().to_string();
    let actual_stable_type = type_name::with_original_ids<StableType>().into_string().to_string();
    assert!(actual_asset_type == *expected_asset_type, EInvalidAssetType);
    assert!(actual_stable_type == *expected_stable_type, EInvalidStableType);

    // Trading parameters
    let review_period_ms = futarchy_config::review_period_ms(futarchy_cfg);
    let trading_period_ms = futarchy_config::trading_period_ms(futarchy_cfg);
    let min_asset_liquidity = futarchy_config::min_asset_amount(futarchy_cfg);
    let min_stable_liquidity = futarchy_config::min_stable_amount(futarchy_cfg);
    let amm_total_fee_bps = futarchy_config::conditional_amm_fee_bps(futarchy_cfg);
    let conditional_liquidity_ratio_percent = futarchy_config::conditional_liquidity_ratio_percent(
        futarchy_cfg,
    );

    // TWAP parameters
    let twap_start_delay = futarchy_config::amm_twap_start_delay(futarchy_cfg);
    let twap_initial_observation = futarchy_config::amm_twap_initial_observation(futarchy_cfg);
    let twap_cap_ppm = futarchy_config::amm_twap_cap_ppm(futarchy_cfg);
    let twap_threshold = futarchy_config::twap_threshold(futarchy_cfg);
    let sponsored_threshold = futarchy_config::sponsored_threshold(futarchy_cfg);

    // TWAP must have a non-zero measurement period within the trading window,
    // since outcome calculation freezes TWAP at the scheduled trading_end time.
    assert!(trading_period_ms > twap_start_delay, EInvalidTwapTiming);

    // Governance parameters
    let max_outcomes = futarchy_config::max_outcomes(futarchy_cfg);
    let max_actions_per_outcome = futarchy_config::max_actions_per_outcome(futarchy_cfg);

    // Validate outcome count
    assert!(outcome_count >= 2, EInvalidOutcome);
    assert!(outcome_count <= max_outcomes, ETooManyOutcomes);

    // Validate outcome_details matches outcome_messages length
    assert!(outcome_details.length() == outcome_count, EOutcomeCountMismatch);

    // Validate fee payment - feeless if using feeless quota
    let base_fee = if (used_feeless_quota) {
        // Check feeless quota availability
        let quota_registry = futarchy_config::quota_registry(futarchy_cfg);
        let has_feeless_quota = proposal_quota_registry::check_feeless_quota_available(
            quota_registry,
            proposer,
            clock,
        );
        // If used_feeless_quota=true but no quota available, abort
        assert!(has_feeless_quota, ENoQuotaAvailable);
        // Feeless quota means no base fee
        0
    } else {
        futarchy_config::proposal_creation_fee(futarchy_cfg)
    };

    let per_outcome_fee = futarchy_config::proposal_fee_per_outcome(futarchy_cfg);
    // Use u128 to prevent overflow on large fees, with explicit overflow check before cast
    let additional_outcome_fee = if (outcome_count <= 2) { 0 } else {
        let fee_u128 = ((outcome_count - 2) as u128) * (per_outcome_fee as u128);
        assert!(fee_u128 <= (18446744073709551615u128), EFeeCalculationOverflow); // u64::MAX
        fee_u128 as u64
    };
    // Check addition won't overflow
    assert!(base_fee <= 18446744073709551615u64 - additional_outcome_fee, EFeeCalculationOverflow);
    let expected_fee = base_fee + additional_outcome_fee;
    assert!(total_fee_paid == expected_fee, EInsufficientFee);

    let mut proposal = Proposal<AssetType, StableType> {
        id,
        state: STATE_PREMARKET,
        dao_id: object::id(dao_account),
        proposer,
        liquidity_provider: option::none(),
        withdraw_only_mode: false,
        used_feeless_quota,
        outcome_sponsorship: vector::tabulate!(outcome_count, |_| SPONSORSHIP_NONE),
        sponsor_quota_used_for_proposal: false,
        sponsor_quota_user: option::none(),
        escrow_id: option::none(),
        market_state_id: option::none(),
        conditional_treasury_caps: bag::new(ctx),
        conditional_metadata_caps: bag::new(ctx),
        conditional_asset_types: vector::tabulate!(outcome_count, |_| ascii::string(b"")),
        conditional_stable_types: vector::tabulate!(outcome_count, |_| ascii::string(b"")),
        title,
        introduction_details,
        details: outcome_details,
        metadata,
        timing: ProposalTiming {
            created_at: clock.timestamp_ms(),
            market_initialized_at: option::none(),
            trading_started_at: option::none(),
            review_period_ms,
            trading_period_ms,
            last_twap_update: 0,
            twap_start_delay,
        },
        liquidity_config: LiquidityConfig {
            min_asset_liquidity,
            min_stable_liquidity,
            asset_amounts: vector::empty(),
            stable_amounts: vector::empty(),
        },
        twap_config: TwapConfig {
            twap_prices: vector::empty(),
            twap_initial_observation,
            twap_cap_ppm,
            twap_threshold,
            sponsored_threshold,
        },
        outcome_data: OutcomeData {
            outcome_count,
            outcome_messages,
            outcome_creators: vector::tabulate!(outcome_count, |_| proposer),
            intent_specs: vector::tabulate!(outcome_count, |_| option::none<vector<ActionSpec>>()),
            actions_per_outcome: vector::tabulate!(outcome_count, |_| 0),
            winning_outcome: option::none(),
        },
        amm_total_fee_bps,
        conditional_liquidity_ratio_percent,
        fee_escrow,
        fee_paid_in_asset,
        total_fee_paid,
        max_outcomes,
    };

    // Apply intent_spec_for_yes if provided (for atomic proposal creation with staged actions).
    // SECURITY: Must apply the same staging-time package whitelist and per-outcome action-count
    // checks as `set_intent_spec_for_outcome` to avoid “toggle-then-malicious-action” patterns.
    if (option::is_some(&intent_spec_for_yes)) {
        let spec = option::destroy_some(intent_spec_for_yes);
        set_intent_spec_for_outcome_internal<AssetType, StableType>(
            &mut proposal,
            OUTCOME_ACCEPTED,
            spec,
            max_actions_per_outcome,
            dao_account,
            package_registry,
        );
    } else {
        option::destroy_none(intent_spec_for_yes);
    };

    // Create market state
    let ms = market_state::new(
        actual_proposal_id,
        proposal.dao_id,
        outcome_count,
        proposal.outcome_data.outcome_messages,
        clock,
        ctx,
    );

    // Create escrow (not shared yet)
    let escrow = coin_escrow::new<AssetType, StableType>(ms, ctx);

    // Emit event - use with_original_ids for consistency with validation
    event::emit(ProposalCreated {
        proposal_id: actual_proposal_id,
        dao_id: proposal.dao_id,
        proposer,
        outcome_count,
        outcome_messages: proposal.outcome_data.outcome_messages,
        created_at: proposal.timing.created_at,
        asset_type: type_name::with_original_ids<AssetType>().into_string(),
        stable_type: type_name::with_original_ids<StableType>().into_string(),
        review_period_ms,
        trading_period_ms,
        title: proposal.title,
        metadata: proposal.metadata,
    });

    // Return UNSHARED - caller must call finalize_proposal
    (proposal, escrow)
}

/// Add one outcome's conditional coins (asset + stable pair).
/// Validates blank metadata, updates with DAO naming, registers caps with escrow.
/// Accepts the DAO Account directly and borrows config internally (avoids PTB reference issues).
///
/// Uses Sui Currency standard:
/// - Currency<T> is a shared object (passed by reference)
/// - MetadataCap<T> is owned (consumed and stored in proposal)
/// - Symbol is immutable ("Govex Conditional" - validated here)
/// - Name/description/icon are set via MetadataCap
public fun add_outcome_coins<AssetType, StableType, AssetCondCoin, StableCondCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    asset_treasury_cap: TreasuryCap<AssetCondCoin>,
    asset_currency: &mut Currency<AssetCondCoin>,
    asset_metadata_cap: MetadataCap<AssetCondCoin>,
    stable_treasury_cap: TreasuryCap<StableCondCoin>,
    stable_currency: &mut Currency<StableCondCoin>,
    stable_metadata_cap: MetadataCap<StableCondCoin>,
    dao_account: &Account,
    base_asset_currency: &Currency<AssetType>,
    base_stable_currency: &Currency<StableType>,
    ctx: &mut TxContext,
) {
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);

    // SECURITY: Validate DAO account matches this proposal's DAO.
    assert!(object::id(dao_account) == proposal.dao_id, EDaoAccountMismatch);

    // SECURITY: Validate escrow's embedded MarketState was created for this proposal/DAO.
    // Without this, a caller could mix-and-match (proposal, escrow, dao_account) from different DAOs
    // with the same type parameters and register conditional caps into the wrong escrow.
    let ms = coin_escrow::get_market_state(escrow);
    assert!(market_state::proposal_id(ms) == object::id(proposal), EProposalEscrowMismatch);
    assert!(market_state::dao_id(ms) == proposal.dao_id, EProposalEscrowMismatch);

    // Borrow DaoConfig from Account internally (avoids PTB reference return issues)
    let dao_cfg = futarchy_config::dao_config(
        account::config<futarchy_config::FutarchyConfig>(dao_account),
    );

    // Validate and update asset conditional coin metadata
    validate_and_update_conditional_metadata(
        outcome_index,
        true, // is_asset
        &asset_treasury_cap,
        asset_currency,
        &asset_metadata_cap,
        dao_cfg,
        base_asset_currency,
        base_stable_currency,
        ctx,
    );

    // Validate and update stable conditional coin metadata
    validate_and_update_conditional_metadata(
        outcome_index,
        false, // is_asset
        &stable_treasury_cap,
        stable_currency,
        &stable_metadata_cap,
        dao_cfg,
        base_asset_currency,
        base_stable_currency,
        ctx,
    );

    // Register caps with escrow (consumes the treasury caps)
    coin_escrow::register_conditional_caps(
        escrow,
        outcome_index,
        asset_treasury_cap,
        stable_treasury_cap,
    );

    // Store MetadataCaps in proposal for future metadata updates
    let asset_key = ConditionalCoinKey { outcome_index, is_asset: true };
    let stable_key = ConditionalCoinKey { outcome_index, is_asset: false };
    bag::add(&mut proposal.conditional_metadata_caps, asset_key, asset_metadata_cap);
    bag::add(&mut proposal.conditional_metadata_caps, stable_key, stable_metadata_cap);

    // Store conditional coin type names for indexing
    let asset_type_slot = vector::borrow_mut(&mut proposal.conditional_asset_types, outcome_index);
    *asset_type_slot = type_name::into_string(type_name::get<AssetCondCoin>());
    let stable_type_slot = vector::borrow_mut(
        &mut proposal.conditional_stable_types,
        outcome_index,
    );
    *stable_type_slot = type_name::into_string(type_name::get<StableCondCoin>());
}

/// Internal helper to validate and update a single conditional coin's metadata
/// Uses Sui Currency standard with MetadataCap for updates
fun validate_and_update_conditional_metadata<AssetType, StableType, ConditionalCoinType>(
    outcome_index: u64,
    is_asset: bool,
    treasury_cap: &TreasuryCap<ConditionalCoinType>,
    currency: &mut Currency<ConditionalCoinType>,
    metadata_cap: &MetadataCap<ConditionalCoinType>,
    dao_cfg: &dao_config::DaoConfig,
    base_asset_currency: &Currency<AssetType>,
    base_stable_currency: &Currency<StableType>,
    ctx: &mut TxContext,
) {
    // Validate supply is zero
    assert!(coin::total_supply(treasury_cap) == 0, ESupplyNotZero);

    validate_conditional_coin_module<ConditionalCoinType>();

    assert_new_unregulated_currency(currency, ctx);

    let registered_cap_id = coin_registry::treasury_cap_id(currency);
    assert!(registered_cap_id.is_some(), ERegulatedCoin);
    assert!(*registered_cap_id.borrow() == object::id(treasury_cap), ERegulatedCoin);
    let registered_metadata_cap_id = coin_registry::metadata_cap_id(currency);
    assert!(registered_metadata_cap_id.is_some(), ERegulatedCoin);
    assert!(*registered_metadata_cap_id.borrow() == object::id(metadata_cap), ERegulatedCoin);

    // Validate symbol is "Govex Conditional" (immutable, set at coin creation)
    let symbol = coin_registry::symbol(currency);
    assert!(symbol == string::utf8(b"Govex Conditional"), EInvalidSymbol);

    // Validate name/description/icon are blank (will be set below via MetadataCap)
    assert!(coin_registry::name(currency).is_empty(), EMetadataNameNotEmpty);
    assert!(coin_registry::description(currency).is_empty(), EMetadataDescriptionNotEmpty);
    assert!(coin_registry::icon_url(currency).is_empty(), EMetadataIconNotEmpty);

    // Get DAO name and coin config
    let dao_name = dao_config::dao_name(dao_config::metadata_config(dao_cfg));
    let coin_config = dao_config::conditional_coin_config(dao_cfg);

    // Get base coin info from Currency<T> (uses coin_registry getters)
    // Note: coin_registry returns UTF-8 strings; symbol needs ASCII fallback, icon stays UTF-8.
    let (base_name, base_symbol, base_icon_url) = if (is_asset) {
        let name = coin_registry::name(base_asset_currency);
        let symbol_str = coin_registry::symbol(base_asset_currency);
        let icon_url = coin_registry::icon_url(base_asset_currency);
        let symbol_ascii_opt = ascii::try_string(symbol_str.into_bytes());
        let symbol_ascii = if (symbol_ascii_opt.is_some()) {
            symbol_ascii_opt.destroy_some()
        } else {
            symbol_ascii_opt.destroy_none();
            ascii::string(b"TOKEN")
        };
        (name, symbol_ascii, icon_url)
    } else {
        let name = coin_registry::name(base_stable_currency);
        let symbol_str = coin_registry::symbol(base_stable_currency);
        let icon_url = coin_registry::icon_url(base_stable_currency);
        let symbol_ascii_opt = ascii::try_string(symbol_str.into_bytes());
        let symbol_ascii = if (symbol_ascii_opt.is_some()) {
            symbol_ascii_opt.destroy_some()
        } else {
            symbol_ascii_opt.destroy_none();
            ascii::string(b"TOKEN")
        };
        (name, symbol_ascii, icon_url)
    };

    // Update metadata using Currency + MetadataCap (Sui Currency standard)
    // Symbol is IMMUTABLE - already set to "Govex Conditional" at coin creation
    conditional_coin_utils::update_conditional_metadata(
        currency,
        metadata_cap,
        coin_config,
        outcome_index,
        dao_name,
        &base_name,
        &base_symbol,
        &base_icon_url,
    );
}

fun assert_new_unregulated_currency<T>(currency: &mut Currency<T>, ctx: &mut TxContext) {
    let (legacy_metadata, borrow) = coin_registry::borrow_legacy_metadata(currency, ctx);
    coin_registry::return_borrowed_legacy_metadata(currency, legacy_metadata, borrow, ctx);
    assert!(!coin_registry::is_regulated(currency), ERegulatedCoin);
}

fun validate_conditional_coin_module<ConditionalCoinType>() {
    let type_info = type_name::with_original_ids<ConditionalCoinType>();
    let module_name = type_name::get_module(&type_info);
    let module_bytes = module_name.into_bytes();
    let prefix = CONDITIONAL_MODULE_PREFIX;
    let prefix_len = prefix.length();

    assert!(module_bytes.length() > prefix_len, EInvalidConditionalCoinModule);

    let mut i = 0;
    while (i < prefix_len) {
        assert!(module_bytes[i] == prefix[i], EInvalidConditionalCoinModule);
        i = i + 1;
    };

    while (i < module_bytes.length()) {
        let c = module_bytes[i];
        assert!(c >= 48 && c <= 57, EInvalidConditionalCoinModule);
        i = i + 1;
    };
}

/// Add 10 outcomes' conditional coins (20 coins total) in one call.
/// For proposals with up to 10 outcomes, this is a single PTB call.
/// For larger proposals, combine with add_outcome_coins for remaining outcomes.
///
/// Uses Sui Currency standard - each coin needs:
/// - TreasuryCap<T> for minting
/// - &mut Currency<T> (shared object, passed by reference)
/// - MetadataCap<T> for metadata updates
public fun add_outcome_coins_10<
    AssetType,
    StableType,
    // Outcome 0
    AC0,
    SC0,
    // Outcome 1
    AC1,
    SC1,
    // Outcome 2
    AC2,
    SC2,
    // Outcome 3
    AC3,
    SC3,
    // Outcome 4
    AC4,
    SC4,
    // Outcome 5
    AC5,
    SC5,
    // Outcome 6
    AC6,
    SC6,
    // Outcome 7
    AC7,
    SC7,
    // Outcome 8
    AC8,
    SC8,
    // Outcome 9
    AC9,
    SC9,
>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    // Outcome 0 caps, currency refs, and metadata caps
    ac0: TreasuryCap<AC0>,
    acur0: &mut Currency<AC0>,
    am0: MetadataCap<AC0>,
    sc0: TreasuryCap<SC0>,
    scur0: &mut Currency<SC0>,
    sm0: MetadataCap<SC0>,
    // Outcome 1
    ac1: TreasuryCap<AC1>,
    acur1: &mut Currency<AC1>,
    am1: MetadataCap<AC1>,
    sc1: TreasuryCap<SC1>,
    scur1: &mut Currency<SC1>,
    sm1: MetadataCap<SC1>,
    // Outcome 2
    ac2: TreasuryCap<AC2>,
    acur2: &mut Currency<AC2>,
    am2: MetadataCap<AC2>,
    sc2: TreasuryCap<SC2>,
    scur2: &mut Currency<SC2>,
    sm2: MetadataCap<SC2>,
    // Outcome 3
    ac3: TreasuryCap<AC3>,
    acur3: &mut Currency<AC3>,
    am3: MetadataCap<AC3>,
    sc3: TreasuryCap<SC3>,
    scur3: &mut Currency<SC3>,
    sm3: MetadataCap<SC3>,
    // Outcome 4
    ac4: TreasuryCap<AC4>,
    acur4: &mut Currency<AC4>,
    am4: MetadataCap<AC4>,
    sc4: TreasuryCap<SC4>,
    scur4: &mut Currency<SC4>,
    sm4: MetadataCap<SC4>,
    // Outcome 5
    ac5: TreasuryCap<AC5>,
    acur5: &mut Currency<AC5>,
    am5: MetadataCap<AC5>,
    sc5: TreasuryCap<SC5>,
    scur5: &mut Currency<SC5>,
    sm5: MetadataCap<SC5>,
    // Outcome 6
    ac6: TreasuryCap<AC6>,
    acur6: &mut Currency<AC6>,
    am6: MetadataCap<AC6>,
    sc6: TreasuryCap<SC6>,
    scur6: &mut Currency<SC6>,
    sm6: MetadataCap<SC6>,
    // Outcome 7
    ac7: TreasuryCap<AC7>,
    acur7: &mut Currency<AC7>,
    am7: MetadataCap<AC7>,
    sc7: TreasuryCap<SC7>,
    scur7: &mut Currency<SC7>,
    sm7: MetadataCap<SC7>,
    // Outcome 8
    ac8: TreasuryCap<AC8>,
    acur8: &mut Currency<AC8>,
    am8: MetadataCap<AC8>,
    sc8: TreasuryCap<SC8>,
    scur8: &mut Currency<SC8>,
    sm8: MetadataCap<SC8>,
    // Outcome 9
    ac9: TreasuryCap<AC9>,
    acur9: &mut Currency<AC9>,
    am9: MetadataCap<AC9>,
    sc9: TreasuryCap<SC9>,
    scur9: &mut Currency<SC9>,
    sm9: MetadataCap<SC9>,
    // Base currency and DAO account
    dao_account: &Account,
    base_asset_currency: &Currency<AssetType>,
    base_stable_currency: &Currency<StableType>,
    // Starting outcome index (usually 0, but could be 10, 20, etc for large proposals)
    start_outcome_index: u64,
    ctx: &mut TxContext,
) {
    // SECURITY: Validate DAO account matches this proposal's DAO.
    assert!(object::id(dao_account) == proposal.dao_id, EDaoAccountMismatch);

    // SECURITY: Validate escrow's embedded MarketState was created for this proposal/DAO.
    let ms = coin_escrow::get_market_state(escrow);
    assert!(market_state::proposal_id(ms) == object::id(proposal), EProposalEscrowMismatch);
    assert!(market_state::dao_id(ms) == proposal.dao_id, EProposalEscrowMismatch);

    let outcome_count = proposal.outcome_data.outcome_count;

    // Add each outcome that exists
    if (start_outcome_index + 0 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 0,
            ac0,
            acur0,
            am0,
            sc0,
            scur0,
            sm0,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        // Destroy unused caps and metadata caps
        destroy_unused_caps(ac0, am0);
        destroy_unused_caps(sc0, sm0);
    };

    if (start_outcome_index + 1 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 1,
            ac1,
            acur1,
            am1,
            sc1,
            scur1,
            sm1,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        destroy_unused_caps(ac1, am1);
        destroy_unused_caps(sc1, sm1);
    };

    if (start_outcome_index + 2 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 2,
            ac2,
            acur2,
            am2,
            sc2,
            scur2,
            sm2,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        destroy_unused_caps(ac2, am2);
        destroy_unused_caps(sc2, sm2);
    };

    if (start_outcome_index + 3 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 3,
            ac3,
            acur3,
            am3,
            sc3,
            scur3,
            sm3,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        destroy_unused_caps(ac3, am3);
        destroy_unused_caps(sc3, sm3);
    };

    if (start_outcome_index + 4 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 4,
            ac4,
            acur4,
            am4,
            sc4,
            scur4,
            sm4,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        destroy_unused_caps(ac4, am4);
        destroy_unused_caps(sc4, sm4);
    };

    if (start_outcome_index + 5 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 5,
            ac5,
            acur5,
            am5,
            sc5,
            scur5,
            sm5,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        destroy_unused_caps(ac5, am5);
        destroy_unused_caps(sc5, sm5);
    };

    if (start_outcome_index + 6 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 6,
            ac6,
            acur6,
            am6,
            sc6,
            scur6,
            sm6,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        destroy_unused_caps(ac6, am6);
        destroy_unused_caps(sc6, sm6);
    };

    if (start_outcome_index + 7 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 7,
            ac7,
            acur7,
            am7,
            sc7,
            scur7,
            sm7,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        destroy_unused_caps(ac7, am7);
        destroy_unused_caps(sc7, sm7);
    };

    if (start_outcome_index + 8 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 8,
            ac8,
            acur8,
            am8,
            sc8,
            scur8,
            sm8,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        destroy_unused_caps(ac8, am8);
        destroy_unused_caps(sc8, sm8);
    };

    if (start_outcome_index + 9 < outcome_count) {
        add_outcome_coins(
            proposal,
            escrow,
            start_outcome_index + 9,
            ac9,
            acur9,
            am9,
            sc9,
            scur9,
            sm9,
            dao_account,
            base_asset_currency,
            base_stable_currency,
            ctx,
        );
    } else {
        destroy_unused_caps(ac9, am9);
        destroy_unused_caps(sc9, sm9);
    };
}

/// Dispose of unused treasury cap and metadata cap (for bulk function when outcome_count < 10).
/// SAFETY: These caps are transferred to @0x0 (the "black hole" address) because:
/// 1. TreasuryCap and MetadataCap lack `drop` ability and have no public destroy function
/// 2. @0x0 is permanently inaccessible - no private key can sign for this address
/// 3. These are caps for conditional coin types that have zero supply and no market
/// 4. Even if theoretically accessible, they'd control worthless, unused coin types
/// This is the standard Sui pattern for disposing of non-droppable objects.
fun destroy_unused_caps<T>(treasury_cap: TreasuryCap<T>, metadata_cap: MetadataCap<T>) {
    transfer::public_transfer(treasury_cap, @0x0);
    transfer::public_transfer(metadata_cap, @0x0);
}

/// Finalize proposal creation: validate all coins registered, create AMM pools, share.
/// Conditional AMM pools are created EMPTY (zero reserves). Liquidity is provided
/// solely by `auto_quantum_split_on_proposal_start` when advancing to TRADING.
/// SECURITY: Requires SpotPoolMutationRegistry for authorized spot pool state changes.
/// SECURITY: Must be called in the SAME PTB as `begin_proposal`. The proposal freezes
/// DAO config at begin-time; enforcing same-PTB finalization prevents proposers from
/// time-capsuling permissive config past governance tightening or DAO termination.
#[allow(lint(share_owned))]
public fun finalize_proposal<AssetType, StableType, LPType>(
    mut proposal: Proposal<AssetType, StableType>,
    escrow: TokenEscrow<AssetType, StableType>,
    ticket: ProposalCreationTicket<AssetType, StableType>,
    dao_account: &Account,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);

    // SECURITY: Enforce atomic proposal creation. begin_proposal freezes DAO config
    // (timing, min liquidity, AMM fees, TWAP seed/thresholds, outcome caps) into the
    // proposal object. The no-ability ticket cannot survive past the current PTB,
    // so consuming the matching ticket here prevents time-capsuling old config.
    let ProposalCreationTicket { proposal_id } = ticket;
    assert!(proposal_id == object::id(&proposal), ENonAtomicProposalCreation);

    // SECURITY: Validate the DAO account matches this proposal's DAO.
    assert!(object::id(dao_account) == proposal.dao_id, EDaoAccountMismatch);

    // SECURITY: Validate escrow's embedded MarketState was created for this proposal/DAO.
    let ms = coin_escrow::get_market_state(&escrow);
    assert!(market_state::proposal_id(ms) == object::id(&proposal), EProposalEscrowMismatch);
    assert!(market_state::dao_id(ms) == proposal.dao_id, EProposalEscrowMismatch);

    // SECURITY: Validate the spot pool belongs to this DAO.
    let futarchy_cfg = account::config<futarchy_config::FutarchyConfig>(dao_account);

    // SECURITY: Block proposal finalization after DAO termination. Mirrors the
    // same check in begin_proposal_internal — without it, a proposer could begin
    // a proposal while the DAO is active, hold the unshared objects, and finalize
    // after termination to spawn a live market post-shutdown.
    futarchy_config::assert_not_terminated(futarchy_config::dao_state(futarchy_cfg));

    let expected_pool_id = futarchy_config::get_spot_pool_id(futarchy_cfg);
    assert!(
        option::is_some(&expected_pool_id)
            && *option::borrow(&expected_pool_id) == object::id(spot_pool),
        ESpotPoolMismatch,
    );

    let outcome_count = proposal.outcome_data.outcome_count;

    // Validate all conditional coins are registered
    assert!(
        bag::length(&proposal.conditional_metadata_caps) == outcome_count * 2,
        EMissingConditionalCoins,
    );
    assert!(coin_escrow::caps_registered_count(&escrow) == outcome_count, EMissingConditionalCoins);

    // Get spot pool reserves for pricing and validation
    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot_pool);

    // Validate spot liquidity meets DAO minimums
    assert!(spot_asset >= proposal.liquidity_config.min_asset_liquidity, EAssetLiquidityTooLow);
    assert!(spot_stable >= proposal.liquidity_config.min_stable_liquidity, EStableLiquidityTooLow);

    // NOTE: twap_initial_observation is read from DAO config at proposal creation
    // and stored in proposal.twap_config.twap_initial_observation. It is applied
    // at advance_state (REVIEW->TRADING) time. For first proposal it's the DAO
    // initialization price; for subsequent proposals it's the previous winning TWAP.

    // Initialize market fields
    // AMM pools are created later during advance_state REVIEW->TRADING transition
    let market_state_id = market_state::market_id(coin_escrow::get_market_state(&escrow));
    let escrow_id = object::id(&escrow);

    option::fill(&mut proposal.market_state_id, market_state_id);
    option::fill(&mut proposal.escrow_id, escrow_id);
    option::fill(&mut proposal.timing.market_initialized_at, clock.timestamp_ms());
    let proposer = proposal.proposer;
    option::fill(&mut proposal.liquidity_provider, proposer);
    proposal.state = STATE_REVIEW;

    // Wrap active escrow in spot pool until proposal resolution.
    let spot_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_active_escrow(spot_pool, escrow, spot_auth);

    // Emit market initialized event with conditional coin types for indexing
    event::emit(ProposalMarketInitialized {
        proposal_id: object::id(&proposal),
        dao_id: proposal.dao_id,
        market_state_id,
        escrow_id,
        timestamp: clock.timestamp_ms(),
        conditional_asset_types: proposal.conditional_asset_types,
        conditional_stable_types: proposal.conditional_stable_types,
    });

    // Share proposal object. Escrow remains wrapped in spot_pool.
    transfer::public_share_object(proposal);
}

// === LP Preferences Dynamic Field Management ===

/// Get immutable reference to proposal's UID for dynamic field reads
/// Public to allow other packages (e.g., futarchy_governance) to use dynamic fields
public fun borrow_uid<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): &UID {
    &proposal.id
}

// === Sponsorship Functions ===

/// Check if ANY outcome in the proposal is sponsored (any type)
public fun is_sponsored<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    let mut i = 0u64;
    while (i < proposal.outcome_sponsorship.length()) {
        if (*proposal.outcome_sponsorship.borrow(i) != SPONSORSHIP_NONE) {
            return true
        };
        i = i + 1;
    };
    false
}

/// Check if a specific outcome is sponsored (any type)
/// Returns true if sponsorship type is ZERO_THRESHOLD or NEGATIVE_DISCOUNT
public fun is_outcome_sponsored<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): bool {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    *proposal.outcome_sponsorship.borrow(outcome_index) != SPONSORSHIP_NONE
}

/// Get the sponsorship type for a specific outcome
/// Returns: 0 = NONE, 1 = ZERO_THRESHOLD, 2 = NEGATIVE_DISCOUNT
public fun get_outcome_sponsorship_type<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): u8 {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    *proposal.outcome_sponsorship.borrow(outcome_index)
}

/// Get the full sponsorship types vector (copy)
/// Returns vector where index = outcome, value = sponsorship type (0=none, 1=zero, 2=negative)
public fun get_outcome_sponsorship_types<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): vector<u8> {
    proposal.outcome_sponsorship
}

/// Set sponsorship for multiple outcomes using a vector of sponsorship types
/// sponsorship_types[i] corresponds to outcome i:
///   0 = SPONSORSHIP_NONE (skip/no change if already sponsored)
///   1 = SPONSORSHIP_ZERO_THRESHOLD
///   2 = SPONSORSHIP_NEGATIVE_DISCOUNT
/// SECURITY: Requires SponsorshipAuth from futarchy_core::sponsorship_auth
/// SECURITY: Outcome 0 (reject) must always be 0 (cannot be sponsored)
/// IDEMPOTENT: Re-sponsoring an already-sponsored outcome with same type is a no-op
public fun set_outcome_sponsorships<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    sponsorship_types: vector<u8>,
    auth: SponsorshipAuth, // Compile-time type safety - only authorized modules can create this
) {
    assert!(sponsorship_auth::target_id(&auth) == object::id(proposal), EAuthTargetMismatch);
    // Sponsorship updates are only valid before execution window starts.
    assert!(
        proposal.state == STATE_PREMARKET ||
        proposal.state == STATE_REVIEW ||
        proposal.state == STATE_TRADING,
        EInvalidState,
    );

    // Vector length must match outcome count
    assert!(sponsorship_types.length() == proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);

    // Outcome 0 (reject) cannot be sponsored
    assert!(*sponsorship_types.borrow(0) == SPONSORSHIP_NONE, ECannotSponsorReject);

    // Apply sponsorships (idempotent - set once, never overwrite)
    let mut applied_count = 0u64;
    let mut i = 1u64; // Skip outcome 0 (reject)
    while (i < sponsorship_types.length()) {
        let new_type = *sponsorship_types.borrow(i);
        let current_type = proposal.outcome_sponsorship.borrow_mut(i);

        // Only apply if new_type is non-zero AND current is unset (first-write-wins, no upgrades)
        if (new_type != SPONSORSHIP_NONE && *current_type == SPONSORSHIP_NONE) {
            // Validate sponsorship type is valid (0, 1, or 2)
            assert!(new_type <= SPONSORSHIP_NEGATIVE_DISCOUNT, EInvalidSponsorshipType);
            *current_type = new_type;
            applied_count = applied_count + 1;
        };
        i = i + 1;
    };

    event::emit(ProposalSponsorshipsUpdated {
        proposal_id: object::id(proposal),
        dao_id: proposal.dao_id,
        applied_count,
        sponsorship_types: proposal.outcome_sponsorship,
    });
}

/// Mark that sponsor quota has been used for this proposal and record who used it
/// SECURITY: Requires SponsorshipAuth from futarchy_core::sponsorship_auth
public fun mark_sponsor_quota_used<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    sponsor: address,
    auth: SponsorshipAuth, // Compile-time type safety - only authorized modules can create this
) {
    assert!(sponsorship_auth::target_id(&auth) == object::id(proposal), EAuthTargetMismatch);
    proposal.sponsor_quota_used_for_proposal = true;
    proposal.sponsor_quota_user = option::some(sponsor);

    event::emit(ProposalSponsorQuotaMarked {
        proposal_id: object::id(proposal),
        dao_id: proposal.dao_id,
        sponsor,
    });
}

/// Check if sponsor quota has already been used for this proposal
public fun is_sponsor_quota_used<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    proposal.sponsor_quota_used_for_proposal
}

/// Get the sponsor who used quota for this proposal (if any)
public fun get_sponsor_quota_user<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): Option<address> {
    proposal.sponsor_quota_user
}

/// Clear all sponsorships (for refunds on eviction/cancellation)
/// SECURITY: Requires SponsorshipAuth from futarchy_core::sponsorship_auth
/// Note: Skips outcome 0 (reject) since it can never be sponsored anyway
public fun clear_all_sponsorships<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    auth: SponsorshipAuth, // Compile-time type safety - only authorized modules can create this
) {
    assert!(sponsorship_auth::target_id(&auth) == object::id(proposal), EAuthTargetMismatch);
    let mut cleared_count = 0u64;
    let mut i = 1u64; // Start at 1 to skip outcome 0 (reject)
    while (i < proposal.outcome_sponsorship.length()) {
        let sponsorship = proposal.outcome_sponsorship.borrow_mut(i);
        if (*sponsorship != SPONSORSHIP_NONE) {
            cleared_count = cleared_count + 1;
        };
        *sponsorship = SPONSORSHIP_NONE;
        i = i + 1;
    };
    proposal.sponsor_quota_used_for_proposal = false;
    proposal.sponsor_quota_user = option::none();

    event::emit(ProposalSponsorshipsCleared {
        proposal_id: object::id(proposal),
        dao_id: proposal.dao_id,
        cleared_count,
    });
}

#[test_only]
/// Simplified test helper: creates a REAL proposal with sensible defaults
/// Can configure state (FINALIZED), outcome_count, and winning_outcome for testing
public fun create_test_proposal<AssetType, StableType>(
    outcome_count: u8,
    winning_outcome: u64,
    is_finalized: bool,
    ctx: &mut TxContext,
): Proposal<AssetType, StableType> {
    use std::string;

    let outcome_messages = vector::tabulate!(outcome_count as u64, |i| {
        string::utf8(b"Outcome")
    });

    let outcome_creators = vector::tabulate!(outcome_count as u64, |_| @0xAAA);

    let intent_specs = vector::tabulate!(
        outcome_count as u64,
        |_| option::none<vector<ActionSpec>>(),
    );

    let mut proposal = new_for_testing<AssetType, StableType>(
        @0x1, // dao_id
        @0x2, // proposer
        option::some(@0x3), // liquidity_provider
        string::utf8(b"Test"), // title
        string::utf8(b"Introduction Details"), // introduction_details
        string::utf8(b"Metadata"), // metadata
        outcome_messages,
        outcome_messages, // initial_outcome_details (reuse outcome_messages)
        outcome_creators,
        outcome_count,
        60000, // review_period_ms (1 min)
        120000, // trading_period_ms (2 min)
        1000, // min_asset_liquidity
        1000, // min_stable_liquidity
        30000, // twap_start_delay
        option::none(), // twap_initial_observation (None = first proposal, derive from reserves)
        10000, // twap_cap_ppm (1%)
        500000000000000000u128, // twap_threshold (50% in 1e18 scale)
        30, // amm_total_fee_bps (0.3%)
        10, // max_outcomes
        option::some(winning_outcome),
        intent_specs,
        ctx,
    );

    if (is_finalized) {
        proposal.state = STATE_FINALIZED;
    };

    proposal
}

#[test_only]
/// Destroy a proposal creation ticket for tests that only exercise begin_proposal.
public fun destroy_creation_ticket_for_testing<AssetType, StableType>(
    ticket: ProposalCreationTicket<AssetType, StableType>,
) {
    let ProposalCreationTicket { proposal_id: _ } = ticket;
}

#[test_only]
/// Destroy a proposal for testing - handles cleanup of all internal structures
public fun destroy_for_testing<AssetType, StableType>(proposal: Proposal<AssetType, StableType>) {
    let Proposal {
        id,
        state: _,
        dao_id: _,
        proposer: _,
        liquidity_provider: _,
        withdraw_only_mode: _,
        used_feeless_quota: _,
        outcome_sponsorship: _,
        sponsor_quota_used_for_proposal: _,
        sponsor_quota_user: _,
        escrow_id: _,
        market_state_id: _,
        conditional_treasury_caps,
        conditional_metadata_caps,
        conditional_asset_types: _,
        conditional_stable_types: _,
        title: _,
        introduction_details: _,
        details: _,
        metadata: _,
        timing: ProposalTiming {
            created_at: _,
            market_initialized_at: _,
            trading_started_at: _,
            review_period_ms: _,
            trading_period_ms: _,
            last_twap_update: _,
            twap_start_delay: _,
        },
        liquidity_config: LiquidityConfig {
            min_asset_liquidity: _,
            min_stable_liquidity: _,
            asset_amounts: _,
            stable_amounts: _,
        },
        twap_config: TwapConfig {
            twap_prices: _,
            twap_initial_observation: _,
            twap_cap_ppm: _,
            twap_threshold: _,
            sponsored_threshold: _,
        },
        outcome_data: OutcomeData {
            outcome_count: _,
            outcome_messages: _,
            outcome_creators: _,
            intent_specs: _,
            actions_per_outcome: _,
            winning_outcome: _,
        },
        amm_total_fee_bps: _,
        conditional_liquidity_ratio_percent: _,
        mut fee_escrow,
        fee_paid_in_asset,
        total_fee_paid: _,
        max_outcomes: _,
    } = proposal;

    // Destroy bags (must be empty for testing)
    bag::destroy_empty(conditional_treasury_caps);
    bag::destroy_empty(conditional_metadata_caps);

    // Remove and destroy the fee balance from the escrow bag
    // The fee is either StableType or AssetType depending on fee_paid_in_asset
    if (bag::contains(&fee_escrow, FeeBalanceKey {})) {
        if (fee_paid_in_asset) {
            let fee_balance: Balance<AssetType> = bag::remove(&mut fee_escrow, FeeBalanceKey {});
            balance::destroy_for_testing(fee_balance);
        } else {
            let fee_balance: Balance<StableType> = bag::remove(&mut fee_escrow, FeeBalanceKey {});
            balance::destroy_for_testing(fee_balance);
        };
    };
    bag::destroy_empty(fee_escrow);

    object::delete(id);
}

#[test_only]
/// Store a MetadataCap in the proposal's conditional_metadata_caps bag for testing.
/// In production, this is done during register_conditional_outcome.
public fun put_conditional_metadata_cap_for_testing<AssetType, StableType, ConditionalCoinType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    metadata_cap: sui::coin_registry::MetadataCap<ConditionalCoinType>,
) {
    let key = ConditionalCoinKey { outcome_index, is_asset };
    bag::add(&mut proposal.conditional_metadata_caps, key, metadata_cap);
}

#[test_only]
public struct TEST_LP has drop {}

#[test_only]
public struct TEST_COND_ASSET_0 has drop {}

#[test_only]
public struct TEST_COND_STABLE_0 has drop {}

#[test_only]
public struct TEST_COND_ASSET_1 has drop {}

#[test_only]
public struct TEST_COND_STABLE_1 has drop {}

#[test_only]
public struct TEST_ACTION has drop {}

#[test_only]
fun set_test_intent_spec<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
) {
    let spec = intents::new_action_spec(TEST_ACTION {}, vector[], 1);
    let spec_slot = vector::borrow_mut(&mut proposal.outcome_data.intent_specs, outcome_index);
    *spec_slot = option::some(vector[spec]);
    let count_slot = vector::borrow_mut(&mut proposal.outcome_data.actions_per_outcome, outcome_index);
    *count_slot = 1;
}

#[test]
fun test_take_intent_spec_lifecycle_excludes_trading_state() {
    assert!(!can_take_intent_spec_in_state(STATE_REVIEW), 0);
    assert!(!can_take_intent_spec_in_state(STATE_TRADING), 1);
    assert!(can_take_intent_spec_in_state(STATE_AWAITING_EXECUTION), 2);
    assert!(can_take_intent_spec_in_state(STATE_FINALIZED), 3);
}

#[test]
fun test_take_intent_spec_allows_finalized_state() {
    use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
    use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
    use sui::test_scenario::{Self as ts};

    let mut scenario = ts::begin(@0xA);
    let ctx = ts::ctx(&mut scenario);
    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 0, false, ctx);
    proposal.state = STATE_FINALIZED;
    set_test_intent_spec(&mut proposal, 1);

    let auth = proposal_mutation_auth::create_for_testing(object::id(&proposal));
    let spec = take_intent_spec_for_outcome(&mut proposal, 1, &auth);

    assert!(option::is_some(&spec), 0);
    option::destroy_some(spec);
    assert!(get_actions_for_outcome(&proposal, 1) == 0, 1);

    destroy_for_testing(proposal);
    ts::end(scenario);
}

#[test_only]
fun create_test_registries_for_advance_state(
    ctx: &mut TxContext,
): (
    futarchy_core::market_state_mutation_auth::MarketStateMutationRegistry,
    futarchy_core::escrow_mutation_auth::EscrowMutationRegistry,
) {
    let mut market_registry = futarchy_core::market_state_mutation_auth::new_registry_for_testing(ctx);
    futarchy_core::market_state_mutation_auth::add_authorized_package_for_testing(
        &mut market_registry,
        @futarchy_proposal,
    );

    let mut escrow_registry = futarchy_core::escrow_mutation_auth::create_registry_for_testing(ctx);
    futarchy_core::escrow_mutation_auth::add_authorized_package_for_testing(
        &mut escrow_registry,
        @futarchy_proposal,
    );

    (market_registry, escrow_registry)
}

#[test_only]
fun register_two_outcome_caps(
    escrow: &mut futarchy_markets_primitives::coin_escrow::TokenEscrow<
        futarchy_one_shot_utils::test_coin_a::TEST_COIN_A,
        futarchy_one_shot_utils::test_coin_b::TEST_COIN_B,
    >,
    ctx: &mut TxContext,
) {
    let cond_asset_0 = sui::coin::create_treasury_cap_for_testing<TEST_COND_ASSET_0>(ctx);
    let cond_stable_0 = sui::coin::create_treasury_cap_for_testing<TEST_COND_STABLE_0>(ctx);
    futarchy_markets_primitives::coin_escrow::register_conditional_caps<
        futarchy_one_shot_utils::test_coin_a::TEST_COIN_A,
        futarchy_one_shot_utils::test_coin_b::TEST_COIN_B,
        TEST_COND_ASSET_0,
        TEST_COND_STABLE_0,
    >(escrow, 0, cond_asset_0, cond_stable_0);

    let cond_asset_1 = sui::coin::create_treasury_cap_for_testing<TEST_COND_ASSET_1>(ctx);
    let cond_stable_1 = sui::coin::create_treasury_cap_for_testing<TEST_COND_STABLE_1>(ctx);
    futarchy_markets_primitives::coin_escrow::register_conditional_caps<
        futarchy_one_shot_utils::test_coin_a::TEST_COIN_A,
        futarchy_one_shot_utils::test_coin_b::TEST_COIN_B,
        TEST_COND_ASSET_1,
        TEST_COND_STABLE_1,
    >(escrow, 1, cond_asset_1, cond_stable_1);
}

#[test]
fun test_advance_state_seeds_twap_from_config_observation() {
    use futarchy_core::escrow_mutation_auth;
    use futarchy_core::market_state_mutation_auth;
    use futarchy_markets_primitives::coin_escrow;
    use futarchy_markets_primitives::conditional_amm;
    use futarchy_markets_primitives::market_state;
    use futarchy_one_shot_utils::constants;
    use futarchy_one_shot_utils::math;
    use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
    use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
    use sui::clock;
    use sui::test_scenario::{Self as ts};

    let mut scenario = ts::begin(@0xA);
    let ctx = ts::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 60_001);

    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 0, false, ctx);
    set_state_for_testing(&mut proposal, state_review());
    set_created_at_for_testing(&mut proposal, 0);
    set_twap_start_delay_for_testing(&mut proposal, 0);
    // Simulate DAO config observation (initialization price or previous winning TWAP)
    let config_price = math::mul_div_to_128(
        5_000,
        constants::price_precision_scale(),
        2_000,
    );
    set_twap_initial_observation_for_testing(&mut proposal, option::some(config_price));

    let mut market = market_state::create_for_testing(2, ctx);
    market_state::set_proposal_id_for_testing(&mut market, object::id(&proposal));
    market_state::set_dao_id_for_testing(&mut market, get_dao_id(&proposal));
    let mut escrow = coin_escrow::create_test_escrow_with_market_state<TEST_COIN_A, TEST_COIN_B>(
        2,
        market,
        ctx,
    );
    set_market_state_id_for_testing(&mut proposal, coin_escrow::market_state_id(&escrow));
    let (market_registry, escrow_registry) = create_test_registries_for_advance_state(ctx);
    let lp_treasury = sui::coin::create_treasury_cap_for_testing<TEST_LP>(ctx);
    // Spot pool has DIFFERENT reserves (3:1) — should NOT affect the TWAP seed
    let spot_pool = unified_spot_pool::create_pool_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury, 2_000, 6_000, 30, ctx,
    );
    let proposal_auth = proposal_mutation_auth::create_for_testing(object::id(&proposal));
    let changed = advance_state<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        &mut proposal,
        &proposal_auth,
        &mut escrow,
        &market_registry,
        &escrow_registry,
        &spot_pool,
        object::id(&spot_pool),
        &clock,
        ctx,
    );

    assert!(changed, 0);
    assert!(get_state(&proposal) == state_trading(), 1);

    // TWAP seed comes from config observation, NOT spot reserves
    assert!(get_twap_initial_observation(&proposal) == option::some(config_price), 2);

    let market = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market);
    assert!(pools.length() == 2, 3);
    assert!(conditional_amm::get_price(&pools[0]) == config_price, 4);
    assert!(conditional_amm::get_price(&pools[1]) == config_price, 5);

    destroy_for_testing(proposal);
    coin_escrow::destroy_for_testing(escrow);
    market_state_mutation_auth::destroy_registry_for_testing(market_registry);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_advance_state_falls_back_to_spot_pool_initial_reserves() {
    use futarchy_core::escrow_mutation_auth;
    use futarchy_core::market_state_mutation_auth;
    use futarchy_markets_primitives::coin_escrow;
    use futarchy_markets_primitives::conditional_amm;
    use futarchy_markets_primitives::market_state;
    use futarchy_one_shot_utils::constants;
    use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
    use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
    use sui::clock;
    use sui::test_scenario::{Self as ts};

    let mut scenario = ts::begin(@0xA);
    let ctx = ts::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 60_001);

    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 0, false, ctx);
    set_state_for_testing(&mut proposal, state_review());
    set_created_at_for_testing(&mut proposal, 0);
    set_twap_start_delay_for_testing(&mut proposal, 0);

    let mut market = market_state::create_for_testing(2, ctx);
    market_state::set_proposal_id_for_testing(&mut market, object::id(&proposal));
    market_state::set_dao_id_for_testing(&mut market, get_dao_id(&proposal));
    let mut escrow = coin_escrow::create_test_escrow_with_market_state<TEST_COIN_A, TEST_COIN_B>(
        2,
        market,
        ctx,
    );
    set_market_state_id_for_testing(&mut proposal, coin_escrow::market_state_id(&escrow));
    let (market_registry, escrow_registry) = create_test_registries_for_advance_state(ctx);
    let lp_treasury = sui::coin::create_treasury_cap_for_testing<TEST_LP>(ctx);
    let mut spot_pool = unified_spot_pool::create_pool_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury, 2_000, 6_000, 30, ctx,
    );
    unified_spot_pool::add_liquidity_for_testing(
        &mut spot_pool,
        balance::create_for_testing<TEST_COIN_A>(4_000),
        balance::create_for_testing<TEST_COIN_B>(2_000),
    );
    let proposal_auth = proposal_mutation_auth::create_for_testing(object::id(&proposal));
    let changed = advance_state<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        &mut proposal,
        &proposal_auth,
        &mut escrow,
        &market_registry,
        &escrow_registry,
        &spot_pool,
        object::id(&spot_pool),
        &clock,
        ctx,
    );

    let expected_price = math::mul_div_to_128(
        6_000,
        constants::price_precision_scale(),
        2_000,
    );
    let current_price = math::mul_div_to_128(
        8_000,
        constants::price_precision_scale(),
        6_000,
    );

    assert!(changed, 0);
    assert!(get_state(&proposal) == state_trading(), 1);
    assert!(get_twap_initial_observation(&proposal) == option::some(expected_price), 2);
    assert!(expected_price != current_price, 3);

    let market = coin_escrow::get_market_state(&escrow);
    let pools = market_state::borrow_amm_pools(market);
    assert!(pools.length() == 2, 4);
    assert!(conditional_amm::get_price(&pools[0]) == expected_price, 5);
    assert!(conditional_amm::get_price(&pools[1]) == expected_price, 6);

    destroy_for_testing(proposal);
    coin_escrow::destroy_for_testing(escrow);
    market_state_mutation_auth::destroy_registry_for_testing(market_registry);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_advance_state_uses_actual_time_when_called_late() {
    use futarchy_core::escrow_mutation_auth;
    use futarchy_core::market_state_mutation_auth;
    use futarchy_markets_primitives::coin_escrow;
    use futarchy_markets_primitives::market_state;
    use futarchy_one_shot_utils::constants;
    use futarchy_one_shot_utils::math;
    use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
    use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
    use sui::clock;
    use sui::test_scenario::{Self as ts};

    let mut scenario = ts::begin(@0xA);
    let ctx = ts::ctx(&mut scenario);
    let mut clock = clock::create_for_testing(ctx);
    // Clock at 90s, but review_end is at 60s; cranking is 30s late.
    clock::set_for_testing(&mut clock, 90_000);

    let mut proposal = create_test_proposal<TEST_COIN_A, TEST_COIN_B>(2, 0, false, ctx);
    set_state_for_testing(&mut proposal, state_review());
    set_created_at_for_testing(&mut proposal, 0);
    set_twap_start_delay_for_testing(&mut proposal, 0);
    // Set config observation so advance_state can seed the TWAP oracle
    let config_price = math::mul_div_to_128(
        4_000,
        constants::price_precision_scale(),
        4_000,
    );
    set_twap_initial_observation_for_testing(&mut proposal, option::some(config_price));

    let mut market = market_state::create_for_testing(2, ctx);
    market_state::set_proposal_id_for_testing(&mut market, object::id(&proposal));
    market_state::set_dao_id_for_testing(&mut market, get_dao_id(&proposal));
    let mut escrow = coin_escrow::create_test_escrow_with_market_state<TEST_COIN_A, TEST_COIN_B>(
        2,
        market,
        ctx,
    );
    set_market_state_id_for_testing(&mut proposal, coin_escrow::market_state_id(&escrow));
    let (market_registry, escrow_registry) = create_test_registries_for_advance_state(ctx);
    let lp_treasury = sui::coin::create_treasury_cap_for_testing<TEST_LP>(ctx);
    let spot_pool = unified_spot_pool::create_pool_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury, 4_000, 4_000, 30, ctx,
    );
    let proposal_auth = proposal_mutation_auth::create_for_testing(object::id(&proposal));
    let changed = advance_state<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        &mut proposal,
        &proposal_auth,
        &mut escrow,
        &market_registry,
        &escrow_registry,
        &spot_pool,
        object::id(&spot_pool),
        &clock,
        ctx,
    );

    assert!(changed, 0);

    // Trading starts at actual crank time so cranker downtime does not shrink
    // the configured trading or TWAP window.
    let market = coin_escrow::get_market_state(&escrow);
    assert!(market_state::get_trading_start(market) == 90_000, 1);
    assert!(get_trading_started_at(&proposal) == 90_000, 2);
    // trading_end = actual start (90s) + trading_period (120s) = 210s
    assert!(market_state::get_trading_end_time(market) == option::some(210_000), 3);

    let pools = market_state::borrow_amm_pools(market);
    let (_, oracle_last_timestamp, _, _, oracle_last_window_end, _, oracle_market_start, _, _, _) =
        conditional_amm::get_oracle_full_state(&pools[0]);
    assert!(oracle_market_start == option::some(90_000), 4);
    assert!(oracle_last_timestamp == 90_000, 5);
    assert!(oracle_last_window_end == 90_000, 6);

    destroy_for_testing(proposal);
    coin_escrow::destroy_for_testing(escrow);
    market_state_mutation_auth::destroy_registry_for_testing(market_registry);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
