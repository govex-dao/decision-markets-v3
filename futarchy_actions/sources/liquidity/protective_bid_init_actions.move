// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Protective Bid Init Actions for Governance
///
/// Flow:
/// 1. DAO passes proposal to create protective bid
/// 2. MintVaultAdminCap action puts VaultAdminCap in executable_resources
/// 3. CreateProtectiveBid takes cap from resources -> creates shared protective bid
/// 4. Token holders can sell to bid at discounted NAV price
///
/// For cancellation, see protective_bid_actions.move

module futarchy_actions::protective_bid_init_actions;

public struct ExecutionProgressWitness has drop {}

use account_actions::action_spec_builder;
use account_actions::vault::{Self, VaultAdminCap};
use account_protocol::account::{Self as account_mod, Account};
use account_protocol::action_events;
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_markets_core::protective_bid;
use futarchy_markets_core::protective_bid_registry;
use std::string::{Self, String};
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::event;
use sui::transfer;

// === Errors ===

const EUnsupportedActionVersion: u64 = 1;
const ENoSpotPool: u64 = 5;
const EWrongDaoTypes: u64 = 6;
const EInvalidPrincipalOverride: u64 = 7;
const ECapAccountMismatch: u64 = 8;

// === Action Type Markers ===

/// Create protective bid action marker
public struct CreateProtectiveBid<phantom RaiseToken, phantom StableCoin> has drop {}

// === Events ===

public struct ProtectiveBidCreatedViaGovernance has copy, drop {
    bid_id: ID,
    account_id: ID,
    pool_id: ID,
    base_fee_bps: u64,
    surge_fee_bps: u64,
    surge_duration_ms: u64,
    reserved_amount: u64,
    nav_discount_bps: u64,
}

// === Action Structs for Proposal System ===

/// Action data for creating a protective bid (vault-backed).
/// VaultAdminCap comes from executable_resources (put there by prior MintVaultAdminCap action).
/// Pool ID is read from FutarchyConfig.spot_pool_id at execution time.
public struct CreateProtectiveBidAction has copy, drop, store {
    /// Name of the resource in executable_resources to take VaultAdminCap from
    vault_cap_resource_name: String,
    /// Spending limit for the bid (decrements on each sell)
    reserved_amount: u64,
    /// NAV discount in basis points (0 = at NAV, 500 = 5% below NAV)
    nav_discount_bps: u64,
    /// Base fee in basis points (max 2000 = 20%)
    base_fee_bps: u64,
    /// Starting fee in basis points (0 = no surge)
    surge_fee_bps: u64,
    /// Duration of surge period in ms (0 = no surge)
    surge_duration_ms: u64,
    /// DAO AMM principal RaiseToken amount (0 = use pool initial reserves)
    dao_amm_asset_principal: u64,
    /// DAO AMM principal StableCoin amount (0 = use pool initial reserves)
    dao_amm_stable_principal: u64,
    /// Duration before permissionless close (0 = no permissionless close)
    release_duration_ms: u64,
}

// === Spec Builders (for proposal PTB construction) ===

public fun add_create_protective_bid_spec<RaiseToken, StableCoin>(
    builder: &mut action_spec_builder::Builder,
    vault_cap_resource_name: String,
    reserved_amount: u64,
    nav_discount_bps: u64,
    base_fee_bps: u64,
    surge_fee_bps: u64,
    surge_duration_ms: u64,
    dao_amm_asset_principal: u64,
    dao_amm_stable_principal: u64,
    release_duration_ms: u64,
) {
    // Validate principal overrides: either both zero (use defaults) or both non-zero
    if (dao_amm_asset_principal != 0 || dao_amm_stable_principal != 0) {
        assert!(
            dao_amm_asset_principal > 0 && dao_amm_stable_principal > 0,
            EInvalidPrincipalOverride,
        );
    };

    let action_index = action_spec_builder::next_action_index(builder);

    let action = CreateProtectiveBidAction {
        vault_cap_resource_name,
        reserved_amount,
        nav_discount_bps,
        base_fee_bps,
        surge_fee_bps,
        surge_duration_ms,
        dao_amm_asset_principal,
        dao_amm_stable_principal,
        release_duration_ms,
    };

    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        CreateProtectiveBid<RaiseToken, StableCoin> {},
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    let mut params = action_events::new_builder();
    action_events::add_string(&mut params, b"vault_cap_resource_name", vault_cap_resource_name);
    action_events::add_u64(&mut params, b"reserved_amount", reserved_amount);
    action_events::add_u64(&mut params, b"nav_discount_bps", nav_discount_bps);
    action_events::add_u64(&mut params, b"base_fee_bps", base_fee_bps);
    action_events::add_u64(&mut params, b"surge_fee_bps", surge_fee_bps);
    action_events::add_u64(&mut params, b"surge_duration_ms", surge_duration_ms);
    action_events::add_u64(&mut params, b"dao_amm_asset_principal", dao_amm_asset_principal);
    action_events::add_u64(&mut params, b"dao_amm_stable_principal", dao_amm_stable_principal);
    action_events::add_u64(&mut params, b"release_duration_ms", release_duration_ms);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<CreateProtectiveBid<RaiseToken, StableCoin>>().into_string().to_string(),
        action_index,
    );
}

