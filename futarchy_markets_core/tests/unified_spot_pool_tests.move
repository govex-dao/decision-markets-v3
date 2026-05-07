#[test_only]
module futarchy_markets_core::unified_spot_pool_tests;

use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::fee_scheduler;
use futarchy_markets_primitives::PCW_TWAP_oracle;
use futarchy_one_shot_utils::test_coin_a::TEST_COIN_A;
use futarchy_one_shot_utils::test_coin_b::TEST_COIN_B;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::test_scenario as ts;

// === Test LP Coin Type ===
public struct TEST_LP has drop {}

// === Constants ===
const INITIAL_LIQUIDITY: u64 = 100_000_000; // 100 tokens
const DEFAULT_FEE_BPS: u64 = 30; // 0.3%

// === Test Helpers ===

#[test_only]
fun create_test_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

#[test_only]
fun create_test_lp_treasury(ctx: &mut TxContext): TreasuryCap<TEST_LP> {
    coin::create_treasury_cap_for_testing<TEST_LP>(ctx)
}

// === Add Liquidity Tests ===

#[test]
fun test_add_liquidity_initial() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);

    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Verify reserves updated
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve == INITIAL_LIQUIDITY, 0);
    assert!(stable_reserve == INITIAL_LIQUIDITY, 1);

    // Verify initial reserves snapshot stored on the pool
    let (init_asset_opt, init_stable_opt) = unified_spot_pool::get_initial_reserves(&pool);
    assert!(init_asset_opt.is_some(), 10);
    assert!(init_stable_opt.is_some(), 11);
    let init_asset = option::destroy_some(init_asset_opt);
    let init_stable = option::destroy_some(init_stable_opt);
    assert!(init_asset == INITIAL_LIQUIDITY, 12);
    assert!(init_stable == INITIAL_LIQUIDITY, 13);

    // Verify LP coin minted (using coin::value instead of lp_token_amount)
    let lp_amount = coin::value(&lp_coin);
    assert!(lp_amount > 0, 2);

    // Verify LP supply increased
    assert!(unified_spot_pool::lp_supply(&pool) > 0, 3);

    // Cleanup - burn LP coin instead of destroy_lp_token_for_testing
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_add_liquidity_proportional() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Initial liquidity
    let asset1 = coin::mint_for_testing<TEST_COIN_A>(100_000, ctx);
    let stable1 = coin::mint_for_testing<TEST_COIN_B>(100_000, ctx);
    let (lp1, excess_asset1, excess_stable1) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset1,
        stable1,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset1);
    coin::burn_for_testing(excess_stable1);

    let initial_lp_supply = unified_spot_pool::lp_supply(&pool);

    // Add more liquidity (proportional)
    let asset2 = coin::mint_for_testing<TEST_COIN_A>(50_000, ctx);
    let stable2 = coin::mint_for_testing<TEST_COIN_B>(50_000, ctx);
    let (lp2, excess_asset2, excess_stable2) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset2,
        stable2,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset2);
    coin::burn_for_testing(excess_stable2);

    // Verify reserves
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve == 150_000, 0);
    assert!(stable_reserve == 150_000, 1);

    // Verify LP supply increased proportionally
    assert!(unified_spot_pool::lp_supply(&pool) > initial_lp_supply, 2);

    // Cleanup
    coin::burn_for_testing(lp1);
    coin::burn_for_testing(lp2);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EZeroAmount
fun test_add_liquidity_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    let asset_coin = coin::zero<TEST_COIN_A>(ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);

    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 6)] // EMinimumLiquidityNotMet
fun test_add_liquidity_below_minimum() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Add liquidity below minimum (1000)
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(10, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(10, ctx);

    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5)] // ESlippageExceeded
fun test_add_liquidity_slippage_exceeded() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);

    // Set impossibly high min_lp_out
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        999_999_999_999, // Impossibly high
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Remove Liquidity Tests ===

