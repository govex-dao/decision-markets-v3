// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Public cleanup functions for expired intents
/// Sui's storage rebate system naturally incentivizes cleanup -
/// cleaners get the storage deposit back when deleting objects
module futarchy_governance_actions::intent_janitor;

use account_protocol::account::{Self, Account};
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use futarchy_core::futarchy_config::{Self as futarchy_config, FutarchyOutcome};
use futarchy_governance_actions::futarchy_governance_actions_version as version;
use futarchy_one_shot_utils::constants;
use std::string::String;
use std::type_name;
use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};

// === Errors ===

const ECleanupLimitExceeded: u64 = 2;
const EInvalidIntentOutcomeType: u64 = 3;

// === Types ===

/// Index for tracking created intents to enable cleanup
public struct IntentIndex has store {
    /// Vector of all intent keys that have been created
    keys: vector<String>,
    /// Map from intent key to expiration time for quick lookup
    expiration_times: Table<String, u64>,
    /// Current scan position for round-robin cleanup
    scan_position: u64,
}

/// Key for storing the intent index in managed data
public struct IntentIndexKey has copy, drop, store {}

#[test_only]
public(package) fun has_intent_index_for_testing(account: &Account): bool {
    account::has_managed_data(account, IntentIndexKey {})
}

// === Events ===

/// Emitted when intents are cleaned
public struct IntentsCleaned has copy, drop {
    dao_id: ID,
    cleaner: address,
    count: u64,
    timestamp: u64,
}

/// Emitted when maintenance is needed
public struct MaintenanceNeeded has copy, drop {
    dao_id: ID,
    expired_count: u64,
    timestamp: u64,
}

// === Public Functions ===

/// Clean up expired FutarchyOutcome intents
/// Sui's storage rebate naturally rewards cleaners
public fun cleanup_expired_futarchy_intents(
    account: &mut Account,
    registry: &PackageRegistry,
    max_to_clean: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(max_to_clean <= constants::max_cleanup_per_call(), ECleanupLimitExceeded);

    let mut cleaned = 0u64;
    let dao_id = object::id(account);
    let cleaner = ctx.sender();

    // Try to clean up to max_to_clean intents. Each search step is scan-bounded;
    // a call may make scan progress without finding an expired intent.
    while (cleaned < max_to_clean) {
        // Find next expired intent
        let mut intent_key_opt = find_and_remove_next_expired_intent(
            account,
            registry,
            clock,
            constants::max_cleanup_scan_per_call(),
        );
        if (intent_key_opt.is_none()) {
            break
        };

        let intent_key = intent_key_opt.extract();

        // Always count toward limit (stale entries still consume gas).
        // The janitor index entry was already removed during the bounded scan.
        try_delete_expired_futarchy_intent(account, intent_key, clock, ctx);
        cleaned = cleaned + 1;
    };

    // Only emit event if we actually cleaned something
    // Don't abort on no expired intents - just a no-op (callers can't check beforehand)
    if (cleaned > 0) {
        event::emit(IntentsCleaned {
            dao_id,
            cleaner,
            count: cleaned,
            timestamp: clock.timestamp_ms(),
        });
    };
}

/// Read-only cleanup status for off-chain crankers.
///
/// Returns:
/// - has_index: whether this account has janitor state
/// - indexed_count: number of indexed intent keys
/// - scan_position: normalized current round-robin scan position
/// - cleanup_scan_limit: entries one cleanup search step scans
/// - next_cleanup_expired_count: expired entries visible to the next cleanup call
/// - preview_expired_count: expired entries visible in the bounded preview window
/// - cleanup_calls_to_first_expired: estimated cleanup calls needed to reach the
///   first expired entry in the preview, or 0 if none is visible
public fun janitor_cleanup_status(
    account: &Account,
    registry: &PackageRegistry,
    clock: &Clock,
): (bool, u64, u64, u64, u64, u64, u64) {
    let cleanup_scan_limit = constants::max_cleanup_scan_per_call();

    if (!account::has_managed_data(account, IntentIndexKey {})) {
        return (false, 0, 0, cleanup_scan_limit, 0, 0, 0)
    };

    let index: &IntentIndex = account::borrow_managed_data_with_package_witness(
        account,
        registry,
        IntentIndexKey {},
        version::current(),
    );

    let indexed_count = vector::length(&index.keys);
    if (indexed_count == 0) {
        return (true, 0, 0, cleanup_scan_limit, 0, 0, 0)
    };

    let mut scan_position = index.scan_position;
    if (scan_position >= indexed_count) {
        scan_position = 0;
    };

    let current_time = clock.timestamp_ms();
    let (_, next_cleanup_expired_count, _) = scan_expired_from_position(
        index,
        current_time,
        cleanup_scan_limit,
    );
    let (_, preview_expired_count, cleanup_calls_to_first_expired) = scan_expired_from_position(
        index,
        current_time,
        cleanup_scan_limit * constants::max_cleanup_per_call(),
    );

    (
        true,
        indexed_count,
        scan_position,
        cleanup_scan_limit,
        next_cleanup_expired_count,
        preview_expired_count,
        cleanup_calls_to_first_expired,
    )
}

