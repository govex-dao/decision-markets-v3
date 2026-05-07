// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// User-facing swap API with optimal routing
///
/// This is where users enter the system. Provides entry functions that:
/// - Calculate optimal routing (direct vs through conditionals)
/// - Execute optimal path to maximize user output
/// - Route trader-owned arbitrage through conditionals when it beats direct spot
///
/// Spot swap entrypoints choose between direct spot execution and a conditional route
/// before finalizing the user's output.
///
/// **Incomplete Set Handling:**
/// All spot swaps transfer incomplete sets (ConditionalMarketBalance) directly to recipient.
/// Balance object has Display metadata so shows as basic NFT in wallets.
/// User owns the balance immediately and can redeem after proposal resolves.
/// No wrapper, no shared registry, no crankers - users control their own positions.
///
/// **Entry Functions:**
///
/// **Spot swaps (aggregators/DCA compatible):**
/// 1. swap_spot_stable_to_asset - Returns profit coins + balance object to recipient
/// 2. swap_spot_asset_to_stable - Returns profit coins + balance object to recipient
///
/// Output coins and balance objects transferred directly to recipient (shows as NFT in wallet).
/// Supports DCA bots calling on behalf of users.

module futarchy_markets_operations::swap_entry;

use futarchy_core::escrow_mutation_auth::EscrowMutationRegistry;
use futarchy_core::market_state_mutation_auth::MarketStateMutationRegistry;
use futarchy_markets_core::arbitrage;
use futarchy_markets_core::arbitrage_math;
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationRegistry};
use futarchy_markets_core::swap_core;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_balance::{Self, ConditionalMarketBalance};
use futarchy_markets_primitives::market_state;
use futarchy_markets_primitives::PCW_TWAP_oracle;
use futarchy_proposal::proposal::{Self, Proposal};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;

// === Events ===

/// Emitted when a user swaps in the spot pool
public struct SpotSwap has copy, drop {
    pool_id: ID,
    is_buy: bool, // true = stable→asset (buying asset), false = asset→stable (selling asset)
    amount_in: u64,
    amount_out: u64,
    sender: address,
    recipient: address,
    asset_reserve: u64,
    stable_reserve: u64,
}

// === Errors ===
const EZeroAmount: u64 = 0;
const EProposalEscrowMismatch: u64 = 1;
const EBatchEscrowMismatch: u64 = 2;
const EUnexpectedNoneBalance: u64 = 3;
const EMinAmountNotMet: u64 = 4;
const EReceiptPoolMismatch: u64 = 6;
const EReceiptEscrowMismatch: u64 = 7;
const EBalanceMarketMismatch: u64 = 8;

/// Witness type for creating SpotPoolMutationAuth.
public struct SpotPoolMutationWitness has drop {}

/// Hot potato receipt binding an extracted escrow to its pool.
/// NO abilities = MUST be consumed in the same PTB via `store_escrow_after_batch`.
/// Prevents escrow theft (attacker extracting and transferring to own address)
/// and cross-pool escrow swaps (storing a different escrow into the wrong pool).
public struct EscrowReceipt {
    pool_id: ID,
    escrow_id: ID,
}

// === Internal Helpers ===

/// Transfer balance to recipient only if non-empty, otherwise destroy it.
/// This prevents spamming users with worthless empty NFTs.
fun transfer_or_destroy_balance<AssetType, StableType>(
    balance: ConditionalMarketBalance<AssetType, StableType>,
    recipient: address,
) {
    if (conditional_balance::is_empty(&balance)) {
        conditional_balance::destroy_empty(balance);
    } else {
        transfer::public_transfer(balance, recipient);
    }
}

fun validate_existing_balance_for_escrow<AssetType, StableType>(
    balance_opt: &option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    if (option::is_some(balance_opt)) {
        let market_id = market_state::market_id(coin_escrow::get_market_state(escrow));
        let balance_market_id = conditional_balance::market_id(option::borrow(balance_opt));
        assert!(balance_market_id == market_id, EBalanceMarketMismatch);
    }
}

// === Spot Swaps with Auto-Arb ===

