// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init wrappers for liquidity actions during DAO creation
///
/// This module provides public functions for creating AMM pools during init.
/// Uses the standard deposit_approved path plus FutarchyConfig-owned config updates.
///
/// LP tokens are now standard Sui Coins. Pool creation requires:
/// - TreasuryCap<LPType> with zero supply
/// - Currency<LPType> with name/symbol = "GOVEX_LP_TOKEN"
module futarchy_actions::liquidity_init_actions;

public struct ExecutionProgressWitness has drop {}

use account_actions::action_spec_builder;
use account_actions::currency::{Self, CurrencyMintAdminCap};
use account_actions::vault;
use account_actions::vault_init_actions;
use account_protocol::account::{Self as account_mod, Account};
use account_protocol::action_events;
use account_protocol::bcs_validation;
use account_protocol::executable::{Self as executable_mod, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::futarchy_config;
use futarchy_one_shot_utils::constants;
use futarchy_markets_core::unified_spot_pool;
use std::ascii::String as AsciiString;
use std::string::{Self, String};
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::Currency;
use sui::event;

// === Constants ===
const DEFAULT_VAULT_NAME: vector<u8> = b"treasury";

// === Errors ===
const EInvalidAmount: u64 = 1;
const EInvalidRatio: u64 = 2;
const EUnsupportedActionVersion: u64 = 3;
const EWrongLPTreasuryCap: u64 = 4;
const EWrongLPCurrency: u64 = 5;
const ECapAccountMismatch: u64 = 6;
const EInvalidAssetType: u64 = 7;
const EInvalidStableType: u64 = 8;
const EUnauthorizedExecutor: u64 = 9;

// === Marker Types (for action validation) ===
// Pool types are encoded in the markers to prevent executor from changing pool types

/// Marker type for CreatePoolWithMintAction validation
/// Pool types are encoded to ensure executor uses the correct pool types
public struct CreatePoolWithMint<phantom AssetType, phantom StableType, phantom LPType> has drop {}

/// Marker type for CreatePoolFromCoinsAction validation.
/// Pool types are encoded to ensure executor uses the correct pool types.
public struct CreatePoolFromCoins<phantom AssetType, phantom StableType, phantom LPType> has drop {}

// === Events ===

/// Emitted when a DAO spot pool is created during initialization
/// This event provides the mapping between DAO, pool, and all relevant types for indexing
/// DEX aggregators can use this to discover and index new pools
public struct DaoSpotPoolCreated has copy, drop {
    dao_id: ID,
    pool_id: ID,
    asset_type: AsciiString,
    stable_type: AsciiString,
    lp_type: AsciiString,
    initial_asset_reserve: u64,
    initial_stable_reserve: u64,
    fee_bps: u64,
}

// === Action Structs (for staging/dispatching) ===

/// Action to create AMM pool with minted asset and stable from executable_resources
public struct CreatePoolWithMintAction has copy, drop, store {
    /// Resource name to take stable coins from (put there by prior VaultSpend action)
    stable_resource_name: String,
    /// Resource name to take CurrencyMintAdminCap from (put there by prior MintCurrencyAdminCap action)
    mint_cap_resource_name: String,
    /// Amount of asset tokens to mint (None = auto-calculate from launchpad_initial_price)
    asset_amount: Option<u64>,
    fee_bps: u64,
    /// Launch fee duration in milliseconds (0 = no launch fee, max 24 hours)
    /// During this period, fees decay exponentially from 99% to fee_bps
    launch_fee_duration_ms: u64,
    /// LP TreasuryCap object ID - validated at execution to prevent substitution
    lp_treasury_cap_id: ID,
    /// LP Currency<T> object ID - validated at execution to prevent substitution
    lp_currency_id: ID,
}

/// Action to create an AMM pool from externally supplied asset and stable coins.
///
/// The exact coin amounts are intentionally not staged because this path is used
/// for atomic migrations where the coins are produced earlier in the same PTB.
/// Staged minimums provide slippage/accounting protection.
public struct CreatePoolFromCoinsAction has copy, drop, store {
    executor: address,
    min_asset_amount: u64,
    min_stable_amount: u64,
    fee_bps: u64,
    /// Launch fee duration in milliseconds (0 = no launch fee, max 24 hours)
    /// During this period, fees decay exponentially from 99% to fee_bps
    launch_fee_duration_ms: u64,
    /// LP TreasuryCap object ID - validated at execution to prevent substitution
    lp_treasury_cap_id: ID,
    /// LP Currency<T> object ID - validated at execution to prevent substitution
    lp_currency_id: ID,
}

// === Spec Builders (for PTB construction) ===

/// Add CreatePoolWithMintAction to Builder
/// Used for staging actions in launchpad raises via PTB
/// Pool types must match the types to be used during execution
/// LP object IDs are stored and validated at execution time
///
/// Stable coins are taken from executable_resources (put there by prior VaultSpend action)
/// This also stages approval for LPType deposits into the treasury vault immediately
/// before the pool action, because pool creation deposits the minted LP coin there.
///
/// asset_amount: None = auto-calculate from launchpad_initial_price, Some(n) = mint exactly n tokens
public fun add_create_pool_with_mint_spec<AssetType, StableType, LPType>(
    builder: &mut action_spec_builder::Builder,
    stable_resource_name: String,
    mint_cap_resource_name: String,
    asset_amount: Option<u64>,
    fee_bps: u64,
    launch_fee_duration_ms: u64,
    lp_treasury_cap_id: ID,
    lp_currency_id: ID,
) {
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidRatio);
    assert!(stable_resource_name.length() > 0, EInvalidAmount);

    vault_init_actions::add_approve_coin_type_spec<LPType>(
        builder,
        string::utf8(DEFAULT_VAULT_NAME),
    );

    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    // Create action struct
    let action = CreatePoolWithMintAction {
        stable_resource_name,
        mint_cap_resource_name,
        asset_amount,
        fee_bps,
        launch_fee_duration_ms,
        lp_treasury_cap_id,
        lp_currency_id,
    };

    // Serialize
    let action_data = bcs::to_bytes(&action);

    // CRITICAL: Use marker type (not action struct type) for validation
    // Pool types encoded in marker to prevent type substitution
    let action_spec = intents::new_action_spec(
        CreatePoolWithMint<AssetType, StableType, LPType> {},
        action_data,
        1, // version 1
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_string(&mut params, b"stable_resource_name", stable_resource_name);
    action_events::add_string(&mut params, b"mint_cap_resource_name", mint_cap_resource_name);
    // Emit asset_amount as u64 (0 if None, actual value if Some)
    let asset_amount_for_event = if (asset_amount.is_some()) { *asset_amount.borrow() } else { 0 };
    action_events::add_u64(&mut params, b"asset_amount", asset_amount_for_event);
    action_events::add_bool(&mut params, b"asset_amount_auto", asset_amount.is_none());
    action_events::add_u64(&mut params, b"fee_bps", fee_bps);
    action_events::add_u64(&mut params, b"launch_fee_duration_ms", launch_fee_duration_ms);
    action_events::add_id(&mut params, b"lp_treasury_cap_id", lp_treasury_cap_id);
    action_events::add_id(&mut params, b"lp_currency_id", lp_currency_id);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<CreatePoolWithMint<AssetType, StableType, LPType>>()
            .into_string()
            .to_string(),
        action_index,
    );
}

