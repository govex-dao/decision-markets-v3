// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Oracle Actions - Price-Based Unlocks
///
/// Clean price-based grant system with:
/// - N tiers with N recipients each
/// - Time bounds (earliest + latest execution)
/// - Price conditions per tier
/// - Launchpad enforcement (global minimum)
/// - Cancelable or immutable grants
/// - Emergency freeze control
///
module futarchy_oracle::oracle_actions;

public struct ExecutionProgressWitness has drop {}

use account_actions::currency::{Self, CurrencyMintAdminCap};
use futarchy_oracle::oracle_version;
use account_protocol::account::Account;
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::PCW_TWAP_oracle;
use futarchy_one_shot_utils::constants;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::event;

// === Action Type Markers ===
// Asset and stable types are encoded in the markers to prevent executor from changing pool types

/// Create oracle grant
/// Asset and stable types are encoded to ensure executor uses the correct types
public struct CreateOracleGrant<phantom AssetType, phantom StableType> has drop {}
/// Cancel oracle grant
/// Asset and stable types are encoded to ensure executor cancels the correct grant type
public struct CancelGrant<phantom AssetType, phantom StableType> has drop {}

public(package) fun create_oracle_grant_marker<AssetType, StableType>(): CreateOracleGrant<AssetType, StableType> {
    CreateOracleGrant {}
}

public(package) fun cancel_grant_marker<AssetType, StableType>(): CancelGrant<AssetType, StableType> {
    CancelGrant {}
}

// === Constants ===

// DAO states (enum-like local value)
const DAO_STATE_TERMINATED: u8 = 1;
// Scaled by 1e12 (constants::price_precision_scale). 1_000_000x cap.
const MAX_RELATIVE_MULTIPLIER: u64 = 1_000_000_000_000_000_000;

// === Errors ===

const ETooManyTiers: u64 = 34;
const EZeroAmount: u64 = 35;
const EIndexOutOfBounds: u64 = 36;
const EPriceConditionNotMet: u64 = 2;
const EPriceBelowLaunchpad: u64 = 3;
const ENotRecipient: u64 = 5;
const EAlreadyCanceled: u64 = 6;
const EInsufficientVested: u64 = 8;
const ETimeCalculationOverflow: u64 = 9;
const EDaoDissolving: u64 = 10;
const EGrantNotCancelable: u64 = 11;
const EExecutionTooEarly: u64 = 14;
const EGrantExpired: u64 = 15;
const EWrongAccount: u64 = 16;
const ERecipientAlreadyClaimed: u64 = 17;
const EEmptyTiers: u64 = 18;
const EDaoIdMismatch: u64 = 19;
const EUnsupportedActionVersion: u64 = 20;
const ETooManyRecipients: u64 = 21;
const EDuplicateRecipientInTier: u64 = 22;
const EInvalidPriceThreshold: u64 = 23;
const EDivisionByZero: u64 = 24;
const EInvalidExecutionWindow: u64 = 25;
const EWrongSpotPool: u64 = 26;
const EInvalidTwapWindow: u64 = 27;
const EOracleHistoryInsufficient: u64 = 28;
const EInvalidRelativeMultiplier: u64 = 29;
const EAssetTypeMismatch: u64 = 30; // AssetType doesn't match DAO config
const EStableTypeMismatch: u64 = 31; // StableType doesn't match DAO config
const EInvalidUtf8: u64 = 32;
const EMintCapAccountMismatch: u64 = 33;

// === Core Structs ===

/// Launchpad price enforcement (applies globally to all tiers in RELATIVE mode only)
public struct LaunchpadEnforcement has copy, drop, store {
    enabled: bool,
    minimum_multiplier: u64, // Scaled 1e12
    launchpad_price: u128, // Absolute price at grant creation (1e12 scale)
}

/// Price condition for a tier
public struct PriceCondition has copy, drop, store {
    threshold: u128, // Absolute price (scaled 1e12)
    is_above: bool, // true = unlock above, false = unlock below
}

/// Recipient allocation
public struct RecipientMint has copy, drop, store {
    recipient: address,
    amount: u64,
}

/// Price tier - one unlock condition with N recipients
/// Each recipient has their own executed flag (vector index matches recipients index)
public struct PriceTier has copy, drop, store {
    price_condition: Option<PriceCondition>,
    recipients: vector<RecipientMint>,
    /// Per-recipient execution tracking: executed[i] corresponds to recipients[i]
    executed: vector<bool>,
    description: String,
}

/// Price-based mint grant - simplified
public struct PriceBasedMintGrant<phantom AssetType, phantom StableType> has key {
    id: UID,
    // === TIER STRUCTURE ===
    tiers: vector<PriceTier>,
    total_amount: u64,
    use_relative_pricing: bool, // true = thresholds are multipliers, false = absolute prices
    // === LAUNCHPAD ENFORCEMENT (global) ===
    launchpad_enforcement: LaunchpadEnforcement,
    // === TIME BOUNDS ===
    earliest_execution: Option<u64>,
    latest_execution: Option<u64>,
    // === STATE ===
    cancelable: bool,
    canceled: bool,
    // === METADATA ===
    description: String,
    created_at: u64,
    dao_id: ID,
    mint_admin_cap: Option<CurrencyMintAdminCap<AssetType>>,
    // === ORACLE CONFIG ===
    twap_window_ms: u64, // 7-90 days, window for price condition TWAP
}

