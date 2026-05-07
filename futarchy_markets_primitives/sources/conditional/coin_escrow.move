// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_markets_primitives::coin_escrow;

use futarchy_core::emergency_cap::{Self, EmergencyCap};
use futarchy_core::escrow_mutation_auth::EscrowMutationAuth;
use futarchy_markets_primitives::market_state::{Self, MarketState};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
use sui::dynamic_field;
use sui::object;

// === Introduction ===
// The TokenEscrow manages TreasuryCap-based conditional coins in the futarchy prediction market system.
//
// === TreasuryCap-Based Conditional Coins ===
// Uses real Sui Coin<T> types instead of custom ConditionalToken structs:
// 1. **TreasuryCap Storage**: Each outcome has 2 TreasuryCaps (asset + stable) stored in dynamic fields
// 2. **Registry Integration**: Blank coins acquired from permissionless registry
// 3. **Quantum Liquidity**: Spot tokens exist simultaneously in ALL outcomes (not split between them)
//
// === Quantum Liquidity Invariant ===
// **CRITICAL**: 100 spot tokens → 100 conditional tokens in EACH outcome
// - NOT proportional split (not 50/50 across 2 outcomes)
// - Liquidity exists fully in all markets simultaneously
// - Only highest-priced outcome wins at finalization
//
// INVARIANT: outcome_escrowed[i] == supply[i] + wrapped[i] (per type, per outcome)
// - Per-outcome allocations track type composition changes from swaps
// - Swaps convert between types within an outcome (zero-sum)
// - Global escrow backs all outcomes simultaneously (quantum model)
// - Post-finalization: only winning outcome checked + solvency constraint
//
// === Architecture ===
// - TreasuryCaps stored via dynamic fields with AssetCapKey/StableCapKey
// - Vector-like indexing: outcome_index determines which cap to use
// - Mint/burn functions borrow caps mutably, perform operation, return cap to storage
// - No Supply objects - total_supply() comes directly from TreasuryCap

// === Errors ===
const EInsufficientBalance: u64 = 0; // Token balance insufficient for operation
const EIncorrectSequence: u64 = 1; // Tokens not provided in correct sequence/order
const EWrongMarket: u64 = 2; // Token belongs to different market
const ESuppliesNotInitialized: u64 = 4; // Token supplies not yet initialized
const EOutcomeOutOfBounds: u64 = 5; // Outcome index exceeds market outcomes
const ENotEnoughLiquidity: u64 = 8; // Insufficient liquidity in escrow
const EZeroAmount: u64 = 13; // Amount must be greater than zero
const EMarketNotFinalized: u64 = 101; // Market must be finalized for single-outcome withdrawal
const ETradingAlreadyStarted: u64 = 102; // Cannot use single-outcome mint during active trading
const EAllocationUnderflow: u64 = 103; // Swap would cause allocation to go negative (accounting bug)
const EAllocationOverflow: u64 = 104; // Swap would cause allocation to exceed u64::MAX (shouldn't happen)
const ESupplyNotZero: u64 = 105; // Conditional TreasuryCap must have zero supply at registration

// === Key Structures for TreasuryCap Storage ===
/// Key for asset conditional coin TreasuryCaps (indexed by outcome)
public struct AssetCapKey has copy, drop, store {
    outcome_index: u64,
}

/// Key for stable conditional coin TreasuryCaps (indexed by outcome)
public struct StableCapKey has copy, drop, store {
    outcome_index: u64,
}

// === Structs ===
public struct TokenEscrow<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    market_state: MarketState,
    // Central balances used for tokens and liquidity
    escrowed_asset: Balance<AssetType>,
    escrowed_stable: Balance<StableType>,
    // TreasuryCaps stored as dynamic fields on UID (vector-like access by index)
    // Asset caps: dynamic_field with AssetCapKey { outcome_index } -> TreasuryCap<T>
    // Stable caps: dynamic_field with StableCapKey { outcome_index } -> TreasuryCap<T>
    // Each outcome's TreasuryCap has a unique generic type T
    outcome_count: u64, // Track how many outcomes have registered caps
    // === Supply Tracking for Safe Recombination ===
    // Track deposits by source to ensure user redemptions are always covered.
    // When LP liquidity is recombined, only LP backing is withdrawn.
    // User backing remains in escrow for their redemptions.
    //
    // LP backing: deposited via quantum split, returned on proposal finalization
    // User backing: deposited via split/deposit functions, redeemed by users
    //
    lp_deposited_asset: u64,
    lp_deposited_stable: u64,
    // User backing tracked per-type for accurate accounting with different token decimals.
    // Cross-type swaps may cause withdrawals from a type the user didn't deposit into;
    // withdrawal decrements use saturating subtraction to handle this gracefully.
    user_deposited_asset: u64,
    user_deposited_stable: u64,
    // === Quantum Invariant Tracking ===
    // Track total minted supply for each outcome to validate quantum invariant.
    // Invariant (during active proposal): escrow_balance == supply[i] + wrapped[i] for ALL outcomes i
    // Invariant (after finalization): escrow_balance >= supply[winning] + wrapped[winning] only
    // This is redundant with TreasuryCap.total_supply() but avoids type explosion
    // when validating the invariant at runtime.
    asset_supplies: vector<u64>, // [outcome_0_asset_supply, outcome_1_asset_supply, ...]
    stable_supplies: vector<u64>, // [outcome_0_stable_supply, outcome_1_stable_supply, ...]
    // === Wrapped Balance Tracking ===
    // Track total wrapped balances across all ConditionalMarketBalance objects.
    // When users wrap coins, supply decreases but wrapped increases.
    // Invariant: escrow == supply + wrapped for each outcome.
    wrapped_asset_balances: vector<u64>, // [outcome_0_wrapped_asset, outcome_1_wrapped_asset, ...]
    wrapped_stable_balances: vector<u64>, // [outcome_0_wrapped_stable, outcome_1_wrapped_stable, ...]
    // === Dust Creation Tracking (Diagnostic Only) ===
    // Monotonic counters tracking cumulative dust created by arbitrage for each outcome.
    // Only incremented when arbitrage creates dust (never decremented).
    // Retained for diagnostics/auditing — NOT used in withdrawal calculations.
    // The pool_claim-based user_claim cap provides correct solvency protection that
    // naturally relaxes when dust is redeemed, unlike these monotonic counters.
    dust_created_asset: vector<u64>, // [outcome_0_dust_asset, outcome_1_dust_asset, ...]
    dust_created_stable: vector<u64>, // [outcome_0_dust_stable, outcome_1_dust_stable, ...]
    // === Protocol Fee Tracking ===
    // Track protocol fees that have been collected from escrow (for diagnostics/auditing).
    //
    // WHY TRACKED: Protocol fees are collected from AMM pool operations. When fees are
    // withdrawn from global escrow, escrow decreases. The corresponding allocation decrease
    // already happened during swap operations (burn amount_in > mint amount_out = fee margin).
    //
    // SOLVENCY: No adjustment needed in the solvency check. During swaps, each fee reduces
    // total allocation (amount_in - amount_out). When fees are later withdrawn from escrow,
    // both escrow and allocations have already been reduced by the same amount.
    // The solvency check simply verifies: escrow >= winning_outcome_allocation.
    collected_protocol_fees_asset: u64,
    collected_protocol_fees_stable: u64,
    // === Per-Outcome Escrow Allocation ===
    // Track the escrowed backing allocated to each outcome per type.
    // This handles both quantum (all outcomes equal) and non-quantum (per-outcome) setups.
    //
    // INVARIANT: outcome_escrowed[i] == supply[i] + wrapped[i] for each type
    //
    // UPDATE POINTS (must maintain invariant):
    // INCREMENT:
    //   - lp_deposit_quantum (all outcomes)
    //   - increment_supplies_for_all_outcomes (all outcomes)
    //   - split_*_progress_step (single outcome per step)
    // DECREMENT:
    //   - lp_withdraw_quantum (all outcomes)
    //   - burn_conditional_*_and_withdraw (winning outcome, post-finalization)
    //   - start_recombine_*_progress / recombine_*_progress_step (single outcome per step)
    // TYPE CONVERSION (zero-sum within outcome):
    //   - track_swap_asset_to_stable: asset--, stable++
    //   - track_swap_stable_to_asset: stable--, asset++
    //
    // DESIGN NOTE: These vectors are technically redundant (could compute as supply + wrapped),
    // but explicit tracking provides auditability and catches accounting bugs early.
    outcome_escrowed_asset: vector<u64>, // [outcome_0, outcome_1, ...] - asset allocated per outcome
    outcome_escrowed_stable: vector<u64>, // [outcome_0, outcome_1, ...] - stable allocated per outcome
    // === Pool Claim Tracking (Dual-Ledger) ===
    // Tracks the LP/AMM portion of outcome_escrowed that was set during quantum split.
    // pool_claim is set at quantum split time, unchanged by typed user swaps
    // (track_swap does NOT touch it), and decremented during LP unwind.
    // This allows the solvency check to only enforce
    // escrow_type >= user_claim_type where user_claim = outcome_escrowed - pool_claim.
    // Without this, swaps shift outcome_escrowed between types, causing false solvency violations.
    pool_claim_asset: vector<u64>, // [outcome_0, outcome_1, ...] - LP's asset claim per outcome
    pool_claim_stable: vector<u64>, // [outcome_0, outcome_1, ...] - LP's stable claim per outcome
}

public struct COIN_ESCROW has drop {}

// === Events ===
public struct LiquidityWithdrawal has copy, drop {
    escrowed_asset: u64,
    escrowed_stable: u64,
    asset_amount: u64,
    stable_amount: u64,
}

public struct LiquidityDeposit has copy, drop {
    escrowed_asset: u64,
    escrowed_stable: u64,
    asset_amount: u64,
    stable_amount: u64,
}

public struct TokenRedemption has copy, drop {
    outcome: u64,
    token_type: u8,
    amount: u64,
}

/// Emitted when saturating subtraction clamps a value to zero instead of
/// performing an exact decrement.  Signals a cross-type swap accounting
/// divergence that is handled safely but worth monitoring.
public struct SaturatingSubtractionEvent has copy, drop {
    escrow_id: ID,
    field: vector<u8>,      // e.g. b"pool_claim_asset", b"user_deposited_asset"
    outcome_index: u64,     // u64::MAX when not per-outcome
    requested: u64,
    available: u64,
}

public fun new<AssetType, StableType>(
    market_state: MarketState,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    TokenEscrow {
        id: object::new(ctx),
        market_state,
        escrowed_asset: balance::zero(),
        escrowed_stable: balance::zero(),
        outcome_count: 0, // Will be incremented as caps are registered
        // Initialize supply tracking
        lp_deposited_asset: 0,
        lp_deposited_stable: 0,
        user_deposited_asset: 0,
        user_deposited_stable: 0,
        // Initialize quantum invariant tracking
        asset_supplies: vector[],
        stable_supplies: vector[],
        // Initialize wrapped balance tracking
        wrapped_asset_balances: vector[],
        wrapped_stable_balances: vector[],
        // Initialize dust creation tracking
        dust_created_asset: vector[],
        dust_created_stable: vector[],
        // Initialize protocol fee tracking
        collected_protocol_fees_asset: 0,
        collected_protocol_fees_stable: 0,
        // Initialize per-outcome escrow allocation tracking
        outcome_escrowed_asset: vector[],
        outcome_escrowed_stable: vector[],
        // Initialize pool claim tracking (dual-ledger)
        pool_claim_asset: vector[],
        pool_claim_stable: vector[],
    }
}