// === Execution Functions (for Proposal System) ===

/// Execute create protective bid action from proposal.
/// Takes VaultAdminCap from executable_resources (put there by prior MintVaultAdminCap).
/// Creates a shared ProtectiveBid for token holders to sell to.
public fun do_create_protective_bid<RaiseToken, StableCoin, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
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
    account_protocol::action_validation::assert_action_type<CreateProtectiveBid<RaiseToken, StableCoin>>(action_spec);

    // 3. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 4. Deserialize action
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let vault_cap_resource_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let reserved_amount = bcs::peel_u64(&mut reader);
    let nav_discount_bps = bcs::peel_u64(&mut reader);
    let base_fee_bps = bcs::peel_u64(&mut reader);
    let surge_fee_bps = bcs::peel_u64(&mut reader);
    let surge_duration_ms = bcs::peel_u64(&mut reader);
    let dao_amm_asset_principal = bcs::peel_u64(&mut reader);
    let dao_amm_stable_principal = bcs::peel_u64(&mut reader);
    let release_duration_ms = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

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

    // 6. Take VaultAdminCap from executable_resources (put there by prior MintVaultAdminCap)
    let vault_cap: VaultAdminCap = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        vault_cap_resource_name,
    );

    let account_id = object::id(account);

    // 6b. Validate cap belongs to this account (prevents foreign cap injection via ProvideObjectToResources)
    assert!(vault::admin_cap_account_id(&vault_cap) == account_id, ECapAccountMismatch);

    // 7. Create protective bid (vault-backed)
    let bid = if (dao_amm_asset_principal == 0 && dao_amm_stable_principal == 0) {
        protective_bid::create<RaiseToken, StableCoin>(
            account_id,
            pool_id,
            base_fee_bps,
            surge_fee_bps,
            surge_duration_ms,
            release_duration_ms,
            vault_cap,
            reserved_amount,
            nav_discount_bps,
            clock,
            ctx,
        )
    } else {
        assert!(
            dao_amm_asset_principal > 0 && dao_amm_stable_principal > 0,
            EInvalidPrincipalOverride,
        );
        protective_bid::create_with_principal<RaiseToken, StableCoin>(
            account_id,
            pool_id,
            base_fee_bps,
            surge_fee_bps,
            surge_duration_ms,
            release_duration_ms,
            dao_amm_asset_principal,
            dao_amm_stable_principal,
            vault_cap,
            reserved_amount,
            nav_discount_bps,
            clock,
            ctx,
        )
    };

    let bid_id = object::id(&bid);

    // 8. Emit event
    event::emit(ProtectiveBidCreatedViaGovernance {
        bid_id,
        account_id,
        pool_id,
        base_fee_bps,
        surge_fee_bps,
        surge_duration_ms,
        reserved_amount,
        nav_discount_bps,
    });

    // 9. Enforce max 10 protective bids per DAO and record bid ID
    protective_bid_registry::set_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        bid_id,
        pool_id,
    );

    // 10. Share the bid
    transfer::public_share_object(bid);

    // 11. Increment action index
    executable::increment_action_idx<_, CreateProtectiveBid<RaiseToken, StableCoin>, _>(executable, registry, ExecutionProgressWitness {});

    bid_id
}