// === Storage Keys ===

public struct GrantStorageKey has copy, drop, store {}

public struct GrantStorage has store {
    grants: sui::table::Table<ID, GrantInfo>,
    grant_ids: vector<ID>,
    total_grants: u64,
}

public struct GrantInfo has copy, drop, store {
    recipient: address,
    cancelable: bool,
}

// === Events ===

public struct GrantCreated has copy, drop {
    grant_id: ID,
    total_amount: u64,
    tier_count: u64,
    timestamp: u64,
}

public struct TokensClaimed has copy, drop {
    grant_id: ID,
    tier_index: u64,
    recipient: address,
    amount_claimed: u64,
    timestamp: u64,
}

public struct GrantCanceled has copy, drop {
    grant_id: ID,
    timestamp: u64,
}

// === Helper Functions ===

/// Convert relative threshold to absolute price
public fun relative_to_absolute_threshold(
    launchpad_price_abs_1e12: u128,
    multiplier_1e12: u64,
): u128 {
    safe_mul_div(launchpad_price_abs_1e12, (multiplier_1e12 as u128), (constants::price_precision_scale() as u128))
}

/// Create absolute price condition
public fun absolute_price_condition(price: u128, is_above: bool): PriceCondition {
    PriceCondition {
        threshold: price,
        is_above,
    }
}

/// Create recipient mint
public fun new_recipient_mint(recipient: address, amount: u64): RecipientMint {
    RecipientMint { recipient, amount }
}

// === Constructor Functions ===

