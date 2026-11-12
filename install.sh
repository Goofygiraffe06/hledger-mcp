#!/bin/sh
set -eu

repository=${HLEDGER_MCP_REPOSITORY:-Goofygiraffe06/hledger-mcp}
install_root=${HLEDGER_MCP_INSTALL_ROOT:-"$HOME/.local/lib/hledger-mcp"}
bin_dir=${HLEDGER_MCP_BIN_DIR:-"$HOME/.local/bin"}

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target=macos-arm64 ;;
  Darwin-x86_64) target=macos-x86_64 ;;
  Linux-x86_64) target=linux-x86_64 ;;
  Linux-aarch64|Linux-arm64) target=linux-arm64 ;;
  *) echo "No prebuilt hledger-mcp release for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

temporary=$(mktemp -d "${TMPDIR:-/tmp}/hledger-mcp-install.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
url="https://github.com/$repository/releases/latest/download/hledger-mcp-$target.tar.gz"
curl --fail --location --silent --show-error "$url" -o "$temporary/package.tar.gz"
tar -xzf "$temporary/package.tar.gz" -C "$temporary"

mkdir -p "$install_root" "$bin_dir"
cp -R "$temporary/hledger-mcp-$target/." "$install_root/"
ln -sf "$install_root/hledger-mcp" "$bin_dir/hledger-mcp"

"$bin_dir/hledger-mcp" --init >/dev/null
printf 'Installed hledger-mcp to %s\n' "$bin_dir/hledger-mcp"
printf 'Workspace: '
"$bin_dir/hledger-mcp" --show-paths