/// Swap stable → asset in spot market with automatic arbitrage
///
/// **DCA BOT & AGGREGATOR COMPATIBLE** - Supports auto-merge and return modes
///
/// # Arguments
/// * `existing_balance_opt` - Optional balance to merge into (DCA bots: pass previous balance)
/// * `return_balance` - If true: return balance to caller. If false: transfer to recipient
///
/// # Returns
/// * `option::Option<Coin<AssetType>>` - Asset output (Some only when `return_balance=true`)
/// * `option::Option<ConditionalMarketBalance>` - Dust balance (Some only when `return_balance=true`)
///
/// # Use Cases
///
/// **Regular User (one swap):**
/// ```typescript
/// tx.moveCall({
///   arguments: [..., recipient, null, false, ...] // Transfer balance to recipient
/// });
/// ```
///
/// **DCA Bot (100 swaps → 1 NFT):**
/// ```typescript
/// let balance = null;
/// for (let i = 0; i < 100; i++) {
///   const [assetOut, balanceOpt] = tx.moveCall({
///     arguments: [..., botAddress, balance, true, ...] // Return balance to accumulate
///   });
///   balance = balanceOpt;
/// }
/// tx.transferObjects([balance], user); // Final: 1 NFT with all dust!
/// ```
public fun swap_spot_stable_to_asset<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    mut stable_in: Coin<StableType>,
    min_asset_out: u64,
    recipient: address,
    mut existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    return_balance: bool,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (
    option::Option<Coin<AssetType>>,
    option::Option<ConditionalMarketBalance<AssetType, StableType>>,
) {
    let amount_in = stable_in.value();
    assert!(amount_in > 0, EZeroAmount);

    if (unified_spot_pool::has_active_escrow(spot_pool)) {
        let extract_auth = spot_pool_mutation_auth::create(
            spot_pool_mutation_registry,
            SpotPoolMutationWitness {},
            object::id(spot_pool),
        );
        let mut escrow = unified_spot_pool::extract_active_escrow(spot_pool, extract_auth);

        let conditional_swaps_allowed =
            market_state::are_swaps_allowed(coin_escrow::get_market_state(&escrow), clock);
        validate_existing_balance_for_escrow(&existing_balance_opt, &escrow);

        let (spot_stable_in, conditional_stable_in, _expected_asset_out) =
            if (conditional_swaps_allowed) {
                let market_state = coin_escrow::get_market_state(&escrow);
                arbitrage_math::compute_best_stable_to_asset_split(
                    spot_pool,
                    market_state::borrow_amm_pools(market_state),
                    amount_in,
                    coin_escrow::get_escrowed_asset_balance(&escrow),
                    clock,
                )
            } else {
                (
                    amount_in,
                    0,
                    unified_spot_pool::simulate_swap_stable_to_asset_accurate(
                        spot_pool,
                        amount_in,
                        clock,
                    ),
                )
            };

        let asset_out = if (conditional_stable_in == 0) {
            let swap_auth = spot_pool_mutation_auth::create(
                spot_pool_mutation_registry,
                SpotPoolMutationWitness {},
                object::id(spot_pool),
            );
            unified_spot_pool::swap_stable_for_asset_with_escrow_extracted(
                spot_pool,
                stable_in,
                min_asset_out,
                clock,
                ctx,
                swap_auth,
            )
        } else if (spot_stable_in == 0) {
            let (asset_out, balance_opt) = arbitrage::swap_stable_to_asset_through_conditionals(
                &mut escrow,
                stable_in,
                min_asset_out,
                existing_balance_opt,
                escrow_registry,
                clock,
                ctx,
            );
            existing_balance_opt = balance_opt;
            asset_out
        } else {
            let stable_for_conditionals = coin::split(&mut stable_in, conditional_stable_in, ctx);
            let swap_auth = spot_pool_mutation_auth::create(
                spot_pool_mutation_registry,
                SpotPoolMutationWitness {},
                object::id(spot_pool),
            );
            let mut spot_asset_out = unified_spot_pool::swap_stable_for_asset_with_escrow_extracted(
                spot_pool,
                stable_in,
                0,
                clock,
                ctx,
                swap_auth,
            );
            let (conditional_asset_out, balance_opt) = arbitrage::swap_stable_to_asset_through_conditionals(
                &mut escrow,
                stable_for_conditionals,
                0,
                existing_balance_opt,
                escrow_registry,
                clock,
                ctx,
            );
            existing_balance_opt = balance_opt;
            coin::join(&mut spot_asset_out, conditional_asset_out);
            spot_asset_out
        };

        assert!(asset_out.value() >= min_asset_out, EMinAmountNotMet);

        if (conditional_swaps_allowed) {
            existing_balance_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
                spot_pool,
                &mut escrow,
                existing_balance_opt,
                escrow_registry,
                market_state_registry,
                clock,
                ctx,
            );
        };

        // Emit after route and rebalance execution so reserves reflect the final path state.
        let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(spot_pool);
        event::emit(SpotSwap {
            pool_id: unified_spot_pool::get_pool_id(spot_pool),
            is_buy: true,
            amount_in,
            amount_out: asset_out.value(),
            sender: ctx.sender(),
            recipient,
            asset_reserve,
            stable_reserve,
        });

        let store_auth = spot_pool_mutation_auth::create(
            spot_pool_mutation_registry,
            SpotPoolMutationWitness {},
            object::id(spot_pool),
        );
        unified_spot_pool::store_active_escrow(spot_pool, escrow, store_auth);

        if (return_balance) {
            (option::some(asset_out), existing_balance_opt)
        } else {
            transfer::public_transfer(asset_out, recipient);
            if (option::is_some(&existing_balance_opt)) {
                transfer_or_destroy_balance(option::extract(&mut existing_balance_opt), recipient);
            };
            option::destroy_none(existing_balance_opt);
            (
                option::none<Coin<AssetType>>(),
                option::none<ConditionalMarketBalance<AssetType, StableType>>(),
            )
        }
    } else {
        // No active escrow in the pool: pure spot path. If a proposal is locked,
        // the escrow is temporarily extracted by this PTB, so use the auth-gated
        // variant that permits spot execution while the escrow is out.
        let asset_out = if (unified_spot_pool::is_locked_for_proposal(spot_pool)) {
            let swap_auth = spot_pool_mutation_auth::create(
                spot_pool_mutation_registry,
                SpotPoolMutationWitness {},
                object::id(spot_pool),
            );
            unified_spot_pool::swap_stable_for_asset_with_escrow_extracted(
                spot_pool,
                stable_in,
                min_asset_out,
                clock,
                ctx,
                swap_auth,
            )
        } else {
            unified_spot_pool::swap_stable_for_asset(
                spot_pool,
                stable_in,
                min_asset_out,
                clock,
                ctx,
            )
        };

        // Emit spot swap event
        let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(spot_pool);
        event::emit(SpotSwap {
            pool_id: unified_spot_pool::get_pool_id(spot_pool),
            is_buy: true,
            amount_in,
            amount_out: asset_out.value(),
            sender: ctx.sender(),
            recipient,
            asset_reserve,
            stable_reserve,
        });

        if (return_balance) {
            (option::some(asset_out), existing_balance_opt)
        } else {
            transfer::public_transfer(asset_out, recipient);
            if (option::is_some(&existing_balance_opt)) {
                transfer_or_destroy_balance(option::extract(&mut existing_balance_opt), recipient);
            };
            option::destroy_none(existing_balance_opt);
            (
                option::none<Coin<AssetType>>(),
                option::none<ConditionalMarketBalance<AssetType, StableType>>(),
            )
        }
    }
}

