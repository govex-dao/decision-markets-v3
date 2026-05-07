// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_markets_operations::spot_pool_emergency;

use futarchy_core::emergency_cap::{Self, EmergencyCap};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use sui::clock::Clock;
use sui::coin;

/// Emergency fallback: after the EmergencyCap's 7-day arm delay, sweep spot pool reserves
/// to the caller (EmergencyCap holder).
///
/// Assets are transferred to ctx.sender().
public entry fun emergency_withdraw_reserves_to_sender<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_amount: u64,
    stable_amount: u64,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &mut TxContext,
) {
    emergency_cap::assert_ready(cap, clock);
    let (asset_coin, stable_coin) = unified_spot_pool::emergency_withdraw_reserves(
        pool,
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

/// Emergency fallback: after the EmergencyCap's 7-day arm delay, sweep accumulated protocol
/// fee balances to the caller (EmergencyCap holder).
///
/// Assets are transferred to ctx.sender().
public entry fun emergency_withdraw_protocol_fees_to_sender<AssetType, StableType, LPType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_amount: u64,
    stable_amount: u64,
    clock: &Clock,
    cap: &EmergencyCap,
    ctx: &mut TxContext,
) {
    emergency_cap::assert_ready(cap, clock);
    let (asset_coin, stable_coin) = unified_spot_pool::emergency_withdraw_protocol_fees(
        pool,
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
