// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Protective Ask Module - Fixed-Price Mint Ceiling
///
/// Creates a mint-on-demand ceiling where users can buy newly minted RaiseToken
/// from the DAO at a fixed price per token, up to a mint quota.
///
/// Price is set at creation time and never changes:
///   stable_required = ceil(asset_amount * price_per_token / PRECISION)
///   where PRECISION = constants::price_precision_scale() = 1e12
///
/// Buy flow:
/// 1. Check DAO not terminated
/// 2. stable_required = ceil(asset_amount * price_per_token / PRECISION)
/// 3. DAO mints asset_amount to user
/// 4. stable_required is deposited to DAO treasury
/// 5. Remaining stable returned to caller
module futarchy_markets_core::protective_ask;

use account_actions::currency::{Self, CurrencyMintAdminCap};
use account_actions::vault;
use account_protocol::account::{Self, Account};
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::emergency_cap::{Self, EmergencyCap};
use futarchy_core::futarchy_config;
use futarchy_markets_core::protective_ask_registry;
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationAuth};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::math;
use std::option;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;

// === Errors ===

const EAskInactive: u64 = 1;
const EDeadlineNotReached: u64 = 2;
const EZeroAmount: u64 = 3;
const EWrongAccount: u64 = 4;
const EAskWallDepleted: u64 = 6;
const EAskWallExpired: u64 = 7;
const EProposalActive: u64 = 8;
const EPoolMismatch: u64 = 9;
const EAuthTargetMismatch: u64 = 13;
const EInsufficientPayment: u64 = 14;
const EMathOverflow: u64 = 16;
const EInvalidMintState: u64 = 17;
const ENoPermissionlessClose: u64 = 18;
const EZeroPrice: u64 = 19;
const EMintCapAccountMismatch: u64 = 20;

// === Structs ===

public struct ProtectiveAsk<phantom RaiseToken, phantom StableCoin> has key, store {
    id: UID,
    /// ID of the DAO account (for mint authority + treasury deposits)
    account_id: ID,
    /// ID of the AMM pool (for proposal lock check)
    pool_id: ID,
    /// Fixed price per token, scaled by price_precision_scale() (1e12).
    /// e.g., 2.5 USDC/token = 2_500_000_000_000
    price_per_token: u64,
    /// Maximum amount of RaiseToken that can be minted via this wall.
    max_mint_amount: u64,
    /// Amount already minted via this wall.
    minted_amount: u64,
    /// Lifetime total stable collected via this wall.
    total_stable_collected: u64,
    /// Event sequence number.
    seq_num: u64,
    /// Timestamp when ask can be closed permissionlessly.
    release_deadline_ms: u64,
    /// Whether ask is still active.
    active: bool,
    /// Explicit delegated mint authority for this ask wall.
    mint_admin_cap: Option<CurrencyMintAdminCap<RaiseToken>>,
}

// === Events ===

public struct ProtectiveAskCreated has copy, drop {
    ask_id: ID,
    account_id: ID,
    pool_id: ID,
    price_per_token: u64,
    max_mint_amount: u64,
    release_deadline_ms: u64,
}

public struct TokensBoughtFromAsk has copy, drop {
    ask_id: ID,
    buyer: address,
    asset_bought: u64,
    stable_spent: u64,
    price_per_token: u64,
    post_minted_amount: u64,
    post_remaining_mint_amount: u64,
    post_total_stable_collected: u64,
    seq_num: u64,
}

public struct AskReleased has copy, drop {
    ask_id: ID,
    stable_to_treasury: u64,
    final_minted_amount: u64,
    final_stable_collected_amount: u64,
}

// === Public Functions ===

