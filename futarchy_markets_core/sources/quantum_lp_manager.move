// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Simplified Quantum LP Management
///
/// With Coin-based LP tokens, management is simpler:
/// - LP operations blocked during active proposals via pool.active_proposal_id
/// - Quantum split ratio controlled by DAO config (10-90%)
/// - No per-LP-token locking needed - pool-level blocking is sufficient
///
/// === LP Token Architecture ===
///
/// **IMPORTANT: Users cannot add/remove LP to conditional AMMs while a proposal is active.**
/// The `active_proposal_id` flag on the spot pool blocks all LP operations during proposals.
/// Only the system (quantum split) provides liquidity to conditional AMMs.
///
/// **AMM Internal `lp_supply`** (in conditional_amm::LiquidityPool):
/// - Tracks quantum (system) liquidity only during active proposals
/// - Users do NOT receive conditional LP tokens - they hold spot pool LP tokens
/// - Reset to 0 when pool is emptied via `empty_all_amm_liquidity` at proposal end
///
/// **Flow:**
/// 1. Proposal starts → quantum split adds system liquidity to conditional AMMs
/// 2. During proposal → users trade but CANNOT add/remove LP (blocked by active_proposal_id)
/// 3. Proposal ends → `empty_all_amm_liquidity` returns reserves to spot pool
///
/// **Why quantum LP is dropped:**
/// - `add_liquidity_proportional` returns LP amount but we drop it (`_lp_amount`)
/// - System liquidity doesn't need ownership tokens - it's tracked via escrow backing
/// - All value flows back to spot pool LPs at proposal end
///
/// === Quantum Collapse Economic Model ===
///
/// **At proposal start:** Liquidity is "quantum split" to ALL conditional pools equally.
/// Each pool receives the same amount (e.g., 100 tokens → 100 in each outcome pool).
/// This is backed by 100 tokens in escrow, not 100 * N.
///
/// **During trading:** Users swap in conditional pools, changing reserve ratios.
/// The winning pool may gain value (traders buying the winner), while losing pools
/// may lose value (traders selling losers).
///
/// **At proposal end:** Only the WINNING pool's reserves return to spot pool.
/// Losing pools' reserves are "quantum collapsed" - they don't return.
///
/// **Economic justification:**
/// 1. The escrow only ever had 1x backing, not Nx for N outcomes
/// 2. Conditional tokens in losing pools become worthless (can't redeem)
/// 3. LP fees collected in the winning pool DO return to spot LPs
/// 4. This mirrors how prediction markets work: losers lose, winners gain
///
/// **Net effect on spot LPs:**
/// - If winning pool grew: spot LPs profit from good prediction market outcome
/// - If winning pool shrank: spot LPs absorbed losses from adverse trading
/// - LP fees in winning pool offset some adverse selection risk
///
/// === Access Control ===
///
/// These functions require `SpotPoolMutationAuth` to ensure only authorized
/// packages (registered in SpotPoolMutationRegistry) can call them.
/// This prevents malicious modules from manipulating quantum liquidity state.
module futarchy_markets_core::quantum_lp_manager;

use futarchy_core::escrow_mutation_auth::{Self, EscrowMutationRegistry};
use futarchy_core::market_state_mutation_auth::{Self, MarketStateMutationRegistry};
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationAuth};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm;
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::math;
use sui::balance;
use sui::clock::Clock;
use sui::coin;

// === Witness for mutation authorization ===
public struct EscrowMutationWitness has drop {}
public struct MarketStateMutationWitness has drop {}

// === Errors ===
const EInvalidWinningOutcome: u64 = 1; // winning_outcome >= num_pools
const EProposalAlreadyActive: u64 = 2; // spot pool already locked for a proposal
const ESpotPoolEscrowMismatch: u64 = 3; // spot_pool.active_escrow != escrow.id
const EMarketNotFinalized: u64 = 4; // market state must be finalized before recombine
const EWinningOutcomeMismatch: u64 = 5; // provided winning_outcome != canonical winner
const EAuthTargetMismatch: u64 = 6; // Auth token target_id doesn't match spot_pool
const EZeroLiquiditySplit: u64 = 7; // Split amounts must be non-zero to avoid permanent DAO bricking

