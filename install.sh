#!/bin/sh

set -eu

BIN_DIR="$HOME/.local/bin"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "fbc currently supports macOS only." >&2
    exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc is required. Install Xcode Command Line Tools, then run this installer again." >&2
    exit 1
fi

SOURCE_FILE=""
case "$0" in
    install.sh|*/install.sh)
        SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        if [ -f "$SCRIPT_DIR/fbc.swift" ]; then
            SOURCE_FILE="$SCRIPT_DIR/fbc.swift"
        fi
        ;;
esac

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fbc-install.XXXXXX")
cleanup() {
    rm -f "$tmp_dir/fbc" "$tmp_dir/fbc.swift"
    rmdir "$tmp_dir" 2>/dev/null || true
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

if [ -z "$SOURCE_FILE" ]; then
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is required to download fbc.swift." >&2
        exit 1
    fi
    SOURCE_FILE="$tmp_dir/fbc.swift"
    echo "Downloading fbc.swift..."
    curl -fsSL "https://raw.githubusercontent.com/FahadBuilds/fbc/main/fbc.swift" -o "$SOURCE_FILE"
fi

echo "Compiling fbc..."
compiler=$(xcrun --find swiftc)
selected_sdk=${SDKROOT:-}
if [ -z "$selected_sdk" ]; then
    developer_dir=$(xcode-select -p)
    developer_dir=${DEVELOPER_DIR:-$developer_dir}
    case "$developer_dir" in
        *.app) developer_dir="$developer_dir/Contents/Developer" ;;
    esac
    for default_sdk in \
        "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
        "$developer_dir/SDKs/MacOSX.sdk"
    do
        if [ -d "$default_sdk" ]; then
            selected_sdk=$default_sdk
            break
        fi
    done
    if [ -z "$selected_sdk" ]; then
        selected_sdk=$(xcrun --sdk macosx --show-sdk-path)
    fi
fi
SDKROOT="$selected_sdk" "$compiler" -sdk "$selected_sdk" "$SOURCE_FILE" -o "$tmp_dir/fbc"

install -d "$BIN_DIR"
install "$tmp_dir/fbc" "$BIN_DIR/fbc"
echo "Installed fbc to $BIN_DIR/fbc"

case ":${PATH:-}:" in
    *":$BIN_DIR:"*)
        echo "$BIN_DIR is already on PATH. Run: fbc"
        exit 0
        ;;
esac

case "${SHELL:-}" in
    */zsh)
        profile="$HOME/.zprofile"
        path_line='export PATH="$HOME/.local/bin:$PATH"'
        current_shell_command='export PATH="$HOME/.local/bin:$PATH"'
        ;;
    */bash)
        profile="$HOME/.bash_profile"
        path_line='export PATH="$HOME/.local/bin:$PATH"'
        current_shell_command='export PATH="$HOME/.local/bin:$PATH"'
        ;;
    */fish)
        profile="$HOME/.config/fish/config.fish"
        path_line='fish_add_path "$HOME/.local/bin"'
        current_shell_command='fish_add_path "$HOME/.local/bin"'
        ;;
    *)
        profile="$HOME/.profile"
        path_line='export PATH="$HOME/.local/bin:$PATH"'
        current_shell_command='export PATH="$HOME/.local/bin:$PATH"'
        ;;
esac

if [ ! -f "$profile" ] || ! grep -Fqx "$path_line" "$profile"; then
    case "$profile" in
        */.config/fish/*) install -d "$(dirname "$profile")" ;;
    esac
    {
        if [ -s "$profile" ]; then
            printf '\n'
        fi
        printf '%s\n' "$path_line"
    } >> "$profile"
    echo "Added $BIN_DIR to PATH in $profile"
else
    echo "$BIN_DIR is already configured in $profile"
fi

echo "For this terminal session, run: $current_shell_command"
echo "Future terminals will pick up the PATH change automatically."
