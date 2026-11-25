#!/bin/sh
# Runs all offline tests. Needs lua5.3 + lua-cjson, and node.
set -e
cd "$(dirname "$0")/.."
for t in tests/test_shelly.lua tests/test_atios.lua tests/test_meeting_room.lua; do lua5.3 "$t"; done
node tests/test_fallback.js
