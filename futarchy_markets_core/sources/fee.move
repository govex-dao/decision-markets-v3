// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_markets_core::fee;

use std::ascii::String as AsciiString;
use std::type_name::{Self, TypeName};
use std::u64;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field;
use sui::event;
use sui::sui::SUI;
use sui::table::Table;
use sui::transfer::{public_share_object, public_transfer};
use futarchy_one_shot_utils::constants;

// === Introduction ===
// Manages all fees earnt by the protocol. It is also the interface for admin fee withdrawal

// === Errors ===
const EInvalidPayment: u64 = 0;
const EStableTypeNotFound: u64 = 1;
const EBadWitness: u64 = 2;
const EInsufficientTreasuryBalance: u64 = 5;
const EArithmeticOverflow: u64 = 6;
const EInvalidAdminCap: u64 = 7;
const EFeeExceedsFiftyXCap: u64 = 12;
const ECoinTypeAlreadyExists: u64 = 13;

// === Structs ===

public struct FEE has drop {}

public struct FeeManager has key, store {
    id: UID,
    admin_cap_id: ID,
    dao_creation_fee: u64,
    proposal_creation_fee_per_outcome: u64,
    launchpad_creation_fee: u64,
    // Pending proposal-fee updates (6-month delay for increases). DAO and launchpad fee
    // updates apply immediately, so they have no pending state.
    pending_proposal_fee: Option<u64>,
    pending_proposal_fee_effective_ts: Option<u64>,
    // 50x cap baseline for the proposal fee.
    proposal_fee_baseline: u64,
    proposal_baseline_reset_ts: u64,
    // All coin fees stored uniformly in dynamic fields: FeeRegistry<CoinType> → Balance<CoinType>
}

public struct FeeAdminCap has key, store {
    id: UID,
}

/// Stores fee amounts for a specific coin type
public struct CoinFeeConfig has store {
    coin_type: TypeName,
    decimals: u8,
    dao_creation_fee: u64,
    proposal_creation_fee_per_outcome: u64,
    // Pending updates with 6-month delay (independent timestamps per fee type)
    pending_creation_fee: Option<u64>,
    pending_creation_fee_effective_timestamp: Option<u64>,
    pending_proposal_fee: Option<u64>,
    pending_proposal_fee_effective_timestamp: Option<u64>,
    // 50x cap tracking - baseline fees that reset every 6 months
    // Each fee type has its own baseline and reset timestamp to prevent interference
    creation_fee_baseline: u64,
    proposal_fee_baseline: u64,
    creation_baseline_reset_timestamp: u64,
    proposal_baseline_reset_timestamp: u64,
}

// === Events ===

public struct DAOCreationFeeUpdated has copy, drop {
    old_fee: u64,
    new_fee: u64,
    admin: address,
    timestamp: u64,
}

public struct ProposalCreationFeeUpdated has copy, drop {
    old_fee: u64,
    new_fee_per_outcome: u64,
    admin: address,
    timestamp: u64,
}

public struct LaunchpadCreationFeeUpdated has copy, drop {
    old_fee: u64,
    new_fee: u64,
    admin: address,
    timestamp: u64,
}

public struct DAOCreationFeeCollected has copy, drop {
    amount: u64,
    payer: address,
    timestamp: u64,
}

public struct ProposalCreationFeeCollected has copy, drop {
    amount: u64,
    payer: address,
    timestamp: u64,
}

public struct LaunchpadCreationFeeCollected has copy, drop {
    amount: u64,
    payer: address,
    timestamp: u64,
}

public struct LaunchpadBidFeeCollected has copy, drop {
    amount: u64,
    payer: address,
    timestamp: u64,
}

public struct FeesCollected has copy, drop {
    amount: u64,
    coin_type: AsciiString,
    proposal_id: ID,
    timestamp: u64,
}

public struct FeesWithdrawn has copy, drop {
    amount: u64,
    coin_type: AsciiString,
    recipient: address,
    timestamp: u64,
}

public struct GlobalFeeIncreaseScheduled has copy, drop {
    fee_type: u8, // 0 = dao, 1 = proposal, 2 = launchpad
    current_fee: u64,
    scheduled_fee: u64,
    effective_timestamp: u64,
    admin: address,
    timestamp: u64,
}

public struct ProposalFeePendingApplied has copy, drop {
    new_proposal_fee: u64,
    timestamp: u64,
}

// === Public Functions ===
/// Package initialization
///
/// IMPORTANT: This function creates and transfers FeeAdminCap to the package publisher.
/// For governance actions to work, the FeeAdminCap MUST be:
/// 1. Transferred to the protocol DAO account
/// 2. Registered as a managed asset with key: "protocol:fee_admin_cap"
///
/// This is typically done in deployment scripts after package publication.
fun init(witness: FEE, ctx: &mut TxContext) {
    // Verify that the witness is valid and one-time only.
    assert!(sui::types::is_one_time_witness(&witness), EBadWitness);

    let fee_admin_cap = FeeAdminCap {
        id: object::new(ctx),
    };

    let fee_manager = FeeManager {
        id: object::new(ctx),
        admin_cap_id: object::id(&fee_admin_cap),
        dao_creation_fee: constants::default_dao_creation_fee(),
        proposal_creation_fee_per_outcome: constants::default_proposal_fee_per_outcome(),
        launchpad_creation_fee: constants::default_launchpad_creation_fee(),
        pending_proposal_fee: option::none(),
        pending_proposal_fee_effective_ts: option::none(),
        proposal_fee_baseline: constants::default_proposal_fee_per_outcome(),
        proposal_baseline_reset_ts: 0,
    };

    public_share_object(fee_manager);
    // FeeAdminCap is transferred to publisher - must be moved to protocol DAO account
    public_transfer(fee_admin_cap, ctx.sender());

    // Consuming the witness ensures one-time initialization.
    let _ = witness;
}

