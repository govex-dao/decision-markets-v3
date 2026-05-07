// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Protective Bid Module - NAV Floor
///
/// Creates a price floor for launchpad tokens using a NAV calculation.
/// NAV is calculated at sell time based on:
/// - DAO treasury stable balance (across all vaults, including bid funds)
/// - DAO AMM principal:
///   - If the bid has an explicit principal override, use it.
///   - Otherwise, use the pool's write-once initial reserves.
///   - Swap-driven live reserve changes are intentionally ignored.
///
/// IMPORTANT:
///   If the DAO later adds/removes its own AMM liquidity, the bid's DAO AMM
///   principal contribution is not updated automatically. Governance must keep
///   that contribution in sync, e.g. by closing/recreating the bid with an
///   explicit principal override around DAO LP changes.
///
/// ══════════════════════════════════════════════════════════════════════════
///                      PRINCIPAL NAV MODEL
/// ══════════════════════════════════════════════════════════════════════════
///
/// NAV = (dao_amm_stable + treasury_stable) / circulating
///
/// Where:
///   - total_supply: From TreasuryCap (total minted tokens)
///   - dao_vault_tokens: DAO's RaiseToken balance across all vaults
///   - dao_amm_tokens: DAO principal RaiseToken deposited as AMM liquidity
///   - dao_amm_stable: DAO principal StableCoin deposited as AMM liquidity
///   - treasury_stable: DAO's StableCoin balance across ALL vaults (bid funds stay in vault)
///
/// CIRCULATING SUPPLY (denominator):
///   circulating = total_supply - dao_vault_tokens - dao_amm_tokens
///
/// TOTAL BACKING (numerator):
///   backing = dao_amm_stable + treasury_stable
///   (Bid funds are in a DAO vault, so they're included in treasury_stable)
///
/// DISCOUNT:
///   discounted_backing = total_backing * (10000 - nav_discount_bps) / 10000
///   gross_stable = token_amount * discounted_backing / circulating
///
/// VAULT-BACKED DESIGN:
///   Bid funds stay in a DAO vault. The bid holds a VaultAdminCap that
///   authorizes per-sell withdrawals. This ensures NAV is consistent
///   between bids and asks (both see the same treasury_stable).
///
/// ══════════════════════════════════════════════════════════════════════════
///                         sell_to_bid FLOW
/// ══════════════════════════════════════════════════════════════════════════
///
/// 1. Check DAO not terminated
/// 2. BLOCK if proposals are active (is_locked_for_proposal)
/// 3. Calculate circulating: total_supply - dao_vault_tokens - dao_amm_tokens
/// 4. Calculate backing: dao_amm_stable + treasury_stable
/// 5. Apply nav_discount_bps to get discounted_backing
/// 6. gross_stable = tokens × discounted_backing / circulating
/// 7. Apply fee → stable_out
/// 8. Check gross_stable <= bid.reserved_amount
/// 9. Decrement reserved_amount by gross_stable
/// 10. Withdraw stable_out from vault via admin cap
/// 11. BURN tokens immediately
/// 12. Pay seller
///
/// ══════════════════════════════════════════════════════════════════════════

module futarchy_markets_core::protective_bid;

use account_actions::currency;
use account_actions::vault::{Self, VaultAdminCap};
use account_protocol::account::{Self, Account};
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::emergency_cap::{Self, EmergencyCap};
use futarchy_core::futarchy_config;
use futarchy_markets_core::protective_bid_registry;
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationAuth};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_one_shot_utils::constants;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;

// === Errors ===

const EInsufficientReserved: u64 = 1;
const EBidInactive: u64 = 2;
const EDeadlineNotReached: u64 = 3;
const EZeroAmount: u64 = 5;
const EWrongAccount: u64 = 7;
const EZeroCirculatingSupply: u64 = 8;
const EFeeTooHigh: u64 = 9;
const EZeroOutput: u64 = 10;
const ECirculatingSupplyUnderflow: u64 = 11;
const EBidWallDepleted: u64 = 13;
const EBidWallExpired: u64 = 14;
const EProposalActive: u64 = 15;
const EPoolMismatch: u64 = 16;
const EInvalidSupplyState: u64 = 17;
const ENoInitialReserves: u64 = 19;
const EInvalidPrincipalOverride: u64 = 20;
const EAuthTargetMismatch: u64 = 22;
const ENoPermissionlessClose: u64 = 23;
const ENavDiscountTooHigh: u64 = 24;
const ECapAlreadyExtracted: u64 = 26;

const MAX_U64_AS_U128: u128 = 18_446_744_073_709_551_615;

// === Structs ===