/// NEW: Register conditional coin TreasuryCaps for an outcome
/// Must be called once per outcome with both asset and stable caps
/// Caps are stored as dynamic fields with vector-like indexing semantics
public fun register_conditional_caps<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_treasury_cap: TreasuryCap<AssetConditionalCoin>,
    stable_treasury_cap: TreasuryCap<StableConditionalCoin>,
) {
    let market_outcome_count = escrow.market_state.outcome_count();
    assert!(outcome_idx < market_outcome_count, EOutcomeOutOfBounds);

    // Must register in order (like pushing to a vector)
    assert!(outcome_idx == escrow.outcome_count, EIncorrectSequence);

    // Conditional caps must be blank at registration. Any already-minted
    // conditional coins would be invisible to escrow's internal supply ledgers.
    assert!(coin::total_supply(&asset_treasury_cap) == 0, ESupplyNotZero);
    assert!(coin::total_supply(&stable_treasury_cap) == 0, ESupplyNotZero);

    // Store TreasuryCaps as dynamic fields with index-based keys
    let asset_key = AssetCapKey { outcome_index: outcome_idx };
    let stable_key = StableCapKey { outcome_index: outcome_idx };

    dynamic_field::add(&mut escrow.id, asset_key, asset_treasury_cap);
    dynamic_field::add(&mut escrow.id, stable_key, stable_treasury_cap);

    // Initialize supply tracking for this outcome (starts at 0)
    escrow.asset_supplies.push_back(0);
    escrow.stable_supplies.push_back(0);

    // Initialize wrapped balance tracking for this outcome (starts at 0)
    escrow.wrapped_asset_balances.push_back(0);
    escrow.wrapped_stable_balances.push_back(0);

    // Initialize dust creation tracking for this outcome (starts at 0)
    escrow.dust_created_asset.push_back(0);
    escrow.dust_created_stable.push_back(0);

    // Initialize per-outcome escrow allocation tracking for this outcome (starts at 0)
    escrow.outcome_escrowed_asset.push_back(0);
    escrow.outcome_escrowed_stable.push_back(0);

    // Initialize pool claim tracking for this outcome (starts at 0)
    escrow.pool_claim_asset.push_back(0);
    escrow.pool_claim_stable.push_back(0);

    // Increment count (like vector length)
    escrow.outcome_count = escrow.outcome_count + 1;
}

/// Emergency helper: remove an asset conditional TreasuryCap from escrow storage.
/// Caller must enforce all lifecycle and access controls.
///
/// RESTRICTED: Requires armed EmergencyCap (timelock enforced).
public fun emergency_remove_asset_treasury_cap<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    cap: &EmergencyCap,
    clock: &Clock,
): TreasuryCap<ConditionalCoinType> {
    emergency_cap::assert_ready(cap, clock);
    assert!(outcome_index < escrow.outcome_count, EOutcomeOutOfBounds);
    let key = AssetCapKey { outcome_index };
    dynamic_field::remove(&mut escrow.id, key)
}

/// Emergency helper: remove a stable conditional TreasuryCap from escrow storage.
/// Caller must enforce all lifecycle and access controls.
///
/// RESTRICTED: Requires armed EmergencyCap (timelock enforced).
public fun emergency_remove_stable_treasury_cap<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    cap: &EmergencyCap,
    clock: &Clock,
): TreasuryCap<ConditionalCoinType> {
    emergency_cap::assert_ready(cap, clock);
    assert!(outcome_index < escrow.outcome_count, EOutcomeOutOfBounds);
    let key = StableCapKey { outcome_index };
    dynamic_field::remove(&mut escrow.id, key)
}

/// Emergency helper: withdraw spot balances from escrow.
/// Caller must enforce all lifecycle and access controls.
///
/// RESTRICTED: Requires armed EmergencyCap (timelock enforced).
public fun emergency_withdraw_spot_balances<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    cap: &EmergencyCap,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    emergency_cap::assert_ready(cap, clock);
    let available_asset = escrow.escrowed_asset.value();
    let available_stable = escrow.escrowed_stable.value();

    let withdraw_asset = if (asset_amount == 0 || asset_amount > available_asset) {
        available_asset
    } else {
        asset_amount
    };
    let withdraw_stable = if (stable_amount == 0 || stable_amount > available_stable) {
        available_stable
    } else {
        stable_amount
    };

    // Intentionally bypasses quantum/accounting invariants. This is a last-resort rescue path.
    let asset_coin = withdraw_asset_balance_pkg(escrow, withdraw_asset, ctx);
    let stable_coin = withdraw_stable_balance_pkg(escrow, withdraw_stable, ctx);
    (asset_coin, stable_coin)
}

// === NEW: TreasuryCap-based Mint/Burn Helpers ===

/// Mint conditional coins for a specific outcome using its TreasuryCap
/// Borrows the cap, mints, and returns it (maintains vector-like storage)
///
/// Package-only: Used internally by progress pattern functions and mint_conditional wrapper.
/// Single-outcome minting would violate quantum invariant (escrow == supply for ALL outcomes).
public(package) fun mint_conditional_asset<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    amount: u64,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    // Use escrow.outcome_count (registered caps) not market_state.outcome_count()
    // to ensure vectors/dynamic fields exist for this index
    assert!(outcome_index < escrow.outcome_count, EOutcomeOutOfBounds);

    // Borrow the TreasuryCap from dynamic field
    let asset_key = AssetCapKey { outcome_index };
    let cap: &mut TreasuryCap<ConditionalCoinType> = dynamic_field::borrow_mut(
        &mut escrow.id,
        asset_key,
    );

    // Track supply for quantum invariant
    let current_supply = &mut escrow.asset_supplies[outcome_index];
    *current_supply = *current_supply + amount;

    // NOTE: outcome_escrowed is updated by deposit functions, NOT here.
    // This ensures invariant catches mints without proper backing.

    // Mint and return
    coin::mint(cap, amount, ctx)
}

/// Mint conditional stable coins for a specific outcome
///
/// Package-only: Used internally by progress pattern functions and mint_conditional wrapper.
/// Single-outcome minting would violate quantum invariant (escrow == supply for ALL outcomes).
public(package) fun mint_conditional_stable<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    amount: u64,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    // Use escrow.outcome_count (registered caps) not market_state.outcome_count()
    // to ensure vectors/dynamic fields exist for this index
    assert!(outcome_index < escrow.outcome_count, EOutcomeOutOfBounds);

    // Borrow the TreasuryCap from dynamic field
    let stable_key = StableCapKey { outcome_index };
    let cap: &mut TreasuryCap<ConditionalCoinType> = dynamic_field::borrow_mut(
        &mut escrow.id,
        stable_key,
    );

    // Track supply for quantum invariant
    let current_supply = &mut escrow.stable_supplies[outcome_index];
    *current_supply = *current_supply + amount;

    // NOTE: outcome_escrowed is updated by deposit functions, NOT here.
    // This ensures invariant catches mints without proper backing.

    // Mint and return
    coin::mint(cap, amount, ctx)
}

/// Burn conditional asset coins for a specific outcome
///
/// Package-only: Used internally by progress pattern functions and burn_conditional wrapper.
/// Single-outcome burning would violate quantum invariant (escrow == supply for ALL outcomes).
public(package) fun burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
) {
    // Use escrow.outcome_count (registered caps) not market_state.outcome_count()
    // to ensure vectors/dynamic fields exist for this index
    assert!(outcome_index < escrow.outcome_count, EOutcomeOutOfBounds);

    // Track supply for quantum invariant (before burn)
    let amount = coin.value();
    let current_supply = &mut escrow.asset_supplies[outcome_index];
    *current_supply = *current_supply - amount;

    // NOTE: outcome_escrowed is updated by withdraw functions, NOT here.
    // This is because burn is also used by wrap_coin which doesn't change backing.

    // Borrow the TreasuryCap from dynamic field
    let asset_key = AssetCapKey { outcome_index };
    let cap: &mut TreasuryCap<ConditionalCoinType> = dynamic_field::borrow_mut(
        &mut escrow.id,
        asset_key,
    );

    // Burn
    coin::burn(cap, coin);
}

/// Burn conditional stable coins for a specific outcome
///
/// Package-only: Used internally by progress pattern functions and burn_conditional wrapper.
/// Single-outcome burning would violate quantum invariant (escrow == supply for ALL outcomes).
public(package) fun burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
) {
    // Use escrow.outcome_count (registered caps) not market_state.outcome_count()
    // to ensure vectors/dynamic fields exist for this index
    assert!(outcome_index < escrow.outcome_count, EOutcomeOutOfBounds);

    // Track supply for quantum invariant (before burn)
    let amount = coin.value();
    let current_supply = &mut escrow.stable_supplies[outcome_index];
    *current_supply = *current_supply - amount;

    // NOTE: outcome_escrowed is updated by withdraw functions, NOT here.
    // This is because burn is also used by wrap_coin which doesn't change backing.

    // Borrow the TreasuryCap from dynamic field
    let stable_key = StableCapKey { outcome_index };
    let cap: &mut TreasuryCap<ConditionalCoinType> = dynamic_field::borrow_mut(
        &mut escrow.id,
        stable_key,
    );

    // Burn
    coin::burn(cap, coin);
}

// === NEW: Generic Mint/Burn for Balance-Based Operations ===

/// Package-internal mint function for conditional coins.
/// Used by conditional_balance.move and other within-package callers.
public(package) fun mint_conditional_pkg<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    if (is_asset) {
        mint_conditional_asset<AssetType, StableType, ConditionalCoinType>(
            escrow,
            outcome_index,
            amount,
            ctx,
        )
    } else {
        mint_conditional_stable<AssetType, StableType, ConditionalCoinType>(
            escrow,
            outcome_index,
            amount,
            ctx,
        )
    }
}

/// Generic mint function for conditional coins (used by balance unwrap)
/// Takes outcome_index and is_asset to determine which TreasuryCap to use
///
/// RESTRICTED: Requires EscrowMutationAuth. Single-outcome minting must be
/// part of an authorized atomic operation that maintains quantum invariant.
/// For within-package use, call mint_conditional_pkg instead.
public fun mint_conditional<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
    ctx: &mut TxContext,
    _auth: &EscrowMutationAuth,
): Coin<ConditionalCoinType> {
    mint_conditional_pkg(escrow, outcome_index, is_asset, amount, ctx)
}

/// Package-internal burn function for conditional coins.
/// Used by conditional_balance.move and other within-package callers.
public(package) fun burn_conditional_pkg<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    coin: Coin<ConditionalCoinType>,
) {
    if (is_asset) {
        burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
            escrow,
            outcome_index,
            coin,
        )
    } else {
        burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
            escrow,
            outcome_index,
            coin,
        )
    }
}

/// Generic burn function for conditional coins (used by balance wrap)
///
/// RESTRICTED: Requires EscrowMutationAuth. Single-outcome burning must be
/// part of an authorized atomic operation that maintains quantum invariant.
/// For within-package use, call burn_conditional_pkg instead.
public fun burn_conditional<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    coin: Coin<ConditionalCoinType>,
    _auth: &EscrowMutationAuth,
) {
    burn_conditional_pkg(escrow, outcome_index, is_asset, coin)
}

/// Deposit spot coins to escrow (for balance-based operations like arbitrage)
/// Returns amounts deposited (for balance tracking)
/// Note: Tracks as user backing since arbitrage completes in same tx (deposit then burn complete set)
///
/// RESTRICTED: Test-only. Production code uses atomic deposit+mint via Progress pattern.
/// Direct deposits without minting would violate the quantum invariant (escrow == supply).
#[test_only]
public fun deposit_spot_coins<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
): (u64, u64) {
    let asset_amt = asset_coin.value();
    let stable_amt = stable_coin.value();

    // Require at least one non-zero amount
    assert!(asset_amt > 0 || stable_amt > 0, EZeroAmount);

    // Add to escrow reserves
    balance::join(&mut escrow.escrowed_asset, coin::into_balance(asset_coin));
    balance::join(&mut escrow.escrowed_stable, coin::into_balance(stable_coin));

    // Track as user backing per-type
    escrow.user_deposited_asset = escrow.user_deposited_asset + asset_amt;
    escrow.user_deposited_stable = escrow.user_deposited_stable + stable_amt;

    (asset_amt, stable_amt)
}

