#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

RELEASE_DIR="build/Build/Products/Release"
APP_BUNDLE="$RELEASE_DIR/Swiftlauncher.app"
CLI_BIN="$RELEASE_DIR/swiftlauncher-cli"

usage() {
    cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  build     Build Swiftlauncher.app and swiftlauncher-cli, embed CLI, and sign (default)
  cli       Build swiftlauncher-cli only
  run       Build, embed/sign, and launch Swiftlauncher.app
  install   Build, embed/sign, and copy Swiftlauncher.app to ~/Applications/
  -h, --help
            Show this help message
EOF
}

build_app() {
    xcodebuild \
        -project Swiftlauncher.xcodeproj \
        -scheme Swiftlauncher \
        -configuration Release \
        -derivedDataPath build \
        CODE_SIGNING_ALLOWED=NO \
        build
}

build_cli() {
    mkdir -p "$RELEASE_DIR"
    swiftc -O SwiftlauncherCLI.swift -o "$CLI_BIN"
}

find_signing_identity() {
    local identity
    identity="$(security find-identity -v -p codesigning | awk '/Swiftlauncher Local Signing/ && length($2)==40 {print $2; exit}' || true)"
    if [[ -z "$identity" ]]; then
        identity="$(security find-identity -v -p codesigning | awk 'length($2)==40 {print $2; exit}' || true)"
    fi
    echo "${identity:--}"
}

embed_and_sign() {
    cp "$CLI_BIN" "$APP_BUNDLE/Contents/MacOS/swiftlauncher-cli"
    local sign_id
    sign_id="$(find_signing_identity)"
    codesign --force --sign "$sign_id" "$APP_BUNDLE/Contents/MacOS/swiftlauncher-cli"
    codesign --force --sign "$sign_id" "$APP_BUNDLE"
}

CMD="${1:-build}"

case "$CMD" in
    -h|--help)
        usage
        ;;
    cli)
        build_cli
        ;;
    build)
        build_app
        build_cli
        embed_and_sign
        ;;
    run)
        build_app
        build_cli
        embed_and_sign
        open "$APP_BUNDLE"
        ;;
    install)
        build_app
        build_cli
        embed_and_sign
        mkdir -p "${HOME}/Applications"
        cp -R -f "$APP_BUNDLE" "${HOME}/Applications/"
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        usage >&2
        exit 1
        ;;
esac
