// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Consolidated configuration actions for futarchy DAOs
/// This module combines basic and advanced configuration actions and their execution logic
module futarchy_actions::config_actions;

public struct ExecutionProgressWitness has drop {}

use account_actions::currency;
use account_protocol::account::{Self, Account};
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::intents::{Self, PendingIntent, Self as protocol_intents};
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::dao_config;
use futarchy_core::futarchy_config::{Self, FutarchyConfig, FutarchyOutcome};
use futarchy_actions::futarchy_actions_version as version;
use futarchy_proposal::proposal::{Self, Proposal};
use std::ascii::{Self, String as AsciiString};
use std::option::{Self, Option};
use std::string::{Self, String};
use std::type_name;
use sui::bcs::{Self, BCS};
use sui::clock::Clock;
use sui::dynamic_field as df;
use sui::event;
use sui::object;
use sui::table::{Self, Table};
use sui::url::{Self, Url};

// === Action Type Markers ===

/// Terminate the DAO
public struct TerminateDao has drop {}
/// Update DAO name
public struct UpdateName has drop {}
/// Update trading parameters
public struct TradingParamsUpdate has drop {}
/// Update metadata
public struct MetadataUpdate has drop {}
/// Update TWAP configuration
public struct TwapConfigUpdate has drop {}
/// Update governance parameters
public struct GovernanceUpdate has drop {}
/// Update metadata table
public struct MetadataTableUpdate has drop {}
/// Update sponsorship configuration
public struct SponsorshipConfigUpdate has drop {}
/// Update conditional metadata
public struct UpdateConditionalMetadata has drop {}
/// Sync TWAP initial observation from proposal's winning TWAP
public struct SyncTwapObservationFromProposal has drop {}

// === Marker Functions ===

/// SECURITY: Marker constructors are package-private to prevent external code from
/// obtaining drop-typed values that could bypass package-witness authorization checks.
/// An external caller with a marker value could impersonate this package's address
/// in config_mut_authorized / assert_package_witness_authorized calls.

public(package) fun terminate_dao_marker(): TerminateDao { TerminateDao {} }

public(package) fun update_name_marker(): UpdateName { UpdateName {} }

public(package) fun trading_params_update_marker(): TradingParamsUpdate { TradingParamsUpdate {} }

public(package) fun metadata_update_marker(): MetadataUpdate { MetadataUpdate {} }

public(package) fun twap_config_update_marker(): TwapConfigUpdate { TwapConfigUpdate {} }

public(package) fun governance_update_marker(): GovernanceUpdate { GovernanceUpdate {} }

public(package) fun metadata_table_update_marker(): MetadataTableUpdate {
    MetadataTableUpdate {}
}

public(package) fun sponsorship_config_update_marker(): SponsorshipConfigUpdate {
    SponsorshipConfigUpdate {}
}

public(package) fun update_conditional_metadata_marker(): UpdateConditionalMetadata {
    UpdateConditionalMetadata {}
}

public(package) fun sync_twap_observation_from_proposal_marker(): SyncTwapObservationFromProposal {
    SyncTwapObservationFromProposal {}
}

#[test_only]
public fun sync_twap_observation_from_proposal_marker_for_testing(): SyncTwapObservationFromProposal {
    SyncTwapObservationFromProposal {}
}

// === Errors ===
const EEmptyName: u64 = 1;
const EInvalidParameter: u64 = 2;
const EEmptyString: u64 = 3;
const EMismatchedKeyValueLength: u64 = 4;
const EUnsupportedActionVersion: u64 = 8;
const ENotActive: u64 = 9; // DAO must be in ACTIVE state for this operation
const EProposalDaoMismatch: u64 = 11; // Proposal does not belong to this DAO
const EProposalExecutableMismatch: u64 = 13; // Proposal does not match executable's outcome
const ENameMustBeAscii: u64 = 14;

fun assert_account_authority<Outcome: store>(executable: &Executable<Outcome>, account: &Account) {
    executable::intent(executable).assert_is_account(account.addr());
}

fun assert_dao_active(account: &Account) {
    let dao_state = futarchy_config::dao_state(account::config<FutarchyConfig>(account));
    assert!(
        futarchy_config::operational_state(dao_state) == futarchy_config::state_active(),
        ENotActive,
    );
}

fun assert_configured_asset_type<AssetType>(account: &Account) {
    let config = account::config<FutarchyConfig>(account);
    let expected_asset_type = futarchy_config::asset_type(config);
    let actual_asset_type = type_name::with_original_ids<AssetType>().into_string().to_string();
    assert!(expected_asset_type == &actual_asset_type, EInvalidParameter);
}

fun assert_ascii_string(value: &String) {
    let bytes = value.as_bytes();
    let mut i = 0;
    while (i < bytes.length()) {
        assert!(*bytes.borrow(i) <= 127, ENameMustBeAscii);
        i = i + 1;
    };
}

// === Witness ===

/// Witness for config module operations
public struct ConfigActionsWitness has drop {}

// === Events ===

/// Emitted when proposals are enabled or disabled
public struct ProposalsEnabledChanged has copy, drop {
    account_id: ID,
    enabled: bool,
    timestamp: u64,
}

/// Emitted when DAO is terminated (irreversible)
public struct DaoTerminated has copy, drop {
    account_id: ID,
    reason: String,
    timestamp: u64,
}

/// Emitted when DAO name is updated
public struct DaoNameChanged has copy, drop {
    account_id: ID,
    new_name: String,
    timestamp: u64,
}

/// Emitted when trading parameters are updated
public struct TradingParamsChanged has copy, drop {
    account_id: ID,
    timestamp: u64,
}

/// Emitted when metadata is updated
public struct MetadataChanged has copy, drop {
    account_id: ID,
    timestamp: u64,
}