/// Swap asset → stable in spot market with automatic arbitrage
///
/// **DCA BOT & AGGREGATOR COMPATIBLE** - Supports auto-merge and return modes
///
/// # Arguments
/// * `existing_balance_opt` - Optional balance to merge into (DCA bots: pass previous balance)
/// * `return_balance` - If true: return balance to caller. If false: transfer to recipient
///
/// # Returns
/// * `option::Option<Coin<StableType>>` - Stable output (Some only when `return_balance=true`)
/// * `option::Option<ConditionalMarketBalance>` - Dust balance (Some only when `return_balance=true`)
///
/// # Use Cases
///
/// **Regular User (one swap):**
/// ```typescript
/// tx.moveCall({
///   arguments: [..., recipient, null, false, ...] // Transfer balance to recipient
/// });
/// ```
///
/// **DCA Bot (100 swaps → 1 NFT):**
/// ```typescript
/// let balance = null;
/// for (let i = 0; i < 100; i++) {
///   const [stableOut, balanceOpt] = tx.moveCall({
///     arguments: [..., botAddress, balance, true, ...] // Return balance to accumulate
///   });
///   balance = balanceOpt;
/// }
/// tx.transferObjects([balance], user); // Final: 1 NFT with all dust!
/// ```
public fun swap_spot_asset_to_stable<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    mut asset_in: Coin<AssetType>,
    min_stable_out: u64,
    recipient: address,
    mut existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    return_balance: bool,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (
    option::Option<Coin<StableType>>,
    option::Option<ConditionalMarketBalance<AssetType, StableType>>,
) {
    let amount_in = asset_in.value();
    assert!(amount_in > 0, EZeroAmount);

    if (unified_spot_pool::has_active_escrow(spot_pool)) {
        let extract_auth = spot_pool_mutation_auth::create(
            spot_pool_mutation_registry,
            SpotPoolMutationWitness {},
            object::id(spot_pool),
        );
        let mut escrow = unified_spot_pool::extract_active_escrow(spot_pool, extract_auth);

        let conditional_swaps_allowed =
            market_state::are_swaps_allowed(coin_escrow::get_market_state(&escrow), clock);
        validate_existing_balance_for_escrow(&existing_balance_opt, &escrow);

        let (spot_asset_in, conditional_asset_in, _expected_stable_out) =
            if (conditional_swaps_allowed) {
                let market_state = coin_escrow::get_market_state(&escrow);
                arbitrage_math::compute_best_asset_to_stable_split(
                    spot_pool,
                    market_state::borrow_amm_pools(market_state),
                    amount_in,
                    coin_escrow::get_escrowed_stable_balance(&escrow),
                    clock,
                )
            } else {
                (
                    amount_in,
                    0,
                    unified_spot_pool::simulate_swap_asset_to_stable_accurate(
                        spot_pool,
                        amount_in,
                        clock,
                    ),
                )
            };

        let stable_out = if (conditional_asset_in == 0) {
            let swap_auth = spot_pool_mutation_auth::create(
                spot_pool_mutation_registry,
                SpotPoolMutationWitness {},
                object::id(spot_pool),
            );
            unified_spot_pool::swap_asset_for_stable_with_escrow_extracted(
                spot_pool,
                asset_in,
                min_stable_out,
                clock,
                ctx,
                swap_auth,
            )
        } else if (spot_asset_in == 0) {
            let (stable_out, balance_opt) = arbitrage::swap_asset_to_stable_through_conditionals(
                &mut escrow,
                asset_in,
                min_stable_out,
                existing_balance_opt,
                escrow_registry,
                clock,
                ctx,
            );
            existing_balance_opt = balance_opt;
            stable_out
        } else {
            let asset_for_conditionals = coin::split(&mut asset_in, conditional_asset_in, ctx);
            let swap_auth = spot_pool_mutation_auth::create(
                spot_pool_mutation_registry,
                SpotPoolMutationWitness {},
                object::id(spot_pool),
            );
            let mut spot_stable_out = unified_spot_pool::swap_asset_for_stable_with_escrow_extracted(
                spot_pool,
                asset_in,
                0,
                clock,
                ctx,
                swap_auth,
            );
            let (conditional_stable_out, balance_opt) = arbitrage::swap_asset_to_stable_through_conditionals(
                &mut escrow,
                asset_for_conditionals,
                0,
                existing_balance_opt,
                escrow_registry,
                clock,
                ctx,
            );
            existing_balance_opt = balance_opt;
            coin::join(&mut spot_stable_out, conditional_stable_out);
            spot_stable_out
        };

        assert!(stable_out.value() >= min_stable_out, EMinAmountNotMet);

        if (conditional_swaps_allowed) {
            existing_balance_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
                spot_pool,
                &mut escrow,
                existing_balance_opt,
                escrow_registry,
                market_state_registry,
                clock,
                ctx,
            );
        };

        // Emit after route and rebalance execution so reserves reflect the final path state.
        let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(spot_pool);
        event::emit(SpotSwap {
            pool_id: unified_spot_pool::get_pool_id(spot_pool),
            is_buy: false,
            amount_in,
            amount_out: stable_out.value(),
            sender: ctx.sender(),
            recipient,
            asset_reserve,
            stable_reserve,
        });

        let store_auth = spot_pool_mutation_auth::create(
            spot_pool_mutation_registry,
            SpotPoolMutationWitness {},
            object::id(spot_pool),
        );
        unified_spot_pool::store_active_escrow(spot_pool, escrow, store_auth);

        if (return_balance) {
            (option::some(stable_out), existing_balance_opt)
        } else {
            transfer::public_transfer(stable_out, recipient);
            if (option::is_some(&existing_balance_opt)) {
                transfer_or_destroy_balance(option::extract(&mut existing_balance_opt), recipient);
            };
            option::destroy_none(existing_balance_opt);
            (
                option::none<Coin<StableType>>(),
                option::none<ConditionalMarketBalance<AssetType, StableType>>(),
            )
        }
    } else {
        // No active escrow in the pool: pure spot path. If a proposal is locked,
        // the escrow is temporarily extracted by this PTB, so use the auth-gated
        // variant that permits spot execution while the escrow is out.
        let stable_out = if (unified_spot_pool::is_locked_for_proposal(spot_pool)) {
            let swap_auth = spot_pool_mutation_auth::create(
                spot_pool_mutation_registry,
                SpotPoolMutationWitness {},
                object::id(spot_pool),
            );
            unified_spot_pool::swap_asset_for_stable_with_escrow_extracted(
                spot_pool,
                asset_in,
                min_stable_out,
                clock,
                ctx,
                swap_auth,
            )
        } else {
            unified_spot_pool::swap_asset_for_stable(
                spot_pool,
                asset_in,
                min_stable_out,
                clock,
                ctx,
            )
        };

        // Emit spot swap event
        let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(spot_pool);
        event::emit(SpotSwap {
            pool_id: unified_spot_pool::get_pool_id(spot_pool),
            is_buy: false,
            amount_in,
            amount_out: stable_out.value(),
            sender: ctx.sender(),
            recipient,
            asset_reserve,
            stable_reserve,
        });

        if (return_balance) {
            (option::some(stable_out), existing_balance_opt)
        } else {
            transfer::public_transfer(stable_out, recipient);
            if (option::is_some(&existing_balance_opt)) {
                transfer_or_destroy_balance(option::extract(&mut existing_balance_opt), recipient);
            };
            option::destroy_none(existing_balance_opt);
            (
                option::none<Coin<StableType>>(),
                option::none<ConditionalMarketBalance<AssetType, StableType>>(),
            )
        }
    }
}