/// Clean up expired intents during normal operations (no reward)
/// Called automatically during proposal finalization and execution
/// Uses constants::max_cleanup_per_call() limit to prevent gas exhaustion
public fun cleanup_all_expired_intents(
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Clean with a bounded limit to prevent gas exhaustion
    // Callers can call this multiple times if more cleanup is needed
    let mut cleaned = 0u64;
    while (cleaned < constants::max_cleanup_per_call()) {
        let mut intent_key_opt = find_and_remove_next_expired_intent(
            account,
            registry,
            clock,
            constants::max_cleanup_scan_per_call(),
        );
        if (intent_key_opt.is_none()) {
            break
        };

        let intent_key = intent_key_opt.extract();

        // Try to delete it - continue even if this specific key is stale/not found.
        // Always count toward limit (stale entries still consume gas).
        try_delete_expired_futarchy_intent(account, intent_key, clock, ctx);
        cleaned = cleaned + 1;
    };
}

/// Clean up expired intents with a limit (for bounded operations)
/// Called automatically during proposal finalization and execution
public(package) fun cleanup_expired_intents_automatic(
    account: &mut Account,
    registry: &PackageRegistry,
    max_to_clean: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(max_to_clean <= constants::max_cleanup_per_call(), ECleanupLimitExceeded);

    let mut cleaned = 0u64;

    while (cleaned < max_to_clean) {
        let mut intent_key_opt = find_and_remove_next_expired_intent(
            account,
            registry,
            clock,
            constants::max_cleanup_scan_per_call(),
        );
        if (intent_key_opt.is_none()) {
            break
        };

        let intent_key = intent_key_opt.extract();

        // Always count toward limit (stale entries still consume gas).
        try_delete_expired_futarchy_intent(account, intent_key, clock, ctx);
        cleaned = cleaned + 1;
    };
}

/// Check if maintenance is needed and emit event if so
public fun check_maintenance_needed(account: &Account, registry: &PackageRegistry, clock: &Clock) {
    let expired_count = count_expired_intents(account, registry, clock);

    if (expired_count > constants::maintenance_threshold()) {
        event::emit(MaintenanceNeeded {
            dao_id: object::id(account),
            expired_count,
            timestamp: clock.timestamp_ms(),
        });
    }
}

// === Internal Functions ===

/// Get or initialize the intent index
fun get_or_init_intent_index(
    account: &mut Account,
    registry: &PackageRegistry,
    ctx: &mut TxContext,
): &mut IntentIndex {
    // Initialize if doesn't exist
    if (!account::has_managed_data(account, IntentIndexKey {})) {
        let index = IntentIndex {
            keys: vector::empty(),
            expiration_times: table::new(ctx),
            scan_position: 0,
        };
        account::add_managed_data_with_package_witness(
            account,
            registry,
            IntentIndexKey {},
            index,
            version::current(),
        );
    };

    account::borrow_managed_data_mut_with_package_witness(
        account,
        registry,
        IntentIndexKey {},
        version::current(),
    )
}

/// Add an intent to the index when it's created.
/// Only FutarchyOutcome intents are supported by janitor cleanup.
public(package) fun register_intent<Outcome>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: String,
    expiration_time: u64,
    ctx: &mut TxContext,
) {
    assert!(
        type_name::with_original_ids<Outcome>() == type_name::with_original_ids<FutarchyOutcome>(),
        EInvalidIntentOutcomeType,
    );
    let index = get_or_init_intent_index(account, registry, ctx);
    vector::push_back(&mut index.keys, key);
    table::add(&mut index.expiration_times, key, expiration_time);
}

/// Remove an intent from the index when it is consumed through non-expiry paths.
/// This keeps the janitor index compact and avoids scanning stale entries.
public(package) fun unregister_intent(
    account: &mut Account,
    registry: &PackageRegistry,
    key: String,
    _ctx: &mut TxContext,
) {
    if (!account::has_managed_data(account, IntentIndexKey {})) {
        return
    };
    remove_from_index(account, registry, key);
}

