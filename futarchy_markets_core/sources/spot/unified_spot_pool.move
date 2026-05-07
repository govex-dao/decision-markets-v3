// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// ============================================================================
/// UNIFIED SPOT POOL - Single pool type with Coin-based LP tokens
/// ============================================================================
///
/// LP tokens are now standard Sui Coins for ecosystem composability.
/// Pool holds TreasuryCap and mints/burns LP coins on liquidity operations.
///
/// LP Coin Requirements:
/// - Symbol must be "GOVEX_LP_TOKEN"
/// - Name must be "GOVEX_LP_TOKEN"
/// - Supply must be 0 when passed to pool creation
///
/// ============================================================================
/// FEE MODEL: Proportional Split
/// ============================================================================
///
/// Fees are split proportionally between protocol and LPs based on their
/// steady-state ratio, regardless of whether the pool is in launch mode or
/// steady state.
///
/// Steady-State Fees (from constants):
/// - Protocol: 50 bps (0.5%) -> constants::protocol_fee_bps()
/// - LP: 25 bps (0.25%) -> pool.fee_bps (configurable per pool)
/// - Total: 75 bps (0.75%)
///
/// Launch Fee Schedule (optional, for anti-snipe protection):
/// - Initial: Up to 99% (9900 bps)
/// - Decays exponentially to steady-state total over configured duration
/// - Hard cutoff: exactly steady-state once the configured duration ends
/// - Max duration: 24 hours
/// - Default duration: 15 minutes
///
/// Proportional Split Formula:
///   protocol_fee = total_fee * (steady_protocol_bps / steady_total_bps)
///   lp_fee = total_fee - protocol_fee  (LP gets remainder/rounding dust)
///
/// Example at 99% launch fee with 50:25 ratio:
///   - Total fee: 9900 bps
///   - Protocol: 9900 * 50/75 = 6600 bps (~66%)
///   - LP: 9900 * 25/75 = 3300 bps (~33%)
///
/// Note: Very small swaps (< ~134 units at 75 bps) may incur zero fees due
/// to integer division. This is acceptable as gas costs prevent dust attacks.
///
/// ============================================================================

module futarchy_markets_core::unified_spot_pool;

use futarchy_core::emergency_cap::{Self, EmergencyCap};
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationAuth};
use futarchy_markets_primitives::coin_escrow::{Self as coin_escrow, TokenEscrow};
use futarchy_markets_primitives::PCW_TWAP_oracle::{Self, SimpleTWAP};
use futarchy_markets_primitives::fee_scheduler::{Self, FeeSchedule};
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::math;
use std::string::{Self, String};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::{Self, Currency};
use sui::event;
use sui::table::{Self as table, Table};
use sui::transfer;

// === Events ===

/// Emitted when initial liquidity is added to a spot pool.
/// Provides initial price data so indexers can show prices before any swaps occur.
public struct SpotPoolInitialized has copy, drop {
    pool_id: ID,
    asset_reserve: u64,
    stable_reserve: u64,
    /// Initial price (stable/asset * 1e12)
    price: u128,
    /// LP fee in basis points (snapshot at creation)
    fee_bps: u64,
}

/// Emitted when liquidity is added to a spot pool.
/// Covers both initial and subsequent LP deposits.
public struct SpotLiquidityAdded has copy, drop {
    pool_id: ID,
    provider: address,
    asset_amount: u64,
    stable_amount: u64,
    lp_amount: u64,
    excess_asset_amount: u64,
    excess_stable_amount: u64,
    asset_reserve: u64,
    stable_reserve: u64,
    is_initial: bool,
}

/// Emitted when liquidity is removed from a spot pool.
public struct SpotLiquidityRemoved has copy, drop {
    pool_id: ID,
    provider: address,
    asset_amount: u64,
    stable_amount: u64,
    lp_amount: u64,
    asset_reserve: u64,
    stable_reserve: u64,
}

// === Errors ===
const EInsufficientLiquidity: u64 = 1;
const EInsufficientLPSupply: u64 = 3;
const EZeroAmount: u64 = 4;
const ESlippageExceeded: u64 = 5;
const EMinimumLiquidityNotMet: u64 = 6;
const ENoActiveProposal: u64 = 7;
const EAggregatorNotEnabled: u64 = 11;
const EProposalActive: u64 = 15;
const EInsufficientGapBetweenProposals: u64 = 16;
const EInvalidLPCoinSymbol: u64 = 20;
const EInvalidLPCoinName: u64 = 21;
const ELPSupplyNotZero: u64 = 22;
const EAmountTooSmall: u64 = 23; // Input amount too small to cover fees
const EInvalidFee: u64 = 24; // Fee exceeds maximum allowed
const EInvalidRatio: u64 = 25; // Ratio must be in range [0, 99]
const EInvalidThreshold: u64 = 26; // Threshold must be in range [0, 10000] bps
const EAuthTargetMismatch: u64 = 27; // Auth token target_id doesn't match pool
// Error 28 removed (emergency delay moved to EmergencyCap)
const ERegulatedCoin: u64 = 29; // LP coin must not be regulated (creator could retain DenyCapV2)
const EEscrowNotFound: u64 = 30; // No escrow exists for the requested market
const EArchivedEscrowAlreadyExists: u64 = 31; // Archived escrow key already exists
const EPoolDissolved: u64 = 32; // Pool has been dissolved; no new liquidity, swaps, or proposals
const EPoolMustShareMismatch: u64 = 33; // MustShare hot potato pool_id doesn't match pool being shared
const ELPMintOverflow: u64 = 34; // LP amount to mint overflows u64
const EEscrowNotFinalized: u64 = 35; // Escrow must be finalized before archiving
const EActiveEscrowPresent: u64 = 36; // Auth-gated extracted-escrow swap requires escrow to be extracted first

// === Constants ===
const LP_SYMBOL: vector<u8> = b"GOVEX_LP_TOKEN";
const LP_NAME: vector<u8> = b"GOVEX_LP_TOKEN";

// Standard u64 max value for gap fee calculations
const U64_MAX: u64 = 18_446_744_073_709_551_615;

// === Structs ===

/// Hot potato that enforces atomic sharing of UnifiedSpotPool.
/// Has NO abilities (no `drop`, `store`, `copy`, or `key`), so it cannot be
/// stored, transferred, or discarded - it MUST be consumed in the same transaction.
/// The `share()` function consumes this, which prevents freeze attacks by making
/// it impossible to complete a transaction without sharing the pool.
/// Carries `pool_id` to bind it to the specific pool created in `new()`.
public struct MustShare {
    pool_id: ID,
}

/// Unified spot pool with Coin-based LP tokens.
/// Now has 3 phantom types: AssetType, StableType, and LPType.
///
/// SECURITY: This struct has `key, store` abilities. Objects with `store` can be
/// frozen by the owner before being shared. The `new()` function returns a MustShare
/// hot potato that enforces atomic sharing - you cannot complete the transaction
/// without calling `share()` which consumes the MustShare.
public struct UnifiedSpotPool<
    phantom AssetType,
    phantom StableType,
    phantom LPType,
> has key, store {
    id: UID,
    // Core AMM fields
    asset_reserve: Balance<AssetType>,
    stable_reserve: Balance<StableType>,
    // Immutable snapshot of the initial liquidity amounts that established the pool's
    // starting price. Stored so on-chain consumers can read launch parameters without
    // relying on off-chain event indexing.
    //
    // Invariant: both are None (not initialized) or both are Some(...) (initialized).
    initial_asset_reserve: Option<u64>,
    initial_stable_reserve: Option<u64>,
    fee_bps: u64,
    minimum_liquidity: u64,
    // LP token management - pool owns the TreasuryCap
    lp_treasury_cap: TreasuryCap<LPType>,
    // Dynamic fee scheduling (optional, for launchpad anti-snipe)
    fee_schedule: Option<FeeSchedule>,
    fee_schedule_activation_time: u64,
    // Proposal tracking - blocks LP operations during proposals, enforces 6hr gap
    active_proposal_id: Option<ID>,
    last_proposal_end_time: Option<u64>,
    // Optional aggregator configuration
    aggregator_config: Option<AggregatorConfig<AssetType, StableType>>,
    // Dissolution flag - set when bypass_minimum dissolution occurs.
    // Blocks add_liquidity, swaps, and new proposals to prevent div-by-zero
    // and oracle manipulation on a dead pool.
    is_dissolved: bool,
}

/// Aggregator-specific configuration (only present when enabled)
public struct AggregatorConfig<phantom AssetType, phantom StableType> has store {
    active_escrow: Option<TokenEscrow<AssetType, StableType>>,
    archived_escrows: Table<ID, TokenEscrow<AssetType, StableType>>,
    simple_twap: Option<SimpleTWAP>,
    last_proposal_usage: Option<u64>,
    conditional_liquidity_ratio_percent: u64,
    oracle_conditional_threshold_bps: u64,
    spot_cumulative_at_lock: Option<u256>,
    protocol_fees_asset: Balance<AssetType>,
    protocol_fees_stable: Balance<StableType>,
}

