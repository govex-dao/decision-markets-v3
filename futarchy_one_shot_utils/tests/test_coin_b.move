#[test_only]
module futarchy_one_shot_utils::test_coin_b;

use sui::coin;
use sui::coin_registry::{Self, CoinRegistry};

/// Marker type for test coin (needs key ability for non-OTW new_currency pattern)
public struct TEST_COIN_B has key { id: UID }

/// Initialize test coin using non-OTW Currency standard
/// Uses new_currency (not new_currency_with_otw) which shares Currency directly via finalize
/// Requires CoinRegistry parameter - use coin_registry::create_coin_data_registry_for_testing in tests
#[test_only]
public fun init_for_testing(registry: &mut CoinRegistry, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency<TEST_COIN_B>(
        registry,
        6, // decimals
        b"TEST_B".to_string(), // symbol (immutable)
        b"Test Coin B".to_string(), // name
        b"Test coin for unit tests".to_string(), // description
        b"".to_string(), // icon url
        ctx,
    );

    // finalize with is_otw=false shares Currency directly (inside coin_registry module)
    let metadata_cap = coin_registry::finalize(initializer, ctx);

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}

/// Witness for deprecated coin functions (kept for backward compatibility tests)
public struct TEST_COIN_B_WITNESS has drop {}

#[test_only]
public fun create_with_name(ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B_WITNESS {},
        6,
        b"",
        b"Test Coin Name",
        b"",
        option::none(),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun create_with_description(ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B_WITNESS {},
        6,
        b"",
        b"",
        b"Test description",
        option::none(),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun create_with_symbol(ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B_WITNESS {},
        6,
        b"TST",
        b"",
        b"",
        option::none(),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun create_with_icon(ctx: &mut TxContext) {
    use sui::url;
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B_WITNESS {},
        6,
        b"",
        b"",
        b"",
        option::some(url::new_unsafe_from_bytes(b"https://example.com/icon.png")),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun create_with_all_metadata(ctx: &mut TxContext) {
    use sui::url;
    let (treasury_cap, metadata) = coin::create_currency(
        TEST_COIN_B_WITNESS {},
        6,
        b"TST",
        b"Test Coin",
        b"A test coin",
        option::some(url::new_unsafe_from_bytes(b"https://example.com/icon.png")),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}