/// Emitted when TWAP config is updated
public struct TwapConfigChanged has copy, drop {
    account_id: ID,
    timestamp: u64,
}

/// Emitted when governance settings are updated
public struct GovernanceSettingsChanged has copy, drop {
    account_id: ID,
    timestamp: u64,
}

/// Emitted when conditional metadata config is updated
public struct ConditionalMetadataChanged has copy, drop {
    account_id: ID,
    has_fallback_metadata: bool,
    use_outcome_index: bool,
    timestamp: u64,
}

/// Emitted when sponsorship config is updated
public struct SponsorshipConfigChanged has copy, drop {
    account_id: ID,
    enabled: bool,
    timestamp: u64,
}

/// Emitted when TWAP initial observation is synced
public struct TwapObservationSynced has copy, drop {
    account_id: ID,
    new_observation: u128,
    source: u8, // 0 = launchpad, 1 = proposal_twap
    timestamp: u64,
}

// === Constants for TWAP observation source ===
const TWAP_SOURCE_PROPOSAL: u8 = 1;

// === Basic Action Structs ===

/// Action to permanently terminate the DAO
/// WARNING: This is IRREVERSIBLE - DAO cannot be reactivated after termination
/// Sets operational state to TERMINATED, blocking all new proposals
/// Existing proposals may still complete, but no new ones can be created
/// This must go through the normal futarchy governance process
public struct TerminateDaoAction has copy, drop, store {
    reason: String, // Why DAO is being terminated (for transparency/audit trail)
    // Time to wait before redemption opens (allows auctions/settlements)
    dissolution_unlock_delay_ms: u64,
}

/// Action to update the DAO name
/// This must go through the normal futarchy governance process
public struct UpdateNameAction has copy, drop, store {
    new_name: String,
}

// === Advanced Action Structs ===

/// Trading parameters update action
/// NOTE: asset_decimals and stable_decimals removed - decimals are immutable in Sui coins
/// Read from sui::coin_registry::Currency<T> instead
public struct TradingParamsUpdateAction has copy, drop, store {
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    amm_total_fee_bps: Option<u64>,
    conditional_liquidity_ratio_percent: Option<u64>,
}

/// DAO metadata update action
public struct MetadataUpdateAction has copy, drop, store {
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
}

/// TWAP configuration update action
public struct TwapConfigUpdateAction has copy, drop, store {
    start_delay: Option<u64>,
    cap_ppm: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u128>,
    sponsored_threshold: Option<u128>, // How much lower sponsored outcomes will be allowed (base 100,000)
}

/// Governance settings update action
public struct GovernanceUpdateAction has copy, drop, store {
    max_outcomes: Option<u64>,
    max_actions_per_outcome: Option<u64>,
    proposal_intent_expiry_ms: Option<u64>,
    proposal_creation_fee: Option<u64>, // DAO-level proposal creation fee
    proposal_fee_per_outcome: Option<u64>, // DAO-level fee per additional outcome
    fee_in_asset_token: Option<bool>, // true = fees in AssetType, false = fees in StableType (default)
}

/// Metadata table update action
public struct MetadataTableUpdateAction has copy, drop, store {
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
}

/// Conditional metadata configuration update action
public struct ConditionalMetadataUpdateAction has copy, drop, store {
    use_outcome_index: Option<bool>,
    // If Some(Some(metadata)), set fallback metadata to the inner value
    // If Some(None), remove fallback metadata
    // If None, don't change fallback metadata
    conditional_metadata: Option<Option<dao_config::ConditionalMetadata>>,
}

/// Sponsorship configuration update action
public struct SponsorshipConfigUpdateAction has copy, drop, store {
    enabled: Option<bool>,
}

/// Sync TWAP initial observation action (empty - source determined by marker type)
/// Used by both SyncTwapObservationFromLaunchpad and SyncTwapObservationFromProposal
public struct SyncTwapObservationAction has copy, drop, store {}

// === Basic Execution Functions ===

/// Execute a terminate DAO action
/// WARNING: This is IRREVERSIBLE - sets operational state to TERMINATED
public fun do_terminate_dao<AssetType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<TerminateDao>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let reason_bytes = reader.peel_vec_u8();
    let reason = string::utf8(reason_bytes);
    let dissolution_unlock_delay_ms = reader.peel_u64();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate reason is not empty
    assert!(reason.length() > 0, EEmptyString);

    // Verify DAO is currently active and capture the configured asset supply
    // before setting the terminal state.
    assert_dao_active(account);
    assert_configured_asset_type<AssetType>(account);
    let total_asset_supply = currency::coin_type_supply<AssetType>(account, registry);
    assert!(total_asset_supply > 0, EInvalidParameter);

    // CRITICAL: This is irreversible - set to TERMINATED and store dissolution params.
    let terminated_at = clock.timestamp_ms();
    futarchy_config::terminate_dao_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        terminated_at,
        dissolution_unlock_delay_ms,
        total_asset_supply,
    );

    // Note: Proposal creation is disabled via state_terminated() above
    // The GovernanceConfig setters are package-private so we can't call them here

    // Emit event
    event::emit(DaoTerminated {
        account_id: object::id(account),
        reason,
        timestamp: clock.timestamp_ms(),
    });

    let _ = intent_witness;

    // Increment action index
    executable::increment_action_idx<_, TerminateDao, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute an update name action
public fun do_update_name<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    assert_dao_active(account);
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<UpdateName>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let new_name = string::utf8(reader.peel_vec_u8());

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate
    assert!(new_name.length() > 0, EEmptyName);
    assert_ascii_string(&new_name);

    futarchy_config::set_dao_name_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        new_name,
    );

    // Emit event
    event::emit(DaoNameChanged {
        account_id: object::id(account),
        new_name,
        timestamp: clock.timestamp_ms(),
    });

    // Increment action index
    executable::increment_action_idx<_, UpdateName, _>(executable, registry, ExecutionProgressWitness {});
}