// === Creation Functions ===

/// Create a futarchy spot pool with Coin-based LP tokens.
///
/// SECURITY: Returns a MustShare hot potato that enforces atomic sharing.
/// The caller MUST call `share()` in the same transaction to consume the MustShare,
/// which prevents freeze attacks. The MustShare has no abilities so it cannot be
/// stored, transferred, or dropped - only consumed by `share()`.
///
/// REQUIREMENTS for lp_treasury_cap:
/// - Symbol must be "GOVEX_LP_TOKEN"
/// - Name must be "GOVEX_LP_TOKEN"
/// - Total supply must be 0
public fun new<AssetType, StableType, LPType>(
    lp_treasury_cap: TreasuryCap<LPType>,
    lp_currency: &mut Currency<LPType>,
    fee_bps: u64,
    fee_schedule: Option<FeeSchedule>,
    oracle_conditional_threshold_bps: u64,
    conditional_liquidity_ratio_percent: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (UnifiedSpotPool<AssetType, StableType, LPType>, MustShare) {
    // Validate fee_bps against maximum allowed
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidFee);

    // Validate conditional liquidity ratio is in valid range [0, 99]
    // 100% would cause remove_liquidity to always fail the projected spot liquidity check
    assert!(conditional_liquidity_ratio_percent < 100, EInvalidRatio);

    // Validate oracle conditional threshold is in valid bps range [0, 10000]
    // Values > 10000 would make the conditional oracle unreachable
    assert!(oracle_conditional_threshold_bps <= 10000, EInvalidThreshold);

    assert_lp_currency_not_legacy_or_regulated(lp_currency, &lp_treasury_cap, ctx);

    // Validate LP coin metadata from Currency<T>
    let symbol: String = coin_registry::symbol(lp_currency);
    let name: String = coin_registry::name(lp_currency);

    let expected_symbol = string::utf8(LP_SYMBOL);
    let expected_name = string::utf8(LP_NAME);
    assert!(symbol == expected_symbol, EInvalidLPCoinSymbol);
    assert!(name == expected_name, EInvalidLPCoinName);

    // Validate supply is zero
    assert!(coin::total_supply(&lp_treasury_cap) == 0, ELPSupplyNotZero);

    // Oracle created lazily on first liquidity add (needs real price)
    let aggregator_config = AggregatorConfig {
        active_escrow: option::none(),
        archived_escrows: table::new(ctx),
        simple_twap: option::none(),
        last_proposal_usage: option::none(),
        conditional_liquidity_ratio_percent,
        oracle_conditional_threshold_bps,
        spot_cumulative_at_lock: option::none(),
        protocol_fees_asset: balance::zero(),
        protocol_fees_stable: balance::zero(),
    };

    let pool = UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: balance::zero(),
        stable_reserve: balance::zero(),
        initial_asset_reserve: option::none(),
        initial_stable_reserve: option::none(),
        fee_bps,
        minimum_liquidity: constants::minimum_liquidity(),
        lp_treasury_cap,
        fee_schedule,
        fee_schedule_activation_time: clock.timestamp_ms(),
        active_proposal_id: option::none(),
        last_proposal_end_time: option::none(),
        aggregator_config: option::some(aggregator_config),
        is_dissolved: false,
    };

    let pool_id = object::id(&pool);
    (pool, MustShare { pool_id })
}

/// LP coins are protocol infrastructure, unlike DAO asset coins. Fail closed:
/// reject regulated LP currencies, reject legacy-migrated currencies whose
/// regulatory state may be Unknown, and bind the Currency to the exact cap.
fun assert_lp_currency_not_legacy_or_regulated<LPType>(
    lp_currency: &mut Currency<LPType>,
    lp_treasury_cap: &TreasuryCap<LPType>,
    ctx: &mut TxContext,
) {
    assert!(!coin_registry::is_regulated(lp_currency), ERegulatedCoin);

    let (legacy_metadata, borrow) = coin_registry::borrow_legacy_metadata(lp_currency, ctx);
    coin_registry::return_borrowed_legacy_metadata(lp_currency, legacy_metadata, borrow, ctx);

    let registered_cap_id = coin_registry::treasury_cap_id(lp_currency);
    assert!(registered_cap_id.is_some(), ERegulatedCoin);
    assert!(*registered_cap_id.borrow() == object::id(lp_treasury_cap), ERegulatedCoin);
}

// === Escrow Management Functions ===

/// Store the active escrow for a proposal.
/// Requires SpotPoolMutationAuth from an authorized package (e.g., futarchy_governance)
public fun store_active_escrow<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: TokenEscrow<AssetType, StableType>,
    auth: SpotPoolMutationAuth,
) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(!pool.is_dissolved, EPoolDissolved);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);

    // If an escrow is already present:
    // - non-finalized => there is still an active proposal, reject replacement
    // - finalized => proposal is no longer active; evict stale escrow so a new one can bind
    {
        let config = pool.aggregator_config.borrow_mut();
        if (config.active_escrow.is_some()) {
            let old_escrow = option::extract(&mut config.active_escrow);
            let old_market_state = coin_escrow::get_market_state(&old_escrow);
            if (!market_state::is_finalized(old_market_state)) {
                option::fill(&mut config.active_escrow, old_escrow);
                abort EProposalActive
            };
            // Archived escrows remain wrapped under the pool (cannot be re-shared once not-new).
            let old_market_id = coin_escrow::market_state_id(&old_escrow);
            assert!(!table::contains(&config.archived_escrows, old_market_id), EArchivedEscrowAlreadyExists);
            table::add(&mut config.archived_escrows, old_market_id, old_escrow);
        };

        option::fill(&mut config.active_escrow, escrow);
    };
}

/// Archive a finalized escrow directly into archived storage.
/// Use this instead of store_active_escrow after proposal finalization so that
/// the active escrow slot remains empty and spot swaps are not blocked.
/// Redemptions still work because extract_escrow_by_market_id checks archived storage.
public fun archive_finalized_escrow<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: TokenEscrow<AssetType, StableType>,
    auth: SpotPoolMutationAuth,
) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(!pool.is_dissolved, EPoolDissolved);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    assert!(market_state::is_finalized(coin_escrow::get_market_state(&escrow)), EEscrowNotFinalized);

    let config = pool.aggregator_config.borrow_mut();
    let market_id = coin_escrow::market_state_id(&escrow);
    assert!(!table::contains(&config.archived_escrows, market_id), EArchivedEscrowAlreadyExists);
    table::add(&mut config.archived_escrows, market_id, escrow);
}

/// Extract the active escrow ID when proposal completes
/// Requires SpotPoolMutationAuth from an authorized package (e.g., futarchy_governance)
public fun extract_active_escrow<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    auth: SpotPoolMutationAuth,
): TokenEscrow<AssetType, StableType> {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    assert!(config.active_escrow.is_some(), ENoActiveProposal);
    option::extract(&mut config.active_escrow)
}

/// Extract an escrow by its MarketState ID from either active or archived storage.
/// Returns `(escrow, was_active)` where `was_active=true` iff extracted from `active_escrow`.
public fun extract_escrow_by_market_id<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    market_id: ID,
    auth: SpotPoolMutationAuth,
): (TokenEscrow<AssetType, StableType>, bool) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();

    if (config.active_escrow.is_some()) {
        let active_escrow = option::borrow(&config.active_escrow);
        if (coin_escrow::market_state_id(active_escrow) == market_id) {
            return (option::extract(&mut config.active_escrow), true)
        };
    };

    if (table::contains(&config.archived_escrows, market_id)) {
        return (table::remove(&mut config.archived_escrows, market_id), false)
    };
    abort EEscrowNotFound
}

/// Restore an escrow previously returned by `extract_escrow_by_market_id`.
public fun store_extracted_escrow<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: TokenEscrow<AssetType, StableType>,
    was_active: bool,
    auth: SpotPoolMutationAuth,
) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();

    if (was_active) {
        assert!(config.active_escrow.is_none(), EProposalActive);
        option::fill(&mut config.active_escrow, escrow);
    } else {
        // Only finalized escrows can be archived — prevents a caller from archiving
        // a live active escrow by lying about the was_active flag.
        assert!(market_state::is_finalized(coin_escrow::get_market_state(&escrow)), EEscrowNotFinalized);
        let market_id = coin_escrow::market_state_id(&escrow);
        assert!(!table::contains(&config.archived_escrows, market_id), EArchivedEscrowAlreadyExists);
        table::add(&mut config.archived_escrows, market_id, escrow);
    };
}

public fun get_active_escrow_id<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): Option<ID> {
    if (pool.aggregator_config.is_none()) {
        return option::none()
    };
    let config = pool.aggregator_config.borrow();
    if (config.active_escrow.is_some()) {
        option::some(object::id(option::borrow(&config.active_escrow)))
    } else {
        option::none()
    }
}

