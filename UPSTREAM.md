# Upstream boundary

This fork was cut from `hledgerorg/hledger` commit
`c4a04b17f616ab0accc2ec5ec8e1c9cce1c8ec24` (hledger 1.99 development tree).
The Git remote named `upstream` points at `https://github.com/hledgerorg/hledger.git`.

The retained `hledger-lib` modules are the transitive source closure required for:

- native journal parsing and `include` directives;
- amount inference, transaction balancing, assertions, and journal checks;
- account/query/date/commodity/lot semantics;
- balance and register reports.

The fork intentionally removes CLI, TUI, web, alternate CSV/timeclock/timedot readers,
output renderers, release infrastructure, examples, and upstream product tests. When
syncing upstream, port accounting-core fixes into `hledger-lib`, keep
`Hledger.Read.JournalReader` journal-only, then run the MCP build and protocol smoke
checks described in the project README.
