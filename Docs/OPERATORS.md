# Swift mutation operators

The operator IDs are defined by the shared spec repository's `operators/catalog.json`. This file documents this Swift implementation's current syntax coverage and campaign policy. Tiers belong to this implementation and do not transfer to another language engine.

## Syntax coverage

| Operator | Current Swift rewrite | Current eligibility and limits |
|---|---|---|
| `relational` | `<` → `<=` or `>`, `<=` → `<` or `>=`, `>` → `>=` or `<`, `>=` → `>` or `<=`, `==` ↔ `!=` | Infix comparisons parsed by SwiftSyntax. Identity comparisons (`===`, `!==`) are not mutated. A type-invalid rewrite becomes unbuildable after isolated fallback. |
| `boolean` | `true` ↔ `false` | Boolean literal expressions, except literals used in an exhaustive Boolean `switch` pattern. |
| `logical` | `&&` ↔ `||` | Infix logical operators. Each operator occurrence is a separate first-order mutant. |
| `arithmetic` | `+` ↔ `-`, `*` ↔ `/`, `%` → `*` | Infix arithmetic operators. Type and division-by-zero behavior is not statically proven; compile failures are unbuildable, runtime failures produce normal mutant test verdicts, and hung tests use the configured timeout. |
| `negateConditional` | `condition` → `!(condition)` | Expression conditions in `if`, `guard`, and `while`, including each expression in a multi-condition clause. Pattern-binding conditions are not generated. |
| `swapTernary` | `condition ? then : else` → `condition ? else : then` | Swift ternary expressions with different branch expressions. The complete parsed condition is kept intact. |
| `removeSideEffects` | A standalone call statement is skipped when its mutant ID is active | Standalone function-call expressions in code-block statements, except `print`, `debugPrint`, assertion/precondition/fatal-error calls, `self.init`, and `super.init`. Calls that are the sole statement in a body are skipped. The engine does not infer whether other calls are pure; equivalent survivors should be reviewed. |

Overlapping source spans are not combined into one schema; they are built and tested as isolated mutants. Unsupported syntax is skipped and does not increase the generated mutant count.

## Campaign tiers

All seven operators remain **experimental**. Automated tests exercise syntax and runner behavior; they are not evidence for tier promotion.

Promotion requires a repeatable campaign over at least three real Swift packages, with at least ten generated mutants per operator in each package. Record generated, unbuildable, killed, survived, no-coverage, and timed-out counts. Review surviving mutants to estimate the equivalent-survivor rate. Use the median kill rate across packages and the thresholds in the shared spec:

- `conservative`: median kill rate at least 70%, unviable rate at most 5%, reviewed equivalent-survivor rate at most 10%.
- `default`: median kill rate at least 40%, unviable rate at most 15%, reviewed equivalent-survivor rate at most 25%.
- Operators that do not meet the default threshold or lack enough campaign data stay `experimental`.

Each engine release should publish its package set, operator counts, reviewed equivalence decisions, and per-operator tier changes. Tier claims are versioned per implementation.