/// Borrow a mutable reference to the active escrow (for TWAP reads that advance the oracle).
/// Requires SpotPoolMutationAuth to prevent unauthorized access.
public fun borrow_active_escrow_mut<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    auth: &SpotPoolMutationAuth,
): &mut TokenEscrow<AssetType, StableType> {
    assert!(spot_pool_mutation_auth::target_id(auth) == object::id(pool), EAuthTargetMismatch);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    assert!(config.active_escrow.is_some(), ENoActiveProposal);
    option::borrow_mut(&mut config.active_escrow)
}

// === Core AMM Functions ===

/// Add liquidity to the pool and return LP coin with excess coins
/// Returns: (Coin<LPType>, excess_asset_coin, excess_stable_coin)
public fun add_liquidity<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    min_lp_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<LPType>, Coin<AssetType>, Coin<StableType>) {
    let asset_amount = coin::value(&asset_coin);
    let stable_amount = coin::value(&stable_coin);

    assert!(asset_amount > 0 && stable_amount > 0, EZeroAmount);
    assert!(!pool.is_dissolved, EPoolDissolved);
    assert!(pool.active_proposal_id.is_none(), EProposalActive);

    let current_supply = coin::total_supply(&pool.lp_treasury_cap);

    let (lp_amount, optimal_asset_amount, optimal_stable_amount, is_initial) = if (
        current_supply == 0
    ) {
        // Initial liquidity
        let product = (asset_amount as u128) * (stable_amount as u128);
        let initial_lp = math::safe_u128_to_u64(product.sqrt());
        // Use strict > to ensure provider receives at least 1 LP token
        // With >=, initial_lp == minimum_liquidity would result in 0 LP minted to provider
        assert!(initial_lp > pool.minimum_liquidity, EMinimumLiquidityNotMet);

        // Mint and burn minimum liquidity (locked forever)
        let min_lp_coin = coin::mint(&mut pool.lp_treasury_cap, pool.minimum_liquidity, ctx);
        transfer::public_freeze_object(min_lp_coin);

        (initial_lp - pool.minimum_liquidity, asset_amount, stable_amount, true)
    } else {
        // Proportional liquidity
        let asset_reserve = balance::value(&pool.asset_reserve);
        let stable_reserve = balance::value(&pool.stable_reserve);

        let lp_from_asset =
            (asset_amount as u128) * (current_supply as u128) / (asset_reserve as u128);
        let lp_from_stable =
            (stable_amount as u128) * (current_supply as u128) / (stable_reserve as u128);

        let lp_to_mint_u128 = lp_from_asset.min(lp_from_stable);
        assert!(lp_to_mint_u128 <= (std::u64::max_value!() as u128), ELPMintOverflow);
        let lp_to_mint = (lp_to_mint_u128 as u64);

        // Round required deposits up so minted LP is never under-collateralized by truncation.
        let optimal_asset = math::mul_div_up(lp_to_mint, asset_reserve, current_supply);
        let optimal_stable = math::mul_div_up(lp_to_mint, stable_reserve, current_supply);

        (lp_to_mint, optimal_asset, optimal_stable, false)
    };

    // Guard against dust deposits that would mint 0 LP due to truncation.
    // Without this, a caller with min_lp_out=0 could deposit tokens and receive nothing.
    assert!(lp_amount > 0, EZeroAmount);
    assert!(lp_amount >= min_lp_out, ESlippageExceeded);

    // Split coins
    let mut asset_coin_to_deposit = asset_coin;
    let mut stable_coin_to_deposit = stable_coin;

    let excess_asset = if (asset_amount > optimal_asset_amount) {
        coin::split(&mut asset_coin_to_deposit, asset_amount - optimal_asset_amount, ctx)
    } else {
        coin::zero<AssetType>(ctx)
    };

    let excess_stable = if (stable_amount > optimal_stable_amount) {
        coin::split(&mut stable_coin_to_deposit, stable_amount - optimal_stable_amount, ctx)
    } else {
        coin::zero<StableType>(ctx)
    };

    // Add to reserves
    balance::join(&mut pool.asset_reserve, coin::into_balance(asset_coin_to_deposit));
    balance::join(&mut pool.stable_reserve, coin::into_balance(stable_coin_to_deposit));

    // Emit SpotPoolInitialized event on first liquidity add
    // Also initialize oracle with real price (not 0)
    if (is_initial) {
        // Persist the initial amounts (write-once).
        if (pool.initial_asset_reserve.is_none() && pool.initial_stable_reserve.is_none()) {
            option::fill(&mut pool.initial_asset_reserve, optimal_asset_amount);
            option::fill(&mut pool.initial_stable_reserve, optimal_stable_amount);
        };

        let initial_price = math::mul_div_to_128(
            optimal_stable_amount,
            constants::price_precision_scale(),
            optimal_asset_amount,
        );

        // Create oracle JIT with real price — single source of truth
        if (pool.aggregator_config.is_some()) {
            let config = pool.aggregator_config.borrow_mut();
            if (config.simple_twap.is_none()) {
                option::fill(
                    &mut config.simple_twap,
                    PCW_TWAP_oracle::new_default(initial_price, clock),
                );
            };
        };

        // Track pool initialization time at first liquidity add (not pool creation).
        // This is used for:
        // - Launch fee schedule decay (when fee_schedule is enabled)
        // - Emergency timelocks (last-resort recovery entrypoints)
        //
        // Without this, an attacker could create+share the pool, wait for the anti-snipe
        // fee schedule to decay to steady-state, then add initial liquidity and trade
        // at low fees — defeating the anti-snipe protection entirely.
        pool.fee_schedule_activation_time = clock.timestamp_ms();

        event::emit(SpotPoolInitialized {
            pool_id: object::id(pool),
            asset_reserve: optimal_asset_amount,
            stable_reserve: optimal_stable_amount,
            price: initial_price,
            fee_bps: pool.fee_bps,
        });
    };

    // Mint LP coins
    let lp_coin = coin::mint(&mut pool.lp_treasury_cap, lp_amount, ctx);

    // Emit LP add event for indexers (includes non-initial adds).
    event::emit(SpotLiquidityAdded {
        pool_id: object::id(pool),
        provider: ctx.sender(),
        asset_amount: optimal_asset_amount,
        stable_amount: optimal_stable_amount,
        lp_amount,
        excess_asset_amount: coin::value(&excess_asset),
        excess_stable_amount: coin::value(&excess_stable),
        asset_reserve: balance::value(&pool.asset_reserve),
        stable_reserve: balance::value(&pool.stable_reserve),
        is_initial,
    });

    (lp_coin, excess_asset, excess_stable)
}

/// Remove liquidity from the pool
public fun remove_liquidity<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    lp_coin: Coin<LPType>,
    min_asset_out: u64,
    min_stable_out: u64,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    let lp_amount = coin::value(&lp_coin);
    let current_supply = coin::total_supply(&pool.lp_treasury_cap);

    assert!(lp_amount > 0, EZeroAmount);
    assert!(current_supply >= lp_amount, EInsufficientLPSupply);
    assert!(pool.active_proposal_id.is_none(), EProposalActive);

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let asset_out_u128 = (asset_reserve as u128) * (lp_amount as u128) / (current_supply as u128);
    let stable_out_u128 = (stable_reserve as u128) * (lp_amount as u128) / (current_supply as u128);

    let asset_out = math::safe_u128_to_u64(asset_out_u128);
    let stable_out = math::safe_u128_to_u64(stable_out_u128);

    assert!(asset_out >= min_asset_out, ESlippageExceeded);
    assert!(stable_out >= min_stable_out, ESlippageExceeded);

    // Burn LP coins
    coin::burn(&mut pool.lp_treasury_cap, lp_coin);

    // Return assets
    let asset_coin = coin::from_balance(
        balance::split(&mut pool.asset_reserve, asset_out),
        ctx,
    );
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, stable_out),
        ctx,
    );

    let remaining_asset = balance::value(&pool.asset_reserve);
    let remaining_stable = balance::value(&pool.stable_reserve);

    // Check minimum liquidity using sqrt(k) to match LP token units.
    // Skipped when pool is dissolved (DAO terminated) so LPs can fully exit.
    if (!pool.is_dissolved) {
        let remaining_k = (remaining_asset as u128) * (remaining_stable as u128);
        let remaining_liquidity = remaining_k.sqrt();
        assert!(remaining_liquidity >= (pool.minimum_liquidity as u128), EMinimumLiquidityNotMet);
    };

    // Emit LP remove event for indexers.
    event::emit(SpotLiquidityRemoved {
        pool_id: object::id(pool),
        provider: ctx.sender(),
        asset_amount: (asset_out as u64),
        stable_amount: (stable_out as u64),
        lp_amount,
        asset_reserve: remaining_asset,
        stable_reserve: remaining_stable,
    });

    (asset_coin, stable_coin)
}

// === Fee Calculation ===

