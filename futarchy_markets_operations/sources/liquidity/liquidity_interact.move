// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_markets_operations::liquidity_interact;

use futarchy_core::emergency_cap::{Self, EmergencyCap};
use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationRegistry};
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationRegistry, MarketStateMutationAuth};
use futarchy_markets_core::fee::{Self, FeeAdminCap, FeeManager};
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationRegistry};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_balance::{Self, ConditionalMarketBalance};
use futarchy_markets_primitives::conditional_amm;
use futarchy_proposal::proposal::Proposal;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::transfer;

// === Witness for mutation authorization ===
public struct EscrowMutationWitness has drop {}
public struct MarketStateMutationWitness has drop {}
public struct SpotPoolMutationWitness has drop {}

// === Introduction ===
// Methods to interact with AMM liquidity and escrow balances using TreasuryCap-based conditional coins

// === Errors ===
const EWrongOutcome: u64 = 2;
const EInvalidState: u64 = 3;
const EInsufficientAmount: u64 = 7;
const EMinAmountNotMet: u64 = 8;
/// Escrow does not belong to the given proposal (cross-proposal attack prevention)
const EProposalEscrowMismatch: u64 = 9;
/// Conditional AMM LP is disabled in the quantum liquidity model.
/// Liquidity is system-managed via futarchy_markets_core::quantum_lp_manager.
const EConditionalLpDisabled: u64 = 10;

// === Events ===
public struct ProtocolFeesCollected has copy, drop {
    proposal_id: ID,
    winning_outcome: u64,
    fee_asset_amount: u64,
    fee_stable_amount: u64,
    timestamp_ms: u64,
}

public struct SpotProtocolFeesCollected has copy, drop {
    pool_id: ID,
    fee_asset_amount: u64,
    fee_stable_amount: u64,
    timestamp_ms: u64,
}

fun extract_proposal_escrow<AssetType, StableType, LPType>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
): (TokenEscrow<AssetType, StableType>, bool) {
    let extract_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::extract_escrow_by_market_id(
        spot_pool,
        proposal.market_state_id(),
        extract_auth,
    )
}

fun store_proposal_escrow<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: TokenEscrow<AssetType, StableType>,
    was_active: bool,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
) {
    let store_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_extracted_escrow(spot_pool, escrow, was_active, store_auth);
}

fun assert_emergency_access<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    clock: &Clock,
    cap: &EmergencyCap,
) {
    assert!(
        coin_escrow::market_state_id(escrow) == proposal.market_state_id(),
        EProposalEscrowMismatch,
    );
    emergency_cap::assert_ready(cap, clock);
}

// NOTE: Single-outcome mint functions (mint_conditional_asset_for_outcome,
// mint_conditional_stable_for_outcome) were REMOVED. Single-outcome minting
// bypasses the quantum invariant. All production deposits go through
// split_*_to_balance (all outcomes) or lp_deposit_quantum.

/// Redeem conditional asset coin back to spot asset
/// Burns the conditional coin and returns spot asset
public fun redeem_conditional_asset<AssetType, StableType, ConditionalCoinType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_coin: Coin<ConditionalCoinType>,
    outcome_index: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    assert!(proposal.is_finalized(), EInvalidState);
    // SECURITY: Validate escrow belongs to this proposal (prevents cross-proposal attacks)
    assert!(
        coin_escrow::market_state_id(escrow) == proposal.market_state_id(),
        EProposalEscrowMismatch,
    );
    let winning_outcome = proposal.get_winning_outcome();
    assert!(outcome_index == winning_outcome, EWrongOutcome);

    // Use combined burn-and-withdraw function that handles everything atomically
    coin_escrow::burn_conditional_asset_and_withdraw<AssetType, StableType, ConditionalCoinType>(
        escrow,
        conditional_coin,
        ctx,
    )
}

