# DEX Aggregator Integration Help

This note is for DEX aggregators and indexers that want exact quoting and execution for the Govex spot AMM, including the live-proposal path.

## Mainnet Packages

- `futarchy_markets_core`: `0x9a470e2a272f1aa1f81f5cd2a3066f878fffd9ce9c8d22309ad62f81e5b77dd2`
- `futarchy_markets_operations`: `0x7279de2610213cdc1da0945f41f7ef7a58abf343e88165fb443be60f066e00a2`
- `futarchy_markets_primitives`: `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781`
- `futarchy_core`: `0xd515e9008496dd209ffb71caf0e5783073385cde00083c8a1437a32093aab95c`

## Objects To Track For DEX Aggregator

objects to track for dex aggregator: `0x9a470e2a272f1aa1f81f5cd2a3066f878fffd9ce9c8d22309ad62f81e5b77dd2::unified_spot_pool::UnifiedSpotPool<AssetType, StableType, LPType>`, nested inside it when a proposal is live: `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781::coin_escrow::TokenEscrow<AssetType, StableType>`, nested inside that escrow: `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781::market_state::MarketState`, nested inside that market state: `vector<0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781::conditional_amm::LiquidityPool>`, optional user carry object for DCA / repeated routing: `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781::conditional_balance::ConditionalMarketBalance<AssetType, StableType>`, execution shared objects: `0x9a470e2a272f1aa1f81f5cd2a3066f878fffd9ce9c8d22309ad62f81e5b77dd2::spot_pool_mutation_auth::SpotPoolMutationRegistry`, `0xd515e9008496dd209ffb71caf0e5783073385cde00083c8a1437a32093aab95c::escrow_mutation_auth::EscrowMutationRegistry`, `0xd515e9008496dd209ffb71caf0e5783073385cde00083c8a1437a32093aab95c::market_state_mutation_auth::MarketStateMutationRegistry`, `0x6::clock::Clock`.

The short version: one shared `UnifiedSpotPool` is the main object to index. During live proposals, the escrow, market state, and conditional pools are wrapped inside that spot pool object. They are not separate shared pool objects.

## Spot Entry Functions

There are two user-facing spot swap functions for aggregator execution:

```move
0x7279de2610213cdc1da0945f41f7ef7a58abf343e88165fb443be60f066e00a2::swap_entry::swap_spot_stable_to_asset<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    recipient: address,
    existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    return_balance: bool,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (
    option::Option<Coin<AssetType>>,
    option::Option<ConditionalMarketBalance<AssetType, StableType>>,
)
```

```move
0x7279de2610213cdc1da0945f41f7ef7a58abf343e88165fb443be60f066e00a2::swap_entry::swap_spot_asset_to_stable<AssetType, StableType, LPType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType, LPType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    recipient: address,
    existing_balance_opt: option::Option<ConditionalMarketBalance<AssetType, StableType>>,
    return_balance: bool,
    spot_pool_mutation_registry: &SpotPoolMutationRegistry,
    escrow_registry: &EscrowMutationRegistry,
    market_state_registry: &MarketStateMutationRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (
    option::Option<Coin<StableType>>,
    option::Option<ConditionalMarketBalance<AssetType, StableType>>,
)
```

Use these two `swap_entry` functions for the full aggregator path. The lower-level `unified_spot_pool::swap_stable_for_asset` and `unified_spot_pool::swap_asset_for_stable` functions only cover the direct spot leg and do not fully handle active proposal routing through wrapped conditional markets.

## Price State Needed

For the direct spot leg, quote from `UnifiedSpotPool` fields:

- `asset_reserve`
- `stable_reserve`
- `fee_bps`
- `fee_schedule`
- `fee_schedule_activation_time`
- `active_proposal_id`
- `is_dissolved`

When `aggregator_config.active_escrow` is present and its `MarketState` allows swaps at the current `Clock`, exact route price also depends on:

- `TokenEscrow.escrowed_asset`
- `TokenEscrow.escrowed_stable`
- `MarketState.status`
- `MarketState.trading_end`
- `MarketState.execution_deadline`
- every `LiquidityPool.asset_reserve`
- every `LiquidityPool.stable_reserve`
- every `LiquidityPool.fee_percent`

The live route searches for the best split between direct spot and the conditional route. The conditional route uses all outcome pools and takes the minimum output across outcomes, capped by escrow backing.