/// Fee calculation result - all components needed for fee split
/// Calculated once per swap to avoid redundant computation
public struct FeeInfo has copy, drop {
    /// Current total fee in basis points (decays from launch to steady-state)
    current_total_bps: u64,
    /// Steady-state protocol fee share in bps (e.g., 50 = 0.5%)
    steady_protocol_bps: u64,
    /// Steady-state LP fee share in bps (e.g., 25 = 0.25%)
    steady_lp_bps: u64,
    /// Steady-state total in bps (protocol + LP, e.g., 75 = 0.75%)
    steady_total_bps: u64,
}

/// Calculate all fee components in one call
/// Returns FeeInfo with current total fee and steady-state split ratios
/// Note: Protocol fee is only applied when aggregator is enabled
fun calculate_fee_info<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
): FeeInfo {
    use futarchy_one_shot_utils::constants;

    // Protocol fee only applies when aggregator is enabled
    // Without aggregator, there's no protocol fee collection mechanism
    let has_aggregator = pool.aggregator_config.is_some();
    let steady_protocol_bps = if (has_aggregator) { constants::protocol_fee_bps() } else { 0 };
    let steady_lp_bps = pool.fee_bps;
    let steady_total_bps = steady_protocol_bps + steady_lp_bps;

    let current_total_bps = if (pool.fee_schedule.is_some()) {
        // Fee schedule decays exponentially from launch fee (99%) to steady-state TOTAL
        fee_scheduler::get_current_fee(
            pool.fee_schedule.borrow(),
            steady_total_bps,
            pool.fee_schedule_activation_time,
            clock.timestamp_ms(),
        )
    } else {
        steady_total_bps
    };

    FeeInfo {
        current_total_bps,
        steady_protocol_bps,
        steady_lp_bps,
        steady_total_bps,
    }
}

/// Split a fee amount proportionally between protocol and LPs
/// Returns (protocol_fee, lp_fee) based on steady-state ratio
fun split_fee(total_fee: u64, fee_info: &FeeInfo, has_aggregator: bool): (u64, u64) {
    use futarchy_one_shot_utils::math;

    if (!has_aggregator || fee_info.steady_total_bps == 0) {
        // No aggregator = no protocol fee, all goes to LPs
        (0, total_fee)
    } else {
        // Protocol fee = total_fee * (steady_protocol / steady_total)
        let protocol_fee = math::mul_div_to_64(
            total_fee,
            fee_info.steady_protocol_bps,
            fee_info.steady_total_bps,
        );
        // LP fee = remainder (avoids rounding dust)
        let lp_fee = total_fee - protocol_fee;
        (protocol_fee, lp_fee)
    }
}

/// Returns the current TOTAL fee in basis points (for external queries)
public fun current_fee_bps<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
): u64 {
    calculate_fee_info(pool, clock).current_total_bps
}

/// Returns the LP's share of the steady-state fee (for external queries)
public fun lp_fee_bps<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): u64 {
    pool.fee_bps
}

public fun can_create_proposals<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
): bool {
    if (pool.is_dissolved) {
        return false
    };

    // Pool must have initial liquidity before proposals can be created.
    // Without this, a proposal on an empty pool would brick add_liquidity
    // (which requires active_proposal_id.is_none()) and poison the oracle with price 0.
    if (pool.initial_asset_reserve.is_none()) {
        return false
    };

    if (pool.fee_schedule.is_some()) {
        let schedule = pool.fee_schedule.borrow();
        let current_time = clock.timestamp_ms();
        let activation_time = pool.fee_schedule_activation_time;
        let duration = fee_scheduler::duration_ms(schedule);

        let is_active = if (duration == 0) {
            false
        } else if (current_time <= activation_time) {
            true
        } else {
            let elapsed = current_time - activation_time;
            elapsed < duration
        };

        !is_active
    } else {
        true
    }
}

/// Swap stable for asset when the pool is not locked to a trading proposal.
public fun swap_stable_for_asset<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    assert!(pool.active_proposal_id.is_none(), EProposalActive);
    swap_stable_for_asset_internal(pool, stable_in, min_asset_out, clock, ctx)
}

/// Auth-gated spot swap for routing layers that have temporarily extracted escrow.
///
/// The caller is responsible for restoring the escrow and running any required
/// post-swap rebalance before returning control to the user.
public fun swap_stable_for_asset_with_escrow_extracted<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
    auth: SpotPoolMutationAuth,
): Coin<AssetType> {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(!has_active_escrow(pool), EActiveEscrowPresent);
    swap_stable_for_asset_internal(pool, stable_in, min_asset_out, clock, ctx)
}

fun swap_stable_for_asset_internal<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    mut stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    use futarchy_one_shot_utils::constants;
    use futarchy_one_shot_utils::math;

    let stable_amount = coin::value(&stable_in);
    assert!(stable_amount > 0, EZeroAmount);
    assert!(!pool.is_dissolved, EPoolDissolved);

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    // FEE MODEL: Proportional split based on steady-state ratio
    // Total fee from schedule is split: protocol gets (protocol_bps/total_bps), LP gets remainder
    // Example: 99% launch fee with 50:25 ratio → 66% protocol, 33% LP

    // Calculate all fee components once
    let fee_info = calculate_fee_info(pool, clock);

    // Calculate total fee amount
    let total_fee = math::mul_div_to_64(
        stable_amount,
        fee_info.current_total_bps,
        constants::total_fee_bps(),
    );

    // Guard against underflow on small swaps
    assert!(stable_amount > total_fee, EAmountTooSmall);

    // Split fee between protocol and LPs
    let has_aggregator = pool.aggregator_config.is_some();
    let (protocol_fee, _lp_fee) = split_fee(total_fee, &fee_info, has_aggregator);

    // Effective swap amount after all fees
    let effective_swap_amount = stable_amount - total_fee;
    let asset_out =
        (asset_reserve as u128) * (effective_swap_amount as u128) /
                    ((stable_reserve as u128) + (effective_swap_amount as u128));

    assert!((asset_out as u64) > 0, EAmountTooSmall);
    assert!((asset_out as u64) >= min_asset_out, ESlippageExceeded);
    assert!((asset_out as u64) < asset_reserve, EInsufficientLiquidity);

    // Extract protocol fee before consuming the coin
    if (has_aggregator && protocol_fee > 0) {
        let config = pool.aggregator_config.borrow_mut();
        let protocol_fee_balance = balance::split(
            coin::balance_mut(&mut stable_in),
            protocol_fee,
        );
        balance::join(&mut config.protocol_fees_stable, protocol_fee_balance);
    };

    // Remaining amount (after protocol fee) goes to reserve
    // This includes the LP fee which stays in reserve (grows k for LPs)
    balance::join(&mut pool.stable_reserve, coin::into_balance(stable_in));
    let asset_coin = coin::from_balance(
        balance::split(&mut pool.asset_reserve, (asset_out as u64)),
        ctx,
    );

    // Update oracle with post-swap price so TWAP tracks actual pool state
    if (has_aggregator) {
        let price_after = get_spot_price(pool);
        let config = pool.aggregator_config.borrow_mut();
        if (config.simple_twap.is_some()) {
            PCW_TWAP_oracle::update(config.simple_twap.borrow_mut(), price_after, clock);
        };
    };

    asset_coin
}

/// Swap asset for stable when the pool is not locked to a trading proposal.
public fun swap_asset_for_stable<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    assert!(pool.active_proposal_id.is_none(), EProposalActive);
    swap_asset_for_stable_internal(pool, asset_in, min_stable_out, clock, ctx)
}

/// Auth-gated spot swap for routing layers that have temporarily extracted escrow.
///
/// The caller is responsible for restoring the escrow and running any required
/// post-swap rebalance before returning control to the user.
public fun swap_asset_for_stable_with_escrow_extracted<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
    auth: SpotPoolMutationAuth,
): Coin<StableType> {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(!has_active_escrow(pool), EActiveEscrowPresent);
    swap_asset_for_stable_internal(pool, asset_in, min_stable_out, clock, ctx)
}

