// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Protective Ask Init Actions for Governance
///
/// Flow:
/// 1. DAO passes proposal to mint a CurrencyMintAdminCap into executable_resources
/// 2. CreateProtectiveAsk takes that cap and creates a shared ask object
/// 3. Users buy/mint in chunks up to remaining quota at the fixed price per token
/// 4. Multiple asks per DAO are allowed (up to max_protective_asks_per_dao)
///
/// For cancellation, see protective_ask_actions.move
module futarchy_actions::protective_ask_init_actions;

public struct ExecutionProgressWitness has drop {}

use account_actions::action_spec_builder;
use account_actions::currency::{Self, CurrencyMintAdminCap};
use account_protocol::account::{Self as account_mod, Account};
use account_protocol::action_events;
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use futarchy_actions::liquidity_actions;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_markets_core::protective_ask;
use futarchy_markets_core::protective_ask_registry;
use futarchy_markets_core::spot_pool_mutation_auth::SpotPoolMutationRegistry;
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::event;

// === Errors ===

const EUnsupportedActionVersion: u64 = 1;
const EZeroMaxMintAmount: u64 = 2;
const ENoSpotPool: u64 = 3;
const EWrongDaoTypes: u64 = 4;
const EZeroPrice: u64 = 5;
const ECapAccountMismatch: u64 = 6;

// === Action Type Markers ===

/// Create protective ask action marker
public struct CreateProtectiveAsk<phantom RaiseToken, phantom StableCoin> has drop {}

// === Events ===

public struct ProtectiveAskCreatedViaGovernance has copy, drop {
    ask_id: ID,
    account_id: ID,
    pool_id: ID,
    price_per_token: u64,
    max_mint_amount: u64,
}

// === Action Structs for Proposal System ===

/// Action data for creating a protective ask.
/// CurrencyMintAdminCap comes from executable_resources (put there by prior MintCurrencyAdminCap).
/// Pool ID is read from FutarchyConfig.spot_pool_id at execution time.
public struct CreateProtectiveAskAction has copy, drop, store {
    /// Name of the resource in executable_resources to take CurrencyMintAdminCap from.
    mint_cap_resource_name: std::string::String,
    /// Fixed price per token, scaled by price_precision_scale() (1e12).
    /// e.g., 2.5 USDC/token = 2_500_000_000_000
    price_per_token: u64,
    /// Maximum RaiseToken amount that can be minted via this ask wall.
    max_mint_amount: u64,
    /// Duration before permissionless close (0 = no permissionless close)
    release_duration_ms: u64,
}

// === Spec Builders (for proposal PTB construction) ===

public fun add_create_protective_ask_spec<RaiseToken, StableCoin>(
    builder: &mut action_spec_builder::Builder,
    mint_cap_resource_name: std::string::String,
    price_per_token: u64,
    max_mint_amount: u64,
    release_duration_ms: u64,
) {
    assert!(price_per_token > 0, EZeroPrice);
    assert!(max_mint_amount > 0, EZeroMaxMintAmount);

    let action_index = action_spec_builder::next_action_index(builder);

    let action = CreateProtectiveAskAction {
        mint_cap_resource_name,
        price_per_token,
        max_mint_amount,
        release_duration_ms,
    };

    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        CreateProtectiveAsk<RaiseToken, StableCoin> {},
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_string(&mut params, b"mint_cap_resource_name", mint_cap_resource_name);
    action_events::add_u64(&mut params, b"price_per_token", price_per_token);
    action_events::add_u64(&mut params, b"max_mint_amount", max_mint_amount);
    action_events::add_u64(&mut params, b"release_duration_ms", release_duration_ms);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<CreateProtectiveAsk<RaiseToken, StableCoin>>().into_string().to_string(),
        action_index,
    );
}

// === Execution Functions (for Proposal System) ===

/// Execute create protective ask action from proposal.
/// Takes CurrencyMintAdminCap from executable_resources and creates a shared ProtectiveAsk.
public fun do_create_protective_ask<RaiseToken, StableCoin, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    clock: &Clock,
    _witness: IW,
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
    account_protocol::action_validation::assert_action_type<CreateProtectiveAsk<RaiseToken, StableCoin>>(action_spec);

    // 3. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 4. Deserialize action
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let mint_cap_resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let price_per_token = bcs::peel_u64(&mut reader);
    let max_mint_amount = bcs::peel_u64(&mut reader);
    let release_duration_ms = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(max_mint_amount > 0, EZeroMaxMintAmount);
    assert!(price_per_token > 0, EZeroPrice);

    // 5. Read pool_id from FutarchyConfig
    let futarchy_config: &FutarchyConfig = account_mod::config(account);
    let expected_asset_type = futarchy_config::asset_type(futarchy_config);
    let expected_stable_type = futarchy_config::stable_type(futarchy_config);
    let actual_asset_type = type_name::with_original_ids<RaiseToken>().into_string().to_string();
    let actual_stable_type = type_name::with_original_ids<StableCoin>().into_string().to_string();
    assert!(expected_asset_type == &actual_asset_type, EWrongDaoTypes);
    assert!(expected_stable_type == &actual_stable_type, EWrongDaoTypes);

    let config_pool_id = futarchy_config::get_spot_pool_id(futarchy_config);
    assert!(config_pool_id.is_some(), ENoSpotPool);
    let pool_id = *config_pool_id.borrow();

    let account_id = object::id(account);
    let mint_cap: CurrencyMintAdminCap<RaiseToken> = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        mint_cap_resource_name,
    );
    assert!(currency::mint_admin_cap_account_id(&mint_cap) == account_id, ECapAccountMismatch);

    // 6. Create protective ask
    let spot_auth = liquidity_actions::new_spot_pool_mutation_auth(
        spot_pool_mutation_registry,
        pool_id,
    );
    let ask = protective_ask::create<RaiseToken, StableCoin>(
        account_id,
        pool_id,
        price_per_token,
        max_mint_amount,
        release_duration_ms,
        mint_cap,
        spot_auth,
        clock,
        ctx,
    );

    let ask_id = object::id(&ask);

    // 7. Emit event
    event::emit(ProtectiveAskCreatedViaGovernance {
        ask_id,
        account_id,
        pool_id,
        price_per_token,
        max_mint_amount,
    });

    // 8. Enforce max protective asks per DAO and record ask ID
    protective_ask_registry::set_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        ask_id,
        pool_id,
    );

    // 9. Share the ask
    sui::transfer::public_share_object(ask);

    // 10. Increment action index
    executable::increment_action_idx<_, CreateProtectiveAsk<RaiseToken, StableCoin>, _>(executable, registry, ExecutionProgressWitness {});

    ask_id
}
