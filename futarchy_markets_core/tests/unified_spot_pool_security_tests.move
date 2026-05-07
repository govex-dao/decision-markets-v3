#[test_only]
module futarchy_markets_core::unified_spot_pool_security_tests;

use futarchy_core::escrow_mutation_auth;
use futarchy_markets_core::spot_pool_mutation_auth;
use futarchy_markets_core::unified_spot_pool::{Self as unified_spot_pool, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self as coin_escrow, TokenEscrow};
use futarchy_markets_primitives::market_state;
use sui::balance;
use sui::clock::{Self as clock};
use sui::coin::{Self as coin, Coin, TreasuryCap};
use sui::test_scenario as ts;

public struct ASSET has drop {}
public struct STABLE has drop {}
public struct LP has drop {}

const ADMIN: address = @0xAD;

fun asset_coin(amount: u64, ctx: &mut TxContext): Coin<ASSET> {
    coin::from_balance(balance::create_for_testing<ASSET>(amount), ctx)
}

fun stable_coin(amount: u64, ctx: &mut TxContext): Coin<STABLE> {
    coin::from_balance(balance::create_for_testing<STABLE>(amount), ctx)
}

fun burn_or_destroy_zero<T>(c: Coin<T>) {
    if (coin::value(&c) == 0) {
        coin::destroy_zero(c);
    } else {
        coin::burn_for_testing(c);
    };
}

fun finalized_test_escrow(ctx: &mut TxContext): TokenEscrow<ASSET, STABLE> {
    let mut escrow = coin_escrow::create_test_escrow<ASSET, STABLE>(2, ctx);
    let auth = escrow_mutation_auth::create_for_testing();
    let state = coin_escrow::get_market_state_mut(&mut escrow, &auth);
    market_state::finalize_for_testing(state);
    escrow
}

#[test]
fun test_can_create_proposals_requires_initial_liquidity() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    assert!(!unified_spot_pool::can_create_proposals(&pool, &clock), 0);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    assert!(unified_spot_pool::can_create_proposals(&pool, &clock), 1);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 23, location = futarchy_markets_core::unified_spot_pool)]
fun test_swap_stable_for_asset_zero_output_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000_000_000, ctx),
        stable_coin(1_000_000_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    // Input is > fee but rounds to 0 output; should abort with EAmountTooSmall (23).
    let out = unified_spot_pool::swap_stable_for_asset(
        &mut pool,
        stable_coin(1, ctx),
        0,
        &clock,
        ctx,
    );
    burn_or_destroy_zero(out);

    // Unreachable cleanup
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun test_swap_stable_for_asset_succeeds_when_inactive_escrow_present() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    let escrow = finalized_test_escrow(ctx);
    let auth = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_active_escrow(&mut pool, escrow, auth);

    let out = unified_spot_pool::swap_stable_for_asset(
        &mut pool,
        stable_coin(1_000, ctx),
        0,
        &clock,
        ctx,
    );
    burn_or_destroy_zero(out);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun test_review_escrow_does_not_lock_spot_swaps_before_quantum_split() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    let escrow = coin_escrow::create_test_escrow<ASSET, STABLE>(2, ctx);
    let auth = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_active_escrow(&mut pool, escrow, auth);

    assert!(!unified_spot_pool::is_locked_for_proposal(&pool), 1);

    let out = unified_spot_pool::swap_stable_for_asset(
        &mut pool,
        stable_coin(1_000, ctx),
        0,
        &clock,
        ctx,
    );
    burn_or_destroy_zero(out);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 15, location = futarchy_markets_core::unified_spot_pool)]
