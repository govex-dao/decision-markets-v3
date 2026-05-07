// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Core swap primitives (building blocks)
///
/// Internal library providing low-level swap functions used by other modules.
/// Users don't call this directly - use swap_entry.move instead.
module futarchy_markets_core::swap_core;

use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationAuth, EscrowMutationRegistry};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_balance;
use futarchy_markets_primitives::market_state;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::object::ID;

// === Witness for escrow mutation authorization ===
public struct EscrowMutationWitness has drop {}

/// Create auth for this package's escrow mutations
public(package) fun create_auth(registry: &EscrowMutationRegistry): EscrowMutationAuth {
    escrow_mutation_auth::create(registry, EscrowMutationWitness {})
}

// === Introduction ===
// Core swap functions for TreasuryCap-based conditional coins
// Swaps work by: burn input → update AMM reserves → mint output
//
// Hot potato pattern ensures session validation:
// 1. begin_swap_session() - creates SwapSession hot potato
// 2. swap_*() - validates session, performs swaps
// 3. finalize_swap_session() - consumes hot potato

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EInsufficientOutput: u64 = 5;
const ESessionMismatch: u64 = 6;
const EProposalMismatch: u64 = 7;
const EOutcomeIndexOverflow: u64 = 8; // outcome_idx > 255 would silently truncate
const EZeroOutput: u64 = 9; // AMM returned zero output, would cause state drift

// === Constants ===
// Swap validation now uses market_state::assert_swaps_allowed()

// === Structs ===

/// Hot potato that enforces session finalization
/// No abilities = must be consumed by finalize_swap_session()
public struct SwapSession {
    market_id: ID, // Track which market this session is for
}

// === Session Management ===

/// Begin a swap session (creates hot potato)
/// Must be called before any swaps in a PTB
///
/// Creates a hot potato that must be consumed by finalize_swap_session().
/// This ensures metrics are updated exactly once after all swaps complete.
public fun begin_swap_session<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): SwapSession {
    let market_state = coin_escrow::get_market_state(escrow);
    let market_id = futarchy_markets_primitives::market_state::market_id(market_state);
    SwapSession {
        market_id,
    }
}

/// Finalize swap session (consumes hot potato)
/// Must be called at end of PTB to consume the SwapSession
public fun finalize_swap_session<AssetType, StableType>(
    session: SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    escrow_registry: &EscrowMutationRegistry,
) {
    let SwapSession { market_id } = session;

    // Validate session matches this market
    let auth = create_auth(escrow_registry);
    let market_state = coin_escrow::get_market_state_mut(escrow, &auth);
    let escrow_market_id = futarchy_markets_primitives::market_state::market_id(market_state);
    assert!(market_id == escrow_market_id, ESessionMismatch);
}

// === Core Swap Functions ===

/// Swap conditional asset coins to conditional stable coins
/// Uses TreasuryCap system: burn input → AMM calculation → mint output
/// Requires valid SwapSession to ensure metrics are updated at end of PTB
public fun swap_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    session: &SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_in: Coin<AssetConditionalCoin>,
    min_amount_out: u64,
    escrow_registry: &EscrowMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableConditionalCoin> {
    // Prevent silent truncation when casting to u8
    assert!(outcome_idx <= 255, EOutcomeIndexOverflow);

    let amount_in = asset_in.value();

    // Step 1: Validate session, market state, and outcome
    {
        let ms = coin_escrow::get_market_state(escrow);
        let market_id = market_state::market_id(ms);
        assert!(session.market_id == market_id, ESessionMismatch);
        // Validate swaps are allowed (trading OR execution window, before deadline)
        market_state::assert_swaps_allowed(ms, clock);
        // Validate outcome exists
        assert!(outcome_idx < market_state::outcome_count(ms), EInvalidOutcome);
    };

    // Create auth for escrow mutations
    let auth = create_auth(escrow_registry);

    // Step 2: Burn input conditional asset coins
    coin_escrow::burn_conditional<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        true, // is_asset = true
        asset_in,
        &auth,
    );

    // Step 3: Calculate swap through AMM and update price leaderboard
    let amount_out = {
        let ms = coin_escrow::get_market_state_mut(escrow, &auth);
        let market_id = market_state::market_id(ms);

        // Execute swap
        let pool = market_state::get_pool_mut_by_outcome(
            ms,
            outcome_idx,
            &auth,
        );
        let amount_out = pool.swap_asset_to_stable(
            market_id,
            amount_in,
            min_amount_out,
            clock,
            ctx,
        );

        amount_out
    };

    assert!(amount_out >= min_amount_out, EInsufficientOutput);
    // Prevent state drift: if AMM returns 0, we'd burn input but mint 0 output
    assert!(amount_out > 0, EZeroOutput);

    // Step 4: Mint output conditional stable coins
    let stable_out = coin_escrow::mint_conditional<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        false, // is_asset = false
        amount_out,
        ctx,
        &auth,
    );

    // CRITICAL: keep per-outcome allocation in sync with supply changes.
    // Typed swap path burns one type and mints the other directly.
    coin_escrow::track_swap_asset_to_stable(escrow, outcome_idx, amount_in, amount_out, &auth);

    stable_out
}

