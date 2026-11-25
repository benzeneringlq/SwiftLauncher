#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

RELEASE_DIR="build/Build/Products/Release"
OBJ_DIR="build/swiftc"
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

plist_set() {
    local plist="$1"
    local key="$2"
    local type="$3"
    local value="$4"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$plist"
}

build_app() {
    mkdir -p "$OBJ_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

    swiftc -O -emit-module -emit-library -static \
        -module-name HotKey \
        -emit-module-path "$OBJ_DIR/HotKey.swiftmodule" \
        -o "$OBJ_DIR/libHotKey.a" \
        HotKey/Sources/HotKey/*.swift

    swiftc -O -parse-as-library \
        -I "$OBJ_DIR" -L "$OBJ_DIR" -lHotKey \
        -framework Carbon -framework AppKit -framework SwiftUI \
        -framework UserNotifications -framework CryptoKit -framework Security \
        -framework ApplicationServices -framework IOKit -framework Cocoa \
        -o "$APP_BUNDLE/Contents/MacOS/Swiftlauncher" \
        Swiftlauncher/CommandLauncher.swift \
        Swiftlauncher/ToastPanel.swift \
        Swiftlauncher/IPC.swift \
        Swiftlauncher/SwiftlauncherApp.swift

    local plist="$APP_BUNDLE/Contents/Info.plist"
    cp Swiftlauncher/Info.plist "$plist"
    plist_set "$plist" "CFBundleDevelopmentRegion" "string" "en"
    plist_set "$plist" "CFBundleExecutable" "string" "Swiftlauncher"
    plist_set "$plist" "CFBundleIdentifier" "string" "start4.Swiftlauncher"
    plist_set "$plist" "CFBundleInfoDictionaryVersion" "string" "6.0"
    plist_set "$plist" "CFBundleName" "string" "Swiftlauncher"
    plist_set "$plist" "CFBundlePackageType" "string" "APPL"
    plist_set "$plist" "CFBundleShortVersionString" "string" "1.0"
    plist_set "$plist" "CFBundleVersion" "string" "1"
    plist_set "$plist" "LSMinimumSystemVersion" "string" "13.7"

    printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
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
    if [[ -f "Swiftlauncher.entitlements" ]]; then
        codesign --force --sign "$sign_id" --entitlements "Swiftlauncher.entitlements" "$APP_BUNDLE"
    else
        codesign --force --sign "$sign_id" "$APP_BUNDLE"
    fi
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
