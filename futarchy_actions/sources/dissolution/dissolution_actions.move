// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// DAO Dissolution and Redemption System
///
/// Enables terminated DAOs to distribute assets proportionally to token holders
/// via a RedemptionPool pattern.
///
/// Flow (two transactions required due to shared object timing):
/// Pattern A (multi-tx): permissionless capability creation
///   1. Proposal terminates DAO (sets dissolution params in config)
///   2. Anyone calls create_capability_if_terminated<AssetType>() → shares DissolutionCapability
///   3. A later governance execution can create a RedemptionPool using the shared capability
///
/// Pattern B (single-PTB): terminate + liquidate + create pool
///   1. Proposal executes:
///      - terminate_dao
///      - do_create_dissolution_capability_unshared<AssetType>() → returns an owned capability
///      - VaultSpend / RemoveLiquidityToResources / burns, etc → coins flow through executable_resources
///      - do_create_redemption_pool_from_unshared_capability<RedeemCoinType>(..., &mut capability, ...) → creates RedemptionPool
///      - do_share_dissolution_capability(..., capability) → shares capability last
///
/// Claims:
///   - After unlock time, users claim directly from pool (pro-rata)
///
/// NOTE:
/// - On Sui, a newly-shared object cannot be referenced later in the same PTB.
///   If you need to mutate the capability in the same action batch (e.g. record RedemptionPoolIdKey),
///   keep it owned and share it at the end.
///
/// Safety:
/// - Pool is immutable once created (only balance changes)
/// - Time-locked to allow auctions/settlements
/// - Pro-rata calculation prevents draining
/// - Each claim is atomic and proportional
/// - Asset tokens are burned on claim
/// - AssetType validated to prevent type confusion attacks

module futarchy_actions::dissolution_actions;

public struct ExecutionProgressWitness has drop {}

use account_actions::currency;
use account_protocol::account::{Self, Account};
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use std::option::{Self, Option};
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::bcs;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event;
use sui::object::{Self, ID, UID};
use sui::transfer;

// === Errors ===

const ENotTerminated: u64 = 0;
const EWrongAccount: u64 = 1;
const ECapabilityAlreadyExists: u64 = 3;
const EZeroSupply: u64 = 5;
const EWrongAssetType: u64 = 6;
const ERedemptionTooSmall: u64 = 7;
const EWrongPool: u64 = 8;
const EPoolNotUnlocked: u64 = 10;
const EUnsupportedActionVersion: u64 = 11;
const EPoolExhausted: u64 = 12;
const EInsufficientRemainingSupply: u64 = 13;
const ERedemptionPoolAlreadyCreated: u64 = 14;
const ERedemptionPoolNotCreated: u64 = 15;
const EEmptyResourceNames: u64 = 16;
const ESupplyIncreasedDuringDissolution: u64 = 17;
const EWrongCapability: u64 = 18;
const EClaimsAlreadyStarted: u64 = 19;
const EZeroRedemptionPool: u64 = 20;
const EEmptyResourceName: u64 = 21;
const EDuplicateResourceName: u64 = 22;

// Dynamic-field key stored on the capability to enforce a single redemption pool.
public struct RedemptionPoolIdKey has copy, drop, store {}

// === Action Type Markers ===
// AssetType is encoded in the marker to prevent executor from changing the asset type

/// Create dissolution capability
/// AssetType is encoded to ensure executor uses the correct asset type
public struct CreateDissolutionCapability<phantom AssetType> has drop {}

/// Create a dissolution capability but do NOT share it.
///
/// This is intended for a single-PTB termination + liquidation flow where the
/// capability must be mutated (e.g. record RedemptionPoolIdKey) before being
/// shared at the end of the action batch.
public struct CreateDissolutionCapabilityUnshared<phantom AssetType> has drop {}

/// Share a newly-created (unshared) DissolutionCapability.
///
/// This exists to make "create capability → create pool → share capability" possible
/// in one proposal execution without relying on extra PTB calls outside the action list.
public struct ShareDissolutionCapability has drop {}

/// Hot-potato returned by do_create_dissolution_capability_unshared.
///
/// This is intentionally NOT droppable: the only intended way to consume it is
/// via do_share_dissolution_capability in the same PTB.
public struct UnsharedDissolutionCapabilityTicket {
    capability_id: ID,
}