/// Protective bid with NAV price floor.
/// NAV calculated at sell time from: AMM principal + treasury balances.
/// Bid funds stay in a DAO vault; VaultAdminCap authorizes per-sell withdrawals.
public struct ProtectiveBid<phantom RaiseToken, phantom StableCoin> has key, store {
    id: UID,
    /// ID of the DAO account (for treasury reads and burns)
    account_id: ID,
    /// ID of the AMM pool (for validation)
    pool_id: ID,
    /// Optional override for DAO AMM principal used in NAV calculation.
    /// If None, NAV uses the pool's write-once initial reserves.
    dao_amm_asset_principal: Option<u64>,
    dao_amm_stable_principal: Option<u64>,
    /// === FEE CONFIGURATION (optional surge/decay) ===
    /// Base fee in basis points (final fee after surge ends, max 20%)
    base_fee_bps: u64,
    /// Starting fee in basis points (0 = no surge, use base_fee_bps)
    surge_fee_bps: u64,
    /// Timestamp when surge ends (0 = no surge, use base_fee_bps)
    surge_end_ms: u64,
    /// Creation timestamp (used to calculate decay)
    created_at_ms: u64,
    /// === VAULT-BACKED FIELDS ===
    /// Cap for withdrawing from DAO vault (None after deactivation)
    vault_admin_cap: Option<VaultAdminCap>,
    /// Soft spending limit — decrements on each sell by gross_stable (pre-fee).
    /// Deliberately not a segregated balance: the backing vault remains flexible DAO
    /// capital and may diverge from this counter if governance spends that vault.
    reserved_amount: u64,
    /// NAV discount in basis points (0 = at NAV, 500 = 5% below NAV)
    nav_discount_bps: u64,
    /// === TRACKING ===
    /// Tokens bought back by bid wall (tracked for events/stats)
    base_bought_amount: u64,
    /// Fees collected (fees stay in vault as surplus, not extracted)
    fees_collected: u64,
    /// Event sequence number
    seq_num: u64,
    /// Timestamp when bid can be closed permissionlessly (0 = never)
    release_deadline_ms: u64,
    /// Whether bid is still active
    active: bool,
    /// === SNAPSHOT VALUES (for unit testing only) ===
    snapshot_backing: u64,
    snapshot_circulating: u64,
}

// === Events ===

public struct ProtectiveBidCreated has copy, drop {
    bid_id: ID,
    account_id: ID,
    pool_id: ID,
    base_fee_bps: u64,
    surge_fee_bps: u64,
    surge_end_ms: u64,
    reserved_amount: u64,
    nav_discount_bps: u64,
    release_deadline_ms: u64,
}

public struct TokensSoldToBid has copy, drop {
    bid_id: ID,
    seller: address,
    tokens_sold: u64,
    stable_received: u64,
    fee_amount: u64,
    nav_at_sale: u64,
    post_reserved_amount: u64,
    post_base_bought_amount: u64,
    seq_num: u64,
}

public struct BidReleased has copy, drop {
    bid_id: ID,
    final_reserved_amount: u64,
    final_base_bought: u64,
    final_fees_collected: u64,
}

// === Public Functions ===