/// Add CreatePoolFromCoinsAction to Builder.
///
/// This stages a pool creation action that consumes asset/stable coins supplied
/// directly to execution, validates they meet the staged minimums, sets the
/// canonical initial price from the actual coin values, and creates the pool.
/// This also stages approval for LPType deposits into the treasury vault,
/// matching add_create_pool_with_mint_spec behavior.
public fun add_create_pool_from_coins_spec<AssetType, StableType, LPType>(
    builder: &mut action_spec_builder::Builder,
    executor: address,
    min_asset_amount: u64,
    min_stable_amount: u64,
    fee_bps: u64,
    launch_fee_duration_ms: u64,
    lp_treasury_cap_id: ID,
    lp_currency_id: ID,
) {
    assert!(min_asset_amount > 0, EInvalidAmount);
    assert!(min_stable_amount > 0, EInvalidAmount);
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidRatio);

    vault_init_actions::add_approve_coin_type_spec<LPType>(
        builder,
        string::utf8(DEFAULT_VAULT_NAME),
    );

    let action_index = action_spec_builder::next_action_index(builder);

    let action = CreatePoolFromCoinsAction {
        executor,
        min_asset_amount,
        min_stable_amount,
        fee_bps,
        launch_fee_duration_ms,
        lp_treasury_cap_id,
        lp_currency_id,
    };

    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        CreatePoolFromCoins<AssetType, StableType, LPType> {},
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_address(&mut params, b"executor", executor);
    action_events::add_u64(&mut params, b"min_asset_amount", min_asset_amount);
    action_events::add_u64(&mut params, b"min_stable_amount", min_stable_amount);
    action_events::add_u64(&mut params, b"fee_bps", fee_bps);
    action_events::add_u64(&mut params, b"launch_fee_duration_ms", launch_fee_duration_ms);
    action_events::add_id(&mut params, b"lp_treasury_cap_id", lp_treasury_cap_id);
    action_events::add_id(&mut params, b"lp_currency_id", lp_currency_id);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<CreatePoolFromCoins<AssetType, StableType, LPType>>()
            .into_string()
            .to_string(),
        action_index,
    );
}