/// Withdraw spot coins from escrow (for complete set burn)
///
/// RESTRICTED: Test-only. Production code uses atomic burn+withdraw via Progress pattern.
/// Direct withdrawal without burning would violate quantum invariant.
#[test_only]
public fun withdraw_from_escrow<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    assert!(balance::value(&escrow.escrowed_asset) >= asset_amount, ENotEnoughLiquidity);
    assert!(balance::value(&escrow.escrowed_stable) >= stable_amount, ENotEnoughLiquidity);

    let asset_bal = balance::split(&mut escrow.escrowed_asset, asset_amount);
    let stable_bal = balance::split(&mut escrow.escrowed_stable, stable_amount);

    // Decrement user backing per-type (saturating for cross-type scenarios)
    saturating_decrement_user_asset(escrow, asset_amount);
    saturating_decrement_user_stable(escrow, stable_amount);

    (coin::from_balance(asset_bal, ctx), coin::from_balance(stable_bal, ctx))
}

/// Get the total supply of a specific outcome's asset conditional coin
public fun get_asset_supply<AssetType, StableType, ConditionalCoinType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    let asset_key = AssetCapKey { outcome_index };
    let cap: &TreasuryCap<ConditionalCoinType> = dynamic_field::borrow(&escrow.id, asset_key);
    coin::total_supply(cap)
}

/// Get the total supply of a specific outcome's stable conditional coin
public fun get_stable_supply<AssetType, StableType, ConditionalCoinType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    let stable_key = StableCapKey { outcome_index };
    let cap: &TreasuryCap<ConditionalCoinType> = dynamic_field::borrow(&escrow.id, stable_key);
    coin::total_supply(cap)
}

// === Getters ===

/// Get the market state from escrow
public fun get_market_state<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): &MarketState {
    &escrow.market_state
}

/// Get mutable market state from escrow
///
/// RESTRICTED: Requires EscrowMutationAuth to prevent unauthorized market state manipulation.
public fun get_market_state_mut<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    _auth: &EscrowMutationAuth,
): &mut MarketState {
    &mut escrow.market_state
}

/// Get the market state ID from escrow
/// Returns the actual object ID of the embedded MarketState (its UID),
/// matching what's stored in proposal.market_state_id
public fun market_state_id<AssetType, StableType>(escrow: &TokenEscrow<AssetType, StableType>): ID {
    object::id(&escrow.market_state)
}

/// Get the number of outcomes that have registered TreasuryCaps
public fun caps_registered_count<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): u64 {
    escrow.outcome_count
}

/// Deposit spot liquidity into escrow (quantum liquidity model)
/// This adds to the escrow balances that will be split quantum-mechanically across all outcomes
/// Tracks as LP backing for safe recombination
///
/// RESTRICTED: Requires EscrowMutationAuth to enforce atomic deposit+mint via quantum_lp_manager.
/// Direct LP deposits without minting would violate the quantum invariant (escrow == supply).
public fun deposit_spot_liquidity<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset: Balance<AssetType>,
    stable: Balance<StableType>,
    _auth: &EscrowMutationAuth,
) {
    let asset_amt = asset.value();
    let stable_amt = stable.value();

    escrow.escrowed_asset.join(asset);
    escrow.escrowed_stable.join(stable);

    // Track as LP backing (can be recombined on proposal end)
    escrow.lp_deposited_asset = escrow.lp_deposited_asset + asset_amt;
    escrow.lp_deposited_stable = escrow.lp_deposited_stable + stable_amt;

    // NOTE: We intentionally do NOT call assert_accounting_invariant here.
    // This function is called by auto_rebalance arbitrage, which converts between
    // asset and stable types in the escrow. After prior arbitrage, per-type LP tracking
    // (lp_deposited_asset/stable) may not match escrowed amounts because arbitrage
    // legitimately changes the type composition. The quantum invariant (checked after
    // arbitrage completes) provides the real solvency guarantee.
}

/// Deposit spot stable coin for balance-based operations
/// Tracks as user backing (not LP backing)
///
/// Package-only for atomic balance operations.
public(package) fun deposit_spot_stable_for_balance<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable_coin: Coin<StableType>,
) {
    let amount = stable_coin.value();
    escrow.escrowed_stable.join(stable_coin.into_balance());
    escrow.user_deposited_stable = escrow.user_deposited_stable + amount;
}

/// Deposit spot asset coin for balance-based operations
/// Tracks as user backing (not LP backing)
///
/// Package-only for atomic balance operations.
public(package) fun deposit_spot_asset_for_balance<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
) {
    let amount = asset_coin.value();
    escrow.escrowed_asset.join(asset_coin.into_balance());
    escrow.user_deposited_asset = escrow.user_deposited_asset + amount;
}

/// LP quantum deposit: deposit spot and virtually mint for ALL outcomes
/// This maintains the quantum invariant by incrementing supply for each outcome.
/// No actual Coin objects are created - supplies are tracked numerically.
/// Used during market creation to seed initial liquidity.
///
/// RESTRICTED: Requires EscrowMutationAuth to ensure only authorized packages can call.
/// This prevents arbitrary inflation of lp_deposited tracking and supplies.
///
/// Returns (asset_amount, stable_amount) for distribution to AMM pools.
public fun lp_deposit_quantum<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset: Balance<AssetType>,
    stable: Balance<StableType>,
    _auth: &EscrowMutationAuth,
): (u64, u64) {
    // Guard: Must have registered caps before quantum operations
    assert!(escrow.outcome_count > 0, ESuppliesNotInitialized);

    let asset_amt = asset.value();
    let stable_amt = stable.value();

    // Deposit spot to escrow
    escrow.escrowed_asset.join(asset);
    escrow.escrowed_stable.join(stable);

    // Track as LP backing
    escrow.lp_deposited_asset = escrow.lp_deposited_asset + asset_amt;
    escrow.lp_deposited_stable = escrow.lp_deposited_stable + stable_amt;

    // Virtual mint: increment supply AND allocation for ALL outcomes (quantum model)
    let mut i = 0;
    while (i < escrow.outcome_count) {
        let asset_supply = &mut escrow.asset_supplies[i];
        *asset_supply = *asset_supply + asset_amt;

        let stable_supply = &mut escrow.stable_supplies[i];
        *stable_supply = *stable_supply + stable_amt;

        // Track per-outcome allocation (backing for each outcome's circulation)
        let asset_alloc = &mut escrow.outcome_escrowed_asset[i];
        *asset_alloc = *asset_alloc + asset_amt;

        let stable_alloc = &mut escrow.outcome_escrowed_stable[i];
        *stable_alloc = *stable_alloc + stable_amt;

        // Track pool claim (LP portion of allocation, constant during trading)
        let pool_asset = &mut escrow.pool_claim_asset[i];
        *pool_asset = *pool_asset + asset_amt;

        let pool_stable = &mut escrow.pool_claim_stable[i];
        *pool_stable = *pool_stable + stable_amt;

        i = i + 1;
    };

    // Enforce invariants
    assert_accounting_invariant(escrow);
    assert_quantum_invariant(escrow);

    (asset_amt, stable_amt)
}

/// Increment supplies AND allocations for ALL outcomes (quantum model)
/// Used by arbitrage when depositing to escrow to maintain the invariant.
/// MUST be called atomically with deposit_spot_liquidity to preserve invariant.
///
/// RESTRICTED: Requires EscrowMutationAuth.
public fun increment_supplies_for_all_outcomes<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    _auth: &EscrowMutationAuth,
) {
    // Guard: Must have registered caps before quantum operations
    assert!(escrow.outcome_count > 0, ESuppliesNotInitialized);

    let mut i = 0;
    while (i < escrow.outcome_count) {
        if (asset_amount > 0) {
            let asset_supply = &mut escrow.asset_supplies[i];
            assert!(*asset_supply <= 0xFFFFFFFFFFFFFFFF - asset_amount, EAllocationOverflow);
            *asset_supply = *asset_supply + asset_amount;
            // Track per-outcome allocation
            let asset_alloc = &mut escrow.outcome_escrowed_asset[i];
            assert!(*asset_alloc <= 0xFFFFFFFFFFFFFFFF - asset_amount, EAllocationOverflow);
            *asset_alloc = *asset_alloc + asset_amount;
            // Keep non-user claim tracking in sync for virtual (arb/system) minting.
            let pool_asset = &mut escrow.pool_claim_asset[i];
            assert!(*pool_asset <= 0xFFFFFFFFFFFFFFFF - asset_amount, EAllocationOverflow);
            *pool_asset = *pool_asset + asset_amount;
        };
        if (stable_amount > 0) {
            let stable_supply = &mut escrow.stable_supplies[i];
            assert!(*stable_supply <= 0xFFFFFFFFFFFFFFFF - stable_amount, EAllocationOverflow);
            *stable_supply = *stable_supply + stable_amount;
            // Track per-outcome allocation
            let stable_alloc = &mut escrow.outcome_escrowed_stable[i];
            assert!(*stable_alloc <= 0xFFFFFFFFFFFFFFFF - stable_amount, EAllocationOverflow);
            *stable_alloc = *stable_alloc + stable_amount;
            // Keep non-user claim tracking in sync for virtual (arb/system) minting.
            let pool_stable = &mut escrow.pool_claim_stable[i];
            assert!(*pool_stable <= 0xFFFFFFFFFFFFFFFF - stable_amount, EAllocationOverflow);
            *pool_stable = *pool_stable + stable_amount;
        };
        i = i + 1;
    };
}

/// Increment wrapped balance for ALL outcomes and check invariant
/// Used by split operations in conditional_balance (deposit spot → get balance)
/// Must be called AFTER depositing spot to escrow
///
/// RESTRICTED: Package-only to prevent external manipulation of wrapped balance tracking.
public(package) fun increment_wrapped_for_all_and_check_invariant<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    is_asset: bool,
    amount: u64,
) {
    // Guard: Must have registered caps before quantum operations
    assert!(escrow.outcome_count > 0, ESuppliesNotInitialized);

    let mut i = 0;
    while (i < escrow.outcome_count) {
        if (is_asset) {
            let wrapped = &mut escrow.wrapped_asset_balances[i];
            *wrapped = *wrapped + amount;
        } else {
            let wrapped = &mut escrow.wrapped_stable_balances[i];
            *wrapped = *wrapped + amount;
        };
        i = i + 1;
    };
    // Check invariant after all updates
    assert_quantum_invariant(escrow);
}

/// Decrement wrapped balance for ALL outcomes and check invariant
/// Used by recombine/burn operations in conditional_balance (burn balance → get spot)
/// Must be called BEFORE withdrawing spot from escrow
///
/// RESTRICTED: Package-only to prevent external manipulation of wrapped balance tracking.
public(package) fun decrement_wrapped_for_all_and_check_invariant<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    is_asset: bool,
    amount: u64,
) {
    // Guard: Must have registered caps before quantum operations
    assert!(escrow.outcome_count > 0, ESuppliesNotInitialized);

    let mut i = 0;
    while (i < escrow.outcome_count) {
        if (is_asset) {
            let wrapped = &mut escrow.wrapped_asset_balances[i];
            assert!(*wrapped >= amount, ENotEnoughLiquidity);
            *wrapped = *wrapped - amount;
        } else {
            let wrapped = &mut escrow.wrapped_stable_balances[i];
            assert!(*wrapped >= amount, ENotEnoughLiquidity);
            *wrapped = *wrapped - amount;
        };
        i = i + 1;
    };
    // Check invariant after all updates
    assert_quantum_invariant(escrow);
}

/// Decrement supply for a SINGLE outcome (for moving from supply to wrapped)
/// Used when different outcomes have different output amounts (e.g., arbitrage dust).
/// This moves tokens from supply tracking to wrapped tracking (total circulation unchanged).
///
/// RESTRICTED: Requires EscrowMutationAuth.
public fun decrement_supply_for_outcome<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
    _auth: &EscrowMutationAuth,
) {
    // Validate outcome index is within bounds
    assert!(outcome_index < escrow.outcome_count, EOutcomeOutOfBounds);
    if (is_asset) {
        let supply = &mut escrow.asset_supplies[outcome_index];
        assert!(*supply >= amount, EAllocationUnderflow);
        *supply = *supply - amount;
    } else {
        let supply = &mut escrow.stable_supplies[outcome_index];
        assert!(*supply >= amount, EAllocationUnderflow);
        *supply = *supply - amount;
    };
}