/// Redeem conditional stable coin back to spot stable
public fun redeem_conditional_stable<AssetType, StableType, ConditionalCoinType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_coin: Coin<ConditionalCoinType>,
    outcome_index: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    assert!(proposal.is_finalized(), EInvalidState);
    // SECURITY: Validate escrow belongs to this proposal (prevents cross-proposal attacks)
    assert!(
        coin_escrow::market_state_id(escrow) == proposal.market_state_id(),
        EProposalEscrowMismatch,
    );
    let winning_outcome = proposal.get_winning_outcome();
    assert!(outcome_index == winning_outcome, EWrongOutcome);

    // Use combined burn-and-withdraw function that handles everything atomically
    coin_escrow::burn_conditional_stable_and_withdraw<AssetType, StableType, ConditionalCoinType>(
        escrow,
        conditional_coin,
        ctx,
    )
}

/// Redeem conditional asset coin while escrow is wrapped in the spot pool.
public fun redeem_conditional_asset_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    conditional_coin: Coin<ConditionalCoinType>,
    outcome_index: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    let redeemed = redeem_conditional_asset(
        proposal,
        &mut escrow,
        conditional_coin,
        outcome_index,
        clock,
        ctx,
    );
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    redeemed
}

/// Redeem conditional stable coin while escrow is wrapped in the spot pool.
public fun redeem_conditional_stable_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    conditional_coin: Coin<ConditionalCoinType>,
    outcome_index: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    let redeemed = redeem_conditional_stable(
        proposal,
        &mut escrow,
        conditional_coin,
        outcome_index,
        clock,
        ctx,
    );
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    redeemed
}

/// Recombine complete sets into spot asset while escrow is wrapped in the spot pool.
public fun recombine_balance_to_asset_with_wrapped_escrow<AssetType, StableType, LPType>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    amount: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    let recombined = conditional_balance::recombine_balance_to_asset(&mut escrow, balance, amount, ctx);
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    recombined
}

/// Recombine complete sets into spot stable while escrow is wrapped in the spot pool.
public fun recombine_balance_to_stable_with_wrapped_escrow<AssetType, StableType, LPType>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    amount: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    ctx: &mut TxContext,
): Coin<StableType> {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    let recombined = conditional_balance::recombine_balance_to_stable(&mut escrow, balance, amount, ctx);
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    recombined
}

/// Unwrap and redeem conditional asset from a balance wrapper while escrow is wrapped.
public fun redeem_conditional_asset_from_balance_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    outcome_index: u8,
    amount: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    let conditional_coin = conditional_balance::unwrap_to_coin<AssetType, StableType, ConditionalCoinType>(
        balance,
        &mut escrow,
        outcome_index,
        true,
        amount,
        ctx,
    );
    let redeemed = redeem_conditional_asset(
        proposal,
        &mut escrow,
        conditional_coin,
        (outcome_index as u64),
        clock,
        ctx,
    );
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    redeemed
}

/// Unwrap and redeem conditional stable from a balance wrapper while escrow is wrapped.
public fun redeem_conditional_stable_from_balance_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    outcome_index: u8,
    amount: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    let conditional_coin = conditional_balance::unwrap_to_coin<AssetType, StableType, ConditionalCoinType>(
        balance,
        &mut escrow,
        outcome_index,
        false,
        amount,
        ctx,
    );
    let redeemed = redeem_conditional_stable(
        proposal,
        &mut escrow,
        conditional_coin,
        (outcome_index as u64),
        clock,
        ctx,
    );
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    redeemed
}

// === AMM Liquidity Management ===

/// Add liquidity to an AMM pool for a specific outcome
/// Takes asset and stable conditional coins and mints LP tokens
/// Uses TreasuryCap-based conditional coins
public entry fun add_liquidity_entry<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
    LPConditionalCoin,