// === Auto-Participation Logic ===

/// Quantum split with configurable ratio
/// x% stays in spot pool, (100-x)% quantum splits to ALL conditional pools
/// Enforces minimum gap between proposals (blocks if gap_fee == U64_MAX)
/// NOTE: Gap fee charging is handled by caller (proposal_lifecycle) which has access to DAO config
///
/// SECURITY: Requires SpotPoolMutationAuth to ensure only authorized packages can call.
public fun auto_quantum_split_on_proposal_start<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    proposal_id: ID,
    conditional_liquidity_ratio_percent: u64, // Percent to quantum split (0-100)
    escrow_registry: &EscrowMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
    auth: SpotPoolMutationAuth, // Proves caller is authorized (consumed)
) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(spot_pool), EAuthTargetMismatch);
    // Prevent double-splitting while a proposal is already active.
    assert!(!unified_spot_pool::is_locked_for_proposal(spot_pool), EProposalAlreadyActive);

    // Bind directly to the proposal being started before mutating either object.
    assert!(
        market_state::proposal_id(coin_escrow::get_market_state(escrow)) == proposal_id,
        ESpotPoolEscrowMismatch,
    );

    // Enforce any existing spot_pool ↔ escrow binding before mutating either object.
    assert_spot_pool_escrow_binding(spot_pool, escrow);

    // Reject repeat starts even if a prior attempt somehow cleared the spot lock.
    assert!(
        coin_escrow::get_lp_deposited_asset(escrow) == 0
            && coin_escrow::get_lp_deposited_stable(escrow) == 0,
        EProposalAlreadyActive,
    );

    // Check proposal gap - blocks immediate re-proposals (when gap_fee == U64_MAX)
    // Fee charging is handled by proposal_lifecycle which has access to DAO config
    unified_spot_pool::check_proposal_gap(spot_pool, clock);

    // Get total reserves to calculate split amounts
    let (total_asset, total_stable) = unified_spot_pool::get_reserves(spot_pool);

    // Calculate how much to quantum split
    let asset_to_split = math::mul_div_to_64(total_asset, conditional_liquidity_ratio_percent, 100);
    let stable_to_split = math::mul_div_to_64(
        total_stable,
        conditional_liquidity_ratio_percent,
        100,
    );

    // SECURITY: Abort if either split amount is zero BEFORE setting active_proposal_id.
    // Zero-reserve conditional pools cause permanent DAO bricking: TWAP resolution
    // aborts on get_current_price(), the proposal gets stuck in TRADING forever, and
    // the non-finalized escrow blocks all future proposals. If we set active_proposal_id
    // before this check, LP operations stay blocked even when the split fails.
    assert!(asset_to_split > 0 && stable_to_split > 0, EZeroLiquiditySplit);

    // Mark proposal as active - this blocks all LP operations.
    // MUST come after the zero-split check to avoid locking LPs on failure.
    unified_spot_pool::set_active_proposal(spot_pool, proposal_id);

    // Remove only the split amounts from spot pool (rest stays for trading)
    let (asset_balance, stable_balance) = unified_spot_pool::split_reserves_for_quantum(
        spot_pool,
        asset_to_split,
        stable_to_split,
    );

    // Create auth for escrow mutations
    let auth = escrow_mutation_auth::create(escrow_registry, EscrowMutationWitness {});

    // Deposit to escrow as quantum backing and update supplies for all outcomes
    let (_deposited_asset, _deposited_stable) = coin_escrow::lp_deposit_quantum(
        escrow,
        asset_balance,
        stable_balance,
        &auth,
    );

    // Get market_state for pool mutations (reuse auth)
    let market_state = coin_escrow::get_market_state_mut(escrow, &auth);

    // Quantum replicate: EACH pool gets the FULL amount (not divided!)
    // 100 spot backing → 100 conditional in EACH outcome (quantum expansion)
    let outcome_count = market_state::outcome_count(market_state);
    let asset_per_pool = asset_to_split;
    let stable_per_pool = stable_to_split;

    let mut i = 0;
    while (i < outcome_count) {
        let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);

        // Add liquidity to conditional AMM
        // NOTE: LP amount is intentionally dropped - this is QUANTUM (system) liquidity
        // which doesn't mint user LP tokens. The AMM's internal lp_supply increases,
        // but no TreasuryCap LP tokens are created. See module docs for details.
        let _lp_amount = conditional_amm::add_liquidity_proportional(
            pool,
            asset_per_pool,
            stable_per_pool,
            0, // min_lp_out
            clock,
            ctx,
        );

        i = i + 1;
    };
}