// === Package Functions ===
// Generic internal fee collection function
fun deposit_payment(
    fee_manager: &mut FeeManager,
    fee_amount: u64,
    payment: Coin<SUI>,
    _clock: &Clock,
): u64 {
    // Verify payment
    let payment_amount = payment.value();
    assert!(payment_amount == fee_amount, EInvalidPayment);

    // Process payment using unified deposit
    let paid_balance = payment.into_balance();
    deposit_fees_internal(fee_manager, paid_balance);
    return payment_amount
    // Event emission will be handled by specific wrappers
}

// Function to collect DAO creation fee
public fun deposit_dao_creation_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let fee_amount = fee_manager.dao_creation_fee;

    let payment_amount = deposit_payment(fee_manager, fee_amount, payment, clock);

    // Emit event
    event::emit(DAOCreationFeeCollected {
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Function to collect launchpad creation fee
public fun deposit_launchpad_creation_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let fee_amount = fee_manager.launchpad_creation_fee;

    let payment_amount = deposit_payment(fee_manager, fee_amount, payment, clock);

    // Emit event
    event::emit(LaunchpadCreationFeeCollected {
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Function to collect launchpad bid fee (per contribution)
// Amount is validated by the caller (launchpad::contribute) against the Raise's snapshot
public fun deposit_launchpad_bid_fee(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    expected_fee: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let payment_amount = deposit_payment(fee_manager, expected_fee, payment, clock);

    event::emit(LaunchpadBidFeeCollected {
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Function to collect proposal creation fee
public fun deposit_proposal_creation_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    outcome_count: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Apply any matured pending proposal fee before reading the current rate
    apply_pending_proposal_fee(fee_manager, clock);
    // Use u128 arithmetic to prevent overflow
    let fee_amount_u128 =
        (fee_manager.proposal_creation_fee_per_outcome as u128) * (outcome_count as u128);

    // Check that result fits in u64
    assert!(fee_amount_u128 <= (u64::max_value!() as u128), EArithmeticOverflow); // u64::max_value()
    let fee_amount = (fee_amount_u128 as u64);

    // deposit_payment asserts the payment amount is exactly the fee_amount
    let payment_amount = deposit_payment(fee_manager, fee_amount, payment, clock);

    // Emit event
    event::emit(ProposalCreationFeeCollected {
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// === Admin Functions ===

/// Validate that `admin_cap` controls `fee_manager`.
/// Useful for admin-gated flows that do not themselves withdraw fees.
public fun assert_admin_cap(fee_manager: &FeeManager, admin_cap: &FeeAdminCap) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
}

/// UNIFIED withdrawal function for ANY coin type (including SUI)
/// Used by governance actions to deposit fees into treasury vault
/// If amount is 0, withdraws all available fees
public fun withdraw_fees_as_coin<CoinType>(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // Verify the admin cap belongs to this fee manager
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);

    // Check if this coin type exists in the fee registry
    if (
        !dynamic_field::exists_with_type<FeeRegistry<CoinType>, Balance<CoinType>>(
            &fee_manager.id,
            FeeRegistry<CoinType> {},
        )
    ) {
        // Return empty coin if no fees of this type have been collected
        return coin::zero<CoinType>(ctx)
    };

    let fee_balance = dynamic_field::borrow_mut<FeeRegistry<CoinType>, Balance<CoinType>>(
        &mut fee_manager.id,
        FeeRegistry<CoinType> {},
    );

    let withdrawal_amount = if (amount == 0) {
        fee_balance.value()
    } else {
        amount
    };

    if (withdrawal_amount == 0) {
        return coin::zero<CoinType>(ctx)
    };

    assert!(fee_balance.value() >= withdrawal_amount, EInsufficientTreasuryBalance);

    let withdrawn = fee_balance.split(withdrawal_amount);
    let coin = withdrawn.into_coin(ctx);

    let type_name = type_name::with_original_ids<CoinType>();
    let type_str = type_name.into_string();

    event::emit(FeesWithdrawn {
        amount: withdrawal_amount,
        coin_type: type_str,
        recipient: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    coin
}

// Admin function to update DAO creation fee (immediate)
public entry fun update_dao_creation_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    let old_fee = fee_manager.dao_creation_fee;
    fee_manager.dao_creation_fee = new_fee;
    event::emit(DAOCreationFeeUpdated {
        old_fee,
        new_fee,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Admin function to update proposal creation fee (with 6-month delay and 50x cap for increases)
public entry fun update_proposal_creation_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    new_fee_per_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);

    // Apply any matured pending fees so old_fee reflects the true current rate
    apply_pending_proposal_fee(fee_manager, clock);
    let current_time = clock.timestamp_ms();

    // Reset baseline if 6 months have passed
    if (current_time >= fee_manager.proposal_baseline_reset_ts + constants::six_months_ms()) {
        fee_manager.proposal_fee_baseline = resettable_baseline(
            fee_manager.proposal_creation_fee_per_outcome,
            0,
            fee_manager.proposal_fee_baseline,
        );
        fee_manager.proposal_baseline_reset_ts = current_time;
    };

    // Enforce 50x cap from baseline
    let max_allowed = max_allowed_from_baseline(fee_manager.proposal_fee_baseline);
    assert!(new_fee_per_outcome <= max_allowed, EFeeExceedsFiftyXCap);

    let old_fee = fee_manager.proposal_creation_fee_per_outcome;
    if (new_fee_per_outcome <= old_fee) {
        // Decrease - apply immediately, clear any pending increase
        fee_manager.proposal_creation_fee_per_outcome = new_fee_per_outcome;
        fee_manager.pending_proposal_fee = option::none();
        fee_manager.pending_proposal_fee_effective_ts = option::none();
        event::emit(ProposalCreationFeeUpdated {
            old_fee,
            new_fee_per_outcome,
            admin: ctx.sender(),
            timestamp: current_time,
        });
    } else {
        // Increase - schedule with 6-month delay
        let effective_ts = current_time + constants::six_months_ms();
        fee_manager.pending_proposal_fee = option::some(new_fee_per_outcome);
        fee_manager.pending_proposal_fee_effective_ts = option::some(effective_ts);
        event::emit(GlobalFeeIncreaseScheduled {
            fee_type: 1,
            current_fee: old_fee,
            scheduled_fee: new_fee_per_outcome,
            effective_timestamp: effective_ts,
            admin: ctx.sender(),
            timestamp: current_time,
        });
    };
}

// Admin function to update launchpad creation fee (immediate)
public entry fun update_launchpad_creation_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    let old_fee = fee_manager.launchpad_creation_fee;
    fee_manager.launchpad_creation_fee = new_fee;
    event::emit(LaunchpadCreationFeeUpdated {
        old_fee,
        new_fee,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Apply a pending proposal-fee increase if its delay has passed (permissionless).
/// Only the proposal fee has a delayed schedule; DAO and launchpad fees apply immediately.
public fun apply_pending_proposal_fee(
    fee_manager: &mut FeeManager,
    clock: &Clock,
) {
    let current_time = clock.timestamp_ms();

    if (fee_manager.pending_proposal_fee_effective_ts.is_none()) return;

    let effective_time = *fee_manager.pending_proposal_fee_effective_ts.borrow();
    if (current_time < effective_time) return;

    if (fee_manager.pending_proposal_fee.is_some()) {
        let new_fee = *fee_manager.pending_proposal_fee.borrow();
        fee_manager.proposal_creation_fee_per_outcome = new_fee;
        fee_manager.pending_proposal_fee = option::none();
        fee_manager.pending_proposal_fee_effective_ts = option::none();
        event::emit(ProposalFeePendingApplied {
            new_proposal_fee: new_fee,
            timestamp: current_time,
        });
    } else {
        fee_manager.pending_proposal_fee_effective_ts = option::none();
    };
}

// === AMM Fees ===

/// Unified registry type for ALL coin fee balances (including SUI)
public struct FeeRegistry<phantom T> has copy, drop, store {}

/// Generic protocol fee deposit - works for ANY coin type including SUI.
/// Requires the FeeAdminCap so arbitrary callers cannot pollute fee-manager
/// state with fake coin balances.
public fun deposit_fees<CoinType>(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    fees: Balance<CoinType>,
    _clock: &Clock,
) {
    assert_admin_cap(fee_manager, admin_cap);
    deposit_fees_internal(fee_manager, fees);
}

/// Generic fee deposit with proposal_id - works for ANY coin type
/// Use this for AMM swap fees that are tied to a specific proposal
public fun deposit_fees_with_proposal<CoinType>(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    fees: Balance<CoinType>,
    proposal_id: ID,
    clock: &Clock,
) {
    assert_admin_cap(fee_manager, admin_cap);
    let amount = deposit_fees_internal(fee_manager, fees);
    if (amount == 0) {
        return
    };

    let type_name = type_name::with_original_ids<CoinType>();
    let type_str = type_name.into_string();
    event::emit(FeesCollected {
        amount,
        coin_type: type_str,
        proposal_id,
        timestamp: clock.timestamp_ms(),
    });
}

fun deposit_fees_internal<CoinType>(
    fee_manager: &mut FeeManager,
    fees: Balance<CoinType>,
): u64 {
    let amount = fees.value();
    if (amount == 0) {
        fees.destroy_zero();
        return 0
    };

    if (
        dynamic_field::exists_with_type<FeeRegistry<CoinType>, Balance<CoinType>>(
            &fee_manager.id,
            FeeRegistry<CoinType> {},
        )
    ) {
        let fee_balance = dynamic_field::borrow_mut<FeeRegistry<CoinType>, Balance<CoinType>>(
            &mut fee_manager.id,
            FeeRegistry<CoinType> {},
        );
        fee_balance.join(fees);
    } else {
        dynamic_field::add(&mut fee_manager.id, FeeRegistry<CoinType> {}, fees);
    };

    amount
}

// === View Functions ===
public fun get_dao_creation_fee(fee_manager: &FeeManager): u64 {
    fee_manager.dao_creation_fee
}

public fun get_proposal_creation_fee_per_outcome(fee_manager: &FeeManager): u64 {
    fee_manager.proposal_creation_fee_per_outcome
}

public fun get_launchpad_creation_fee(fee_manager: &FeeManager): u64 {
    fee_manager.launchpad_creation_fee
}

public fun get_sui_balance(fee_manager: &FeeManager): u64 {
    get_fee_balance<SUI>(fee_manager)
}

/// Generic function to get fee balance for any coin type
public fun get_fee_balance<CoinType>(fee_manager: &FeeManager): u64 {
    if (
        dynamic_field::exists_with_type<FeeRegistry<CoinType>, Balance<CoinType>>(
            &fee_manager.id,
            FeeRegistry<CoinType> {},
        )
    ) {
        let fee_balance = dynamic_field::borrow<FeeRegistry<CoinType>, Balance<CoinType>>(
            &fee_manager.id,
            FeeRegistry<CoinType> {},
        );
        fee_balance.value()
    } else {
        0
    }
}

// === Coin-specific Fee Management ===

/// Add a new coin type with its fee configuration
public fun add_coin_fee_config(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    decimals: u8,
    dao_creation_fee: u64,
    proposal_fee_per_outcome: u64,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    // Check that coin type doesn't already exist to provide clear error message
    assert!(!dynamic_field::exists_(&fee_manager.id, coin_type), ECoinTypeAlreadyExists);

    let config = CoinFeeConfig {
        coin_type,
        decimals,
        dao_creation_fee,
        proposal_creation_fee_per_outcome: proposal_fee_per_outcome,
        pending_creation_fee: option::none(),
        pending_creation_fee_effective_timestamp: option::none(),
        pending_proposal_fee: option::none(),
        pending_proposal_fee_effective_timestamp: option::none(),
        // Initialize baselines to current fees - each has its own reset timestamp
        creation_fee_baseline: dao_creation_fee,
        proposal_fee_baseline: proposal_fee_per_outcome,
        creation_baseline_reset_timestamp: clock.timestamp_ms(),
        proposal_baseline_reset_timestamp: clock.timestamp_ms(),
    };

    // Store using coin type as key
    dynamic_field::add(&mut fee_manager.id, coin_type, config);
}

fun resettable_baseline(candidate_fee: u64, global_fee: u64, prior_baseline: u64): u64 {
    if (candidate_fee > 0) {
        return candidate_fee
    };
    if (global_fee > 0) {
        return global_fee
    };
    if (prior_baseline > 0) {
        return prior_baseline
    };
    // Keep 50x cap semantics but avoid permanent zero-lock.
    1
}

fun max_allowed_from_baseline(baseline: u64): u64 {
    if (baseline > 0xFFFFFFFFFFFFFFFF / constants::max_fee_multiplier()) {
        0xFFFFFFFFFFFFFFFF
    } else {
        baseline * constants::max_fee_multiplier()
    }
}

/// Entry wrapper for add_coin_fee_config that takes coin type as generic parameter
public entry fun add_coin_fee_config_entry<CoinType>(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    decimals: u8,
    dao_creation_fee: u64,
    proposal_fee_per_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let coin_type = type_name::get<CoinType>();
    add_coin_fee_config(
        fee_manager,
        admin_cap,
        coin_type,
        decimals,
        dao_creation_fee,
        proposal_fee_per_outcome,
        clock,
        ctx,
    );
}

/// Update creation fee for a specific coin type (with 6-month delay and 50x cap)
public fun update_coin_creation_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    new_fee: u64,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);

    // Apply any matured pending fees so old fee reflects the true current rate
    apply_pending_coin_fees(fee_manager, coin_type, clock);

    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);
    let current_time = clock.timestamp_ms();

    // Check if 6 months have passed since creation baseline was set - if so, reset baseline
    if (current_time >= config.creation_baseline_reset_timestamp + constants::six_months_ms()) {
        config.creation_fee_baseline = resettable_baseline(
            config.dao_creation_fee,
            0,
            config.creation_fee_baseline,
        );
        config.creation_baseline_reset_timestamp = current_time;
    };

    // Enforce 50x cap from baseline (with overflow protection)
    let max_allowed_creation = max_allowed_from_baseline(config.creation_fee_baseline);
    assert!(new_fee <= max_allowed_creation, EFeeExceedsFiftyXCap);

    // Allow immediate decrease, delayed increase
    if (new_fee <= config.dao_creation_fee) {
        // Fee decrease - apply immediately
        config.dao_creation_fee = new_fee;
        // Clear any previously scheduled increase to prevent stale pending
        // increases from being applied later by apply_pending_coin_fees
        config.pending_creation_fee = option::none();
        config.pending_creation_fee_effective_timestamp = option::none();
    } else {
        // Fee increase - apply after delay
        let effective_timestamp = current_time + constants::six_months_ms();
        config.pending_creation_fee = option::some(new_fee);
        config.pending_creation_fee_effective_timestamp = option::some(effective_timestamp);
    };
}

/// Update proposal fee for a specific coin type (with 6-month delay and 50x cap)
public fun update_coin_proposal_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    new_fee_per_outcome: u64,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);

    // Apply any matured pending fees so old fee reflects the true current rate
    apply_pending_coin_fees(fee_manager, coin_type, clock);

    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);
    let current_time = clock.timestamp_ms();

    // Check if 6 months have passed since proposal baseline was set - if so, reset baseline
    if (current_time >= config.proposal_baseline_reset_timestamp + constants::six_months_ms()) {
        config.proposal_fee_baseline = resettable_baseline(
            config.proposal_creation_fee_per_outcome,
            0,
            config.proposal_fee_baseline,
        );
        config.proposal_baseline_reset_timestamp = current_time;
    };

    // Enforce 50x cap from baseline (with overflow protection)
    let max_allowed_proposal = max_allowed_from_baseline(config.proposal_fee_baseline);
    assert!(new_fee_per_outcome <= max_allowed_proposal, EFeeExceedsFiftyXCap);

    // Allow immediate decrease, delayed increase
    if (new_fee_per_outcome <= config.proposal_creation_fee_per_outcome) {
        // Fee decrease - apply immediately
        config.proposal_creation_fee_per_outcome = new_fee_per_outcome;
        // Clear any previously scheduled increase to prevent stale pending
        // increases from being applied later by apply_pending_coin_fees
        config.pending_proposal_fee = option::none();
        config.pending_proposal_fee_effective_timestamp = option::none();
    } else {
        // Fee increase - apply after delay
        let effective_timestamp = current_time + constants::six_months_ms();
        config.pending_proposal_fee = option::some(new_fee_per_outcome);
        config.pending_proposal_fee_effective_timestamp = option::some(effective_timestamp);
    };
}

/// Apply pending fee updates if their respective delays have passed
/// Each fee type is applied independently based on its own effective timestamp
public fun apply_pending_coin_fees(
    fee_manager: &mut FeeManager,
    coin_type: TypeName,
    clock: &Clock,
) {
    if (!dynamic_field::exists_(&fee_manager.id, coin_type)) {
        return
    };

    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);
    let current_time = clock.timestamp_ms();

    // Apply pending creation fee if its delay has passed (independent of proposal fee)
    if (config.pending_creation_fee_effective_timestamp.is_some()) {
        let effective_time = *config.pending_creation_fee_effective_timestamp.borrow();
        if (current_time >= effective_time) {
            if (config.pending_creation_fee.is_some()) {
                config.dao_creation_fee = *config.pending_creation_fee.borrow();
                config.pending_creation_fee = option::none();
            };
            config.pending_creation_fee_effective_timestamp = option::none();
        };
    };

    // Apply pending proposal fee if its delay has passed (independent of creation fee)
    if (config.pending_proposal_fee_effective_timestamp.is_some()) {
        let effective_time = *config.pending_proposal_fee_effective_timestamp.borrow();
        if (current_time >= effective_time) {
            if (config.pending_proposal_fee.is_some()) {
                config.proposal_creation_fee_per_outcome = *config.pending_proposal_fee.borrow();
                config.pending_proposal_fee = option::none();
            };
            config.pending_proposal_fee_effective_timestamp = option::none();
        };
    };
}

/// Get fee config for a specific coin type
public fun get_coin_fee_config(fee_manager: &FeeManager, coin_type: TypeName): &CoinFeeConfig {
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);
    dynamic_field::borrow(&fee_manager.id, coin_type)
}

// ======== Test Functions ========
#[test_only]
public fun create_fee_manager_for_testing(ctx: &mut TxContext) {
    let admin_cap = FeeAdminCap {
        id: object::new(ctx),
    };

    let fee_manager = FeeManager {
        id: object::new(ctx),
        admin_cap_id: object::id(&admin_cap),
        dao_creation_fee: constants::default_dao_creation_fee(),
        proposal_creation_fee_per_outcome: constants::default_proposal_fee_per_outcome(),
        launchpad_creation_fee: constants::default_launchpad_creation_fee(),
        pending_proposal_fee: option::none(),
        pending_proposal_fee_effective_ts: option::none(),
        proposal_fee_baseline: constants::default_proposal_fee_per_outcome(),
        proposal_baseline_reset_ts: 0,
    };

    public_share_object(fee_manager);
    public_transfer(admin_cap, ctx.sender());
}

#[test_only]
public fun create_fake_admin_cap_for_testing(ctx: &mut TxContext): FeeAdminCap {
    FeeAdminCap {
        id: object::new(ctx),
    }
}

/// Get pending creation fee for testing
#[test_only]
public fun get_pending_creation_fee(config: &CoinFeeConfig): Option<u64> {
    config.pending_creation_fee
}

/// Get pending proposal fee for testing
#[test_only]
public fun get_pending_proposal_fee(config: &CoinFeeConfig): Option<u64> {
    config.pending_proposal_fee
}

/// Get creation fee for testing
#[test_only]
public fun get_coin_creation_fee(config: &CoinFeeConfig): u64 {
    config.dao_creation_fee
}

/// Get proposal fee for testing
#[test_only]
public fun get_coin_proposal_fee(config: &CoinFeeConfig): u64 {
    config.proposal_creation_fee_per_outcome
}

// === Global Fee Test Helpers ===

#[test_only]
public fun get_pending_proposal_fee_global(fee_manager: &FeeManager): Option<u64> {
    fee_manager.pending_proposal_fee
}

#[test_only]
public fun get_pending_proposal_fee_effective_ts_global(fee_manager: &FeeManager): Option<u64> {
    fee_manager.pending_proposal_fee_effective_ts
}

// === Unit Tests for Independent Fee Timestamps ===

#[test_only]
public struct TEST_COIN has drop {}

#[test]
/// Test that independent fee timestamps work correctly:
/// - Schedule creation fee increase at T1
/// - Schedule proposal fee increase at T2 (later)
/// - Advance clock past T1 but before T2
/// - Apply pending fees
/// - Verify only creation fee is applied, proposal fee remains pending
fun test_independent_fee_timestamps() {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    // Create fee manager and admin cap
    create_fee_manager_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, sender);
    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Initial time: 1000ms
    clock::set_for_testing(&mut clock, 1000);

    // Add coin fee config with initial fees
    let coin_type = type_name::get<TEST_COIN>();
    add_coin_fee_config(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        6, // decimals
        1_000_000, // initial creation fee
        500_000, // initial proposal fee
        &clock,
        ts::ctx(&mut scenario),
    );

    // Schedule creation fee increase at T1 = 1000 + FEE_UPDATE_DELAY_MS
    update_coin_creation_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        2_000_000, // new creation fee (increase)
        &clock,
        ts::ctx(&mut scenario),
    );

    // Advance time by 1 day (86_400_000 ms)
    clock::increment_for_testing(&mut clock, 86_400_000);

    // Schedule proposal fee increase at T2 = (1000 + 86_400_000) + FEE_UPDATE_DELAY_MS
    // This is 1 day later than T1
    update_coin_proposal_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        1_000_000, // new proposal fee (increase)
        &clock,
        ts::ctx(&mut scenario),
    );

    // Verify both fees are pending
    {
        let config = get_coin_fee_config(&fee_manager, coin_type);
        assert!(get_pending_creation_fee(config).is_some(), 0);
        assert!(get_pending_proposal_fee(config).is_some(), 1);
        // Current fees should be unchanged
        assert!(get_coin_creation_fee(config) == 1_000_000, 2);
        assert!(get_coin_proposal_fee(config) == 500_000, 3);
    };

    // Advance clock past T1 but before T2
    // T1 = 1000 + six_months_ms (creation fee effective)
    // T2 = 86_401_000 + six_months_ms (proposal fee effective)
    // Current time before advance: 86_401_000
    // We advance by (six_months_ms - 43_200_000) to land at:
    // 86_401_000 + six_months_ms - 43_200_000 = six_months_ms + 43_201_000
    // This is past T1 (six_months_ms + 1000) but before T2
    clock::increment_for_testing(&mut clock, constants::six_months_ms() - 43_200_000);

    // Apply pending fees
    apply_pending_coin_fees(&mut fee_manager, coin_type, &clock);

    // Verify: creation fee applied, proposal fee still pending
    {
        let config = get_coin_fee_config(&fee_manager, coin_type);
        // Creation fee should be applied (no longer pending)
        assert!(get_pending_creation_fee(config).is_none(), 4);
        assert!(get_coin_creation_fee(config) == 2_000_000, 5);
        // Proposal fee should still be pending (not yet applied)
        assert!(get_pending_proposal_fee(config).is_some(), 6);
        assert!(get_coin_proposal_fee(config) == 500_000, 7);
    };

    // Advance past T2
    clock::increment_for_testing(&mut clock, 86_400_000); // 1 more day

    // Apply pending fees again
    apply_pending_coin_fees(&mut fee_manager, coin_type, &clock);

    // Verify: both fees now applied
    {
        let config = get_coin_fee_config(&fee_manager, coin_type);
        assert!(get_pending_creation_fee(config).is_none(), 8);
        assert!(get_pending_proposal_fee(config).is_none(), 9);
        assert!(get_coin_creation_fee(config) == 2_000_000, 10);
        assert!(get_coin_proposal_fee(config) == 1_000_000, 11);
    };

    // Cleanup
    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

#[test]
/// Test the reverse case: proposal fee is scheduled first, then creation fee later
/// Verify that applying at the right time only applies the earlier one
fun test_independent_fee_timestamps_reverse_order() {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, sender);
    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, 1000);

    let coin_type = type_name::get<TEST_COIN>();
    add_coin_fee_config(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        6,
        1_000_000,
        500_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Schedule proposal fee increase FIRST
    update_coin_proposal_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        1_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Advance time by 1 day
    clock::increment_for_testing(&mut clock, 86_400_000);

    // Schedule creation fee increase SECOND (1 day later)
    update_coin_creation_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        2_000_000,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Advance past proposal fee's effective time but not creation fee's
    // Proposal fee effective: 1000 + six_months_ms
    // Creation fee effective: 86_401_000 + six_months_ms
    // Current time before advance: 86_401_000
    // Advance by (six_months_ms - 43_200_000) to land in between
    clock::increment_for_testing(&mut clock, constants::six_months_ms() - 43_200_000);

    apply_pending_coin_fees(&mut fee_manager, coin_type, &clock);

    // Verify: proposal fee applied, creation fee still pending
    {
        let config = get_coin_fee_config(&fee_manager, coin_type);
        assert!(get_pending_proposal_fee(config).is_none(), 0);
        assert!(get_coin_proposal_fee(config) == 1_000_000, 1);
        assert!(get_pending_creation_fee(config).is_some(), 2);
        assert!(get_coin_creation_fee(config) == 1_000_000, 3);
    };

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

#[test]
/// Regression: lowering a coin-specific creation fee to zero must not permanently
/// lock future increases after baseline reset.
fun test_zero_creation_fee_can_be_increased_after_baseline_reset() {
    use sui::clock;
    use sui::test_scenario::{Self as ts};

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, sender);

    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut clock, 1000);

    let coin_type = type_name::get<TEST_COIN>();
    add_coin_fee_config(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        6,
        100,
        50,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Decrease to zero (applies immediately).
    update_coin_creation_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert!(get_coin_creation_fee(get_coin_fee_config(&fee_manager, coin_type)) == 0, 0);

    // Move past baseline reset window, then increase to a positive value.
    clock::increment_for_testing(&mut clock, constants::six_months_ms() + 1);
    update_coin_creation_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        5,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Increase should schedule (not abort due to zero baseline lock).
    let config = get_coin_fee_config(&fee_manager, coin_type);
    assert!(get_pending_creation_fee(config).is_some(), 1);

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

#[test]
/// Regression: lowering a coin-specific proposal fee to zero must not permanently
/// lock future increases after baseline reset.
fun test_zero_proposal_fee_can_be_increased_after_baseline_reset() {
    use sui::clock;
    use sui::test_scenario::{Self as ts};

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, sender);

    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut clock, 1000);

    let coin_type = type_name::get<TEST_COIN>();
    add_coin_fee_config(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        6,
        100,
        50,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Decrease to zero (applies immediately).
    update_coin_proposal_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert!(get_coin_proposal_fee(get_coin_fee_config(&fee_manager, coin_type)) == 0, 0);

    // Move past baseline reset window, then increase to a positive value.
    clock::increment_for_testing(&mut clock, constants::six_months_ms() + 1);
    update_coin_proposal_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        5,
        &clock,
        ts::ctx(&mut scenario),
    );

    // Increase should schedule (not abort due to zero baseline lock).
    let config = get_coin_fee_config(&fee_manager, coin_type);
    assert!(get_pending_proposal_fee(config).is_some(), 1);

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

