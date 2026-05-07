#[test_only]
module futarchy_markets_primitives::test_conditional_coins;

use sui::coin;

// === Conditional Coin Types for Testing ===
// These are blank coin types used for testing conditional markets
// Pattern: CONDITIONAL_N where N is the sequential index
// Mapping: conditional_0 = outcome 0 asset, conditional_1 = outcome 0 stable,
//          conditional_2 = outcome 1 asset, conditional_3 = outcome 1 stable, etc.
// Each coin type follows the proper OTW pattern with init() function

// === Conditional Coin 0 (Outcome 0 Asset) ===

public struct CONDITIONAL_0 has drop {}

fun init_conditional_0(witness: CONDITIONAL_0, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0, // decimals
        b"", // empty symbol
        b"", // empty name
        b"", // empty description
        option::none(), // no icon url
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_conditional_0_for_testing(ctx: &mut TxContext) {
    init_conditional_0(CONDITIONAL_0 {}, ctx);
}

// === Conditional Coin 1 (Outcome 0 Stable) ===

public struct CONDITIONAL_1 has drop {}

fun init_conditional_1(witness: CONDITIONAL_1, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_conditional_1_for_testing(ctx: &mut TxContext) {
    init_conditional_1(CONDITIONAL_1 {}, ctx);
}

// === Conditional Coin 2 (Outcome 1 Asset) ===

public struct CONDITIONAL_2 has drop {}

fun init_conditional_2(witness: CONDITIONAL_2, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_conditional_2_for_testing(ctx: &mut TxContext) {
    init_conditional_2(CONDITIONAL_2 {}, ctx);
}

// === Conditional Coin 3 (Outcome 1 Stable) ===

public struct CONDITIONAL_3 has drop {}

fun init_conditional_3(witness: CONDITIONAL_3, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_conditional_3_for_testing(ctx: &mut TxContext) {
    init_conditional_3(CONDITIONAL_3 {}, ctx);
}

// === Conditional Coin 4 (Outcome 2 Asset) ===

public struct CONDITIONAL_4 has drop {}

fun init_conditional_4(witness: CONDITIONAL_4, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_conditional_4_for_testing(ctx: &mut TxContext) {
    init_conditional_4(CONDITIONAL_4 {}, ctx);
}

// === Conditional Coin 5 (Outcome 2 Stable) ===

public struct CONDITIONAL_5 has drop {}

fun init_conditional_5(witness: CONDITIONAL_5, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        0,
        b"",
        b"",
        b"",
        option::none(),
        ctx,
    );
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}

#[test_only]
public fun init_conditional_5_for_testing(ctx: &mut TxContext) {
    init_conditional_5(CONDITIONAL_5 {}, ctx);
}