/// Increment outcome_escrowed allocation for ALL outcomes (without changing supply)
/// Used by split operations in conditional_balance where spot is deposited to escrow
/// and wrapped balance is created for all outcomes.
///
/// WHY: When users deposit spot → wrapped balance, the backing allocation must increase
/// even though no conditional coins are minted (supply unchanged).
/// Invariant: outcome_escrowed[i] == supply[i] + wrapped[i]
/// Since wrapped[i] increases, outcome_escrowed[i] must also increase.
public(package) fun increment_outcome_escrowed_for_all<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    is_asset: bool,
    amount: u64,
) {
    let mut i = 0;
    while (i < escrow.outcome_count) {
        if (is_asset) {
            let alloc = &mut escrow.outcome_escrowed_asset[i];
            *alloc = *alloc + amount;
        } else {
            let alloc = &mut escrow.outcome_escrowed_stable[i];
            *alloc = *alloc + amount;
        };
        i = i + 1;
    };
}

/// Decrement outcome_escrowed allocation for ALL outcomes (without changing supply)
/// Used by burn_complete_set operations where wrapped balance is burned and
/// spot is withdrawn from escrow.
///
/// WHY: When users burn wrapped balance → withdraw spot, the backing allocation must decrease
/// even though no conditional coins are burned (supply unchanged).
/// Invariant: outcome_escrowed[i] == supply[i] + wrapped[i]
/// Since wrapped[i] decreases, outcome_escrowed[i] must also decrease.
public(package) fun decrement_outcome_escrowed_for_all<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    is_asset: bool,
    amount: u64,
) {
    let mut i = 0;
    while (i < escrow.outcome_count) {
        if (is_asset) {
            let alloc = &mut escrow.outcome_escrowed_asset[i];
            assert!(*alloc >= amount, EAllocationUnderflow);
            *alloc = *alloc - amount;
        } else {
            let alloc = &mut escrow.outcome_escrowed_stable[i];
            assert!(*alloc >= amount, EAllocationUnderflow);
            *alloc = *alloc - amount;
        };
        i = i + 1;
    };
}

/// LP quantum withdraw after finalization.
/// Withdraw amount is capped by winning-outcome supply, LP backing, and escrow balance.
/// This prevents underflow when wrapped balances reduced winning supply.
///
/// RESTRICTED: Requires EscrowMutationAuth and only callable after market finalization.
public fun lp_withdraw_quantum<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    _auth: &EscrowMutationAuth,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    // Only allow after finalization
    assert!(market_state::is_finalized(&escrow.market_state), EMarketNotFinalized);

    let winning_outcome = market_state::get_winning_outcome(&escrow.market_state);
    let escrow_asset = escrow.escrowed_asset.value();
    let escrow_stable = escrow.escrowed_stable.value();
    let lp_asset = escrow.lp_deposited_asset;
    let lp_stable = escrow.lp_deposited_stable;
    let winning_asset_supply = escrow.asset_supplies[winning_outcome];
    let winning_stable_supply = escrow.stable_supplies[winning_outcome];

    // User claim cap: LP cannot withdraw so much that user claims become unbacked.
    // user_claim = outcome_escrowed - pool_claim (what users need per-type)
    // LP can withdraw at most: escrow - user_claim per type
    let oe_asset = escrow.outcome_escrowed_asset[winning_outcome];
    let oe_stable = escrow.outcome_escrowed_stable[winning_outcome];
    let pc_asset = escrow.pool_claim_asset[winning_outcome];
    let pc_stable = escrow.pool_claim_stable[winning_outcome];
    let user_claim_asset = if (oe_asset > pc_asset) { oe_asset - pc_asset } else { 0 };
    let user_claim_stable = if (oe_stable > pc_stable) { oe_stable - pc_stable } else { 0 };
    let user_cap_asset = if (escrow_asset > user_claim_asset) {
        escrow_asset - user_claim_asset
    } else { 0 };
    let user_cap_stable = if (escrow_stable > user_claim_stable) {
        escrow_stable - user_claim_stable
    } else { 0 };

    let max_asset = {
        let a = if (lp_asset < winning_asset_supply) { lp_asset } else { winning_asset_supply };
        let a = if (a < user_cap_asset) { a } else { user_cap_asset };
        if (a < pc_asset) { a } else { pc_asset }
    };
    let max_stable = {
        let a = if (lp_stable < winning_stable_supply) { lp_stable } else { winning_stable_supply };
        let a = if (a < user_cap_stable) { a } else { user_cap_stable };
        if (a < pc_stable) { a } else { pc_stable }
    };

    let withdraw_asset = if (asset_amount < max_asset) { asset_amount } else { max_asset };
    let withdraw_stable = if (stable_amount < max_stable) {
        stable_amount
    } else {
        max_stable
    };

    if (withdraw_asset > 0) {
        let asset_supply = &mut escrow.asset_supplies[winning_outcome];
        *asset_supply = *asset_supply - withdraw_asset;
        let asset_alloc = &mut escrow.outcome_escrowed_asset[winning_outcome];
        *asset_alloc = *asset_alloc - withdraw_asset;
        // Saturating decrement: swaps may have shifted types so pool_claim for a type
        // can exceed what was actually withdrawn from that type.
        let asset_claim = &mut escrow.pool_claim_asset[winning_outcome];
        if (*asset_claim >= withdraw_asset) {
            *asset_claim = *asset_claim - withdraw_asset;
        } else {
            *asset_claim = 0;
        };
    };
    if (withdraw_stable > 0) {
        let stable_supply = &mut escrow.stable_supplies[winning_outcome];
        *stable_supply = *stable_supply - withdraw_stable;
        let stable_alloc = &mut escrow.outcome_escrowed_stable[winning_outcome];
        *stable_alloc = *stable_alloc - withdraw_stable;
        // Saturating decrement: swaps may have shifted types so pool_claim for a type
        // can exceed what was actually withdrawn from that type.
        let stable_claim = &mut escrow.pool_claim_stable[winning_outcome];
        if (*stable_claim >= withdraw_stable) {
            *stable_claim = *stable_claim - withdraw_stable;
        } else {
            *stable_claim = 0;
        };
    };

    // Decrement LP backing (use internal helper - lp_withdraw_quantum is a safe entry point)
    decrement_lp_backing_internal(escrow, withdraw_asset, withdraw_stable);

    // Withdraw from escrow (use internal helpers - lp_withdraw_quantum is a safe entry point)
    let asset_coin = withdraw_asset_balance_pkg(escrow, withdraw_asset, ctx);
    let stable_coin = withdraw_stable_balance_pkg(escrow, withdraw_stable, ctx);

    // Enforce quantum invariant (post-finalization: winning outcome only)
    assert_quantum_invariant(escrow);

    (asset_coin, stable_coin)
}

// === Burn and Withdraw Helpers (For Redemption) ===

/// Burn conditional asset coins and withdraw equivalent spot asset
/// Used when redeeming conditional coins back to spot tokens (e.g., after market finalization)
///
/// SECURITY: Only allows withdrawal from winning outcome after market finalization.
/// For pre-finalization exit, use complete-set withdrawal (burn from ALL outcomes).
public fun burn_conditional_asset_and_withdraw<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_coin: Coin<ConditionalCoinType>,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // SECURITY CHECK: Market must be finalized for single-outcome withdrawal
    assert!(market_state::is_finalized(&escrow.market_state), EMarketNotFinalized);

    // Get the winning outcome
    let winning_outcome = market_state::get_winning_outcome(&escrow.market_state);

    let amount = conditional_coin.value();
    assert!(amount > 0, EZeroAmount);

    // Burn the user's conditional coins
    burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        winning_outcome,
        conditional_coin,
    );

    // Explicit balance check before split for better error messages
    assert!(escrow.escrowed_asset.value() >= amount, ENotEnoughLiquidity);

    // Withdraw equivalent spot tokens (1:1 due to quantum liquidity)
    let asset_balance = escrow.escrowed_asset.split(amount);

    // Decrement user backing (saturating for cross-type swap scenarios)
    saturating_decrement_user_asset(escrow, amount);

    // Track per-outcome allocation (backing is being removed)
    let alloc = &mut escrow.outcome_escrowed_asset[winning_outcome];
    *alloc = *alloc - amount;

    // Enforce quantum invariant (post-finalization: only winning outcome checked)
    assert_quantum_invariant(escrow);

    coin::from_balance(asset_balance, ctx)
}

/// Burn conditional stable coins and withdraw equivalent spot stable
///
/// SECURITY: Only allows withdrawal from winning outcome after market finalization.
/// For pre-finalization exit, use complete-set withdrawal (burn from ALL outcomes).
public fun burn_conditional_stable_and_withdraw<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_coin: Coin<ConditionalCoinType>,
    ctx: &mut TxContext,
): Coin<StableType> {
    // SECURITY CHECK: Market must be finalized for single-outcome withdrawal
    assert!(market_state::is_finalized(&escrow.market_state), EMarketNotFinalized);

    // Get the winning outcome
    let winning_outcome = market_state::get_winning_outcome(&escrow.market_state);

    let amount = conditional_coin.value();
    assert!(amount > 0, EZeroAmount);

    // Burn the user's conditional coins
    burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        winning_outcome,
        conditional_coin,
    );

    // Explicit balance check before split for better error messages
    assert!(escrow.escrowed_stable.value() >= amount, ENotEnoughLiquidity);

    // Withdraw equivalent spot tokens
    let stable_balance = escrow.escrowed_stable.split(amount);

    // Decrement user backing (saturating for cross-type swap scenarios)
    saturating_decrement_user_stable(escrow, amount);

    // Track per-outcome allocation (backing is being removed)
    let alloc = &mut escrow.outcome_escrowed_stable[winning_outcome];
    *alloc = *alloc - amount;

    // Enforce quantum invariant (post-finalization: only winning outcome checked)
    assert_quantum_invariant(escrow);

    coin::from_balance(stable_balance, ctx)
}

// Note: burn_complete_set_and_withdraw_from_balance moved to conditional_balance.move
// to avoid cyclic dependency between coin_escrow and conditional_balance

// NOTE: Single-outcome deposit+mint functions (deposit_asset_and_mint_conditional,
// deposit_stable_and_mint_conditional) were REMOVED. They were dead code in production
// (all real deposits go through split_*_to_balance for all outcomes) and exposed a
// post-finalization attack surface where users could deposit to losing outcomes and
// permanently trap their spot tokens. Test-only versions are in the test helpers section.

/// Get escrow spot balances (read-only)
public fun get_spot_balances<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (u64, u64) {
    (escrow.escrowed_asset.value(), escrow.escrowed_stable.value())
}

/// Get escrowed asset balance
public fun get_escrowed_asset_balance<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): u64 {
    escrow.escrowed_asset.value()
}

/// Get escrowed stable balance
public fun get_escrowed_stable_balance<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): u64 {
    escrow.escrowed_stable.value()
}

/// Get LP deposited asset backing
public fun get_lp_deposited_asset<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): u64 {
    escrow.lp_deposited_asset
}

/// Get LP deposited stable backing
public fun get_lp_deposited_stable<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): u64 {
    escrow.lp_deposited_stable
}

/// Get user deposited asset backing
public fun get_user_deposited_asset<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): u64 {
    escrow.user_deposited_asset
}

/// Get user deposited stable backing
public fun get_user_deposited_stable<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): u64 {
    escrow.user_deposited_stable
}

/// Get asset supply for a specific outcome (for quantum invariant validation)
public fun get_outcome_asset_supply<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.asset_supplies[outcome_index]
}

/// Get stable supply for a specific outcome (for quantum invariant validation)
public fun get_outcome_stable_supply<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.stable_supplies[outcome_index]
}

/// Get wrapped asset balance for a specific outcome
public fun get_outcome_wrapped_asset<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.wrapped_asset_balances[outcome_index]
}

/// Get wrapped stable balance for a specific outcome
public fun get_outcome_wrapped_stable<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.wrapped_stable_balances[outcome_index]
}

/// Get error code for quantum invariant violation (for use in inlined checks)
public fun quantum_invariant_error(): u64 {
    EQuantumInvariantViolation
}

/// Get all asset supplies (for diagnostics)
public fun get_all_asset_supplies<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): &vector<u64> {
    &escrow.asset_supplies
}

/// Get all stable supplies (for diagnostics)
public fun get_all_stable_supplies<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): &vector<u64> {
    &escrow.stable_supplies
}