/// Create redemption pool action marker
/// RedeemCoinType is encoded to prevent executor from changing coin type
public struct CreateRedemptionPool<phantom RedeemCoinType> has drop {}

/// Add coins to existing redemption pool
public struct AddToRedemptionPool<phantom RedeemCoinType> has drop {}

public(package) fun create_dissolution_capability_marker<AssetType>(): CreateDissolutionCapability<AssetType> {
    CreateDissolutionCapability {}
}

public(package) fun create_dissolution_capability_unshared_marker<AssetType>(): CreateDissolutionCapabilityUnshared<AssetType> {
    CreateDissolutionCapabilityUnshared {}
}

public(package) fun share_dissolution_capability_marker(): ShareDissolutionCapability {
    ShareDissolutionCapability {}
}

public(package) fun create_redemption_pool_marker<RedeemCoinType>(): CreateRedemptionPool<RedeemCoinType> {
    CreateRedemptionPool {}
}

public(package) fun add_to_redemption_pool_marker<RedeemCoinType>(): AddToRedemptionPool<RedeemCoinType> {
    AddToRedemptionPool {}
}

// === Structs ===

/// Shared capability proving a DAO is dissolved and ready for redemption
/// Created via governance proposal, becomes active after time delay
public struct DissolutionCapability has key {
    id: UID,
    /// Address of the dissolved DAO Account
    dao_address: address,
    /// When the capability was created (for audit trail)
    created_at_ms: u64,
    /// When redemption becomes available (time-locked)
    unlock_at_ms: u64,
    /// Total asset supply captured when the DAO was terminated.
    total_asset_supply: u64,
}

/// Shared pool holding funds for redemption
/// Created during dissolution, users claim directly from this
public struct RedemptionPool<phantom RedeemCoinType> has key {
    id: UID,
    /// Address of the dissolved DAO Account (for verification)
    dao_address: address,
    /// Reference to the DissolutionCapability (for pro-rata calculation)
    capability_id: ID,
    /// Total asset supply at DAO termination (copied from capability)
    total_asset_supply: u64,
    /// Remaining asset supply (decremented as users claim)
    /// Used as denominator in pro-rata calculation to ensure fair distribution
    remaining_asset_supply: u64,
    /// When redemption becomes available
    unlock_at_ms: u64,
    /// The coin type this pool holds
    coin_type: TypeName,
    /// Balance available for redemption
    balance: Balance<RedeemCoinType>,
}

// === Events ===

/// Emitted when a dissolution capability is created
public struct DissolutionCapabilityCreated has copy, drop {
    capability_id: ID,
    dao_address: address,
    created_at_ms: u64,
    unlock_at_ms: u64,
    total_asset_supply: u64,
}

/// Emitted when a redemption pool is created
public struct RedemptionPoolCreated has copy, drop {
    pool_id: ID,
    capability_id: ID,
    dao_address: address,
    coin_type: TypeName,
    initial_balance: u64,
}

/// Emitted when a dissolution capability is shared (becomes publicly accessible)
public struct DissolutionCapabilityShared has copy, drop {
    capability_id: ID,
    dao_address: address,
}

/// Emitted when coins are added to a redemption pool
public struct RedemptionPoolFunded has copy, drop {
    pool_id: ID,
    coin_type: TypeName,
    amount_added: u64,
    new_balance: u64,
}

/// Emitted when a user redeems tokens
public struct Redemption has copy, drop {
    pool_id: ID,
    user: address,
    asset_amount_burned: u64,
    coin_type_redeemed: String,
    coin_amount_received: u64,
}

// === Public Functions ===

fun assert_configured_asset_type<AssetType>(account: &Account) {
    let config = account::config<FutarchyConfig>(account);
    let expected_asset_type = futarchy_config::asset_type(config);
    let actual_asset_type = type_name::with_original_ids<AssetType>().into_string().to_string();
    assert!(expected_asset_type == &actual_asset_type, EWrongAssetType);
}

