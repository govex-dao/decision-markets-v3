# Decision Markets

This is a configuration of the [Sui smart account](https://github.com/govex-dao/smart-account-v3) that orchestrates actions based on their predicted impact on an organization's token price. The token price TWAP is read frin an internal `x*y=k` style AMM. This AMM splits liquidity across spot and conditional market outcomes to keep decisions high-signal. 

This package implements various organizational lifecycle steps as smart-account-compatible actions, namely: dissolution, price-based unlocks, fundraising, and buybacks. 

Use and interact with this software at your own risk. This code has not been independently audited and may contain bugs, vulnerabilities, or other defects. It is provided “as is,” without warranties of any kind. You are responsible for reviewing, testing, and determining its suitability for your intended use.