// === Unit Tests for Global SUI Fee Update Semantics ===

#[test]
/// Regression: DAO fee updates are immediate, while proposal fee increases
/// still use the delayed 6-month schedule and 50x cap.
fun test_global_dao_fee_immediate_and_proposal_delay() {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, sender);
    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Set initial time well past the initial baseline reset (baselines init to 0)
    clock::set_for_testing(&mut clock, constants::six_months_ms() + 1000);

    let initial_dao_fee = fee_manager.dao_creation_fee;
    let initial_proposal_fee = fee_manager.proposal_creation_fee_per_outcome;

    // DAO fee updates apply immediately.
    let new_dao_fee = initial_dao_fee * 5;
    update_dao_creation_fee(
        &mut fee_manager,
        &admin_cap,
        new_dao_fee,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(fee_manager.dao_creation_fee == new_dao_fee, 0);

    // Advance 1 day
    clock::increment_for_testing(&mut clock, 86_400_000);

    // Proposal fee increases remain delayed.
    let new_proposal_fee = initial_proposal_fee * 3;
    update_proposal_creation_fee(
        &mut fee_manager,
        &admin_cap,
        new_proposal_fee,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(fee_manager.proposal_creation_fee_per_outcome == initial_proposal_fee, 2);
    assert!(fee_manager.pending_proposal_fee.is_some(), 3);

    // Applying before the delay expires is a no-op.
    apply_pending_proposal_fee(&mut fee_manager, &clock);
    assert!(fee_manager.proposal_creation_fee_per_outcome == initial_proposal_fee, 4);
    assert!(fee_manager.pending_proposal_fee.is_some(), 5);

    // Advance past the proposal fee effective time.
    clock::increment_for_testing(&mut clock, constants::six_months_ms());
    apply_pending_proposal_fee(&mut fee_manager, &clock);

    assert!(fee_manager.dao_creation_fee == new_dao_fee, 6);
    assert!(fee_manager.proposal_creation_fee_per_outcome == new_proposal_fee, 8);
    assert!(fee_manager.pending_proposal_fee.is_none(), 9);

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

#[test]
/// Test DAO fee increases and decreases both apply immediately.
fun test_global_dao_fee_updates_apply_immediately() {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, sender);
    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, constants::six_months_ms() + 1000);

    let initial_dao_fee = fee_manager.dao_creation_fee;

    // Increases apply immediately.
    let increased_fee = initial_dao_fee * 5;
    update_dao_creation_fee(
        &mut fee_manager,
        &admin_cap,
        increased_fee,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert!(fee_manager.dao_creation_fee == increased_fee, 0);

    // Decreases also apply immediately.
    let decreased_fee = initial_dao_fee / 2;
    update_dao_creation_fee(
        &mut fee_manager,
        &admin_cap,
        decreased_fee,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(fee_manager.dao_creation_fee == decreased_fee, 2);

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EFeeExceedsFiftyXCap)]
/// Test that global proposal fee increases beyond the per-baseline cap are rejected.
fun test_global_proposal_fee_exceeds_fifty_x_cap() {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, sender);
    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, constants::six_months_ms() + 1000);

    let initial_proposal_fee = fee_manager.proposal_creation_fee_per_outcome;

    // Try to increase beyond the cap multiplier - should fail
    update_proposal_creation_fee(
        &mut fee_manager,
        &admin_cap,
        initial_proposal_fee * (constants::max_fee_multiplier() + 1),
        &clock,
        ts::ctx(&mut scenario),
    );

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