/// Internal helper: creates an unshared DissolutionCapability after termination.
/// Caller is responsible for sharing/transferring the returned object.
/// Aborts if the one-time creation flag was already consumed.
fun create_capability_unshared_internal<AssetType>(
    account: &mut Account,
    registry: &PackageRegistry,
    ctx: &mut TxContext,
): DissolutionCapability {
    // Preserve this module's external abort semantics while using the narrowed
    // config mutator in futarchy_core.
    {
        let config_view = account::config<FutarchyConfig>(account);
        let dao_state = futarchy_config::dao_state(config_view);
        assert!(
            futarchy_config::operational_state(dao_state) == futarchy_config::state_terminated(),
            ENotTerminated,
        );
        assert!(
            !futarchy_config::dissolution_capability_created(dao_state),
            ECapabilityAlreadyExists,
        );
        let unlock_time_option = futarchy_config::dissolution_unlock_time(dao_state);
        assert!(unlock_time_option.is_some(), ENotTerminated);
    };

    // Extract all data we need and consume the one-time creation flag.
    let (unlock_at_ms, terminated_at_ms, total_asset_supply) =
        futarchy_config::consume_dissolution_capability_creation_from_account(
            account,
            registry,
            ExecutionProgressWitness {},
        );

    create_capability_validated<AssetType>(
        account,
        unlock_at_ms,
        terminated_at_ms,
        total_asset_supply,
        ctx,
    )
}

fun create_capability_from_terminated_config<AssetType>(
    account: &Account,
    ctx: &mut TxContext,
): DissolutionCapability {
    let config = account::config<FutarchyConfig>(account);
    let dao_state = futarchy_config::dao_state(config);
    assert!(
        futarchy_config::operational_state(dao_state) == futarchy_config::state_terminated(),
        ENotTerminated,
    );
    let unlock_time_option = futarchy_config::dissolution_unlock_time(dao_state);
    assert!(unlock_time_option.is_some(), ENotTerminated);
    let total_asset_supply_option = futarchy_config::dissolution_total_asset_supply(dao_state);
    assert!(total_asset_supply_option.is_some(), ENotTerminated);

    create_capability_validated<AssetType>(
        account,
        *unlock_time_option.borrow(),
        *futarchy_config::terminated_at(dao_state).borrow(),
        *total_asset_supply_option.borrow(),
        ctx,
    )
}

/// Shared tail for capability creation: validates AssetType and uses the supply captured at termination.
fun create_capability_validated<AssetType>(
    account: &Account,
    unlock_at_ms: u64,
    terminated_at_ms: u64,
    total_supply: u64,
    ctx: &mut TxContext,
): DissolutionCapability {
    assert_configured_asset_type<AssetType>(account);
    assert!(total_supply > 0, EZeroSupply);

    // Create capability with parameters from DAO config
    let capability = DissolutionCapability {
        id: object::new(ctx),
        dao_address: account.addr(),
        created_at_ms: terminated_at_ms, // Use termination time, not creation time
        unlock_at_ms,
        total_asset_supply: total_supply,
    };

    let capability_id = object::id(&capability);

    // Emit creation event
    event::emit(DissolutionCapabilityCreated {
        capability_id,
        dao_address: account.addr(),
        created_at_ms: terminated_at_ms,
        unlock_at_ms,
        total_asset_supply: total_supply,
    });

    capability
}

/// Permissionless creation of dissolution capability
/// Anyone can call this after DAO is terminated
/// Reads dissolution parameters from DAO config (set during termination)
///
/// SAFETY:
/// - Only works on terminated DAOs
/// - Validates AssetType matches DAO's configured asset
/// - Parameters come from DAO governance decision (can't be manipulated)
/// - Creates immutable capability with time lock
/// - Can only be called once (prevents multiple capability creation)
public fun create_capability_if_terminated<AssetType>(
    account: &mut Account,
    registry: &PackageRegistry,
    ctx: &mut TxContext,
) {
    let capability = create_capability_unshared_internal<AssetType>(account, registry, ctx);
    // Share the capability so anyone can use it for redemption
    transfer::share_object(capability);
}

/// Get capability info for display/verification
public fun capability_info(cap: &DissolutionCapability): (address, u64, u64, u64) {
    (cap.dao_address, cap.created_at_ms, cap.unlock_at_ms, cap.total_asset_supply)
}

/// Check if capability is unlocked and ready for redemption
public fun is_unlocked(cap: &DissolutionCapability, clock: &Clock): bool {
    clock.timestamp_ms() >= cap.unlock_at_ms
}

/// Get pool info for display
/// Returns: (dao_address, capability_id, total_asset_supply, remaining_asset_supply, balance)
public fun pool_info<RedeemCoinType>(
    pool: &RedemptionPool<RedeemCoinType>,
): (address, ID, u64, u64, u64) {
    (pool.dao_address, pool.capability_id, pool.total_asset_supply, pool.remaining_asset_supply, pool.balance.value())
}

