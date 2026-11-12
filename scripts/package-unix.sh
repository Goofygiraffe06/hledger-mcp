#!/bin/sh
set -eu

target=${1:?usage: package-unix.sh TARGET}
case "$target" in
  linux-x86_64|linux-arm64|macos-arm64|macos-x86_64) ;;
  *) echo "unsupported target: $target" >&2; exit 1 ;;
esac
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary=$(cd "$repo_dir" && cabal list-bin hledger-mcp)
stage="$repo_dir/release/hledger-mcp-$target"
archive="$repo_dir/release/hledger-mcp-$target.tar.gz"

rm -rf "$stage"
mkdir -p "$stage/lib"

case $(uname -s) in
  Darwin)
    cp "$binary" "$stage/hledger-mcp"
    gmp_path=$(otool -L "$binary" | awk '/libgmp/{print $1; exit}')
    if [ -n "$gmp_path" ]; then
      cp "$gmp_path" "$stage/lib/"
      install_name_tool -change "$gmp_path" "@executable_path/lib/$(basename "$gmp_path")" "$stage/hledger-mcp"
    fi
    codesign --force --sign - "$stage/hledger-mcp"
    ;;
  Linux)
    cp "$binary" "$stage/hledger-mcp-bin"
    for library in $(ldd "$binary" | awk '/libgmp|libffi/{print $3}'); do
      [ -f "$library" ] && cp "$library" "$stage/lib/"
    done
    cat >"$stage/hledger-mcp" <<'EOF'
#!/bin/sh
runtime_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LD_LIBRARY_PATH="$runtime_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$runtime_dir/hledger-mcp-bin" "$@"
EOF
    chmod +x "$stage/hledger-mcp"
    ;;
  *)
    echo "unsupported packaging host" >&2
    exit 1
    ;;
esac

cp "$repo_dir/LICENSE" "$stage/LICENSE"
cp "$repo_dir/hledger-mcp/README.md" "$stage/README.md"
tar -czf "$archive" -C "$repo_dir/release" "hledger-mcp-$target"
printf '%s\n' "$archive"
