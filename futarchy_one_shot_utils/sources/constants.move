// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Centralized constants for the Futarchy protocol
/// Uses public functions for upgradability (values can change on package upgrade)
///
/// # Upgrade Safety
/// - NEVER MODIFY: Divisors/scales used in math (would break existing calculations)
/// - Safe to modify: Validation limits, defaults, fees
///
/// # Network-Dependent Constants
/// 11 constants are re-exported from `futarchy_config::network_constants`.
/// The active config is selected via the symlink at `futarchy_config/active/`
/// (default → localnet/testnet values, mainnet → production values).
/// See `packages/scripts/set_network.sh` to switch.
module futarchy_one_shot_utils::constants;

use futarchy_config::constants as network_constants;

// === AMM Fee Constants ===

/// Maximum AMM fee in basis points (5%) - hard cap for steady-state fees
public fun max_amm_fee_bps(): u64 { 500 }

/// Protocol fee in basis points - 0.5% of swap amount (goes to protocol treasury)
public fun protocol_fee_bps(): u64 { 50 }

/// Total fee basis points denominator (100%)
/// NEVER MODIFY - divisor in all fee calculations
public fun total_fee_bps(): u64 { 10000 }

/// Maximum launch fee in basis points (99%) - anti-snipe MEV protection
public fun max_launch_fee_bps(): u64 { 9900 }

// === Protective Bid Constants ===

/// Maximum protective bid fee in basis points (20%).
/// Used by `futarchy_markets_core::protective_bid`.
public fun max_protective_bid_fee_bps(): u64 { 2000 }

/// Maximum protective bid walls per DAO (1 — single bid wall design).
public fun max_protective_bids_per_dao(): u64 { 1 }

/// Maximum protective ask walls per DAO.
public fun max_protective_asks_per_dao(): u64 { 10 }

/// Default conditional AMM fee in basis points (0.25%).
/// Combined with protocol fee (0.50%), default total is 0.75%.
public fun default_conditional_amm_fee_bps(): u64 { 25 }

/// Maximum fee multiplier for governance fee increases (per 6-month baseline window)
public fun max_fee_multiplier(): u64 { 50 }

// === Price Precision Constants ===

/// Price scale for AMM calculations (10^12)
/// NEVER MODIFY - stored prices use this scale
public fun price_scale(): u128 { 1_000_000_000_000 }

/// Price precision scale for calculations (10^12)
/// NEVER MODIFY - existing prices/calculations use this scale
public fun price_precision_scale(): u64 { 1_000_000_000_000 }

/// Parts per million denominator for percentage calculations
/// NEVER MODIFY - divisor in percentage math
public fun ppm_denominator(): u64 { 1_000_000 }

// === Time Constants ===

/// TWAP price cap window in milliseconds (60 seconds)
/// NEVER MODIFY - active oracles depend on this
public fun twap_price_cap_window(): u64 { 60_000 }

/// TWAP threshold base for percentage calculations (100,000 = 100%)
/// NEVER MODIFY - all threshold calculations use this base
public fun twap_threshold_base(): u128 { 100_000 }

/// Maximum sponsored threshold (10% = 10,000 with base 100,000)
public fun max_sponsored_threshold(): u128 { 10000 }

/// One week in milliseconds
public fun one_week_ms(): u64 { 604_800_000 }

/// Three days in milliseconds (for TWAP readiness checks)
public fun three_days_ms(): u64 { 259_200_000 }

/// One day in milliseconds (24 hours)
public fun one_day_ms(): u64 { 86_400_000 }

/// Twelve hours in milliseconds
public fun twelve_hours_ms(): u64 { 43_200_000 }

/// Fifteen minutes in milliseconds (default MEV protection window)
public fun fifteen_minutes_ms(): u64 { 900_000 }

/// Thirty minutes in milliseconds (gap fee decay half-life)
public fun thirty_minutes_ms(): u64 { 1_800_000 }

