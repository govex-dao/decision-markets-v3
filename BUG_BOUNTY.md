# Bug Bounty

**Starts: May 7, 2026**

## Scope

Production Move code, excluding tests, in:

- `futarchy_markets_primitives/sources/`
- `futarchy_markets_core/sources/`
- `futarchy_proposal/sources/`
- `futarchy_markets_operations/sources/`
- `futarchy_governance_actions/sources/`
- `futarchy_actions/sources/`
- `futarchy_oracle_actions/sources/`
- `futarchy_one_shot_utils/sources/`

## Rewards

| Severity | Description | Reward |
| -------- | ----------- | ------ |
| Critical | Direct theft of funds by unprivliedged user | $15,000 |
| Critical | Permanent bricking or freezing of funds that doesnt require privledged access or unlikely preconditions| $15,000 |
| Critical | Critical corruption or unauthorized alteration of significant governance outcomes that doesnt require privledged access or unlikely preconditions | $15,000 |

## Rules

- First valid report wins.
- Must include proof-of-concept.
- No public disclosure before a fix is released.
- Test files, scripts, dependencies, generated build artifacts, deployment metadata, and docs are out of scope.
- Code marked `#[test_only]` is out of scope.
- For issues in a repeated pattern, we only pay out for the first report of that pattern.
- Total bug bounty paid across all reports is capped at $30,000.

## Submit

Email: contact@govex.ai

Raw text only. Do not include links or attachments.