/// Check if pool is unlocked
public fun pool_is_unlocked<RedeemCoinType>(
    pool: &RedemptionPool<RedeemCoinType>,
    clock: &Clock,
): bool {
    clock.timestamp_ms() >= pool.unlock_at_ms
}

/// Get pool balance
public fun pool_balance<RedeemCoinType>(pool: &RedemptionPool<RedeemCoinType>): u64 {
    pool.balance.value()
}

/// Claim pro-rata share from redemption pool
/// Burns asset tokens and returns proportional coins from pool
///
/// PERMISSIONLESS: Anyone holding asset tokens can claim after unlock
///
/// Safety:
/// - Pool must be unlocked (time check)
/// - Burns asset tokens BEFORE withdrawal (prevents double-claim)
/// - Pro-rata calculation is exact
/// - Account reference only needed for burn (already permissionless)
/// - AssetType validated against DAO config (prevents type confusion)
public fun claim<AssetType, RedeemCoinType>(
    pool: &mut RedemptionPool<RedeemCoinType>,
    account: &mut Account,
    registry: &PackageRegistry,
    asset_coins: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RedeemCoinType> {
    // 1. Verify pool matches this DAO account
    assert!(pool.dao_address == account.addr(), EWrongPool);

    // 2. Verify pool is unlocked
    assert!(clock.timestamp_ms() >= pool.unlock_at_ms, EPoolNotUnlocked);

    // 3. CRITICAL: Validate AssetType matches DAO's configured asset type
    // This prevents type confusion attacks where attacker burns wrong token type
    let config = account::config<FutarchyConfig>(account);
    let expected_asset_type = futarchy_config::asset_type(config);
    let actual_asset_type = type_name::with_original_ids<AssetType>().into_string().to_string();
    assert!(expected_asset_type == &actual_asset_type, EWrongAssetType);

    // 4. Sync remaining_asset_supply with actual circulating supply
    // This accounts for tokens burned externally via public_burn
    // M29 fix: reject supply increases to prevent pool drain via post-dissolution minting
    let current_supply = currency::coin_type_supply<AssetType>(account, registry);
    assert!(current_supply <= pool.remaining_asset_supply, ESupplyIncreasedDuringDissolution);
    if (current_supply < pool.remaining_asset_supply) {
        pool.remaining_asset_supply = current_supply;
    };

    // 5. Verify pool has remaining supply (prevents division by zero)
    assert!(pool.remaining_asset_supply > 0, EPoolExhausted);

    // 6. Get asset amount and validate bounds
    let asset_amount = asset_coins.value();
    assert!(asset_amount <= pool.remaining_asset_supply, EInsufficientRemainingSupply);

    // 7. Calculate pro-rata share using REMAINING supply as denominator
    // This ensures each token has equal value regardless of claim order
    let pool_balance = pool.balance.value();

    // Use u128 to prevent overflow
    let share_numerator = (asset_amount as u128);
    // Formula: pool_balance * tokens_burned / remaining_supply
    // This guarantees each token redeems for equal value
    // NOTE: Integer division truncates, so small rounding losses accumulate in the pool.
    // The final claimant may receive slightly more or less than exact pro-rata share
    // due to accumulated rounding. This is standard DeFi behavior.
    let share_denominator = (pool.remaining_asset_supply as u128);
    let pool_balance_u128 = (pool_balance as u128);

    let redeem_amount = (pool_balance_u128 * share_numerator / share_denominator) as u64;

    // Prevent zero-value redemptions
    assert!(redeem_amount > 0, ERedemptionTooSmall);

    // 8. Burn asset tokens FIRST (permissionless via public_burn)
    currency::public_burn<AssetType>(account, registry, asset_coins);

    // 9. Decrement remaining supply to track burned tokens
    pool.remaining_asset_supply = pool.remaining_asset_supply - asset_amount;

    // 10. Take from pool
    let redeemed_coin = coin::take(&mut pool.balance, redeem_amount, ctx);

    // 11. Emit event
    event::emit(Redemption {
        pool_id: object::id(pool),
        user: ctx.sender(),
        asset_amount_burned: asset_amount,
        coin_type_redeemed: type_name::with_original_ids<RedeemCoinType>()
            .into_string()
            .to_string(),
        coin_amount_received: redeem_amount,
    });

    redeemed_coin
}

// === Action Structs for Proposal System ===

/// Action data for creating a dissolution capability
/// Note: This is typically called permissionlessly AFTER termination,
/// but can also be included in the termination proposal itself
public struct CreateDissolutionCapabilityAction<phantom AssetType> has copy, drop, store {
    // Empty - all parameters come from DAO config set during termination
}

/// Action data for creating an owned dissolution capability for same-PTB setup.
public struct CreateDissolutionCapabilityUnsharedAction<phantom AssetType> has copy, drop, store {
    // Empty - all parameters come from DAO config set during termination
}

/// Action data for sharing an owned dissolution capability.
public struct ShareDissolutionCapabilityAction has copy, drop, store {
    // Empty - the capability object is passed between PTB calls
}

/// Action data for creating a redemption pool
/// Coins come from executable_resources (put there by prior VaultSpend or RemoveLiquidity actions)
/// Supports multiple resource names to merge stable from different sources
public struct CreateRedemptionPoolAction has copy, drop, store {
    /// Expected DissolutionCapability ID.
    /// None is only valid for same-PTB flows that pass UnsharedDissolutionCapabilityTicket.
    capability_id: Option<address>,
    /// Names of resources in executable_resources to take coins from (merged into one pool)
    resource_names: vector<String>,
}

/// Action data for adding to existing redemption pool
public struct AddToRedemptionPoolAction has copy, drop, store {
    /// Name of the resource in executable_resources
    resource_name: String,
    /// ID of the redemption pool (validated at execution to prevent substitution)
    pool_id: address,
}

// === Action Constructors ===

/// Create action for proposal system
public fun new_create_dissolution_capability<AssetType>(): CreateDissolutionCapabilityAction<
    AssetType,
> {
    CreateDissolutionCapabilityAction {}
}

/// Create action for same-PTB unshared capability creation.
public fun new_create_dissolution_capability_unshared<AssetType>(): CreateDissolutionCapabilityUnsharedAction<
    AssetType,
> {
    CreateDissolutionCapabilityUnsharedAction {}
}

/// Create action for sharing an unshared dissolution capability.
public fun new_share_dissolution_capability(): ShareDissolutionCapabilityAction {
    ShareDissolutionCapabilityAction {}
}

/// Create action for creating redemption pool from multiple stable sources
public fun new_create_redemption_pool(
    capability_id: ID,
    resource_names: vector<String>,
): CreateRedemptionPoolAction {
    CreateRedemptionPoolAction {
        capability_id: option::some(capability_id.to_address()),
        resource_names,
    }
}

/// Create action for a same-PTB unshared capability whose ID is not known at staging time.
public fun new_create_redemption_pool_from_unshared_capability(
    resource_names: vector<String>,
): CreateRedemptionPoolAction {
    CreateRedemptionPoolAction {
        capability_id: option::none(),
        resource_names,
    }
}

/// Create action for adding to redemption pool
public fun new_add_to_redemption_pool(resource_name: String, pool_id: ID): AddToRedemptionPoolAction {
    AddToRedemptionPoolAction {
        resource_name,
        pool_id: pool_id.to_address(),
    }
}

// === Execution Functions (for Proposal System) ===

/// Execute create dissolution capability action from proposal.
/// This variant shares the capability immediately. If the same action batch must also
/// create a redemption pool, use do_create_dissolution_capability_unshared +
/// do_create_redemption_pool + do_share_dissolution_capability instead.
public fun do_create_dissolution_capability<AssetType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _witness: IW,
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
    account_protocol::action_validation::assert_action_type<CreateDissolutionCapability<AssetType>>(action_spec);
    // AssetType encoded in marker to prevent type substitution


    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let reader = bcs::new(*action_data);

    // No fields to deserialize - empty action
    bcs_validation::validate_all_bytes_consumed(reader);

    assert_configured_asset_type<AssetType>(account);

    // Idempotent: skip if capability was already created (e.g. via permissionless call).
    // This prevents a front-running DoS where someone calls create_capability_if_terminated
    // directly between TerminateDAO and this action, permanently bricking the proposal.
    let config_view = account::config<FutarchyConfig>(account);
    let dao_state = futarchy_config::dao_state(config_view);
    if (!futarchy_config::dissolution_capability_created(dao_state)) {
        create_capability_if_terminated<AssetType>(
            account,
            registry,
            ctx,
        );
    };

    executable::increment_action_idx<_, CreateDissolutionCapability<AssetType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute create dissolution capability action from proposal but return the capability unshared.
///
/// This is useful for single-PTB flows where subsequent actions need a mutable
/// reference to the capability before it becomes shared.
public fun do_create_dissolution_capability_unshared<AssetType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _witness: IW,
    ctx: &mut TxContext,
): (DissolutionCapability, UnsharedDissolutionCapabilityTicket) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<CreateDissolutionCapabilityUnshared<AssetType>>(action_spec);
    // AssetType encoded in marker to prevent type substitution


    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let reader = bcs::new(*action_data);

    // No fields to deserialize - empty action
    bcs_validation::validate_all_bytes_consumed(reader);

    let config_view = account::config<FutarchyConfig>(account);
    let dao_state = futarchy_config::dao_state(config_view);
    let capability = if (!futarchy_config::dissolution_capability_created(dao_state)) {
        create_capability_unshared_internal<AssetType>(account, registry, ctx)
    } else {
        create_capability_from_terminated_config<AssetType>(account, ctx)
    };

    let ticket = UnsharedDissolutionCapabilityTicket {
        capability_id: object::id(&capability),
    };

    executable::increment_action_idx<_, CreateDissolutionCapabilityUnshared<AssetType>, _>(executable, registry, ExecutionProgressWitness {});

    (capability, ticket)
}

