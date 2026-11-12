# hledger-mcp

An agent-native plain-text accounting server built directly on the hledger engine.

This fork intentionally keeps `hledger-lib` as the accounting utility and replaces
the CLI/TUI/web product surface with one compact MCP executable. Agents translate
plain-language bookkeeping instructions into typed double-entry transactions; the
embedded hledger engine parses, balances, validates, reports, and persists them.

Prebuilt releases install without Haskell and initialize a conventional included-file
workspace with a chart of accounts, opening balances, and yearly transaction journals.

See [hledger-mcp/README.md](hledger-mcp/README.md) for build, configuration, and tool
details.

## Repository shape

```text
hledger-lib/   upstream accounting engine
hledger-mcp/   thin MCP protocol and accounting-tool layer
```

The project remains GPL-3.0-or-later and retains hledger's copyright history.
