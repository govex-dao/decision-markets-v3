// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_proposal::liquidity_initialize;

use futarchy_core::market_state_mutation_auth::MarketStateMutationAuth;
use futarchy_markets_primitives::coin_escrow::TokenEscrow;
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use sui::clock::Clock;

// === Introduction ===
// Creates empty conditional AMM pools for each outcome.
// Liquidity is injected later via auto_quantum_split_on_proposal_start.
// Assumes TreasuryCaps have been registered with escrow before calling this.

// === Errors ===
const EInvalidOutcomeCount: u64 = 105;
const ECapsNotRegistered: u64 = 106;
const EMissingInitialPrice: u64 = 107;

// === Public Functions ===
/// Create empty outcome markets using TreasuryCap-based conditional coins.
/// Pools start with zero reserves; liquidity is injected later at advance-to-trading.
///
/// IMPORTANT: TreasuryCaps must be registered with escrow BEFORE calling this function.
///
/// Requires twap_initial_observation to be Some(price) for oracle initialization.
public(package) fun create_outcome_markets<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    twap_start_delay: u64,
    twap_initial_observation: Option<u128>,
    twap_cap_ppm: u64,
    amm_total_fee_bps: u64,
    auth: &MarketStateMutationAuth,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<LiquidityPool> {
    assert!(outcome_count > 0, EInvalidOutcomeCount);
    assert!(outcome_count <= 255, EInvalidOutcomeCount);
    assert!(escrow.caps_registered_count() == outcome_count, ECapsNotRegistered);
    assert!(twap_initial_observation.is_some(), EMissingInitialPrice);

    // Create empty AMM pools for each outcome
    let mut amm_pools = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        let ms = escrow.get_market_state();
        let market_id = futarchy_markets_primitives::market_state::market_id(ms);

        let pool = conditional_amm::new_empty_pool(
            market_id,
            (i as u8),
            amm_total_fee_bps,
            *twap_initial_observation.borrow(),
            twap_start_delay,
            twap_cap_ppm,
            auth,
            clock,
            ctx,
        );
        amm_pools.push_back(pool);

        i = i + 1;
    };

    amm_pools
}