/// Create a new protective bid (vault-backed).
///
/// The bid holds a VaultAdminCap that authorizes withdrawals from a DAO vault.
/// `reserved_amount` is a soft spending limit (not a balance transfer).
/// Deliberately, the backing vault is not escrowed or locked to this amount:
/// the DAO keeps that capital liquid/flexible, and live vault balance is enforced
/// separately at payout time.
/// `nav_discount_bps` sets price below NAV (0 = at NAV, 500 = 5% below).
///
/// FEE PARAMETERS:
///   - base_fee_bps: Final fee after surge period ends (max 20%)
///   - surge_fee_bps: Starting elevated fee (0 = no surge)
///   - surge_duration_ms: How long surge lasts (0 = no surge)
public fun create<RaiseToken, StableCoin>(
    account_id: ID,
    pool_id: ID,
    base_fee_bps: u64,
    surge_fee_bps: u64,
    surge_duration_ms: u64,
    release_duration_ms: u64,
    vault_admin_cap: VaultAdminCap,
    reserved_amount: u64,
    nav_discount_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ProtectiveBid<RaiseToken, StableCoin> {
    // Validate inputs
    assert!(base_fee_bps <= constants::max_protective_bid_fee_bps(), EFeeTooHigh);
    assert!(surge_fee_bps <= constants::max_protective_bid_fee_bps(), EFeeTooHigh);
    assert!(nav_discount_bps < 10000, ENavDiscountTooHigh);
    if (surge_fee_bps > 0) {
        assert!(surge_fee_bps >= base_fee_bps, EFeeTooHigh);
    };

    let now = clock.timestamp_ms();
    let release_deadline_ms = if (release_duration_ms == 0) { 0 } else { now + release_duration_ms };

    let surge_end_ms = if (surge_fee_bps == 0 || surge_duration_ms == 0) {
        0
    } else {
        now + surge_duration_ms
    };

    let bid = ProtectiveBid {
        id: object::new(ctx),
        account_id,
        pool_id,
        dao_amm_asset_principal: option::none(),
        dao_amm_stable_principal: option::none(),
        base_fee_bps,
        surge_fee_bps,
        surge_end_ms,
        created_at_ms: now,
        vault_admin_cap: option::some(vault_admin_cap),
        reserved_amount,
        nav_discount_bps,
        base_bought_amount: 0,
        fees_collected: 0,
        seq_num: 0,
        release_deadline_ms,
        active: true,
        snapshot_backing: 0,
        snapshot_circulating: 0,
    };

    event::emit(ProtectiveBidCreated {
        bid_id: object::id(&bid),
        account_id,
        pool_id,
        base_fee_bps,
        surge_fee_bps,
        surge_end_ms,
        reserved_amount,
        nav_discount_bps,
        release_deadline_ms,
    });

    bid
}

/// Create a new protective bid with an explicit DAO AMM principal override.
public fun create_with_principal<RaiseToken, StableCoin>(
    account_id: ID,
    pool_id: ID,
    base_fee_bps: u64,
    surge_fee_bps: u64,
    surge_duration_ms: u64,
    release_duration_ms: u64,
    dao_amm_asset_principal: u64,
    dao_amm_stable_principal: u64,
    vault_admin_cap: VaultAdminCap,
    reserved_amount: u64,
    nav_discount_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ProtectiveBid<RaiseToken, StableCoin> {
    assert!(base_fee_bps <= constants::max_protective_bid_fee_bps(), EFeeTooHigh);
    assert!(surge_fee_bps <= constants::max_protective_bid_fee_bps(), EFeeTooHigh);
    assert!(nav_discount_bps < 10000, ENavDiscountTooHigh);
    if (surge_fee_bps > 0) {
        assert!(surge_fee_bps >= base_fee_bps, EFeeTooHigh);
    };

    let now = clock.timestamp_ms();
    let release_deadline_ms = if (release_duration_ms == 0) { 0 } else { now + release_duration_ms };

    let surge_end_ms = if (surge_fee_bps == 0 || surge_duration_ms == 0) {
        0
    } else {
        now + surge_duration_ms
    };

    let bid = ProtectiveBid {
        id: object::new(ctx),
        account_id,
        pool_id,
        dao_amm_asset_principal: option::some(dao_amm_asset_principal),
        dao_amm_stable_principal: option::some(dao_amm_stable_principal),
        base_fee_bps,
        surge_fee_bps,
        surge_end_ms,
        created_at_ms: now,
        vault_admin_cap: option::some(vault_admin_cap),
        reserved_amount,
        nav_discount_bps,
        base_bought_amount: 0,
        fees_collected: 0,
        seq_num: 0,
        release_deadline_ms,
        active: true,
        snapshot_backing: 0,
        snapshot_circulating: 0,
    };

    event::emit(ProtectiveBidCreated {
        bid_id: object::id(&bid),
        account_id,
        pool_id,
        base_fee_bps,
        surge_fee_bps,
        surge_end_ms,
        reserved_amount,
        nav_discount_bps,
        release_deadline_ms,
    });

    bid
}

/// Resolve the DAO AMM principal amounts to use for NAV.
///
/// The default initial-reserve path pins AMM principal against swap-driven
/// reserve movement. It does not track later DAO LP add/remove actions.
fun dao_amm_principal_for_nav<RT, SC, LPType>(
    bid: &ProtectiveBid<RT, SC>,
    pool: &UnifiedSpotPool<RT, SC, LPType>,
): (u64, u64) {
    if (bid.dao_amm_asset_principal.is_some() || bid.dao_amm_stable_principal.is_some()) {
        assert!(
            bid.dao_amm_asset_principal.is_some() && bid.dao_amm_stable_principal.is_some(),
            EInvalidPrincipalOverride,
        );
        return (*bid.dao_amm_asset_principal.borrow(), *bid.dao_amm_stable_principal.borrow())
    };

    let (asset_opt, stable_opt) = unified_spot_pool::get_initial_reserves(pool);
    assert!(asset_opt.is_some() && stable_opt.is_some(), ENoInitialReserves);
    (*asset_opt.borrow(), *stable_opt.borrow())
}

/// Sell tokens to the protective bid at discounted NAV price.
///
/// REQUIRES:
/// - DAO must NOT be terminated
/// - Proposals must NOT be active (pump-and-dump protection)
/// - Pool for validation + initial-reserve principal (or bid principal override)
/// - Account to burn tokens and read treasury balances
///
/// NAV = (dao_amm_stable + treasury_stable) / circulating
/// discounted_backing = total_backing * (10000 - nav_discount_bps) / 10000
/// gross_stable = token_amount * discounted_backing / circulating
///
/// Tokens are burned immediately. Stable paid from vault via admin cap.
public fun sell_to_bid<Config: store, RaiseToken: drop, StableCoin, LPType>(
    bid: &mut ProtectiveBid<RaiseToken, StableCoin>,
    account: &mut Account,
    registry: &PackageRegistry,
    pool: &UnifiedSpotPool<RaiseToken, StableCoin, LPType>,
    tokens: Coin<RaiseToken>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableCoin> {
    // Check DAO not terminated
    let config: &futarchy_config::FutarchyConfig = account::config(account);
    futarchy_config::assert_not_terminated(futarchy_config::dao_state(config));

    // Validate bid state
    assert!(bid.active, EBidInactive);
    assert!(object::id(account) == bid.account_id, EWrongAccount);
    assert!(object::id(pool) == bid.pool_id, EPoolMismatch);

    // PUMP-AND-DUMP PROTECTION: Block sells during active proposals
    assert!(!unified_spot_pool::is_locked_for_proposal(pool), EProposalActive);

    // Only allow selling if bid hasn't expired (0 = no expiry)
    if (bid.release_deadline_ms > 0) {
        assert!(clock.timestamp_ms() < bid.release_deadline_ms, EBidWallExpired);
    };

    // Can't sell if reserved amount is depleted
    assert!(bid.reserved_amount > 0, EBidWallDepleted);

    let token_amount = tokens.value();
    assert!(token_amount > 0, EZeroAmount);

    // === CALCULATE CIRCULATING SUPPLY (denominator) ===
    let total_supply = currency::coin_type_supply<RaiseToken>(account, registry);
    let dao_vault_tokens = vault::get_total_balance<Config, RaiseToken>(account, registry);
    let (dao_amm_tokens, dao_amm_stable) = dao_amm_principal_for_nav(bid, pool);

    let dao_owned = (dao_vault_tokens as u128) + (dao_amm_tokens as u128);
    assert!((total_supply as u128) >= dao_owned, EInvalidSupplyState);
    let circulating = total_supply - dao_vault_tokens - dao_amm_tokens;
    assert!(circulating > 0, EZeroCirculatingSupply);
    assert!(token_amount <= circulating, ECirculatingSupplyUnderflow);

    // === CALCULATE TOTAL BACKING (numerator) ===
    // Bid funds are in a DAO vault, so treasury_stable already includes them
    let treasury_stable = vault::get_total_balance<Config, StableCoin>(account, registry);
    let total_backing: u128 =
        (dao_amm_stable as u128)
        + (treasury_stable as u128);

    // === APPLY NAV DISCOUNT ===
    let discounted_backing = if (bid.nav_discount_bps == 0) {
        total_backing
    } else {
        total_backing * ((10000 - bid.nav_discount_bps) as u128) / 10000
    };

    // === CALCULATE STABLE OUTPUT ===
    let gross_stable_u256 = (token_amount as u256) * (discounted_backing as u256) / (circulating as u256);
    assert!(gross_stable_u256 <= (bid.reserved_amount as u256), EInsufficientReserved);
    let gross_stable = (gross_stable_u256 as u64);

    // Apply fee
    let current_fee = current_fee_bps_at(bid, clock.timestamp_ms());
    let fee_amount = (((gross_stable as u128) * (current_fee as u128)) / 10000u128) as u64;
    let stable_out = gross_stable - fee_amount;
    assert!(stable_out > 0, EZeroOutput);

    // BURN tokens immediately (reduces total_supply for future NAV calculations)
    currency::public_burn<RaiseToken>(account, registry, tokens);

    // Update state — reserved_amount decrements by gross_stable (pre-fee)
    // Fees stay in vault as surplus
    bid.reserved_amount = bid.reserved_amount - gross_stable;
    bid.fees_collected = bid.fees_collected + fee_amount;
    bid.base_bought_amount = bid.base_bought_amount + token_amount;
    bid.seq_num = bid.seq_num + 1;

    // NAV scaled to 1e12 precision (saturate to u64::MAX for low-decimal tokens with large backing)
    let nav_u256 = (total_backing as u256) * (constants::price_precision_scale() as u256) / (circulating as u256);
    let nav_at_sale = if (nav_u256 > (MAX_U64_AS_U128 as u256)) { (MAX_U64_AS_U128 as u64) } else { (nav_u256 as u64) };

    // Deliberate design: reserved_amount is a soft limit, while payout comes
    // from the live DAO vault balance so the capital remains flexible/liquid.
    let cap = bid.vault_admin_cap.borrow();
    let stable_coin = vault::withdraw_with_admin_cap<Config, StableCoin>(
        account, registry, cap, stable_out, ctx,
    );

    event::emit(TokensSoldToBid {
        bid_id: object::id(bid),
        seller: ctx.sender(),
        tokens_sold: token_amount,
        stable_received: stable_out,
        fee_amount,
        nav_at_sale,
        post_reserved_amount: bid.reserved_amount,
        post_base_bought_amount: bid.base_bought_amount,
        seq_num: bid.seq_num,
    });

    stable_coin
}

/// Close the bid wall permissionlessly after deadline.
/// Funds stay in vault — just deactivates and destroys the cap.
public fun close<RaiseToken, StableCoin>(
    bid: &mut ProtectiveBid<RaiseToken, StableCoin>,
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
) {
    assert!(bid.active, EBidInactive);
    assert!(bid.release_deadline_ms > 0, ENoPermissionlessClose);
    assert!(clock.timestamp_ms() >= bid.release_deadline_ms, EDeadlineNotReached);
    assert!(object::id(account) == bid.account_id, EWrongAccount);

    deactivate_internal<RaiseToken, StableCoin>(bid, account, registry);
}

/// Cancel the bid wall via governance.
/// Funds stay in vault — just deactivates, destroys the cap, and clears registry.
/// SECURITY: Requires SpotPoolMutationAuth from an authorized package.
public fun cancel<RaiseToken, StableCoin>(
    bid: &mut ProtectiveBid<RaiseToken, StableCoin>,
    account: &mut Account,
    registry: &PackageRegistry,
    auth: SpotPoolMutationAuth,
) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == bid.pool_id, EAuthTargetMismatch);
    assert!(bid.active, EBidInactive);
    assert!(object::id(account) == bid.account_id, EWrongAccount);

    deactivate_internal<RaiseToken, StableCoin>(bid, account, registry);
}

/// Internal deactivation logic shared by close and cancel.
/// Extracts and destroys the VaultAdminCap, clears registry, emits event.
fun deactivate_internal<RaiseToken, StableCoin>(
    bid: &mut ProtectiveBid<RaiseToken, StableCoin>,
    account: &mut Account,
    registry: &PackageRegistry,
) {
    // Extract and destroy the VaultAdminCap
    assert!(bid.vault_admin_cap.is_some(), ECapAlreadyExtracted);
    let cap = bid.vault_admin_cap.extract();
    vault::destroy_vault_admin_cap(cap);

    bid.active = false;

    // Clear registry so a new protective bid can be created
    protective_bid_registry::clear_with_package_witness(account, registry, object::id(bid));

    event::emit(BidReleased {
        bid_id: object::id(bid),
        final_reserved_amount: bid.reserved_amount,
        final_base_bought: bid.base_bought_amount,
        final_fees_collected: bid.fees_collected,
    });
}

// === Emergency Functions ===

/// Emergency deactivate: extract and destroy the VaultAdminCap.
/// Requires EmergencyCap. Funds stay in vault for emergency recovery.
/// Clears registry so the DAO's bid-wall slot is freed for reuse.
public fun emergency_deactivate<RaiseToken, StableCoin>(
    bid: &mut ProtectiveBid<RaiseToken, StableCoin>,
    account: &mut Account,
    registry: &PackageRegistry,
    cap: &EmergencyCap,
    clock: &Clock,
) {
    emergency_cap::assert_ready(cap, clock);
    assert!(object::id(account) == bid.account_id, EWrongAccount);
    if (bid.vault_admin_cap.is_some()) {
        let admin_cap = bid.vault_admin_cap.extract();
        vault::destroy_vault_admin_cap(admin_cap);
    };
    bid.active = false;

    // Clear registry so a new protective bid can be created (M-9 fix)
    protective_bid_registry::clear_with_package_witness(account, registry, object::id(bid));
}

// === View Functions ===

/// Calculate current NAV (without discount) using DAO-recorded AMM principal.
/// NAV = (dao_amm_stable + treasury_stable) / circulating
public fun calculate_nav<Config: store, RT, SC, LPType>(
    bid: &ProtectiveBid<RT, SC>,
    account: &Account,
    registry: &PackageRegistry,
    pool: &UnifiedSpotPool<RT, SC, LPType>,
): u64 {
    if (object::id(account) != bid.account_id) return 0;
    if (object::id(pool) != bid.pool_id) return 0;

    let total_supply = currency::coin_type_supply<RT>(account, registry);
    let dao_vault_tokens = vault::get_total_balance<Config, RT>(account, registry);
    let (dao_amm_tokens, dao_amm_stable) = dao_amm_principal_for_nav(bid, pool);

    let dao_owned = (dao_vault_tokens as u128) + (dao_amm_tokens as u128);
    if ((total_supply as u128) < dao_owned) return 0;
    let circulating = total_supply - dao_vault_tokens - dao_amm_tokens;
    if (circulating == 0) return 0;

    let treasury_stable = vault::get_total_balance<Config, SC>(account, registry);
    let total_backing: u128 =
        (dao_amm_stable as u128)
        + (treasury_stable as u128);

    let nav_u256 = (total_backing as u256) * (constants::price_precision_scale() as u256) / (circulating as u256);
    if (nav_u256 > (MAX_U64_AS_U128 as u256)) { (MAX_U64_AS_U128 as u64) } else { (nav_u256 as u64) }
}

/// Quote how much stable you'd get for selling tokens (includes discount + fee).
/// Deliberately uses `reserved_amount` as the soft budget, not the live vault
/// balance, so quotes track intended bid capacity while the backing capital
/// remains flexible inside the DAO vault.
public fun quote_sell<Config: store, RT, SC, LPType>(
    bid: &ProtectiveBid<RT, SC>,
    account: &Account,
    registry: &PackageRegistry,
    pool: &UnifiedSpotPool<RT, SC, LPType>,
    token_amount: u64,
    clock: &Clock,
): u64 {
    if (!bid.active) return 0;
    if (token_amount == 0) return 0;
    if (bid.reserved_amount == 0) return 0;

    if (bid.release_deadline_ms > 0 && clock.timestamp_ms() >= bid.release_deadline_ms) return 0;

    if (object::id(account) != bid.account_id) return 0;
    if (object::id(pool) != bid.pool_id) return 0;

    if (unified_spot_pool::is_locked_for_proposal(pool)) return 0;

    let total_supply = currency::coin_type_supply<RT>(account, registry);
    let dao_vault_tokens = vault::get_total_balance<Config, RT>(account, registry);
    let (dao_amm_tokens, dao_amm_stable) = dao_amm_principal_for_nav(bid, pool);

    let dao_owned = (dao_vault_tokens as u128) + (dao_amm_tokens as u128);
    if ((total_supply as u128) < dao_owned) return 0;
    let circulating = total_supply - dao_vault_tokens - dao_amm_tokens;
    if (circulating == 0) return 0;

    let treasury_stable = vault::get_total_balance<Config, SC>(account, registry);
    let total_backing: u128 =
        (dao_amm_stable as u128)
        + (treasury_stable as u128);

    let discounted_backing = if (bid.nav_discount_bps == 0) {
        total_backing
    } else {
        total_backing * ((10000 - bid.nav_discount_bps) as u128) / 10000
    };

    let gross_stable_u256 = (token_amount as u256) * (discounted_backing as u256) / (circulating as u256);
    if (gross_stable_u256 > (bid.reserved_amount as u256)) return 0;
    let gross_stable = (gross_stable_u256 as u64);

    let current_fee = current_fee_bps_at(bid, clock.timestamp_ms());
    let fee_amount = (((gross_stable as u128) * (current_fee as u128)) / 10000u128) as u64;
    if (gross_stable > fee_amount) { gross_stable - fee_amount } else { 0 }
}

/// Get remaining reserved amount
public fun reserved_amount<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.reserved_amount
}

