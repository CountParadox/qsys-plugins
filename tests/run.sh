#!/bin/sh
# Runs all offline tests. Needs Lua 5.3 (the Q-SYS Lua version) and node.
# lua-cjson is used if installed; otherwise tests/json.lua is used.
set -e
cd "$(dirname "$0")/.."
LUA=$(command -v lua5.3 || command -v lua53 || command -v lua)
for t in tests/test_shelly.lua tests/test_dali.lua tests/test_meeting_room.lua; do "$LUA" "$t"; done
node tests/test_fallback.js