>(
    _proposal: &mut Proposal<AssetType, StableType>,
    _escrow: &mut TokenEscrow<AssetType, StableType>,
    _outcome_idx: u64,
    _asset_in: Coin<AssetConditionalCoin>,
    _stable_in: Coin<StableConditionalCoin>,
    _min_lp_out: u64,
    _escrow_registry: &EscrowMutationRegistry,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Quantum liquidity: conditional AMM liquidity is system-only.
    // This function is retained for backwards compatibility but intentionally disabled.
    // If you want to adjust system liquidity, use quantum_lp_manager entrypoints.
    abort (EConditionalLpDisabled)
}

/// Remove liquidity from an AMM pool proportionally
/// Burns LP tokens and returns asset and stable conditional coins
public entry fun remove_liquidity_entry<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
    LPConditionalCoin,
>(
    _proposal: &mut Proposal<AssetType, StableType>,
    _escrow: &mut TokenEscrow<AssetType, StableType>,
    _outcome_idx: u64,
    _lp_token: Coin<LPConditionalCoin>,
    _min_asset_out: u64,
    _min_stable_out: u64,
    _escrow_registry: &EscrowMutationRegistry,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Quantum liquidity: conditional AMM liquidity is system-only.
    // This function is retained for backwards compatibility but intentionally disabled.
    abort (EConditionalLpDisabled)
}

// === Protocol Fee Collection ===

/// Collect protocol fees from the winning pool after finalization
/// Withdraws fees from escrow and deposits them to the fee manager
/// NOW COLLECTS BOTH ASSET AND STABLE TOKEN FEES
public fun collect_protocol_fees<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    fee_admin_cap: &FeeAdminCap,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(proposal.is_finalized(), EInvalidState);
    assert!(proposal.is_winning_outcome_set(), EInvalidState);
    // SECURITY: Validate escrow belongs to this proposal (prevents cross-proposal attacks)
    assert!(
        coin_escrow::market_state_id(escrow) == proposal.market_state_id(),
        EProposalEscrowMismatch,
    );
    fee::assert_admin_cap(fee_manager, fee_admin_cap);

    // Create auth for escrow mutations
    let auth = escrow_mutation_auth::create(escrow_registry, EscrowMutationWitness {});
    // Create auth for market state mutations (needed for conditional AMM operations)
    let market_auth = market_state_mutation_auth::create(
        market_state_registry,
        MarketStateMutationWitness {},
    );

    let winning_outcome = proposal.get_winning_outcome();
    // Get protocol fees from winning pool
    let (protocol_fee_asset, protocol_fee_stable) = {
        let market_state = escrow.get_market_state_mut(&auth);
        let winning_pool = futarchy_markets_primitives::market_state::get_pool_mut_by_outcome(
            market_state,
            winning_outcome,
            &auth,
        );

        // Get both asset and stable protocol fees
        let fee_asset = winning_pool.get_protocol_fees_asset();
        let fee_stable = winning_pool.get_protocol_fees_stable();
        (fee_asset, fee_stable)
    }; // winning_pool borrow dropped here

    // Fetch balances once at the start to validate both withdrawals
    // This prevents state inconsistency between withdrawals
    let (spot_asset, spot_stable) = coin_escrow::get_spot_balances(escrow);

    // Validate both withdrawals can succeed before performing either
    if (protocol_fee_asset > 0) {
        assert!(spot_asset >= protocol_fee_asset, EInsufficientAmount);
    };
    if (protocol_fee_stable > 0) {
        assert!(spot_stable >= protocol_fee_stable, EInsufficientAmount);
    };

    // Collect asset token fees
    if (protocol_fee_asset > 0) {
        let fee_balance_coin = coin_escrow::withdraw_asset_balance(
            escrow,
            protocol_fee_asset,
            ctx,
            &auth,
        );
        let fee_balance = coin::into_balance(fee_balance_coin);

        // Deposit to fee manager
        fee::deposit_fees_with_proposal<AssetType>(
            fee_manager,
            fee_admin_cap,
            fee_balance,
            proposal.get_id(),
            clock,
        );
    };

    // Collect stable token fees
    if (protocol_fee_stable > 0) {
        let fee_balance_coin = coin_escrow::withdraw_stable_balance(
            escrow,
            protocol_fee_stable,
            ctx,
            &auth,
        );
        let fee_balance = coin::into_balance(fee_balance_coin);

        // Deposit to fee manager
        fee::deposit_fees_with_proposal<StableType>(
            fee_manager,
            fee_admin_cap,
            fee_balance,
            proposal.get_id(),
            clock,
        );
    };

    // Reset fees in the pool after collection and track collected fees for invariant
    if (protocol_fee_asset > 0 || protocol_fee_stable > 0) {
        // Track collected fees in escrow for quantum invariant maintenance
        coin_escrow::track_collected_protocol_fees(
            escrow,
            protocol_fee_asset,
            protocol_fee_stable,
            &auth,
        );

        let market_state = escrow.get_market_state_mut(&auth);
        let winning_pool = futarchy_markets_primitives::market_state::get_pool_mut_by_outcome(
            market_state,
            winning_outcome,
            &auth,
        );
        winning_pool.collect_protocol_fees(&market_auth);

        // Emit event
        event::emit(ProtocolFeesCollected {
            proposal_id: proposal.get_id(),
            winning_outcome,
            fee_asset_amount: protocol_fee_asset,
            fee_stable_amount: protocol_fee_stable,
            timestamp_ms: clock.timestamp_ms(),
        });
    };

    // Verify solvency after fee withdrawal. Fees are "slack" (escrow surplus not
    // tracked by outcome allocations), so the invariant should hold. This catches
    // bugs in AMM fee calculation that could over-drain the escrow.
    coin_escrow::assert_quantum_invariant(escrow);
}