/// Create price-based grant with N tiers and N recipients per tier
///
/// SECURITY: Package-private to prevent external callers from creating unsolicited grants
/// on DAO accounts without going through governance (do_create_oracle_grant).
///
/// @param tiers: Vector of price tiers, each with price condition + recipients
/// @param use_relative_pricing: true = thresholds are multipliers of launchpad, false = absolute prices
/// @param launchpad_multiplier: Minimum price multiplier (0 = disabled, scaled 1e12)
///                              ONLY enforced when use_relative_pricing = true
/// @param earliest_execution_offset_ms: Minimum time before claiming (0 = immediate)
/// @param expiry_years: Maximum time to claim (0 = no expiry)
public(package) fun create_grant<AssetType, StableType>(
    account: &mut Account,
    registry: &PackageRegistry,
    tiers: vector<PriceTier>,
    use_relative_pricing: bool,
    launchpad_multiplier: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    cancelable: bool,
    description: String,
    dao_id: ID,
    mint_admin_cap: CurrencyMintAdminCap<AssetType>,
    twap_window_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validation
    assert!(vector::length(&tiers) > 0, EEmptyTiers);
    assert!(vector::length(&tiers) <= constants::max_oracle_tiers(), ETooManyTiers);
    // Validate dao_id matches the account to prevent grants referencing wrong DAO
    assert!(dao_id == object::id(account), EDaoIdMismatch);
    assert!(currency::mint_admin_cap_account_id(&mint_admin_cap) == dao_id, EMintCapAccountMismatch);
    // Validate TWAP window: 7 days minimum, 90 days maximum
    assert!(
        twap_window_ms >= constants::one_week_ms() && twap_window_ms <= constants::ninety_days_ms(),
        EInvalidTwapWindow,
    );

    let now = clock.timestamp_ms();

    // Calculate total amount across all tiers and validate recipient counts
    let mut total_amount = 0u64;
    let mut i = 0;
    let tier_count = vector::length(&tiers);
    while (i < tier_count) {
        let tier = vector::borrow(&tiers, i);
        if (use_relative_pricing && tier.price_condition.is_some()) {
            let threshold = tier.price_condition.borrow().threshold;
            assert!(
                threshold <= (MAX_RELATIVE_MULTIPLIER as u128),
                EInvalidPriceThreshold,
            );
        };
        let mut j = 0;
        let recipient_count = vector::length(&tier.recipients);
        // Validate recipient count to prevent gas exhaustion
        assert!(recipient_count <= constants::max_recipients_per_tier(), ETooManyRecipients);
        while (j < recipient_count) {
            let amount = vector::borrow(&tier.recipients, j).amount;
            // Addition overflow is caught by Move VM's built-in safety checks
            total_amount = total_amount + amount;
            j = j + 1;
        };
        i = i + 1;
    };

    assert!(total_amount > 0, EZeroAmount);

    // Oracle grants are launchpad-derived; require the canonical raise price
    // instead of creating grant objects with a meaningless zero snapshot.
    let dao_config = account_protocol::account::config(account);
    let launchpad_price_opt = futarchy_core::futarchy_config::get_launchpad_initial_price(
        dao_config,
    );
    assert!(launchpad_price_opt.is_some(), EPriceBelowLaunchpad);
    let launchpad_price = *launchpad_price_opt.borrow();
    assert!(launchpad_price > 0, EPriceBelowLaunchpad);
    if (use_relative_pricing) {
        assert!(launchpad_multiplier <= MAX_RELATIVE_MULTIPLIER, EInvalidRelativeMultiplier);

        // Prevent claim-time conversion overflow in relative pricing mode.
        let max_product =
            (std::u128::max_value!() as u256) * ((constants::price_precision_scale() as u128) as u256);
        let min_price_lhs = (launchpad_price as u256) * (launchpad_multiplier as u256);
        assert!(min_price_lhs <= max_product, EInvalidRelativeMultiplier);

        let mut t = 0;
        while (t < tier_count) {
            let tier = vector::borrow(&tiers, t);
            if (tier.price_condition.is_some()) {
                let condition = tier.price_condition.borrow();
                let threshold = condition.threshold;
                let threshold_lhs = (launchpad_price as u256) * (threshold as u256);
                assert!(threshold_lhs <= max_product, EInvalidPriceThreshold);
                // SECURITY: Reject relative downside tiers where threshold < launchpad_multiplier.
                // In relative mode with launchpad enforcement, claim requires BOTH:
                //   price <= threshold (downside condition) AND price >= floor (launchpad minimum).
                // When threshold < floor, no price can satisfy both → funds permanently locked.
                if (!condition.is_above && launchpad_multiplier > 0) {
                    assert!(
                        threshold >= (launchpad_multiplier as u128),
                        EInvalidPriceThreshold,
                    );
                };
            };
            t = t + 1;
        };
    };

    // Calculate time bounds
    let earliest_execution_opt = if (earliest_execution_offset_ms > 0) {
        assert!(earliest_execution_offset_ms <= constants::ten_years_ms(), ETimeCalculationOverflow);
        std::option::some(now + earliest_execution_offset_ms)
    } else {
        std::option::none()
    };

    let latest_execution_opt = if (expiry_years > 0) {
        // Use u128 for intermediate calculation to prevent overflow
        let expiry_ms_u128 = (expiry_years as u128) * 365 * 24 * 60 * 60 * 1000;
        // Cap at u64::MAX to prevent overflow when adding to `now`
        let expiry_ms = if (expiry_ms_u128 > (18_446_744_073_709_551_615u128 - (now as u128))) {
            18_446_744_073_709_551_615u64 - now // max safe value
        } else {
            (expiry_ms_u128 as u64)
        };
        std::option::some(now + expiry_ms)
    } else {
        std::option::none()
    };

    // Validate earliest < latest when both are set to prevent permanently unclaimable grants
    if (std::option::is_some(&earliest_execution_opt) && std::option::is_some(&latest_execution_opt)) {
        assert!(
            *std::option::borrow(&earliest_execution_opt) < *std::option::borrow(&latest_execution_opt),
            EInvalidExecutionWindow,
        );
    };

    let grant_id = object::new(ctx);
    let grant_id_inner = object::uid_to_inner(&grant_id);

    event::emit(GrantCreated {
        grant_id: grant_id_inner,
        total_amount,
        tier_count,
        timestamp: now,
    });

    let launchpad_enforcement_enabled = use_relative_pricing && launchpad_multiplier > 0;
    let effective_launchpad_multiplier = if (launchpad_enforcement_enabled) {
        launchpad_multiplier
    } else {
        0
    };
    let grant = PriceBasedMintGrant<AssetType, StableType> {
        id: grant_id,
        tiers,
        total_amount,
        use_relative_pricing,
        launchpad_enforcement: LaunchpadEnforcement {
            enabled: launchpad_enforcement_enabled,
            minimum_multiplier: effective_launchpad_multiplier,
            launchpad_price,
        },
        earliest_execution: earliest_execution_opt,
        latest_execution: latest_execution_opt,
        cancelable,
        canceled: false,
        description,
        created_at: now,
        dao_id,
        mint_admin_cap: option::some(mint_admin_cap),
        twap_window_ms,
    };

    // Share the grant
    transfer::share_object(grant);

    // Ensure grant storage exists and register grant
    ensure_grant_storage(account, registry, ctx);
    register_grant(account, registry, grant_id_inner, cancelable);

    grant_id_inner
}

// === View Functions ===

public fun total_amount<A, S>(grant: &PriceBasedMintGrant<A, S>): u64 {
    grant.total_amount
}

public fun is_canceled<A, S>(grant: &PriceBasedMintGrant<A, S>): bool {
    grant.canceled
}

public fun description<A, S>(grant: &PriceBasedMintGrant<A, S>): &String {
    &grant.description
}

public fun tier_count<A, S>(grant: &PriceBasedMintGrant<A, S>): u64 {
    vector::length(&grant.tiers)
}