// === Dispatchers ===

/// Package-internal helper for executing a pre-decoded pool creation action.
/// External callers must use do_init_create_pool_with_mint so executable authorization is enforced.
public(package) fun dispatch_create_pool_with_mint<
    Config: store,
    AssetType,
    StableType,
    LPType,
    W: copy + drop,
>(
    account: &mut Account,
    registry: &PackageRegistry,
    action: &CreatePoolWithMintAction,
    stable_coin: Coin<StableType>,
    mint_admin_cap: CurrencyMintAdminCap<AssetType>,
    lp_treasury_cap: TreasuryCap<LPType>,
    lp_currency: &mut Currency<LPType>,
    witness: W,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate LP objects match staged IDs (defense-in-depth)
    assert!(object::id(&lp_treasury_cap) == action.lp_treasury_cap_id, EWrongLPTreasuryCap);
    assert!(object::id(lp_currency) == action.lp_currency_id, EWrongLPCurrency);

    // Execute with the exact parameters from the staged action
    init_create_pool_with_mint_from_coin<Config, AssetType, StableType, LPType, W>(
        account,
        registry,
        stable_coin,
        mint_admin_cap,
        action.asset_amount,
        action.fee_bps,
        action.launch_fee_duration_ms,
        lp_treasury_cap,
        lp_currency,
        witness,
        clock,
        ctx,
    )
}

// === Intent Execution (for PTB executor pattern) ===

/// Execute pool creation from Intent during launchpad initialization
/// Follows 3-layer action execution pattern (see IMPORTANT_ACTION_EXECUTION_PATTERN.md)
///
/// This function is called from PTB executor after begin_execution:
/// 1. begin_execution() creates Executable hot potato
/// 2. PTB calls do_init_* functions in sequence (including this one)
/// 3. finalize_execution() confirms the executable
///
/// Stable coins are taken from executable_resources (put there by prior VaultSpend action)
/// Returns: pool_id
public fun do_init_create_pool_with_mint<
    Config: store,
    Outcome: store,
    RaiseToken,
    StableType,
    LPType,
    IW: copy + drop,