fun swap_asset_for_stable_internal<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    mut asset_in: Coin<AssetType>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    use futarchy_one_shot_utils::constants;
    use futarchy_one_shot_utils::math;

    let asset_amount = coin::value(&asset_in);
    assert!(asset_amount > 0, EZeroAmount);
    assert!(!pool.is_dissolved, EPoolDissolved);

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    // FEE MODEL: Proportional split based on steady-state ratio
    // Total fee from schedule is split: protocol gets (protocol_bps/total_bps), LP gets remainder
    // Example: 99% launch fee with 50:25 ratio → 66% protocol, 33% LP

    // Calculate all fee components once
    let fee_info = calculate_fee_info(pool, clock);

    // Calculate total fee amount
    let total_fee = math::mul_div_to_64(
        asset_amount,
        fee_info.current_total_bps,
        constants::total_fee_bps(),
    );

    // Guard against underflow on small swaps
    assert!(asset_amount > total_fee, EAmountTooSmall);

    // Split fee between protocol and LPs
    let has_aggregator = pool.aggregator_config.is_some();
    let (protocol_fee, _lp_fee) = split_fee(total_fee, &fee_info, has_aggregator);

    // Effective swap amount after all fees
    let effective_swap_amount = asset_amount - total_fee;
    let stable_out =
        (stable_reserve as u128) * (effective_swap_amount as u128) /
                     ((asset_reserve as u128) + (effective_swap_amount as u128));

    assert!((stable_out as u64) > 0, EAmountTooSmall);
    assert!((stable_out as u64) >= min_stable_out, ESlippageExceeded);
    assert!((stable_out as u64) < stable_reserve, EInsufficientLiquidity);

    // Extract protocol fee before consuming the coin
    if (has_aggregator && protocol_fee > 0) {
        let config = pool.aggregator_config.borrow_mut();
        let protocol_fee_balance = balance::split(
            coin::balance_mut(&mut asset_in),
            protocol_fee,
        );
        balance::join(&mut config.protocol_fees_asset, protocol_fee_balance);
    };

    // Remaining amount (after protocol fee) goes to reserve
    // This includes the LP fee which stays in reserve (grows k for LPs)
    balance::join(&mut pool.asset_reserve, coin::into_balance(asset_in));
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, (stable_out as u64)),
        ctx,
    );

    // Update oracle with post-swap price so TWAP tracks actual pool state
    if (has_aggregator) {
        let price_after = get_spot_price(pool);
        let config = pool.aggregator_config.borrow_mut();
        if (config.simple_twap.is_some()) {
            PCW_TWAP_oracle::update(config.simple_twap.borrow_mut(), price_after, clock);
        };
    };

    stable_coin
}

// === View Functions ===

public fun get_reserves<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): (u64, u64) {
    (balance::value(&pool.asset_reserve), balance::value(&pool.stable_reserve))
}

/// Initial liquidity amounts used to establish the pool's starting price.
/// Returns (None, None) if the pool has not yet received its first liquidity.
public fun get_initial_reserves<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): (Option<u64>, Option<u64>) {
    (pool.initial_asset_reserve, pool.initial_stable_reserve)
}

public fun lp_supply<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): u64 {
    coin::total_supply(&pool.lp_treasury_cap)
}

public fun get_spot_price<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): u128 {
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    if (asset_reserve == 0 || stable_reserve == 0) {
        return 0
    };

    (stable_reserve as u128) * constants::price_scale() / (asset_reserve as u128)
}

public fun is_aggregator_enabled<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): bool {
    pool.aggregator_config.is_some()
}

public fun has_active_escrow<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): bool {
    if (pool.aggregator_config.is_none()) {
        return false
    };
    let config = pool.aggregator_config.borrow();
    config.active_escrow.is_some()
}

/// Returns true if the pool has been dissolved (bypass_minimum dissolution has occurred).
/// A dissolved pool blocks add_liquidity, swaps, and new proposals.
public fun is_dissolved<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): bool {
    pool.is_dissolved
}

/// Returns true if there is currently an active proposal on this pool
/// This checks the active_proposal_id which is set/cleared during proposal lifecycle
public fun is_locked_for_proposal<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): bool {
    pool.active_proposal_id.is_some()
}

/// Returns the active proposal ID if one is set, or none otherwise.
public fun get_active_proposal_id<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): Option<ID> {
    pool.active_proposal_id
}

/// Returns true if this pool has ever been used for a proposal
/// This is a historical record that is never cleared
public fun has_proposal_history<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): bool {
    if (pool.aggregator_config.is_none()) {
        return false
    };
    let config = pool.aggregator_config.borrow();
    config.last_proposal_usage.is_some()
}

public fun get_conditional_liquidity_ratio_percent<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): u64 {
    if (pool.aggregator_config.is_none()) {
        return 0
    };
    let config = pool.aggregator_config.borrow();
    config.conditional_liquidity_ratio_percent
}

public fun get_oracle_conditional_threshold_bps<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): u64 {
    if (pool.aggregator_config.is_none()) {
        return 10000
    };
    let config = pool.aggregator_config.borrow();
    config.oracle_conditional_threshold_bps
}

/// Returns the TWAP cumulative snapshot taken when the current proposal was locked.
/// Needed by governance/resolution contracts to compute the TWAP delta over the voting window.
public fun get_spot_cumulative_at_lock<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): Option<u256> {
    if (pool.aggregator_config.is_none()) {
        return option::none()
    };
    let config = pool.aggregator_config.borrow();
    config.spot_cumulative_at_lock
}

public fun get_fee_bps<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): u64 {
    pool.fee_bps
}

/// Update the pool's LP fee (basis points)
/// This allows governance to adjust fees after pool creation
/// Validates against max_amm_fee_bps (5%) to prevent excessive fees
/// Requires SpotPoolMutationAuth from an authorized package (e.g., futarchy_actions)
public fun set_fee_bps<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    new_fee_bps: u64,
    auth: SpotPoolMutationAuth,
) {
    use futarchy_one_shot_utils::constants;
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(new_fee_bps <= constants::max_amm_fee_bps(), EInvalidFee);
    pool.fee_bps = new_fee_bps;
}

public fun get_pool_id<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): ID {
    object::uid_to_inner(&pool.id)
}

/// Get the last proposal end timestamp (for gap fee calculation)
/// Returns None if no proposal has ever ended on this pool
public fun get_last_proposal_end_time<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): Option<u64> {
    pool.last_proposal_end_time
}

// === Quantum Liquidity Functions ===

public(package) fun split_reserves_for_quantum<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_amount: u64,
    stable_amount: u64,
): (Balance<AssetType>, Balance<StableType>) {
    assert!(asset_amount > 0 && stable_amount > 0, EZeroAmount);

    let current_asset = balance::value(&pool.asset_reserve);
    let current_stable = balance::value(&pool.stable_reserve);
    assert!(asset_amount <= current_asset, EInsufficientLiquidity);
    assert!(stable_amount <= current_stable, EInsufficientLiquidity);

    // Enforce minimum liquidity after split to prevent the pool from operating
    // below its invariant. This guards against edge cases where LPs withdraw
    // between proposals (when conditional_liquidity_ratio_percent is 0).
    let remaining_asset = (current_asset - asset_amount as u128);
    let remaining_stable = (current_stable - stable_amount as u128);
    let remaining_liquidity = (remaining_asset * remaining_stable).sqrt();
    assert!(remaining_liquidity >= (pool.minimum_liquidity as u128), EMinimumLiquidityNotMet);

    let asset_balance = balance::split(&mut pool.asset_reserve, asset_amount);
    let stable_balance = balance::split(&mut pool.stable_reserve, stable_amount);

    (asset_balance, stable_balance)
}

public(package) fun add_liquidity_from_quantum_redeem<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset: Balance<AssetType>,
    stable: Balance<StableType>,
) {
    balance::join(&mut pool.asset_reserve, asset);
    balance::join(&mut pool.stable_reserve, stable);
}

// === Arbitrage Reserve Operations ===

public(package) fun take_stable_for_arbitrage<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    amount: u64,
): Balance<StableType> {
    assert!(amount > 0, EZeroAmount);
    assert!(balance::value(&pool.stable_reserve) >= amount, EInsufficientLiquidity);
    balance::split(&mut pool.stable_reserve, amount)
}

public(package) fun take_asset_for_arbitrage<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    amount: u64,
): Balance<AssetType> {
    assert!(amount > 0, EZeroAmount);
    assert!(balance::value(&pool.asset_reserve) >= amount, EInsufficientLiquidity);
    balance::split(&mut pool.asset_reserve, amount)
}

public(package) fun return_stable_from_arbitrage<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    stable: Balance<StableType>,
) {
    balance::join(&mut pool.stable_reserve, stable);
}

public(package) fun return_asset_from_arbitrage<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset: Balance<AssetType>,
) {
    balance::join(&mut pool.asset_reserve, asset);
}

/// Update the spot TWAP oracle after arbitrage changes reserves.
/// Must be called after all reserve mutations are complete.
public(package) fun update_twap_after_arbitrage<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
) {
    if (pool.aggregator_config.is_some()) {
        let price_after = get_spot_price(pool);
        let config = pool.aggregator_config.borrow_mut();
        if (config.simple_twap.is_some()) {
            PCW_TWAP_oracle::update(config.simple_twap.borrow_mut(), price_after, clock);
        };
    };
}

// === Proposal State Management ===

public(package) fun set_active_proposal<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    proposal_id: ID,
) {
    pool.active_proposal_id = option::some(proposal_id);
}

public(package) fun clear_active_proposal<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
) {
    pool.active_proposal_id = option::none();
    pool.last_proposal_end_time = option::some(clock.timestamp_ms());

    // Reset conditional liquidity ratio so LPs are not permanently constrained
    // by a stale ratio from the now-finished proposal.
    if (pool.aggregator_config.is_some()) {
        let config = pool.aggregator_config.borrow_mut();
        config.conditional_liquidity_ratio_percent = 0;
    };
}