/// Share a newly-created unshared DissolutionCapability (consumes it).
public fun do_share_dissolution_capability<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &Account,
    registry: &PackageRegistry,
    capability: DissolutionCapability,
    ticket: UnsharedDissolutionCapabilityTicket,
    _witness: IW,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<ShareDissolutionCapability>(action_spec);

    // Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let reader = bcs::new(*action_data);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Defense-in-depth: ensure capability is for this DAO.
    assert!(capability.dao_address == account.addr(), EWrongAccount);

    // In the single-PTB flow, the capability MUST have been used to create a RedemptionPool
    // (which records the pool id on the capability) before it can be shared.
    assert!(
        df::exists_(&capability.id, RedemptionPoolIdKey {}),
        ERedemptionPoolNotCreated,
    );

    // Consume the hot potato and validate it matches this capability.
    let UnsharedDissolutionCapabilityTicket { capability_id } = ticket;
    assert!(capability_id == object::id(&capability), EWrongCapability);

    event::emit(DissolutionCapabilityShared {
        capability_id,
        dao_address: capability.dao_address,
    });

    transfer::share_object(capability);

    executable::increment_action_idx<_, ShareDissolutionCapability, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute create redemption pool action from proposal
/// Takes coins from multiple executable_resources and merges them into one pool
/// Sources can include VaultSpend outputs, RemoveLiquidityToResources stable output, etc.
public fun do_create_redemption_pool<RedeemCoinType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    capability: &mut DissolutionCapability,
    _witness: IW,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    let action = read_create_redemption_pool_action<RedeemCoinType, Outcome>(executable);
    assert!(action.capability_id.is_some(), EWrongCapability);
    let expected_capability_id = object::id_from_address(*action.capability_id.borrow());
    assert!(object::id(capability) == expected_capability_id, EWrongCapability);
    let CreateRedemptionPoolAction { capability_id: _, resource_names } = action;

    create_redemption_pool_inner<RedeemCoinType, Outcome>(
        executable,
        account,
        registry,
        capability,
        resource_names,
        ctx,
    );
}

