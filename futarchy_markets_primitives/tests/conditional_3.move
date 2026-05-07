#[test_only]
module futarchy_markets_primitives::conditional_3;

use sui::coin_registry::{Self, CoinRegistry};

/// Marker type for CONDITIONAL_3 (needs key ability for non-OTW new_currency pattern)
public struct CONDITIONAL_3 has key { id: UID }

/// Initialize test conditional coin using non-OTW Currency standard
/// Uses new_currency (not new_currency_with_otw) which shares Currency directly via finalize
/// Requires CoinRegistry parameter - use coin_registry::create_coin_data_registry_for_testing in tests
#[test_only]
public fun init_for_testing(registry: &mut CoinRegistry, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency<CONDITIONAL_3>(
        registry,
        6, // decimals matching stable token
        b"Govex Conditional".to_string(),
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    // finalize with is_otw=false shares Currency directly (inside coin_registry module)
    let metadata_cap = coin_registry::finalize(initializer, ctx);
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