/// Get NAV discount in basis points
public fun nav_discount_bps<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.nav_discount_bps
}

/// Get pool ID
public fun pool_id<RT, SC>(bid: &ProtectiveBid<RT, SC>): ID {
    bid.pool_id
}

/// Get base bought amount (tokens bought back / burned)
public fun base_bought_amount<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.base_bought_amount
}

/// Get base fee in basis points
public fun base_fee_bps<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.base_fee_bps
}

/// Get surge fee in basis points
public fun surge_fee_bps<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.surge_fee_bps
}

/// Get surge end timestamp
public fun surge_end_ms<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.surge_end_ms
}

/// Get creation timestamp
public fun created_at_ms<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.created_at_ms
}

/// Calculate current fee in basis points
fun current_fee_bps_at<RT, SC>(bid: &ProtectiveBid<RT, SC>, now_ms: u64): u64 {
    if (bid.surge_end_ms == 0 || bid.surge_fee_bps == 0) {
        return bid.base_fee_bps
    };

    if (now_ms >= bid.surge_end_ms) {
        return bid.base_fee_bps
    };

    let remaining_ms = bid.surge_end_ms - now_ms;
    let total_duration_ms = bid.surge_end_ms - bid.created_at_ms;

    if (total_duration_ms == 0) {
        return bid.base_fee_bps
    };

    let decay_amount = if (bid.surge_fee_bps > bid.base_fee_bps) {
        let diff = bid.surge_fee_bps - bid.base_fee_bps;
        ((diff as u128) * (remaining_ms as u128) / (total_duration_ms as u128)) as u64
    } else {
        0
    };

    bid.base_fee_bps + decay_amount
}