/// Calculate the proposal gap fee using smooth exponential decay (half-life formula)
/// Returns u64::MAX immediately after proposal ends, decays smoothly to 0 over 12+ hours
/// Uses the shared `calculate_raw_gap_fee` function for the core math
public fun get_proposal_gap_fee<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
): u64 {
    // No previous proposal = no gap fee
    if (pool.last_proposal_end_time.is_none()) {
        return 0
    };

    let last_end = *option::borrow(&pool.last_proposal_end_time);
    let current_time = clock.timestamp_ms();

    // Shouldn't happen, but handle edge case
    if (current_time <= last_end) {
        return U64_MAX
    };

    let elapsed = current_time - last_end;

    // Use shared math function
    calculate_raw_gap_fee(elapsed)
}

/// Check proposal gap - now uses exponential decay fee
/// Blocks if gap fee is still at maximum (prevents immediate re-proposal)
public(package) fun check_proposal_gap<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
) {
    let gap_fee = get_proposal_gap_fee(pool, clock);
    // Block if fee is at maximum (no time has passed) - prevents spam
    // Once any half-life has passed, proposals are allowed (with associated fee)
    assert!(gap_fee < U64_MAX, EInsufficientGapBetweenProposals);
}

/// Pure math function: Calculate raw gap fee from elapsed time
/// This is the core calculation that can be called by SDK via devInspect
/// Returns (raw_fee, elapsed_ms) where raw_fee is 0 to U64_MAX
public fun calculate_raw_gap_fee(elapsed_ms: u64): u64 {
    // After 12 hours, fee is 0
    if (elapsed_ms >= constants::twelve_hours_ms()) {
        return 0
    };

    // Calculate number of complete half-lives elapsed and remainder
    let half_lives = elapsed_ms / constants::thirty_minutes_ms();
    let remainder = elapsed_ms % constants::thirty_minutes_ms();

    // After 63 half-lives, result is essentially 0 (avoid shift overflow)
    if (half_lives >= 63) {
        return 0
    };

    // Get fee at current step and next step
    let fee_at_step = U64_MAX >> (half_lives as u8);
    let fee_at_next = U64_MAX >> ((half_lives + 1) as u8);

    // Linear interpolate between steps for smooth curve
    let fee_drop = fee_at_step - fee_at_next;
    let decay_amount = ((fee_drop as u128) * (remainder as u128) / (constants::thirty_minutes_ms() as u128)) as u64;

    fee_at_step - decay_amount
}

/// Calculate the scaled gap fee in token units
/// Formula: raw_gap_fee * GAP_FEE_MULTIPLIER * proposal_creation_fee / U64_MAX
/// GAP_FEE_MULTIPLIER = 10000 (fee starts at 10000x proposal_creation_fee)
///
/// This function can be called by SDK via devInspect to get exact fee amount
/// Uses u256 for intermediate calculation to prevent overflow
public fun calculate_scaled_gap_fee<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    proposal_creation_fee: u64,
    clock: &Clock,
): u64 {
    let raw_fee = get_proposal_gap_fee(pool, clock);
    if (raw_fee == 0) {
        return 0
    };

    // GAP_FEE_MULTIPLIER = 10000
    // Use u256 for intermediate calculation to prevent overflow:
    // raw_fee (u64 max) * 10000 * proposal_creation_fee (u64) could exceed u128
    let multiplier: u256 = 10000;
    let result = (raw_fee as u256) * multiplier * (proposal_creation_fee as u256) / (U64_MAX as u256);
    // Saturate to U64_MAX if result exceeds u64 range
    // This can happen if proposal_creation_fee > U64_MAX / 10000
    let max_u64: u256 = (U64_MAX as u256);
    if (result > max_u64) {
        U64_MAX
    } else {
        (result as u64)
    }
}

#[test_only]
public fun reset_proposal_gap_for_testing<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
) {
    pool.last_proposal_end_time = option::none();
}

// === Aggregator Functions ===

fun assert_projected_spot_liquidity_after_split<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    conditional_liquidity_ratio_percent: u64,
) {
    if (conditional_liquidity_ratio_percent == 0) {
        return
    };

    let spot_ratio = 100 - conditional_liquidity_ratio_percent;
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let projected_spot_asset = (asset_reserve as u128) * (spot_ratio as u128) / 100u128;
    let projected_spot_stable = (stable_reserve as u128) * (spot_ratio as u128) / 100u128;
    let projected_k = projected_spot_asset * projected_spot_stable;
    let projected_liquidity = projected_k.sqrt();
    assert!(projected_liquidity >= (pool.minimum_liquidity as u128), EMinimumLiquidityNotMet);
}

/// Mark liquidity allocation for a proposal
/// Validates ratio is in valid range [0, 99] and proposal-time split feasibility.
/// Requires SpotPoolMutationAuth from an authorized package (e.g., futarchy_governance)
public fun mark_liquidity_to_proposal<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    conditional_liquidity_ratio_percent: u64,
    clock: &Clock,
    auth: SpotPoolMutationAuth,
) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(!pool.is_dissolved, EPoolDissolved);
    assert!(pool.active_proposal_id.is_none(), EProposalActive);
    // Validate ratio is in valid range [0, 99]
    // 100% would leave zero projected spot liquidity during proposal split.
    assert!(conditional_liquidity_ratio_percent < 100, EInvalidRatio);

    if (pool.aggregator_config.is_none()) {
        return
    };

    // Enforce proposal-time feasibility: after moving conditional ratio out of spot,
    // projected spot liquidity must still satisfy minimum_liquidity.
    assert_projected_spot_liquidity_after_split(pool, conditional_liquidity_ratio_percent);

    let current_price = get_spot_price(pool);
    let config = pool.aggregator_config.borrow_mut();

    if (config.simple_twap.is_some()) {
        PCW_TWAP_oracle::update(config.simple_twap.borrow_mut(), current_price, clock);

        let cumulative_at_lock = PCW_TWAP_oracle::cumulative_total(config.simple_twap.borrow());
        config.spot_cumulative_at_lock = option::some(cumulative_at_lock);
    };

    let proposal_start = clock.timestamp_ms();
    config.last_proposal_usage = option::some(proposal_start);

    config.conditional_liquidity_ratio_percent = conditional_liquidity_ratio_percent;
}

public fun is_twap_ready<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
): bool {
    if (pool.aggregator_config.is_none()) {
        return false
    };
    let config = pool.aggregator_config.borrow();
    if (config.simple_twap.is_none()) {
        return false
    };
    PCW_TWAP_oracle::is_ready(config.simple_twap.borrow(), clock)
}

public fun get_geometric_twap<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
): u128 {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow();
    assert!(config.simple_twap.is_some(), EAggregatorNotEnabled);
    let twap = config.simple_twap.borrow();
    let base_twap = PCW_TWAP_oracle::get_twap(twap);
    let long_opt = PCW_TWAP_oracle::get_ninety_day_twap(twap, clock);
    unwrap_option_with_default(long_opt, base_twap)
}

fun unwrap_option_with_default(opt: option::Option<u128>, fallback: u128): u128 {
    if (option::is_some(&opt)) {
        option::destroy_some(opt)
    } else {
        option::destroy_none(opt);
        fallback
    }
}

public fun get_simple_twap<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): &SimpleTWAP {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow();
    assert!(config.simple_twap.is_some(), EAggregatorNotEnabled);
    config.simple_twap.borrow()
}

// === Simulate Functions ===

/// Accurate swap simulation that matches actual swap behavior
/// Uses the full fee calculation including protocol fee and fee schedule decay
/// This is the recommended function for accurate swap quotes
public fun simulate_swap_asset_to_stable_accurate<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_in: u64,
    clock: &Clock,
): u64 {
    if (asset_in == 0) {
        return 0
    };

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    if (asset_reserve == 0 || stable_reserve == 0) {
        return 0
    };

    // Use actual fee calculation matching swap_asset_for_stable
    let fee_info = calculate_fee_info(pool, clock);
    let total_fee = math::mul_div_to_64(
        asset_in,
        fee_info.current_total_bps,
        constants::total_fee_bps(),
    );

    if (asset_in <= total_fee) {
        return 0
    };

    let effective_swap_amount = asset_in - total_fee;
    let stable_out =
        (stable_reserve as u128) * (effective_swap_amount as u128) /
                     ((asset_reserve as u128) + (effective_swap_amount as u128));

    if ((stable_out as u64) >= stable_reserve) {
        return 0
    };

    (stable_out as u64)
}

/// Accurate swap simulation that matches actual swap behavior
/// Uses the full fee calculation including protocol fee and fee schedule decay
/// This is the recommended function for accurate swap quotes
public fun simulate_swap_stable_to_asset_accurate<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    stable_in: u64,
    clock: &Clock,
): u64 {
    if (stable_in == 0) {
        return 0
    };

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    if (asset_reserve == 0 || stable_reserve == 0) {
        return 0
    };

    // Use actual fee calculation matching swap_stable_for_asset
    let fee_info = calculate_fee_info(pool, clock);
    let total_fee = math::mul_div_to_64(
        stable_in,
        fee_info.current_total_bps,
        constants::total_fee_bps(),
    );

    if (stable_in <= total_fee) {
        return 0
    };

    let effective_swap_amount = stable_in - total_fee;
    let asset_out =
        (asset_reserve as u128) * (effective_swap_amount as u128) /
                    ((stable_reserve as u128) + (effective_swap_amount as u128));

    if ((asset_out as u64) >= asset_reserve) {
        return 0
    };

    (asset_out as u64)
}