/// Collect conditional protocol fees while escrow is wrapped in the spot pool.
public fun collect_protocol_fees_with_wrapped_escrow<AssetType, StableType, LPType>(
    proposal: &mut Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    fee_manager: &mut FeeManager,
    fee_admin_cap: &FeeAdminCap,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    collect_protocol_fees(
        proposal,
        &mut escrow,
        fee_manager,
        fee_admin_cap,
        escrow_registry,
        market_state_registry,
        clock,
        ctx,
    );

    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
}

/// Read spot balances from wrapped escrow without exposing raw extract/store.
public fun get_spot_balances_with_wrapped_escrow<AssetType, StableType, LPType>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
): (u64, u64) {
    let (escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    let (spot_asset, spot_stable) = coin_escrow::get_spot_balances(&escrow);

    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    (spot_asset, spot_stable)
}

/// Collect protocol fees from a spot pool and deposit them to the fee manager.
/// This mirrors `collect_protocol_fees` for conditional AMM pools but operates on
/// UnifiedSpotPool's aggregator_config.protocol_fees_{asset,stable} balances.
public fun collect_spot_protocol_fees<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    fee_manager: &mut FeeManager,
    fee_admin_cap: &FeeAdminCap,
    spot_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
) {
    fee::assert_admin_cap(fee_manager, fee_admin_cap);

    let (fee_asset_amount, fee_stable_amount) = unified_spot_pool::get_protocol_fee_amounts(pool);

    // Early return if no fees to collect
    if (fee_asset_amount == 0 && fee_stable_amount == 0) {
        return
    };

    let pool_id = unified_spot_pool::get_pool_id(pool);

    // Withdraw and deposit asset fees
    if (fee_asset_amount > 0) {
        let auth = spot_pool_mutation_auth::create(
            spot_mutation_registry,
            SpotPoolMutationWitness {},
            object::id(pool),
        );
        let fee_balance = unified_spot_pool::withdraw_protocol_fees_asset(pool, auth);
        fee::deposit_fees<AssetType>(fee_manager, fee_admin_cap, fee_balance, clock);
    };

    // Withdraw and deposit stable fees
    if (fee_stable_amount > 0) {
        let auth = spot_pool_mutation_auth::create(
            spot_mutation_registry,
            SpotPoolMutationWitness {},
            object::id(pool),
        );
        let fee_balance = unified_spot_pool::withdraw_protocol_fees_stable(pool, auth);
        fee::deposit_fees<StableType>(fee_manager, fee_admin_cap, fee_balance, clock);
    };

    event::emit(SpotProtocolFeesCollected {
        pool_id,
        fee_asset_amount,
        fee_stable_amount,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Emergency fallback: withdraw escrow spot balances to sender once EmergencyCap is ready.
/// This bypasses normal market flows on purpose as a last-resort recovery path.
public entry fun emergency_withdraw_escrow_to_sender<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &mut TxContext,
) {
    assert_emergency_access(proposal, escrow, clock, cap);
    let (asset_coin, stable_coin) = coin_escrow::emergency_withdraw_spot_balances(
        escrow,
        asset_amount,
        stable_amount,
        cap,
        clock,
        ctx,
    );

    let asset_val = asset_coin.value();
    if (asset_val > 0) {
        transfer::public_transfer(asset_coin, ctx.sender());
    } else {
        coin::destroy_zero(asset_coin);
    };
    let stable_val = stable_coin.value();
    if (stable_val > 0) {
        transfer::public_transfer(stable_coin, ctx.sender());
    } else {
        coin::destroy_zero(stable_coin);
    };
}

/// Emergency fallback: extract a conditional ASSET TreasuryCap from escrow to sender once EmergencyCap is ready.
public entry fun emergency_take_asset_treasury_cap_to_sender<
    AssetType,
    StableType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &TxContext,
) {
    assert_emergency_access(proposal, escrow, clock, cap);
    let cap = coin_escrow::emergency_remove_asset_treasury_cap<
        AssetType,
        StableType,
        ConditionalCoinType,
    >(escrow, outcome_index, cap, clock);
    transfer::public_transfer(cap, ctx.sender());
}

/// Emergency fallback: extract a conditional STABLE TreasuryCap from escrow to sender once EmergencyCap is ready.
public entry fun emergency_take_stable_treasury_cap_to_sender<
    AssetType,
    StableType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &TxContext,
) {
    assert_emergency_access(proposal, escrow, clock, cap);
    let cap = coin_escrow::emergency_remove_stable_treasury_cap<
        AssetType,
        StableType,
        ConditionalCoinType,
    >(escrow, outcome_index, cap, clock);
    transfer::public_transfer(cap, ctx.sender());
}

