#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT_DIR/plugin/codux_remote_iroh"
RUST_DIR="$PLUGIN_DIR/rust"
IOS_RUST_DIR="$PLUGIN_DIR/ios/Rust"
HEADERS_DIR="$IOS_RUST_DIR/Headers"
XCFRAMEWORK_DIR="$IOS_RUST_DIR/CoduxRemoteIrohBridge.xcframework"

cd "$RUST_DIR"

rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

mkdir -p "$HEADERS_DIR"
cat > "$HEADERS_DIR/codux_remote_iroh_bridge.h" <<'EOF'
#ifndef CODUX_REMOTE_IROH_BRIDGE_H
#define CODUX_REMOTE_IROH_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

uint64_t codux_iroh_connect(const char *config_json);
bool codux_iroh_send(uint64_t handle, const char *envelope_json);
char *codux_iroh_poll_event(uint64_t handle);
void codux_iroh_close(uint64_t handle);
void codux_iroh_free_string(char *value);

#endif
EOF

rm -rf "$XCFRAMEWORK_DIR"
xcodebuild -create-xcframework \
  -library "$RUST_DIR/target/aarch64-apple-ios/release/libcodux_remote_iroh_bridge.a" \
  -headers "$HEADERS_DIR" \
  -library "$RUST_DIR/target/aarch64-apple-ios-sim/release/libcodux_remote_iroh_bridge.a" \
  -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK_DIR"