/// Feeless simulation: stable → asset swap using pure constant product
/// Used for arbitrage calculations where no fees apply
public fun simulate_swap_stable_to_asset_feeless<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    stable_in: u64,
): u64 {
    if (stable_in == 0) {
        return 0
    };

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    if (asset_reserve == 0 || stable_reserve == 0) {
        return 0
    };

    // No fee deduction - pure constant product
    let asset_out =
        (asset_reserve as u128) * (stable_in as u128) /
                    ((stable_reserve as u128) + (stable_in as u128));

    if ((asset_out as u64) >= asset_reserve) {
        return 0
    };

    (asset_out as u64)
}

/// Feeless simulation: asset → stable swap using pure constant product
/// Used for arbitrage calculations where no fees apply
public fun simulate_swap_asset_to_stable_feeless<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_in: u64,
): u64 {
    if (asset_in == 0) {
        return 0
    };

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    if (asset_reserve == 0 || stable_reserve == 0) {
        return 0
    };

    // No fee deduction - pure constant product
    let stable_out =
        (stable_reserve as u128) * (asset_in as u128) /
                     ((asset_reserve as u128) + (asset_in as u128));

    if ((stable_out as u64) >= stable_reserve) {
        return 0
    };

    (stable_out as u64)
}

// === Dissolution Functions ===

/// Remove liquidity during DAO dissolution
/// The bypass_minimum flag bypasses the minimum-liquidity invariant check during dissolution.
/// NOTE: a frozen minimum-LP coin still prevents full reserve drainage.
/// Requires SpotPoolMutationAuth from an authorized package
public fun remove_liquidity_for_dissolution<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    lp_coin: Coin<LPType>,
    bypass_minimum: bool,
    auth: SpotPoolMutationAuth,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    let lp_amount = coin::value(&lp_coin);
    let current_supply = coin::total_supply(&pool.lp_treasury_cap);

    assert!(lp_amount > 0, EZeroAmount);
    assert!(current_supply >= lp_amount, EInsufficientLPSupply);

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let asset_out = (asset_reserve as u128) * (lp_amount as u128) / (current_supply as u128);
    let stable_out = (stable_reserve as u128) * (lp_amount as u128) / (current_supply as u128);

    // Burn LP coins
    coin::burn(&mut pool.lp_treasury_cap, lp_coin);

    let asset_coin = coin::from_balance(
        balance::split(&mut pool.asset_reserve, (asset_out as u64)),
        ctx,
    );
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, (stable_out as u64)),
        ctx,
    );

    if (!bypass_minimum) {
        let remaining_asset = balance::value(&pool.asset_reserve);
        let remaining_stable = balance::value(&pool.stable_reserve);
        let remaining_k = (remaining_asset as u128) * (remaining_stable as u128);
        let remaining_liquidity = remaining_k.sqrt();
        assert!(remaining_liquidity >= (pool.minimum_liquidity as u128), EMinimumLiquidityNotMet);
    } else {
        pool.minimum_liquidity = 0;
        pool.is_dissolved = true;
    };

    (asset_coin, stable_coin)
}

public fun get_dao_lp_value<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    dao_owned_lp_amount: u64,
): (u64, u64) {
    let total_lp = coin::total_supply(&pool.lp_treasury_cap);
    if (total_lp == 0) {
        return (0, 0)
    };

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let asset_value = (asset_reserve as u128) * (dao_owned_lp_amount as u128) / (total_lp as u128);
    let stable_value =
        (stable_reserve as u128) * (dao_owned_lp_amount as u128) / (total_lp as u128);

    ((asset_value as u64), (stable_value as u64))
}

// === Protocol Fee Management ===

public fun withdraw_protocol_fees_asset<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    auth: SpotPoolMutationAuth,
): Balance<AssetType> {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    let amount = config.protocol_fees_asset.value();
    config.protocol_fees_asset.split(amount)
}

public fun withdraw_protocol_fees_stable<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    auth: SpotPoolMutationAuth,
): Balance<StableType> {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    let amount = config.protocol_fees_stable.value();
    config.protocol_fees_stable.split(amount)
}

public fun deposit_protocol_fees_asset<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    fee: Balance<AssetType>,
    auth: SpotPoolMutationAuth,
) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    balance::join(&mut config.protocol_fees_asset, fee);
}

public fun deposit_protocol_fees_stable<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    fee: Balance<StableType>,
    auth: SpotPoolMutationAuth,
) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(pool), EAuthTargetMismatch);
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    balance::join(&mut config.protocol_fees_stable, fee);
}

public fun get_protocol_fee_amounts<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): (u64, u64) {
    if (pool.aggregator_config.is_none()) {
        return (0, 0)
    };
    let config = pool.aggregator_config.borrow();
    (config.protocol_fees_asset.value(), config.protocol_fees_stable.value())
}

/// Timestamp used for timelocks and (when enabled) launch fee schedule decay.
/// Set at first liquidity add (initialization).
public fun get_initialized_at_ms<AssetType, StableType, LPType>(
    pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
): u64 {
    pool.fee_schedule_activation_time
}

// === Emergency Helpers ===

/// Emergency helper: withdraw reserves from a spot pool.
/// Requires an armed EmergencyCap with 7-day delay elapsed.
///
/// RESTRICTED: Requires EmergencyCap.
public fun emergency_withdraw_reserves<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_amount: u64,
    stable_amount: u64,
    cap: &EmergencyCap,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    emergency_cap::assert_ready(cap, clock);
    let available_asset = balance::value(&pool.asset_reserve);
    let available_stable = balance::value(&pool.stable_reserve);

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

    // Intentionally bypasses pool invariants. This is a last-resort rescue path.
    let asset_coin = coin::from_balance(balance::split(&mut pool.asset_reserve, withdraw_asset), ctx);
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, withdraw_stable),
        ctx,
    );
    (asset_coin, stable_coin)
}

/// Emergency helper: withdraw protocol fee balances from a spot pool.
/// Requires an armed EmergencyCap with 7-day delay elapsed.
///
/// RESTRICTED: Requires EmergencyCap.
public fun emergency_withdraw_protocol_fees<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_amount: u64,
    stable_amount: u64,
    cap: &EmergencyCap,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    emergency_cap::assert_ready(cap, clock);
    if (pool.aggregator_config.is_none()) {
        return (coin::zero<AssetType>(ctx), coin::zero<StableType>(ctx))
    };

    let config = pool.aggregator_config.borrow_mut();
    let available_asset = balance::value(&config.protocol_fees_asset);
    let available_stable = balance::value(&config.protocol_fees_stable);

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

    // Intentionally bypasses normal fee withdrawal auth. This is a last-resort rescue path.
    let asset_coin = coin::from_balance(config.protocol_fees_asset.split(withdraw_asset), ctx);
    let stable_coin = coin::from_balance(config.protocol_fees_stable.split(withdraw_stable), ctx);
    (asset_coin, stable_coin)
}

// === Sharing Function ===

/// Share the pool as a shared object.
///
/// SECURITY: This MUST be called in the same transaction as `new()`.
/// The MustShare hot potato enforces this - since MustShare has no abilities,
/// it cannot be stored or dropped, so it must be consumed by this function.
/// Failing to call share() will cause the transaction to abort.
public fun share<AssetType, StableType, LPType>(
    pool: UnifiedSpotPool<AssetType, StableType, LPType>,
    must_share: MustShare,
) {
    // Destructure to consume the hot potato and validate pool binding
    let MustShare { pool_id } = must_share;
    assert!(pool_id == object::id(&pool), EPoolMustShareMismatch);
    transfer::public_share_object(pool);
}

// === Test Functions ===

#[test_only]
public fun new_for_testing<AssetType, StableType, LPType>(
    lp_treasury_cap: TreasuryCap<LPType>,
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType, LPType> {
    use sui::clock;

    let clock = clock::create_for_testing(ctx);
    // Test oracle with 1:1 price (1e12 = price_scale)
    let simple_twap = PCW_TWAP_oracle::new_default(
        constants::price_scale(), &clock,
    );

    let aggregator_config = AggregatorConfig {
        active_escrow: option::none(),
        archived_escrows: table::new(ctx),
        simple_twap: option::some(simple_twap),
        last_proposal_usage: option::none(),
        conditional_liquidity_ratio_percent: 50,
        oracle_conditional_threshold_bps: 5000,
        spot_cumulative_at_lock: option::none(),
        protocol_fees_asset: balance::zero(),
        protocol_fees_stable: balance::zero(),
    };

    clock::destroy_for_testing(clock);

    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: balance::zero(),
        stable_reserve: balance::zero(),
        initial_asset_reserve: option::none(),
        initial_stable_reserve: option::none(),
        fee_bps,
        minimum_liquidity: constants::minimum_liquidity(),
        lp_treasury_cap,
        fee_schedule: option::none(),
        fee_schedule_activation_time: 0,
        active_proposal_id: option::none(),
        last_proposal_end_time: option::none(),
        aggregator_config: option::some(aggregator_config),
        is_dissolved: false,
    }
}