fun test_swap_stable_for_asset_aborts_when_active_proposal_present() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    unified_spot_pool::set_active_proposal_for_testing(&mut pool, object::id_from_address(@0xCAFE));

    let out = unified_spot_pool::swap_stable_for_asset(
        &mut pool,
        stable_coin(1_000, ctx),
        0,
        &clock,
        ctx,
    );
    burn_or_destroy_zero(out);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun test_swap_stable_for_asset_with_extracted_escrow_succeeds_under_active_proposal() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    let escrow = coin_escrow::create_test_escrow<ASSET, STABLE>(2, ctx);
    let market_id = coin_escrow::market_state_id(&escrow);
    let auth_store = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_active_escrow(&mut pool, escrow, auth_store);
    unified_spot_pool::set_active_proposal_for_testing(&mut pool, object::id_from_address(@0xCAFE));

    let auth_extract = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    let (escrow_out, was_active) = unified_spot_pool::extract_escrow_by_market_id(
        &mut pool,
        market_id,
        auth_extract,
    );
    assert!(was_active, 0);

    let auth_swap = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    let out = unified_spot_pool::swap_stable_for_asset_with_escrow_extracted(
        &mut pool,
        stable_coin(1_000, ctx),
        0,
        &clock,
        ctx,
        auth_swap,
    );
    burn_or_destroy_zero(out);

    let auth_restore = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_extracted_escrow(&mut pool, escrow_out, was_active, auth_restore);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun test_swap_asset_for_stable_with_extracted_escrow_succeeds_under_active_proposal() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    let escrow = coin_escrow::create_test_escrow<ASSET, STABLE>(2, ctx);
    let market_id = coin_escrow::market_state_id(&escrow);
    let auth_store = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_active_escrow(&mut pool, escrow, auth_store);
    unified_spot_pool::set_active_proposal_for_testing(&mut pool, object::id_from_address(@0xCAFE));

    let auth_extract = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    let (escrow_out, was_active) = unified_spot_pool::extract_escrow_by_market_id(
        &mut pool,
        market_id,
        auth_extract,
    );
    assert!(was_active, 0);

    let auth_swap = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    let out = unified_spot_pool::swap_asset_for_stable_with_escrow_extracted(
        &mut pool,
        asset_coin(1_000, ctx),
        0,
        &clock,
        ctx,
        auth_swap,
    );
    burn_or_destroy_zero(out);

    let auth_restore = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_extracted_escrow(&mut pool, escrow_out, was_active, auth_restore);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 36, location = futarchy_markets_core::unified_spot_pool)]
fun test_swap_with_extracted_escrow_aborts_when_active_escrow_still_present() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    let escrow = coin_escrow::create_test_escrow<ASSET, STABLE>(2, ctx);
    let auth_store = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_active_escrow(&mut pool, escrow, auth_store);

    let auth_swap = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    let out = unified_spot_pool::swap_stable_for_asset_with_escrow_extracted(
        &mut pool,
        stable_coin(1_000, ctx),
        0,
        &clock,
        ctx,
        auth_swap,
    );
    burn_or_destroy_zero(out);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 23, location = futarchy_markets_core::unified_spot_pool)]
fun test_swap_asset_for_stable_zero_output_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000_000_000, ctx),
        stable_coin(1_000_000_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    // Input is > fee but rounds to 0 output; should abort with EAmountTooSmall (23).
    let out = unified_spot_pool::swap_asset_for_stable(
        &mut pool,
        asset_coin(1, ctx),
        0,
        &clock,
        ctx,
    );
    burn_or_destroy_zero(out);

    // Unreachable cleanup
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun test_swap_asset_for_stable_succeeds_when_inactive_escrow_present() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    let escrow = finalized_test_escrow(ctx);
    let auth = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_active_escrow(&mut pool, escrow, auth);

    let out = unified_spot_pool::swap_asset_for_stable(
        &mut pool,
        asset_coin(1_000, ctx),
        0,
        &clock,
        ctx,
    );
    burn_or_destroy_zero(out);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 15, location = futarchy_markets_core::unified_spot_pool)]