// === CONDITIONAL SWAP BATCHING ===
//
// PTB-based conditional swap batching for advanced traders.
// Allows chaining multiple conditional swaps, then settling at the end.
//
// Hot potato pattern ensures explicit batch finalization.
//
// Flow:
// 1. begin_conditional_swaps() → creates ConditionalSwapBatch hot potato
// 2. swap_in_batch() × N → accumulates swaps in balance (chainable)
// 3. finalize_conditional_swaps() → finalizes session, runs auto-rebalance, returns balance
//
// ============================================================================

/// Extract the active escrow from a spot pool for conditional swap PTBs.
///
/// SECURITY: package-only to prevent arbitrary external extraction of wrapped escrows.
public(package) fun extract_active_escrow_for_conditional_swaps<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
): TokenEscrow<AssetType, StableType> {
    let auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::extract_active_escrow(spot_pool, auth)
}

/// Store an active escrow back into the spot pool after conditional swap PTBs.
///
/// SECURITY: package-only counterpart to extract_active_escrow_for_conditional_swaps.
public(package) fun store_active_escrow_after_conditional_swaps<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: TokenEscrow<AssetType, StableType>,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
) {
    let auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_active_escrow(spot_pool, escrow, auth);
}

/// Read proposal oracle state while escrow is wrapped in the spot pool.
///
/// Extracts escrow, reads oracle state, and restores escrow atomically.
public fun read_oracle_state_by_outcome_with_wrapped_escrow<AssetType, StableType, LPType>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    outcome_idx: u8,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
): (
    u128,
    u64,
    u256,
    u256,
    u64,
    u128,
    Option<u64>,
    u128,
    u64,
    u64,
    u64,
    u64,
) {
    let extract_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    let (escrow, was_active) = unified_spot_pool::extract_escrow_by_market_id(
        spot_pool,
        proposal::market_state_id(proposal),
        extract_auth,
    );
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
        asset_reserve,
        stable_reserve,
    ) = proposal::get_oracle_state_by_outcome(proposal, &escrow, outcome_idx);

    let store_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_extracted_escrow(spot_pool, escrow, was_active, store_auth);
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

/// Read escrow state while escrow is wrapped in the spot pool.
///
/// Returns global escrow balances and per-outcome allocations.
/// Extracts escrow, reads state, and restores escrow atomically.
/// Read-only: no state mutation.
///
/// Returns:
///   (escrowed_asset, escrowed_stable, lp_deposited_asset, lp_deposited_stable,
///    user_deposited_asset, user_deposited_stable,
///    outcome_escrowed_asset, outcome_escrowed_stable,
///    pool_claim_asset, pool_claim_stable,
///    asset_supplies, stable_supplies)
public fun read_escrow_state_with_wrapped_escrow<AssetType, StableType, LPType>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
): (
    u64, // escrowed_asset
    u64, // escrowed_stable
    u64, // lp_deposited_asset
    u64, // lp_deposited_stable
    u64, // user_deposited_asset
    u64, // user_deposited_stable
    vector<u64>, // outcome_escrowed_asset
    vector<u64>, // outcome_escrowed_stable
    vector<u64>, // pool_claim_asset
    vector<u64>, // pool_claim_stable
    vector<u64>, // asset_supplies
    vector<u64>, // stable_supplies
) {
    let extract_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    let (escrow, was_active) = unified_spot_pool::extract_escrow_by_market_id(
        spot_pool,
        proposal::market_state_id(proposal),
        extract_auth,
    );

    let (escrowed_asset, escrowed_stable, lp_deposited_asset, lp_deposited_stable,
         user_deposited_asset, user_deposited_stable) = coin_escrow::get_all_tracking(&escrow);

    let outcome_count = proposal::outcome_count(proposal);
    let mut outcome_escrowed_asset = vector[];
    let mut outcome_escrowed_stable = vector[];
    let mut pool_claim_asset = vector[];
    let mut pool_claim_stable = vector[];
    let mut asset_supplies = vector[];
    let mut stable_supplies = vector[];

    let mut i = 0;
    while (i < outcome_count) {
        outcome_escrowed_asset.push_back(coin_escrow::get_outcome_escrowed_asset(&escrow, i));
        outcome_escrowed_stable.push_back(coin_escrow::get_outcome_escrowed_stable(&escrow, i));
        pool_claim_asset.push_back(coin_escrow::get_pool_claim_asset(&escrow, i));
        pool_claim_stable.push_back(coin_escrow::get_pool_claim_stable(&escrow, i));
        asset_supplies.push_back(coin_escrow::get_outcome_asset_supply(&escrow, i));
        stable_supplies.push_back(coin_escrow::get_outcome_stable_supply(&escrow, i));
        i = i + 1;
    };

    let store_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_extracted_escrow(spot_pool, escrow, was_active, store_auth);

    (
        escrowed_asset, escrowed_stable,
        lp_deposited_asset, lp_deposited_stable,
        user_deposited_asset, user_deposited_stable,
        outcome_escrowed_asset, outcome_escrowed_stable,
        pool_claim_asset, pool_claim_stable,
        asset_supplies, stable_supplies,
    )
}