/// Thirty days in milliseconds (default oracle grant TWAP window)
public fun thirty_days_ms(): u64 { 2_592_000_000 }

/// Six months in milliseconds (180 days - fee governance delay)
public fun six_months_ms(): u64 { 15_552_000_000 }

/// Ten years in milliseconds (maximum oracle grant duration)
public fun ten_years_ms(): u64 { 315_360_000_000 }

// === Governance Constants ===

/// Protocol-level maximum outcomes per proposal
public fun protocol_max_outcomes(): u64 { 50 }

/// Protocol-level maximum actions per single outcome
public fun protocol_max_actions_per_outcome(): u64 { 50 }

/// Default maximum outcomes per proposal for DAOs
public fun default_max_outcomes(): u64 { 2 }

/// Default maximum actions per outcome for DAOs
public fun default_max_actions_per_outcome(): u64 { 50 }

/// Minimum number of outcomes for any proposal
public fun min_outcomes(): u64 { 2 }

/// Minimum review period in milliseconds (network-dependent)
public fun min_review_period_ms(): u64 { network_constants::min_review_period_ms() }

/// Minimum trading period in milliseconds (network-dependent)
public fun min_trading_period_ms(): u64 { network_constants::min_trading_period_ms() }

/// Minimum proposal intent expiry in milliseconds (network-dependent)
public fun min_proposal_intent_expiry_ms(): u64 { network_constants::min_proposal_intent_expiry_ms() }

/// Default proposal intent expiry in milliseconds (30 days)
public fun default_proposal_intent_expiry_ms(): u64 { 2_592_000_000 }

// === Liquidity Constants ===

/// Minimum percentage of liquidity that can move to conditional markets (base 100)
public fun min_conditional_liquidity_percent(): u64 { 1 }

/// Maximum percentage of liquidity that can move to conditional markets (base 100)
public fun max_conditional_liquidity_percent(): u64 { 99 }

/// Default percentage of liquidity that moves to conditional markets (base 100)
public fun default_conditional_liquidity_percent(): u64 { 80 }

// === Treasury & Payment Constants ===

/// Maximum beneficiaries per stream/vesting
public fun max_beneficiaries(): u64 { 100 }

// === Launchpad Constants ===

/// Default launchpad duration for tests only (30 seconds)
/// Production raises set their own duration_ms parameter at creation time
#[test_only]
public fun test_launchpad_duration_ms(): u64 { 60_000 }

/// SUI fee per launchpad buy/bid (network-dependent)
public fun launchpad_bid_fee_per_method_action(): u64 { network_constants::launchpad_bid_fee_per_method_action() }

/// Maximum number of init actions during DAO creation intent (shared for factory + launchpad)
public fun dao_init_max_actions(): u64 { protocol_max_actions_per_outcome() }

/// Maximum number of init actions during launchpad completion intent creation
public fun launchpad_max_init_actions(): u64 { dao_init_max_actions() }

/// Maximum number of init actions during factory DAO initialization
public fun factory_max_init_actions(): u64 { dao_init_max_actions() }

/// DAO init intent expiry in milliseconds (30 days)
public fun dao_init_intent_expiry_ms(): u64 { 2_592_000_000 }

// === Pool Constants ===

/// Minimum liquidity for AMM pools
public fun minimum_liquidity(): u64 { 1_000 }

// === Market Trading Constants ===

/// Maximum trading duration (30 days)
public fun max_trading_duration_ms(): u64 { 2_592_000_000 }

/// Default proposal execution window (30 minutes, but at least network minimum)
public fun execution_window_ms(): u64 {
    let default = 1_800_000;
    let min = network_constants::min_execution_window_ms();
    if (default > min) { default } else { min }
}

/// Minimum execution window (network-dependent)
public fun min_execution_window_ms(): u64 { network_constants::min_execution_window_ms() }

/// Maximum execution window (24 hours)
public fun max_execution_window_ms(): u64 { 86_400_000 }

