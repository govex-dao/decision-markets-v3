// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_markets_operations::routing_optimization_tests;

use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationRegistry};
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationRegistry};
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationRegistry};
use futarchy_markets_core::arbitrage_math;
use futarchy_markets_core::swap_core;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_operations::swap_entry;
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::conditional_balance;
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use futarchy_proposal::proposal::{Self, Proposal};
use std::option;
use std::string;
use std::vector;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::object;
use sui::test_scenario as ts;

// Test LP type
public struct LP has drop {}

// === Constants ===
const DEFAULT_FEE_BPS: u16 = 30; // 0.3%
const STATE_TRADING: u8 = 2;

// === Test Helpers ===

fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    clock::create_for_testing(ctx)
}

fun amount_after_spot_protocol_fee(amount: u64): u64 {
    amount - (amount * constants::protocol_fee_bps() / constants::total_fee_bps())
}

fun expected_spot_protocol_fee(amount: u64, lp_fee_bps: u64): u64 {
    let steady_total_bps = constants::protocol_fee_bps() + lp_fee_bps;
    let total_fee = amount * steady_total_bps / constants::total_fee_bps();
    total_fee * constants::protocol_fee_bps() / steady_total_bps
}

fun expected_conditional_protocol_fee(amount: u64): u64 {
    amount * constants::protocol_fee_bps() / constants::total_fee_bps()
}

fun quote_conditional_stable_to_asset_for_testing(
    pools: &vector<LiquidityPool>,
    stable_amount: u64,
): u64 {
    if (stable_amount == 0) return 0;
    let n = vector::length(pools);
    if (n == 0) return 0;

    let mut min_out = std::u64::max_value!();
    let mut i = 0;
    while (i < n) {
        let out = conditional_amm::simulate_swap_stable_to_asset(&pools[i], stable_amount);
        if (out == 0) return 0;
        if (out < min_out) {
            min_out = out;
        };
        i = i + 1;
    };

    if (min_out == std::u64::max_value!()) { 0 } else { min_out }
}

fun quote_conditional_asset_to_stable_for_testing(
    pools: &vector<LiquidityPool>,
    asset_amount: u64,
): u64 {
    if (asset_amount == 0) return 0;
    let n = vector::length(pools);
    if (n == 0) return 0;

    let mut min_out = std::u64::max_value!();
    let mut i = 0;
    while (i < n) {
        let out = conditional_amm::simulate_swap_asset_to_stable(&pools[i], asset_amount);
        if (out == 0) return 0;
        if (out < min_out) {
            min_out = out;
        };
        i = i + 1;
    };

    if (min_out == std::u64::max_value!()) { 0 } else { min_out }
}

#[test_only]
fun create_test_escrow_registry(ctx: &mut TxContext): EscrowMutationRegistry {
    let mut registry = escrow_mutation_auth::create_registry_for_testing(ctx);
    // Add futarchy_markets_core to authorized packages so arbitrage can create auth
    escrow_mutation_auth::add_authorized_package_for_testing(&mut registry, @futarchy_markets_core);
    registry
}

#[test_only]
fun create_test_market_state_registry(ctx: &mut TxContext): MarketStateMutationRegistry {
    let mut registry = market_state_mutation_auth::new_registry_for_testing(ctx);
    // Add futarchy_markets_core to authorized packages so arbitrage can create auth
    market_state_mutation_auth::add_authorized_package_for_testing(&mut registry, @futarchy_markets_core);
    registry
}

#[test_only]
fun create_test_spot_pool_mutation_registry(ctx: &mut TxContext): SpotPoolMutationRegistry {
    let mut registry = spot_pool_mutation_auth::new_registry_for_testing(ctx);
    let admin_cap = spot_pool_mutation_auth::new_admin_cap_for_testing(&registry, ctx);
    spot_pool_mutation_auth::add_authorized_package(
        &mut registry,
        &admin_cap,
        @futarchy_markets_operations,
    );
    spot_pool_mutation_auth::destroy_admin_cap_for_testing(admin_cap);
    registry
}

fun create_lp_treasury(ctx: &mut TxContext): coin::TreasuryCap<LP> {
    coin::create_treasury_cap_for_testing<LP>(ctx)
}

fun create_test_spot_pool(
    asset_reserve: u64,
    stable_reserve: u64,
    fee_bps: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP> {
    let lp_treasury = create_lp_treasury(ctx);
    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, LP>(
        lp_treasury,
        fee_bps,
        ctx,
    );
    let asset_balance = sui::balance::create_for_testing<TEST_COIN_A>(asset_reserve);
    let stable_balance = sui::balance::create_for_testing<TEST_COIN_B>(stable_reserve);
    unified_spot_pool::add_liquidity_for_testing(&mut pool, asset_balance, stable_balance);
    pool
}

fun create_test_escrow_with_markets(
    outcome_count: u64,
    _initial_reserve: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): TokenEscrow<TEST_COIN_A, TEST_COIN_B> {
    let proposal_id = object::id_from_address(@0xABC);
    let dao_id = object::id_from_address(@0xDEF);

    // Create market state with pools
    let mut outcome_messages = vector::empty();
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut outcome_messages, string::utf8(b"Outcome"));
        i = i + 1;
    };

    let market_state = market_state::new(
        proposal_id,
        dao_id,
        outcome_count,
        outcome_messages,
        clock,
        ctx,
    );

    // Create escrow with market state
    coin_escrow::create_test_escrow_with_market_state(
        outcome_count,
        market_state,
        ctx,
    )
}