/// Read spot pool PCW_TWAP oracle state.
///
/// The spot pool is a shared object so no extract/restore needed.
/// Read-only: no state mutation.
///
/// Returns: (last_price, last_window_twap, initialized_at, cumulative_total)
public fun read_spot_oracle_state<AssetType, StableType, LPType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): (
    u128, // last_price
    u128, // last_window_twap
    u64,  // initialized_at
    u256, // cumulative_total
) {
    let twap = unified_spot_pool::get_simple_twap(spot_pool);
    (
        PCW_TWAP_oracle::last_price(twap),
        PCW_TWAP_oracle::get_twap(twap),
        PCW_TWAP_oracle::initialized_at(twap),
        PCW_TWAP_oracle::cumulative_total(twap),
    )
}

/// Execute a stable->asset conditional swap when escrow is wrapped in the spot pool.
///
/// Input is spot stable. Internally:
/// 1) extract wrapped escrow
/// 2) split spot stable into balance
/// 3) unwrap target conditional stable coin
/// 4) swap to conditional asset
/// 5) finalize and auto-rebalance
/// 6) store escrow back and transfer output to recipient
public fun conditional_swap_stable_to_asset_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    StableConditionalCoin,
    AssetConditionalCoin,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    stable_in: Coin<StableType>,
    outcome_index: u8,
    min_amount_out: u64,
    recipient: address,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount_in = stable_in.value();
    assert!(amount_in > 0, EZeroAmount);

    let extract_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    let mut escrow = unified_spot_pool::extract_active_escrow(spot_pool, extract_auth);
    assert!(
        coin_escrow::market_state_id(&escrow) == proposal::market_state_id(proposal),
        EProposalEscrowMismatch,
    );

    let session = swap_core::begin_swap_session(&escrow);
    let mut batch = begin_conditional_swaps(&escrow, clock, ctx);

    conditional_balance::split_stable_to_balance(&mut escrow, &mut batch.balance, stable_in);
    let input_coin = conditional_balance::unwrap_to_coin<AssetType, StableType, StableConditionalCoin>(
        &mut batch.balance,
        &mut escrow,
        outcome_index,
        false,
        amount_in,
        ctx,
    );
    let (batch, output_coin) = swap_in_batch<AssetType, StableType, StableConditionalCoin, AssetConditionalCoin>(
        batch,
        &session,
        &mut escrow,
        outcome_index,
        input_coin,
        false,
        min_amount_out,
        escrow_registry,
        clock,
        ctx,
    );

    finalize_conditional_swaps(
        batch,
        spot_pool,
        proposal,
        &mut escrow,
        session,
        recipient,
        escrow_registry,
        market_state_registry,
        clock,
        ctx,
    );

    let store_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_active_escrow(spot_pool, escrow, store_auth);
    transfer::public_transfer(output_coin, recipient);
}

/// Execute an asset->stable conditional swap when escrow is wrapped in the spot pool.
///
/// Input is spot asset. Internally:
/// 1) extract wrapped escrow
/// 2) split spot asset into balance
/// 3) unwrap target conditional asset coin
/// 4) swap to conditional stable
/// 5) finalize and auto-rebalance
/// 6) store escrow back and transfer output to recipient
public fun conditional_swap_asset_to_stable_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_in: Coin<AssetType>,
    outcome_index: u8,
    min_amount_out: u64,
    recipient: address,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount_in = asset_in.value();
    assert!(amount_in > 0, EZeroAmount);

    let extract_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    let mut escrow = unified_spot_pool::extract_active_escrow(spot_pool, extract_auth);
    assert!(
        coin_escrow::market_state_id(&escrow) == proposal::market_state_id(proposal),
        EProposalEscrowMismatch,
    );

    let session = swap_core::begin_swap_session(&escrow);
    let mut batch = begin_conditional_swaps(&escrow, clock, ctx);

    conditional_balance::split_asset_to_balance(&mut escrow, &mut batch.balance, asset_in);
    let input_coin = conditional_balance::unwrap_to_coin<AssetType, StableType, AssetConditionalCoin>(
        &mut batch.balance,
        &mut escrow,
        outcome_index,
        true,
        amount_in,
        ctx,
    );
    let (batch, output_coin) = swap_in_batch<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
        batch,
        &session,
        &mut escrow,
        outcome_index,
        input_coin,
        true,
        min_amount_out,
        escrow_registry,
        clock,
        ctx,
    );

    finalize_conditional_swaps(
        batch,
        spot_pool,
        proposal,
        &mut escrow,
        session,
        recipient,
        escrow_registry,
        market_state_registry,
        clock,
        ctx,
    );

    let store_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_active_escrow(spot_pool, escrow, store_auth);
    transfer::public_transfer(output_coin, recipient);
}

/// Execute a conditional swap using input from an existing balance wrapper.
///
/// Input is sourced from the provided `ConditionalMarketBalance` in the selected outcome.
/// Internally:
/// 1) extract wrapped escrow
/// 2) unwrap target conditional input coin from balance wrapper
/// 3) swap to output conditional coin
/// 4) finalize and auto-rebalance
/// 5) store escrow back and transfer output to recipient
public fun conditional_swap_balance_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    InputCoin,
    OutputCoin,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    outcome_index: u8,
    is_asset_to_stable: bool,
    amount_in: u64,
    min_amount_out: u64,
    recipient: address,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount_in > 0, EZeroAmount);

    let extract_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    let mut escrow = unified_spot_pool::extract_active_escrow(spot_pool, extract_auth);
    assert!(
        coin_escrow::market_state_id(&escrow) == proposal::market_state_id(proposal),
        EProposalEscrowMismatch,
    );

    let session = swap_core::begin_swap_session(&escrow);
    let batch = begin_conditional_swaps(&escrow, clock, ctx);
    let input_coin = conditional_balance::unwrap_to_coin<AssetType, StableType, InputCoin>(
        balance,
        &mut escrow,
        outcome_index,
        is_asset_to_stable,
        amount_in,
        ctx,
    );
    let (batch, output_coin) = swap_in_batch<AssetType, StableType, InputCoin, OutputCoin>(
        batch,
        &session,
        &mut escrow,
        outcome_index,
        input_coin,
        is_asset_to_stable,
        min_amount_out,
        escrow_registry,
        clock,
        ctx,
    );

    finalize_conditional_swaps(
        batch,
        spot_pool,
        proposal,
        &mut escrow,
        session,
        recipient,
        escrow_registry,
        market_state_registry,
        clock,
        ctx,
    );

    let store_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_active_escrow(spot_pool, escrow, store_auth);
    transfer::public_transfer(output_coin, recipient);
}

