// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Liquidity-related actions for futarchy DAOs
///
/// LP tokens are now standard Sui Coins stored in vault.
/// No more lp_token_custody - just vault deposits/withdrawals.
///
/// IMPORTANT:
///   DAO LP add/remove actions change the DAO's AMM principal, but they do not
///   update active protective bid wall AMM principal contributions. If bid wall
///   NAV should reflect the new DAO AMM principal, governance must keep the bid
///   wall contribution in sync, e.g. by closing/recreating the bid with an
///   explicit principal override around these liquidity actions.
module futarchy_actions::liquidity_actions;

public struct ExecutionProgressWitness has drop {}

use account_actions::action_spec_builder;
use account_actions::vault;
use account_protocol::account::{Self, Account};
use account_protocol::action_events;
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_markets_core::spot_pool_mutation_auth::{Self, SpotPoolMutationAuth, SpotPoolMutationRegistry};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_one_shot_utils::constants;
use std::string::{Self, String};
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, ID};

// === Action Type Markers ===
// Pool types are encoded in the markers to prevent executor from changing pool types

/// Add liquidity to pool
/// Pool types are encoded to ensure executor uses the correct pool
public struct AddLiquidity<phantom AssetType, phantom StableType, phantom LPType> has drop {}
/// Execute swap in pool
/// Pool types are encoded to ensure executor uses the correct pool
public struct Swap<phantom AssetType, phantom StableType, phantom LPType> has drop {}
/// Update pool LP fee
/// Pool types are encoded to ensure executor updates the correct pool
public struct UpdatePoolFee<phantom AssetType, phantom StableType, phantom LPType> has drop {}
/// Remove liquidity and output coins to executable_resources (for chaining to AddLiquidity)
/// Pool types are encoded to ensure executor uses the correct pool
public struct RemoveLiquidityToResources<
    phantom AssetType,
    phantom StableType,
    phantom LPType,
> has drop {}

// === Witness for SpotPoolMutationAuth ===
/// Witness type for creating SpotPoolMutationAuth.
/// This package must be registered in the SpotPoolMutationRegistry.
public struct SpotPoolMutationWitness has drop {}

/// Create a SpotPoolMutationAuth for internal use by other modules in this package.
/// The underlying witness type must come from this allowed module.
public(package) fun new_spot_pool_mutation_auth(
    registry: &SpotPoolMutationRegistry,
    target_id: ID,
): SpotPoolMutationAuth {
    spot_pool_mutation_auth::create(registry, SpotPoolMutationWitness {}, target_id)
}

// === Action Type Marker Constructors ===

/// Creates an add liquidity marker for package-owned spec builders.
public(package) fun add_liquidity_marker<AssetType, StableType, LPType>(): AddLiquidity<
    AssetType,
    StableType,
    LPType,
> {
    AddLiquidity {}
}

/// Creates a swap marker for package-owned spec builders.
public(package) fun swap_marker<AssetType, StableType, LPType>(): Swap<AssetType, StableType, LPType> {
    Swap {}
}

/// Creates an update pool fee marker for package-owned spec builders.
public(package) fun update_pool_fee_marker<AssetType, StableType, LPType>(): UpdatePoolFee<
    AssetType,
    StableType,
    LPType,
> {
    UpdatePoolFee {}
}

/// Creates a remove liquidity to resources marker for package-owned spec builders.
public(package) fun remove_liquidity_to_resources_marker<
    AssetType,
    StableType,
    LPType,
>(): RemoveLiquidityToResources<AssetType, StableType, LPType> {
    RemoveLiquidityToResources {}
}

// === Errors ===
const EInvalidAmount: u64 = 1;
const EPoolMismatch: u64 = 4;
const EUnsupportedActionVersion: u64 = 8;
const EEmptyResourceName: u64 = 9;
const EInvalidFeeBps: u64 = 10;
const ENotTerminated: u64 = 11;
const ESpotPoolNotConfigured: u64 = 12;
const ESpotPoolDaoMismatch: u64 = 13;
const EDuplicateResourceName: u64 = 14;

// === Constants ===
const DEFAULT_VAULT_NAME: vector<u8> = b"treasury";

// === Events ===

public struct GovernanceLiquidityAdded has copy, drop {
    account_id: ID,
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
}

public struct GovernanceLiquidityRemoved has copy, drop {
    account_id: ID,
    pool_id: ID,
    lp_amount: u64,
    for_dissolution: bool,
}

