// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Registry of pre-created "blank" coin types that can be used for conditional tokens
/// Solves the problem that coin types can't be created dynamically in Sui
/// Allows proposal creators to acquire coin pairs without requiring two transactions
module futarchy_one_shot_utils::blank_coins;

use std::string;
use std::type_name;
use sui::clock::Clock;
use sui::coin::{TreasuryCap, Coin};
use sui::coin_registry::{Self, Currency, MetadataCap};
use sui::dynamic_field;
use sui::event;
use sui::sui::SUI;

// === Errors ===
const ESupplyNotZero: u64 = 0;
const EInsufficientFee: u64 = 1;
const ERegistryFull: u64 = 7;
const ENoCoinSetsAvailable: u64 = 9;
const EInvalidCoinModule: u64 = 10;
const EDecimalsMismatch: u64 = 12;
const EInvalidDecimals: u64 = 13;
const EInvalidSymbol: u64 = 14;
const ERegulatedCoin: u64 = 15;

/// Maximum supported decimals (Sui coins can have 0-18 decimals)
const MAX_DECIMALS: u8 = 18;

// === Constants ===
const MAX_COIN_SETS: u64 = 100_000;
/// Fixed protocol fee in SUI MIST (0.01 SUI = 10_000_000 MIST)
/// Compensates depositors for gas cost of deploying coin modules
const LISTING_FEE: u64 = 10_000_000;
/// Allowed module name prefix for blank coins deposited into the registry
/// Module names must be "conditional_" followed by only digits (e.g., conditional_0, conditional_42)
/// This prevents offensive module names from appearing in type strings shown to users
const ALLOWED_MODULE_PREFIX: vector<u8> = b"conditional_";
/// Required symbol for all conditional coins (immutable, set at creation)
/// All conditional coins must have this exact symbol
const REQUIRED_SYMBOL: vector<u8> = b"Govex Conditional";

// === Structs ===

/// A single coin set ready for use as conditional tokens
/// Contains TreasuryCap for minting and MetadataCap for updating metadata
/// (Currency<T> is shared automatically via coin_registry::finalize())
public struct CoinSet<phantom T> has store {
    treasury_cap: TreasuryCap<T>,
    metadata_cap: MetadataCap<T>, // For updating name/description/icon (not symbol - that's immutable)
    currency_id: ID, // ID of the shared Currency<T> object for this coin type
    owner: address, // Who deposited this set and gets paid
    decimals: u8, // Decimals of the coin (immutable, captured from Currency<T> at deposit)
}

/// Composite key for storing coin sets: (decimals, cap_id)
/// This enables efficient routing by decimals while maintaining unique cap_id lookup
public struct CoinSetKey has copy, drop, store {
    decimals: u8,
    cap_id: ID,
}

/// Global registry storing available blank coin sets for conditional tokens
/// Permissionless - anyone can add coin sets
/// BUCKETED BY DECIMALS: Coin sets are stored in buckets by their decimal value
/// - Depositor supplies expected decimals (validated against Currency<T>)
/// - Taker supplies desired decimals (routes to correct bucket)
public struct BlankCoinsRegistry has key {
    id: UID,
    // CoinSets stored as dynamic fields with (decimals, cap_id) composite key
    // This allows efficient lookup by decimals
    total_sets: u64,
    // Track count per bucket for visibility
    sets_by_decimals: vector<u64>, // Index = decimals (0-18), value = count
}

// === Events ===

public struct CoinSetDeposited has copy, drop {
    registry_id: ID,
    cap_id: ID,
    owner: address,
    decimals: u8, // Decimals of the coin (for indexing/filtering)
    timestamp: u64,
}

public struct CoinSetTaken has copy, drop {
    registry_id: ID,
    cap_id: ID,
    taker: address,
    fee_paid: u64,
    owner_paid: address,
    timestamp: u64,
}

// === Validation Functions ===

/// Basic validation of a coin set (supply must be zero)
/// Used by factory and launchpad to ensure cap validity
/// Does NOT enforce empty metadata - use validate_coin_set_for_registry for that
///
/// Checks:
/// 1. Supply must be zero (prevents using already-minted coins)
public fun validate_coin_set<T>(treasury_cap: &TreasuryCap<T>) {
    // Validate coin meets requirements: supply must be zero
    assert!(treasury_cap.total_supply() == 0, ESupplyNotZero);
}