fun seed_lp_backing(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    asset_amount: u64,
    stable_amount: u64,
) {
    let auth = escrow_mutation_auth::create_for_testing();
    let asset_balance = sui::balance::create_for_testing<TEST_COIN_A>(asset_amount);
    let stable_balance = sui::balance::create_for_testing<TEST_COIN_B>(stable_amount);
    let (_deposited_asset, _deposited_stable) = coin_escrow::lp_deposit_quantum(
        escrow,
        asset_balance,
        stable_balance,
        &auth,
    );
}

fun setup_proposal_for_testing(
    escrow_id: object::ID,
    market_state_id: object::ID,
    ctx: &mut TxContext,
): Proposal<TEST_COIN_A, TEST_COIN_B> {
    let mut proposal = proposal::create_test_proposal<TEST_COIN_A, TEST_COIN_B>(
        2, // outcome_count
        0, // winning_outcome
        false, // is_finalized
        ctx,
    );
    proposal::set_state_for_testing(&mut proposal, STATE_TRADING);
    proposal::set_escrow_id_for_testing(&mut proposal, escrow_id);
    proposal::set_market_state_id_for_testing(&mut proposal, market_state_id);
    proposal
}

fun lock_pool_with_escrow(
    spot_pool: &mut UnifiedSpotPool<TEST_COIN_A, TEST_COIN_B, LP>,
    escrow: TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
) {
    let proposal_id = market_state::proposal_id(coin_escrow::get_market_state(&escrow));
    let store_auth = spot_pool_mutation_auth::create_for_testing(object::id(spot_pool));
    unified_spot_pool::store_active_escrow(spot_pool, escrow, store_auth);
    unified_spot_pool::set_active_proposal_for_testing(spot_pool, proposal_id);
}

fun install_two_conditional_pools(
    escrow: &mut TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    pool0_asset: u64,
    pool0_stable: u64,
    pool1_asset: u64,
    pool1_stable: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let market_id = market_state::market_id(coin_escrow::get_market_state(escrow));
    let mut pools = vector::empty<LiquidityPool>();
    pools.push_back(conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        pool0_asset,
        pool0_stable,
        clock,
        ctx,
    ));
    pools.push_back(conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        pool1_asset,
        pool1_stable,
        clock,
        ctx,
    ));

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
}

fun assert_two_pool_reserves(
    escrow: &TokenEscrow<TEST_COIN_A, TEST_COIN_B>,
    pool0_asset: u64,
    pool0_stable: u64,
    pool1_asset: u64,
    pool1_stable: u64,
    code: u64,
) {
    let pools = market_state::borrow_amm_pools(coin_escrow::get_market_state(escrow));
    let (actual0_asset, actual0_stable) = conditional_amm::get_reserves(&pools[0]);
    let (actual1_asset, actual1_stable) = conditional_amm::get_reserves(&pools[1]);
    assert!(actual0_asset == pool0_asset, code);
    assert!(actual0_stable == pool0_stable, code + 1);
    assert!(actual1_asset == pool1_asset, code + 2);
    assert!(actual1_stable == pool1_stable, code + 3);
}

fun assert_best_split_matches_exhaustive_case(
    spot_asset: u64,
    spot_stable: u64,
    cond0_asset: u64,
    cond0_stable: u64,
    cond1_asset: u64,
    cond1_stable: u64,
    swap_amount: u64,
    code: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let spot_pool = create_test_spot_pool(
        spot_asset,
        spot_stable,
        (DEFAULT_FEE_BPS as u64),
        clock,
        ctx,
    );
    let mut escrow = create_test_escrow_with_markets(2, 1000, clock, ctx);
    seed_lp_backing(&mut escrow, 10_000_000, 10_000_000);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    pools.push_back(conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        cond0_asset,
        cond0_stable,
        clock,
        ctx,
    ));
    pools.push_back(conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        cond1_asset,
        cond1_stable,
        clock,
        ctx,
    ));

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    let pools_ref = market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow));
    let asset_cap = coin_escrow::get_escrowed_asset_balance(&escrow);
    let stable_cap = coin_escrow::get_escrowed_stable_balance(&escrow);
    let (_, _, best_asset_out) = arbitrage_math::compute_best_stable_to_asset_split(
        &spot_pool,
        pools_ref,
        swap_amount,
        asset_cap,
        clock,
    );
    let (_, _, best_stable_out) = arbitrage_math::compute_best_asset_to_stable_split(
        &spot_pool,
        pools_ref,
        swap_amount,
        stable_cap,
        clock,
    );

    let mut conditional_in = 0u64;
    while (conditional_in <= swap_amount) {
        let spot_in = swap_amount - conditional_in;

        let spot_asset_out = if (spot_in == 0) {
            0
        } else {
            unified_spot_pool::simulate_swap_stable_to_asset_accurate(&spot_pool, spot_in, clock)
        };
        let conditional_asset_out = if (conditional_in == 0) {
            0
        } else {
            quote_conditional_stable_to_asset_for_testing(pools_ref, conditional_in)
        };
        if (conditional_asset_out <= asset_cap) {
            assert!(best_asset_out >= spot_asset_out + conditional_asset_out, code);
        };

        let spot_stable_out = if (spot_in == 0) {
            0
        } else {
            unified_spot_pool::simulate_swap_asset_to_stable_accurate(&spot_pool, spot_in, clock)
        };
        let conditional_stable_out = if (conditional_in == 0) {
            0
        } else {
            quote_conditional_asset_to_stable_for_testing(pools_ref, conditional_in)
        };
        if (conditional_stable_out <= stable_cap) {
            assert!(best_stable_out >= spot_stable_out + conditional_stable_out, code + 1);
        };

        if (conditional_in == swap_amount) break;
        conditional_in = conditional_in + 1;
    };

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
}

