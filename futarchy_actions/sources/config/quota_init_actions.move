// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for quota management operations.
/// These can be staged in intents for proposals.
module futarchy_actions::quota_init_actions;

use account_actions::action_spec_builder;
use account_protocol::action_events;
use account_protocol::intents;
use std::type_name;
use sui::bcs;

// === Layer 2: Spec Builder Functions ===

/// Add set quotas action to the spec builder
/// Allows batch setting of proposal quotas for multiple addresses
/// period_ms: shared period for both quota types
/// feeless_proposal_amount: N free proposals per period (0 = no feeless quota)
/// sponsor_amount: N TWAP sponsorships per period (0 = no sponsor quota)
public fun add_set_quotas_spec(
    builder: &mut action_spec_builder::Builder,
    users: vector<address>,
    period_ms: u64,
    feeless_proposal_amount: u64,
    sponsor_amount: u64,
) {
    // Capture action_index BEFORE adding spec
    let action_index = action_spec_builder::next_action_index(builder);

    let action = futarchy_actions::quota_actions::new_set_quotas(
        users,
        period_ms,
        feeless_proposal_amount,
        sponsor_amount,
    );
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        futarchy_actions::quota_actions::set_quotas_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

    // Emit ActionParamsStaged event
    let mut params = action_events::new_builder();
    action_events::add_vector_address(&mut params, b"users", &users);
    action_events::add_u64(&mut params, b"period_ms", period_ms);
    action_events::add_u64(&mut params, b"feeless_proposal_amount", feeless_proposal_amount);
    action_events::add_u64(&mut params, b"sponsor_amount", sponsor_amount);
    action_events::emit_action_params(
        params,
        action_spec_builder::source_type(builder),
        action_spec_builder::source_id(builder),
        action_spec_builder::outcome_index(builder),
        type_name::with_original_ids<futarchy_actions::quota_actions::SetQuotas>().into_string().to_string(),
        action_index,
    );
}