// === Advanced Execution Functions ===

/// Execute a trading params update action
public fun do_update_trading_params<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    assert_dao_active(account);
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<TradingParamsUpdate>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let min_asset_amount = reader.peel_option_u64();
    let min_stable_amount = reader.peel_option_u64();
    let review_period_ms = reader.peel_option_u64();
    let trading_period_ms = reader.peel_option_u64();
    let amm_total_fee_bps = reader.peel_option_u64();
    let conditional_liquidity_ratio_percent = reader.peel_option_u64();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct for validation
    let action = TradingParamsUpdateAction {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps,
        conditional_liquidity_ratio_percent,
    };

    // Validate parameters
    validate_trading_params_update(&action);

    futarchy_config::apply_trading_params_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        action.min_asset_amount,
        action.min_stable_amount,
        action.review_period_ms,
        action.trading_period_ms,
        action.amm_total_fee_bps,
        action.conditional_liquidity_ratio_percent,
    );
    // NOTE: asset_decimals and stable_decimals are immutable in Sui coins

    // Emit event
    event::emit(TradingParamsChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });

    // Increment action index
    executable::increment_action_idx<_, TradingParamsUpdate, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute a metadata update action
public fun do_update_metadata<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    assert_dao_active(account);
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<MetadataUpdate>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let dao_name = if (reader.peel_bool()) {
        option::some(ascii::string(reader.peel_vec_u8()))
    } else {
        option::none()
    };
    let icon_url = if (reader.peel_bool()) {
        option::some(url::new_unsafe_from_bytes(reader.peel_vec_u8()))
    } else {
        option::none()
    };
    let description = if (reader.peel_bool()) {
        option::some(string::utf8(reader.peel_vec_u8()))
    } else {
        option::none()
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct for validation
    let action = MetadataUpdateAction {
        dao_name,
        icon_url,
        description,
    };

    // Validate parameters
    validate_metadata_update(&action);

    let dao_name = if (action.dao_name.is_some()) {
        option::some(string::from_ascii(*action.dao_name.borrow()))
    } else {
        option::none()
    };
    let icon_url = if (action.icon_url.is_some()) {
        let url = *action.icon_url.borrow();
        option::some(string::from_ascii(url.inner_url()))
    } else {
        option::none()
    };
    futarchy_config::apply_metadata_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        dao_name,
        icon_url,
        action.description,
    );

    // Emit event
    event::emit(MetadataChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });

    // Increment action index
    executable::increment_action_idx<_, MetadataUpdate, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute a TWAP config update action
public fun do_update_twap_config<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    assert_dao_active(account);
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<TwapConfigUpdate>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let start_delay = reader.peel_option_u64();
    let cap_ppm = reader.peel_option_u64();
    let initial_observation = reader.peel_option_u128();
    let threshold = reader.peel_option_u128();
    let sponsored_threshold = reader.peel_option_u128();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct for validation
    let action = TwapConfigUpdateAction {
        start_delay,
        cap_ppm,
        initial_observation,
        threshold,
        sponsored_threshold,
    };

    // Validate parameters
    validate_twap_config_update(&action);

    futarchy_config::apply_twap_config_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        action.start_delay,
        action.cap_ppm,
        action.initial_observation,
        action.threshold,
        action.sponsored_threshold,
    );

    // Emit event
    event::emit(TwapConfigChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });

    // Increment action index
    executable::increment_action_idx<_, TwapConfigUpdate, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute a governance update action
public fun do_update_governance<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    assert_dao_active(account);
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<GovernanceUpdate>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let max_outcomes = reader.peel_option_u64();
    let max_actions_per_outcome = reader.peel_option_u64();
    let proposal_intent_expiry_ms = reader.peel_option_u64();
    let proposal_creation_fee = reader.peel_option_u64();
    let proposal_fee_per_outcome = reader.peel_option_u64();
    let fee_in_asset_token = reader.peel_option_bool();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct for validation
    let action = GovernanceUpdateAction {
        max_outcomes,
        max_actions_per_outcome,
        proposal_intent_expiry_ms,
        proposal_creation_fee,
        proposal_fee_per_outcome,
        fee_in_asset_token,
    };

    // Validate parameters
    validate_governance_update(&action);

    futarchy_config::apply_governance_updates_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        action.max_outcomes,
        action.max_actions_per_outcome,
        action.proposal_intent_expiry_ms,
        action.proposal_creation_fee,
        action.proposal_fee_per_outcome,
        action.fee_in_asset_token,
    );

    // Emit event
    event::emit(GovernanceSettingsChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });

    // Increment action index
    executable::increment_action_idx<_, GovernanceUpdate, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute a metadata table update action