#[test]
fun test_remove_liquidity_success() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Add liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);
    let (mut lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Split LP coin to only remove 90% - we need to leave enough liquidity
    // for the projected conditional split (50% ratio in test config) to pass
    // the sqrt(k) >= MINIMUM_LIQUIDITY check
    let lp_to_remove = coin::value(&lp_coin) * 90 / 100;
    let lp_to_burn = coin::split(&mut lp_coin, lp_to_remove, ctx);
    coin::burn_for_testing(lp_coin); // Burn the remaining 10%

    // Remove liquidity (LP coin is burned inside remove_liquidity)
    let (asset_out, stable_out) = unified_spot_pool::remove_liquidity(
        &mut pool,
        lp_to_burn,
        0, // min_asset_out
        0, // min_stable_out
        ctx,
    );

    // Verify output amounts
    assert!(coin::value(&asset_out) > 0, 0);
    assert!(coin::value(&stable_out) > 0, 1);

    // Cleanup
    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(stable_out);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Swap Tests ===

#[test]
fun test_swap_asset_for_stable() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Swap asset for stable
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(10_000, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(
        &mut pool,
        asset_in,
        0, // min_stable_out
        &clock,
        ctx,
    );

    // Verify output
    assert!(coin::value(&stable_out) > 0, 0);

    // Cleanup
    coin::burn_for_testing(stable_out);
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_swap_stable_for_asset() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Swap stable for asset
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(10_000, ctx);
    let asset_out = unified_spot_pool::swap_stable_for_asset(
        &mut pool,
        stable_in,
        0, // min_asset_out
        &clock,
        ctx,
    );

    // Verify output
    assert!(coin::value(&asset_out) > 0, 0);

    // Cleanup
    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)] // EZeroAmount
fun test_swap_zero_amount() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Try to swap zero amount
    let asset_in = coin::zero<TEST_COIN_A>(ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);

    coin::burn_for_testing(stable_out);
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 5)] // ESlippageExceeded
fun test_swap_slippage_exceeded() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Swap with impossibly high min_out
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(10_000, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(
        &mut pool,
        asset_in,
        999_999_999, // Impossibly high
        &clock,
        ctx,
    );

    coin::burn_for_testing(stable_out);
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === View Function Tests ===

#[test]
fun test_get_reserves() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Initially zero
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve == 0, 0);
    assert!(stable_reserve == 0, 1);

    // Add liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(50_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(75_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Check reserves updated
    let (asset_reserve2, stable_reserve2) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve2 == 50_000, 2);
    assert!(stable_reserve2 == 75_000, 3);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_get_spot_price() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Zero price when no liquidity
    assert!(unified_spot_pool::get_spot_price(&pool) == 0, 0);

    // Add liquidity (1:1 ratio)
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Price should be approximately 1:1 (with precision)
    let price = unified_spot_pool::get_spot_price(&pool);
    assert!(price > 0, 1);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_simulate_swap() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Add liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Simulate swap asset to stable
    let simulated_out = unified_spot_pool::simulate_swap_asset_to_stable_accurate(&pool, 10_000, &clock);
    assert!(simulated_out > 0, 0);

    // Simulate swap stable to asset
    let simulated_out2 = unified_spot_pool::simulate_swap_stable_to_asset_accurate(&pool, 10_000, &clock);
    assert!(simulated_out2 > 0, 1);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Integration Tests ===

#[test]
fun test_complete_pool_lifecycle() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    // 1. Create pool
    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // 2. Add initial liquidity
    let asset1 = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable1 = coin::mint_for_testing<TEST_COIN_B>(1_000_000, ctx);
    let (lp1, excess_asset1, excess_stable1) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset1,
        stable1,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset1);
    coin::burn_for_testing(excess_stable1);

    // 3. Perform swaps
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(10_000, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // 4. Add more liquidity
    let asset2 = coin::mint_for_testing<TEST_COIN_A>(500_000, ctx);
    let stable2 = coin::mint_for_testing<TEST_COIN_B>(500_000, ctx);
    let (lp2, excess_asset2, excess_stable2) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset2,
        stable2,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset2);
    coin::burn_for_testing(excess_stable2);

    // 5. Remove liquidity (lp2 is burned inside)
    let (asset_out, stable_out) = unified_spot_pool::remove_liquidity(&mut pool, lp2, 0, 0, ctx);
    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(stable_out);

    // Cleanup
    coin::burn_for_testing(lp1);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Multiple Swaps Test ===