>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    lp_treasury_cap: TreasuryCap<LPType>,
    lp_currency: &mut Currency<LPType>,
    clock: &Clock,
    _intent_witness: IW,
    ctx: &mut TxContext,
): ID {
    // 1. Assert account ownership and current execution context.
    account_mod::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    // 2. Get current ActionSpec from Executable
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<CreatePoolWithMint<RaiseToken, StableType, LPType>>(action_spec);

    // 4. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 5. Deserialize CreatePoolWithMintAction from BCS bytes
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let stable_resource_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let mint_cap_resource_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    // Deserialize Option<u64>: 0x00 = None, 0x01 + value = Some
    let asset_amount = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_u64(&mut reader))
    } else {
        option::none()
    };
    let fee_bps = bcs::peel_u64(&mut reader);
    let launch_fee_duration_ms = bcs::peel_u64(&mut reader);
    let staged_lp_treasury_cap_id = object::id_from_address(bcs::peel_address(&mut reader));
    let staged_lp_currency_id = object::id_from_address(bcs::peel_address(&mut reader));

    // 6. Validate all bytes consumed (security check)
    bcs_validation::validate_all_bytes_consumed(reader);

    // 7. Validate LP objects match staged IDs
    assert!(object::id(&lp_treasury_cap) == staged_lp_treasury_cap_id, EWrongLPTreasuryCap);
    assert!(object::id(lp_currency) == staged_lp_currency_id, EWrongLPCurrency);

    // 8. Take stable coin from executable_resources (put there by prior VaultSpend action)
    let stable_coin: Coin<StableType> = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        stable_resource_name,
    );
    let mint_admin_cap: CurrencyMintAdminCap<RaiseToken> = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        mint_cap_resource_name,
    );
    assert!(currency::mint_admin_cap_account_id(&mint_admin_cap) == object::id(account), ECapAccountMismatch);

    // 9. Execute pool creation
    let pool_id = init_create_pool_with_mint_from_coin<Config, RaiseToken, StableType, LPType, IW>(
        account,
        registry,
        stable_coin,
        mint_admin_cap,
        asset_amount,
        fee_bps,
        launch_fee_duration_ms,
        lp_treasury_cap,
        lp_currency,
        _intent_witness,
        clock,
        ctx,
    );

    // 10. Increment action index
    executable_mod::increment_action_idx<_, CreatePoolWithMint<RaiseToken, StableType, LPType>, _>(executable, registry, ExecutionProgressWitness {});

    pool_id
}

/// Execute pool creation from externally supplied coins during DAO initialization.
///
/// This is the migration-oriented counterpart to do_init_create_pool_with_mint:
/// the asset and stable coins are PTB-provided values, while all policy
/// parameters and object bindings come from the staged ActionSpec.
public fun do_init_create_pool_from_coins<
    Config: store,
    Outcome: store,
    AssetType,
    StableType,
    LPType,
    IW: copy + drop,
>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    lp_treasury_cap: TreasuryCap<LPType>,
    lp_currency: &mut Currency<LPType>,
    clock: &Clock,
    _intent_witness: IW,
    ctx: &mut TxContext,
): ID {
    // 1. Assert account ownership and current execution context.
    account_mod::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    // 2. Get current ActionSpec from Executable
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<CreatePoolFromCoins<AssetType, StableType, LPType>>(action_spec);

    // 3. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 4. Deserialize CreatePoolFromCoinsAction from BCS bytes
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let executor = bcs::peel_address(&mut reader);
    let min_asset_amount = bcs::peel_u64(&mut reader);
    let min_stable_amount = bcs::peel_u64(&mut reader);
    let fee_bps = bcs::peel_u64(&mut reader);
    let launch_fee_duration_ms = bcs::peel_u64(&mut reader);
    let staged_lp_treasury_cap_id = object::id_from_address(bcs::peel_address(&mut reader));
    let staged_lp_currency_id = object::id_from_address(bcs::peel_address(&mut reader));

    // 5. Validate all bytes consumed (security check)
    bcs_validation::validate_all_bytes_consumed(reader);

    // 6. Validate staged policy and object bindings
    assert!(ctx.sender() == executor, EUnauthorizedExecutor);
    assert!(min_asset_amount > 0, EInvalidAmount);
    assert!(min_stable_amount > 0, EInvalidAmount);
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidRatio);
    assert!(object::id(&lp_treasury_cap) == staged_lp_treasury_cap_id, EWrongLPTreasuryCap);
    assert!(object::id(lp_currency) == staged_lp_currency_id, EWrongLPCurrency);

    let asset_amount = coin::value(&asset_coin);
    let stable_amount = coin::value(&stable_coin);
    assert!(asset_amount >= min_asset_amount, EInvalidAmount);
    assert!(stable_amount >= min_stable_amount, EInvalidAmount);

    // 7. Seed launchpad_initial_price/TWAP observation from actual migrated reserves.
    // price = stable / asset, scaled by price_precision_scale.
    let scale = (constants::price_precision_scale() as u128);
    let initial_price = (stable_amount as u128) * scale / (asset_amount as u128);
    assert!(initial_price > 0, EInvalidAmount);
    futarchy_config::set_launchpad_initial_price_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        initial_price,
    );

    // 8. Create pool from the externally supplied coins
    let pool_id = init_create_pool<Config, AssetType, StableType, LPType, IW>(
        account,
        registry,
        asset_coin,
        stable_coin,
        lp_treasury_cap,
        lp_currency,
        fee_bps,
        launch_fee_duration_ms,
        _intent_witness,
        clock,
        ctx,
    );

    // 9. Increment action index
    executable_mod::increment_action_idx<_, CreatePoolFromCoins<AssetType, StableType, LPType>, _>(executable, registry, ExecutionProgressWitness {});

    pool_id
}