/// Updates the DAO's metadata table stored as managed data on the Account
public fun do_update_metadata_table<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    assert_dao_active(account);
    let _ = intent_witness; // API consistency - may be used for additional auth in future

    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<MetadataTableUpdate>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let keys = {
        let len = reader.peel_vec_length();
        let mut result = vector[];
        let mut i = 0;
        while (i < len) {
            result.push_back(string::utf8(reader.peel_vec_u8()));
            i = i + 1;
        };
        result
    };
    let values = {
        let len = reader.peel_vec_length();
        let mut result = vector[];
        let mut i = 0;
        while (i < len) {
            result.push_back(string::utf8(reader.peel_vec_u8()));
            i = i + 1;
        };
        result
    };
    let keys_to_remove = {
        let len = reader.peel_vec_length();
        let mut result = vector[];
        let mut i = 0;
        while (i < len) {
            result.push_back(string::utf8(reader.peel_vec_u8()));
            i = i + 1;
        };
        result
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct for validation
    let action = MetadataTableUpdateAction {
        keys,
        values,
        keys_to_remove,
    };

    // Validate parameters
    assert!(action.keys.length() == action.values.length(), EMismatchedKeyValueLength);

    // Get or create metadata table as managed data on Account
    let metadata_key = futarchy_config::new_metadata_table_key();

    if (!account::has_managed_data(account, metadata_key)) {
        // Create new metadata table
        let metadata_table = table::new<String, String>(ctx);
        account::add_managed_data(
            account,
            registry,
            metadata_key,
            metadata_table,
            executable,
            ExecutionProgressWitness {},
        );
    };

    // Get mutable reference to metadata table
    let metadata_table: &mut Table<String, String> = account::borrow_managed_data_mut(
        account,
        registry,
        metadata_key,
        executable,
        ExecutionProgressWitness {},
    );

    // Add/update entries
    let mut i = 0;
    while (i < action.keys.length()) {
        let key = *action.keys.borrow(i);
        let value = *action.values.borrow(i);

        if (table::contains(metadata_table, key)) {
            // Update existing entry
            *table::borrow_mut(metadata_table, key) = value;
        } else {
            // Add new entry
            table::add(metadata_table, key, value);
        };
        i = i + 1;
    };

    // Remove entries
    let mut j = 0;
    while (j < action.keys_to_remove.length()) {
        let key = *action.keys_to_remove.borrow(j);
        if (table::contains(metadata_table, key)) {
            table::remove(metadata_table, key);
        };
        j = j + 1;
    };

    // Emit event
    event::emit(MetadataChanged {
        account_id: object::id(account),
        timestamp: clock.timestamp_ms(),
    });

    // Increment action index
    executable::increment_action_idx<_, MetadataTableUpdate, _>(executable, registry, ExecutionProgressWitness {});
}

/// Update conditional metadata configuration
/// This controls how conditional token metadata is derived during proposal creation
public fun do_update_conditional_metadata<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    assert_dao_active(account);
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<UpdateConditionalMetadata>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let use_outcome_index_opt = bcs::peel_option!(&mut reader, |r| r.peel_bool());
    let conditional_metadata_opt = bcs::peel_option!(&mut reader, |r| {
        bcs::peel_option!(r, |r2| {
            let decimals = r2.peel_u8();
            let coin_name_prefix = r2.peel_vec_u8().to_ascii_string();
            let icon_url_bytes = r2.peel_vec_u8().to_ascii_string();
            let coin_icon_url = url::new_unsafe(icon_url_bytes);
            dao_config::new_conditional_metadata(decimals, coin_name_prefix, coin_icon_url)
        })
    });

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Get account ID first before taking mutable borrows
    let account_id = object::id(account);

    futarchy_config::apply_conditional_metadata_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        use_outcome_index_opt,
        conditional_metadata_opt,
    );

    // Get final values after updates
    let dao_cfg = futarchy_config::dao_config(account::config<FutarchyConfig>(account));
    let coin_cfg = dao_config::conditional_coin_config(dao_cfg);
    let final_use_outcome_index = dao_config::use_outcome_index(coin_cfg);
    let final_has_fallback = dao_config::conditional_metadata(coin_cfg).is_some();

    // Emit event
    event::emit(ConditionalMetadataChanged {
        account_id,
        has_fallback_metadata: final_has_fallback,
        use_outcome_index: final_use_outcome_index,
        timestamp: clock.timestamp_ms(),
    });

    // Increment action index
    executable::increment_action_idx<_, UpdateConditionalMetadata, _>(executable, registry, ExecutionProgressWitness {});
}

/// Sync TWAP initial observation from proposal's winning TWAP
/// This reads the winning outcome's TWAP from the proposal being executed and sets it as the
/// amm_twap_initial_observation for future proposals.
/// Used when a proposal passes to update the TWAP base to reflect market-discovered price.
public fun do_sync_twap_observation_from_proposal<AssetType, StableType, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    proposal: &Proposal<AssetType, StableType>,
    _intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    assert_dao_active(account);

    // SECURITY: Verify proposal belongs to this DAO to prevent TWAP manipulation attacks
    // An attacker could pass a proposal from a different DAO with a favorable TWAP
    assert!(proposal::get_dao_id(proposal) == object::id(account), EProposalDaoMismatch);

    // SECURITY: Verify the passed proposal matches the Executable's FutarchyOutcome.
    // Without this, an executor could pass a different finalized proposal from the same DAO,
    // syncing that proposal's TWAP data instead of the executing proposal's.
    let outcome_proposal_id = futarchy_config::outcome_proposal_id(
        intents::outcome(executable.intent()),
    );
    assert!(
        option::is_some(&outcome_proposal_id) &&
        *option::borrow(&outcome_proposal_id) == object::id(proposal),
        EProposalExecutableMismatch,
    );

    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<SyncTwapObservationFromProposal>(action_spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // No fields to deserialize - action struct is empty
    // Still validate bytes consumed (empty)
    let action_data = protocol_intents::action_spec_data(action_spec);
    let reader = bcs::new(*action_data);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Read the winning TWAP from the proposal
    // NOTE: Proposal must be in FINALIZED state for get_winning_twap to work
    let new_observation = proposal::get_winning_twap(proposal);

    // Get account ID before mutable borrow
    let account_id = object::id(account);

    // Set the TWAP initial observation via execution-gated config mutator.
    futarchy_config::set_twap_initial_observation_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        new_observation,
    );

    // Emit event
    event::emit(TwapObservationSynced {
        account_id,
        new_observation,
        source: TWAP_SOURCE_PROPOSAL,
        timestamp: clock.timestamp_ms(),
    });

    // Increment action index
    executable::increment_action_idx<_, SyncTwapObservationFromProposal, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute a sponsorship config update action