#[test]
/// Test launchpad fee updates apply immediately and never leave pending state.
fun test_global_launchpad_fee_updates_apply_immediately() {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, sender);
    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, constants::six_months_ms() + 1000);

    let initial_launchpad_fee = fee_manager.launchpad_creation_fee;

    // Launchpad fee updates apply immediately.
    let new_launchpad_fee = initial_launchpad_fee * 8;
    update_launchpad_creation_fee(
        &mut fee_manager,
        &admin_cap,
        new_launchpad_fee,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(fee_manager.launchpad_creation_fee == new_launchpad_fee, 0);

    // Applying pending proposal fees later should not affect launchpad state.
    apply_pending_proposal_fee(&mut fee_manager, &clock);
    assert!(fee_manager.launchpad_creation_fee == new_launchpad_fee, 3);

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

#[test]
/// Regression: raising a zero DAO fee applies immediately and does not depend
/// on the old baseline-reset path.
fun test_zero_global_fee_can_be_increased_immediately() {
    use sui::clock;
    use sui::test_scenario::{Self as ts};

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, sender);

    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut clock, constants::six_months_ms() + 1000);

    // Decrease DAO fee to zero (applies immediately).
    update_dao_creation_fee(
        &mut fee_manager,
        &admin_cap,
        0,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert!(fee_manager.dao_creation_fee == 0, 0);

    // Move past the old baseline reset window, then increase to a positive value.
    clock::increment_for_testing(&mut clock, constants::six_months_ms() + 1);
    update_dao_creation_fee(
        &mut fee_manager,
        &admin_cap,
        5,
        &clock,
        ts::ctx(&mut scenario),
    );

    assert!(fee_manager.dao_creation_fee == 5, 1);

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

#[test]
/// Regression: when a pending global proposal fee increase has already matured,
/// a follow-up update must compare against the matured fee, not the stale
/// pre-increase fee.
fun test_update_global_proposal_fee_applies_matured_pending_fee_before_comparing_old_fee() {
    use sui::clock;
    use sui::test_scenario::{Self as ts};

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, sender);

    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut clock, constants::six_months_ms() + 1_000);

    let initial_fee = fee_manager.proposal_creation_fee_per_outcome;
    let matured_fee = initial_fee * 2;
    let follow_up_fee = initial_fee + (initial_fee / 2);

    update_proposal_creation_fee(
        &mut fee_manager,
        &admin_cap,
        matured_fee,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert!(fee_manager.pending_proposal_fee == option::some(matured_fee), 0);

    clock::increment_for_testing(&mut clock, constants::six_months_ms() + 1);

    update_proposal_creation_fee(
        &mut fee_manager,
        &admin_cap,
        follow_up_fee,
        &clock,
        ts::ctx(&mut scenario),
    );

    // The matured 2x increase must apply first, so 1.5x is treated as a decrease.
    assert!(fee_manager.proposal_creation_fee_per_outcome == follow_up_fee, 1);
    assert!(fee_manager.pending_proposal_fee.is_none(), 2);
    assert!(fee_manager.pending_proposal_fee_effective_ts.is_none(), 3);

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}

