// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Authorization for spot pool mutation operations.
///
/// Security model:
/// - SpotPoolMutationAuth can only be created via create() which requires a witness
/// - The witness type must come from an authorized package AND match
///   an explicitly allowed module-scoped witness type
/// - This ensures only authorized modules can mutate critical pool state
///
/// Protected operations (require SpotPoolMutationAuth):
/// - set_fee_bps
/// - store_active_escrow
/// - extract_active_escrow
/// - swap_*_with_escrow_extracted
/// - mark_liquidity_to_proposal
/// - remove_liquidity_for_dissolution
module futarchy_markets_core::spot_pool_mutation_auth;

use std::ascii::String as AsciiString;
use std::type_name;
use sui::address;
use sui::event;
use sui::vec_set::{Self, VecSet};

// === Errors ===
const EUnauthorizedWitness: u64 = 0;
const EPackageAlreadyAuthorized: u64 = 1;
const EPackageNotAuthorized: u64 = 2;
const ERegistryCapMismatch: u64 = 3;
// === Constants ===
const ASCII_LT: u8 = 60; // '<'

const WITNESS_STRUCT_NAME: vector<u8> = b"SpotPoolMutationWitness";
const MODULE_PROPOSAL_LIFECYCLE: vector<u8> = b"proposal_lifecycle";
const MODULE_PTB_EXECUTOR: vector<u8> = b"ptb_executor";
const MODULE_LIQUIDITY_ACTIONS: vector<u8> = b"liquidity_actions";
const MODULE_LIQUIDITY_INTERACT: vector<u8> = b"liquidity_interact";
const MODULE_PROPOSAL: vector<u8> = b"proposal";
const MODULE_SWAP_ENTRY: vector<u8> = b"swap_entry";

// === Events ===

public struct SpotPoolMutationAuthorizedPackageAdded has copy, drop {
    package_addr: address,
}

public struct SpotPoolMutationAuthorizedPackageRemoved has copy, drop {
    package_addr: address,
}

// === Structs ===

/// Registry of packages authorized to create SpotPoolMutationAuth.
/// Created during futarchy protocol initialization.
public struct SpotPoolMutationRegistry has key {
    id: UID,
    /// Packages authorized to create SpotPoolMutationAuth (e.g., futarchy_governance, futarchy_actions)
    authorized_packages: VecSet<address>,
}

/// Admin capability for managing the SpotPoolMutationRegistry.
/// Transferred to protocol admin during initialization.
/// The registry_id binds this cap to a specific registry, preventing cross-registry attacks.
public struct SpotPoolMutationAdminCap has key, store {
    id: UID,
    registry_id: ID,
}

/// Authorization witness for spot pool mutation operations.
/// Only packages in the SpotPoolMutationRegistry can create instances.
/// Consumed when calling protected mutation functions in unified_spot_pool.move.
/// Defense-in-depth: target_id binds this auth to a specific pool object.
public struct SpotPoolMutationAuth has drop {
    target_id: ID,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    let registry_uid = object::new(ctx);
    let registry_id = object::uid_to_inner(&registry_uid);
    transfer::transfer(
        SpotPoolMutationAdminCap {
            id: object::new(ctx),
            registry_id,
        },
        ctx.sender(),
    );
    transfer::share_object(SpotPoolMutationRegistry {
        id: registry_uid,
        authorized_packages: vec_set::empty(),
    });
}

// === Admin Functions ===

/// Add a package to the spot-pool-mutation-authorized list.
///
/// Register the exact package address returned by the caller's VersionWitness.
public fun add_authorized_package(
    registry: &mut SpotPoolMutationRegistry,
    cap: &SpotPoolMutationAdminCap,
    package_addr: address,
) {
    // Validate cap is bound to this specific registry
    assert!(object::id(registry) == cap.registry_id, ERegistryCapMismatch);
    assert!(!registry.authorized_packages.contains(&package_addr), EPackageAlreadyAuthorized);
    registry.authorized_packages.insert(package_addr);
    event::emit(SpotPoolMutationAuthorizedPackageAdded { package_addr });
}

/// Remove a package from the spot-pool-mutation-authorized list.
///
/// Removing a package address revokes callers whose VersionWitness resolves to
/// that address.
public fun remove_authorized_package(
    registry: &mut SpotPoolMutationRegistry,
    cap: &SpotPoolMutationAdminCap,
    package_addr: address,
) {
    // Validate cap is bound to this specific registry
    assert!(object::id(registry) == cap.registry_id, ERegistryCapMismatch);
    assert!(registry.authorized_packages.contains(&package_addr), EPackageNotAuthorized);
    registry.authorized_packages.remove(&package_addr);
    event::emit(SpotPoolMutationAuthorizedPackageRemoved { package_addr });
}

// === View Functions ===

/// Check if a package is authorized for spot pool mutation
public fun is_authorized_package(registry: &SpotPoolMutationRegistry, package_addr: address): bool {
    registry.authorized_packages.contains(&package_addr)
}