/// Swap conditional stable coins to conditional asset coins
/// Requires valid SwapSession to ensure metrics are updated at end of PTB
public fun swap_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    session: &SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    stable_in: Coin<StableConditionalCoin>,
    min_amount_out: u64,
    escrow_registry: &EscrowMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetConditionalCoin> {
    // Prevent silent truncation when casting to u8
    assert!(outcome_idx <= 255, EOutcomeIndexOverflow);

    let amount_in = stable_in.value();

    // Step 1: Validate session, market state, and outcome
    {
        let ms = coin_escrow::get_market_state(escrow);
        let market_id = market_state::market_id(ms);
        assert!(session.market_id == market_id, ESessionMismatch);
        // Validate swaps are allowed (trading OR execution window, before deadline)
        market_state::assert_swaps_allowed(ms, clock);
        // Validate outcome exists
        assert!(outcome_idx < market_state::outcome_count(ms), EInvalidOutcome);
    };

    // Create auth for escrow mutations
    let auth = create_auth(escrow_registry);

    // Step 2: Burn input conditional stable coins
    coin_escrow::burn_conditional<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        false, // is_asset = false
        stable_in,
        &auth,
    );

    // Step 3: Calculate swap through AMM and update price leaderboard
    let amount_out = {
        let ms = coin_escrow::get_market_state_mut(escrow, &auth);
        let market_id = market_state::market_id(ms);

        // Execute swap
        let pool = market_state::get_pool_mut_by_outcome(
            ms,
            outcome_idx,
            &auth,
        );
        let amount_out = pool.swap_stable_to_asset(
            market_id,
            amount_in,
            min_amount_out,
            clock,
            ctx,
        );

        amount_out
    };

    assert!(amount_out >= min_amount_out, EInsufficientOutput);
    // Prevent state drift: if AMM returns 0, we'd burn input but mint 0 output
    assert!(amount_out > 0, EZeroOutput);

    // Step 4: Mint output conditional asset coins
    let asset_out = coin_escrow::mint_conditional<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        true, // is_asset = true
        amount_out,
        ctx,
        &auth,
    );

    // CRITICAL: keep per-outcome allocation in sync with supply changes.
    // Typed swap path burns one type and mints the other directly.
    coin_escrow::track_swap_stable_to_asset(escrow, outcome_idx, amount_in, amount_out, &auth);

    asset_out
}

// === CONDITIONAL TRADER CONSTRAINTS ===
//
// Conditional traders CANNOT perform cross-market arbitrage without complete sets.
// The quantum liquidity model prevents burning tokens from one outcome and withdrawing
// spot tokens, as this would break the invariant: spot_balance == Cond0_supply == Cond1_supply
//
// Available operations for conditional traders:
// 1. Swap within same outcome: Cond0_Stable ↔ Cond0_Asset (using swap_stable_to_asset/swap_asset_to_stable)
// 2. Acquire complete sets: Get tokens from ALL outcomes → burn complete set → withdraw spot
//
// Cross-market routing requires spot tokens, which conditional traders cannot obtain
// without first acquiring a complete set (tokens from ALL outcomes).
//
// See arbitrage_executor.move for spot trader arbitrage pattern with complete sets.