/// Simplified recombination - returns system liquidity from winning conditional pool back to spot
/// Clears active_proposal_id to unblock LP operations and records proposal end time
/// Returns only AMM reserves (LP fees included), NOT protocol fees.
///
/// SECURITY: Requires SpotPoolMutationAuth to ensure only authorized packages can call.
/// Also validates winning_outcome is within bounds.
public fun auto_redeem_on_proposal_end_from_escrow<AssetType, StableType, LPType>(
    winning_outcome: u64,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
    auth: SpotPoolMutationAuth, // Proves caller is authorized (consumed)
) {
    assert!(spot_pool_mutation_auth::target_id(&auth) == object::id(spot_pool), EAuthTargetMismatch);
    // Enforce spot_pool ↔ escrow binding before mutating either object.
    assert_active_spot_pool_escrow_binding(spot_pool, escrow);

    // Defense in depth: ensure this function only runs with finalized state and
    // the canonical winning outcome from market_state.
    let market_state_ro = coin_escrow::get_market_state(escrow);
    assert!(market_state::is_finalized(market_state_ro), EMarketNotFinalized);
    let canonical_winner = market_state::get_winning_outcome(market_state_ro);
    assert!(winning_outcome == canonical_winner, EWinningOutcomeMismatch);

    // Create auth for escrow mutations
    let auth = escrow_mutation_auth::create(escrow_registry, EscrowMutationWitness {});

    // Create auth for market state mutations (needed for conditional AMM operations)
    let market_auth = market_state_mutation_auth::create(
        market_state_registry,
        MarketStateMutationWitness {},
    );

    // Empty ALL conditional pools - quantum split added liquidity to ALL pools,
    // not just the winning one. We need to clean up stale liquidity from losing pools
    // to prevent it from accumulating across proposals.
    // Only the winning outcome's reserves are returned to spot pool (quantum recombine).
    let (asset_amount, stable_amount) = {
        let market_state = coin_escrow::get_market_state_mut(escrow, &auth);
        let num_pools = market_state::outcome_count(market_state);

        // SECURITY: Validate winning_outcome is within bounds
        // If invalid, we'd silently return 0 to spot pool (stranding funds)
        assert!(winning_outcome < num_pools, EInvalidWinningOutcome);

        let mut total_asset = 0u64;
        let mut total_stable = 0u64;
        let mut i = 0u64;

        while (i < num_pools) {
            let pool = market_state::get_pool_mut_by_outcome(market_state, i, &auth);
            let (pool_asset, pool_stable) = conditional_amm::empty_all_amm_liquidity(pool, ctx, &market_auth);

            // Only count the winning outcome's reserves for return to spot pool
            // Losing pools' liquidity was "quantum collapsed" - it doesn't get returned
            if (i == winning_outcome) {
                total_asset = pool_asset;
                total_stable = pool_stable;
            };
            // Note: Losing pool reserves are effectively burned (not returned)
            // This is correct quantum behavior - only the winning branch materializes

            i = i + 1;
        };

        (total_asset, total_stable)
    };

    // Total to withdraw from escrow = AMM reserves only (no protocol fees)
    let total_asset = asset_amount;
    let total_stable = stable_amount;

    // SAFETY: Cap withdrawals at LP backing to preserve user redemptions
    // We cap each token type independently to avoid dimensionally incorrect arithmetic
    // (adding different token amounts with potentially different decimals/values).
    let lp_asset = coin_escrow::get_lp_deposited_asset(escrow);
    let lp_stable = coin_escrow::get_lp_deposited_stable(escrow);
    let escrow_asset = coin_escrow::get_escrowed_asset_balance(escrow);
    let escrow_stable = coin_escrow::get_escrowed_stable_balance(escrow);
    let winning_asset_supply = coin_escrow::get_outcome_asset_supply(escrow, winning_outcome);
    let winning_stable_supply = coin_escrow::get_outcome_stable_supply(escrow, winning_outcome);

    // Cap each type at: min(winning_reserves, lp_deposited, winning_outcome_supply, user_cap, pool_claim)
    // This ensures:
    // 1. We don't withdraw more than the winning pool had
    // 2. We don't withdraw more than LP deposited (leaving user deposits intact)
    // 3. We don't withdraw more than remaining winning-outcome supply
    // 4. We don't withdraw more than escrow minus user claims (includes dust via pool_claim)
    // 5. We don't exceed pool_claim (LP's tracked share of outcome allocation)

    // User claim cap: LP cannot withdraw so much that user claims become unbacked.
    // user_claim = outcome_escrowed - pool_claim (what users need per-type)
    // LP can withdraw at most: escrow - user_claim per type
    let winning_oe_asset = coin_escrow::get_outcome_escrowed_asset(escrow, winning_outcome);
    let winning_oe_stable = coin_escrow::get_outcome_escrowed_stable(escrow, winning_outcome);
    let pool_claim_asset = coin_escrow::get_pool_claim_asset(escrow, winning_outcome);
    let pool_claim_stable = coin_escrow::get_pool_claim_stable(escrow, winning_outcome);
    // Saturating subtraction: swaps can shift outcome_escrowed between types,
    // so OE for a type can legitimately be less than pool_claim for that type.
    let user_claim_asset = if (winning_oe_asset > pool_claim_asset) {
        winning_oe_asset - pool_claim_asset
    } else { 0 };
    let user_claim_stable = if (winning_oe_stable > pool_claim_stable) {
        winning_oe_stable - pool_claim_stable
    } else { 0 };
    let user_cap_asset = if (escrow_asset > user_claim_asset) {
        escrow_asset - user_claim_asset
    } else { 0 };
    let user_cap_stable = if (escrow_stable > user_claim_stable) {
        escrow_stable - user_claim_stable
    } else { 0 };

    let withdraw_asset = {
        let a = if (total_asset < lp_asset) { total_asset } else { lp_asset };
        let b = if (a < winning_asset_supply) { a } else { winning_asset_supply };
        let c = if (b < user_cap_asset) { b } else { user_cap_asset };
        if (c < pool_claim_asset) { c } else { pool_claim_asset }
    };
    let withdraw_stable = {
        let a = if (total_stable < lp_stable) { total_stable } else { lp_stable };
        let b = if (a < winning_stable_supply) { a } else { winning_stable_supply };
        let c = if (b < user_cap_stable) { b } else { user_cap_stable };
        if (c < pool_claim_stable) { c } else { pool_claim_stable }
    };

    // Withdraw capped amounts from escrow
    let asset_coin = coin_escrow::withdraw_asset_balance(escrow, withdraw_asset, ctx, &auth);
    let stable_coin = coin_escrow::withdraw_stable_balance(escrow, withdraw_stable, ctx, &auth);

    // Decrement LP backing tracking
    coin_escrow::decrement_lp_backing(escrow, withdraw_asset, withdraw_stable, &auth);

    // Post-finalization only the winning outcome is redeemable, so decrement winning
    // outcome tracking only. This avoids underflow when balances were wrapped
    // during trading (wrapped reduces supply but still needs backing).
    if (withdraw_asset > 0) {
        coin_escrow::decrement_supply_for_outcome(escrow, winning_outcome, true, withdraw_asset, &auth);
    };
    if (withdraw_stable > 0) {
        coin_escrow::decrement_supply_for_outcome(
            escrow,
            winning_outcome,
            false,
            withdraw_stable,
            &auth,
        );
    };
    coin_escrow::decrement_outcome_allocation(escrow, winning_outcome, withdraw_asset, withdraw_stable, &auth);

    // Decrement pool claim by the same amounts as outcome allocation (LP portion unwound)
    coin_escrow::decrement_pool_claim(escrow, winning_outcome, withdraw_asset, withdraw_stable, &auth);

    // Validate invariant immediately after recombination accounting updates.
    coin_escrow::assert_quantum_invariant(escrow);

    // Keep winning pool protocol fees in escrow so collect_protocol_fees can withdraw them later.
    let (pending_fee_asset, pending_fee_stable) = {
        let market_state = coin_escrow::get_market_state(escrow);
        let winning_pool = market_state::get_pool_by_outcome(market_state, winning_outcome);
        (
            conditional_amm::get_protocol_fees_asset(winning_pool),
            conditional_amm::get_protocol_fees_stable(winning_pool),
        )
    };

    // Sweep post-finalization excess (primarily losing-side collateral and arb residue) to spot.
    // Preserve only:
    // 1) remaining winning-outcome allocation (all winning circulation)
    // 2) pending protocol fees for the winning pool
    let (sweep_asset, sweep_stable) = compute_post_finalize_sweep_amounts(
        escrow,
        winning_outcome,
        pending_fee_asset,
        pending_fee_stable,
    );

    let mut asset_balance = coin::into_balance(asset_coin);
    let mut stable_balance = coin::into_balance(stable_coin);

    // Decrement LP backing for the swept portion (losing-side LP collateral).
    // The first decrement_lp_backing (above) only covers the capped withdrawal;
    // the remaining LP backing from losing outcomes must also be cleared.
    let remaining_lp_asset = lp_asset - withdraw_asset;
    let remaining_lp_stable = lp_stable - withdraw_stable;
    let sweep_lp_asset = if (sweep_asset < remaining_lp_asset) { sweep_asset } else { remaining_lp_asset };
    let sweep_lp_stable = if (sweep_stable < remaining_lp_stable) { sweep_stable } else { remaining_lp_stable };
    if (sweep_lp_asset > 0 || sweep_lp_stable > 0) {
        coin_escrow::decrement_lp_backing(escrow, sweep_lp_asset, sweep_lp_stable, &auth);
    };

    if (sweep_asset > 0) {
        let sweep_asset_coin = coin_escrow::withdraw_asset_balance(escrow, sweep_asset, ctx, &auth);
        // Collapse losing-side user backing at finalization.
        // Only decrement the user portion; the LP portion was already decremented above.
        let sweep_user_asset = sweep_asset - sweep_lp_asset;
        if (sweep_user_asset > 0) {
            coin_escrow::decrement_user_backing(escrow, sweep_user_asset, true, &auth);
        };
        balance::join(&mut asset_balance, coin::into_balance(sweep_asset_coin));
    };
    if (sweep_stable > 0) {
        let sweep_stable_coin = coin_escrow::withdraw_stable_balance(escrow, sweep_stable, ctx, &auth);
        // Collapse losing-side user backing at finalization.
        // Only decrement the user portion; the LP portion was already decremented above.
        let sweep_user_stable = sweep_stable - sweep_lp_stable;
        if (sweep_user_stable > 0) {
            coin_escrow::decrement_user_backing(escrow, sweep_user_stable, false, &auth);
        };
        balance::join(&mut stable_balance, coin::into_balance(sweep_stable_coin));
    };

    // Re-validate after sweep.
    coin_escrow::assert_quantum_invariant(escrow);

    // Add liquidity back to spot pool
    unified_spot_pool::add_liquidity_from_quantum_redeem(
        spot_pool,
        asset_balance,
        stable_balance,
    );

    // Update TWAP oracle to reflect the post-redemption reserves.
    // Without this, the oracle accumulates the stale pre-redemption price
    // until the next organic swap, skewing the time-weighted average.
    unified_spot_pool::update_twap_after_arbitrage(spot_pool, clock);

    // Clear active_proposal_id and record end time - this unblocks LP operations
    unified_spot_pool::clear_active_proposal(spot_pool, clock);
}