/// Create a new protective ask with a fixed price per token.
/// `price_per_token` is scaled by price_precision_scale() (1e12).
public fun create<RaiseToken, StableCoin>(
    account_id: ID,
    pool_id: ID,
    price_per_token: u64,
    max_mint_amount: u64,
    release_duration_ms: u64,
    mint_admin_cap: CurrencyMintAdminCap<RaiseToken>,
    auth: SpotPoolMutationAuth,
    clock: &Clock,
    ctx: &mut TxContext,
): ProtectiveAsk<RaiseToken, StableCoin> {
    assert!(max_mint_amount > 0, EZeroAmount);
    assert!(price_per_token > 0, EZeroPrice);
    assert!(spot_pool_mutation_auth::target_id(&auth) == pool_id, EAuthTargetMismatch);
    assert!(currency::mint_admin_cap_account_id(&mint_admin_cap) == account_id, EMintCapAccountMismatch);

    let now = clock.timestamp_ms();
    let release_deadline_ms = if (release_duration_ms == 0) { 0 } else { now + release_duration_ms };

    let ask = ProtectiveAsk {
        id: object::new(ctx),
        account_id,
        pool_id,
        price_per_token,
        max_mint_amount,
        minted_amount: 0,
        total_stable_collected: 0,
        seq_num: 0,
        release_deadline_ms,
        active: true,
        mint_admin_cap: option::some(mint_admin_cap),
    };

    event::emit(ProtectiveAskCreated {
        ask_id: object::id(&ask),
        account_id,
        pool_id,
        price_per_token,
        max_mint_amount,
        release_deadline_ms,
    });

    ask
}

/// Buy freshly-minted RaiseToken from the DAO at the fixed price.
///
/// REQUIRES:
/// - DAO must NOT be terminated
/// - Proposals must NOT be active (pool not locked)
/// - Account for mint authority + treasury deposit
///
/// stable_required = ceil(asset_amount * price_per_token / PRECISION)
///
/// Returns: (minted_asset_coin, stable_change_coin)
public fun buy_from_ask<Config: store, RaiseToken, StableCoin, LPType>(
    ask: &mut ProtectiveAsk<RaiseToken, StableCoin>,
    account: &mut Account,
    registry: &PackageRegistry,
    pool: &UnifiedSpotPool<RaiseToken, StableCoin, LPType>,
    stable_payment: Coin<StableCoin>,
    asset_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<RaiseToken>, Coin<StableCoin>) {
    // Check DAO not terminated — prevents post-termination minting that bricks dissolution
    let config: &futarchy_config::FutarchyConfig = account::config(account);
    futarchy_config::assert_not_terminated(futarchy_config::dao_state(config));

    assert!(ask.active, EAskInactive);
    assert!(object::id(account) == ask.account_id, EWrongAccount);
    assert!(object::id(pool) == ask.pool_id, EPoolMismatch);
    assert!(!unified_spot_pool::is_locked_for_proposal(pool), EProposalActive);
    if (ask.release_deadline_ms > 0) {
        assert!(clock.timestamp_ms() < ask.release_deadline_ms, EAskWallExpired);
    };

    assert!(ask.max_mint_amount >= ask.minted_amount, EInvalidMintState);
    let remaining = ask.max_mint_amount - ask.minted_amount;
    assert!(remaining > 0, EAskWallDepleted);
    assert!(asset_amount > 0, EZeroAmount);
    assert!(asset_amount <= remaining, EAskWallDepleted);

    let payment_amount = stable_payment.value();

    // Fixed price: stable_required = ceil(asset_amount * price_per_token / PRECISION)
    let precision = constants::price_precision_scale();
    let stable_required_u128: u128 = math::mul_div_mixed_up(
        (ask.price_per_token as u128),
        asset_amount,
        (precision as u128),
    );
    assert!(stable_required_u128 <= (std::u64::max_value!() as u128), EMathOverflow);
    let stable_required = stable_required_u128 as u64;
    assert!(payment_amount >= stable_required, EInsufficientPayment);

    // Mint output asset
    let asset_out = currency::mint_with_admin_cap<RaiseToken>(
        account,
        registry,
        ask.mint_admin_cap.borrow(),
        asset_amount,
        ctx,
    );

    // Split required stable, deposit directly to treasury, return change.
    let mut payment_balance = stable_payment.into_balance();
    let collected_balance = payment_balance.split(stable_required);
    let collected_coin = coin::from_balance(collected_balance, ctx);
    vault::deposit_approved<Config, StableCoin>(
        account,
        registry,
        std::string::utf8(b"treasury"),
        collected_coin,
    );

    assert!(ask.total_stable_collected <= std::u64::max_value!() - stable_required, EMathOverflow);
    ask.total_stable_collected = ask.total_stable_collected + stable_required;
    ask.minted_amount = ask.minted_amount + asset_amount;
    ask.seq_num = ask.seq_num + 1;

    let post_remaining = ask.max_mint_amount - ask.minted_amount;

    event::emit(TokensBoughtFromAsk {
        ask_id: object::id(ask),
        buyer: ctx.sender(),
        asset_bought: asset_amount,
        stable_spent: stable_required,
        price_per_token: ask.price_per_token,
        post_minted_amount: ask.minted_amount,
        post_remaining_mint_amount: post_remaining,
        post_total_stable_collected: ask.total_stable_collected,
        seq_num: ask.seq_num,
    });

    let stable_change = coin::from_balance(payment_balance, ctx);
    (asset_out, stable_change)
}