// === BALANCE-BASED SWAP FUNCTIONS ===
//
// These functions work with ConditionalMarketBalance instead of typed coins.
// This ELIMINATES type explosion - works for ANY outcome count without N type parameters.
//
// Key benefits:
// 1. No type parameters for conditional coins (just AssetType, StableType)
// 2. Works for 2, 3, 4, 5, 200 outcomes without separate modules
// 3. Same swap logic, different input/output handling
//
// Used by: arbitrage with balance tracking, unified swap entry functions

/// Swap from balance: conditional asset → conditional stable
///
/// Works for ANY outcome count by operating on balance indices.
/// No conditional coin type parameters needed!
///
/// # Arguments
/// * `balance` - Balance object to update (decreases asset, increases stable)
/// * `outcome_idx` - Which outcome to swap in (0, 1, 2, ...)
/// * `amount_in` - Asset amount to swap
/// * `min_amount_out` - Minimum stable amount to receive (slippage protection)
///
/// # Example
/// ```move
/// // Swap 1000 asset → stable in outcome 0 (works for 2, 3, 4, ... outcomes!)
/// swap_balance_asset_to_stable(
///     &session, &mut escrow, &mut balance,
///     0, 1000, 950, &clock, ctx
/// );
/// // Balance updated: outcome 0 asset -1000, outcome 0 stable +~950
/// ```
public fun swap_balance_asset_to_stable<AssetType, StableType>(
    session: &SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    balance: &mut conditional_balance::ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    amount_in: u64,
    min_amount_out: u64,
    escrow_registry: &EscrowMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    // Create auth for escrow mutations
    let auth = create_auth(escrow_registry);

    // Get market state and validate everything from it
    let market_state = coin_escrow::get_market_state_mut(escrow, &auth);
    let market_id = futarchy_markets_primitives::market_state::market_id(market_state);

    // Validate swaps are allowed (trading OR execution window)
    futarchy_markets_primitives::market_state::assert_swaps_allowed(market_state, clock);

    // Validate session matches market
    assert!(session.market_id == market_id, ESessionMismatch);

    // CRITICAL SECURITY: Validate balance belongs to this market
    // Prevents exploiting price differences between markets
    assert!(conditional_balance::market_id(balance) == market_id, EProposalMismatch);

    // Validate outcome exists in market
    let market_outcome_count = futarchy_markets_primitives::market_state::outcome_count(
        market_state,
    );
    assert!((outcome_idx as u64) < market_outcome_count, EInvalidOutcome);

    // Subtract from asset balance (input)
    // Note: sub_from_balance validates balance sufficiency internally
    conditional_balance::sub_from_balance(balance, outcome_idx, true, amount_in, &auth);

    // Calculate swap through AMM (reuse market_state and market_id)
    let pool = futarchy_markets_primitives::market_state::get_pool_mut_by_outcome(
        market_state,
        (outcome_idx as u64),
        &auth,
    );
    let amount_out = pool.swap_asset_to_stable(
        market_id,
        amount_in,
        min_amount_out,
        clock,
        ctx,
    );

    assert!(amount_out >= min_amount_out, EInsufficientOutput);
    // Prevent state drift: if AMM returns 0, we'd decrement input but increment 0 output
    assert!(amount_out > 0, EZeroOutput);

    // Add to stable balance (output)
    conditional_balance::add_to_balance(balance, outcome_idx, false, amount_out, &auth);

    // CRITICAL: Update wrapped balance tracking to maintain quantum invariant
    // When swapping in balance space, the wrapped amounts must transfer between asset/stable
    // This ensures unwrap_to_coin can properly decrement the output type's wrapped balance
    coin_escrow::decrement_wrapped_balance(escrow, (outcome_idx as u64), true, amount_in, &auth);
    coin_escrow::increment_wrapped_balance(escrow, (outcome_idx as u64), false, amount_out, &auth);

    // CRITICAL: Update per-outcome allocation to match wrapped balance changes
    // Invariant: outcome_escrowed[i] == supply[i] + wrapped[i]
    // Swap converts allocation between types: asset allocation decreases, stable allocation increases
    coin_escrow::track_swap_asset_to_stable(escrow, (outcome_idx as u64), amount_in, amount_out, &auth);

    amount_out
}