public fun twap_window_ms<A, S>(grant: &PriceBasedMintGrant<A, S>): u64 {
    grant.twap_window_ms
}

// === Emergency Controls ===

/// Cancel a grant - internal function for proposal-based cancellation
/// SECURITY: This is now package-private to prevent unauthorized cancellation.
/// Use do_cancel_grant through the proposal system for authorized cancellation.
fun cancel_grant_internal<A, S>(grant: &mut PriceBasedMintGrant<A, S>, clock: &Clock) {
    assert!(grant.cancelable, EGrantNotCancelable);
    assert!(!grant.canceled, EAlreadyCanceled);
    grant.canceled = true;

    // Destroy the embedded mint cap so it doesn't leak permanently.
    let cap = std::option::extract(&mut grant.mint_admin_cap);
    currency::destroy_currency_mint_admin_cap(cap);

    event::emit(GrantCanceled {
        grant_id: object::id(grant),
        timestamp: clock.timestamp_ms(),
    });
}

// === Claim Hot Potato ===

/// Module-local hot potato forcing claim validation and mint fulfillment into the same PTB.
/// Private fields prevent external packages from destructuring or discarding a validated claim.
public struct ClaimGrantRequest<phantom AssetType, phantom StableType> {
    grant_id: ID,
    tier_index: u64,
    recipient: address,
    claimable_amount: u64,
    dao_address: address,
}

// === Claim Helper Functions ===

/// Validate claim eligibility (DAO state, grant state, timing)
fun validate_claim_eligibility<AssetType, StableType>(
    account: &Account,
    registry: &PackageRegistry,
    grant: &PriceBasedMintGrant<AssetType, StableType>,
    clock: &Clock,
) {
    // Ensure account context belongs to the grant's DAO before policy checks.
    assert!(grant.dao_id == object::id(account), EDaoIdMismatch);

    // Check DAO is not dissolving
    assert_not_dissolving(account, registry);

    // Check grant is not canceled/frozen
    assert!(!grant.canceled, EAlreadyCanceled);
    let now = clock.timestamp_ms();

    // Check time bounds
    if (grant.earliest_execution.is_some()) {
        let earliest = grant.earliest_execution.borrow();
        assert!(now >= *earliest, EExecutionTooEarly);
    };

    if (grant.latest_execution.is_some()) {
        let latest = grant.latest_execution.borrow();
        assert!(now <= *latest, EGrantExpired);
    };
}

/// Safe multiplication with division to prevent overflow
/// Computes (a * b) / c without intermediate overflow by using u256
/// Aborts if c == 0 (division by zero)
fun safe_mul_div(a: u128, b: u128, c: u128): u128 {
    assert!(c > 0, EDivisionByZero);
    let a_u256 = (a as u256);
    let b_u256 = (b as u256);
    let c_u256 = (c as u256);
    let product = a_u256 * b_u256;
    ((product / c_u256) as u128)
}

/// Validate price conditions with pre-extracted launchpad enforcement
/// This avoids borrow conflicts when tier is already mutably borrowed
fun validate_price_conditions_with_enforcement<AssetType, StableType, LPType>(
    launchpad_enforcement: LaunchpadEnforcement,
    use_relative_pricing: bool,
    tier: &PriceTier,
    spot_pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    twap_window_ms: u64,
    clock: &Clock,
) {
    // Read windowed TWAP from spot pool's PCW oracle (7-90 day configurable window)
    let simple_twap = unified_spot_pool::get_simple_twap(spot_pool);
    let twap_opt = PCW_TWAP_oracle::get_window_twap(simple_twap, twap_window_ms, clock);
    assert!(twap_opt.is_some(), EOracleHistoryInsufficient);
    let current_price = *twap_opt.borrow();

    // Check tier price condition
    if (tier.price_condition.is_some()) {
        let condition = tier.price_condition.borrow();

        // Calculate actual threshold based on pricing mode
        let actual_threshold = if (use_relative_pricing) {
            // Relative mode: threshold is a multiplier of the fixed launchpad price.
            // Always use the original launchpad_price as baseline so thresholds don't
            // shift with the market — otherwise downside unlocks become impossible and
            // the launchpad minimum enforcement is bypassed during price drops.
            assert!(launchpad_enforcement.launchpad_price > 0, EPriceBelowLaunchpad);
            safe_mul_div(launchpad_enforcement.launchpad_price, condition.threshold, (constants::price_precision_scale() as u128))
        } else {
            // Absolute mode: threshold is already an absolute price
            condition.threshold
        };

        let threshold_condition = PriceCondition {
            threshold: actual_threshold,
            is_above: condition.is_above,
        };

        assert!(check_price_condition(&threshold_condition, current_price), EPriceConditionNotMet);
    };

    // Check launchpad enforcement (global minimum) - ONLY for relative pricing mode
    if (use_relative_pricing && launchpad_enforcement.enabled) {
        // Use the fixed launchpad price as the baseline for the minimum price floor.
        // This ensures the DAO's minimum multiplier is always enforced against the
        // original launch price, not a shifting target.
        let min_price = safe_mul_div(
            launchpad_enforcement.launchpad_price,
            (launchpad_enforcement.minimum_multiplier as u128),
            (constants::price_precision_scale() as u128)
        );
        assert!(current_price >= min_price, EPriceBelowLaunchpad);
    };
}

