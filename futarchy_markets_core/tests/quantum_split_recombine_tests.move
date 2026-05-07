// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Tests for quantum split and recombine flow with fee tracking
#[test_only]
module futarchy_markets_core::quantum_split_recombine_tests;

use futarchy_markets_core::quantum_lp_manager;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm;
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use std::vector;
use sui::balance;
use sui::clock;
use sui::coin;
use sui::test_scenario as ts;

// === Constants ===
const ADMIN: address = @0xAD;
const INITIAL_LIQUIDITY: u64 = 1000_000_000_000; // 1000 tokens with 9 decimals
const FEE_BPS: u64 = 30; // 0.3%