/// Execute a single conditional swap when escrow is wrapped in the spot pool.
///
/// Input is a conditional coin (`InputCoin`) for the target outcome.
public fun conditional_swap_coin_with_wrapped_escrow<
    AssetType,
    StableType,
    LPType,
    InputCoin,
    OutputCoin,
>(
    proposal: &Proposal<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    coin_in: Coin<InputCoin>,
    outcome_index: u8,
    is_asset_to_stable: bool,
    min_amount_out: u64,
    recipient: address,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount_in = coin_in.value();
    assert!(amount_in > 0, EZeroAmount);

    let extract_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    let mut escrow = unified_spot_pool::extract_active_escrow(spot_pool, extract_auth);
    assert!(
        coin_escrow::market_state_id(&escrow) == proposal::market_state_id(proposal),
        EProposalEscrowMismatch,
    );

    let session = swap_core::begin_swap_session(&escrow);
    let batch = begin_conditional_swaps(&escrow, clock, ctx);
    let (batch, output_coin) = swap_in_batch<AssetType, StableType, InputCoin, OutputCoin>(
        batch,
        &session,
        &mut escrow,
        outcome_index,
        coin_in,
        is_asset_to_stable,
        min_amount_out,
        escrow_registry,
        clock,
        ctx,
    );

    finalize_conditional_swaps(
        batch,
        spot_pool,
        proposal,
        &mut escrow,
        session,
        recipient,
        escrow_registry,
        market_state_registry,
        clock,
        ctx,
    );

    let store_auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_active_escrow(spot_pool, escrow, store_auth);
    transfer::public_transfer(output_coin, recipient);
}

// === Escrow Extract/Store for Batch PTB ===

/// Extract the active escrow from the spot pool for batch PTB operations.
///
/// Returns the escrow AND a hot potato `EscrowReceipt` that binds this escrow
/// to this pool. The receipt has no abilities, so it MUST be consumed by
/// `store_escrow_after_batch` in the same PTB — preventing escrow theft
/// (attacker can't transfer the escrow to their own address) and cross-pool
/// swaps (attacker can't store a different escrow into the wrong pool).
///
/// # Example PTB
/// ```typescript
/// // 1. Extract escrow + receipt
/// const [escrow, receipt] = tx.moveCall({
///   target: '${PKG}::swap_entry::extract_escrow_for_batch',
///   arguments: [spotPool, spotPoolMutationRegistry]
/// });
/// // 2. ... batch operations using escrow ...
/// // 3. Store escrow back (consumes receipt)
/// tx.moveCall({
///   target: '${PKG}::swap_entry::store_escrow_after_batch',
///   arguments: [spotPool, escrow, receipt, spotPoolMutationRegistry]
/// });
/// ```
public fun extract_escrow_for_batch<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
): (TokenEscrow<AssetType, StableType>, EscrowReceipt) {
    let auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    let escrow = unified_spot_pool::extract_active_escrow(spot_pool, auth);
    let receipt = EscrowReceipt {
        pool_id: object::id(spot_pool),
        escrow_id: object::id(&escrow),
    };
    (escrow, receipt)
}

/// Store the escrow back into the spot pool after batch PTB operations.
///
/// Consumes the hot potato `EscrowReceipt` from `extract_escrow_for_batch`.
/// Validates that the escrow being stored is the same one that was extracted
/// and that it's going back to the same pool.
///
/// SECURITY: Runs mandatory rebalance before storing. This ensures that any spot
/// swaps performed while the escrow was extracted are followed by arbitrage to
/// re-synchronize spot and conditional prices. Without this, an attacker could
/// extract the escrow, do unprotected spot swaps, and store back without rebalance.
/// The rebalance is idempotent — if prices are already balanced, it's a no-op.
public fun store_escrow_after_batch<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    mut escrow: TokenEscrow<AssetType, StableType>,
    receipt: EscrowReceipt,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    _recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let EscrowReceipt { pool_id, escrow_id } = receipt;
    assert!(pool_id == object::id(spot_pool), EReceiptPoolMismatch);
    assert!(escrow_id == object::id(&escrow), EReceiptEscrowMismatch);

    // Mandatory rebalance: re-synchronize spot and conditional prices.
    // This is critical to prevent spot price manipulation during batch extraction.
    let balance_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        spot_pool,
        &mut escrow,
        option::none(),
        escrow_registry,
        market_state_registry,
        clock,
        ctx,
    );
    // System rebalance must not create or transfer user-owned dust.
    option::destroy_none(balance_opt);

    let auth = spot_pool_mutation_auth::create(
        spot_pool_mutation_registry,
        SpotPoolMutationWitness {},
        object::id(spot_pool),
    );
    unified_spot_pool::store_active_escrow(spot_pool, escrow, auth);
}

// === Hot Potato Batch Pattern ===

/// Hot potato for batching conditional swaps in PTB
/// NO abilities = MUST be consumed in same transaction
///
/// This forces users to call finalize_conditional_swaps() at end of PTB,
/// and cannot be stored between transactions.
public struct ConditionalSwapBatch<phantom AssetType, phantom StableType> {
    balance: ConditionalMarketBalance<AssetType, StableType>,
    market_id: ID,
}

