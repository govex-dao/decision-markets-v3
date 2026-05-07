#[test_only]
module futarchy_one_shot_utils::test_coin_a;

use sui::coin_registry::{Self, CoinRegistry};

/// Marker type for test coin (needs key ability for non-OTW new_currency pattern)
public struct TEST_COIN_A has key { id: UID }

/// Initialize test coin using non-OTW Currency standard
/// Uses new_currency (not new_currency_with_otw) which shares Currency directly via finalize
/// Requires CoinRegistry parameter - use coin_registry::create_coin_data_registry_for_testing in tests
#[test_only]
public fun init_for_testing(registry: &mut CoinRegistry, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency<TEST_COIN_A>(
        registry,
        6, // decimals
        b"TEST_A".to_string(), // symbol (immutable)
        b"Test Coin A".to_string(), // name
        b"Test coin for unit tests".to_string(), // description
        b"".to_string(), // icon url
        ctx,
    );

    // finalize with is_otw=false shares Currency directly (inside coin_registry module)
    let metadata_cap = coin_registry::finalize(initializer, ctx);

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