/// Emergency fallback: "burn" an extracted ASSET TreasuryCap by sending it to @0x0.
public entry fun emergency_burn_asset_treasury_cap<
    AssetType,
    StableType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    clock: &Clock,
    cap: &EmergencyCap,
    _ctx: &TxContext,
) {
    assert_emergency_access(proposal, escrow, clock, cap);
    let cap = coin_escrow::emergency_remove_asset_treasury_cap<
        AssetType,
        StableType,
        ConditionalCoinType,
    >(escrow, outcome_index, cap, clock);
    transfer::public_transfer(cap, @0x0);
}

/// Emergency fallback: "burn" an extracted STABLE TreasuryCap by sending it to @0x0.
public entry fun emergency_burn_stable_treasury_cap<
    AssetType,
    StableType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    clock: &Clock,
    cap: &EmergencyCap,
    _ctx: &TxContext,
) {
    assert_emergency_access(proposal, escrow, clock, cap);
    let cap = coin_escrow::emergency_remove_stable_treasury_cap<
        AssetType,
        StableType,
        ConditionalCoinType,
    >(escrow, outcome_index, cap, clock);
    transfer::public_transfer(cap, @0x0);
}

// === Emergency Wrapped Escrow Variants ===

/// Emergency withdraw escrow while it's wrapped in the spot pool.
public entry fun emergency_withdraw_escrow_to_sender_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_amount: u64,
    stable_amount: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &mut TxContext,
) {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    assert_emergency_access(proposal, &escrow, clock, cap);
    let (asset_coin, stable_coin) = coin_escrow::emergency_withdraw_spot_balances(
        &mut escrow,
        asset_amount,
        stable_amount,
        cap,
        clock,
        ctx,
    );
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);

    let asset_val = asset_coin.value();
    if (asset_val > 0) {
        transfer::public_transfer(asset_coin, ctx.sender());
    } else {
        coin::destroy_zero(asset_coin);
    };
    let stable_val = stable_coin.value();
    if (stable_val > 0) {
        transfer::public_transfer(stable_coin, ctx.sender());
    } else {
        coin::destroy_zero(stable_coin);
    };
}