/// Close the ask wall (PERMISSIONLESS).
public fun close<RaiseToken, StableCoin>(
    ask: &mut ProtectiveAsk<RaiseToken, StableCoin>,
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
) {
    assert!(ask.active, EAskInactive);
    assert!(ask.release_deadline_ms > 0, ENoPermissionlessClose);
    assert!(clock.timestamp_ms() >= ask.release_deadline_ms, EDeadlineNotReached);
    assert!(object::id(account) == ask.account_id, EWrongAccount);

    ask.active = false;
    if (ask.mint_admin_cap.is_some()) {
        currency::destroy_currency_mint_admin_cap(option::extract(&mut ask.mint_admin_cap));
    };

    protective_ask_registry::clear_with_package_witness(account, registry, object::id(ask));

    event::emit(AskReleased {
        ask_id: object::id(ask),
        stable_to_treasury: 0,
        final_minted_amount: ask.minted_amount,
        final_stable_collected_amount: ask.total_stable_collected,
    });
}

/// Cancel the ask wall via governance.
/// Returns zero stable coin because proceeds are deposited to treasury on each buy.
public fun cancel<RaiseToken, StableCoin>(
    ask: &mut ProtectiveAsk<RaiseToken, StableCoin>,
    account: &mut Account,
    registry: &PackageRegistry,
    auth: SpotPoolMutationAuth,
    ctx: &mut TxContext,
): Coin<StableCoin> {
    assert!(spot_pool_mutation_auth::target_id(&auth) == ask.pool_id, EAuthTargetMismatch);
    assert!(ask.active, EAskInactive);
    assert!(object::id(account) == ask.account_id, EWrongAccount);

    ask.active = false;
    if (ask.mint_admin_cap.is_some()) {
        currency::destroy_currency_mint_admin_cap(option::extract(&mut ask.mint_admin_cap));
    };

    protective_ask_registry::clear_with_package_witness(account, registry, object::id(ask));

    event::emit(AskReleased {
        ask_id: object::id(ask),
        stable_to_treasury: 0,
        final_minted_amount: ask.minted_amount,
        final_stable_collected_amount: ask.total_stable_collected,
    });

    coin::zero<StableCoin>(ctx)
}

// === Emergency Functions ===