/// Get current fee in basis points
public fun current_fee_bps<RT, SC>(bid: &ProtectiveBid<RT, SC>, clock: &Clock): u64 {
    current_fee_bps_at(bid, clock.timestamp_ms())
}

/// Get fees collected
public fun fees_collected<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.fees_collected
}

/// Get sequence number
public fun seq_num<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.seq_num
}

/// Get release deadline
public fun release_deadline_ms<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.release_deadline_ms
}

/// Check if active
public fun is_active<RT, SC>(bid: &ProtectiveBid<RT, SC>): bool {
    bid.active
}

/// Get account ID
public fun account_id<RT, SC>(bid: &ProtectiveBid<RT, SC>): ID {
    bid.account_id
}

/// Get the precision constant
public fun precision(): u64 {
    constants::price_precision_scale()
}

// === Test Functions ===

/// Create for testing with snapshot values for unit tests.
/// Uses no VaultAdminCap (snapshot tests don't do vault withdrawals).
#[test_only]
public fun create_for_testing<RaiseToken, StableCoin>(
    account_id: ID,
    base_fee_bps: u64,
    surge_fee_bps: u64,
    surge_duration_ms: u64,
    release_duration_ms: u64,
    reserved_amount: u64,
    nav_discount_bps: u64,
    snapshot_backing: u64,
    snapshot_circulating: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ProtectiveBid<RaiseToken, StableCoin> {
    assert!(base_fee_bps <= constants::max_protective_bid_fee_bps(), EFeeTooHigh);
    assert!(surge_fee_bps <= constants::max_protective_bid_fee_bps(), EFeeTooHigh);
    assert!(nav_discount_bps < 10000, ENavDiscountTooHigh);
    if (surge_fee_bps > 0) {
        assert!(surge_fee_bps >= base_fee_bps, EFeeTooHigh);
    };

    let now = clock.timestamp_ms();
    let release_deadline_ms = if (release_duration_ms == 0) { 0 } else { now + release_duration_ms };

    let surge_end_ms = if (surge_fee_bps == 0 || surge_duration_ms == 0) {
        0
    } else {
        now + surge_duration_ms
    };

    ProtectiveBid {
        id: object::new(ctx),
        account_id,
        pool_id: object::id_from_address(@0x0),
        dao_amm_asset_principal: option::none(),
        dao_amm_stable_principal: option::none(),
        base_fee_bps,
        surge_fee_bps,
        surge_end_ms,
        created_at_ms: now,
        vault_admin_cap: option::none(),
        reserved_amount,
        nav_discount_bps,
        base_bought_amount: 0,
        fees_collected: 0,
        seq_num: 0,
        release_deadline_ms,
        active: true,
        snapshot_backing,
        snapshot_circulating,
    }
}

#[test_only]
public fun deactivate_for_testing<RT, SC>(bid: &mut ProtectiveBid<RT, SC>) {
    bid.active = false;
}

/// Sell tokens using snapshot values (for unit testing without Account/Registry/Pool)
#[test_only]
public fun sell_to_bid_snapshot<RaiseToken, StableCoin>(
    bid: &mut ProtectiveBid<RaiseToken, StableCoin>,
    tokens: Coin<RaiseToken>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableCoin> {
    assert!(bid.active, EBidInactive);
    if (bid.release_deadline_ms > 0) {
        assert!(clock.timestamp_ms() < bid.release_deadline_ms, EBidWallExpired);
    };
    assert!(bid.reserved_amount > 0, EBidWallDepleted);

    let token_amount = tokens.value();
    assert!(token_amount > 0, EZeroAmount);

    let circulating = bid.snapshot_circulating;
    assert!(circulating > 0, EZeroCirculatingSupply);
    assert!(circulating >= token_amount, ECirculatingSupplyUnderflow);

    let total_backing: u128 = bid.snapshot_backing as u128;

    // Apply discount
    let discounted_backing = if (bid.nav_discount_bps == 0) {
        total_backing
    } else {
        total_backing * ((10000 - bid.nav_discount_bps) as u128) / 10000
    };

    let gross_stable_u256 = (token_amount as u256) * (discounted_backing as u256) / (circulating as u256);
    assert!(gross_stable_u256 <= (bid.reserved_amount as u256), EInsufficientReserved);
    let gross_stable = (gross_stable_u256 as u64);

    // Apply fee
    let current_fee = current_fee_bps_at(bid, clock.timestamp_ms());
    let fee_amount = (((gross_stable as u128) * (current_fee as u128)) / 10000u128) as u64;
    let stable_out = gross_stable - fee_amount;
    assert!(stable_out > 0 || gross_stable == 0, EZeroOutput);

    // Destroy tokens (test burn)
    coin::burn_for_testing(tokens);

    // Update state
    bid.reserved_amount = bid.reserved_amount - gross_stable;
    bid.fees_collected = bid.fees_collected + fee_amount;
    bid.base_bought_amount = bid.base_bought_amount + token_amount;
    bid.seq_num = bid.seq_num + 1;

    // Update snapshots
    bid.snapshot_backing = bid.snapshot_backing - gross_stable;
    bid.snapshot_circulating = bid.snapshot_circulating - token_amount;

    // Mint stable for testing (in production, withdrawn from vault)
    coin::mint_for_testing<StableCoin>(stable_out, ctx)
}

/// Quote sell using snapshot values (for unit testing)
#[test_only]
public fun quote_sell_snapshot<RT, SC>(
    bid: &ProtectiveBid<RT, SC>,
    token_amount: u64,
    clock: &Clock,
): u64 {
    if (!bid.active) return 0;
    if (token_amount == 0) return 0;
    if (bid.reserved_amount == 0) return 0;

    let circulating = bid.snapshot_circulating;
    if (circulating == 0) return 0;
    if (token_amount > circulating) return 0;

    let total_backing: u128 = bid.snapshot_backing as u128;

    let discounted_backing = if (bid.nav_discount_bps == 0) {
        total_backing
    } else {
        total_backing * ((10000 - bid.nav_discount_bps) as u128) / 10000
    };

    let gross_stable_u256 = (token_amount as u256) * (discounted_backing as u256) / (circulating as u256);
    if (gross_stable_u256 > (bid.reserved_amount as u256)) return 0;
    let gross_stable = (gross_stable_u256 as u64);

    let current_fee = current_fee_bps_at(bid, clock.timestamp_ms());
    let fee_amount = (((gross_stable as u128) * (current_fee as u128)) / 10000u128) as u64;
    if (gross_stable > fee_amount) { gross_stable - fee_amount } else { 0 }
}

/// Get current NAV using snapshot values (for unit testing)
#[test_only]
public fun current_nav_snapshot<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    if (bid.snapshot_circulating == 0) return constants::price_precision_scale();
    let nav_u256 = (bid.snapshot_backing as u256) * (constants::price_precision_scale() as u256) / (bid.snapshot_circulating as u256);
    if (nav_u256 > (MAX_U64_AS_U128 as u256)) { (MAX_U64_AS_U128 as u64) } else { (nav_u256 as u64) }
}

#[test_only]
public fun snapshot_backing<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.snapshot_backing
}

#[test_only]
public fun snapshot_circulating<RT, SC>(bid: &ProtectiveBid<RT, SC>): u64 {
    bid.snapshot_circulating
}

#[test_only]
public fun destroy_for_testing<RaiseToken, StableCoin>(bid: ProtectiveBid<RaiseToken, StableCoin>) {
    let ProtectiveBid {
        id,
        account_id: _,
        pool_id: _,
        dao_amm_asset_principal: _,
        dao_amm_stable_principal: _,
        base_fee_bps: _,
        surge_fee_bps: _,
        surge_end_ms: _,
        created_at_ms: _,
        vault_admin_cap,
        reserved_amount: _,
        nav_discount_bps: _,
        base_bought_amount: _,
        fees_collected: _,
        seq_num: _,
        release_deadline_ms: _,
        active: _,
        snapshot_backing: _,
        snapshot_circulating: _,
    } = bid;
    object::delete(id);
    if (vault_admin_cap.is_some()) {
        vault::destroy_vault_admin_cap(vault_admin_cap.destroy_some());
    } else {
        vault_admin_cap.destroy_none();
    };
}