/// Get all supplies (both asset and stable) for diagnostics
public fun get_all_supplies<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (vector<u64>, vector<u64>) {
    (escrow.asset_supplies, escrow.stable_supplies)
}

/// Get all wrapped balances (both asset and stable) for diagnostics
public fun get_wrapped_balances<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (vector<u64>, vector<u64>) {
    (escrow.wrapped_asset_balances, escrow.wrapped_stable_balances)
}

/// Internal helper for decrementing LP backing.
/// Called by lp_withdraw_quantum and the public auth-requiring wrapper.
fun decrement_lp_backing_internal<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
) {
    assert!(escrow.lp_deposited_asset >= asset_amount, ENotEnoughLiquidity);
    assert!(escrow.lp_deposited_stable >= stable_amount, ENotEnoughLiquidity);
    escrow.lp_deposited_asset = escrow.lp_deposited_asset - asset_amount;
    escrow.lp_deposited_stable = escrow.lp_deposited_stable - stable_amount;

    // NOTE: We intentionally do NOT call assert_accounting_invariant here.
    // During trading, arbitrage can change the escrow composition (asset↔stable conversion)
    // while LP tracking reflects the original deposit composition. This is expected behavior
    // in the quantum liquidity model - the quantum invariant ensures overall solvency,
    // while per-type composition can legitimately differ due to arbitrage/swaps.
}

/// Decrement LP backing after recombination (called by quantum_lp_manager)
/// Aborts if amount exceeds tracked LP deposits - this indicates an accounting bug.
///
/// RESTRICTED: Requires EscrowMutationAuth to prevent accounting corruption.
public fun decrement_lp_backing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    _auth: &EscrowMutationAuth,
) {
    decrement_lp_backing_internal(escrow, asset_amount, stable_amount);
}

/// Decrement per-outcome allocation during LP withdrawal.
/// Called by quantum_lp_manager when LP withdraws liquidity at proposal finalization.
///
/// This is CRITICAL for maintaining the quantum invariant: when LP's backing is
/// withdrawn from escrow, the corresponding allocation must also decrease. Otherwise,
/// the allocation would exceed the actual escrow balance, causing user redemptions to fail.
///
/// RESTRICTED: Requires EscrowMutationAuth to prevent accounting corruption.
public fun decrement_outcome_allocation<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    asset_amount: u64,
    stable_amount: u64,
    _auth: &EscrowMutationAuth,
) {
    // Decrement asset allocation for this outcome
    let asset_alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
    assert!(*asset_alloc >= asset_amount, ENotEnoughLiquidity);
    *asset_alloc = *asset_alloc - asset_amount;

    // Decrement stable allocation for this outcome
    let stable_alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
    assert!(*stable_alloc >= stable_amount, ENotEnoughLiquidity);
    *stable_alloc = *stable_alloc - stable_amount;
}

// === Pool Claim (Dual-Ledger) ===
// pool_claim tracks the LP/AMM portion of outcome_escrowed. It is:
// - Set during quantum split (same amounts as outcome_escrowed increment)
// - Unchanged by typed user swaps (track_swap does NOT touch it)
// - Decremented during LP unwind at proposal end
// user_claim = outcome_escrowed - pool_claim gives the amount users need per-type.

/// Decrement pool claim for a specific outcome during LP unwind.
/// Called by quantum_lp_manager when LP withdraws at proposal finalization.
///
/// RESTRICTED: Requires EscrowMutationAuth to prevent accounting corruption.
public fun decrement_pool_claim<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    asset_amount: u64,
    stable_amount: u64,
    _auth: &EscrowMutationAuth,
) {
    // Saturating subtraction: after swaps, the LP withdrawal per type may not
    // match the original deposit composition. pool_claim bottoms out at 0.
    let escrow_id = object::id(escrow);
    let asset_claim = &mut escrow.pool_claim_asset[outcome_index];
    if (*asset_claim >= asset_amount) {
        *asset_claim = *asset_claim - asset_amount;
    } else {
        sui::event::emit(SaturatingSubtractionEvent {
            escrow_id,
            field: b"pool_claim_asset",
            outcome_index,
            requested: asset_amount,
            available: *asset_claim,
        });
        *asset_claim = 0;
    };

    let stable_claim = &mut escrow.pool_claim_stable[outcome_index];
    if (*stable_claim >= stable_amount) {
        *stable_claim = *stable_claim - stable_amount;
    } else {
        sui::event::emit(SaturatingSubtractionEvent {
            escrow_id,
            field: b"pool_claim_stable",
            outcome_index,
            requested: stable_amount,
            available: *stable_claim,
        });
        *stable_claim = 0;
    };
}

/// Get pool claim asset for a specific outcome
public fun get_pool_claim_asset<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.pool_claim_asset[outcome_index]
}

/// Get pool claim stable for a specific outcome
public fun get_pool_claim_stable<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.pool_claim_stable[outcome_index]
}

// === User Backing Helpers ===
// Saturating decrement: cross-type swaps may cause users to withdraw from a type
// they didn't deposit into (e.g., deposit stable, swap to conditional asset, redeem asset).
// The quantum invariant is the primary solvency guard; these counters are for accounting.

fun saturating_decrement_user_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
) {
    if (escrow.user_deposited_asset >= amount) {
        escrow.user_deposited_asset = escrow.user_deposited_asset - amount;
    } else {
        sui::event::emit(SaturatingSubtractionEvent {
            escrow_id: object::id(escrow),
            field: b"user_deposited_asset",
            outcome_index: 18446744073709551615, // u64::MAX = not per-outcome
            requested: amount,
            available: escrow.user_deposited_asset,
        });
        escrow.user_deposited_asset = 0;
    };
}

fun saturating_decrement_user_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
) {
    if (escrow.user_deposited_stable >= amount) {
        escrow.user_deposited_stable = escrow.user_deposited_stable - amount;
    } else {
        sui::event::emit(SaturatingSubtractionEvent {
            escrow_id: object::id(escrow),
            field: b"user_deposited_stable",
            outcome_index: 18446744073709551615, // u64::MAX = not per-outcome
            requested: amount,
            available: escrow.user_deposited_stable,
        });
        escrow.user_deposited_stable = 0;
    };
}

/// Package-internal version of decrement_user_backing.
/// Called by conditional_balance.move and other within-package callers.
/// Uses saturating subtraction: cross-type swaps may cause type mismatch.
public(package) fun decrement_user_backing_pkg<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    is_asset: bool,
) {
    if (is_asset) {
        saturating_decrement_user_asset(escrow, amount);
    } else {
        saturating_decrement_user_stable(escrow, amount);
    };
}

/// Decrement user backing after withdrawal (for complete set burns via balance wrapper)
/// Uses saturating subtraction: cross-type swaps may cause type mismatch.
///
/// RESTRICTED: Requires EscrowMutationAuth to prevent accounting corruption.
/// For within-package use, call decrement_user_backing_pkg instead.
public fun decrement_user_backing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    is_asset: bool,
    _auth: &EscrowMutationAuth,
) {
    decrement_user_backing_pkg(escrow, amount, is_asset);
}

/// Package-internal version of increment_wrapped_balance.
/// Called by conditional_balance.move and other within-package callers.
public(package) fun increment_wrapped_balance_pkg<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
) {
    if (is_asset) {
        let current = &mut escrow.wrapped_asset_balances[outcome_index];
        assert!(*current <= 0xFFFFFFFFFFFFFFFF - amount, EAllocationOverflow);
        *current = *current + amount;
    } else {
        let current = &mut escrow.wrapped_stable_balances[outcome_index];
        assert!(*current <= 0xFFFFFFFFFFFFFFFF - amount, EAllocationOverflow);
        *current = *current + amount;
    };
}

/// Increment wrapped balance tracking when a coin is wrapped into a ConditionalMarketBalance.
/// Called by conditional_balance::wrap_coin after burning the actual coin.
///
/// RESTRICTED: Requires EscrowMutationAuth to maintain invariant: escrowed == supply + wrapped
/// NOTE: This is a TYPE CONVERSION (supply → wrapped), so escrowed is NOT updated.
/// The supply was already decremented elsewhere, so total circulation is unchanged.
/// For within-package use, call increment_wrapped_balance_pkg instead.
public fun increment_wrapped_balance<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
    _auth: &EscrowMutationAuth,
) {
    increment_wrapped_balance_pkg(escrow, outcome_index, is_asset, amount);
}

/// Increment dust_created counter when arbitrage creates dust for an outcome.
/// Monotonic: only ever incremented, never decremented.
/// Retained for diagnostics/auditing. NOT used in withdrawal calculations —
/// the pool_claim-based user_claim cap provides correct, non-monotonic solvency protection.
///
/// RESTRICTED: Requires EscrowMutationAuth (called from arbitrage.move).
public fun increment_dust_created<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
    _auth: &EscrowMutationAuth,
) {
    if (is_asset) {
        let current = &mut escrow.dust_created_asset[outcome_index];
        *current = if (*current <= 0xFFFFFFFFFFFFFFFF - amount) {
            *current + amount
        } else {
            0xFFFFFFFFFFFFFFFF
        };
    } else {
        let current = &mut escrow.dust_created_stable[outcome_index];
        *current = if (*current <= 0xFFFFFFFFFFFFFFFF - amount) {
            *current + amount
        } else {
            0xFFFFFFFFFFFFFFFF
        };
    };
}

/// Get cumulative dust created for a specific outcome (asset side).
public fun get_dust_created_asset<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.dust_created_asset[outcome_index]
}

/// Get cumulative dust created for a specific outcome (stable side).
public fun get_dust_created_stable<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.dust_created_stable[outcome_index]
}

/// Package-internal version of decrement_wrapped_balance.
/// Called by conditional_balance.move and other within-package callers.
public(package) fun decrement_wrapped_balance_pkg<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
) {
    if (is_asset) {
        let current = &mut escrow.wrapped_asset_balances[outcome_index];
        assert!(*current >= amount, ENotEnoughLiquidity);
        *current = *current - amount;
    } else {
        let current = &mut escrow.wrapped_stable_balances[outcome_index];
        assert!(*current >= amount, ENotEnoughLiquidity);
        *current = *current - amount;
    };
}

/// Decrement wrapped balance tracking when a coin is unwrapped or withdrawn.
/// Called by conditional_balance::unwrap_to_coin and burn_complete_set_and_withdraw_from_balance.
///
/// RESTRICTED: Requires EscrowMutationAuth to maintain invariant: escrowed == supply + wrapped
/// NOTE: This is a TYPE CONVERSION (wrapped → supply), so escrowed is NOT updated.
/// The supply will be incremented elsewhere, so total circulation is unchanged.
/// For within-package use, call decrement_wrapped_balance_pkg instead.
public fun decrement_wrapped_balance<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
    _auth: &EscrowMutationAuth,
) {
    decrement_wrapped_balance_pkg(escrow, outcome_index, is_asset, amount);
}

// === Swap Type Conversion Tracking ===
//
// Track type conversions from swaps to update per-outcome allocations.
// ONLY updated in swap_balance_* functions in swap_core.move - nowhere else!
//
// When swapping, one type is consumed and another is produced within the same outcome.
// This converts allocation between types without changing total allocation.
//
// Invariant: outcome_escrowed[i] == supply[i] + wrapped[i] for each type

/// Track a stable→asset swap for per-outcome allocation.
/// Called by swap_core after a balance-based swap.
///
/// When stable is swapped for asset in outcome i:
/// - stable allocation decreases by stable_in
/// - asset allocation increases by asset_out
///
/// RESTRICTED: Requires EscrowMutationAuth - only call from swap_core swap functions.
public fun track_swap_stable_to_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    stable_in: u64,
    asset_out: u64,
    _auth: &EscrowMutationAuth,
) {
    // Bounds check: ensure allocation won't underflow
    let stable_alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
    assert!(*stable_alloc >= stable_in, EAllocationUnderflow);

    // Bounds check: ensure allocation won't overflow
    let asset_alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
    assert!(*asset_alloc <= 0xFFFFFFFFFFFFFFFF - asset_out, EAllocationOverflow);

    // Decrement stable allocation (stable was consumed by swap)
    *stable_alloc = *stable_alloc - stable_in;

    // Increment asset allocation (asset was produced by swap)
    *asset_alloc = *asset_alloc + asset_out;
}