// === Init Actions ===

/// Create AMM pool during DAO init (before account is shared)
///
/// This function:
/// 1. Gets DAO config
/// 2. Creates fee schedule (anti-snipe)
/// 3. Creates a new UnifiedSpotPool with Coin-based LP tokens
/// 4. Adds initial liquidity
/// 5. Shares the pool (makes it public)
/// 6. Emits DaoSpotPoolCreated event
/// 7. Deposits LP coin to vault
/// 8. Returns excess coins to treasury vault
/// 9. Stores pool_id in FutarchyConfig
///
/// Requires:
/// - TreasuryCap<LPType> with zero supply
/// - Currency<LPType> with name/symbol = "GOVEX_LP_TOKEN"
///
/// Returns: pool_id for use in subsequent init actions
public(package) fun init_create_pool<
    Config: store,
    AssetType,
    StableType,
    LPType,
    W: copy + drop,
>(
    account: &mut Account,
    registry: &PackageRegistry,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    lp_treasury_cap: TreasuryCap<LPType>,
    lp_currency: &mut Currency<LPType>,
    fee_bps: u64,
    launch_fee_duration_ms: u64,
    _witness: W,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    use futarchy_markets_primitives::fee_scheduler;

    // Validate inputs
    assert!(coin::value(&asset_coin) > 0, EInvalidAmount);
    assert!(coin::value(&stable_coin) > 0, EInvalidAmount);
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidRatio);

    // 1. Get DAO config to read conditional_liquidity_ratio_percent
    let config = account_mod::config(account);

    let expected_asset_type = futarchy_config::asset_type(config);
    let expected_stable_type = futarchy_config::stable_type(config);
    let actual_asset_type = type_name::with_original_ids<AssetType>().into_string().to_string();
    let actual_stable_type = type_name::with_original_ids<StableType>().into_string().to_string();
    assert!(actual_asset_type == *expected_asset_type, EInvalidAssetType);
    assert!(actual_stable_type == *expected_stable_type, EInvalidStableType);

    let conditional_liquidity_ratio_percent = futarchy_config::conditional_liquidity_ratio_percent(
        config,
    );

    // 2. Create fee schedule if duration > 0 (anti-snipe protection)
    let fee_schedule = if (launch_fee_duration_ms > 0) {
        // 99% initial fee decaying exponentially to fee_bps over launch_fee_duration_ms
        option::some(fee_scheduler::new_schedule(constants::max_launch_fee_bps(), launch_fee_duration_ms))
    } else {
        option::none()
    };

    // Capture initial amounts for event (before coins are consumed)
    let initial_asset_amount = coin::value(&asset_coin);
    let initial_stable_amount = coin::value(&stable_coin);

    // 3. Create pool with FULL FUTARCHY FEATURES + Coin-based LP
    // Pool validates LP coin metadata (name/symbol = "GOVEX_LP_TOKEN", supply = 0)
    // Returns (pool, must_share) - MustShare is a hot potato that enforces atomic sharing
    let (mut pool, must_share) = unified_spot_pool::new<AssetType, StableType, LPType>(
        lp_treasury_cap,
        lp_currency,
        fee_bps,
        fee_schedule,
        constants::oracle_conditional_threshold_bps(), // 50%
        conditional_liquidity_ratio_percent, // From DAO config!
        clock,
        ctx,
    );

    // 4. Add initial liquidity (returns LP coin + any excess coins)
    // This also initializes the oracle with the real initial price
    let (lp_coin, excess_asset, excess_stable) = unified_spot_pool::add_liquidity(
        &mut pool,
        asset_coin,
        stable_coin,
        0, // min_lp_out = 0 for initial liquidity (no slippage)
        clock,
        ctx,
    );

    // Get pool ID before sharing
    let pool_id = object::id(&pool);

    // 5. Share the pool - consumes must_share hot potato (enforces atomic sharing)
    unified_spot_pool::share(pool, must_share);

    // 6. Emit DaoSpotPoolCreated event for indexing and DEX aggregators
    let dao_id = object::id(account);
    event::emit(DaoSpotPoolCreated {
        dao_id,
        pool_id,
        asset_type: type_name::get<AssetType>().into_string(),
        stable_type: type_name::get<StableType>().into_string(),
        lp_type: type_name::get<LPType>().into_string(),
        initial_asset_reserve: initial_asset_amount,
        initial_stable_reserve: initial_stable_amount,
        fee_bps,
    });

    // 7. Store LP coin in vault
    // 8. Return any excess coins to treasury vault
    // 9. Store pool_id in FutarchyConfig
    //
    let vault_name = string::utf8(DEFAULT_VAULT_NAME);

    vault::deposit_approved<Config, LPType>(account, registry, vault_name, lp_coin);
    if (coin::value(&excess_asset) > 0) {
        vault::deposit_approved<Config, AssetType>(
            account, registry, vault_name, excess_asset,
        );
    } else { coin::destroy_zero(excess_asset); };
    if (coin::value(&excess_stable) > 0) {
        vault::deposit_approved<Config, StableType>(
            account, registry, vault_name, excess_stable,
        );
    } else { coin::destroy_zero(excess_stable); };

    futarchy_config::set_spot_pool_id_from_account(
        account,
        registry,
        pool_id,
        ExecutionProgressWitness {},
    );

    pool_id
}

