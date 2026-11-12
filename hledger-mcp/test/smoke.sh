#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
server=$(cd "$repo_dir" && cabal list-bin hledger-mcp)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/hledger-mcp-workspace.XXXXXX")
responses=$(mktemp "${TMPDIR:-/tmp}/hledger-mcp-responses.XXXXXX")
trap 'rm -rf "$workspace"; rm -f "$responses"' EXIT

"$server" --home "$workspace" >"$responses" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}
{"jsonrpc":"2.0","id":2,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"setup_workspace","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"declare_account","arguments":{"account":"assets:bank:checking","type":"asset","commit":true}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"declare_account","arguments":{"account":"expenses:groceries","type":"expense","commit":true}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"record_transaction","arguments":{"date":"2025-12-31","description":"Prior year groceries","postings":[{"account":"expenses:groceries","amount":"INR 250"},{"account":"assets:bank:checking"}],"commit":true}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"record_transaction","arguments":{"date":"2026-11-12","description":"Groceries","postings":[{"account":"expenses:groceries","amount":"INR 1250"},{"account":"assets:bank:checking"}],"commit":true}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"record_transaction","arguments":{"date":"2026-11-12","description":"Broken","postings":[{"account":"expenses:groceries","amount":"INR 10"},{"account":"assets:bank:checking","amount":"INR 10"}]}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"journal_info","arguments":{}}}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"balance","arguments":{"query":"expenses"}}}
EOF

jq -se 'any(.[]; .id == 1 and .result.protocolVersion == "2025-06-18")' "$responses" >/dev/null
jq -se 'any(.[]; .id == 2 and .result.supportedVersions == ["2026-07-28"])' "$responses" >/dev/null
jq -se 'any(.[]; .id == 3 and .result.isError == false and (.result.structuredContent.created | length) == 4)' "$responses" >/dev/null
jq -se 'any(.[]; .id == 4 and .result.isError == false)' "$responses" >/dev/null
jq -se 'any(.[]; .id == 6 and (.result.structuredContent.file | endswith("transactions/2025.journal")))' "$responses" >/dev/null
jq -se 'any(.[]; .id == 7 and (.result.structuredContent.file | endswith("transactions/2026.journal")))' "$responses" >/dev/null
jq -se 'any(.[]; .id == 8 and .result.isError == true)' "$responses" >/dev/null
jq -se 'any(.[]; .id == 9 and .result.structuredContent.transactions == 2 and (.result.structuredContent.files | length) == 5)' "$responses" >/dev/null
jq -se 'any(.[]; .id == 10 and .result.structuredContent.rows[0].balance == "INR 1500")' "$responses" >/dev/null
grep -q '^account assets:bank:checking  ; type: A$' "$workspace/accounts.journal"
grep -q '^2025-12-31 Prior year groceries$' "$workspace/transactions/2025.journal"
grep -q '^2026-11-12 Groceries$' "$workspace/transactions/2026.journal"

printf 'hledger-mcp smoke test passed\n'