public fun do_update_sponsorship_config<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    intent_witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_account_authority(executable, account);
    assert_dao_active(account);
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<SponsorshipConfigUpdate>(action_spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let enabled = reader.peel_option_bool();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Get account ID first before taking mutable borrows
    let account_id = object::id(account);

    futarchy_config::apply_sponsorship_config_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
        enabled,
    );

    // Get final values after updates
    let dao_cfg = futarchy_config::dao_config(account::config<FutarchyConfig>(account));
    let sponsorship_cfg = dao_config::sponsorship_config(dao_cfg);
    let final_enabled = dao_config::sponsorship_enabled(sponsorship_cfg);

    // Emit event
    event::emit(SponsorshipConfigChanged {
        account_id,
        enabled: final_enabled,
        timestamp: clock.timestamp_ms(),
    });

    // Increment action index
    executable::increment_action_idx<_, SponsorshipConfigUpdate, _>(executable, registry, ExecutionProgressWitness {});
}

// === Destruction Functions ===

/// Destroy an UpdateNameAction
public fun destroy_update_name(action: UpdateNameAction) {
    let UpdateNameAction { new_name: _ } = action;
}

/// Destroy a TradingParamsUpdateAction
public fun destroy_trading_params_update(action: TradingParamsUpdateAction) {
    let TradingParamsUpdateAction {
        min_asset_amount: _,
        min_stable_amount: _,
        review_period_ms: _,
        trading_period_ms: _,
        amm_total_fee_bps: _,
        conditional_liquidity_ratio_percent: _,
    } = action;
}

/// Destroy a MetadataUpdateAction
public fun destroy_metadata_update(action: MetadataUpdateAction) {
    let MetadataUpdateAction {
        dao_name: _,
        icon_url: _,
        description: _,
    } = action;
}

/// Destroy a TwapConfigUpdateAction
public fun destroy_twap_config_update(action: TwapConfigUpdateAction) {
    let TwapConfigUpdateAction {
        start_delay: _,
        cap_ppm: _,
        initial_observation: _,
        threshold: _,
        sponsored_threshold: _,
    } = action;
}

/// Destroy a GovernanceUpdateAction
public fun destroy_governance_update(action: GovernanceUpdateAction) {
    let GovernanceUpdateAction {
        max_outcomes: _,
        max_actions_per_outcome: _,
        proposal_intent_expiry_ms: _,
        proposal_creation_fee: _,
        proposal_fee_per_outcome: _,
        fee_in_asset_token: _,
    } = action;
}

/// Destroy a MetadataTableUpdateAction
public fun destroy_metadata_table_update(action: MetadataTableUpdateAction) {
    let MetadataTableUpdateAction {
        keys: _,
        values: _,
        keys_to_remove: _,
    } = action;
}

/// Destroy a SponsorshipConfigUpdateAction
public fun destroy_sponsorship_config_update(action: SponsorshipConfigUpdateAction) {
    let SponsorshipConfigUpdateAction {
        enabled: _,
    } = action;
}

// === Constructor Functions ===

/// Create a terminate DAO action
public fun new_terminate_dao_action(
    reason: String,
    dissolution_unlock_delay_ms: u64,
): TerminateDaoAction {
    assert!(reason.length() > 0, EEmptyString);
    TerminateDaoAction {
        reason,
        dissolution_unlock_delay_ms,
    }
}

/// Create an update name action
public fun new_update_name_action(new_name: String): UpdateNameAction {
    assert!(new_name.length() > 0, EEmptyName);
    assert_ascii_string(&new_name);
    UpdateNameAction { new_name }
}

/// Create a trading params update action
/// NOTE: asset_decimals and stable_decimals removed - decimals are immutable in Sui coins
public fun new_trading_params_update_action(
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    amm_total_fee_bps: Option<u64>,
    conditional_liquidity_ratio_percent: Option<u64>,
): TradingParamsUpdateAction {
    let action = TradingParamsUpdateAction {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps,
        conditional_liquidity_ratio_percent,
    };
    validate_trading_params_update(&action);
    action
}

/// Create a metadata update action
public fun new_metadata_update_action(
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
): MetadataUpdateAction {
    let action = MetadataUpdateAction {
        dao_name,
        icon_url,
        description,
    };
    validate_metadata_update(&action);
    action
}

/// Create a TWAP config update action
public fun new_twap_config_update_action(
    start_delay: Option<u64>,
    cap_ppm: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u128>,
    sponsored_threshold: Option<u128>,
): TwapConfigUpdateAction {
    let action = TwapConfigUpdateAction {
        start_delay,
        cap_ppm,
        initial_observation,
        threshold,
        sponsored_threshold,
    };
    validate_twap_config_update(&action);
    action
}

/// Create a governance update action
public fun new_governance_update_action(
    max_outcomes: Option<u64>,
    max_actions_per_outcome: Option<u64>,
    proposal_intent_expiry_ms: Option<u64>,
    proposal_creation_fee: Option<u64>,
    proposal_fee_per_outcome: Option<u64>,
    fee_in_asset_token: Option<bool>,
): GovernanceUpdateAction {
    let action = GovernanceUpdateAction {
        max_outcomes,
        max_actions_per_outcome,
        proposal_intent_expiry_ms,
        proposal_creation_fee,
        proposal_fee_per_outcome,
        fee_in_asset_token,
    };
    validate_governance_update(&action);
    action
}