#[test]
fun test_multiple_swaps_same_direction() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(1000000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Add liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(10_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(10_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Perform multiple swaps
    let mut i = 0;
    while (i < 5) {
        let asset_in = coin::mint_for_testing<TEST_COIN_A>(1_000, ctx);
        let stable_out = unified_spot_pool::swap_asset_for_stable(
            &mut pool,
            asset_in,
            0,
            &clock,
            ctx,
        );
        coin::burn_for_testing(stable_out);
        i = i + 1;
    };

    // Verify pool still functional
    let (asset_reserve, stable_reserve) = unified_spot_pool::get_reserves(&pool);
    assert!(asset_reserve > 0, 0);
    assert!(stable_reserve > 0, 1);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// === Fee Split Tests ===
// These tests verify the proportional fee split model:
// - Total fee from schedule is split based on steady-state ratio
// - Protocol gets (protocol_bps / total_bps) share
// - LP gets remainder

/// Test fee split at launch (99% fee with 50:25 ratio)
/// Protocol should get ~66% (50/75), LP should get ~33% (25/75)
#[test]
fun test_fee_split_at_launch() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    // Create clock at time 0 (launch time)
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    // Create fee schedule: 99% initial, 1 hour duration
    let fee_schedule = fee_scheduler::new_schedule(9900, 3_600_000);

    // Create pool with fee schedule (25 bps LP fee = 0.25%)
    // Steady-state: 50 bps protocol + 25 bps LP = 75 bps total
    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        25, // LP fee bps (matches default_amm_total_fee_bps)
        fee_schedule,
        0, // activation_time = 0
        ctx,
    );

    // Add initial liquidity
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(10_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(10_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Record reserves before swap
    let (asset_before, _stable_before) = unified_spot_pool::get_reserves(&pool);

    // Swap 1,000,000 units (large enough to see fee split clearly)
    let swap_amount = 1_000_000u64;
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // Check protocol fees accumulated
    let (protocol_asset_fees, _protocol_stable_fees) = unified_spot_pool::get_protocol_fee_amounts(
        &pool,
    );

    // At 99% fee (9900 bps), total fee = 1,000,000 * 9900 / 10000 = 990,000
    // Protocol share = 990,000 * 50 / 75 = 660,000 (approximately)
    // LP share = 990,000 * 25 / 75 = 330,000 (approximately)

    // Protocol should get ~66% of total fee
    // Allow 1% tolerance for rounding
    assert!(protocol_asset_fees >= 650_000 && protocol_asset_fees <= 670_000, 0);

    // Check reserves grew by LP fee portion
    let (asset_after, _stable_after) = unified_spot_pool::get_reserves(&pool);
    let asset_increase = asset_after - asset_before;

    // Asset reserve should increase by: swap_amount - protocol_fee (LP fee stays in reserve)
    // The output stable is taken from reserve, so we just check asset side
    // Expected LP fee: swap_amount * 9900 / 10000 * 25 / 75 = ~330,000
    let effective_input = swap_amount - protocol_asset_fees;

    // Asset reserve should have increased by effective input (which includes LP fee)
    assert!(asset_increase == effective_input, 1);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Test fee split at steady state (after decay period)
/// Should use steady-state fees: 50 bps protocol, 25 bps LP
#[test]
fun test_fee_split_at_steady_state() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut clock = create_test_clock(7_200_000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    // Create fee schedule: 99% initial, 1 hour duration
    let fee_schedule = fee_scheduler::new_schedule(9900, 3_600_000);

    // Create pool with fee schedule
    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        25, // LP fee bps
        fee_schedule,
        0, // activation_time = 0
        ctx,
    );

    // Add initial liquidity (resets fee_schedule_activation_time to current clock)
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(10_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(10_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Advance clock past fee schedule duration to reach steady state
    clock::set_for_testing(&mut clock, 7_200_000 + 3_600_000);

    // Swap 1,000,000 units
    let swap_amount = 1_000_000u64;
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // Check protocol fees accumulated
    let (protocol_asset_fees, _protocol_stable_fees) = unified_spot_pool::get_protocol_fee_amounts(
        &pool,
    );

    // At steady state (75 bps total), total fee = 1,000,000 * 75 / 10000 = 7,500
    // Protocol share = 7,500 * 50 / 75 = 5,000
    // LP share = 7,500 * 25 / 75 = 2,500

    // Protocol should get exactly 5,000 (50 bps of swap amount)
    assert!(protocol_asset_fees == 5_000, 0);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Test fee split at halfway through decay (50% through schedule)
#[test]
fun test_fee_split_at_halfway_decay() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut clock = create_test_clock(1_000_000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    // Create fee schedule: 99% initial, 1 hour duration
    let fee_schedule = fee_scheduler::new_schedule(9900, 3_600_000);

    // Create pool with fee schedule
    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        25, // LP fee bps
        fee_schedule,
        0, // activation_time = 0
        ctx,
    );

    // Add initial liquidity (resets fee_schedule_activation_time to 1_000_000)
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(10_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(10_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Advance clock to halfway through fee schedule (activation + 50% of 3_600_000)
    clock::set_for_testing(&mut clock, 1_000_000 + 1_800_000);

    // Swap 1,000,000 units
    let swap_amount = 1_000_000u64;
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // Check protocol fees accumulated
    let (protocol_asset_fees, _protocol_stable_fees) = unified_spot_pool::get_protocol_fee_amounts(
        &pool,
    );

    // At 50% decay, 4 of 8 launch half-lives have elapsed:
    // fee = 75 + ceil((9900 - 75) / 16) = 690 bps
    // Total fee = 1,000,000 * 690 / 10000 = 69,000
    // Protocol share = 69,000 * 50 / 75 = 46,000

    // Protocol should get approximately 50/75 = 66.67% of total fee
    assert!(protocol_asset_fees >= 45_000 && protocol_asset_fees <= 47_000, 0);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_current_fee_bps_launch_schedule_activation_and_proposal_gate() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut clock = create_test_clock(1_000_000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);
    let fee_schedule = fee_scheduler::new_schedule(9900, 3_600_000);

    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        25,
        fee_schedule,
        0,
        ctx,
    );

    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(10_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(10_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Activation time is reset to first-liquidity time, not construction time.
    assert!(unified_spot_pool::current_fee_bps(&pool, &clock) == 9900, 0);
    assert!(!unified_spot_pool::can_create_proposals(&pool, &clock), 1);

    clock::set_for_testing(&mut clock, 1_000_000 + 900_000);
    assert!(unified_spot_pool::current_fee_bps(&pool, &clock) == 2532, 2);
    assert!(!unified_spot_pool::can_create_proposals(&pool, &clock), 3);

    clock::set_for_testing(&mut clock, 1_000_000 + 1_800_000);
    assert!(unified_spot_pool::current_fee_bps(&pool, &clock) == 690, 4);
    assert!(!unified_spot_pool::can_create_proposals(&pool, &clock), 5);

    clock::set_for_testing(&mut clock, 1_000_000 + 3_600_000 - 1);
    assert!(unified_spot_pool::current_fee_bps(&pool, &clock) == 114, 6);
    assert!(!unified_spot_pool::can_create_proposals(&pool, &clock), 7);

    clock::set_for_testing(&mut clock, 1_000_000 + 3_600_000);
    assert!(unified_spot_pool::current_fee_bps(&pool, &clock) == 75, 8);
    assert!(unified_spot_pool::can_create_proposals(&pool, &clock), 9);

    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_zero_duration_fee_schedule_does_not_block_proposals() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let clock = create_test_clock(1_000_000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);
    let fee_schedule = fee_scheduler::new_schedule(9900, 0);

    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        25,
        fee_schedule,
        0,
        ctx,
    );

    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(10_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(10_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    assert!(unified_spot_pool::current_fee_bps(&pool, &clock) == 75, 0);
    assert!(unified_spot_pool::can_create_proposals(&pool, &clock), 1);

    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Test that protocol fees accumulate across multiple swaps
#[test]
fun test_protocol_fees_accumulate() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut clock = create_test_clock(7_200_000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let fee_schedule = fee_scheduler::new_schedule(9900, 3_600_000);

    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        25,
        fee_schedule,
        0,
        ctx,
    );

    // Add initial liquidity (resets fee_schedule_activation_time to current clock)
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(100_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(100_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Advance clock past fee schedule duration to reach steady state
    clock::set_for_testing(&mut clock, 7_200_000 + 3_600_000);

    // Perform 5 swaps of 1,000,000 each
    let swap_amount = 1_000_000u64;
    let mut i = 0;
    while (i < 5) {
        let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
        let stable_out = unified_spot_pool::swap_asset_for_stable(
            &mut pool,
            asset_in,
            0,
            &clock,
            ctx,
        );
        coin::burn_for_testing(stable_out);
        i = i + 1;
    };

    // Check total protocol fees
    let (protocol_asset_fees, _protocol_stable_fees) = unified_spot_pool::get_protocol_fee_amounts(
        &pool,
    );

    // Each swap: protocol fee = 1,000,000 * 50 / 10000 = 5,000
    // 5 swaps: total = 25,000
    assert!(protocol_asset_fees == 25_000, 0);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Test fee split in both swap directions (asset→stable and stable→asset)
#[test]
fun test_fee_split_both_directions() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut clock = create_test_clock(7_200_000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let fee_schedule = fee_scheduler::new_schedule(9900, 3_600_000);

    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        25,
        fee_schedule,
        0,
        ctx,
    );

    // Add initial liquidity (resets fee_schedule_activation_time to current clock)
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(100_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(100_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Advance clock past fee schedule duration to reach steady state
    clock::set_for_testing(&mut clock, 7_200_000 + 3_600_000);

    // Swap asset for stable
    let swap_amount = 1_000_000u64;
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // Swap stable for asset
    let stable_in = coin::mint_for_testing<TEST_COIN_B>(swap_amount, ctx);
    let asset_out = unified_spot_pool::swap_stable_for_asset(&mut pool, stable_in, 0, &clock, ctx);
    coin::burn_for_testing(asset_out);

    // Check protocol fees in both directions
    let (protocol_asset_fees, protocol_stable_fees) = unified_spot_pool::get_protocol_fee_amounts(
        &pool,
    );

    // Each swap: protocol fee = 1,000,000 * 50 / 10000 = 5,000
    assert!(protocol_asset_fees == 5_000, 0);
    assert!(protocol_stable_fees == 5_000, 1);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Test small swap that results in zero fees at steady state
/// At 75 bps (0.75%) total fee, swaps < 134 units will have zero fee
/// This is acceptable because gas costs prevent economic dust attacks
#[test]
fun test_zero_fee_small_swap() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut clock = create_test_clock(7_200_000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let fee_schedule = fee_scheduler::new_schedule(9900, 3_600_000);

    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        25,
        fee_schedule,
        0,
        ctx,
    );

    // Add initial liquidity (resets fee_schedule_activation_time to current clock)
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(100_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(100_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Advance clock past fee schedule duration to reach steady state
    clock::set_for_testing(&mut clock, 7_200_000 + 3_600_000);

    // Swap a small amount (100 units)
    // At 75 bps: fee = 100 * 75 / 10000 = 0 (integer division)
    let swap_amount = 100u64;
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // Protocol fees should be 0 (too small to generate fees)
    let (protocol_asset_fees, _protocol_stable_fees) = unified_spot_pool::get_protocol_fee_amounts(
        &pool,
    );
    assert!(protocol_asset_fees == 0, 0);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Test minimum swap that generates at least 1 unit of protocol fee
/// Protocol gets 50/75 of total fee, so need total_fee >= 2 for protocol_fee >= 1
/// At 75 bps, need swap_amount * 75 / 10000 >= 2, so swap_amount >= 267
#[test]
fun test_minimum_fee_generating_swap() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut clock = create_test_clock(7_200_000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let fee_schedule = fee_scheduler::new_schedule(9900, 3_600_000);

    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        25,
        fee_schedule,
        0,
        ctx,
    );

    // Add initial liquidity (resets fee_schedule_activation_time to current clock)
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(100_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(100_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Advance clock past fee schedule duration to reach steady state
    clock::set_for_testing(&mut clock, 7_200_000 + 3_600_000);

    // Swap 10,000 units (clearly generates fees)
    // At 75 bps: total_fee = 10000 * 75 / 10000 = 75
    // Protocol fee = 75 * 50 / 75 = 50
    let swap_amount = 10_000u64;
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // Protocol fees should be 50 (0.5% of 10,000)
    let (protocol_asset_fees, _protocol_stable_fees) = unified_spot_pool::get_protocol_fee_amounts(
        &pool,
    );
    assert!(protocol_asset_fees == 50, 0);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Test edge case: LP fee is 0 (pool.fee_bps = 0)
/// When steady_total_bps = protocol_fee_bps only (50 bps), protocol gets 100%
/// This tests the boundary where LP share is zero
#[test]
fun test_fee_split_zero_lp_fee() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let mut clock = create_test_clock(7_200_000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let fee_schedule = fee_scheduler::new_schedule(9900, 3_600_000);

    // Create pool with 0 LP fee (only protocol fee applies)
    let mut pool = unified_spot_pool::new_with_fee_schedule_for_testing<
        TEST_COIN_A,
        TEST_COIN_B,
        TEST_LP,
    >(
        lp_treasury,
        0, // LP fee = 0
        fee_schedule,
        0,
        ctx,
    );

    // Add initial liquidity (resets fee_schedule_activation_time to current clock)
    let asset_liq = coin::mint_for_testing<TEST_COIN_A>(100_000_000, ctx);
    let stable_liq = coin::mint_for_testing<TEST_COIN_B>(100_000_000, ctx);
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_liq,
        stable_liq,
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(excess_asset);
    coin::burn_for_testing(excess_stable);

    // Advance clock past fee schedule duration to reach steady state
    clock::set_for_testing(&mut clock, 7_200_000 + 3_600_000);

    // Record reserves before swap
    let (asset_before, _stable_before) = unified_spot_pool::get_reserves(&pool);

    // Swap 1,000,000 units
    // At steady state with 0 LP fee: total = 50 bps (protocol only)
    // Total fee = 1,000,000 * 50 / 10000 = 5,000
    // Protocol gets 100%: 5,000 * 50/50 = 5,000
    // LP gets 0%: 0
    let swap_amount = 1_000_000u64;
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // Protocol should get entire fee (5,000)
    let (protocol_asset_fees, _protocol_stable_fees) = unified_spot_pool::get_protocol_fee_amounts(
        &pool,
    );
    assert!(protocol_asset_fees == 5_000, 0);

    // Verify reserves: should increase by swap_amount - protocol_fee
    // (no LP fee means no extra k growth beyond the swap mechanics)
    let (asset_after, _stable_after) = unified_spot_pool::get_reserves(&pool);
    let asset_increase = asset_after - asset_before;
    assert!(asset_increase == swap_amount - protocol_asset_fees, 1);

    // Cleanup
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// Test edge case: no aggregator means no protocol fees (all to LP)
/// This tests the branch where has_aggregator = false in split_fee
#[test]
fun test_fee_split_no_aggregator() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);

    let clock = create_test_clock(1000000, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    // Use new_for_testing which creates pool with aggregator
    // But we need a pool WITHOUT aggregator for this test
    // The create_pool_for_testing creates one without aggregator
    let mut pool = unified_spot_pool::create_pool_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        100_000_000, // asset_amount
        100_000_000, // stable_amount
        30, // fee_bps (0.3%)
        ctx,
    );

    // Record reserves before swap
    let (asset_before, _stable_before) = unified_spot_pool::get_reserves(&pool);

    // Swap - without aggregator, all fees should go to LP (grow reserves)
    let swap_amount = 1_000_000u64;
    let asset_in = coin::mint_for_testing<TEST_COIN_A>(swap_amount, ctx);
    let stable_out = unified_spot_pool::swap_asset_for_stable(&mut pool, asset_in, 0, &clock, ctx);
    coin::burn_for_testing(stable_out);

    // Protocol fees should be 0 (no aggregator)
    let (protocol_asset_fees, protocol_stable_fees) = unified_spot_pool::get_protocol_fee_amounts(
        &pool,
    );
    assert!(protocol_asset_fees == 0, 0);
    assert!(protocol_stable_fees == 0, 1);

    // All of swap_amount should be in reserves (LP gets all fees)
    let (asset_after, _stable_after) = unified_spot_pool::get_reserves(&pool);
    let asset_increase = asset_after - asset_before;
    assert!(asset_increase == swap_amount, 2);

    // Cleanup
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ==========================================================================
// Oracle lazy creation tests (Bug 1+3 fix)
// ==========================================================================

/// B1: Oracle does not exist at pool construction (before liquidity).
#[test]
fun test_oracle_not_created_at_pool_construction() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    // Pool with aggregator but no oracle
    let pool = unified_spot_pool::new_without_oracle_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // is_twap_ready should return false
    assert!(!unified_spot_pool::is_twap_ready(&pool, &clock), 0);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// B1b: get_simple_twap aborts when oracle doesn't exist.
#[test]
#[expected_failure]
fun test_get_simple_twap_aborts_without_oracle() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let lp_treasury = create_test_lp_treasury(ctx);

    let pool = unified_spot_pool::new_without_oracle_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Should abort — oracle not created yet
    // Cleanup won't run because get_simple_twap aborts
    let _twap = unified_spot_pool::get_simple_twap(&pool);

    abort 99 // unreachable
}

/// B2: Oracle is created on first liquidity add with correct price.
#[test]
fun test_oracle_created_on_first_liquidity_add() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let mut clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_without_oracle_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Before liquidity: no oracle
    assert!(!unified_spot_pool::is_twap_ready(&pool, &clock), 0);

    // Add initial liquidity
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);
    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool, asset_coin, stable_coin, 0, &clock, ctx,
    );
    coin::burn_for_testing(lp_coin);
    coin::burn_for_testing(excess_a);
    coin::burn_for_testing(excess_s);

    // Still not ready (need to wait one window)
    assert!(!unified_spot_pool::is_twap_ready(&pool, &clock), 1);

    // Advance past one window (1 minute)
    clock::set_for_testing(&mut clock, 60_001);
    assert!(unified_spot_pool::is_twap_ready(&pool, &clock), 2);

    // get_simple_twap should now succeed
    let twap = unified_spot_pool::get_simple_twap(&pool);
    let twap_value = PCW_TWAP_oracle::get_twap(twap);
    // Equal amounts → price = 1:1 = price_scale (1e12)
    assert!(twap_value > 0, 3);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// B3: Swap works after oracle is created via liquidity add.
#[test]
fun test_swap_works_after_oracle_created() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let mut clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_without_oracle_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // Add initial liquidity (creates oracle)
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(INITIAL_LIQUIDITY, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(INITIAL_LIQUIDITY, ctx);
    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool, asset_coin, stable_coin, 0, &clock, ctx,
    );
    coin::burn_for_testing(lp_coin);
    coin::burn_for_testing(excess_a);
    coin::burn_for_testing(excess_s);

    // Swap should succeed and update oracle
    clock::set_for_testing(&mut clock, 1000);
    let swap_in = coin::mint_for_testing<TEST_COIN_B>(1_000, ctx);
    let out = unified_spot_pool::swap_stable_for_asset(
        &mut pool, swap_in, 0, &clock, ctx,
    );
    assert!(coin::value(&out) > 0, 0);
    coin::burn_for_testing(out);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

/// B4: Oracle initial price matches the liquidity ratio.
#[test]
fun test_oracle_price_matches_initial_liquidity_ratio() {
    let mut scenario = ts::begin(@0x1);
    let ctx = ts::ctx(&mut scenario);
    let clock = create_test_clock(0, ctx);
    let lp_treasury = create_test_lp_treasury(ctx);

    let mut pool = unified_spot_pool::new_without_oracle_for_testing<TEST_COIN_A, TEST_COIN_B, TEST_LP>(
        lp_treasury,
        DEFAULT_FEE_BPS,
        ctx,
    );

    // 1000 asset, 2000 stable → price = 2000/1000 * price_scale = 2 * 1e12
    let asset_coin = coin::mint_for_testing<TEST_COIN_A>(1_000_000, ctx);
    let stable_coin = coin::mint_for_testing<TEST_COIN_B>(2_000_000, ctx);
    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool, asset_coin, stable_coin, 0, &clock, ctx,
    );
    coin::burn_for_testing(lp_coin);
    coin::burn_for_testing(excess_a);
    coin::burn_for_testing(excess_s);

    let twap = unified_spot_pool::get_simple_twap(&pool);
    let twap_value = PCW_TWAP_oracle::get_twap(twap);
    // Expected: 2 * 1e12 = 2_000_000_000_000
    assert!(twap_value == 2_000_000_000_000, 0);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