/// Track an asset→stable swap for per-outcome allocation.
/// Called by swap_core after a balance-based swap.
///
/// When asset is swapped for stable in outcome i:
/// - asset allocation decreases by asset_in
/// - stable allocation increases by stable_out
///
/// RESTRICTED: Requires EscrowMutationAuth - only call from swap_core swap functions.
public fun track_swap_asset_to_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    asset_in: u64,
    stable_out: u64,
    _auth: &EscrowMutationAuth,
) {
    // Bounds check: ensure allocation won't underflow
    let asset_alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
    assert!(*asset_alloc >= asset_in, EAllocationUnderflow);

    // Bounds check: ensure allocation won't overflow
    let stable_alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
    assert!(*stable_alloc <= 0xFFFFFFFFFFFFFFFF - stable_out, EAllocationOverflow);

    // Decrement asset allocation (asset was consumed by swap)
    *asset_alloc = *asset_alloc - asset_in;

    // Increment stable allocation (stable was produced by swap)
    *stable_alloc = *stable_alloc + stable_out;
}

/// Track a system-level (arbitrage) conditional swap: stable consumed, asset produced.
///
/// Unlike user swaps (which go through burn/mint + track_swap), arbitrage operates via
/// inject/swap/extract on AMM reserve counters. This function applies the equivalent
/// accounting shift to escrow state for a single outcome:
///   - supply: stable decreases, asset increases
///   - outcome_escrowed: stable decreases, asset increases
///   - pool_claim: stable decreases (saturating), asset increases
///
/// RESTRICTED: Requires EscrowMutationAuth.
public fun track_system_swap_stable_to_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    stable_consumed: u64,
    asset_produced: u64,
    _auth: &EscrowMutationAuth,
) {
    // Supply shift: stable consumed, asset produced
    let stable_supply = &mut escrow.stable_supplies[outcome_index];
    assert!(*stable_supply >= stable_consumed, EAllocationUnderflow);
    *stable_supply = *stable_supply - stable_consumed;

    let asset_supply = &mut escrow.asset_supplies[outcome_index];
    assert!(*asset_supply <= 0xFFFFFFFFFFFFFFFF - asset_produced, EAllocationOverflow);
    *asset_supply = *asset_supply + asset_produced;

    // Outcome escrowed shift: stable consumed, asset produced
    let stable_alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
    assert!(*stable_alloc >= stable_consumed, EAllocationUnderflow);
    *stable_alloc = *stable_alloc - stable_consumed;

    let asset_alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
    assert!(*asset_alloc <= 0xFFFFFFFFFFFFFFFF - asset_produced, EAllocationOverflow);
    *asset_alloc = *asset_alloc + asset_produced;

    // Pool claim shift: stable consumed (saturating), asset produced.
    // Saturating on consumed side because user swaps can deplete pool_claim
    // below the arb input amount without breaking invariants.
    let pool_stable = &mut escrow.pool_claim_stable[outcome_index];
    if (*pool_stable >= stable_consumed) {
        *pool_stable = *pool_stable - stable_consumed;
    } else {
        *pool_stable = 0;
    };
    let pool_asset = &mut escrow.pool_claim_asset[outcome_index];
    assert!(*pool_asset <= 0xFFFFFFFFFFFFFFFF - asset_produced, EAllocationOverflow);
    *pool_asset = *pool_asset + asset_produced;
}

/// Track a system-level (arbitrage) conditional swap: asset consumed, stable produced.
///
/// Mirror of track_system_swap_stable_to_asset for the opposite direction.
/// Shifts all 3 accounting layers: supply, outcome_escrowed, pool_claim.
///
/// RESTRICTED: Requires EscrowMutationAuth.
public fun track_system_swap_asset_to_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    asset_consumed: u64,
    stable_produced: u64,
    _auth: &EscrowMutationAuth,
) {
    // Supply shift: asset consumed, stable produced
    let asset_supply = &mut escrow.asset_supplies[outcome_index];
    assert!(*asset_supply >= asset_consumed, EAllocationUnderflow);
    *asset_supply = *asset_supply - asset_consumed;

    let stable_supply = &mut escrow.stable_supplies[outcome_index];
    assert!(*stable_supply <= 0xFFFFFFFFFFFFFFFF - stable_produced, EAllocationOverflow);
    *stable_supply = *stable_supply + stable_produced;

    // Outcome escrowed shift: asset consumed, stable produced
    let asset_alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
    assert!(*asset_alloc >= asset_consumed, EAllocationUnderflow);
    *asset_alloc = *asset_alloc - asset_consumed;

    let stable_alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
    assert!(*stable_alloc <= 0xFFFFFFFFFFFFFFFF - stable_produced, EAllocationOverflow);
    *stable_alloc = *stable_alloc + stable_produced;

    // Pool claim shift: asset consumed (saturating), stable produced.
    // Saturating on consumed side because user swaps can deplete pool_claim
    // below the arb input amount without breaking invariants.
    let pool_asset = &mut escrow.pool_claim_asset[outcome_index];
    if (*pool_asset >= asset_consumed) {
        *pool_asset = *pool_asset - asset_consumed;
    } else {
        *pool_asset = 0;
    };
    let pool_stable = &mut escrow.pool_claim_stable[outcome_index];
    assert!(*pool_stable <= 0xFFFFFFFFFFFFFFFF - stable_produced, EAllocationOverflow);
    *pool_stable = *pool_stable + stable_produced;
}

/// Get per-outcome escrowed asset allocation (for diagnostics)
public fun get_outcome_escrowed_asset<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.outcome_escrowed_asset[outcome_index]
}

/// Get per-outcome escrowed stable allocation (for diagnostics)
public fun get_outcome_escrowed_stable<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    escrow.outcome_escrowed_stable[outcome_index]
}

/// Track protocol fees that have been collected from escrow.
/// Called by liquidity_interact::collect_protocol_fees after withdrawing from escrow.
/// This maintains the quantum invariant: escrow + collected_fees == supply + wrapped
///
/// RESTRICTED: Requires EscrowMutationAuth to prevent accounting corruption.
public fun track_collected_protocol_fees<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_fees: u64,
    stable_fees: u64,
    _auth: &EscrowMutationAuth,
) {
    escrow.collected_protocol_fees_asset = escrow.collected_protocol_fees_asset + asset_fees;
    escrow.collected_protocol_fees_stable = escrow.collected_protocol_fees_stable + stable_fees;
}

/// Get collected protocol fees (for diagnostics)
public fun get_collected_protocol_fees<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (u64, u64) {
    (escrow.collected_protocol_fees_asset, escrow.collected_protocol_fees_stable)
}

/// Package-internal helper for withdrawing asset balance.
/// Called by internal functions like lp_withdraw_quantum and finish_recombine_asset_progress,
/// and by conditional_balance.move for within-package operations.
public(package) fun withdraw_asset_balance_pkg<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // Explicit balance check for better error messages
    assert!(escrow.escrowed_asset.value() >= amount, ENotEnoughLiquidity);
    let balance = escrow.escrowed_asset.split(amount);
    coin::from_balance(balance, ctx)
}

/// Package-internal helper for withdrawing stable balance.
/// Called by internal functions like lp_withdraw_quantum and finish_recombine_stable_progress,
/// and by conditional_balance.move for within-package operations.
public(package) fun withdraw_stable_balance_pkg<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<StableType> {
    // Explicit balance check for better error messages
    assert!(escrow.escrowed_stable.value() >= amount, ENotEnoughLiquidity);
    let balance = escrow.escrowed_stable.split(amount);
    coin::from_balance(balance, ctx)
}

/// Withdraw asset balance from escrow (for external use)
///
/// RESTRICTED: Requires EscrowMutationAuth to enforce atomic burn+withdraw.
/// Direct withdrawal without burning would violate quantum invariant.
public fun withdraw_asset_balance<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
    _auth: &EscrowMutationAuth,
): Coin<AssetType> {
    withdraw_asset_balance_pkg(escrow, amount, ctx)
}

/// Withdraw stable balance from escrow (for external use)
///
/// RESTRICTED: Requires EscrowMutationAuth to enforce atomic burn+withdraw.
/// Direct withdrawal without burning would violate quantum invariant.
public fun withdraw_stable_balance<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
    _auth: &EscrowMutationAuth,
): Coin<StableType> {
    withdraw_stable_balance_pkg(escrow, amount, ctx)
}

// === Invariant Validation ===
//
// QUANTUM LIQUIDITY INVARIANT (with per-outcome escrow allocations):
//
// The quantum model uses per-outcome escrow allocations to track type conversions.
// This allows swaps to convert between types without breaking the invariant.
//
// During active proposal (not finalized):
// - outcome_escrowed_asset[i] == asset_supplies[i] + wrapped_asset[i] (for ALL outcomes)
// - outcome_escrowed_stable[i] == stable_supplies[i] + wrapped_stable[i] (for ALL outcomes)
//
// This per-outcome invariant is maintained by:
// - Quantum deposits: increment allocations for all outcomes
// - Quantum withdrawals: decrement allocations for all outcomes
// - Swaps: convert between types within an outcome (stable→asset or asset→stable)
//
// After finalization:
// - Same per-outcome invariant for winning outcome only
// - Escrow must be solvent per token type (asset backs asset claims, stable backs stable claims)
// - No cross-type backing between asset and stable claims
//
// ACCOUNTING INVARIANT (pre-trading only, checked at proposal start):
// - lp_deposited_asset + lp_deposited_stable + user_deposited_asset + user_deposited_stable
//   <= escrow_asset + escrow_stable (combined, using u128 to avoid overflow)
// - After swaps/arbitrage this diverges by design; quantum invariant provides solvency.

const EAccountingInvariantViolation: u64 = 200;
const EQuantumInvariantViolation: u64 = 201;
const ESolvencyViolation: u64 = 202;

/// Validate that tracked deposits don't exceed escrow balance.
/// ONLY valid pre-trading (called by lp_deposit_quantum at proposal start).
/// After swaps/arbitrage, per-type trackers legitimately diverge from escrow composition
/// due to cross-type conversions. Post-trading solvency is enforced by assert_quantum_invariant.
/// Aborts with EAccountingInvariantViolation if invariant is violated.
public fun assert_accounting_invariant<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let escrow_asset = escrow.escrowed_asset.value();
    let escrow_stable = escrow.escrowed_stable.value();

    // LP deposits must not exceed escrow balance
    assert!(escrow.lp_deposited_asset <= escrow_asset, EAccountingInvariantViolation);
    assert!(escrow.lp_deposited_stable <= escrow_stable, EAccountingInvariantViolation);

    // Total tracked (LP + user) should fit within escrow
    // user_deposited_* are intent-level counters (deposit/withdraw provenance), not hard
    // liabilities by type. Swaps change claim composition, so we keep this as a combined
    // sanity check and enforce strict per-type solvency in assert_quantum_invariant.
    let total_escrow = (escrow_asset as u128) + (escrow_stable as u128);
    let total_tracked =
        (escrow.lp_deposited_asset as u128) +
        (escrow.lp_deposited_stable as u128) +
        (escrow.user_deposited_asset as u128) +
        (escrow.user_deposited_stable as u128);
    assert!(total_tracked <= total_escrow, EAccountingInvariantViolation);
}

