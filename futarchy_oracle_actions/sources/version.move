// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Version tracking for the futarchy_oracle package
module futarchy_oracle::oracle_version;

use account_protocol::version_witness::{Self, VersionWitness};

// === Constants ===
const VERSION: u64 = 1;

// === Structs ===
public struct V1() has drop;

// === Package-Private Functions ===

/// Get the current version witness for futarchy_oracle
/// SECURITY: Package-private to prevent external PTBs from obtaining valid VersionWitnesses.
/// Only code within futarchy_oracle can create version witnesses for this package.
public(package) fun current(): VersionWitness {
    version_witness::new(V1())
}

/// Test-only helper for integration tests in dependent packages.
#[test_only]
public fun current_for_testing(): VersionWitness {
    current()
}

// === Public functions ===

public fun get(): u64 {
    VERSION
}
