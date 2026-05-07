// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Utilities for conditional tokens:
/// - Validation (treasury cap, supply checks)
/// - Metadata generation and updates for conditional coins
/// - Helper functions for building coin names/symbols
module futarchy_proposal::conditional_coin_utils;

use futarchy_core::dao_config::ConditionalCoinConfig;
use std::ascii::{Self, String as AsciiString};
use std::string::{Self, String};
use std::vector;
use sui::coin::TreasuryCap;
use sui::coin_registry::{Self, Currency, MetadataCap};

// === Errors ===
const ESupplyNotZero: u64 = 0;

// === Validation Functions ===

/// Validates that a coin's total supply is zero
public fun assert_zero_supply<T>(treasury_cap: &TreasuryCap<T>) {
    assert!(treasury_cap.total_supply() == 0, ESupplyNotZero);
}

/// Check if supply is zero without aborting
public fun is_supply_zero<T>(treasury_cap: &TreasuryCap<T>): bool {
    treasury_cap.total_supply() == 0
}

// === Metadata Update Functions ===

/// Update conditional Currency<T> metadata with DAO naming pattern
/// Uses MetadataCap to update name, description, and icon
/// Note: Symbol is IMMUTABLE - it's set to "Govex Conditional" at coin creation
/// Icon copied from base coin, description includes DAO name
public fun update_conditional_metadata<ConditionalCoinType>(
    currency: &mut Currency<ConditionalCoinType>,
    metadata_cap: &MetadataCap<ConditionalCoinType>,
    _coin_config: &ConditionalCoinConfig, // Kept for API compatibility, symbol logic removed
    outcome_index: u64,
    dao_name: &AsciiString,
    base_coin_name: &String,
    _base_coin_symbol: &AsciiString, // Kept for API compatibility, no longer used for symbol
    base_icon_url: &String,
) {
    // Symbol is IMMUTABLE - set to "Govex Conditional" at coin creation
    // No need to build or update symbol here

    // Build conditional coin name (human-readable)
    // Example: "Conditional 0: Sui", "Conditional 1: USD Coin"
    let name_str = build_conditional_name(outcome_index, base_coin_name);

    // Build description with DAO name
    // Example: "Conditional coin for Govex. Outcome 0 redeemable for Sui if this outcome wins."
    let description_str = build_conditional_description(dao_name, outcome_index, base_coin_name);

    // Update Currency<T> metadata using MetadataCap (new Sui Currency standard)
    // Symbol cannot be updated - it's immutable
    coin_registry::set_name(currency, metadata_cap, name_str);
    coin_registry::set_description(currency, metadata_cap, description_str);

    // Copy icon URL from base currency to conditional coin
    // This ensures conditional coins visually match their base asset/stable
    if (!base_icon_url.is_empty()) {
        coin_registry::set_icon_url(currency, metadata_cap, *base_icon_url);
    };
}

// === Helper Functions ===

/// Build conditional coin symbol as ASCII: prefix + outcome_index + _ + base_symbol
/// Example: "c_0_SUI", "c_1_USDC"
/// Returns ASCII string for use with old CoinMetadata pattern
public fun build_conditional_symbol_ascii(
    coin_config: &ConditionalCoinConfig,
    outcome_index: u64,
    base_coin_symbol: &AsciiString,
): AsciiString {
    use futarchy_core::dao_config;

    let mut symbol_bytes = vector::empty<u8>();

    // Add prefix (e.g., "c_") if configured
    let prefix_opt = dao_config::coin_name_prefix(coin_config);
    if (prefix_opt.is_some()) {
        let prefix = prefix_opt.destroy_some();
        let prefix_bytes_val = ascii::as_bytes(&prefix);
        vector::append(&mut symbol_bytes, *prefix_bytes_val);
    } else {
        prefix_opt.destroy_none();
    };

    // Add outcome index if configured
    if (dao_config::use_outcome_index(coin_config)) {
        vector::append(&mut symbol_bytes, u64_to_string(outcome_index));
        vector::push_back(&mut symbol_bytes, 95); // '_' = ASCII 95
    };

    // Add base coin symbol (e.g., "SUI", "USDC")
    let base_bytes = ascii::as_bytes(base_coin_symbol);
    vector::append(&mut symbol_bytes, *base_bytes);

    ascii::string(symbol_bytes)
}

/// Build conditional coin symbol as UTF-8: prefix + outcome_index + _ + base_symbol
/// Example: "c_0_SUI", "c_1_USDC"
/// Returns UTF-8 string for logging/display
public fun build_conditional_symbol(
    coin_config: &ConditionalCoinConfig,
    outcome_index: u64,
    base_coin_symbol: &String,
): String {
    use futarchy_core::dao_config;

    let mut symbol_str = string::utf8(b"");

    // Add prefix (e.g., "c_") if configured
    let prefix_opt = dao_config::coin_name_prefix(coin_config);
    if (prefix_opt.is_some()) {
        let prefix = prefix_opt.destroy_some();
        let prefix_bytes = ascii::as_bytes(&prefix);
        string::append_utf8(&mut symbol_str, *prefix_bytes);
    } else {
        prefix_opt.destroy_none();
    };

    // Add outcome index if configured
    if (dao_config::use_outcome_index(coin_config)) {
        string::append_utf8(&mut symbol_str, u64_to_string(outcome_index));
        string::append_utf8(&mut symbol_str, b"_");
    };

    // Add base coin symbol (e.g., "SUI", "USDC")
    string::append(&mut symbol_str, *base_coin_symbol);

    symbol_str
}

/// Build conditional coin name (human-readable)
/// Example: "Conditional 0: Sui", "Conditional 1: USD Coin"
public fun build_conditional_name(outcome_index: u64, base_coin_name: &String): String {
    let mut name_str = string::utf8(b"Conditional ");
    string::append_utf8(&mut name_str, u64_to_string(outcome_index));
    string::append_utf8(&mut name_str, b": ");
    string::append(&mut name_str, *base_coin_name);
    name_str
}

/// Build conditional coin description with DAO name
/// Example: "Conditional coin for Govex. Outcome 0 redeemable for Sui if this outcome wins."
public fun build_conditional_description(
    dao_name: &AsciiString,
    outcome_index: u64,
    base_coin_name: &String,
): String {
    let mut description_str = string::utf8(b"Conditional coin for ");
    // Append DAO name (convert ASCII to UTF-8)
    string::append_utf8(&mut description_str, *ascii::as_bytes(dao_name));
    string::append_utf8(&mut description_str, b". Outcome ");
    string::append_utf8(&mut description_str, u64_to_string(outcome_index));
    string::append_utf8(&mut description_str, b" redeemable for ");
    string::append(&mut description_str, *base_coin_name);
    string::append_utf8(&mut description_str, b" if this outcome wins.");
    description_str
}

/// Convert u64 to UTF-8 string (for use in names/descriptions)
public fun u64_to_string(mut num: u64): vector<u8> {
    if (num == 0) {
        return b"0"
    };

    let mut digits = vector::empty<u8>();
    while (num > 0) {
        let digit = ((num % 10) as u8) + 48; // ASCII '0' = 48
        vector::push_back(&mut digits, digit);
        num = num / 10;
    };

    // Reverse digits
    vector::reverse(&mut digits);
    digits
}

/// Convert u64 to ASCII string
public fun u64_to_ascii(num: u64): AsciiString {
    ascii::string(u64_to_string(num))
}