/// Validate the quantum liquidity invariant using per-outcome escrow allocations.
///
/// QUANTUM MODEL: Each outcome tracks its own escrow allocation that adjusts with swaps.
/// This allows type conversions (stable↔asset) without breaking the invariant.
///
/// - During active proposal: outcome_escrowed[i] == supply[i] + wrapped[i] for EACH outcome
///   Each outcome's allocation independently matches its circulation.
/// - After finalization: same check for WINNING outcome, plus strict per-type solvency
///   (losing outcomes may have mismatched allocations after partial burns, which is fine)
///
/// The key insight: swaps convert between types within an outcome, so we track
/// per-outcome allocations that update together with circulation.
///
/// SOLVENCY: Escrow must cover winning allocation for EACH token type independently.
/// Asset claims are backed by asset escrow, stable claims are backed by stable escrow.
///
/// Aborts with EQuantumInvariantViolation if invariant is violated.
public fun assert_quantum_invariant<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let escrow_asset = escrow.escrowed_asset.value();
    let escrow_stable = escrow.escrowed_stable.value();

    if (market_state::is_finalized(&escrow.market_state)) {
        // After finalization: only check winning outcome
        let winning_outcome = market_state::get_winning_outcome(&escrow.market_state);

        // Get circulation for winning outcome
        let asset_supply = escrow.asset_supplies[winning_outcome];
        let stable_supply = escrow.stable_supplies[winning_outcome];
        let wrapped_asset = escrow.wrapped_asset_balances[winning_outcome];
        let wrapped_stable = escrow.wrapped_stable_balances[winning_outcome];

        let circulating_asset = asset_supply + wrapped_asset;
        let circulating_stable = stable_supply + wrapped_stable;

        // Get per-outcome allocations
        let outcome_asset_alloc = escrow.outcome_escrowed_asset[winning_outcome];
        let outcome_stable_alloc = escrow.outcome_escrowed_stable[winning_outcome];

        // Per-outcome invariant: allocation == circulation
        assert!(outcome_asset_alloc == circulating_asset, EQuantumInvariantViolation);
        assert!(outcome_stable_alloc == circulating_stable, EQuantumInvariantViolation);

        // Per-type solvency: escrow must hold enough of EACH token type to cover
        // user claims (outcome allocation minus LP/pool claim).
        // User swaps (track_swap) shift outcome_escrowed between types without touching
        // pool_claim. System swaps (track_system_swap, used by arbitrage) shift both OE
        // and pool_claim proportionally. In both cases:
        // user_claim = outcome_escrowed - pool_claim correctly reflects what users need.
        let pool_asset = escrow.pool_claim_asset[winning_outcome];
        let pool_stable = escrow.pool_claim_stable[winning_outcome];
        // Saturating subtraction: swaps can shift outcome_escrowed between types,
        // so outcome_alloc for a type CAN be less than pool_claim for that type.
        // When that happens, user_claim is 0 (all allocation belongs to LP/pool).
        let user_claim_asset = if (outcome_asset_alloc > pool_asset) {
            outcome_asset_alloc - pool_asset
        } else { 0 };
        let user_claim_stable = if (outcome_stable_alloc > pool_stable) {
            outcome_stable_alloc - pool_stable
        } else { 0 };
        assert!(escrow_asset >= user_claim_asset, ESolvencyViolation);
        assert!(escrow_stable >= user_claim_stable, ESolvencyViolation);
    } else {
        // During active proposal: strict per-outcome equality for ALL outcomes
        // Each outcome's allocation must match its circulation
        let mut i = 0;
        while (i < escrow.outcome_count) {
            // Get circulation for this outcome
            let asset_supply = escrow.asset_supplies[i];
            let stable_supply = escrow.stable_supplies[i];
            let wrapped_asset = escrow.wrapped_asset_balances[i];
            let wrapped_stable = escrow.wrapped_stable_balances[i];

            let circulating_asset = asset_supply + wrapped_asset;
            let circulating_stable = stable_supply + wrapped_stable;

            // Get per-outcome allocations
            let outcome_asset_alloc = escrow.outcome_escrowed_asset[i];
            let outcome_stable_alloc = escrow.outcome_escrowed_stable[i];

            // Per-outcome invariant: allocation == circulation
            assert!(outcome_asset_alloc == circulating_asset, EQuantumInvariantViolation);
            assert!(outcome_stable_alloc == circulating_stable, EQuantumInvariantViolation);

            i = i + 1;
        };
    };
}

/// Validate both accounting and quantum invariants
/// Use this for comprehensive invariant checking
public fun assert_all_invariants<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    assert_accounting_invariant(escrow);
    assert_quantum_invariant(escrow);
}

/// Check if escrow has sufficient balance for all tracked deposits
/// Returns (has_sufficient_asset, has_sufficient_stable)
/// Use this for diagnostics - doesn't abort
public fun check_balance_sufficiency<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (bool, bool) {
    let escrow_asset = escrow.escrowed_asset.value();
    let escrow_stable = escrow.escrowed_stable.value();

    // Check if escrow can cover LP backing
    let asset_ok = escrow.lp_deposited_asset <= escrow_asset;
    let stable_ok = escrow.lp_deposited_stable <= escrow_stable;

    (asset_ok, stable_ok)
}

/// Get all tracking values for debugging/diagnostics
/// Returns (escrow_asset, escrow_stable, lp_asset, lp_stable, user_asset, user_stable)
public fun get_all_tracking<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (u64, u64, u64, u64, u64, u64) {
    (
        escrow.escrowed_asset.value(),
        escrow.escrowed_stable.value(),
        escrow.lp_deposited_asset,
        escrow.lp_deposited_stable,
        escrow.user_deposited_asset,
        escrow.user_deposited_stable,
    )
}

// === Complete Set Operations (Split/Recombine) ===
// Uses PTB hot potato pattern - see TYPE_PARAMETER_EXPLOSION_PROBLEM.md

/// Progress tracker for splitting a spot asset coin into a complete set of conditional asset coins.
/// This struct MUST be fully consumed via `finish_split_asset_progress` to preserve the quantum invariant.
/// NO DROP ABILITY: Enforces hot potato pattern - caller must complete all steps.
public struct SplitAssetProgress<phantom AssetType, phantom StableType> {
    market_id: ID,
    amount: u64,
    outcome_count: u64,
    next_outcome: u64,
}

/// Progress tracker for splitting a spot stable coin into a complete set of conditional stable coins.
/// NO DROP ABILITY: Enforces hot potato pattern - caller must complete all steps.
public struct SplitStableProgress<phantom AssetType, phantom StableType> {
    market_id: ID,
    amount: u64,
    outcome_count: u64,
    next_outcome: u64,
}

/// Progress tracker for recombining conditional asset coins back into a spot asset coin.
/// All outcomes must be processed sequentially from 0 → outcome_count - 1.
/// NO DROP ABILITY: Enforces hot potato pattern - caller must complete all steps.
public struct RecombineAssetProgress<phantom AssetType, phantom StableType> {
    market_id: ID,
    amount: u64,
    outcome_count: u64,
    next_outcome: u64,
}

/// Progress tracker for recombining conditional stable coins back into a spot stable coin.
/// NO DROP ABILITY: Enforces hot potato pattern - caller must complete all steps.
public struct RecombineStableProgress<phantom AssetType, phantom StableType> {
    market_id: ID,
    amount: u64,
    outcome_count: u64,
    next_outcome: u64,
}

/// Begin splitting a spot asset coin into a complete set of conditional assets.
/// Returns a progress object that must be passed through `split_asset_progress_step`
/// for each outcome, then finalized with `finish_split_asset_progress`.
public fun start_split_asset_progress<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_asset: Coin<AssetType>,
): SplitAssetProgress<AssetType, StableType> {
    let amount = spot_asset.value();
    assert!(amount > 0, EZeroAmount);

    let outcome_count = caps_registered_count(escrow);
    assert!(outcome_count > 0, ESuppliesNotInitialized);

    let asset_balance = coin::into_balance(spot_asset);
    escrow.escrowed_asset.join(asset_balance);

    // Track as user backing
    escrow.user_deposited_asset = escrow.user_deposited_asset + amount;

    SplitAssetProgress {
        market_id: market_state_id(escrow),
        amount,
        outcome_count,
        next_outcome: 0,
    }
}

/// Mint the next conditional asset coin in the sequence.
/// Caller is responsible for transferring or otherwise handling the returned coin.
public fun split_asset_progress_step<AssetType, StableType, ConditionalCoinType>(
    mut progress: SplitAssetProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    ctx: &mut TxContext,
): (SplitAssetProgress<AssetType, StableType>, Coin<ConditionalCoinType>) {
    assert!(market_state_id(escrow) == progress.market_id, EWrongMarket);

    assert!(progress.next_outcome < progress.outcome_count, EOutcomeOutOfBounds);
    assert!(outcome_index == progress.next_outcome, EIncorrectSequence);

    // Track per-outcome allocation (backing for this outcome's circulation)
    let alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
    *alloc = *alloc + progress.amount;

    let coin = mint_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        progress.amount,
        ctx,
    );

    progress.next_outcome = progress.next_outcome + 1;

    (progress, coin)
}

/// Ensure the split operation covered all outcomes. Must be called exactly once per progress object.
/// Enforces quantum invariant after completion.
public fun finish_split_asset_progress<AssetType, StableType>(
    progress: SplitAssetProgress<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let SplitAssetProgress { market_id, amount: _, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
    assert!(market_state_id(escrow) == market_id, EWrongMarket);

    // Enforce quantum invariant after complete split
    assert_quantum_invariant(escrow);
}

/// Begin splitting a spot stable coin into a complete set of conditional stables.
public fun start_split_stable_progress<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_stable: Coin<StableType>,
): SplitStableProgress<AssetType, StableType> {
    let amount = spot_stable.value();
    assert!(amount > 0, EZeroAmount);

    let outcome_count = caps_registered_count(escrow);
    assert!(outcome_count > 0, ESuppliesNotInitialized);

    let stable_balance = coin::into_balance(spot_stable);
    escrow.escrowed_stable.join(stable_balance);

    // Track as user backing
    escrow.user_deposited_stable = escrow.user_deposited_stable + amount;

    SplitStableProgress {
        market_id: market_state_id(escrow),
        amount,
        outcome_count,
        next_outcome: 0,
    }
}

/// Mint the next conditional stable coin in the sequence.
public fun split_stable_progress_step<AssetType, StableType, ConditionalCoinType>(
    mut progress: SplitStableProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    ctx: &mut TxContext,
): (SplitStableProgress<AssetType, StableType>, Coin<ConditionalCoinType>) {
    assert!(market_state_id(escrow) == progress.market_id, EWrongMarket);

    assert!(progress.next_outcome < progress.outcome_count, EOutcomeOutOfBounds);
    assert!(outcome_index == progress.next_outcome, EIncorrectSequence);

    // Track per-outcome allocation (backing for this outcome's circulation)
    let alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
    *alloc = *alloc + progress.amount;

    let coin = mint_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        progress.amount,
        ctx,
    );

    progress.next_outcome = progress.next_outcome + 1;

    (progress, coin)
}

/// Ensure the stable split operation covered all outcomes.
/// Enforces quantum invariant after completion.
public fun finish_split_stable_progress<AssetType, StableType>(
    progress: SplitStableProgress<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let SplitStableProgress { market_id, amount: _, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
    assert!(market_state_id(escrow) == market_id, EWrongMarket);

    // Enforce quantum invariant after complete split
    assert_quantum_invariant(escrow);
}

/// Begin recombining conditional asset coins into a spot asset coin.
/// Consumes and burns the first coin (must be outcome index 0).
public fun start_recombine_asset_progress<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
): RecombineAssetProgress<AssetType, StableType> {
    assert!(outcome_index == 0, EIncorrectSequence);

    let outcome_count = caps_registered_count(escrow);
    assert!(outcome_count > 0, ESuppliesNotInitialized);
    assert!(outcome_index < outcome_count, EOutcomeOutOfBounds);

    let amount = coin.value();
    assert!(amount > 0, EZeroAmount);

    burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        coin,
    );

    // Track per-outcome allocation (backing is being removed)
    let alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
    assert!(*alloc >= amount, EAllocationUnderflow);
    *alloc = *alloc - amount;

    RecombineAssetProgress {
        market_id: market_state_id(escrow),
        amount,
        outcome_count,
        next_outcome: 1,
    }
}

/// Burn the next conditional asset coin in the recombination sequence.
public fun recombine_asset_progress_step<AssetType, StableType, ConditionalCoinType>(
    mut progress: RecombineAssetProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
): RecombineAssetProgress<AssetType, StableType> {
    assert!(market_state_id(escrow) == progress.market_id, EWrongMarket);

    assert!(progress.next_outcome < progress.outcome_count, EOutcomeOutOfBounds);
    assert!(outcome_index == progress.next_outcome, EIncorrectSequence);

    let amount = coin.value();
    assert!(amount == progress.amount, EInsufficientBalance);

    burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        coin,
    );

    // Track per-outcome allocation (backing is being removed)
    let alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
    assert!(*alloc >= progress.amount, EAllocationUnderflow);
    *alloc = *alloc - progress.amount;

    progress.next_outcome = progress.next_outcome + 1;
    progress
}