/// Step 1: Begin a conditional swap batch (returns hot potato)
///
/// Creates hot potato with empty balance. Must be consumed by finalize_conditional_swaps().
///
/// # Example PTB Flow
/// ```typescript
/// const batch = tx.moveCall({
///   target: '${PKG}::swap_entry::begin_conditional_swaps',
///   typeArguments: [AssetType, StableType],
///   arguments: [escrow]
/// });
///
/// // Chain swaps...
/// const batch2 = tx.moveCall({
///   target: '${PKG}::swap_entry::swap_in_batch',
///   arguments: [batch, session, escrow, ...] // Returns modified hot potato
/// });
///
/// // Must finalize at end
/// tx.moveCall({
///   target: '${PKG}::swap_entry::finalize_conditional_swaps',
///   arguments: [batch2, ...]
/// });
/// ```
public fun begin_conditional_swaps<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalSwapBatch<AssetType, StableType> {
    // Get market info - allow swaps during trading OR execution window
    let market_state = coin_escrow::get_market_state(escrow);
    market_state::assert_swaps_allowed(market_state, clock);

    let market_id = market_state::market_id(market_state);
    let outcome_count = market_state::outcome_count(market_state);

    // Create empty balance
    let balance = conditional_balance::new<AssetType, StableType>(
        market_id,
        (outcome_count as u8),
        ctx,
    );

    // Return hot potato (NO abilities = must consume)
    ConditionalSwapBatch {
        balance,
        market_id,
    }
}

/// Split a spot asset coin into the batch's balance for all outcomes.
///
/// This is the PTB-callable wrapper for `conditional_balance::split_asset_to_balance`.
/// After calling this, each outcome in the batch has `asset_in.value()` of asset balance.
/// Use `unwrap_from_batch` to extract individual outcome positions as typed coins.
///
/// # Example PTB
/// ```typescript
/// // Split 1000 ASSET into conditional positions for all outcomes
/// batch = tx.moveCall({
///   target: '${PKG}::swap_entry::split_asset_to_batch',
///   typeArguments: [AssetType, StableType],
///   arguments: [batch, escrow, assetCoin]
/// });
/// ```
public fun split_asset_to_batch<AssetType, StableType>(
    mut batch: ConditionalSwapBatch<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_in: Coin<AssetType>,
): ConditionalSwapBatch<AssetType, StableType> {
    conditional_balance::split_asset_to_balance(escrow, &mut batch.balance, asset_in);
    batch
}

/// Split a spot stable coin into the batch's balance for all outcomes.
///
/// This is the PTB-callable wrapper for `conditional_balance::split_stable_to_balance`.
/// After calling this, each outcome in the batch has `stable_in.value()` of stable balance.
/// Use `unwrap_from_batch` to extract individual outcome positions as typed coins.
///
/// # Example PTB
/// ```typescript
/// // Split 1000 STABLE into conditional positions for all outcomes
/// batch = tx.moveCall({
///   target: '${PKG}::swap_entry::split_stable_to_batch',
///   typeArguments: [AssetType, StableType],
///   arguments: [batch, escrow, stableCoin]
/// });
/// ```
public fun split_stable_to_batch<AssetType, StableType>(
    mut batch: ConditionalSwapBatch<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable_in: Coin<StableType>,
): ConditionalSwapBatch<AssetType, StableType> {
    conditional_balance::split_stable_to_balance(escrow, &mut batch.balance, stable_in);
    batch
}

/// Unwrap a conditional position from the batch's balance into a typed coin.
///
/// Use this between `swap_in_batch` and `finalize_conditional_swaps` to extract
/// residual positions as coins instead of receiving a ConditionalMarketBalance.
/// Call once per outcome you want to extract. Works for any outcome count.
///
/// # Arguments
/// * `batch` - Hot potato from begin/split/swap
/// * `escrow` - Token escrow (for mint validation)
/// * `outcome_idx` - Which outcome to unwrap (0, 1, 2, ...)
/// * `is_asset` - true = unwrap asset position, false = unwrap stable position
/// * `amount` - Amount to unwrap
///
/// # Returns
/// Modified hot potato + typed conditional coin
///
/// # Example PTB (N-outcome agnostic)
/// ```typescript
/// // After swap in outcome 0, unwrap residuals for all other outcomes
/// for (let i = 0; i < outcomeCount; i++) {
///   if (i === swapOutcome) continue;
///   const [newBatch, coin] = tx.moveCall({
///     target: '${PKG}::swap_entry::unwrap_from_batch',
///     typeArguments: [AssetType, StableType, conditionalCoinTypes[i]],
///     arguments: [batch, escrow, i, isAsset, amount]
///   });
///   batch = newBatch;
///   tx.transferObjects([coin], recipient);
/// }
/// ```
public fun unwrap_from_batch<AssetType, StableType, CoinType>(
    mut batch: ConditionalSwapBatch<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    amount: u64,
    ctx: &mut TxContext,
): (ConditionalSwapBatch<AssetType, StableType>, Coin<CoinType>) {
    let coin = conditional_balance::unwrap_to_coin<AssetType, StableType, CoinType>(
        &mut batch.balance,
        escrow,
        outcome_idx,
        is_asset,
        amount,
        ctx,
    );
    (batch, coin)
}