/// Create AMM pool during DAO init with minted asset tokens
///
/// This variant mints new asset tokens from TreasuryCap and uses stable coin provided directly.
/// If asset_amount is None, calculates from stable amount using launchpad_initial_price in FutarchyConfig.
/// Requires:
/// - TreasuryCap<LPType> with zero supply
/// - Currency<LPType> with name/symbol = "GOVEX_LP_TOKEN"
public(package) fun init_create_pool_with_mint_from_coin<
    Config: store,
    AssetType,
    StableType,
    LPType,
    W: copy + drop,
>(
    account: &mut Account,
    registry: &PackageRegistry,
    stable_coin: Coin<StableType>,
    mint_admin_cap: CurrencyMintAdminCap<AssetType>,
    asset_amount: Option<u64>,
    fee_bps: u64,
    launch_fee_duration_ms: u64,
    lp_treasury_cap: TreasuryCap<LPType>,
    lp_currency: &mut Currency<LPType>,
    witness: W,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let stable_amount = coin::value(&stable_coin);

    // Validate inputs
    assert!(stable_amount > 0, EInvalidAmount);
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidRatio);

    // 1. Calculate asset_amount if not specified (use launchpad_initial_price)
    let final_asset_amount = if (asset_amount.is_none()) {
        // Read launchpad_initial_price from FutarchyConfig
        // price = stable / asset (scaled by price_precision_scale, 1e12)
        // asset = stable * scale / price
        let config = account_mod::config(account);
        let price_opt = futarchy_config::get_launchpad_initial_price(config);
        assert!(price_opt.is_some(), EInvalidAmount); // Must have launchpad_initial_price set
        let price = *price_opt.borrow();
        assert!(price > 0, EInvalidAmount);
        let scale = (constants::price_precision_scale() as u128);
        let calculated = (stable_amount as u128) * scale / price;
        assert!(calculated <= (std::u64::max_value!() as u128), EInvalidAmount);
        (calculated as u64)
    } else {
        *asset_amount.borrow()
    };

    assert!(final_asset_amount > 0, EInvalidAmount);

    // 2. Mint asset tokens via guarded path (M1 fix: enforces CurrencyRules)
    let asset_coin = currency::mint_with_admin_cap<AssetType>(
        account, registry, &mint_admin_cap, final_asset_amount, ctx,
    );
    currency::destroy_currency_mint_admin_cap(mint_admin_cap);

    // 3. Create pool with LP coin infrastructure
    init_create_pool<Config, AssetType, StableType, LPType, W>(
        account,
        registry,
        asset_coin,
        stable_coin,
        lp_treasury_cap,
        lp_currency,
        fee_bps,
        launch_fee_duration_ms,
        witness,
        clock,
        ctx,
    )
}