/// Create a metadata table update action
public fun new_metadata_table_update_action(
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
): MetadataTableUpdateAction {
    assert!(keys.length() == values.length(), EMismatchedKeyValueLength);
    MetadataTableUpdateAction {
        keys,
        values,
        keys_to_remove,
    }
}

/// Create a conditional metadata update action
public fun new_conditional_metadata_update_action(
    use_outcome_index: Option<bool>,
    conditional_metadata: Option<Option<dao_config::ConditionalMetadata>>,
): ConditionalMetadataUpdateAction {
    ConditionalMetadataUpdateAction {
        use_outcome_index,
        conditional_metadata,
    }
}

/// Create a sponsorship config update action
public fun new_sponsorship_config_update_action(
    enabled: Option<bool>,
): SponsorshipConfigUpdateAction {
    SponsorshipConfigUpdateAction {
        enabled,
    }
}

/// Create a sync TWAP observation action
public fun new_sync_twap_observation_action(): SyncTwapObservationAction {
    SyncTwapObservationAction {}
}

// === Intent Creation Functions (with serialize-then-destroy pattern) ===

/// Add an UpdateName action to an intent
public fun new_update_name<Outcome, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    new_name: String,
    intent_witness: IW,
) {
    assert!(new_name.length() > 0, EEmptyName);
    assert_ascii_string(&new_name);
    let action = UpdateNameAction { new_name };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        UpdateName {},
        action_data,
        intent_witness,
    );
    destroy_update_name(action);
}

/// Add a TradingParamsUpdate action to an intent
/// NOTE: asset_decimals and stable_decimals removed - decimals are immutable in Sui coins
public fun new_trading_params_update<Outcome, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    amm_total_fee_bps: Option<u64>,
    conditional_liquidity_ratio_percent: Option<u64>,
    intent_witness: IW,
) {
    let action = TradingParamsUpdateAction {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps,
        conditional_liquidity_ratio_percent,
    };
    validate_trading_params_update(&action);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        TradingParamsUpdate {},
        action_data,
        intent_witness,
    );
    destroy_trading_params_update(action);
}

/// Add a MetadataUpdate action to an intent
public fun new_metadata_update<Outcome, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
    intent_witness: IW,
) {
    let action = MetadataUpdateAction {
        dao_name,
        icon_url,
        description,
    };
    validate_metadata_update(&action);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        MetadataUpdate {},
        action_data,
        intent_witness,
    );
    destroy_metadata_update(action);
}

/// Add a TwapConfigUpdate action to an intent
public fun new_twap_config_update<Outcome, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    start_delay: Option<u64>,
    cap_ppm: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u128>,
    sponsored_threshold: Option<u128>,
    intent_witness: IW,
) {
    let action = TwapConfigUpdateAction {
        start_delay,
        cap_ppm,
        initial_observation,
        threshold,
        sponsored_threshold,
    };
    validate_twap_config_update(&action);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        TwapConfigUpdate {},
        action_data,
        intent_witness,
    );
    destroy_twap_config_update(action);
}

/// Add a GovernanceUpdate action to an intent
public fun new_governance_update<Outcome, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    max_outcomes: Option<u64>,
    max_actions_per_outcome: Option<u64>,
    proposal_intent_expiry_ms: Option<u64>,
    proposal_creation_fee: Option<u64>,
    proposal_fee_per_outcome: Option<u64>,
    fee_in_asset_token: Option<bool>,
    intent_witness: IW,
) {
    let action = GovernanceUpdateAction {
        max_outcomes,
        max_actions_per_outcome,
        proposal_intent_expiry_ms,
        proposal_creation_fee,
        proposal_fee_per_outcome,
        fee_in_asset_token,
    };
    validate_governance_update(&action);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        GovernanceUpdate {},
        action_data,
        intent_witness,
    );
    destroy_governance_update(action);
}

/// Add a MetadataTableUpdate action to an intent
public fun new_metadata_table_update<Outcome, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
    intent_witness: IW,
) {
    assert!(keys.length() == values.length(), EMismatchedKeyValueLength);
    let action = MetadataTableUpdateAction {
        keys,
        values,
        keys_to_remove,
    };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        MetadataTableUpdate {},
        action_data,
        intent_witness,
    );
    destroy_metadata_table_update(action);
}

// === Getter Functions ===

/// Get new name field
public fun get_new_name(action: &UpdateNameAction): String {
    action.new_name
}

/// Get trading params update fields
/// NOTE: asset_decimals and stable_decimals removed - decimals are immutable in Sui coins
public fun get_trading_params_fields(
    update: &TradingParamsUpdateAction,
): (&Option<u64>, &Option<u64>, &Option<u64>, &Option<u64>, &Option<u64>, &Option<u64>) {
    (
        &update.min_asset_amount,
        &update.min_stable_amount,
        &update.review_period_ms,
        &update.trading_period_ms,
        &update.amm_total_fee_bps,
        &update.conditional_liquidity_ratio_percent,
    )
}

/// Get metadata update fields
public fun get_metadata_fields(
    update: &MetadataUpdateAction,
): (&Option<AsciiString>, &Option<Url>, &Option<String>) {
    (&update.dao_name, &update.icon_url, &update.description)
}

/// Get TWAP config update fields
public fun get_twap_config_fields(
    update: &TwapConfigUpdateAction,
): (&Option<u64>, &Option<u64>, &Option<u128>, &Option<u128>, &Option<u128>) {
    (
        &update.start_delay,
        &update.cap_ppm,
        &update.initial_observation,
        &update.threshold,
        &update.sponsored_threshold,
    )
}

