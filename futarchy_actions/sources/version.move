// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Version tracking for the futarchy_actions package
module futarchy_actions::futarchy_actions_version;

use account_protocol::version_witness::{Self, VersionWitness};

// === Constants ===
const VERSION: u64 = 1;

// === Structs ===
public struct V1() has drop;

// === Package-Private Functions ===

/// Get the current version witness for futarchy_actions
/// SECURITY: Package-private to prevent external PTBs from obtaining valid VersionWitnesses.
/// Only code within futarchy_actions can create version witnesses for this package.
public(package) fun current(): VersionWitness {
    version_witness::new(V1())
}

/// Get the version number
public fun get(): u64 {
    VERSION
}