public struct GovernanceSwapExecuted has copy, drop {
    account_id: ID,
    pool_id: ID,
    swap_asset: bool,
    amount_in: u64,
    min_amount_out: u64,
}

public struct GovernancePoolFeeUpdated has copy, drop {
    account_id: ID,
    pool_id: ID,
    new_fee_bps: u64,
}

// === Action Structs ===

/// Action to add liquidity to a pool
/// Uses composable pattern: takes coins from executable_resources (put there by VaultSpend actions)
public struct AddLiquidityAction<
    phantom AssetType,
    phantom StableType,
    phantom LPType,
> has copy, drop, store {
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
    /// Resource name for asset coin in executable_resources (from prior VaultSpend)
    asset_resource_name: String,
    /// Resource name for stable coin in executable_resources (from prior VaultSpend)
    stable_resource_name: String,
}

/// Action to perform a swap in the pool
/// Uses composable pattern: takes input coin from executable_resources (put there by VaultSpend action)
public struct SwapAction<
    phantom AssetType,
    phantom StableType,
    phantom LPType,
> has copy, drop, store {
    pool_id: ID,
    swap_asset: bool, // true = swap asset for stable, false = swap stable for asset
    amount_in: u64,
    min_amount_out: u64,
    /// Resource name for input coin in executable_resources (from prior VaultSpend)
    input_resource_name: String,
}

/// Action to update the pool's LP fee
/// Takes fee_bps directly - no config dependency
public struct UpdatePoolFeeAction<
    phantom AssetType,
    phantom StableType,
    phantom LPType,
> has copy, drop, store {
    pool_id: ID,
    new_fee_bps: u64,
}

/// Action to remove liquidity and output coins to executable_resources
/// Enables chaining: RemoveLiquidityToResources → AddLiquidity (coins flow directly)
/// The returned asset/stable coins are provided to executable_resources for subsequent actions
///
/// When for_dissolution=true, uses remove_liquidity_for_dissolution(bypass_minimum=true)
/// which zeroes minimum_liquidity to bypass the minimum-liquidity invariant check.
/// NOTE: the pool still has a frozen minimum-LP coin, so reserves cannot be fully drained.
/// Defense-in-depth: DAO must be in terminated state for dissolution path.
public struct RemoveLiquidityToResourcesAction<
    phantom AssetType,
    phantom StableType,
    phantom LPType,
> has copy, drop, store {
    pool_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    /// Resource name for LP coin input (from prior VaultSpend)
    lp_resource_name: String,
    /// Resource name for asset coin output (to executable_resources)
    asset_output_name: String,
    /// Resource name for stable coin output (to executable_resources)
    stable_output_name: String,
    /// When true, use remove_liquidity_for_dissolution (requires DAO terminated)
    for_dissolution: bool,
}

// === Spec Builders ===

public fun add_add_liquidity_spec<AssetType, StableType, LPType>(
    builder: &mut action_spec_builder::Builder,
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
    asset_resource_name: String,
    stable_resource_name: String,
) {
    let action_index = action_spec_builder::next_action_index(builder);
    let action = new_add_liquidity_action<AssetType, StableType, LPType>(
        pool_id,
        asset_amount,
        stable_amount,
        min_lp_out,
        asset_resource_name,
        stable_resource_name,
    );
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        add_liquidity_marker<AssetType, StableType, LPType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_id(&mut params, b"pool_id", pool_id);
    action_events::add_u64(&mut params, b"asset_amount", asset_amount);
    action_events::add_u64(&mut params, b"stable_amount", stable_amount);
    action_events::add_u64(&mut params, b"min_lp_out", min_lp_out);
    action_events::add_string(&mut params, b"asset_resource_name", asset_resource_name);
    action_events::add_string(&mut params, b"stable_resource_name", stable_resource_name);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<AddLiquidity<AssetType, StableType, LPType>>()
            .into_string()
            .to_string(),
        action_index,
    );
}