/// Validate a coin set for deposit into registry
/// Enforces stricter requirements for "blank" conditional tokens
///
/// Checks:
/// 1. Supply must be zero (prevents using already-minted coins)
/// 2. Symbol must be "Govex Conditional" (immutable, set at creation)
/// 3. Name, description, icon must be empty (will be set by proposal.move)
/// 4. Currency must be unregulated and bound to the deposited caps
/// 5. Module name must be "conditional_N" where N is digits only (prevents offensive names)
fun validate_coin_set_for_registry<T>(
    currency: &mut Currency<T>,
    treasury_cap: &TreasuryCap<T>,
    metadata_cap: &MetadataCap<T>,
    ctx: &mut TxContext,
) {
    // First do basic validation (supply must be zero)
    validate_coin_set(treasury_cap);

    assert_new_unregulated_currency(currency, ctx);

    // Bind the Currency metadata to the exact caps being deposited. `is_some` is
    // insufficient because set_treasury_cap_id is public for legacy migrations.
    let registered_cap_id = coin_registry::treasury_cap_id(currency);
    assert!(registered_cap_id.is_some(), ERegulatedCoin);
    assert!(*registered_cap_id.borrow() == object::id(treasury_cap), ERegulatedCoin);

    let registered_metadata_cap_id = coin_registry::metadata_cap_id(currency);
    assert!(registered_metadata_cap_id.is_some(), ERegulatedCoin);
    assert!(*registered_metadata_cap_id.borrow() == object::id(metadata_cap), ERegulatedCoin);

    // Symbol must be "Govex Conditional" (immutable, set at coin creation)
    let symbol = coin_registry::symbol(currency);
    assert!(symbol == string::utf8(REQUIRED_SYMBOL), EInvalidSymbol);

    // Name, description, icon must be empty (will be set by proposal.move via MetadataCap)
    assert!(coin_registry::name(currency).is_empty(), EInvalidCoinModule);
    assert!(coin_registry::description(currency).is_empty(), EInvalidCoinModule);
    assert!(coin_registry::icon_url(currency).is_empty(), EInvalidCoinModule);

    // Validate module name to prevent offensive names appearing in type strings
    // This is content moderation, not security - anyone could deploy a module
    // with the allowed pattern, but this prevents casual abuse
    let type_info = type_name::with_original_ids<T>();
    let module_name = type_name::get_module(&type_info);
    let module_bytes = module_name.into_bytes();
    let prefix = ALLOWED_MODULE_PREFIX;
    let prefix_len = prefix.length();

    // Must be at least prefix + 1 digit
    assert!(module_bytes.length() > prefix_len, EInvalidCoinModule);

    // Check prefix matches "conditional_"
    let mut i = 0;
    while (i < prefix_len) {
        assert!(module_bytes[i] == prefix[i], EInvalidCoinModule);
        i = i + 1;
    };

    // Check remaining characters are all digits (0-9 = 48-57 in ASCII)
    while (i < module_bytes.length()) {
        let c = module_bytes[i];
        assert!(c >= 48 && c <= 57, EInvalidCoinModule);
        i = i + 1;
    };
}

fun assert_new_unregulated_currency<T>(currency: &mut Currency<T>, ctx: &mut TxContext) {
    let (legacy_metadata, borrow) = coin_registry::borrow_legacy_metadata(currency, ctx);
    coin_registry::return_borrowed_legacy_metadata(currency, legacy_metadata, borrow, ctx);
    assert!(!coin_registry::is_regulated(currency), ERegulatedCoin);
}

// === Admin Functions ===

/// Create a new blank coins registry (admin/one-time setup)
public fun create_registry(ctx: &mut TxContext): BlankCoinsRegistry {
    // Initialize vector with 19 zeros (for decimals 0-18)
    let mut sets_by_decimals = vector::empty<u64>();
    let mut i = 0u8;
    while (i <= MAX_DECIMALS) {
        sets_by_decimals.push_back(0);
        i = i + 1;
    };

    BlankCoinsRegistry {
        id: object::new(ctx),
        total_sets: 0,
        sets_by_decimals,
    }
}

/// Share the registry to make it publicly accessible
public entry fun share_registry(registry: BlankCoinsRegistry) {
    transfer::share_object(registry);
}

// === Deposit Functions ===

