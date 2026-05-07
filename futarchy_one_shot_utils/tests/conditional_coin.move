#[test_only]
/// Test coin module with a valid "conditional_N" module name
/// This module name matches the pattern "conditional_N" required by blank_coins
/// Uses coin_registry::new_currency for non-OTW pattern (shares Currency directly)
module conditional_coin::conditional_99;

use sui::coin_registry::{Self, CoinRegistry};

/// Marker type for CONDITIONAL_0 coin (needs key ability for new_currency)
public struct CONDITIONAL_0 has key { id: UID }

/// Decimals for this test coin (9 = asset decimals)
const DECIMALS: u8 = 9;

/// Initialize for testing - creates conditional coin with standard symbol
/// Uses new_currency (non-OTW) which shares Currency directly via finalize
/// Transfers both TreasuryCap and MetadataCap - MetadataCap needed for deposit_coin_set
#[test_only]
public fun init_for_testing_with_registry(registry: &mut CoinRegistry, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency<CONDITIONAL_0>(
        registry,
        DECIMALS,
        b"Govex Conditional".to_string(), // Symbol (IMMUTABLE) - standard for all conditional coins
        b"".to_string(), // empty name (set by proposal.move)
        b"".to_string(), // empty description (set by proposal.move)
        b"".to_string(), // empty icon_url (set by proposal.move)
        ctx,
    );

    // finalize with is_otw=false shares Currency directly
    let metadata_cap = coin_registry::finalize(initializer, ctx);

    // Transfer TreasuryCap and MetadataCap to sender for deposit into BlankCoinsRegistry
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}

/// Get the decimals for this coin (for use in tests)
#[test_only]
public fun decimals(): u8 {
    DECIMALS
}