/// Swap from balance: conditional stable → conditional asset
///
/// Works for ANY outcome count by operating on balance indices.
/// No conditional coin type parameters needed!
///
/// # Arguments
/// * `balance` - Balance object to update (decreases stable, increases asset)
/// * `outcome_idx` - Which outcome to swap in (0, 1, 2, ...)
/// * `amount_in` - Stable amount to swap
/// * `min_amount_out` - Minimum asset amount to receive (slippage protection)
///
/// # Example
/// ```move
/// // Swap 1000 stable → asset in outcome 1 (works for 2, 3, 4, ... outcomes!)
/// swap_balance_stable_to_asset(
///     &session, &mut escrow, &mut balance,
///     1, 1000, 950, &clock, ctx
/// );
/// // Balance updated: outcome 1 stable -1000, outcome 1 asset +~950
/// ```
public fun swap_balance_stable_to_asset<AssetType, StableType>(
    session: &SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    balance: &mut conditional_balance::ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    amount_in: u64,
    min_amount_out: u64,
    escrow_registry: &EscrowMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    // Create auth for escrow mutations
    let auth = create_auth(escrow_registry);

    // Get market state and validate everything from it
    let market_state = coin_escrow::get_market_state_mut(escrow, &auth);
    let market_id = futarchy_markets_primitives::market_state::market_id(market_state);

    // Validate swaps are allowed (trading OR execution window)
    futarchy_markets_primitives::market_state::assert_swaps_allowed(market_state, clock);

    // Validate session matches market
    assert!(session.market_id == market_id, ESessionMismatch);

    // CRITICAL SECURITY: Validate balance belongs to this market
    // Prevents exploiting price differences between markets
    assert!(conditional_balance::market_id(balance) == market_id, EProposalMismatch);

    // Validate outcome exists in market
    let market_outcome_count = futarchy_markets_primitives::market_state::outcome_count(
        market_state,
    );
    assert!((outcome_idx as u64) < market_outcome_count, EInvalidOutcome);

    // Subtract from stable balance (input)
    // Note: sub_from_balance validates balance sufficiency internally
    conditional_balance::sub_from_balance(balance, outcome_idx, false, amount_in, &auth);

    // Calculate swap through AMM (reuse market_state and market_id)
    let pool = futarchy_markets_primitives::market_state::get_pool_mut_by_outcome(
        market_state,
        (outcome_idx as u64),
        &auth,
    );
    let amount_out = pool.swap_stable_to_asset(
        market_id,
        amount_in,
        min_amount_out,
        clock,
        ctx,
    );

    assert!(amount_out >= min_amount_out, EInsufficientOutput);
    // Prevent state drift: if AMM returns 0, we'd decrement input but increment 0 output
    assert!(amount_out > 0, EZeroOutput);

    // Add to asset balance (output)
    conditional_balance::add_to_balance(balance, outcome_idx, true, amount_out, &auth);

    // CRITICAL: Update wrapped balance tracking to maintain quantum invariant
    // When swapping in balance space, the wrapped amounts must transfer between asset/stable
    // This ensures unwrap_to_coin can properly decrement the output type's wrapped balance
    coin_escrow::decrement_wrapped_balance(escrow, (outcome_idx as u64), false, amount_in, &auth);
    coin_escrow::increment_wrapped_balance(escrow, (outcome_idx as u64), true, amount_out, &auth);

    // CRITICAL: Update per-outcome allocation to match wrapped balance changes
    // Invariant: outcome_escrowed[i] == supply[i] + wrapped[i]
    // Swap converts allocation between types: stable allocation decreases, asset allocation increases
    coin_escrow::track_swap_stable_to_asset(escrow, (outcome_idx as u64), amount_in, amount_out, &auth);

    amount_out
}

// === Test Helpers ===

#[test_only]
/// Create a test swap session for testing
public fun create_test_swap_session(market_id: ID): SwapSession {
    SwapSession { market_id }
}

#[test_only]
/// Destroy a swap session for testing
public fun destroy_test_swap_session(session: SwapSession) {
    let SwapSession { market_id: _ } = session;
}