/// Get governance update fields
public fun get_governance_fields(
    update: &GovernanceUpdateAction,
): (&Option<u64>, &Option<u64>, &Option<u64>, &Option<u64>, &Option<u64>, &Option<bool>) {
    (
        &update.max_outcomes,
        &update.max_actions_per_outcome,
        &update.proposal_intent_expiry_ms,
        &update.proposal_creation_fee,
        &update.proposal_fee_per_outcome,
        &update.fee_in_asset_token,
    )
}

/// Get metadata table update fields
public fun get_metadata_table_fields(
    update: &MetadataTableUpdateAction,
): (&vector<String>, &vector<String>, &vector<String>) {
    (&update.keys, &update.values, &update.keys_to_remove)
}

// === Metadata Table Reader Functions ===

/// Check if the DAO has a metadata table
public fun has_metadata_table(account: &Account): bool {
    account::has_managed_data(account, futarchy_config::new_metadata_table_key())
}

/// Get a value from the DAO's metadata table
/// Returns None if key doesn't exist or table doesn't exist
public fun get_metadata_value(
    account: &Account,
    registry: &PackageRegistry,
    key: &String,
): Option<String> {
    let metadata_key = futarchy_config::new_metadata_table_key();
    if (!account::has_managed_data(account, metadata_key)) {
        return option::none()
    };

    let metadata_table: &Table<String, String> = account::borrow_managed_data_with_package_witness(
        account,
        registry,
        metadata_key,
        version::current(),
    );

    if (table::contains(metadata_table, *key)) {
        option::some(*table::borrow(metadata_table, *key))
    } else {
        option::none()
    }
}

// === Internal Validation Functions ===

/// Validate trading params update
/// Checks mirror dao_config setters exactly to prevent staging-execution mismatch
fun validate_trading_params_update(action: &TradingParamsUpdateAction) {
    if (action.min_asset_amount.is_some()) {
        let v = *action.min_asset_amount.borrow();
        assert!(v > 0, EInvalidParameter);
        assert!(v >= futarchy_one_shot_utils::constants::protocol_min_liquidity_amount(), EInvalidParameter);
    };
    if (action.min_stable_amount.is_some()) {
        let v = *action.min_stable_amount.borrow();
        assert!(v > 0, EInvalidParameter);
        assert!(v >= futarchy_one_shot_utils::constants::protocol_min_liquidity_amount(), EInvalidParameter);
    };
    if (action.review_period_ms.is_some()) {
        let v = *action.review_period_ms.borrow();
        assert!(v >= futarchy_one_shot_utils::constants::min_review_period_ms(), EInvalidParameter);
        assert!(v <= futarchy_one_shot_utils::constants::max_trading_duration_ms(), EInvalidParameter);
    };
    if (action.trading_period_ms.is_some()) {
        let v = *action.trading_period_ms.borrow();
        assert!(v >= futarchy_one_shot_utils::constants::min_trading_period_ms(), EInvalidParameter);
        assert!(v <= futarchy_one_shot_utils::constants::max_trading_duration_ms(), EInvalidParameter);
    };
    if (action.amm_total_fee_bps.is_some()) {
        assert!(
            *action.amm_total_fee_bps.borrow() <= futarchy_one_shot_utils::constants::max_amm_fee_bps(),
            EInvalidParameter,
        );
    };
    if (action.conditional_liquidity_ratio_percent.is_some()) {
        let ratio = *action.conditional_liquidity_ratio_percent.borrow();
        assert!(
            ratio >= futarchy_one_shot_utils::constants::min_conditional_liquidity_percent()
                && ratio <= futarchy_one_shot_utils::constants::max_conditional_liquidity_percent(),
            EInvalidParameter,
        );
    };
}

/// Validate metadata update
fun validate_metadata_update(action: &MetadataUpdateAction) {
    if (action.dao_name.is_some()) {
        assert!(action.dao_name.borrow().length() > 0, EEmptyString);
    };
    if (action.description.is_some()) {
        assert!(action.description.borrow().length() > 0, EEmptyString);
    };
}

/// Validate TWAP config update
/// Checks mirror dao_config setters exactly to prevent staging-execution mismatch
fun validate_twap_config_update(action: &TwapConfigUpdateAction) {
    if (action.start_delay.is_some()) {
        let v = *action.start_delay.borrow();
        assert!(v < futarchy_one_shot_utils::constants::one_week_ms(), EInvalidParameter);
        assert!(v % futarchy_one_shot_utils::constants::twap_price_cap_window() == 0, EInvalidParameter);
    };
    if (action.cap_ppm.is_some()) {
        let v = *action.cap_ppm.borrow();
        assert!(v > 0, EInvalidParameter);
        assert!(v <= futarchy_one_shot_utils::constants::ppm_denominator(), EInvalidParameter);
    };
    if (action.initial_observation.is_some()) {
        assert!(*action.initial_observation.borrow() > 0, EInvalidParameter);
    };
    if (action.threshold.is_some()) {
        assert!(
            *action.threshold.borrow() <= futarchy_one_shot_utils::constants::twap_threshold_base(),
            EInvalidParameter,
        );
    };
    if (action.sponsored_threshold.is_some()) {
        assert!(
            *action.sponsored_threshold.borrow() <= futarchy_one_shot_utils::constants::max_sponsored_threshold(),
            EInvalidParameter,
        );
    };
}

