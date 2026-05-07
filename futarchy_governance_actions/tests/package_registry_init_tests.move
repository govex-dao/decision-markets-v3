#[test_only]
module futarchy_governance_actions::package_registry_init_tests;

use account_actions::action_spec_builder;
use account_protocol::constants as account_constants;
use futarchy_governance_actions::package_registry_init_actions;
use futarchy_one_shot_utils::constants;

fun too_long_metadata_string(): std::string::String {
    let mut bytes = vector::empty<u8>();
    let mut i = 0u64;
    while (i <= account_constants::max_action_data_size()) {
        bytes.push_back(97);
        i = i + 1;
    };
    bytes.to_string()
}

fun too_many_action_types(): vector<std::string::String> {
    let mut action_types = vector::empty<std::string::String>();
    let mut i = 0u64;
    while (i <= constants::max_package_registry_action_types()) {
        action_types.push_back(b"Action".to_string());
        i = i + 1;
    };
    action_types
}

// Tests for package registry init action spec builders.
// These test the Layer 2 spec building functions.

// === Spec Builder Tests ===

#[test]
fun test_add_add_package_spec() {
    let mut builder = action_spec_builder::new_for_testing();
    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"TestPackage".to_string(),
        @0x123,
        1,
        vector[b"TestAction".to_string()],
        b"Governance".to_string(),
        b"Test package".to_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}

#[test]
fun test_add_add_package_spec_empty_actions() {
    let mut builder = action_spec_builder::new_for_testing();
    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"MinimalPackage".to_string(),
        @0x456,
        1,
        vector::empty(),
        b"Core".to_string(),
        b"Minimal package".to_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}

#[test]
fun test_add_add_package_spec_many_actions() {
    let mut builder = action_spec_builder::new_for_testing();
    let mut action_types = vector::empty<std::string::String>();
    let mut i = 0u64;
    while (i < 10) {
        action_types.push_back(b"Action".to_string());
        i = i + 1;
    };

    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"BigPackage".to_string(),
        @0x789,
        1,
        action_types,
        b"Actions".to_string(),
        b"Package with many actions".to_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}

#[test]
fun test_add_update_package_metadata_spec() {
    let mut builder = action_spec_builder::new_for_testing();
    package_registry_init_actions::add_update_package_metadata_spec(
        &mut builder,
        b"TestPackage".to_string(),
        vector[b"UpdatedAction".to_string()],
        b"Updated Category".to_string(),
        b"Updated description".to_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}

// === Multiple Actions Tests ===

#[test]
fun test_multiple_package_actions() {
    let mut builder = action_spec_builder::new_for_testing();
    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"Package1".to_string(),
        @0x1,
        1,
        vector[],
        b"Cat1".to_string(),
        b"Desc1".to_string(),
    );
    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"Package2".to_string(),
        @0x2,
        1,
        vector[],
        b"Cat2".to_string(),
        b"Desc2".to_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 2, 0);
}

// === Edge Case Tests ===

#[test]
fun test_package_unicode_name() {
    let mut builder = action_spec_builder::new_for_testing();
    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"Paquet_\xc3\xa9".to_string(),
        @0x200,
        1,
        vector[],
        b"Unicode".to_string(),
        b"Package with unicode name".to_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}

#[test]
fun test_package_long_description() {
    let mut builder = action_spec_builder::new_for_testing();
    let long_desc = b"This is a very long description that contains many words and sentences to test the handling of long string fields.".to_string();
    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"VerbosePackage".to_string(),
        @0x300,
        1,
        vector[],
        b"Verbose".to_string(),
        long_desc,
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}

#[test]
fun test_package_version_zero() {
    let mut builder = action_spec_builder::new_for_testing();
    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"UnpublishedPackage".to_string(),
        @0x400,
        0,
        vector[],
        b"Dev".to_string(),
        b"Not yet published".to_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}

#[test, expected_failure(abort_code = 1, location = futarchy_governance_actions::package_registry_init_actions)]
fun test_add_package_spec_rejects_too_many_action_types() {
    let mut builder = action_spec_builder::new_for_testing();
    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"TooManyActions".to_string(),
        @0x500,
        1,
        too_many_action_types(),
        b"Actions".to_string(),
        b"Too many action types".to_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}

#[test, expected_failure(abort_code = 2, location = futarchy_governance_actions::package_registry_init_actions)]
fun test_add_package_spec_rejects_long_metadata() {
    let mut builder = action_spec_builder::new_for_testing();
    package_registry_init_actions::add_add_package_spec(
        &mut builder,
        b"LongMetadata".to_string(),
        @0x600,
        1,
        vector[],
        b"Metadata".to_string(),
        too_long_metadata_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}

#[test]
fun test_update_metadata_clear_actions() {
    let mut builder = action_spec_builder::new_for_testing();
    package_registry_init_actions::add_update_package_metadata_spec(
        &mut builder,
        b"ClearedPackage".to_string(),
        vector::empty(),
        b"NoActions".to_string(),
        b"Cleared action types".to_string(),
    );
    let specs = action_spec_builder::into_vector(builder);
    assert!(specs.length() == 1, 0);
}