/// Execute create redemption pool when the capability was created earlier in the
/// same PTB and therefore had no known ID at staging time.
public fun do_create_redemption_pool_from_unshared_capability<
    RedeemCoinType,
    Outcome: store,
    IW: drop,
>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    capability: &mut DissolutionCapability,
    ticket: &UnsharedDissolutionCapabilityTicket,
    _witness: IW,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    let action = read_create_redemption_pool_action<RedeemCoinType, Outcome>(executable);
    assert!(action.capability_id.is_none(), EWrongCapability);
    assert!(ticket.capability_id == object::id(capability), EWrongCapability);
    let CreateRedemptionPoolAction { capability_id: _, resource_names } = action;

    create_redemption_pool_inner<RedeemCoinType, Outcome>(
        executable,
        account,
        registry,
        capability,
        resource_names,
        ctx,
    );
}

fun read_create_redemption_pool_action<RedeemCoinType, Outcome: store>(
    executable: &Executable<Outcome>,
): CreateRedemptionPoolAction {
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<CreateRedemptionPool<RedeemCoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let capability_id = bcs::peel_option!(&mut reader, |r| bcs::peel_address(r));
    let resource_names_count = bcs::peel_vec_length(&mut reader);
    let mut resource_names = vector[];
    let mut i = 0;
    while (i < resource_names_count) {
        resource_names.push_back(std::string::utf8(bcs::peel_vec_u8(&mut reader)));
        i = i + 1;
    };
    bcs_validation::validate_all_bytes_consumed(reader);

    CreateRedemptionPoolAction { capability_id, resource_names }
}