public fun add_swap_spec<AssetType, StableType, LPType>(
    builder: &mut action_spec_builder::Builder,
    pool_id: ID,
    swap_asset: bool,
    amount_in: u64,
    min_amount_out: u64,
    input_resource_name: String,
) {
    let action_index = action_spec_builder::next_action_index(builder);
    let action = new_swap_action<AssetType, StableType, LPType>(
        pool_id,
        swap_asset,
        amount_in,
        min_amount_out,
        input_resource_name,
    );
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        swap_marker<AssetType, StableType, LPType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_id(&mut params, b"pool_id", pool_id);
    action_events::add_bool(&mut params, b"swap_asset", swap_asset);
    action_events::add_u64(&mut params, b"amount_in", amount_in);
    action_events::add_u64(&mut params, b"min_amount_out", min_amount_out);
    action_events::add_string(&mut params, b"input_resource_name", input_resource_name);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<Swap<AssetType, StableType, LPType>>()
            .into_string()
            .to_string(),
        action_index,
    );
}

public fun add_update_pool_fee_spec<AssetType, StableType, LPType>(
    builder: &mut action_spec_builder::Builder,
    pool_id: ID,
    new_fee_bps: u64,
) {
    let action_index = action_spec_builder::next_action_index(builder);
    let action = new_update_pool_fee_action<AssetType, StableType, LPType>(
        pool_id,
        new_fee_bps,
    );
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        update_pool_fee_marker<AssetType, StableType, LPType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_id(&mut params, b"pool_id", pool_id);
    action_events::add_u64(&mut params, b"new_fee_bps", new_fee_bps);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<UpdatePoolFee<AssetType, StableType, LPType>>()
            .into_string()
            .to_string(),
        action_index,
    );
}

public fun add_remove_liquidity_to_resources_spec<AssetType, StableType, LPType>(
    builder: &mut action_spec_builder::Builder,
    pool_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    lp_resource_name: String,
    asset_output_name: String,
    stable_output_name: String,
    for_dissolution: bool,
) {
    let action_index = action_spec_builder::next_action_index(builder);
    let action = new_remove_liquidity_to_resources_action<
        AssetType, StableType, LPType,
    >(
        pool_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        lp_resource_name,
        asset_output_name,
        stable_output_name,
        for_dissolution,
    );
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        remove_liquidity_to_resources_marker<AssetType, StableType, LPType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_id(&mut params, b"pool_id", pool_id);
    action_events::add_u64(&mut params, b"lp_amount", lp_amount);
    action_events::add_u64(&mut params, b"min_asset_amount", min_asset_amount);
    action_events::add_u64(&mut params, b"min_stable_amount", min_stable_amount);
    action_events::add_string(&mut params, b"lp_resource_name", lp_resource_name);
    action_events::add_string(&mut params, b"asset_output_name", asset_output_name);
    action_events::add_string(&mut params, b"stable_output_name", stable_output_name);
    action_events::add_bool(&mut params, b"for_dissolution", for_dissolution);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<
            RemoveLiquidityToResources<AssetType, StableType, LPType>,
        >().into_string().to_string(),
        action_index,
    );
}

// === Execution Functions ===

/// Execute add liquidity action
/// Takes coins from executable_resources (put there by prior VaultSpend actions),
/// adds liquidity to pool, deposits LP coin to vault, returns excess to vault
/// NOTE: This does not update any active protective bid wall AMM principal.
public fun do_add_liquidity<AssetType, StableType, LPType, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<AddLiquidity<AssetType, StableType, LPType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);

    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let asset_amount = bcs::peel_u64(&mut reader);
    let stable_amount = bcs::peel_u64(&mut reader);
    let min_lp_out = bcs::peel_u64(&mut reader);
    let asset_resource_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let stable_resource_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(asset_amount > 0, EInvalidAmount);
    assert!(stable_amount > 0, EInvalidAmount);
    assert!(asset_resource_name.length() > 0, EEmptyResourceName);
    assert!(stable_resource_name.length() > 0, EEmptyResourceName);
    assert!(pool_id == object::id(pool), EPoolMismatch);

    // Defense-in-depth: verify pool belongs to this DAO
    let config_view = account::config<FutarchyConfig>(account);
    let config_spot_pool_id = futarchy_config::get_spot_pool_id(config_view);
    assert!(option::is_some(&config_spot_pool_id), ESpotPoolNotConfigured);
    assert!(*option::borrow(&config_spot_pool_id) == object::id(pool), ESpotPoolDaoMismatch);

    // Take coins from executable_resources (put there by prior VaultSpend actions)
    let asset_coin: Coin<AssetType> = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        asset_resource_name,
    );
    let stable_coin: Coin<StableType> = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        stable_resource_name,
    );

    // Validate coin amounts match action amounts (defense in depth)
    assert!(coin::value(&asset_coin) == asset_amount, EInvalidAmount);
    assert!(coin::value(&stable_coin) == stable_amount, EInvalidAmount);

    // Add liquidity to pool
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        pool,
        asset_coin,
        stable_coin,
        min_lp_out,
        clock,
        ctx,
    );

    // Deposit LP coin to vault
    let vault_name = string::utf8(DEFAULT_VAULT_NAME);
    vault::deposit_approved<FutarchyConfig, LPType>(
        account,
        registry,
        vault_name,
        lp_coin,
    );

    // Return excess coins to vault
    if (coin::value(&excess_asset) > 0) {
        vault::deposit_approved<FutarchyConfig, AssetType>(
            account,
            registry,
            vault_name,
            excess_asset,
        );
    } else {
        coin::destroy_zero(excess_asset);
    };

    if (coin::value(&excess_stable) > 0) {
        vault::deposit_approved<FutarchyConfig, StableType>(
            account,
            registry,
            vault_name,
            excess_stable,
        );
    } else {
        coin::destroy_zero(excess_stable);
    };

    event::emit(GovernanceLiquidityAdded {
        account_id: object::id(account),
        pool_id,
        asset_amount,
        stable_amount,
        min_lp_out,
    });

    executable::increment_action_idx<_, AddLiquidity<AssetType, StableType, LPType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute a swap action
