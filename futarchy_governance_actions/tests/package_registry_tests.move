#[test_only]
module futarchy_governance_actions::package_registry_tests;

use futarchy_governance_actions::package_registry_actions;

// Tests for package registry action markers.
// Full integration tests with governance execution are in action_tests package.

// === Marker Function Tests ===

#[test]
fun test_add_package_marker() {
    let marker = package_registry_actions::add_package_marker();
    let _ = marker;
}

#[test]
fun test_update_package_metadata_marker() {
    let marker = package_registry_actions::update_package_metadata_marker();
    let _ = marker;
}
