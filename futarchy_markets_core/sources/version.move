// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Version tracking for the futarchy_markets_core package
module futarchy_markets_core::markets_core_version;

use account_protocol::version_witness::{Self, VersionWitness};

// === Constants ===
const VERSION: u64 = 1;

// === Structs ===
public struct V1() has drop;

// === Package-Private Functions ===

/// Get the current version witness for futarchy_markets_core.
/// SECURITY: Package-private to prevent external PTBs from obtaining valid VersionWitnesses.
public(package) fun current(): VersionWitness {
    version_witness::new(V1())
}

/// Get the version number.
public fun get(): u64 {
    VERSION
}