/// Finish recombination and withdraw the corresponding spot asset coin.
/// Enforces quantum invariant after completion.
public fun finish_recombine_asset_progress<AssetType, StableType>(
    progress: RecombineAssetProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let RecombineAssetProgress { market_id, amount, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
    assert!(market_state_id(escrow) == market_id, EWrongMarket);

    // Decrement user backing (saturating for cross-type swap scenarios)
    saturating_decrement_user_asset(escrow, amount);

    let coin = withdraw_asset_balance_pkg(escrow, amount, ctx);

    // Enforce quantum invariant after complete recombination
    assert_quantum_invariant(escrow);

    coin
}

/// Begin recombining conditional stable coins into spot stable.
public fun start_recombine_stable_progress<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
): RecombineStableProgress<AssetType, StableType> {
    assert!(outcome_index == 0, EIncorrectSequence);

    let outcome_count = caps_registered_count(escrow);
    assert!(outcome_count > 0, ESuppliesNotInitialized);
    assert!(outcome_index < outcome_count, EOutcomeOutOfBounds);

    let amount = coin.value();
    assert!(amount > 0, EZeroAmount);

    burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        coin,
    );

    // Track per-outcome allocation (backing is being removed)
    let alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
    assert!(*alloc >= amount, EAllocationUnderflow);
    *alloc = *alloc - amount;

    RecombineStableProgress {
        market_id: market_state_id(escrow),
        amount,
        outcome_count,
        next_outcome: 1,
    }
}

/// Burn the next conditional stable coin in the recombination sequence.
public fun recombine_stable_progress_step<AssetType, StableType, ConditionalCoinType>(
    mut progress: RecombineStableProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
): RecombineStableProgress<AssetType, StableType> {
    assert!(market_state_id(escrow) == progress.market_id, EWrongMarket);

    assert!(progress.next_outcome < progress.outcome_count, EOutcomeOutOfBounds);
    assert!(outcome_index == progress.next_outcome, EIncorrectSequence);

    let amount = coin.value();
    assert!(amount == progress.amount, EInsufficientBalance);

    burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        coin,
    );

    // Track per-outcome allocation (backing is being removed)
    let alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
    assert!(*alloc >= progress.amount, EAllocationUnderflow);
    *alloc = *alloc - progress.amount;

    progress.next_outcome = progress.next_outcome + 1;
    progress
}

/// Finish recombination and withdraw the corresponding spot stable coin.
/// Enforces quantum invariant after completion.
public fun finish_recombine_stable_progress<AssetType, StableType>(
    progress: RecombineStableProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
): Coin<StableType> {
    let RecombineStableProgress { market_id, amount, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
    assert!(market_state_id(escrow) == market_id, EWrongMarket);

    // Decrement user backing (saturating for cross-type swap scenarios)
    saturating_decrement_user_stable(escrow, amount);

    let coin = withdraw_stable_balance_pkg(escrow, amount, ctx);

    // Enforce quantum invariant after complete recombination
    assert_quantum_invariant(escrow);

    coin
}

// === Test Helpers ===

#[test_only]
/// Create a blank TreasuryCap for testing (zero supply, blank metadata)
/// This simulates getting a blank coin from the registry
public fun create_test_treasury_cap<CoinType: drop>(
    otw: CoinType,
    ctx: &mut TxContext,
): (TreasuryCap<CoinType>, CoinMetadata<CoinType>) {
    // Create coin with blank metadata
    let (treasury_cap, metadata) = coin::create_currency(
        otw,
        0, // decimals
        b"", // symbol (empty)
        b"", // name (empty)
        b"", // description (empty)
        option::none(), // icon_url (empty)
        ctx,
    );

    (treasury_cap, metadata)
}

#[test_only]
/// Create a test escrow with a real MarketState (not a mock)
/// This is a simplified helper that creates an actual TokenEscrow with sensible defaults
public fun create_test_escrow<AssetType, StableType>(
    outcome_count: u64,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    // Create a real MarketState using existing test infrastructure
    let market_state = futarchy_markets_primitives::market_state::create_for_testing(
        outcome_count,
        ctx,
    );

    // Create and return the TokenEscrow with the real MarketState
    new<AssetType, StableType>(market_state, ctx)
}

#[test_only]
/// Create a test escrow with outcome_count and fee_bps parameters
/// Alias for compatibility with test code that passes (num_outcomes, fee_bps, ctx)
public fun create_for_testing<AssetType, StableType>(
    outcome_count: u64,
    _fee_bps: u64, // Fee is configured in individual AMM pools, not escrow level
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    create_test_escrow<AssetType, StableType>(outcome_count, ctx)
}

#[test_only]
/// Create a test escrow with a provided MarketState
/// Useful when you need to customize the market state before creating the escrow
/// Also initializes supply, wrapped, and swap flow vectors for each outcome
public fun create_test_escrow_with_market_state<AssetType, StableType>(
    outcome_count: u64,
    market_state: MarketState,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    let mut escrow = new<AssetType, StableType>(market_state, ctx);

    // Initialize supply, wrapped, and per-outcome allocation vectors for each outcome
    let mut i = 0;
    while (i < outcome_count) {
        escrow.asset_supplies.push_back(0);
        escrow.stable_supplies.push_back(0);
        escrow.wrapped_asset_balances.push_back(0);
        escrow.wrapped_stable_balances.push_back(0);
        escrow.dust_created_asset.push_back(0);
        escrow.dust_created_stable.push_back(0);
        escrow.outcome_escrowed_asset.push_back(0);
        escrow.outcome_escrowed_stable.push_back(0);
        escrow.pool_claim_asset.push_back(0);
        escrow.pool_claim_stable.push_back(0);
        escrow.outcome_count = escrow.outcome_count + 1;
        i = i + 1;
    };

    escrow
}

#[test_only]
/// Destroy escrow for testing (with remaining balances)
/// Useful for cleaning up test state
public fun destroy_for_testing<AssetType, StableType>(escrow: TokenEscrow<AssetType, StableType>) {
    let TokenEscrow {
        id,
        market_state,
        escrowed_asset,
        escrowed_stable,
        outcome_count: _,
        lp_deposited_asset: _,
        lp_deposited_stable: _,
        user_deposited_asset: _,
        user_deposited_stable: _,
        asset_supplies: _,
        stable_supplies: _,
        wrapped_asset_balances: _,
        wrapped_stable_balances: _,
        dust_created_asset: _,
        dust_created_stable: _,
        collected_protocol_fees_asset: _,
        collected_protocol_fees_stable: _,
        outcome_escrowed_asset: _,
        outcome_escrowed_stable: _,
        pool_claim_asset: _,
        pool_claim_stable: _,
    } = escrow;

    // Destroy balances
    balance::destroy_for_testing(escrowed_asset);
    balance::destroy_for_testing(escrowed_stable);

    // Destroy market state
    futarchy_markets_primitives::market_state::destroy_for_testing(market_state);

    // Delete UID (TreasuryCaps in dynamic fields will be destroyed automatically)
    object::delete(id);
}

#[test_only]
/// Set wrapped balance for testing (to simulate wrapped coins without going through wrap flow)
/// Useful for unit testing unwrap functionality
/// Also updates escrowed allocation: new_escrowed = supply + amount
public fun set_wrapped_balance_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
) {
    if (is_asset) {
        let current = &mut escrow.wrapped_asset_balances[outcome_index];
        *current = amount;
        // Update escrowed to maintain invariant: escrowed = supply + wrapped
        let supply = escrow.asset_supplies[outcome_index];
        let alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
        *alloc = supply + amount;
    } else {
        let current = &mut escrow.wrapped_stable_balances[outcome_index];
        *current = amount;
        // Update escrowed to maintain invariant: escrowed = supply + wrapped
        let supply = escrow.stable_supplies[outcome_index];
        let alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
        *alloc = supply + amount;
    };
}

#[test_only]
/// Increment supply for a specific outcome (for testing setup).
/// Does NOT update escrowed - use this for swap simulations where
/// track_swap_* already handles escrowed changes, or when manually
/// setting escrowed separately.
public fun increment_supply_for_outcome<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
) {
    if (is_asset) {
        let supply = &mut escrow.asset_supplies[outcome_index];
        *supply = *supply + amount;
    } else {
        let supply = &mut escrow.stable_supplies[outcome_index];
        *supply = *supply + amount;
    };
}

#[test_only]
/// Set outcome_escrowed for testing (to simulate proper backing allocation)
/// Useful for unit tests that use raw mint functions without proper atomic operations
public fun set_outcome_escrowed_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
) {
    if (is_asset) {
        let alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
        *alloc = amount;
    } else {
        let alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
        *alloc = amount;
    };
}

#[test_only]
/// Increment escrowed allocation for a specific outcome (for testing setup).
/// Use this to simulate deposit operations that increase backing.
/// Paired with increment_wrapped_balance, this simulates: deposit → mint → wrap.
public fun increment_escrowed_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
) {
    if (is_asset) {
        let alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
        *alloc = *alloc + amount;
    } else {
        let alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
        *alloc = *alloc + amount;
    };
}

#[test_only]
/// Decrement supply for a specific outcome (for testing setup).
/// Does NOT update escrowed - use this for swap simulations where
/// track_swap_* already handles escrowed changes.
public fun decrement_supply_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
) {
    if (is_asset) {
        let supply = &mut escrow.asset_supplies[outcome_index];
        *supply = *supply - amount;
    } else {
        let supply = &mut escrow.stable_supplies[outcome_index];
        *supply = *supply - amount;
    };
}

#[test_only]
/// Set supply for a specific outcome (for testing - directly sets value)
/// Also updates escrowed allocation: new_escrowed = amount + wrapped
public fun set_supply_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
) {
    if (is_asset) {
        let supply = &mut escrow.asset_supplies[outcome_index];
        *supply = amount;
        // Update escrowed to maintain invariant: escrowed = supply + wrapped
        let wrapped = escrow.wrapped_asset_balances[outcome_index];
        let alloc = &mut escrow.outcome_escrowed_asset[outcome_index];
        *alloc = amount + wrapped;
    } else {
        let supply = &mut escrow.stable_supplies[outcome_index];
        *supply = amount;
        // Update escrowed to maintain invariant: escrowed = supply + wrapped
        let wrapped = escrow.wrapped_stable_balances[outcome_index];
        let alloc = &mut escrow.outcome_escrowed_stable[outcome_index];
        *alloc = amount + wrapped;
    };
}

#[test_only]
/// Deposit spot liquidity for testing (directly adds to escrow balances)
public fun deposit_spot_liquidity_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
) {
    let asset_coin = balance::create_for_testing<AssetType>(asset_amount);
    let stable_coin = balance::create_for_testing<StableType>(stable_amount);
    escrow.escrowed_asset.join(asset_coin);
    escrow.escrowed_stable.join(stable_coin);
}

#[test_only]
/// Set LP deposited amounts directly for testing invariant edge cases.
/// WARNING: This can create invalid states - use only for testing invariant failures.
public fun set_lp_deposited_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
) {
    escrow.lp_deposited_asset = asset_amount;
    escrow.lp_deposited_stable = stable_amount;
}

#[test_only]
/// Get LP deposited amounts for testing assertions.
public fun get_lp_deposited_for_testing<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (u64, u64) {
    (escrow.lp_deposited_asset, escrow.lp_deposited_stable)
}

#[test_only]
/// Set pool claim for a specific outcome (for testing).
/// Useful for simulating quantum split without going through the full flow.
public fun set_pool_claim_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    asset_amount: u64,
    stable_amount: u64,
) {
    let asset_claim = &mut escrow.pool_claim_asset[outcome_index];
    *asset_claim = asset_amount;
    let stable_claim = &mut escrow.pool_claim_stable[outcome_index];
    *stable_claim = stable_amount;
}