fun test_swap_asset_for_stable_aborts_when_active_proposal_present() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    unified_spot_pool::set_active_proposal_for_testing(&mut pool, object::id_from_address(@0xCAFE));

    let out = unified_spot_pool::swap_asset_for_stable(
        &mut pool,
        asset_coin(1_000, ctx),
        0,
        &clock,
        ctx,
    );
    burn_or_destroy_zero(out);

    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun test_extract_escrow_by_market_id_archived_and_active_paths() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let escrow_a = finalized_test_escrow(ctx);
    let market_a = coin_escrow::market_state_id(&escrow_a);
    let auth_a = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_active_escrow(&mut pool, escrow_a, auth_a);

    let escrow_b = coin_escrow::create_test_escrow<ASSET, STABLE>(2, ctx);
    let market_b = coin_escrow::market_state_id(&escrow_b);
    let auth_b = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_active_escrow(&mut pool, escrow_b, auth_b);

    let auth_extract_a = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    let (escrow_a_out, was_active_a) = unified_spot_pool::extract_escrow_by_market_id(
        &mut pool,
        market_a,
        auth_extract_a,
    );
    assert!(!was_active_a, 10);
    assert!(coin_escrow::market_state_id(&escrow_a_out) == market_a, 11);
    let auth_restore_a = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_extracted_escrow(&mut pool, escrow_a_out, was_active_a, auth_restore_a);

    let auth_extract_b = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    let (escrow_b_out, was_active_b) = unified_spot_pool::extract_escrow_by_market_id(
        &mut pool,
        market_b,
        auth_extract_b,
    );
    assert!(was_active_b, 12);
    assert!(coin_escrow::market_state_id(&escrow_b_out) == market_b, 13);
    let auth_restore_b = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::store_extracted_escrow(&mut pool, escrow_b_out, was_active_b, auth_restore_b);

    unified_spot_pool::destroy_for_testing(pool);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 30, location = futarchy_markets_core::unified_spot_pool)]
fun test_extract_escrow_by_market_id_not_found_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let dummy = object::new(ctx);
    let missing_market = dummy.uid_to_inner();
    object::delete(dummy);

    let auth = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    let (escrow, _was_active) = unified_spot_pool::extract_escrow_by_market_id(
        &mut pool,
        missing_market,
        auth,
    );

    // Unreachable cleanup
    coin_escrow::destroy_for_testing(escrow);
    unified_spot_pool::destroy_for_testing(pool);
    scenario.end();
}

#[test]
fun test_remove_liquidity_ignores_projected_split_when_no_proposal() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    // Initial liquidity at the edge where minimum-liquidity holds but
    // a hypothetical 50% proposal split would fail.
    let (mut lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(2_000, ctx),
        stable_coin(2_000, ctx),
        0,
        &clock,
        ctx,
    );
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    // Remove 800/2000 LP supply-equivalent share; this should succeed when no proposal is active.
    let lp_to_remove = coin::split(&mut lp_coin, 800, ctx);
    let (asset_out, stable_out) = unified_spot_pool::remove_liquidity(
        &mut pool,
        lp_to_remove,
        0,
        0,
        ctx,
    );

    assert!(coin::value(&asset_out) > 0, 20);
    assert!(coin::value(&stable_out) > 0, 21);

    coin::burn_for_testing(asset_out);
    coin::burn_for_testing(stable_out);
    coin::burn_for_testing(lp_coin);
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 15, location = futarchy_markets_core::unified_spot_pool)]
fun test_mark_liquidity_to_proposal_aborts_when_active_proposal_present() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_000_000, ctx),
        stable_coin(1_000_000, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    unified_spot_pool::set_active_proposal_for_testing(
        &mut pool,
        object::id_from_address(@0xCAFE),
    );

    let auth = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::mark_liquidity_to_proposal(&mut pool, 50, &clock, auth);

    // Unreachable cleanup
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 6, location = futarchy_markets_core::unified_spot_pool)]
fun test_mark_liquidity_to_proposal_aborts_when_projected_spot_below_minimum() {
    let mut scenario = ts::begin(ADMIN);
    let ctx = scenario.ctx();

    let clock = clock::create_for_testing(ctx);
    let lp_treasury: TreasuryCap<LP> = coin::create_treasury_cap_for_testing<LP>(ctx);
    let mut pool: UnifiedSpotPool<ASSET, STABLE, LP> =
        unified_spot_pool::new_for_testing<ASSET, STABLE, LP>(lp_treasury, 30, ctx);

    let (lp_coin, excess_a, excess_s) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin(1_900, ctx),
        stable_coin(1_900, ctx),
        0,
        &clock,
        ctx,
    );
    coin::burn_for_testing(lp_coin);
    burn_or_destroy_zero(excess_a);
    burn_or_destroy_zero(excess_s);

    // 50% to conditional leaves 950/950 in spot => sqrt(k)=950 < minimum_liquidity(1000).
    let auth = spot_pool_mutation_auth::create_for_testing(object::id(&pool));
    unified_spot_pool::mark_liquidity_to_proposal(&mut pool, 50, &clock, auth);

    // Unreachable cleanup
    unified_spot_pool::destroy_for_testing(pool);
    clock::destroy_for_testing(clock);
    scenario.end();
}