// === Public Functions ===

/// Create a SpotPoolMutationAuth by providing a witness from an authorized package.
/// The witness type must:
/// 1) come from a package registered in SpotPoolMutationRegistry, and
/// 2) match the canonical SpotPoolMutationWitness type from an allowed module.
///
/// Example usage (in futarchy_governance::proposal_lifecycle):
/// ```
/// struct SpotPoolMutationWitness has drop {}
/// let auth = spot_pool_mutation_auth::create(registry, SpotPoolMutationWitness {});
/// ```
public fun create<W: drop>(registry: &SpotPoolMutationRegistry, _witness: W, target_id: ID): SpotPoolMutationAuth {
    // Verify witness comes from an authorized package
    assert_authorized_witness<W>(registry);
    SpotPoolMutationAuth { target_id }
}

/// Returns the target object ID this auth is bound to
public fun target_id(auth: &SpotPoolMutationAuth): ID {
    auth.target_id
}

// === Internal Functions ===

/// Verify that a witness type comes from an authorized package
/// and matches an explicitly allowed witness type.
fun assert_authorized_witness<W: drop>(registry: &SpotPoolMutationRegistry) {
    let witness_type = type_name::with_original_ids<W>();
    assert!(!type_name::is_primitive(&witness_type), EUnauthorizedWitness);

    // Extract the package address from the type name
    let package_addr_string: AsciiString = type_name::address_string(&witness_type);

    // Convert to address for registry lookup
    let package_addr = address::from_ascii_bytes(package_addr_string.as_bytes());

    // Check if package is in the authorized list
    assert!(is_authorized_package(registry, package_addr), EUnauthorizedWitness);
    assert!(is_allowed_witness_type(&witness_type), EUnauthorizedWitness);
}

fun is_allowed_witness_type(witness_type: &type_name::TypeName): bool {
    let module_name = type_name::module_string(witness_type);
    if (!is_allowed_witness_module(&module_name)) {
        return false
    };

    let struct_name = struct_name_bytes(witness_type);
    &struct_name == &WITNESS_STRUCT_NAME
}

fun is_allowed_witness_module(module_name: &AsciiString): bool {
    let module_bytes = module_name.as_bytes();
    module_bytes == &MODULE_PROPOSAL_LIFECYCLE ||
        module_bytes == &MODULE_PTB_EXECUTOR ||
        module_bytes == &MODULE_LIQUIDITY_ACTIONS ||
        module_bytes == &MODULE_LIQUIDITY_INTERACT ||
        module_bytes == &MODULE_PROPOSAL ||
        module_bytes == &MODULE_SWAP_ENTRY
}

fun struct_name_bytes(witness_type: &type_name::TypeName): vector<u8> {
    let full_type_bytes = type_name::as_string(witness_type).as_bytes();
    let address_len = type_name::address_string(witness_type).as_bytes().length();
    let module_len = type_name::module_string(witness_type).as_bytes().length();
    let start = address_len + 2 + module_len + 2; // <addr>::<module>::

    if (start >= full_type_bytes.length()) {
        return vector[]
    };

    let mut struct_name = vector[];
    let mut i = start;
    while (i < full_type_bytes.length()) {
        let c = full_type_bytes[i];
        if (c == ASCII_LT) {
            break
        };
        struct_name.push_back(c);
        i = i + 1;
    };
    struct_name
}

// === Test Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Create a SpotPoolMutationAuth for testing purposes.
/// This bypasses the package verification and should only be used in tests.
public fun create_for_testing(target_id: ID): SpotPoolMutationAuth {
    SpotPoolMutationAuth { target_id }
}

#[test_only]
/// Create a SpotPoolMutationRegistry for testing purposes.
public fun new_registry_for_testing(ctx: &mut TxContext): SpotPoolMutationRegistry {
    SpotPoolMutationRegistry {
        id: object::new(ctx),
        authorized_packages: vec_set::empty(),
    }
}

#[test_only]
/// Create a SpotPoolMutationAdminCap for testing purposes.
public fun new_admin_cap_for_testing(
    registry: &SpotPoolMutationRegistry,
    ctx: &mut TxContext,
): SpotPoolMutationAdminCap {
    SpotPoolMutationAdminCap {
        id: object::new(ctx),
        registry_id: object::id(registry),
    }
}

#[test_only]
/// Share the registry for testing
public fun share_registry_for_testing(registry: SpotPoolMutationRegistry) {
    transfer::share_object(registry);
}

#[test_only]
/// Destroy registry for testing cleanup
public fun destroy_registry_for_testing(registry: SpotPoolMutationRegistry) {
    let SpotPoolMutationRegistry { id, authorized_packages: _ } = registry;
    object::delete(id);
}

#[test_only]
/// Destroy admin cap for testing cleanup
public fun destroy_admin_cap_for_testing(cap: SpotPoolMutationAdminCap) {
    let SpotPoolMutationAdminCap { id, registry_id: _ } = cap;
    object::delete(id);
}