/// Find recipient's allocation in the tier
/// Returns (recipient_index, claimable_amount) for the recipient
fun find_recipient_allocation(tier: &PriceTier, recipient: address): (u64, u64) {
    let mut claimable_amount = 0u64;
    let mut recipient_index = 0u64;
    let mut found = false;
    let mut i = 0;
    let recipient_count = vector::length(&tier.recipients);
    let executed_count = vector::length(&tier.executed);

    while (i < recipient_count) {
        let recipient_mint = vector::borrow(&tier.recipients, i);
        if (recipient_mint.recipient == recipient) {
            claimable_amount = recipient_mint.amount;
            recipient_index = i;
            found = true;
            break
        };
        i = i + 1;
    };

    assert!(found, ENotRecipient);
    assert!(claimable_amount > 0, EInsufficientVested);
    // Ensure recipient_index is valid for the executed vector (guards against desync)
    assert!(recipient_index < executed_count, EIndexOutOfBounds);

    (recipient_index, claimable_amount)
}

// === Claim Functions ===

/// Claim tokens from a specific tier (STEP 1: Validation)
///
/// Refactored into helper functions for:
/// - Eligibility validation (DAO state, grant state, timing)
/// - Price condition checks (tier + launchpad)
/// - Recipient lookup and allocation
/// - Claim tracking and tier execution
///
/// Returns ClaimGrantRequest hot potato that must be fulfilled via
/// fulfill_claim_grant_from_account() in the same PTB
public fun claim_grant<AssetType, StableType, LPType>(
    account: &Account,
    registry: &PackageRegistry,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    tier_index: u64,
    recipient: address,
    spot_pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
    clock: &Clock,
): ClaimGrantRequest<AssetType, StableType> {
    // Phase 1: Validate claim eligibility
    validate_claim_eligibility(account, registry, grant, clock);

    // Phase 1.5: Validate spot pool belongs to this DAO
    validate_spot_pool(account, spot_pool);

    // Phase 2: Extract launchpad enforcement and pricing mode before mutable borrow
    let launchpad_enforcement = grant.launchpad_enforcement;
    let use_relative_pricing = grant.use_relative_pricing;
    let twap_window_ms = grant.twap_window_ms;

    // Phase 3-5: Work with tier (in its own scope to control borrowing)
    let (recipient, claimable_amount) = {
        assert!(tier_index < vector::length(&grant.tiers), EIndexOutOfBounds);
        let tier = vector::borrow_mut(&mut grant.tiers, tier_index);

        // Find recipient allocation and index
        // recipient is passed as parameter so smart contracts/multisigs can claim
        let (recipient_index, claimable_amount) = find_recipient_allocation(tier, recipient);

        // Check if this specific recipient has already claimed (per-recipient tracking)
        assert!(!*vector::borrow(&tier.executed, recipient_index), ERecipientAlreadyClaimed);

        // Validate price conditions against windowed TWAP
        validate_price_conditions_with_enforcement(
            launchpad_enforcement,
            use_relative_pricing,
            tier,
            spot_pool,
            twap_window_ms,
            clock,
        );

        // Mark this recipient as executed (per-recipient tracking)
        *vector::borrow_mut(&mut tier.executed, recipient_index) = true;

        (recipient, claimable_amount)
    }; // tier borrow ends here

    // Phase 6: Return non-droppable request that must be fulfilled in this PTB.
    let dao_address = object::id_to_address(&grant.dao_id);
    ClaimGrantRequest {
        grant_id: object::id(grant),
        tier_index,
        recipient,
        claimable_amount,
        dao_address,
    }
}

/// Fulfill claim by minting tokens from DAO's TreasuryCap (STEP 2)
public fun fulfill_claim_grant_from_account<AssetType, StableType>(
    request: ClaimGrantRequest<AssetType, StableType>,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
    ctx: &mut tx_context::TxContext,
) {
    let ClaimGrantRequest {
        grant_id,
        tier_index,
        recipient,
        claimable_amount,
        dao_address,
    } = request;

    // Verify correct DAO Account
    let account_addr = account.addr();
    assert!(account_addr == dao_address, EWrongAccount);
    assert!(grant.dao_id == object::id(account), EDaoIdMismatch);
    assert!(object::id(grant) == grant_id, EWrongAccount);

    // Revalidate immediately before minting. The hot potato enforces same-PTB
    // fulfillment, but DAO termination or grant cancellation can still happen
    // in an earlier command in that PTB after claim_grant marks the tier claimed.
    validate_claim_eligibility(account, registry, grant, clock);

    let minted_coin = currency::mint_with_admin_cap<AssetType>(
        account,
        registry,
        grant.mint_admin_cap.borrow(),
        claimable_amount,
        ctx,
    );

    // Transfer to recipient
    transfer::public_transfer(minted_coin, recipient);

    // Emit event
    event::emit(TokensClaimed {
        grant_id,
        tier_index,
        recipient,
        amount_claimed: claimable_amount,
        timestamp: clock.timestamp_ms(),
    });
}