#[test]
fun test_best_split_math_matches_exhaustive_small_domain() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );
    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 1_000_000, 1_000_000);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0u64;
    while (i < 2u64) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    let swap_amount = 1_000u64;
    let pools_ref = market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow));
    let (_, _, best_asset_out) = arbitrage_math::compute_best_stable_to_asset_split(
        &spot_pool,
        pools_ref,
        swap_amount,
        coin_escrow::get_escrowed_asset_balance(&escrow),
        &clock,
    );
    let (_, _, best_stable_out) = arbitrage_math::compute_best_asset_to_stable_split(
        &spot_pool,
        pools_ref,
        swap_amount,
        coin_escrow::get_escrowed_stable_balance(&escrow),
        &clock,
    );

    let mut conditional_in = 0u64;
    while (conditional_in <= swap_amount) {
        let spot_in = swap_amount - conditional_in;
        let spot_asset_out = if (spot_in == 0) {
            0
        } else {
            unified_spot_pool::simulate_swap_stable_to_asset_accurate(&spot_pool, spot_in, &clock)
        };
        let conditional_asset_out = if (conditional_in == 0) {
            0
        } else {
            quote_conditional_stable_to_asset_for_testing(pools_ref, conditional_in)
        };
        assert!(best_asset_out >= spot_asset_out + conditional_asset_out, 900);

        let spot_stable_out = if (spot_in == 0) {
            0
        } else {
            unified_spot_pool::simulate_swap_asset_to_stable_accurate(&spot_pool, spot_in, &clock)
        };
        let conditional_stable_out = if (conditional_in == 0) {
            0
        } else {
            quote_conditional_asset_to_stable_for_testing(pools_ref, conditional_in)
        };
        assert!(best_stable_out >= spot_stable_out + conditional_stable_out, 901);

        if (conditional_in == swap_amount) break;
        conditional_in = conditional_in + 1;
    };

    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_best_split_math_matches_exhaustive_varied_domains() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    assert_best_split_matches_exhaustive_case(
        1_000_000,
        1_000_000,
        900_000,
        1_400_000,
        1_300_000,
        800_000,
        173,
        930,
        &clock,
        ctx,
    );
    assert_best_split_matches_exhaustive_case(
        1_300_000,
        800_000,
        1_000_000,
        1_000_000,
        1_100_000,
        1_050_000,
        211,
        940,
        &clock,
        ctx,
    );
    assert_best_split_matches_exhaustive_case(
        800_000,
        1_300_000,
        1_500_000,
        700_000,
        600_000,
        1_600_000,
        157,
        950,
        &clock,
        ctx,
    );

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_spot_stable_to_asset_executes_best_split() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );
    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 2_000_000, 2_000_000);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0u64;
    while (i < 2u64) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    let swap_amount = 100_000u64;
    let pools_ref = market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow));
    let direct_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let conditional_quote = quote_conditional_stable_to_asset_for_testing(
        pools_ref,
        swap_amount,
    );
    let (spot_in, conditional_in, split_quote) = arbitrage_math::compute_best_stable_to_asset_split(
        &spot_pool,
        pools_ref,
        swap_amount,
        coin_escrow::get_escrowed_asset_balance(&escrow),
        &clock,
    );
    assert!(spot_in > 0 && conditional_in > 0, 910);
    assert!(spot_in + conditional_in == swap_amount, 911);
    assert!(split_quote > direct_quote, 912);
    assert!(split_quote > conditional_quote, 913);

    lock_pool_with_escrow(&mut spot_pool, escrow);

    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(swap_amount, ctx);
    let (mut asset_out_opt, mut balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        split_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() == split_quote, 914);

    let (spot_protocol_asset, spot_protocol_stable) =
        unified_spot_pool::get_protocol_fee_amounts(&spot_pool);
    assert!(spot_protocol_asset == 0, 915);
    assert!(
        spot_protocol_stable ==
            expected_spot_protocol_fee(spot_in, (DEFAULT_FEE_BPS as u64)),
        916,
    );

    {
        let pool_auth = spot_pool_mutation_auth::create_for_testing(object::id(&spot_pool));
        let escrow_ref = unified_spot_pool::borrow_active_escrow_mut(&mut spot_pool, &pool_auth);
        let pools_after = market_state::borrow_amm_pools(coin_escrow::get_market_state(escrow_ref));
        let expected_conditional_fee = expected_conditional_protocol_fee(conditional_in);
        let mut j = 0u64;
        while (j < 2u64) {
            let pool = &pools_after[j];
            assert!(conditional_amm::get_protocol_fees_asset(pool) == 0, 917);
            assert!(conditional_amm::get_protocol_fees_stable(pool) == expected_conditional_fee, 918);
            j = j + 1;
        };
    };

    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    if (option::is_some(&balance_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut balance_opt));
    };
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_spot_asset_to_stable_executes_best_split() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );
    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 2_000_000, 2_000_000);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0u64;
    while (i < 2u64) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    let swap_amount = 100_000u64;
    let pools_ref = market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow));
    let direct_quote = unified_spot_pool::simulate_swap_asset_to_stable_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let conditional_quote = quote_conditional_asset_to_stable_for_testing(
        pools_ref,
        swap_amount,
    );
    let (spot_in, conditional_in, split_quote) = arbitrage_math::compute_best_asset_to_stable_split(
        &spot_pool,
        pools_ref,
        swap_amount,
        coin_escrow::get_escrowed_stable_balance(&escrow),
        &clock,
    );
    assert!(spot_in > 0 && conditional_in > 0, 920);
    assert!(spot_in + conditional_in == swap_amount, 921);
    assert!(split_quote > direct_quote, 922);
    assert!(split_quote > conditional_quote, 923);

    lock_pool_with_escrow(&mut spot_pool, escrow);

    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let (mut stable_out_opt, mut balance_opt) = swap_entry::swap_spot_asset_to_stable(
        &mut spot_pool,
        asset_in,
        split_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let stable_out = option::extract(&mut stable_out_opt);
    assert!(stable_out.value() == split_quote, 924);

    let (spot_protocol_asset, spot_protocol_stable) =
        unified_spot_pool::get_protocol_fee_amounts(&spot_pool);
    assert!(
        spot_protocol_asset ==
            expected_spot_protocol_fee(spot_in, (DEFAULT_FEE_BPS as u64)),
        925,
    );
    assert!(spot_protocol_stable == 0, 926);

    {
        let pool_auth = spot_pool_mutation_auth::create_for_testing(object::id(&spot_pool));
        let escrow_ref = unified_spot_pool::borrow_active_escrow_mut(&mut spot_pool, &pool_auth);
        let pools_after = market_state::borrow_amm_pools(coin_escrow::get_market_state(escrow_ref));
        let expected_conditional_fee = expected_conditional_protocol_fee(conditional_in);
        let mut j = 0u64;
        while (j < 2u64) {
            let pool = &pools_after[j];
            assert!(conditional_amm::get_protocol_fees_asset(pool) == expected_conditional_fee, 927);
            assert!(conditional_amm::get_protocol_fees_stable(pool) == 0, 928);
            j = j + 1;
        };
    };

    coin::burn_for_testing(stable_out);
    option::destroy_none(stable_out_opt);
    if (option::is_some(&balance_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut balance_opt));
    };
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Routing Tests ===