/// Takes input coin from executable_resources, swaps in pool, deposits output to vault
public fun do_swap<AssetType, StableType, LPType, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<Swap<AssetType, StableType, LPType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);

    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let swap_asset = bcs::peel_bool(&mut reader);
    let amount_in = bcs::peel_u64(&mut reader);
    let min_amount_out = bcs::peel_u64(&mut reader);
    let input_resource_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(amount_in > 0, EInvalidAmount);
    assert!(input_resource_name.length() > 0, EEmptyResourceName);
    assert!(pool_id == object::id(pool), EPoolMismatch);

    // Defense-in-depth: verify pool belongs to this DAO
    let config_view = account::config<FutarchyConfig>(account);
    let config_spot_pool_id = futarchy_config::get_spot_pool_id(config_view);
    assert!(option::is_some(&config_spot_pool_id), ESpotPoolNotConfigured);
    assert!(*option::borrow(&config_spot_pool_id) == object::id(pool), ESpotPoolDaoMismatch);

    let vault_name = string::utf8(DEFAULT_VAULT_NAME);

    if (swap_asset) {
        // Swap asset for stable
        let asset_coin: Coin<AssetType> = executable_resources::take_coin(
            executable,
            registry,
            ExecutionProgressWitness {},
            input_resource_name,
        );
        assert!(coin::value(&asset_coin) == amount_in, EInvalidAmount);

        let stable_coin = unified_spot_pool::swap_asset_for_stable(
            pool,
            asset_coin,
            min_amount_out,
            clock,
            ctx,
        );

        vault::deposit_approved<FutarchyConfig, StableType>(
            account,
            registry,
            vault_name,
            stable_coin,
        );
    } else {
        // Swap stable for asset
        let stable_coin: Coin<StableType> = executable_resources::take_coin(
            executable,
            registry,
            ExecutionProgressWitness {},
            input_resource_name,
        );
        assert!(coin::value(&stable_coin) == amount_in, EInvalidAmount);

        let asset_coin = unified_spot_pool::swap_stable_for_asset(
            pool,
            stable_coin,
            min_amount_out,
            clock,
            ctx,
        );

        vault::deposit_approved<FutarchyConfig, AssetType>(
            account,
            registry,
            vault_name,
            asset_coin,
        );
    };

    event::emit(GovernanceSwapExecuted {
        account_id: object::id(account),
        pool_id,
        swap_asset,
        amount_in,
        min_amount_out,
    });

    executable::increment_action_idx<_, Swap<AssetType, StableType, LPType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute update pool fee action