/// Check if price condition is met
fun check_price_condition(condition: &PriceCondition, current_price: u128): bool {
    if (condition.is_above) {
        current_price >= condition.threshold
    } else {
        current_price <= condition.threshold
    }
}

// === Grant Registry Management ===

fun ensure_grant_storage(
    account: &mut Account,
    registry: &PackageRegistry,
    ctx: &mut TxContext,
) {
    use account_protocol::account;

    if (!account::has_managed_data(account, GrantStorageKey {})) {
        account::add_managed_data_with_package_witness(
            account,
            registry,
            GrantStorageKey {},
            GrantStorage {
                grants: sui::table::new(ctx),
                grant_ids: vector::empty(),
                total_grants: 0,
            },
            oracle_version::current(),
        );
    }
}

fun register_grant(
    account: &mut Account,
    registry: &PackageRegistry,
    grant_id: ID,
    cancelable: bool,
) {
    use account_protocol::account;

    let storage: &mut GrantStorage = account::borrow_managed_data_mut_with_package_witness(
        account,
        registry,
        GrantStorageKey {},
        oracle_version::current(),
    );

    let info = GrantInfo {
        recipient: @0x0, // Multi-recipient, no single owner
        cancelable,
    };

    sui::table::add(&mut storage.grants, grant_id, info);
    storage.grant_ids.push_back(grant_id);
    storage.total_grants = storage.total_grants + 1;
}

fun assert_not_dissolving(
    account: &Account,
    _registry: &PackageRegistry,
) {
    use account_protocol::account;
    use futarchy_core::futarchy_config::{Self, FutarchyConfig};

    // DaoState is now embedded in FutarchyConfig, access via config
    let config = account::config<FutarchyConfig>(account);
    let dao_state = futarchy_config::dao_state(config);

    assert!(futarchy_config::operational_state(dao_state) != DAO_STATE_TERMINATED, EDaoDissolving);
}

fun validate_spot_pool<AssetType, StableType, LPType>(
    account: &Account,
    spot_pool: &UnifiedSpotPool<AssetType, StableType, LPType>,
) {
    use account_protocol::account;
    use futarchy_core::futarchy_config::{Self, FutarchyConfig};

    let config = account::config<FutarchyConfig>(account);
    let spot_pool_id_opt = futarchy_config::get_spot_pool_id(config);
    assert!(spot_pool_id_opt.is_some(), EWrongSpotPool);
    assert!(*spot_pool_id_opt.borrow() == object::id(spot_pool), EWrongSpotPool);
}

public fun get_all_grant_ids(
    account: &Account,
    registry: &PackageRegistry,
): vector<ID> {
    use account_protocol::account;

    if (!account::has_managed_data(account, GrantStorageKey {})) {
        return vector::empty()
    };

    let storage: &GrantStorage = account::borrow_managed_data_with_package_witness(
        account,
        registry,
        GrantStorageKey {},
        oracle_version::current(),
    );

    storage.grant_ids
}

// === Action Structs for Proposal System ===

/// Tier specification for action structs
public struct TierSpec has copy, drop, store {
    price_threshold: u128,
    is_above: bool,
    recipients: vector<RecipientMint>,
    tier_description: String,
}

public struct CreateOracleGrantAction<phantom AssetType, phantom StableType> has copy, drop, store {
    mint_cap_resource_name: String,
    tier_specs: vector<TierSpec>,
    use_relative_pricing: bool,
    launchpad_multiplier: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    cancelable: bool,
    description: String,
    twap_window_ms: u64,
}

public struct CancelGrantAction has copy, drop, store {
    grant_id: ID,
}

// === Action Constructors ===

public fun new_create_oracle_grant<AssetType, StableType>(
    mint_cap_resource_name: String,
    tier_specs: vector<TierSpec>,
    use_relative_pricing: bool,
    launchpad_multiplier: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    cancelable: bool,
    description: String,
    twap_window_ms: u64,
): CreateOracleGrantAction<AssetType, StableType> {
    CreateOracleGrantAction {
        mint_cap_resource_name,
        tier_specs,
        use_relative_pricing,
        launchpad_multiplier,
        earliest_execution_offset_ms,
        expiry_years,
        cancelable,
        description,
        twap_window_ms,
    }
}

public fun new_tier_spec(
    price_threshold: u128,
    is_above: bool,
    recipients: vector<RecipientMint>,
    tier_description: String,
): TierSpec {
    TierSpec {
        price_threshold,
        is_above,
        recipients,
        tier_description,
    }
}