/// Find and remove the next expired intent index entry within a fixed scan budget.
/// Removing by the found vector position avoids an extra unbounded remove scan in
/// cleanup paths. If the underlying intent delete aborts later, this removal
/// reverts with the transaction.
fun find_and_remove_next_expired_intent(
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
    max_scan: u64,
): Option<String> {
    if (!account::has_managed_data(account, IntentIndexKey {})) {
        return option::none()
    };

    let index: &mut IntentIndex = account::borrow_managed_data_mut_with_package_witness(
        account,
        registry,
        IntentIndexKey {},
        version::current(),
    );

    let current_time = clock.timestamp_ms();
    let len = vector::length(&index.keys);

    if (len == 0 || max_scan == 0) {
        return option::none()
    };

    // Start from last scan position for round-robin
    let mut checked = 0u64;
    let mut pos = index.scan_position;

    while (checked < len && checked < max_scan) {
        if (pos >= len) {
            pos = 0; // Wrap around
        };

        let key = *vector::borrow(&index.keys, pos);

        // Check if this intent is expired
        if (table::contains(&index.expiration_times, key)) {
            let expiry = *table::borrow(&index.expiration_times, key);
            if (current_time >= expiry) {
                table::remove(&mut index.expiration_times, key);
                vector::swap_remove(&mut index.keys, pos);

                let new_len = vector::length(&index.keys);
                if (new_len == 0 || pos >= new_len) {
                    index.scan_position = 0;
                } else {
                    index.scan_position = pos;
                };

                return option::some(key)
            }
        };

        pos = pos + 1;
        checked = checked + 1;
    };

    if (pos >= len) {
        pos = 0;
    };
    index.scan_position = pos;

    option::none()
}

/// Try to delete an expired FutarchyOutcome intent
fun try_delete_expired_futarchy_intent(
    account: &mut Account,
    key: String,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Check if intent exists
    let intents_store = account::intents(account);
    if (!intents::contains(intents_store, key)) {
        return false
    };

    intents::drain_and_destroy_expired(futarchy_config::delete_expired_intent(
        account,
        key,
        clock,
        ctx,
    ));

    true
}

/// Count expired intents
fun count_expired_intents(account: &Account, registry: &PackageRegistry, clock: &Clock): u64 {
    // Check if index exists
    if (!account::has_managed_data(account, IntentIndexKey {})) {
        return 0
    };

    let index: &IntentIndex = account::borrow_managed_data_with_package_witness(
        account,
        registry,
        IntentIndexKey {},
        version::current(),
    );

    let (_, count, _) = scan_expired_from_position(
        index,
        clock.timestamp_ms(),
        constants::max_cleanup_scan_per_call(),
    );
    count
}

fun scan_expired_from_position(
    index: &IntentIndex,
    current_time: u64,
    max_scan: u64,
): (u64, u64, u64) {
    let len = vector::length(&index.keys);
    if (len == 0 || max_scan == 0) {
        return (0, 0, 0)
    };

    let mut scan_limit = max_scan;
    if (scan_limit > len) {
        scan_limit = len;
    };

    let mut checked = 0u64;
    let mut expired_count = 0u64;
    let mut first_expired_offset = 0u64;
    let mut pos = index.scan_position;

    while (checked < scan_limit) {
        if (pos >= len) {
            pos = 0;
        };

        let key = vector::borrow(&index.keys, pos);
        if (table::contains(&index.expiration_times, *key)) {
            let expiry = *table::borrow(&index.expiration_times, *key);
            if (current_time >= expiry) {
                if (expired_count == 0) {
                    first_expired_offset = checked;
                };
                expired_count = expired_count + 1;
            }
        };
        pos = pos + 1;
        checked = checked + 1;
    };

    let cleanup_calls_to_first_expired = if (expired_count == 0) {
        0
    } else {
        (first_expired_offset / constants::max_cleanup_scan_per_call()) + 1
    };

    (checked, expired_count, cleanup_calls_to_first_expired)
}

/// Remove an intent from the index after deletion
fun remove_from_index(
    account: &mut Account,
    registry: &PackageRegistry,
    key: String,
) {
    if (!account::has_managed_data(account, IntentIndexKey {})) {
        return
    };

    let index: &mut IntentIndex = account::borrow_managed_data_mut_with_package_witness(
        account,
        registry,
        IntentIndexKey {},
        version::current(),
    );

    // Remove from expiration times table
    if (table::contains(&index.expiration_times, key)) {
        table::remove(&mut index.expiration_times, key);
    };

    // Remove from keys vector (expensive but necessary)
    let keys = &mut index.keys;
    let len = vector::length(keys);
    let mut i = 0;

    while (i < len) {
        if (*vector::borrow(keys, i) == key) {
            vector::swap_remove(keys, i);

            // After swap_remove, the element that was at len-1 is now at position i.
            // Simply clamp scan_position to be within bounds of the new length.
            // The round-robin scan in find_and_remove_next_expired_intent checks all elements
            // regardless of starting position, so no entries are skipped.
            let new_len = vector::length(keys);
            if (new_len == 0 || index.scan_position >= new_len) {
                index.scan_position = 0;
            };
            break
        };
        i = i + 1;
    };
}