#[test_only]
/// Create a pool with a fee schedule for testing fee decay
public fun new_with_fee_schedule_for_testing<AssetType, StableType, LPType>(
    lp_treasury_cap: TreasuryCap<LPType>,
    fee_bps: u64,
    fee_schedule: FeeSchedule,
    activation_time: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType, LPType> {
    use sui::clock;

    let clock = clock::create_for_testing(ctx);
    let simple_twap = PCW_TWAP_oracle::new_default(
        constants::price_scale(), &clock,
    );

    let aggregator_config = AggregatorConfig {
        active_escrow: option::none(),
        archived_escrows: table::new(ctx),
        simple_twap: option::some(simple_twap),
        last_proposal_usage: option::none(),
        conditional_liquidity_ratio_percent: 50,
        oracle_conditional_threshold_bps: 5000,
        spot_cumulative_at_lock: option::none(),
        protocol_fees_asset: balance::zero(),
        protocol_fees_stable: balance::zero(),
    };

    clock::destroy_for_testing(clock);

    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: balance::zero(),
        stable_reserve: balance::zero(),
        initial_asset_reserve: option::none(),
        initial_stable_reserve: option::none(),
        fee_bps,
        minimum_liquidity: constants::minimum_liquidity(),
        lp_treasury_cap,
        fee_schedule: option::some(fee_schedule),
        fee_schedule_activation_time: activation_time,
        active_proposal_id: option::none(),
        last_proposal_end_time: option::none(),
        aggregator_config: option::some(aggregator_config),
        is_dissolved: false,
    }
}

/// Create a pool with aggregator enabled but oracle not yet created (simulates pre-liquidity state)
#[test_only]
public fun new_without_oracle_for_testing<AssetType, StableType, LPType>(
    lp_treasury_cap: TreasuryCap<LPType>,
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType, LPType> {
    let aggregator_config = AggregatorConfig {
        active_escrow: option::none(),
        archived_escrows: table::new(ctx),
        simple_twap: option::none(),
        last_proposal_usage: option::none(),
        conditional_liquidity_ratio_percent: 50,
        oracle_conditional_threshold_bps: 5000,
        spot_cumulative_at_lock: option::none(),
        protocol_fees_asset: balance::zero(),
        protocol_fees_stable: balance::zero(),
    };

    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: balance::zero(),
        stable_reserve: balance::zero(),
        initial_asset_reserve: option::none(),
        initial_stable_reserve: option::none(),
        fee_bps,
        minimum_liquidity: constants::minimum_liquidity(),
        lp_treasury_cap,
        fee_schedule: option::none(),
        fee_schedule_activation_time: 0,
        active_proposal_id: option::none(),
        last_proposal_end_time: option::none(),
        aggregator_config: option::some(aggregator_config),
        is_dissolved: false,
    }
}

#[test_only]
public fun create_pool_for_testing<AssetType, StableType, LPType>(
    lp_treasury_cap: TreasuryCap<LPType>,
    asset_amount: u64,
    stable_amount: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType, LPType> {
    let asset_balance = balance::create_for_testing<AssetType>(asset_amount);
    let stable_balance = balance::create_for_testing<StableType>(stable_amount);
    let initialized = asset_amount > 0 && stable_amount > 0;
    let initial_asset_reserve = if (initialized) {
        option::some(asset_amount)
    } else {
        option::none()
    };
    let initial_stable_reserve = if (initialized) {
        option::some(stable_amount)
    } else {
        option::none()
    };

    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: asset_balance,
        stable_reserve: stable_balance,
        initial_asset_reserve,
        initial_stable_reserve,
        fee_bps,
        minimum_liquidity: constants::minimum_liquidity(),
        lp_treasury_cap,
        fee_schedule: option::none(),
        fee_schedule_activation_time: 0,
        active_proposal_id: option::none(),
        last_proposal_end_time: option::none(),
        aggregator_config: option::none(),
        is_dissolved: false,
    }
}

#[test_only]
public fun destroy_for_testing<AssetType, StableType, LPType>(
    pool: UnifiedSpotPool<AssetType, StableType, LPType>,
) {
    let UnifiedSpotPool {
        id,
        asset_reserve,
        stable_reserve,
        initial_asset_reserve: _,
        initial_stable_reserve: _,
        fee_bps: _,
        minimum_liquidity: _,
        lp_treasury_cap,
        fee_schedule: _,
        fee_schedule_activation_time: _,
        active_proposal_id: _,
        last_proposal_end_time: _,
        aggregator_config,
        is_dissolved: _,
    } = pool;

    object::delete(id);
    balance::destroy_for_testing(asset_reserve);
    balance::destroy_for_testing(stable_reserve);
    sui::test_utils::destroy(lp_treasury_cap);

    if (aggregator_config.is_some()) {
        let config = option::destroy_some(aggregator_config);
        let AggregatorConfig {
            active_escrow,
            archived_escrows,
            simple_twap,
            last_proposal_usage: _,
            conditional_liquidity_ratio_percent: _,
            oracle_conditional_threshold_bps: _,
            spot_cumulative_at_lock: _,
            protocol_fees_asset,
            protocol_fees_stable,
        } = config;

        if (active_escrow.is_some()) {
            let escrow = option::destroy_some(active_escrow);
            coin_escrow::destroy_for_testing(escrow);
        } else {
            option::destroy_none(active_escrow);
        };
        sui::test_utils::destroy(archived_escrows);

        if (simple_twap.is_some()) {
            PCW_TWAP_oracle::destroy_for_testing(option::destroy_some(simple_twap));
        } else {
            option::destroy_none(simple_twap);
        };
        balance::destroy_for_testing(protocol_fees_asset);
        balance::destroy_for_testing(protocol_fees_stable);
    } else {
        option::destroy_none(aggregator_config);
    };
}

#[test_only]
public fun create_for_testing<AssetType, StableType, LPType>(
    lp_treasury_cap: TreasuryCap<LPType>,
    asset_balance: Balance<AssetType>,
    stable_balance: Balance<StableType>,
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType, LPType> {
    let initial_asset = balance::value(&asset_balance);
    let initial_stable = balance::value(&stable_balance);
    let initialized = initial_asset > 0 && initial_stable > 0;
    let initial_asset_reserve = if (initialized) {
        option::some(initial_asset)
    } else {
        option::none()
    };
    let initial_stable_reserve = if (initialized) {
        option::some(initial_stable)
    } else {
        option::none()
    };
    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: asset_balance,
        stable_reserve: stable_balance,
        initial_asset_reserve,
        initial_stable_reserve,
        fee_bps,
        minimum_liquidity: constants::minimum_liquidity(),
        lp_treasury_cap,
        fee_schedule: option::none(),
        fee_schedule_activation_time: 0,
        active_proposal_id: option::none(),
        last_proposal_end_time: option::none(),
        aggregator_config: option::none(),
        is_dissolved: false,
    }
}

#[test_only]
/// Set the active escrow ID for testing security validations.
/// This allows testing scenarios where spot_pool and escrow are mismatched.
public fun set_active_escrow_for_testing<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: TokenEscrow<AssetType, StableType>,
) {
    let config = pool.aggregator_config.borrow_mut();
    if (config.active_escrow.is_some()) {
        let old = option::swap(&mut config.active_escrow, escrow);
        coin_escrow::destroy_for_testing(old);
    } else {
        option::fill(&mut config.active_escrow, escrow);
    };
}

#[test_only]
public fun set_active_proposal_for_testing<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    proposal_id: ID,
) {
    pool.active_proposal_id = option::some(proposal_id);
}

#[test_only]
public fun clear_active_proposal_for_testing<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
) {
    pool.active_proposal_id = option::none();
}

#[test_only]
/// Add liquidity to a pool for testing purposes.
/// Used when pool was created with new_for_testing (which has aggregator_config but no reserves).
public fun add_liquidity_for_testing<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_balance: Balance<AssetType>,
    stable_balance: Balance<StableType>,
) {
    let asset_amount = balance::value(&asset_balance);
    let stable_amount = balance::value(&stable_balance);
    let is_initial = pool.initial_asset_reserve.is_none()
        && pool.initial_stable_reserve.is_none()
        && balance::value(&pool.asset_reserve) == 0
        && balance::value(&pool.stable_reserve) == 0;
    balance::join(&mut pool.asset_reserve, asset_balance);
    balance::join(&mut pool.stable_reserve, stable_balance);
    if (is_initial && asset_amount > 0 && stable_amount > 0) {
        option::fill(&mut pool.initial_asset_reserve, asset_amount);
        option::fill(&mut pool.initial_stable_reserve, stable_amount);
    };
}