/// Ninety days in milliseconds (for oracle max duration)
public fun ninety_days_ms(): u64 { 7_776_000_000 }

// === Launchpad Validation Constants ===

/// Maximum unique caps per launchpad
public fun launchpad_max_unique_caps(): u64 { 128 }

/// Maximum batch size for launchpad claims
public fun launchpad_max_batch_size(): u64 { 100 }

/// Maximum affiliate ID length
public fun launchpad_max_affiliate_id_length(): u64 { 64 }

/// Maximum description length for launchpad
public fun launchpad_max_description_length(): u64 { 1000 }

/// Maximum metadata key-value pairs
public fun launchpad_max_metadata_pairs(): u64 { 20 }

/// Maximum reserved allocations per raise
public fun launchpad_max_reservations(): u64 { 50 }

/// Minimum raise duration (network-dependent)
public fun launchpad_min_duration_ms(): u64 { network_constants::launchpad_min_duration_ms() }

/// Maximum raise duration (90 days)
public fun launchpad_max_duration_ms(): u64 { 7_776_000_000 }

/// Maximum start delay before raise begins (30 days)
public fun launchpad_max_start_delay_ms(): u64 { 2_592_000_000 }

// === Oracle Constants ===

/// Maximum oracle grant tiers
public fun max_oracle_tiers(): u64 { 20 }

/// Maximum recipients per oracle tier
public fun max_recipients_per_tier(): u64 { 100 }

/// Maximum TWAP checkpoints to store
public fun max_twap_checkpoints(): u64 { 20 }

/// Default TWAP max movement per window in PPM (1% = 10,000 PPM)
public fun default_twap_max_movement_ppm(): u64 { 10_000 }

// === Governance Limits ===

/// Maximum quota entries per registry
public fun max_quota_entries(): u64 { 50 }

/// Maximum intents cleaned per janitor call
public fun max_cleanup_per_call(): u64 { 20 }

/// Maximum index entries scanned by one janitor search step.
/// Cleanup may delete fewer than max_cleanup_per_call() intents if the scan
/// budget is spent walking live/unexpired entries.
public fun max_cleanup_scan_per_call(): u64 { max_cleanup_per_call() }

/// Threshold for emitting maintenance needed event
public fun maintenance_threshold(): u64 { 10 }

/// Maximum action type strings accepted by package-registry governance actions.
public fun max_package_registry_action_types(): u64 { 50 }

// === Fee Defaults ===

/// Default DAO creation fee (network-dependent)
public fun default_dao_creation_fee(): u64 { network_constants::default_dao_creation_fee() }

/// Default proposal creation fee (network-dependent)
public fun default_proposal_creation_fee(): u64 { network_constants::default_proposal_creation_fee() }

/// Default proposal fee per outcome (network-dependent)
public fun default_proposal_fee_per_outcome(): u64 { network_constants::default_proposal_fee_per_outcome() }

/// Default launchpad creation fee (network-dependent)
public fun default_launchpad_creation_fee(): u64 { network_constants::default_launchpad_creation_fee() }

/// Maximum proposal creation fee (no practical cap — DAOs set their own token-denominated fees)
public fun max_proposal_creation_fee(): u64 { 18_446_744_073_709_551_615 } // u64::MAX

/// Maximum proposal fee per outcome (hard cap)
public fun max_proposal_fee_per_outcome(): u64 { 10_000_000_000 }

/// Protocol minimum liquidity amount (network-dependent)
public fun protocol_min_liquidity_amount(): u64 { network_constants::protocol_min_liquidity_amount() }

/// Default TWAP threshold (0.1% = 100 with base 100,000)
public fun default_twap_threshold(): u64 { 100 }

/// Oracle conditional threshold in basis points (50%)
public fun oracle_conditional_threshold_bps(): u64 { 5000 }

// === Precision Constants ===

/// Fee precision scale for intermediate calculations
public fun fee_precision_scale(): u128 { 100_000 }