/// Takes fee directly from action - single action to update pool fee
public fun do_update_pool_fee<AssetType, StableType, LPType, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &Account,
    registry: &PackageRegistry,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<UpdatePoolFee<AssetType, StableType, LPType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);

    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let new_fee_bps = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(pool_id == object::id(pool), EPoolMismatch);

    // Defense-in-depth: verify pool belongs to this DAO
    let config_view = account::config<FutarchyConfig>(account);
    let config_spot_pool_id = futarchy_config::get_spot_pool_id(config_view);
    assert!(option::is_some(&config_spot_pool_id), ESpotPoolNotConfigured);
    assert!(
        *option::borrow(&config_spot_pool_id) == object::id(pool),
        ESpotPoolDaoMismatch,
    );

    // Create SpotPoolMutationAuth for authorized state changes
    let spot_auth = new_spot_pool_mutation_auth(spot_pool_mutation_registry, object::id(pool));

    // Apply to pool (set_fee_bps validates against max_amm_fee_bps)
    unified_spot_pool::set_fee_bps(pool, new_fee_bps, spot_auth);

    event::emit(GovernancePoolFeeUpdated {
        account_id: object::id(account),
        pool_id,
        new_fee_bps,
    });

    executable::increment_action_idx<_, UpdatePoolFee<AssetType, StableType, LPType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute remove liquidity to resources - outputs coins to executable_resources
/// Takes LP coin from executable_resources, removes liquidity from pool,
/// and provides the returned coins to executable_resources for subsequent actions
/// NOTE: This does not update any active protective bid wall AMM principal.
///
/// When for_dissolution=true:
/// - Verifies DAO is in terminated state (defense-in-depth)
/// - Calls remove_liquidity_for_dissolution(bypass_minimum=true) which zeroes minimum_liquidity
/// - Allows LP withdrawals without the minimum-liquidity invariant check blocking final exits
public fun do_remove_liquidity_to_resources<
    AssetType,
    StableType,
    LPType,
    Outcome: store,
>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    spot_mutation_registry: &SpotPoolMutationRegistry,
    pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<RemoveLiquidityToResources<AssetType, StableType, LPType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);

    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let lp_amount = bcs::peel_u64(&mut reader);
    let min_asset_amount = bcs::peel_u64(&mut reader);
    let min_stable_amount = bcs::peel_u64(&mut reader);
    let lp_resource_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let asset_output_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let stable_output_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let for_dissolution = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(lp_amount > 0, EInvalidAmount);
    assert!(lp_resource_name.length() > 0, EEmptyResourceName);
    assert!(asset_output_name.length() > 0, EEmptyResourceName);
    assert!(stable_output_name.length() > 0, EEmptyResourceName);
    assert!(pool_id == object::id(pool), EPoolMismatch);

    // Defense-in-depth: verify pool belongs to this DAO for both normal and dissolution paths
    let config_view = account::config<FutarchyConfig>(account);
    let config_spot_pool_id = futarchy_config::get_spot_pool_id(config_view);
    assert!(option::is_some(&config_spot_pool_id), ESpotPoolNotConfigured);
    assert!(
        *option::borrow(&config_spot_pool_id) == object::id(pool),
        ESpotPoolDaoMismatch,
    );

    // Take LP coin from executable_resources
    let lp_coin: Coin<LPType> = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        lp_resource_name,
    );

    // Validate coin amount matches action amount (defense in depth)
    assert!(coin::value(&lp_coin) == lp_amount, EInvalidAmount);

    let (asset_coin, stable_coin) = if (for_dissolution) {
        // Defense-in-depth: verify DAO is actually terminated
        let dao_state = futarchy_config::dao_state(config_view);
        assert!(
            futarchy_config::operational_state(dao_state)
                == futarchy_config::state_terminated(),
            ENotTerminated,
        );

        // Use dissolution path: bypasses minimum liquidity, zeroes it for third-party LPs
        let auth = new_spot_pool_mutation_auth(spot_mutation_registry, object::id(pool));
        unified_spot_pool::remove_liquidity_for_dissolution(
            pool,
            lp_coin,
            true, // bypass_minimum → zeroes minimum_liquidity
            auth,
            ctx,
        )
    } else {
        // Normal path: enforces minimum liquidity
        unified_spot_pool::remove_liquidity(
            pool,
            lp_coin,
            min_asset_amount,
            min_stable_amount,
            ctx,
        )
    };

    // Slippage protection for both paths
    assert!(coin::value(&asset_coin) >= min_asset_amount, EInvalidAmount);
    assert!(coin::value(&stable_coin) >= min_stable_amount, EInvalidAmount);

    // Provide returned coins to executable_resources for subsequent actions
    executable_resources::provide_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        asset_output_name,
        asset_coin,
        ctx,
    );

    executable_resources::provide_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        stable_output_name,
        stable_coin,
        ctx,
    );

    event::emit(GovernanceLiquidityRemoved {
        account_id: object::id(account),
        pool_id,
        lp_amount,
        for_dissolution,
    });

    executable::increment_action_idx<_, RemoveLiquidityToResources<AssetType, StableType, LPType>, _>(executable, registry, ExecutionProgressWitness {});
}

