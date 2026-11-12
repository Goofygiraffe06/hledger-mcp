# hledger-mcp

A portable stdio MCP server linked directly to `hledger-lib`. It gives agents a real
multi-file plain-text accounting workspace without invoking the hledger CLI.

## Install

Prebuilt release archives need neither Haskell nor hledger. On macOS or Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/Goofygiraffe06/hledger-mcp/main/install.sh | sh
```

On Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/Goofygiraffe06/hledger-mcp/main/install.ps1 | iex
```

The installers place the program on the user PATH and initialize its default workspace.
You can also extract a release archive anywhere and run `hledger-mcp --init`.

The repository's release workflow builds Linux x86-64/ARM64, macOS Intel/Apple Silicon,
and Windows x86-64 archives whenever a `v*` tag is pushed. The installer URLs become
available after that first tagged GitHub Release is published.

To build from source instead:

```sh
cabal build hledger-mcp
cabal install hledger-mcp --installdir "$HOME/.local/bin" --overwrite-policy=always
```

## Workspace

By default, data lives in the platform user-data directory returned by the operating
system—normally `~/.local/share/hledger-mcp/personal` on Linux and macOS, and the local
application-data directory on Windows.

```text
personal/
├── main.journal                 # root journal containing includes
├── accounts.journal             # explicit chart of accounts
├── opening-balances.journal     # opening and migration entries
└── transactions/
    ├── 2025.journal
    └── 2026.journal             # transactions route here by date
```

Setup never overwrites an existing file:

```sh
hledger-mcp --init
hledger-mcp --show-paths
```

Use `--home DIR` or `HLEDGER_MCP_HOME` to put the managed workspace anywhere. Existing
hledger users can use `--journal FILE` or `HLEDGER_FILE`; this compatibility mode reads
and writes their supplied root journal instead of creating the managed layout.

## Agent configuration

After installation, no data-path configuration is needed:

```json
{
  "mcpServers": {
    "hledger": {
      "command": "hledger-mcp"
    }
  }
}
```

To select a custom book:

```json
{
  "mcpServers": {
    "hledger": {
      "command": "hledger-mcp",
      "args": ["--home", "/absolute/path/to/my-accounts"]
    }
  }
}
```

The tools are `setup_workspace`, `journal_info`, `list_accounts`, `declare_account`,
`append_journal_text`, `balance`, `register`, `validate_journal`, and
`record_transaction`. The advanced text tool handles native directives such as
commodities, payees, market prices, tags, and periodic rules, but cannot modify include
boundaries or write outside the selected workspace.

`record_transaction` and `declare_account` preview by default. Commits validate the
entire included journal under an exclusive workspace lock before appending. Account
declarations go to `accounts.journal`; transactions go to the year file matching their
date. Agents can therefore manage the book without flattening it into one file.

The server supports both the established `initialize` handshake and MCP revision
`2026-07-28` discovery over newline-delimited stdio JSON-RPC.

## Verify

With `jq` installed:

```sh
cabal build hledger-mcp
./hledger-mcp/test/smoke.sh
```

The implementation is GPL-3.0-or-later because it links with `hledger-lib`.