/// Deposit a coin set into the registry
/// Validates that the coin meets all requirements for conditional tokens
/// Requires passing the Currency<T> object (shared by coin_registry::finalize)
///
/// BUCKETED BY DECIMALS:
/// - Depositor supplies expected_decimals which is VALIDATED against Currency<T>.decimals()
/// - Coin set is stored in the bucket for that decimal value
/// - Taker can request coins by decimals to get matching asset/stable coins
public fun deposit_coin_set<T>(
    registry: &mut BlankCoinsRegistry,
    currency: &mut Currency<T>,
    treasury_cap: TreasuryCap<T>,
    metadata_cap: MetadataCap<T>, // For updating name/description/icon later
    expected_decimals: u8, // Depositor declares expected decimals - VALIDATED!
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check registry not full
    assert!(registry.total_sets < MAX_COIN_SETS, ERegistryFull);

    // Validate decimals is in valid range
    assert!(expected_decimals <= MAX_DECIMALS, EInvalidDecimals);

    // Validate coin set for registry (supply must be zero, metadata must be empty, module name must match pattern)
    validate_coin_set_for_registry(currency, &treasury_cap, &metadata_cap, ctx);

    // Read actual decimals from Currency<T> (immutable, set at coin creation)
    let actual_decimals = coin_registry::decimals(currency);

    // CRITICAL: Validate depositor's expected_decimals matches actual coin decimals
    assert!(expected_decimals == actual_decimals, EDecimalsMismatch);

    let cap_id = object::id(&treasury_cap);
    let currency_id = object::id(currency);
    let owner = ctx.sender();

    // Create coin set with decimals, currency reference, and metadata cap
    let coin_set = CoinSet {
        treasury_cap,
        metadata_cap,
        currency_id,
        owner,
        decimals: actual_decimals,
    };

    // Store in registry with composite key (decimals, cap_id) for bucketed lookup
    let key = CoinSetKey { decimals: actual_decimals, cap_id };
    dynamic_field::add(&mut registry.id, key, coin_set);
    registry.total_sets = registry.total_sets + 1;

    // Increment bucket counter
    let bucket_count = registry.sets_by_decimals.borrow_mut(actual_decimals as u64);
    *bucket_count = *bucket_count + 1;

    // Emit event with decimals for indexing
    event::emit(CoinSetDeposited {
        registry_id: object::id(registry),
        cap_id,
        owner,
        decimals: actual_decimals,
        timestamp: clock.timestamp_ms(),
    });
}

/// Deposit a coin set via entry function (transfers ownership)
public entry fun deposit_coin_set_entry<T>(
    registry: &mut BlankCoinsRegistry,
    currency: &mut Currency<T>,
    treasury_cap: TreasuryCap<T>,
    metadata_cap: MetadataCap<T>,
    expected_decimals: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    deposit_coin_set(
        registry,
        currency,
        treasury_cap,
        metadata_cap,
        expected_decimals,
        clock,
        ctx,
    );
}

// === Take Functions ===

/// Take a coin set from registry and transfer TreasuryCap to sender
/// Returns the remaining payment coin for chaining multiple takes in a PTB
/// Call this N times in a PTB for N outcomes
///
/// BUCKETED BY DECIMALS:
/// - Taker supplies desired_decimals to route to correct bucket
/// - This ensures asset-conditional coins have 9 decimals, stable-conditional have 6 decimals
#[allow(lint(self_transfer))]
public fun take_coin_set<T>(
    registry: &mut BlankCoinsRegistry,
    desired_decimals: u8, // Taker declares what decimals they need - used for routing!
    cap_id: ID,
    mut fee_payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    // Build composite key for bucketed lookup
    let key = CoinSetKey { decimals: desired_decimals, cap_id };

    // Check exists in the correct bucket
    assert!(
        dynamic_field::exists_with_type<CoinSetKey, CoinSet<T>>(&registry.id, key),
        ENoCoinSetsAvailable,
    );

    // Remove from registry using composite key
    let coin_set: CoinSet<T> = dynamic_field::remove(&mut registry.id, key);

    // Validate fee payment covers fixed protocol fee
    assert!(fee_payment.value() >= LISTING_FEE, EInsufficientFee);

    // Split exact payment and pay the depositor
    let payment = fee_payment.split(LISTING_FEE, ctx);
    transfer::public_transfer(payment, coin_set.owner);

    // Update total count
    registry.total_sets = registry.total_sets - 1;

    // Decrement bucket counter
    let bucket_count = registry.sets_by_decimals.borrow_mut(coin_set.decimals as u64);
    *bucket_count = *bucket_count - 1;

    // Emit event
    event::emit(CoinSetTaken {
        registry_id: object::id(registry),
        cap_id,
        taker: ctx.sender(),
        fee_paid: LISTING_FEE,
        owner_paid: coin_set.owner,
        timestamp: clock.timestamp_ms(),
    });

    // Return TreasuryCap and MetadataCap to sender (Currency<T> is already shared)
    let CoinSet { treasury_cap, metadata_cap, currency_id: _, owner: _, decimals: _ } =
        coin_set;
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());

    // Return remaining payment for next take
    fee_payment
}