/// Emergency take asset treasury cap while escrow is wrapped in the spot pool.
public entry fun emergency_take_asset_treasury_cap_to_sender_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    outcome_index: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &TxContext,
) {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    assert_emergency_access(proposal, &escrow, clock, cap);
    let treasury_cap = coin_escrow::emergency_remove_asset_treasury_cap<
        AssetType,
        StableType,
        ConditionalCoinType,
    >(&mut escrow, outcome_index, cap, clock);
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    transfer::public_transfer(treasury_cap, ctx.sender());
}

/// Emergency take stable treasury cap while escrow is wrapped in the spot pool.
public entry fun emergency_take_stable_treasury_cap_to_sender_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    outcome_index: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &TxContext,
) {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    assert_emergency_access(proposal, &escrow, clock, cap);
    let treasury_cap = coin_escrow::emergency_remove_stable_treasury_cap<
        AssetType,
        StableType,
        ConditionalCoinType,
    >(&mut escrow, outcome_index, cap, clock);
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    transfer::public_transfer(treasury_cap, ctx.sender());
}

/// Emergency burn asset treasury cap while escrow is wrapped in the spot pool.
public entry fun emergency_burn_asset_treasury_cap_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    outcome_index: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    cap: &EmergencyCap,
    _ctx: &TxContext,
) {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    assert_emergency_access(proposal, &escrow, clock, cap);
    let treasury_cap = coin_escrow::emergency_remove_asset_treasury_cap<
        AssetType,
        StableType,
        ConditionalCoinType,
    >(&mut escrow, outcome_index, cap, clock);
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    transfer::public_transfer(treasury_cap, @0x0);
}

/// Emergency burn stable treasury cap while escrow is wrapped in the spot pool.
public entry fun emergency_burn_stable_treasury_cap_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    ConditionalCoinType,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    outcome_index: u64,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    cap: &EmergencyCap,
    _ctx: &TxContext,
) {
    let (mut escrow, was_active) = extract_proposal_escrow(
        proposal,
        spot_pool,
        spot_pool_mutation_registry,
    );
    assert_emergency_access(proposal, &escrow, clock, cap);
    let treasury_cap = coin_escrow::emergency_remove_stable_treasury_cap<
        AssetType,
        StableType,
        ConditionalCoinType,
    >(&mut escrow, outcome_index, cap, clock);
    store_proposal_escrow(spot_pool, escrow, was_active, spot_pool_mutation_registry);
    transfer::public_transfer(treasury_cap, @0x0);
}

// === Test Helpers ===

#[test_only]
public fun get_liquidity_for_proposal<AssetType, StableType>(
    escrow: &futarchy_markets_primitives::coin_escrow::TokenEscrow<AssetType, StableType>,
): vector<u64> {
    let market_state = escrow.get_market_state();
    let pools = futarchy_markets_primitives::market_state::borrow_amm_pools(market_state);
    let mut liquidity = vector[];
    let mut i = 0;
    while (i < pools.length()) {
        let pool = &pools[i];
        let (asset, stable) = pool.get_reserves();
        liquidity.push_back(asset);
        liquidity.push_back(stable);
        i = i + 1;
    };
    liquidity
}
