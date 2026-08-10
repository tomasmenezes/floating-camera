#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh — Floating Camera
# Copyright (c) 2026 Tomás Menezes @tomasmenezes — MIT License
#
# USAGE
#   chmod +x build.sh
#   ./build.sh                   # Apple Silicon (arm64) — default
#   ./build.sh --intel           # Intel Mac (x86_64)
#   ./build.sh --universal       # Universal binary (arm64 + x86_64)
#   ./build.sh --install         # Build + install to /Applications
#   ./build.sh --universal --install
#   ./build.sh --sign "Developer ID Application: Your Name (TEAMID)"
#
# SCRIPT MODE (no build required)
#   swift FloatingCamera.swift
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/FloatingCamera.swift"
APP_NAME="FloatingCamera"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
PLIST_SRC="$SCRIPT_DIR/Info.plist"
ENT_SRC="$SCRIPT_DIR/FloatingCamera.entitlements"
ICON_SRC="$SCRIPT_DIR/AppIcon.icns"

ARCH="arm64"
INSTALL=false
SIGN_IDENTITY=""

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --intel)     ARCH="x86_64"; shift ;;
        --universal) ARCH="universal"; shift ;;
        --install)   INSTALL=true; shift ;;
        --sign)
            # Guard before dereferencing $2: `set -u` would abort on it.
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "✗  --sign requires a signing identity, e.g. --sign \"Developer ID Application: Name (TEAMID)\""
                exit 1
            fi
            SIGN_IDENTITY="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Prerequisite check ────────────────────────────────────────────────────────
if ! command -v swiftc &>/dev/null; then
    echo "✗  swiftc not found. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi
echo "▶  Using $(swiftc --version 2>&1 | head -1)"
echo "▶  Target: $ARCH"
echo "▶  Building $APP_NAME.app …"

# ── Bundle structure ──────────────────────────────────────────────────────────
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
[[ -f "$ICON_SRC" ]] && cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"

# ── Compile ───────────────────────────────────────────────────────────────────
FLAGS=(-O -framework AppKit -framework AVFoundation -framework CoreMedia -framework Carbon)

if [[ "$ARCH" == "universal" ]]; then
    echo "▶  Compiling arm64 …"
    swiftc "${FLAGS[@]}" -target arm64-apple-macos12.0   "$SRC" -o "/tmp/${APP_NAME}_arm64"
    echo "▶  Compiling x86_64 …"
    swiftc "${FLAGS[@]}" -target x86_64-apple-macos12.0  "$SRC" -o "/tmp/${APP_NAME}_x86_64"
    echo "▶  Linking universal binary …"
    lipo -create "/tmp/${APP_NAME}_arm64" "/tmp/${APP_NAME}_x86_64" -output "$MACOS_DIR/$APP_NAME"
    rm -f "/tmp/${APP_NAME}_arm64" "/tmp/${APP_NAME}_x86_64"
else
    swiftc "${FLAGS[@]}" -target "${ARCH}-apple-macos12.0" "$SRC" -o "$MACOS_DIR/$APP_NAME"
fi

chmod +x "$MACOS_DIR/$APP_NAME"
echo "✔  Compiled"

# ── Code sign ─────────────────────────────────────────────────────────────────
if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --deep --force --sign "$SIGN_IDENTITY" \
             --entitlements "$ENT_SRC" --options runtime "$APP_BUNDLE"
    echo "✔  Signed with: $SIGN_IDENTITY"
else
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
    echo "✔  Ad-hoc signed"
fi
echo "✔  Built: $APP_BUNDLE"

# ── Install ───────────────────────────────────────────────────────────────────
if $INSTALL; then
    echo "▶  Installing to /Applications …"
    osascript -e 'tell application "FloatingCamera" to quit' 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/"
    echo "✔  Installed"
    open "/Applications/$APP_NAME.app"
fi

echo ""
echo "Usage:"
echo "  open \"$APP_BUNDLE\"          — launch from build folder"
echo "  ./build.sh --install         — install to /Applications"
echo "  ./build.sh --universal       — fat binary (arm64 + x86_64)"