fun assert_spot_pool_escrow_binding<AssetType, StableType, LPType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let active_escrow_opt = unified_spot_pool::get_active_escrow_id(spot_pool);
    if (active_escrow_opt.is_some()) {
        // Verify exact escrow ID when stored in pool
        assert!(*option::borrow(&active_escrow_opt) == object::id(escrow), ESpotPoolEscrowMismatch);
    } else {
        // Defense-in-depth: when escrow is extracted, validate via proposal_id
        // to prevent cross-market attacks with a foreign escrow.
        let pool_proposal_opt = unified_spot_pool::get_active_proposal_id(spot_pool);
        if (pool_proposal_opt.is_some()) {
            let pool_proposal_id = *option::borrow(&pool_proposal_opt);
            let escrow_proposal_id = market_state::proposal_id(coin_escrow::get_market_state(escrow));
            assert!(pool_proposal_id == escrow_proposal_id, ESpotPoolEscrowMismatch);
        };
    };
}

fun assert_active_spot_pool_escrow_binding<AssetType, StableType, LPType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let active_escrow_opt = unified_spot_pool::get_active_escrow_id(spot_pool);
    if (active_escrow_opt.is_some()) {
        assert!(*option::borrow(&active_escrow_opt) == object::id(escrow), ESpotPoolEscrowMismatch);
    } else {
        let pool_proposal_opt = unified_spot_pool::get_active_proposal_id(spot_pool);
        assert!(pool_proposal_opt.is_some(), ESpotPoolEscrowMismatch);
        let pool_proposal_id = *option::borrow(&pool_proposal_opt);
        let escrow_proposal_id = market_state::proposal_id(coin_escrow::get_market_state(escrow));
        assert!(pool_proposal_id == escrow_proposal_id, ESpotPoolEscrowMismatch);
    };
}