/// Take a coin set from registry and RETURN caps for use in same PTB
/// Unlike take_coin_set(), this returns the caps instead of transferring them
/// This allows the caps to be used immediately in the same transaction
/// (e.g., to register with escrow)
///
/// BUCKETED BY DECIMALS:
/// - Taker supplies desired_decimals to route to correct bucket
/// - This ensures asset-conditional coins have 9 decimals, stable-conditional have 6 decimals
///
/// Returns: (TreasuryCap<T>, MetadataCap<T>, currency_id, remaining_payment)
public fun take_coin_set_for_ptb<T>(
    registry: &mut BlankCoinsRegistry,
    desired_decimals: u8, // Taker declares what decimals they need - used for routing!
    cap_id: ID,
    mut fee_payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): (TreasuryCap<T>, MetadataCap<T>, ID, Coin<SUI>) {
    // Build composite key for bucketed lookup
    let key = CoinSetKey { decimals: desired_decimals, cap_id };

    // Check exists in the correct bucket
    assert!(
        dynamic_field::exists_with_type<CoinSetKey, CoinSet<T>>(&registry.id, key),
        ENoCoinSetsAvailable,
    );

    // Remove from registry using composite key
    let coin_set: CoinSet<T> = dynamic_field::remove(&mut registry.id, key);

    // Validate fee payment covers fixed protocol fee
    assert!(fee_payment.value() >= LISTING_FEE, EInsufficientFee);

    // Split exact payment and pay the depositor
    let payment = fee_payment.split(LISTING_FEE, ctx);
    transfer::public_transfer(payment, coin_set.owner);

    // Update total count
    registry.total_sets = registry.total_sets - 1;

    // Decrement bucket counter
    let bucket_count = registry.sets_by_decimals.borrow_mut(coin_set.decimals as u64);
    *bucket_count = *bucket_count - 1;

    // Emit event
    event::emit(CoinSetTaken {
        registry_id: object::id(registry),
        cap_id,
        taker: ctx.sender(),
        fee_paid: LISTING_FEE,
        owner_paid: coin_set.owner,
        timestamp: clock.timestamp_ms(),
    });

    // RETURN caps and currency_id instead of transferring (key difference!)
    let CoinSet { treasury_cap, metadata_cap, currency_id, owner: _, decimals: _ } =
        coin_set;

    // Return (treasury_cap, metadata_cap, currency_id, remaining_payment) for use in same PTB
    // Taker can use currency_id to find the shared Currency<T> object
    (treasury_cap, metadata_cap, currency_id, fee_payment)
}

// === View Functions ===

/// Get total number of coin sets in registry
public fun total_sets(registry: &BlankCoinsRegistry): u64 {
    registry.total_sets
}

/// Get the fixed protocol listing fee (in MIST)
public fun listing_fee(): u64 {
    LISTING_FEE
}

/// Get number of coin sets available for a specific decimal value
/// Use this to find if there are coins available matching your asset/stable decimals
public fun sets_available_for_decimals(registry: &BlankCoinsRegistry, decimals: u8): u64 {
    if (decimals > MAX_DECIMALS) {
        return 0
    };
    *registry.sets_by_decimals.borrow(decimals as u64)
}

/// Check if a specific coin set is available in a given bucket
/// Requires knowing the decimals to locate the coin set
public fun has_coin_set(registry: &BlankCoinsRegistry, decimals: u8, cap_id: ID): bool {
    let key = CoinSetKey { decimals, cap_id };
    dynamic_field::exists_(&registry.id, key)
}

/// Get owner of a specific coin set
public fun get_owner<T>(registry: &BlankCoinsRegistry, decimals: u8, cap_id: ID): address {
    let key = CoinSetKey { decimals, cap_id };
    let coin_set: &CoinSet<T> = dynamic_field::borrow(&registry.id, key);
    coin_set.owner
}

/// Get decimals of a specific coin set (returns the stored decimals)
/// Useful for verification - should match the decimals used in the key
public fun get_decimals<T>(registry: &BlankCoinsRegistry, decimals: u8, cap_id: ID): u8 {
    let key = CoinSetKey { decimals, cap_id };
    let coin_set: &CoinSet<T> = dynamic_field::borrow(&registry.id, key);
    coin_set.decimals
}

/// Get currency_id of a specific coin set
/// Returns the ID of the shared Currency<T> object for this coin type
public fun get_currency_id<T>(registry: &BlankCoinsRegistry, decimals: u8, cap_id: ID): ID {
    let key = CoinSetKey { decimals, cap_id };
    let coin_set: &CoinSet<T> = dynamic_field::borrow(&registry.id, key);
    coin_set.currency_id
}