/// Validate governance update
/// Checks mirror dao_config setters exactly to prevent staging-execution mismatch
fun validate_governance_update(action: &GovernanceUpdateAction) {
    if (action.max_outcomes.is_some()) {
        let max_outcomes = *action.max_outcomes.borrow();
        assert!(max_outcomes >= futarchy_one_shot_utils::constants::min_outcomes(), EInvalidParameter);
        assert!(max_outcomes <= futarchy_one_shot_utils::constants::protocol_max_outcomes(), EInvalidParameter);
    };
    if (action.max_actions_per_outcome.is_some()) {
        let v = *action.max_actions_per_outcome.borrow();
        assert!(v > 0, EInvalidParameter);
        assert!(v <= futarchy_one_shot_utils::constants::protocol_max_actions_per_outcome(), EInvalidParameter);
    };
    if (action.proposal_intent_expiry_ms.is_some()) {
        assert!(
            *action.proposal_intent_expiry_ms.borrow() >= futarchy_one_shot_utils::constants::min_proposal_intent_expiry_ms(),
            EInvalidParameter,
        );
    };
    if (action.proposal_creation_fee.is_some()) {
        assert!(
            *action.proposal_creation_fee.borrow() <= futarchy_one_shot_utils::constants::max_proposal_creation_fee(),
            EInvalidParameter,
        );
    };
    if (action.proposal_fee_per_outcome.is_some()) {
        assert!(
            *action.proposal_fee_per_outcome.borrow() <= futarchy_one_shot_utils::constants::max_proposal_fee_per_outcome(),
            EInvalidParameter,
        );
    };
}

// === Deserialization Constructors ===

/// Deserialize UpdateNameAction from bytes
public(package) fun update_name_action_from_bytes(bytes: vector<u8>): UpdateNameAction {
    let mut bcs = bcs::new(bytes);
    let action = UpdateNameAction {
        new_name: string::utf8(bcs.peel_vec_u8()),
    };
    assert!(action.new_name.length() > 0, EEmptyName);
    assert_ascii_string(&action.new_name);
    action
}

/// Deserialize MetadataUpdateAction from bytes
public(package) fun metadata_update_action_from_bytes(bytes: vector<u8>): MetadataUpdateAction {
    let mut bcs = bcs::new(bytes);
    MetadataUpdateAction {
        dao_name: if (bcs.peel_bool()) {
            option::some(ascii::string(bcs.peel_vec_u8()))
        } else {
            option::none()
        },
        icon_url: if (bcs.peel_bool()) {
            option::some(url::new_unsafe_from_bytes(bcs.peel_vec_u8()))
        } else {
            option::none()
        },
        description: if (bcs.peel_bool()) {
            option::some(string::utf8(bcs.peel_vec_u8()))
        } else {
            option::none()
        },
    }
}

/// Deserialize TradingParamsUpdateAction from bytes
public(package) fun trading_params_update_action_from_bytes(
    bytes: vector<u8>,
): TradingParamsUpdateAction {
    let mut bcs = bcs::new(bytes);
    TradingParamsUpdateAction {
        min_asset_amount: bcs.peel_option_u64(),
        min_stable_amount: bcs.peel_option_u64(),
        review_period_ms: bcs.peel_option_u64(),
        trading_period_ms: bcs.peel_option_u64(),
        amm_total_fee_bps: bcs.peel_option_u64(),
        conditional_liquidity_ratio_percent: bcs.peel_option_u64(),
    }
}

/// Deserialize TwapConfigUpdateAction from bytes
public(package) fun twap_config_update_action_from_bytes(
    bytes: vector<u8>,
): TwapConfigUpdateAction {
    let mut bcs = bcs::new(bytes);
    TwapConfigUpdateAction {
        start_delay: bcs.peel_option_u64(),
        cap_ppm: bcs.peel_option_u64(),
        initial_observation: bcs.peel_option_u128(),
        threshold: bcs.peel_option_u128(),
        sponsored_threshold: bcs.peel_option_u128(),
    }
}

/// Deserialize GovernanceUpdateAction from bytes
public(package) fun governance_update_action_from_bytes(bytes: vector<u8>): GovernanceUpdateAction {
    let mut bcs = bcs::new(bytes);
    GovernanceUpdateAction {
        max_outcomes: bcs.peel_option_u64(),
        max_actions_per_outcome: bcs.peel_option_u64(),
        proposal_intent_expiry_ms: bcs.peel_option_u64(),
        proposal_creation_fee: bcs.peel_option_u64(),
        proposal_fee_per_outcome: bcs.peel_option_u64(),
        fee_in_asset_token: bcs.peel_option_bool(),
    }
}

/// Deserialize MetadataTableUpdateAction from bytes
public(package) fun metadata_table_update_action_from_bytes(
    bytes: vector<u8>,
): MetadataTableUpdateAction {
    let mut bcs = bcs::new(bytes);
    let keys = {
        let len = bcs.peel_vec_length();
        let mut result = vector[];
        let mut i = 0;
        while (i < len) {
            result.push_back(string::utf8(bcs.peel_vec_u8()));
            i = i + 1;
        };
        result
    };
    let values = {
        let len = bcs.peel_vec_length();
        let mut result = vector[];
        let mut i = 0;
        while (i < len) {
            result.push_back(string::utf8(bcs.peel_vec_u8()));
            i = i + 1;
        };
        result
    };
    let keys_to_remove = {
        let len = bcs.peel_vec_length();
        let mut result = vector[];
        let mut i = 0;
        while (i < len) {
            result.push_back(string::utf8(bcs.peel_vec_u8()));
            i = i + 1;
        };
        result
    };
    assert!(keys.length() == values.length(), EMismatchedKeyValueLength);
    MetadataTableUpdateAction { keys, values, keys_to_remove }
}

/// Deserialize SponsorshipConfigUpdateAction from bytes
public(package) fun sponsorship_config_update_action_from_bytes(
    bytes: vector<u8>,
): SponsorshipConfigUpdateAction {
    let mut bcs = bcs::new(bytes);
    SponsorshipConfigUpdateAction {
        enabled: bcs.peel_option_bool(),
    }
}

// === Test-Only Marker Constructors ===

#[test_only]
public fun governance_update_marker_for_testing(): GovernanceUpdate { GovernanceUpdate {} }