public fun recipient_address(rm: &RecipientMint): address {
    rm.recipient
}

public fun recipient_amount(rm: &RecipientMint): u64 {
    rm.amount
}

public fun tier_price_threshold(ts: &TierSpec): u128 {
    ts.price_threshold
}

public fun tier_is_above(ts: &TierSpec): bool {
    ts.is_above
}

public fun tier_recipients(ts: &TierSpec): &vector<RecipientMint> {
    &ts.recipients
}

public fun tier_description(ts: &TierSpec): &String {
    &ts.tier_description
}

public fun new_cancel_grant(grant_id: ID): CancelGrantAction {
    CancelGrantAction { grant_id }
}

// === Helper Functions for BCS Deserialization ===

/// Deserialize tier specifications from BCS reader
fun deserialize_tier_specs(reader: &mut bcs::BCS): vector<TierSpec> {
    let tier_spec_count = bcs::peel_vec_length(reader);
    let mut tier_specs = vector::empty<TierSpec>();
    let mut i = 0;

    while (i < tier_spec_count) {
        let price_threshold = bcs::peel_u128(reader);
        let is_above = bcs::peel_bool(reader);

        // Deserialize recipients for this tier
        let recipients = deserialize_recipients(reader);

        let tier_description_bytes = bcs::peel_vec_u8(reader);
        let tier_description_opt = std::string::try_utf8(tier_description_bytes);
        assert!(tier_description_opt.is_some(), EInvalidUtf8);
        let tier_description = tier_description_opt.destroy_some();

        vector::push_back(
            &mut tier_specs,
            TierSpec {
                price_threshold,
                is_above,
                recipients,
                tier_description,
            },
        );
        i = i + 1;
    };

    tier_specs
}

/// Deserialize recipient mints from BCS reader
fun deserialize_recipients(reader: &mut bcs::BCS): vector<RecipientMint> {
    let recipient_count = bcs::peel_vec_length(reader);
    let mut recipients = vector::empty<RecipientMint>();
    let mut j = 0;

    while (j < recipient_count) {
        let recipient = bcs::peel_address(reader);
        let amount = bcs::peel_u64(reader);
        vector::push_back(&mut recipients, RecipientMint { recipient, amount });
        j = j + 1;
    };

    recipients
}

/// Convert TierSpecs to PriceTiers for grant creation
/// Initializes executed vector with false for each recipient (matching recipients by index)
/// SECURITY: Validates no duplicate recipients within a tier to prevent fund lockup
fun convert_tier_specs_to_price_tiers(tier_specs: &vector<TierSpec>): vector<PriceTier> {
    let mut tiers = vector::empty<PriceTier>();
    let mut k = 0;

    while (k < vector::length(tier_specs)) {
        let tier_spec = vector::borrow(tier_specs, k);

        // Validate recipient count early to prevent O(N²) gas exhaustion
        // in the duplicate-check loop below on maliciously large payloads
        let recipient_count = vector::length(&tier_spec.recipients);
        assert!(recipient_count <= constants::max_recipients_per_tier(), ETooManyRecipients);

        // Initialize executed vector with false for each recipient
        // executed[i] will track whether recipients[i] has claimed
        let mut executed = vector::empty<bool>();
        let mut r = 0;
        while (r < recipient_count) {
            vector::push_back(&mut executed, false);
            r = r + 1;
        };

        // SECURITY: Validate recipients - re-enforce checks from staging time
        // after BCS deserialization to prevent tampered action data
        let mut seen_addrs = vector::empty<address>();
        let mut i = 0;
        while (i < recipient_count) {
            let rm = vector::borrow(&tier_spec.recipients, i);
            // Validate no zero amounts (re-enforce staging checks)
            assert!(rm.amount > 0, EZeroAmount);
            // Check for duplicate recipients within this tier
            // If duplicates exist, find_recipient_allocation would only find the first,
            // permanently locking funds for subsequent allocations to the same address
            let mut j = 0;
            while (j < vector::length(&seen_addrs)) {
                assert!(*vector::borrow(&seen_addrs, j) != rm.recipient, EDuplicateRecipientInTier);
                j = j + 1;
            };
            vector::push_back(&mut seen_addrs, rm.recipient);
            i = i + 1;
        };

        // SECURITY: Validate price threshold to prevent unclaimable tiers
        // If is_above=false and threshold=0, condition "price <= 0" is never true
        // (prices are unsigned). This would permanently lock funds.
        // threshold=0 with is_above=true is allowed (means "no price requirement")
        if (!tier_spec.is_above) {
            assert!(tier_spec.price_threshold > 0, EInvalidPriceThreshold);
        };

        let tier = PriceTier {
            price_condition: std::option::some(PriceCondition {
                threshold: tier_spec.price_threshold,
                is_above: tier_spec.is_above,
            }),
            recipients: tier_spec.recipients,
            executed,
            description: tier_spec.tier_description,
        };
        vector::push_back(&mut tiers, tier);
        k = k + 1;
    };

    tiers
}