/// Emergency deactivate: treasury-coupled model has no stable to withdraw,
/// but the ask still must be disabled and deregistered so minting cannot continue.
public fun emergency_withdraw_stable<RaiseToken, StableCoin>(
    ask: &mut ProtectiveAsk<RaiseToken, StableCoin>,
    account: &mut Account,
    registry: &PackageRegistry,
    cap: &EmergencyCap,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableCoin> {
    emergency_cap::assert_ready(cap, clock);
    assert!(object::id(account) == ask.account_id, EWrongAccount);

    if (ask.mint_admin_cap.is_some()) {
        currency::destroy_currency_mint_admin_cap(option::extract(&mut ask.mint_admin_cap));
    };
    ask.active = false;

    protective_ask_registry::clear_with_package_witness(account, registry, object::id(ask));

    coin::zero<StableCoin>(ctx)
}

// === View Functions ===

/// Quote stable required to buy `asset_amount` from ask wall.
public fun quote_buy<RT, SC>(
    ask: &ProtectiveAsk<RT, SC>,
    asset_amount: u64,
    clock: &Clock,
): u64 {
    if (!ask.active) return 0;
    if (asset_amount == 0) return 0;
    if (ask.release_deadline_ms > 0 && clock.timestamp_ms() >= ask.release_deadline_ms) return 0;
    if (ask.minted_amount > ask.max_mint_amount) return 0;

    let remaining = ask.max_mint_amount - ask.minted_amount;
    if (remaining == 0 || asset_amount > remaining) return 0;

    let precision = constants::price_precision_scale();
    let stable_required_u128: u128 = math::mul_div_mixed_up(
        (ask.price_per_token as u128),
        asset_amount,
        (precision as u128),
    );
    if (stable_required_u128 > (std::u64::max_value!() as u128)) return 0;
    stable_required_u128 as u64
}

/// Get remaining mint amount.
public fun remaining_mint_amount<RT, SC>(ask: &ProtectiveAsk<RT, SC>): u64 {
    if (ask.minted_amount >= ask.max_mint_amount) {
        0
    } else {
        ask.max_mint_amount - ask.minted_amount
    }
}

/// Get configured max mint amount.
public fun max_mint_amount<RT, SC>(ask: &ProtectiveAsk<RT, SC>): u64 {
    ask.max_mint_amount
}

/// Get total minted amount.
public fun minted_amount<RT, SC>(ask: &ProtectiveAsk<RT, SC>): u64 {
    ask.minted_amount
}

/// Get lifetime stable collected by ask wall.
public fun stable_collected_amount<RT, SC>(ask: &ProtectiveAsk<RT, SC>): u64 {
    ask.total_stable_collected
}

/// Always 0 in treasury-coupled model.
public fun remaining_stable<RT, SC>(_ask: &ProtectiveAsk<RT, SC>): u64 {
    0
}

/// Get pool ID.
public fun pool_id<RT, SC>(ask: &ProtectiveAsk<RT, SC>): ID {
    ask.pool_id
}

/// Get account ID.
public fun account_id<RT, SC>(ask: &ProtectiveAsk<RT, SC>): ID {
    ask.account_id
}

/// Get fixed price per token (scaled by precision).
public fun price_per_token<RT, SC>(ask: &ProtectiveAsk<RT, SC>): u64 {
    ask.price_per_token
}

/// Get release deadline.
public fun release_deadline_ms<RT, SC>(ask: &ProtectiveAsk<RT, SC>): u64 {
    ask.release_deadline_ms
}

/// Check if active.
public fun is_active<RT, SC>(ask: &ProtectiveAsk<RT, SC>): bool {
    ask.active
}

/// Get sequence number.
public fun seq_num<RT, SC>(ask: &ProtectiveAsk<RT, SC>): u64 {
    ask.seq_num
}

/// Get precision constant.
public fun precision(): u64 {
    constants::price_precision_scale()
}

// === Test Functions ===

#[test_only]
public fun create_for_testing<RaiseToken, StableCoin>(
    account_id: ID,
    price_per_token: u64,
    max_mint_amount: u64,
    release_duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ProtectiveAsk<RaiseToken, StableCoin> {
    assert!(max_mint_amount > 0, EZeroAmount);
    assert!(price_per_token > 0, EZeroPrice);
    let now = clock.timestamp_ms();
    let release_deadline_ms = if (release_duration_ms == 0) { 0 } else { now + release_duration_ms };

    ProtectiveAsk {
        id: object::new(ctx),
        account_id,
        pool_id: object::id_from_address(@0x0),
        price_per_token,
        max_mint_amount,
        minted_amount: 0,
        total_stable_collected: 0,
        seq_num: 0,
        release_deadline_ms,
        active: true,
        mint_admin_cap: option::none(),
    }
}

#[test_only]
public fun deactivate_for_testing<RT, SC>(ask: &mut ProtectiveAsk<RT, SC>) {
    ask.active = false;
}

/// Buy from ask using fixed price (for unit testing without Account/Registry/Pool).
#[test_only]
public fun buy_from_ask_snapshot<RaiseToken, StableCoin>(
    ask: &mut ProtectiveAsk<RaiseToken, StableCoin>,
    stable_payment: Coin<StableCoin>,
    asset_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<RaiseToken>, Coin<StableCoin>) {
    assert!(ask.active, EAskInactive);
    if (ask.release_deadline_ms > 0) {
        assert!(clock.timestamp_ms() < ask.release_deadline_ms, EAskWallExpired);
    };
    assert!(ask.max_mint_amount >= ask.minted_amount, EInvalidMintState);
    let remaining = ask.max_mint_amount - ask.minted_amount;
    assert!(remaining > 0, EAskWallDepleted);
    assert!(asset_amount > 0, EZeroAmount);
    assert!(asset_amount <= remaining, EAskWallDepleted);

    let payment_amount = stable_payment.value();

    let precision = constants::price_precision_scale();
    let stable_required_u128: u128 = math::mul_div_mixed_up(
        (ask.price_per_token as u128),
        asset_amount,
        (precision as u128),
    );
    assert!(stable_required_u128 <= (std::u64::max_value!() as u128), EMathOverflow);
    let stable_required = stable_required_u128 as u64;
    assert!(payment_amount >= stable_required, EInsufficientPayment);

    let mut payment_balance = stable_payment.into_balance();
    let collected_coin = coin::from_balance(payment_balance.split(stable_required), ctx);
    coin::burn_for_testing(collected_coin);

    ask.total_stable_collected = ask.total_stable_collected + stable_required;
    ask.minted_amount = ask.minted_amount + asset_amount;
    ask.seq_num = ask.seq_num + 1;

    let asset_out = coin::mint_for_testing<RaiseToken>(asset_amount, ctx);
    let stable_change = coin::from_balance(payment_balance, ctx);
    (asset_out, stable_change)
}

#[test_only]
public fun quote_buy_snapshot<RT, SC>(ask: &ProtectiveAsk<RT, SC>, asset_amount: u64, clock: &Clock): u64 {
    if (!ask.active) return 0;
    if (asset_amount == 0) return 0;
    if (ask.release_deadline_ms > 0 && clock.timestamp_ms() >= ask.release_deadline_ms) return 0;
    if (ask.minted_amount > ask.max_mint_amount) return 0;

    let remaining = ask.max_mint_amount - ask.minted_amount;
    if (remaining == 0 || asset_amount > remaining) return 0;

    let precision = constants::price_precision_scale();
    let stable_required_u128: u128 = math::mul_div_mixed_up(
        (ask.price_per_token as u128),
        asset_amount,
        (precision as u128),
    );
    if (stable_required_u128 > (std::u64::max_value!() as u128)) return 0;
    stable_required_u128 as u64
}

#[test_only]
public fun destroy_for_testing<RaiseToken, StableCoin>(ask: ProtectiveAsk<RaiseToken, StableCoin>) {
    let ProtectiveAsk {
        id,
        account_id: _,
        pool_id: _,
        price_per_token: _,
        max_mint_amount: _,
        minted_amount: _,
        total_stable_collected: _,
        seq_num: _,
        release_deadline_ms: _,
        active: _,
        mint_admin_cap,
    } = ask;
    if (mint_admin_cap.is_some()) {
        currency::destroy_currency_mint_admin_cap(mint_admin_cap.destroy_some());
    } else {
        mint_admin_cap.destroy_none();
    };
    object::delete(id);
}
