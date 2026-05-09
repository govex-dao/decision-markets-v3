# DEX Aggregator Integration Help

For exact Govex spot AMM quoting and execution, use the object and function lists below.

During live proposals, the spot pool wraps the escrow, market state, and conditional AMM pools. Indexers should decode the shared `UnifiedSpotPool` object deeply.

## Package IDs

| Name | ID |
| --- | --- |
| `futarchy_markets_core` | `0x9a470e2a272f1aa1f81f5cd2a3066f878fffd9ce9c8d22309ad62f81e5b77dd2` |
| `futarchy_markets_operations` | `0x7279de2610213cdc1da0945f41f7ef7a58abf343e88165fb443be60f066e00a2` |
| `futarchy_markets_primitives` | `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781` |
| `futarchy_core` | `0xd515e9008496dd209ffb71caf0e5783073385cde00083c8a1437a32093aab95c` |

## Objects To Track For DEX Aggregator

| Name | ID | Type |
| --- | --- | --- |
| Spot pool | `pool_id` from `DaoSpotPoolCreated` or DAO config `spot_pool_id` | `0x9a470e2a272f1aa1f81f5cd2a3066f878fffd9ce9c8d22309ad62f81e5b77dd2::unified_spot_pool::UnifiedSpotPool<AssetType, StableType, LPType>` |
| Active escrow, live proposals only | `UnifiedSpotPool.aggregator_config.active_escrow.id` | `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781::coin_escrow::TokenEscrow<AssetType, StableType>` |
| Market state, live proposals only | `TokenEscrow.market_state.id` | `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781::market_state::MarketState` |
| Conditional AMM pools, live proposals only | Each `MarketState.amm_pools[i].id` | `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781::conditional_amm::LiquidityPool` |
| User carry balance, optional | User-provided object ID | `0x844fcce6ab4bbfb44b09431b0f07765d671d2aee3122f578b15b2402c2033781::conditional_balance::ConditionalMarketBalance<AssetType, StableType>` |
| Spot pool mutation registry | `0xe7b10d3e9d0dd9241c6742c7b470bcad8a47725a532da141e565fc3f55f9feed` | `0x9a470e2a272f1aa1f81f5cd2a3066f878fffd9ce9c8d22309ad62f81e5b77dd2::spot_pool_mutation_auth::SpotPoolMutationRegistry` |
| Escrow mutation registry | `0x66493dc8caccb6f301a5c73f3ea4ecd53657634e9ceae0a9d4fab37f4f8a7441` | `0xd515e9008496dd209ffb71caf0e5783073385cde00083c8a1437a32093aab95c::escrow_mutation_auth::EscrowMutationRegistry` |
| Market state mutation registry | `0xe9c4f8839e047def9df9bc6589c5a6fa7d0f94a7494932fc8e7230255772c485` | `0xd515e9008496dd209ffb71caf0e5783073385cde00083c8a1437a32093aab95c::market_state_mutation_auth::MarketStateMutationRegistry` |
| Sui clock | `0x6` | `0x2::clock::Clock` |

## Spot Entry Functions

| Name | ID | Type |
| --- | --- | --- |
| Stable to asset spot swap | `0x7279de2610213cdc1da0945f41f7ef7a58abf343e88165fb443be60f066e00a2` | `0x7279de2610213cdc1da0945f41f7ef7a58abf343e88165fb443be60f066e00a2::swap_entry::swap_spot_stable_to_asset<AssetType, StableType, LPType>` |
| Asset to stable spot swap | `0x7279de2610213cdc1da0945f41f7ef7a58abf343e88165fb443be60f066e00a2` | `0x7279de2610213cdc1da0945f41f7ef7a58abf343e88165fb443be60f066e00a2::swap_entry::swap_spot_asset_to_stable<AssetType, StableType, LPType>` |

Use these two `swap_entry` functions for the full aggregator path. The lower-level `unified_spot_pool::swap_stable_for_asset` and `unified_spot_pool::swap_asset_for_stable` functions only cover the direct spot leg and do not fully handle active proposal routing through wrapped conditional markets.