// === Execution Functions ===

/// Execute create oracle grant action from proposal
/// Refactored into smaller helper functions for clarity
public fun do_create_oracle_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    account_protocol::account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );
    // Validate DAO state and ensure storage exists
    assert_not_dissolving(account, registry);
    ensure_grant_storage(account, registry, ctx);

    // Validate AssetType/StableType match the DAO's configured types
    let futarchy_cfg: &FutarchyConfig = account_protocol::account::config(account);
    let expected_asset = futarchy_config::asset_type(futarchy_cfg);
    let expected_stable = futarchy_config::stable_type(futarchy_cfg);
    let actual_asset = type_name::with_original_ids<AssetType>().into_string().to_string();
    let actual_stable = type_name::with_original_ids<StableType>().into_string().to_string();
    assert!(actual_asset == *expected_asset, EAssetTypeMismatch);
    assert!(actual_stable == *expected_stable, EStableTypeMismatch);

    // Extract and validate action spec
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<CreateOracleGrant<AssetType, StableType>>(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize action data from BCS
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);

    let mint_cap_resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let tier_specs = deserialize_tier_specs(&mut reader);
    let use_relative_pricing = bcs::peel_bool(&mut reader);
    let launchpad_multiplier = bcs::peel_u64(&mut reader);
    let earliest_execution_offset_ms = bcs::peel_u64(&mut reader);
    let expiry_years = bcs::peel_u64(&mut reader);
    let cancelable = bcs::peel_bool(&mut reader);
    let description_bytes = bcs::peel_vec_u8(&mut reader);
    let twap_window_ms = bcs::peel_u64(&mut reader);

    bcs_validation::validate_all_bytes_consumed(reader);

    // Convert deserialized data to runtime structures
    let description_opt = std::string::try_utf8(description_bytes);
    assert!(description_opt.is_some(), EInvalidUtf8);
    let description = description_opt.destroy_some();
    let dao_id = object::id(account);
    let tiers = convert_tier_specs_to_price_tiers(&tier_specs);
    let mint_admin_cap: CurrencyMintAdminCap<AssetType> = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        mint_cap_resource_name,
    );

    // Create the grant
    create_grant<AssetType, StableType>(
        account,
        registry,
        tiers,
        use_relative_pricing,
        launchpad_multiplier,
        earliest_execution_offset_ms,
        expiry_years,
        cancelable,
        description,
        dao_id,
        mint_admin_cap,
        twap_window_ms,
        clock,
        ctx,
    );

    executable::increment_action_idx<_, CreateOracleGrant<AssetType, StableType>, _>(executable, registry, ExecutionProgressWitness {});
}

public fun do_cancel_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _witness: IW,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    account_protocol::account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );
    let specs = executable::intent(executable).action_specs();
    let action_spec = specs.borrow(executable::action_idx(executable));
    account_protocol::action_validation::assert_action_type<CancelGrant<AssetType, StableType>>(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize grant_id and validate it matches the passed grant
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let grant_id_addr = bcs::peel_address(&mut reader); // ID serializes as address (32 bytes)
    bcs_validation::validate_all_bytes_consumed(reader);

    // Ensure the passed grant matches the spec
    assert!(object::id(grant).to_address() == grant_id_addr, EWrongAccount);
    // Prevent cross-DAO cancellation of a grant by requiring the grant be bound to the same DAO account.
    assert!(grant.dao_id == object::id(account), EDaoIdMismatch);

    // Prevent grant cancellation on terminated DAOs (consistent with create/claim paths).
    assert_not_dissolving(account, registry);

    cancel_grant_internal(grant, clock);
    executable::increment_action_idx<_, CancelGrant<AssetType, StableType>, _>(executable, registry, ExecutionProgressWitness {});
}

// === Test-Only Functions ===

#[test_only]
/// Convert TierSpecs to PriceTiers for testing
public fun convert_tier_specs_for_testing(tier_specs: vector<TierSpec>): vector<PriceTier> {
    convert_tier_specs_to_price_tiers(&tier_specs)
}

#[test_only]
/// Cancel a grant for testing - bypasses the proposal system
public fun cancel_grant<A, S>(grant: &mut PriceBasedMintGrant<A, S>, clock: &Clock) {
    cancel_grant_internal(grant, clock);
}

#[test_only]
public fun launchpad_enforcement_enabled_for_testing<A, S>(
    grant: &PriceBasedMintGrant<A, S>,
): bool {
    grant.launchpad_enforcement.enabled
}

#[test_only]
public fun launchpad_minimum_multiplier_for_testing<A, S>(
    grant: &PriceBasedMintGrant<A, S>,
): u64 {
    grant.launchpad_enforcement.minimum_multiplier
}

#[test_only]
public fun launchpad_price_for_testing<A, S>(grant: &PriceBasedMintGrant<A, S>): u128 {
    grant.launchpad_enforcement.launchpad_price
}