#[test]
/// Regression: coin-specific fee updates must also apply matured pending increases
/// before deciding whether the new value is an increase or decrease.
fun test_update_coin_fee_applies_matured_pending_fee_before_comparing_old_fee() {
    use sui::clock;
    use sui::test_scenario::{Self as ts};

    let sender = @0xA;
    let mut scenario = ts::begin(sender);

    create_fee_manager_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, sender);

    let mut fee_manager = ts::take_shared<FeeManager>(&scenario);
    let admin_cap = ts::take_from_sender<FeeAdminCap>(&scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut clock, 1_000);

    let coin_type = type_name::get<TEST_COIN>();
    add_coin_fee_config(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        6,
        100,
        50,
        &clock,
        ts::ctx(&mut scenario),
    );

    update_coin_creation_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        200,
        &clock,
        ts::ctx(&mut scenario),
    );
    assert!(get_pending_creation_fee(get_coin_fee_config(&fee_manager, coin_type)) == option::some(200), 0);

    clock::increment_for_testing(&mut clock, constants::six_months_ms() + 1);

    update_coin_creation_fee(
        &mut fee_manager,
        &admin_cap,
        coin_type,
        150,
        &clock,
        ts::ctx(&mut scenario),
    );

    let config = get_coin_fee_config(&fee_manager, coin_type);
    assert!(get_coin_creation_fee(config) == 150, 1);
    assert!(get_pending_creation_fee(config).is_none(), 2);

    clock::destroy_for_testing(clock);
    ts::return_shared(fee_manager);
    ts::return_to_sender(&scenario, admin_cap);
    ts::end(scenario);
}