/// Step 2: Swap in batch (consumes and returns hot potato)
///
/// Wraps coin → swaps in balance → unwraps to coin → returns modified hot potato
///
/// Can be called N times in a PTB to chain swaps across multiple outcomes.
/// Each call mutates the balance in the hot potato and returns it for next call.
///
/// # Arguments
/// * `batch` - Hot potato from begin_conditional_swaps or previous swap_in_batch
/// * `session` - SwapSession hot potato (from swap_core::begin_swap_session)
/// * `outcome_index` - Which outcome to swap in (0, 1, 2, ...)
/// * `coin_in` - Input coin (conditional asset or stable)
/// * `is_asset_to_stable` - true = swap asset→stable, false = swap stable→asset
/// * `min_amount_out` - Minimum output amount (slippage protection)
///
/// # Returns
/// Modified hot potato (pass to next swap_in_batch or finalize_conditional_swaps)
///
/// # Type Parameters
/// * `InputCoin` - Type of input conditional coin
/// * `OutputCoin` - Type of output conditional coin
///
/// # Example
/// ```typescript
/// // Swap in outcome 0: stable → asset
/// let batch = tx.moveCall({
///   target: '${PKG}::swap_entry::swap_in_batch',
///   typeArguments: [AssetType, StableType, Cond0Stable, Cond0Asset],
///   arguments: [batch, session, escrow, 0, stableCoin, false, minOut, clock]
/// });
///
/// // Swap in outcome 1: asset → stable
/// batch = tx.moveCall({
///   target: '${PKG}::swap_entry::swap_in_batch',
///   typeArguments: [AssetType, StableType, Cond1Asset, Cond1Stable],
///   arguments: [batch, session, escrow, 1, assetCoin, true, minOut, clock]
/// });
/// ```
public fun swap_in_batch<AssetType, StableType, InputCoin, OutputCoin>(
    mut batch: ConditionalSwapBatch<AssetType, StableType>,
    session: &swap_core::SwapSession,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u8,
    coin_in: Coin<InputCoin>,
    is_asset_to_stable: bool,
    min_amount_out: u64,
    escrow_registry: &EscrowMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (ConditionalSwapBatch<AssetType, StableType>, Coin<OutputCoin>) {
    let amount_in = coin_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // Defense-in-depth: Early batch-escrow market check
    assert!(batch.market_id == coin_escrow::market_state_id(escrow), EBatchEscrowMismatch);

    // Validate swaps allowed (trading OR execution window, before deadline)
    let market_state = coin_escrow::get_market_state(escrow);
    market_state::assert_swaps_allowed(market_state, clock);

    // Wrap coin → balance
    conditional_balance::wrap_coin<AssetType, StableType, InputCoin>(
        &mut batch.balance,
        escrow,
        coin_in,
        outcome_index,
        is_asset_to_stable, // is_asset flag: true wraps asset input, false wraps stable input
    );

    // Swap in balance (balance-based swap works for ANY outcome count!)
    let amount_out = if (is_asset_to_stable) {
        swap_core::swap_balance_asset_to_stable<AssetType, StableType>(
            session,
            escrow,
            &mut batch.balance,
            outcome_index,
            amount_in,
            min_amount_out,
            escrow_registry,
            clock,
            ctx,
        )
    } else {
        swap_core::swap_balance_stable_to_asset<AssetType, StableType>(
            session,
            escrow,
            &mut batch.balance,
            outcome_index,
            amount_in,
            min_amount_out,
            escrow_registry,
            clock,
            ctx,
        )
    };

    // Unwrap balance → coin
    let coin_out = conditional_balance::unwrap_to_coin<AssetType, StableType, OutputCoin>(
        &mut batch.balance,
        escrow,
        outcome_index,
        !is_asset_to_stable, // is_asset flag: inverted because output type is opposite of input type
        amount_out,
        ctx,
    );

    // Return modified hot potato and output coin
    (batch, coin_out)
}

/// Step 3: Finalize conditional swaps (consumes hot potato)
///
/// Finalizes the swap session, runs spot/conditional auto-rebalance, and transfers
/// the remaining balance to recipient for post-trade position management.
///
/// This MUST be called at end of PTB to consume hot potato.
///
/// # Arguments
/// * `batch` - Hot potato from swap_in_batch (final state)
/// * `spot_pool` - Spot pool (used for post-swap auto-rebalance, not for swapping)
/// * `proposal` - Proposal object
/// * `escrow` - Token escrow
/// * `session` - SwapSession hot potato (consumed here)
/// * `recipient` - Who receives the final incomplete-set balance
/// * `clock` - Clock object
///
/// # Flow
/// 1. Finalize swap session
/// 2. Run automatic spot rebalance
/// 3. Transfer incomplete set balance to recipient (for pro traders to manage)
///
/// # Example PTB
/// ```typescript
/// tx.moveCall({
///   target: '${PKG}::swap_entry::finalize_conditional_swaps',
///   typeArguments: [AssetType, StableType],
///   arguments: [batch, spot_pool, proposal, escrow, session, recipient, clock]
/// });
/// ```
public fun finalize_conditional_swaps<AssetType, StableType, LPType>(
    batch: ConditionalSwapBatch<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    session: swap_core::SwapSession,
    recipient: address,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate proposal-escrow binding to prevent mismatched objects
    assert!(
        coin_escrow::market_state_id(escrow) == proposal::market_state_id(proposal),
        EProposalEscrowMismatch,
    );

    // Destructure hot potato
    let ConditionalSwapBatch { mut balance, market_id } = batch;
    // Ensure batch is finalized against the same market it was created for.
    assert!(market_id == coin_escrow::market_state_id(escrow), EBatchEscrowMismatch);

    // The balance holds the user's residual incomplete-set position from swap operations
    // across outcomes. No complete-set settlement is performed at finalize.

    // Finalize session
    swap_core::finalize_swap_session(session, escrow, escrow_registry);

    // CRITICAL: Automatic arbitrage to bring spot price back into conditional range
    // After conditional swaps, spot can be outside the safe range. This atomically
    // arbitrages using pool liquidity to rebalance prices without requiring user coins.
    let mut balance_opt = arbitrage::auto_rebalance_spot_after_conditional_swaps(
        spot_pool,
        escrow,
        option::some(balance),
        escrow_registry,
        market_state_registry,
        clock,
        ctx,
    );
    // Extract balance from arbitrage result. Since we passed Some(balance),
    // the function must always return Some.
    assert!(option::is_some(&balance_opt), EUnexpectedNoneBalance);
    balance = option::extract(&mut balance_opt);
    option::destroy_none(balance_opt);

    // Transfer incomplete set balance to recipient only if non-empty
    // Pro traders can choose to:
    // - Hold and wait for proposal resolution
    // - Rebalance positions across outcomes
    // - Sell to market makers
    // - Store in registry themselves if desired
    transfer_or_destroy_balance(balance, recipient);
}
