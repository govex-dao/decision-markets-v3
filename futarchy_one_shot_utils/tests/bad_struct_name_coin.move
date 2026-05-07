#[test_only]
/// Test coin with MISMATCHED struct name for testing struct name validation
/// Module is conditional_98 but struct is WRONG_NAME (should be CONDITIONAL_98)
module futarchy_one_shot_utils::conditional_98;

use sui::coin_registry::{Self, CoinRegistry};

/// Deliberately mismatched struct name to test validation rejection
public struct WRONG_NAME has key { id: UID }

const DECIMALS: u8 = 9;

#[test_only]
public fun init_for_testing_with_registry(registry: &mut CoinRegistry, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency<WRONG_NAME>(
        registry,
        DECIMALS,
        b"Govex Conditional".to_string(),
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );

    let metadata_cap = coin_registry::finalize(initializer, ctx);

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