/// Compute how much escrow can be swept back to spot after finalization.
///
/// Keep enough escrow for:
/// - full winning-outcome allocation per type (all remaining winning circulation)
/// - pending winning-pool protocol fees
///
/// We use full winning_alloc (not user_claim) because ALL remaining circulation
/// needs escrow backing — both user-minted tokens AND LP-originated tokens that
/// users acquired via AMM trading and may have wrapped. User redemptions will
/// naturally drain escrow to 0 as wrapped tokens are unwrapped and redeemed.
fun compute_post_finalize_sweep_amounts<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    winning_outcome: u64,
    pending_fee_asset: u64,
    pending_fee_stable: u64,
): (u64, u64) {
    let escrow_asset = coin_escrow::get_escrowed_asset_balance(escrow);
    let escrow_stable = coin_escrow::get_escrowed_stable_balance(escrow);

    let winning_alloc_asset = coin_escrow::get_outcome_escrowed_asset(escrow, winning_outcome);
    let winning_alloc_stable = coin_escrow::get_outcome_escrowed_stable(escrow, winning_outcome);

    let required_asset = (winning_alloc_asset as u128) + (pending_fee_asset as u128);
    let required_stable = (winning_alloc_stable as u128) + (pending_fee_stable as u128);

    let sweep_asset = if ((escrow_asset as u128) > required_asset) {
        (((escrow_asset as u128) - required_asset) as u64)
    } else { 0 };
    let sweep_stable = if ((escrow_stable as u128) > required_stable) {
        (((escrow_stable as u128) - required_stable) as u64)
    } else { 0 };

    (sweep_asset, sweep_stable)
}
