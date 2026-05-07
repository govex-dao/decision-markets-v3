#[test_only]
module futarchy_markets_primitives::conditional_0;

use sui::coin_registry::{Self, CoinRegistry};

/// Marker type for CONDITIONAL_0 (needs key ability for non-OTW new_currency pattern)
public struct CONDITIONAL_0 has key { id: UID }

/// Initialize test conditional coin using non-OTW Currency standard
/// Uses new_currency (not new_currency_with_otw) which shares Currency directly via finalize
/// Requires CoinRegistry parameter - use coin_registry::create_coin_data_registry_for_testing in tests
#[test_only]
public fun init_for_testing(registry: &mut CoinRegistry, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency<CONDITIONAL_0>(
        registry,
        9, // decimals matching base asset token
        b"Govex Conditional".to_string(), // Symbol (IMMUTABLE) - same for all conditional coins
        b"".to_string(), // Empty name (set by proposal.move)
        b"".to_string(), // Empty description (set by proposal.move)
        b"".to_string(), // Empty icon_url (set by proposal.move)
        ctx,
    );

    // finalize with is_otw=false shares Currency directly (inside coin_registry module)
    let metadata_cap = coin_registry::finalize(initializer, ctx);

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