// === Constructor Functions ===

public(package) fun new_add_liquidity_action<AssetType, StableType, LPType>(
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
    asset_resource_name: String,
    stable_resource_name: String,
): AddLiquidityAction<AssetType, StableType, LPType> {
    assert!(asset_amount > 0, EInvalidAmount);
    assert!(stable_amount > 0, EInvalidAmount);
    assert!(asset_resource_name.length() > 0, EEmptyResourceName);
    assert!(stable_resource_name.length() > 0, EEmptyResourceName);

    AddLiquidityAction {
        pool_id,
        asset_amount,
        stable_amount,
        min_lp_out,
        asset_resource_name,
        stable_resource_name,
    }
}

public(package) fun new_swap_action<AssetType, StableType, LPType>(
    pool_id: ID,
    swap_asset: bool,
    amount_in: u64,
    min_amount_out: u64,
    input_resource_name: String,
): SwapAction<AssetType, StableType, LPType> {
    assert!(amount_in > 0, EInvalidAmount);
    assert!(input_resource_name.length() > 0, EEmptyResourceName);

    SwapAction {
        pool_id,
        swap_asset,
        amount_in,
        min_amount_out,
        input_resource_name,
    }
}

/// Create update pool fee action
/// Fee is validated against max_amm_fee_bps (5%) at creation time
public(package) fun new_update_pool_fee_action<AssetType, StableType, LPType>(
    pool_id: ID,
    new_fee_bps: u64,
): UpdatePoolFeeAction<AssetType, StableType, LPType> {
    assert!(new_fee_bps <= constants::max_amm_fee_bps(), EInvalidFeeBps);
    UpdatePoolFeeAction {
        pool_id,
        new_fee_bps,
    }
}

/// Create remove liquidity to resources action
/// Outputs coins to executable_resources instead of vault, enabling direct chaining
/// Set for_dissolution=true to use dissolution path (requires DAO terminated)
public(package) fun new_remove_liquidity_to_resources_action<AssetType, StableType, LPType>(
    pool_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    lp_resource_name: String,
    asset_output_name: String,
    stable_output_name: String,
    for_dissolution: bool,
): RemoveLiquidityToResourcesAction<AssetType, StableType, LPType> {
    assert!(lp_amount > 0, EInvalidAmount);
    assert!(lp_resource_name.length() > 0, EEmptyResourceName);
    assert!(asset_output_name.length() > 0, EEmptyResourceName);
    assert!(stable_output_name.length() > 0, EEmptyResourceName);
    assert!(asset_output_name != stable_output_name, EDuplicateResourceName);

    RemoveLiquidityToResourcesAction {
        pool_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        lp_resource_name,
        asset_output_name,
        stable_output_name,
        for_dissolution,
    }
}

// === Getter Functions ===

public fun get_pool_id<AssetType, StableType, LPType>(
    action: &AddLiquidityAction<AssetType, StableType, LPType>,
): ID {
    action.pool_id
}

public fun get_asset_amount<AssetType, StableType, LPType>(
    action: &AddLiquidityAction<AssetType, StableType, LPType>,
): u64 {
    action.asset_amount
}

public fun get_stable_amount<AssetType, StableType, LPType>(
    action: &AddLiquidityAction<AssetType, StableType, LPType>,
): u64 {
    action.stable_amount
}

public fun get_min_lp_amount<AssetType, StableType, LPType>(
    action: &AddLiquidityAction<AssetType, StableType, LPType>,
): u64 {
    action.min_lp_out
}

// === UpdatePoolFee Getters ===

public fun get_update_fee_pool_id<AssetType, StableType, LPType>(
    action: &UpdatePoolFeeAction<AssetType, StableType, LPType>,
): ID {
    action.pool_id
}

public fun get_new_fee_bps<AssetType, StableType, LPType>(
    action: &UpdatePoolFeeAction<AssetType, StableType, LPType>,
): u64 {
    action.new_fee_bps
}
