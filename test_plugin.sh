#!/usr/bin/env bash
# Grabit Plugin Test Script
# Tests the plugin functionality via IPC

set -euo pipefail

PLUGIN="snowballons/grabit"
PASS=0
FAIL=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { log "✓ PASS: $*"; (( PASS += 1 )); }
fail() { log "✗ FAIL: $*"; (( FAIL += 1 )); }

# Check if Noctalia is running
if ! pgrep -x noctalia >/dev/null; then
    fail "Noctalia not running"
    exit 1
fi
pass "Noctalia is running"

# Check plugin is enabled
if ! noctalia msg plugins list 2>&1 | grep -q "$PLUGIN.*enabled"; then
    fail "Plugin not enabled"
    exit 1
fi
pass "Plugin is enabled"

# Test service IPC - record then stop (round-trip exercises real state transitions)
# "start" is not a valid IPC event; "record" → "stop" is the real path.
log "Testing service:record..."
if noctalia msg plugin "$PLUGIN:service" all record 2>&1 | grep -q "ok: dispatched"; then
    pass "service:record dispatched"
else
    fail "service:record failed"
fi

sleep 0.6  # allow the pending state to settle before stopping

log "Testing service:stop..."
if noctalia msg plugin "$PLUGIN:service" all stop 2>&1 | grep -q "ok: dispatched"; then
    pass "service:stop dispatched"
else
    fail "service:stop failed"
fi

# Test service IPC - capture
log "Testing service:capture..."
if noctalia msg plugin "$PLUGIN:service" all capture copy 2>&1 | grep -q "ok: dispatched"; then
    pass "service:capture dispatched"
else
    fail "service:capture failed"
fi

# Test service IPC - menu
log "Testing service:menu..."
if noctalia msg plugin "$PLUGIN:service" all menu 2>&1 | grep -q "ok: dispatched"; then
    pass "service:menu dispatched"
else
    fail "service:menu failed"
fi

# Test panel toggle
log "Testing panel-toggle menu..."
if noctalia msg panel-toggle "$PLUGIN:menu" 2>&1 | grep -q "ok"; then
    pass "panel-toggle menu works"
else
    fail "panel-toggle menu failed"
fi

# Test panel toggle settings
log "Testing panel-toggle settings..."
if noctalia msg panel-toggle "$PLUGIN:settings" 2>&1 | grep -q "ok"; then
    pass "panel-toggle settings works"
else
    fail "panel-toggle settings failed"
fi

# Test grabit binary exists
if command -v grabit >/dev/null; then
    pass "grabit binary found at $(which grabit)"
else
    fail "grabit binary not found"
fi

# Summary
echo ""
log "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    exit 1
fi