fun validate_redemption_resource_names(resource_names: &vector<String>) {
    assert!(resource_names.length() > 0, EEmptyResourceNames);
    let mut i = 0;
    while (i < resource_names.length()) {
        assert!(resource_names[i].length() > 0, EEmptyResourceName);
        let mut j = i + 1;
        while (j < resource_names.length()) {
            assert!(resource_names[i] != resource_names[j], EDuplicateResourceName);
            j = j + 1;
        };
        i = i + 1;
    };
}

fun create_redemption_pool_inner<RedeemCoinType, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    capability: &mut DissolutionCapability,
    resource_names: vector<String>,
    ctx: &mut TxContext,
) {
    validate_redemption_resource_names(&resource_names);

    // Verify capability matches account
    assert!(capability.dao_address == account.addr(), EWrongAccount);

    // Per-capability check first so we fail fast before touching resources or the
    // DAO-level single-pool flag.
    assert!(
        !df::exists_(&capability.id, RedemptionPoolIdKey {}),
        ERedemptionPoolAlreadyCreated,
    );

    // Take and merge coins from all resource names
    let mut total_coins = coin::zero<RedeemCoinType>(ctx);
    let mut i = 0;
    while (i < resource_names.length()) {
        let c = executable_resources::take_coin(
            executable,
            registry,
            ExecutionProgressWitness {},
            resource_names[i],
        );
        coin::join(&mut total_coins, c);
        i = i + 1;
    };

    let initial_balance = total_coins.value();

    // Reject zero-balance pools before consuming the DAO's single-pool flag.
    // A zero-balance pool would abort every `claim` with ERedemptionTooSmall
    // (redeem_amount floors to 0), permanently bricking redemptions while
    // still burning the one-pool-per-DAO allowance.
    assert!(initial_balance > 0, EZeroRedemptionPool);

    // DAO-level single-pool invariant: only one redemption pool per DAO, regardless
    // of how many DissolutionCapability objects exist (prevents fallback-path bypass).
    // This check + set is atomic via consume_redemption_pool_creation.
    futarchy_config::consume_redemption_pool_creation_from_execution(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    // Create pool
    let pool = RedemptionPool<RedeemCoinType> {
        id: object::new(ctx),
        dao_address: capability.dao_address,
        capability_id: object::id(capability),
        total_asset_supply: capability.total_asset_supply,
        remaining_asset_supply: capability.total_asset_supply, // Initially equals total
        unlock_at_ms: capability.unlock_at_ms,
        coin_type: type_name::with_original_ids<RedeemCoinType>(),
        balance: total_coins.into_balance(),
    };

    let pool_id = object::id(&pool);

    // Record pool id on the capability to prevent multiple pools for the same dissolution.
    df::add(&mut capability.id, RedemptionPoolIdKey {}, pool_id);

    event::emit(RedemptionPoolCreated {
        pool_id,
        capability_id: object::id(capability),
        dao_address: capability.dao_address,
        coin_type: type_name::with_original_ids<RedeemCoinType>(),
        initial_balance,
    });

    transfer::share_object(pool);

    executable::increment_action_idx<_, CreateRedemptionPool<RedeemCoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute add to redemption pool action
/// Takes coins from executable_resources and adds to existing pool
public fun do_add_to_redemption_pool<RedeemCoinType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &Account,
    registry: &PackageRegistry,
    pool: &mut RedemptionPool<RedeemCoinType>,
    _witness: IW,
    _ctx: &mut TxContext,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<AddToRedemptionPool<RedeemCoinType>>(action_spec);

    // Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize action
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let staged_pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify pool matches staged ID and account
    assert!(object::id(pool) == staged_pool_id, EWrongPool);
    assert!(pool.dao_address == account.addr(), EWrongPool);

    // Prevent funding exhausted pools (funds would be stuck forever)
    assert!(pool.remaining_asset_supply > 0, EPoolExhausted);

    // Defense-in-depth: prevent funding after claims have started.
    // If remaining_asset_supply < total_asset_supply, tokens have been burned via claim(),
    // and late funding would break pro-rata fairness (early claimants miss later funds).
    // In the standard futarchy governance path this is unreachable (begin_execution blocks
    // post-termination), but this guard protects against alternative execution paths.
    assert!(pool.remaining_asset_supply == pool.total_asset_supply, EClaimsAlreadyStarted);

    // Take coins from executable_resources
    let coins = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    let amount_added = coins.value();
    pool.balance.join(coins.into_balance());

    event::emit(RedemptionPoolFunded {
        pool_id: object::id(pool),
        coin_type: type_name::with_original_ids<RedeemCoinType>(),
        amount_added,
        new_balance: pool.balance.value(),
    });

    executable::increment_action_idx<_, AddToRedemptionPool<RedeemCoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

// === Test-only Helpers ===

#[test_only]
/// Create a DissolutionCapability for testing
/// In production, this is created via do_create_dissolution_capability action
public fun create_capability_for_testing(
    dao_address: address,
    total_asset_supply: u64,
    unlock_at_ms: u64,
    ctx: &mut TxContext,
): DissolutionCapability {
    DissolutionCapability {
        id: object::new(ctx),
        dao_address,
        created_at_ms: 0, // Test value
        total_asset_supply,
        unlock_at_ms,
    }
}

#[test_only]
/// Remove the dynamic-field marker used to enforce single-pool creation (test cleanup helper).
public fun clear_redemption_pool_id_for_testing(capability: &mut DissolutionCapability) {
    if (df::exists_(&capability.id, RedemptionPoolIdKey {})) {
        let _pool_id: ID = df::remove(&mut capability.id, RedemptionPoolIdKey {});
    };
}

#[test_only]
/// Create and SHARE a RedemptionPool for testing
/// In production, this is created via do_create_redemption_pool action
/// Returns the pool ID for reference
public fun create_and_share_redemption_pool_for_testing<CoinType>(
    capability: &mut DissolutionCapability,
    coins: Coin<CoinType>,
    ctx: &mut TxContext,
): ID {
    assert!(
        !df::exists_(&capability.id, RedemptionPoolIdKey {}),
        ERedemptionPoolAlreadyCreated,
    );
    let pool = RedemptionPool<CoinType> {
        id: object::new(ctx),
        dao_address: capability.dao_address,
        capability_id: object::id(capability),
        total_asset_supply: capability.total_asset_supply,
        remaining_asset_supply: capability.total_asset_supply,
        unlock_at_ms: capability.unlock_at_ms,
        coin_type: type_name::with_original_ids<CoinType>(),
        balance: coins.into_balance(),
    };
    let pool_id = object::id(&pool);
    df::add(&mut capability.id, RedemptionPoolIdKey {}, pool_id);
    transfer::share_object(pool);
    pool_id
}

#[test_only]
/// Create a RedemptionPool for testing (returns unshared for inspection)
/// Use create_and_share_redemption_pool_for_testing if you need to share it
public fun create_redemption_pool_for_testing<CoinType>(
    capability: &mut DissolutionCapability,
    coins: Coin<CoinType>,
    ctx: &mut TxContext,
): RedemptionPool<CoinType> {
    assert!(
        !df::exists_(&capability.id, RedemptionPoolIdKey {}),
        ERedemptionPoolAlreadyCreated,
    );
    let pool = RedemptionPool<CoinType> {
        id: object::new(ctx),
        dao_address: capability.dao_address,
        capability_id: object::id(capability),
        total_asset_supply: capability.total_asset_supply,
        remaining_asset_supply: capability.total_asset_supply,
        unlock_at_ms: capability.unlock_at_ms,
        coin_type: type_name::with_original_ids<CoinType>(),
        balance: coins.into_balance(),
    };
    let pool_id = object::id(&pool);
    df::add(&mut capability.id, RedemptionPoolIdKey {}, pool_id);
    pool
}
