// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

#[test_only]
module futarchy_proposal::not_conditional;

use sui::coin_registry::{Self, CoinRegistry};
use sui::object::UID;

public struct NOT_CONDITIONAL has key { id: UID }

public fun init_for_testing_with_registry(registry: &mut CoinRegistry, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency<NOT_CONDITIONAL>(
        registry,
        9,
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