/// Test direct swap path when conditional pools are too small (routing doesn't help)
#[test]
fun test_routing_prefers_direct_when_conditionals_tiny() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Large spot pool
    let spot_asset = 200_000_000_000u64; // 200B
    let spot_stable = 200_000_000u64; // 200M
    let mut spot_pool = create_test_spot_pool(
        spot_asset,
        spot_stable,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    // Tiny conditional pools (0.01% of spot = routing won't help)
    let conditional_ratio = 1; // 0.01% each
    let outcome_count = 2u64;
    let cond_asset = (spot_asset * conditional_ratio) / (10000 * outcome_count); // 100M each
    let cond_stable = (spot_stable * conditional_ratio) / (10000 * outcome_count); // 100 each

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    // Create conditional pools
    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0;
    while (i < 2) {
        let pool = conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            cond_asset,
            cond_stable,
            &clock,
            ctx,
        );
        pools.push_back(pool);
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Get reserves before
    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);
    std::debug::print(&b"=== BEFORE SWAP ===");
    std::debug::print(&b"Spot asset:");
    std::debug::print(&spot_asset_before);
    std::debug::print(&b"Spot stable:");
    std::debug::print(&spot_stable_before);

    // Swap 10k stable → asset (should go direct) - small swap to avoid no-arb violation
    let swap_amount = 10_000u64;
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(swap_amount, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut asset_out_opt, mut balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        0, // min_asset_out
        @0x1, // recipient
        option::none(),
        true, // return_balance
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let asset_out = option::extract(&mut asset_out_opt);
    let output_amount = asset_out.value();
    std::debug::print(&b"\n=== AFTER SWAP ===");
    std::debug::print(&b"Asset output:");
    std::debug::print(&output_amount);

    // Get reserves after
    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    std::debug::print(&b"Spot asset after:");
    std::debug::print(&spot_asset_after);
    std::debug::print(&b"Spot stable after:");
    std::debug::print(&spot_stable_after);

    // Verify spot pool changed (proving direct swap happened)
    assert!(
        spot_stable_after == spot_stable_before + amount_after_spot_protocol_fee(swap_amount),
        0,
    );
    assert!(spot_asset_after < spot_asset_before, 1);

    // Verify conditional pools unchanged (proving no routing happened)
    let market_state2 = coin_escrow::get_market_state(&escrow);
    let pools2 = market_state::borrow_amm_pools(market_state2);
    let (cond0_asset_after, cond0_stable_after) = conditional_amm::get_reserves(&pools2[0]);
    assert!(cond0_asset_after == cond_asset, 2);
    assert!(cond0_stable_after == cond_stable, 3);

    // Verify output is reasonable
    assert!(output_amount > 0, 4);

    // Cleanup
    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    if (option::is_some(&balance_opt)) {
        let balance = option::extract(&mut balance_opt);
        conditional_balance::destroy_for_testing(balance);
    };
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Test routing optimization in reverse direction (asset → stable)
#[test]
fun test_routing_asset_to_stable_direction() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot pool
    let spot_asset = 200_000_000_000u64;
    let spot_stable = 200_000_000u64;
    let mut spot_pool = create_test_spot_pool(
        spot_asset,
        spot_stable,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    // 1% conditional pools
    let conditional_ratio = 1;
    let outcome_count = 2u64;
    let cond_asset = (spot_asset * conditional_ratio) / (100 * outcome_count);
    let cond_stable = (spot_stable * conditional_ratio) / (100 * outcome_count);

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0;
    while (i < 2) {
        let pool = conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            cond_asset,
            cond_stable,
            &clock,
            ctx,
        );
        pools.push_back(pool);
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    // Get reserves before
    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);
    std::debug::print(&b"=== BEFORE SWAP (Asset → Stable) ===");
    std::debug::print(&b"Spot asset:");
    std::debug::print(&spot_asset_before);
    std::debug::print(&b"Spot stable:");
    std::debug::print(&spot_stable_before);

    // Swap asset → stable - small swap to avoid no-arb violation
    let swap_amount = 1_000_000u64; // 1M asset
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut stable_out_opt, mut balance_opt) = swap_entry::swap_spot_asset_to_stable(
        &mut spot_pool,
        asset_in,
        0, // min_stable_out
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let stable_out = option::extract(&mut stable_out_opt);
    let output_amount = stable_out.value();
    std::debug::print(&b"\n=== AFTER SWAP ===");
    std::debug::print(&b"Stable output:");
    std::debug::print(&output_amount);

    // Get reserves after
    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    std::debug::print(&b"Spot asset after:");
    std::debug::print(&spot_asset_after);
    std::debug::print(&b"Spot stable after:");
    std::debug::print(&spot_stable_after);

    // Verify spot pool changed
    assert!(
        spot_asset_after == spot_asset_before + amount_after_spot_protocol_fee(swap_amount),
        0,
    );
    assert!(spot_stable_after < spot_stable_before, 1);

    // Verify output is reasonable
    assert!(output_amount > 0, 2);

    // Cleanup
    coin::burn_for_testing(stable_out);
    option::destroy_none(stable_out_opt);
    if (option::is_some(&balance_opt)) {
        let balance = option::extract(&mut balance_opt);
        conditional_balance::destroy_for_testing(balance);
    };
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_spot_stable_to_asset_uses_conditional_route_when_better() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot asset is expensive; the conditional route should produce more asset.
    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 1_000_000, 1_000_000);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0;
    while (i < 2) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);

    let stable_in = coin::mint_for_testing<TEST_COIN_B>(swap_amount, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut asset_out_opt, mut balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        0,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() > direct_quote, 10);

    // The trader route is conditional-owned, then the locked pool runs
    // best-effort maintenance before storing the escrow back.
    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(spot_asset_after != spot_asset_before || spot_stable_after != spot_stable_before, 11);

    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    if (option::is_some(&balance_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut balance_opt));
    };
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_spot_asset_to_stable_uses_conditional_route_when_better() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot asset is cheap; selling asset through conditionals should produce more stable.
    let mut spot_pool = create_test_spot_pool(
        5_000_000,
        1_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 1_000_000, 1_000_000);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0;
    while (i < 2) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_asset_to_stable_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);

    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut stable_out_opt, mut balance_opt) = swap_entry::swap_spot_asset_to_stable(
        &mut spot_pool,
        asset_in,
        0,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let stable_out = option::extract(&mut stable_out_opt);
    assert!(stable_out.value() > direct_quote, 20);

    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(spot_asset_after != spot_asset_before || spot_stable_after != spot_stable_before, 21);

    coin::burn_for_testing(stable_out);
    option::destroy_none(stable_out_opt);
    if (option::is_some(&balance_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut balance_opt));
    };
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_spot_swap_keeps_direct_route_when_direct_is_better() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    // Spot asset is cheap for stable buyers; direct spot should win.
    let mut spot_pool = create_test_spot_pool(
        5_000_000,
        1_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0;
    while (i < 2) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(10_000, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut asset_out_opt, mut balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        0,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() > 0, 30);

    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(spot_asset_after < spot_asset_before, 31);
    assert!(spot_stable_after > spot_stable_before, 32);

    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    if (option::is_some(&balance_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut balance_opt));
    };
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_locked_spot_stable_to_asset_works_before_conditional_trading_starts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0u64;
    while (i < 2u64) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(swap_amount, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut asset_out_opt, balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        direct_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() == direct_quote, 33);
    assert!(option::is_none(&balance_opt), 34);

    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(spot_asset_after < spot_asset_before, 35);
    assert!(spot_stable_after > spot_stable_before, 36);

    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_locked_spot_asset_to_stable_works_before_conditional_trading_starts() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        5_000_000,
        1_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0u64;
    while (i < 2u64) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_asset_to_stable_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut stable_out_opt, balance_opt) = swap_entry::swap_spot_asset_to_stable(
        &mut spot_pool,
        asset_in,
        direct_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let stable_out = option::extract(&mut stable_out_opt);
    assert!(stable_out.value() == direct_quote, 37);
    assert!(option::is_none(&balance_opt), 38);

    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(spot_asset_after > spot_asset_before, 39);
    assert!(spot_stable_after < spot_stable_before, 40);

    coin::burn_for_testing(stable_out);
    option::destroy_none(stable_out_opt);
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_locked_spot_swaps_work_while_escrow_is_extracted() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        5_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0u64;
    while (i < 2u64) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (escrow, receipt) = swap_entry::extract_escrow_for_batch(
        &mut spot_pool,
        &spot_pool_mutation_registry,
    );

    let stable_amount = 10_000u64;
    let direct_asset_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
        &spot_pool,
        stable_amount,
        &clock,
    );
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(stable_amount, ctx);
    let (mut asset_out_opt, balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        direct_asset_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() == direct_asset_quote, 41);
    assert!(option::is_none(&balance_opt), 42);
    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    option::destroy_none(balance_opt);

    let asset_amount = 10_000u64;
    let direct_stable_quote = unified_spot_pool::simulate_swap_asset_to_stable_accurate(
        &spot_pool,
        asset_amount,
        &clock,
    );
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(asset_amount, ctx);
    let (mut stable_out_opt, balance_opt) = swap_entry::swap_spot_asset_to_stable(
        &mut spot_pool,
        asset_in,
        direct_stable_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    let stable_out = option::extract(&mut stable_out_opt);
    assert!(stable_out.value() == direct_stable_quote, 43);
    assert!(option::is_none(&balance_opt), 44);
    coin::burn_for_testing(stable_out);
    option::destroy_none(stable_out_opt);
    option::destroy_none(balance_opt);

    swap_entry::store_escrow_after_batch(
        &mut spot_pool,
        escrow,
        receipt,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        @0x1,
        &clock,
        ctx,
    );

    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_spot_swaps_work_without_proposal_or_escrow() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        5_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    let stable_amount = 20_000u64;
    let direct_asset_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
        &spot_pool,
        stable_amount,
        &clock,
    );
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(stable_amount, ctx);
    let (mut asset_out_opt, balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        direct_asset_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() == direct_asset_quote, 200);
    assert!(option::is_none(&balance_opt), 201);
    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    option::destroy_none(balance_opt);

    let asset_amount = 20_000u64;
    let direct_stable_quote = unified_spot_pool::simulate_swap_asset_to_stable_accurate(
        &spot_pool,
        asset_amount,
        &clock,
    );
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(asset_amount, ctx);
    let (mut stable_out_opt, balance_opt) = swap_entry::swap_spot_asset_to_stable(
        &mut spot_pool,
        asset_in,
        direct_stable_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    let stable_out = option::extract(&mut stable_out_opt);
    assert!(stable_out.value() == direct_stable_quote, 202);
    assert!(option::is_none(&balance_opt), 203);
    coin::burn_for_testing(stable_out);
    option::destroy_none(stable_out_opt);
    option::destroy_none(balance_opt);

    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_locked_spot_swap_after_scheduled_trading_end_stays_direct() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let mut clock = create_test_clock(0, ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );
    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 2_000_000, 2_000_000);
    install_two_conditional_pools(
        &mut escrow,
        2_000_000,
        1_000_000,
        1_000_000,
        1_000_000,
        &clock,
        ctx,
    );

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::start_trading_for_testing(market_state, 100, &clock);
    clock::set_for_testing(&mut clock, 101);

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let conditional_quote = quote_conditional_stable_to_asset_for_testing(
        market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow)),
        swap_amount,
    );
    assert!(conditional_quote > direct_quote, 210);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(swap_amount, ctx);
    let (mut asset_out_opt, balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        direct_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() == direct_quote, 211);
    assert!(option::is_none(&balance_opt), 212);
    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    option::destroy_none(balance_opt);

    let (escrow, receipt) = swap_entry::extract_escrow_for_batch(
        &mut spot_pool,
        &spot_pool_mutation_registry,
    );
    assert_two_pool_reserves(&escrow, 2_000_000, 1_000_000, 1_000_000, 1_000_000, 213);
    swap_entry::store_escrow_after_batch(
        &mut spot_pool,
        escrow,
        receipt,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        @0x1,
        &clock,
        ctx,
    );

    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_locked_spot_swap_in_execution_window_can_route_and_return_trader_dust() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );
    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 2_000_000, 2_000_000);
    install_two_conditional_pools(
        &mut escrow,
        2_000_000,
        1_000_000,
        1_000_000,
        1_000_000,
        &clock,
        ctx,
    );

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::init_trading_for_testing(market_state);
    market_state::start_execution_window_for_testing(
        market_state,
        constants::min_execution_window_ms(),
        vector[1_000_000_000_000_000u128, 1_000_000_000_000_000u128],
        1,
        &clock,
    );

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let conditional_quote = quote_conditional_stable_to_asset_for_testing(
        market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow)),
        swap_amount,
    );
    assert!(conditional_quote > direct_quote, 220);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(swap_amount, ctx);
    let (mut asset_out_opt, mut balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        0,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() > direct_quote, 221);
    assert!(option::is_some(&balance_opt), 222);
    let dust = option::borrow(&balance_opt);
    assert!(conditional_balance::get_balance(dust, 0, true) > 0, 223);
    assert!(conditional_balance::get_balance(dust, 1, true) == 0, 224);

    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    conditional_balance::destroy_for_testing(option::extract(&mut balance_opt));
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_locked_spot_swap_after_finalization_stays_direct() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        5_000_000,
        1_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );
    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 2_000_000, 2_000_000);
    install_two_conditional_pools(
        &mut escrow,
        1_000_000,
        2_000_000,
        1_000_000,
        1_000_000,
        &clock,
        ctx,
    );

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::init_trading_for_testing(market_state);
    market_state::finalize_for_testing(market_state);

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_asset_to_stable_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let conditional_quote = quote_conditional_asset_to_stable_for_testing(
        market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow)),
        swap_amount,
    );
    assert!(conditional_quote > direct_quote, 230);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let (mut stable_out_opt, balance_opt) = swap_entry::swap_spot_asset_to_stable(
        &mut spot_pool,
        asset_in,
        direct_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );
    let stable_out = option::extract(&mut stable_out_opt);
    assert!(stable_out.value() == direct_quote, 231);
    assert!(option::is_none(&balance_opt), 232);
    coin::burn_for_testing(stable_out);
    option::destroy_none(stable_out_opt);
    option::destroy_none(balance_opt);

    let (escrow, receipt) = swap_entry::extract_escrow_for_batch(
        &mut spot_pool,
        &spot_pool_mutation_registry,
    );
    assert_two_pool_reserves(&escrow, 1_000_000, 2_000_000, 1_000_000, 1_000_000, 233);
    swap_entry::store_escrow_after_batch(
        &mut spot_pool,
        escrow,
        receipt,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        @0x1,
        &clock,
        ctx,
    );

    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_spot_stable_to_asset_falls_back_direct_when_conditional_route_unbacked() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0;
    while (i < 2) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let pools_ref = market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow));
    let conditional_quote = quote_conditional_stable_to_asset_for_testing(
        pools_ref,
        swap_amount,
    );
    assert!(conditional_quote > direct_quote, 40);
    assert!(coin_escrow::get_escrowed_asset_balance(&escrow) == 0, 41);

    lock_pool_with_escrow(&mut spot_pool, escrow);

    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(swap_amount, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut asset_out_opt, mut balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        0,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() == direct_quote, 42);

    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(spot_asset_after < spot_asset_before, 43);
    assert!(spot_stable_after > spot_stable_before, 44);

    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    if (option::is_some(&balance_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut balance_opt));
    };
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_spot_asset_to_stable_falls_back_direct_when_conditional_route_unbacked() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        5_000_000,
        1_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0;
    while (i < 2) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_asset_to_stable_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let pools_ref = market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow));
    let conditional_quote = quote_conditional_asset_to_stable_for_testing(
        pools_ref,
        swap_amount,
    );
    assert!(conditional_quote > direct_quote, 50);
    assert!(coin_escrow::get_escrowed_stable_balance(&escrow) == 0, 51);

    lock_pool_with_escrow(&mut spot_pool, escrow);

    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut stable_out_opt, mut balance_opt) = swap_entry::swap_spot_asset_to_stable(
        &mut spot_pool,
        asset_in,
        0,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let stable_out = option::extract(&mut stable_out_opt);
    assert!(stable_out.value() == direct_quote, 52);

    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(spot_asset_after > spot_asset_before, 53);
    assert!(spot_stable_after < spot_stable_before, 54);

    coin::burn_for_testing(stable_out);
    option::destroy_none(stable_out_opt);
    if (option::is_some(&balance_opt)) {
        conditional_balance::destroy_for_testing(option::extract(&mut balance_opt));
    };
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_three_outcome_spot_swap_uses_conditional_route_without_bricking() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(3, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 1_000_000, 1_000_000);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0u64;
    while (i < 3u64) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);

    let swap_amount = 10_000u64;
    let direct_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
        &spot_pool,
        swap_amount,
        &clock,
    );
    let pools_ref = market_state::borrow_amm_pools(coin_escrow::get_market_state(&escrow));
    let conditional_quote = quote_conditional_stable_to_asset_for_testing(
        pools_ref,
        swap_amount,
    );
    assert!(conditional_quote > direct_quote, 60);

    lock_pool_with_escrow(&mut spot_pool, escrow);
    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);

    let stable_in = coin::mint_for_testing<TEST_COIN_B>(swap_amount, ctx);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let (mut asset_out_opt, balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        conditional_quote,
        @0x1,
        option::none(),
        true,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    let asset_out = option::extract(&mut asset_out_opt);
    assert!(asset_out.value() == conditional_quote, 61);
    assert!(option::is_none(&balance_opt), 62);

    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(spot_asset_after != spot_asset_before || spot_stable_after != spot_stable_before, 63);

    coin::burn_for_testing(asset_out);
    option::destroy_none(asset_out_opt);
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_repeated_conditional_route_merges_dust_and_rebalances_spot() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 1_000_000, 1_000_000);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    pools.push_back(conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        2_000_000,
        1_000_000,
        &clock,
        ctx,
    ));
    pools.push_back(conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1_000_000,
        1_000_000,
        &clock,
        ctx,
    ));

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let (spot_asset_before, spot_stable_before) = unified_spot_pool::get_reserves(&spot_pool);
    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut existing_balance_opt = option::none();

    let mut j = 0u64;
    while (j < 2u64) {
        let stable_in = coin::mint_for_testing<TEST_COIN_B>(10_000, ctx);
        let (mut asset_out_opt, next_balance_opt) = swap_entry::swap_spot_stable_to_asset(
            &mut spot_pool,
            stable_in,
            0,
            @0x1,
            existing_balance_opt,
            true,
            &spot_pool_mutation_registry,
            &escrow_registry,
            &market_state_registry,
            &clock,
            ctx,
        );
        existing_balance_opt = next_balance_opt;

        let asset_out = option::extract(&mut asset_out_opt);
        assert!(asset_out.value() > 0, 70);
        coin::burn_for_testing(asset_out);
        option::destroy_none(asset_out_opt);

        assert!(option::is_some(&existing_balance_opt), 71);
        let dust = option::borrow(&existing_balance_opt);
        assert!(conditional_balance::get_balance(dust, 0, true) > 0, 72);
        assert!(conditional_balance::get_balance(dust, 1, true) == 0, 73);

        j = j + 1;
    };

    let (spot_asset_after, spot_stable_after) = unified_spot_pool::get_reserves(&spot_pool);
    assert!(spot_asset_after != spot_asset_before || spot_stable_after != spot_stable_before, 74);

    conditional_balance::destroy_for_testing(option::extract(&mut existing_balance_opt));
    option::destroy_none(existing_balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_unbacked_better_conditional_quote_repeatedly_falls_back_direct() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));
    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0u64;
    while (i < 2u64) {
        pools.push_back(conditional_amm::create_test_pool(
            market_id,
            (i as u8),
            (DEFAULT_FEE_BPS as u64),
            1_000_000,
            1_000_000,
            &clock,
            ctx,
        ));
        i = i + 1;
    };

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);
    assert!(coin_escrow::get_escrowed_asset_balance(&escrow) == 0, 80);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let mut existing_balance_opt = option::none();

    let mut j = 0u64;
    while (j < 5u64) {
        let direct_quote = unified_spot_pool::simulate_swap_stable_to_asset_accurate(
            &spot_pool,
            1_000,
            &clock,
        );
        let stable_in = coin::mint_for_testing<TEST_COIN_B>(1_000, ctx);
        let (mut asset_out_opt, next_balance_opt) = swap_entry::swap_spot_stable_to_asset(
            &mut spot_pool,
            stable_in,
            direct_quote,
            @0x1,
            existing_balance_opt,
            true,
            &spot_pool_mutation_registry,
            &escrow_registry,
            &market_state_registry,
            &clock,
            ctx,
        );
        existing_balance_opt = next_balance_opt;

        let asset_out = option::extract(&mut asset_out_opt);
        assert!(asset_out.value() == direct_quote, 81);
        assert!(option::is_none(&existing_balance_opt), 82);
        coin::burn_for_testing(asset_out);
        option::destroy_none(asset_out_opt);
        j = j + 1;
    };

    option::destroy_none(existing_balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_conditional_route_transfer_mode_with_dust_does_not_abort() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        1_000_000,
        5_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    seed_lp_backing(&mut escrow, 1_000_000, 1_000_000);
    let market_id = market_state::market_id(coin_escrow::get_market_state(&escrow));

    let mut pools = vector::empty<LiquidityPool>();
    pools.push_back(conditional_amm::create_test_pool(
        market_id,
        0,
        (DEFAULT_FEE_BPS as u64),
        2_000_000,
        1_000_000,
        &clock,
        ctx,
    ));
    pools.push_back(conditional_amm::create_test_pool(
        market_id,
        1,
        (DEFAULT_FEE_BPS as u64),
        1_000_000,
        1_000_000,
        &clock,
        ctx,
    ));

    let escrow_auth = escrow_mutation_auth::create_for_testing();
    let market_state = coin_escrow::get_market_state_mut(&mut escrow, &escrow_auth);
    market_state::set_amm_pools_for_testing(market_state, pools);
    market_state::init_trading_for_testing(market_state);
    lock_pool_with_escrow(&mut spot_pool, escrow);

    let spot_pool_mutation_registry = create_test_spot_pool_mutation_registry(ctx);
    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(10_000, ctx);
    let (asset_out_opt, balance_opt) = swap_entry::swap_spot_stable_to_asset(
        &mut spot_pool,
        stable_in,
        0,
        @0xBEEF,
        option::none(),
        false,
        &spot_pool_mutation_registry,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    assert!(option::is_none(&asset_out_opt), 90);
    assert!(option::is_none(&balance_opt), 91);
    option::destroy_none(asset_out_opt);
    option::destroy_none(balance_opt);
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    spot_pool_mutation_auth::destroy_registry_for_testing(spot_pool_mutation_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 2)] // swap_entry::EBatchEscrowMismatch
fun test_finalize_batch_rejects_mismatched_escrow_market() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);

    let mut spot_pool = create_test_spot_pool(
        200_000_000_000,
        200_000_000,
        (DEFAULT_FEE_BPS as u64),
        &clock,
        ctx,
    );

    let mut escrow_a = create_test_escrow_with_markets(2, 1000, &clock, ctx);
    let mut escrow_b = create_test_escrow_with_markets(2, 1000, &clock, ctx);

    // Enable swaps on both markets so batch/session creation succeeds.
    let auth_a = escrow_mutation_auth::create_for_testing();
    let market_state_a = coin_escrow::get_market_state_mut(&mut escrow_a, &auth_a);
    market_state::init_trading_for_testing(market_state_a);

    let auth_b = escrow_mutation_auth::create_for_testing();
    let market_state_b = coin_escrow::get_market_state_mut(&mut escrow_b, &auth_b);
    market_state::init_trading_for_testing(market_state_b);

    // Batch is created from escrow A.
    let batch_a = swap_entry::begin_conditional_swaps(&escrow_a, &clock, ctx);
    // Session/proposal are created for escrow B.
    let session_b = swap_core::begin_swap_session(&escrow_b);
    let escrow_b_id = object::id(&escrow_b);
    let market_state_b_id = object::id(coin_escrow::get_market_state(&escrow_b));
    let mut proposal_b = setup_proposal_for_testing(escrow_b_id, market_state_b_id, ctx);

    let escrow_registry = create_test_escrow_registry(ctx);
    let market_state_registry = create_test_market_state_registry(ctx);

    // Must fail: batch market (A) does not match finalize escrow market (B).
    swap_entry::finalize_conditional_swaps(
        batch_a,
        &mut spot_pool,
        &mut proposal_b,
        &mut escrow_b,
        session_b,
        @0x1,
        &escrow_registry,
        &market_state_registry,
        &clock,
        ctx,
    );

    // Cleanup (unreachable in expected abort case, required for type checking).
    escrow_mutation_auth::destroy_registry_for_testing(escrow_registry);
    market_state_mutation_auth::destroy_registry_for_testing(market_state_registry);
    unified_spot_pool::destroy_for_testing(spot_pool);
    coin_escrow::destroy_for_testing(escrow_a);
    coin_escrow::destroy_for_testing(escrow_b);
    proposal::destroy_for_testing(proposal_b);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
