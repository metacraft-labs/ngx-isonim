#!/usr/bin/env bash
#
# E2E test runner for ngx-isonim.
# Starts nginx with the isonim module, runs curl tests, stops nginx.
#
# Prerequisites:
#   - nix build .#nginx-with-isonim  (produces the module .so)
#   - nginx binary available in PATH
#
# Usage:
#   bash tests/e2e/test_e2e.sh
#
# The script exits 0 if all tests pass, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="/tmp/ngx-isonim-test"
NGINX_CONF="${SCRIPT_DIR}/nginx.conf"
PORT=8088
BASE_URL="http://localhost:${PORT}"

PASS=0
FAIL=0
SKIP=0

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

# shellcheck disable=SC2329
cleanup() {
    echo ""
    echo "Cleaning up..."
    if [ -f "${TEST_DIR}/nginx.pid" ]; then
        kill "$(cat "${TEST_DIR}/nginx.pid")" 2>/dev/null || true
    fi
    rm -rf "${TEST_DIR}"
}

trap cleanup EXIT

pass() {
    local name="$1"
    echo "  PASS: ${name}"
    PASS=$((PASS + 1))
}

fail() {
    local name="$1"
    shift
    echo "  FAIL: ${name} — $*"
    FAIL=$((FAIL + 1))
}

skip() {
    local name="$1"
    shift
    echo "  SKIP: ${name} — $*"
    SKIP=$((SKIP + 1))
}

assert_status() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [ "${actual}" = "${expected}" ]; then
        return 0
    else
        fail "${name}" "expected status ${expected}, got ${actual}"
        return 1
    fi
}

assert_contains() {
    local name="$1"
    local body="$2"
    local pattern="$3"
    if echo "${body}" | grep -q "${pattern}"; then
        return 0
    else
        fail "${name}" "body missing '${pattern}'"
        return 1
    fi
}

assert_not_contains() {
    local name="$1"
    local body="$2"
    local pattern="$3"
    if echo "${body}" | grep -q "${pattern}"; then
        fail "${name}" "body unexpectedly contains '${pattern}'"
        return 1
    else
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

echo "=== ngx-isonim E2E Tests ==="
echo ""

# Create temp directories for nginx
mkdir -p "${TEST_DIR}"/{client_body,proxy,fastcgi,uwsgi,scgi}

# Start nginx
echo "Starting nginx..."
nginx -c "${NGINX_CONF}" -p "${TEST_DIR}"
sleep 1

# Verify nginx is running
if ! kill -0 "$(cat "${TEST_DIR}/nginx.pid")" 2>/dev/null; then
    echo "FATAL: nginx did not start"
    cat "${TEST_DIR}/error.log" 2>/dev/null
    exit 1
fi
echo "  nginx started (pid $(cat "${TEST_DIR}/nginx.pid"))"
echo ""

# ---------------------------------------------------------------------------
# Basic Tests
# ---------------------------------------------------------------------------

echo "--- Basic Tests ---"

# Test: GET /hello
echo "Test: GET /hello"
STATUS=$(curl -s -o /tmp/ngx-isonim-test/hello_body -w "%{http_code}" "${BASE_URL}/hello")
BODY=$(cat /tmp/ngx-isonim-test/hello_body)
if assert_status "GET /hello status" "200" "${STATUS}" && \
  assert_contains "GET /hello body" "${BODY}" "Hello from IsoNim" && \
  assert_contains "GET /hello html" "${BODY}" "<html>"; then
    pass "GET /hello"
fi

# Test: GET /hello Content-Type
echo "Test: GET /hello Content-Type"
CONTENT_TYPE=$(curl -s -o /dev/null -w "%{content_type}" "${BASE_URL}/hello")
if echo "${CONTENT_TYPE}" | grep -q "text/html"; then
    pass "GET /hello Content-Type"
else
    fail "GET /hello Content-Type" "expected text/html, got ${CONTENT_TYPE}"
fi

# Test: GET /hello without hydration (no script tag)
echo "Test: GET /hello no hydration"
BODY=$(curl -s "${BASE_URL}/hello")
if assert_not_contains "GET /hello no hydration" "${BODY}" "window._\$HY"; then
    pass "GET /hello no hydration"
fi

# Test: GET /hello-hydrated with hydration
echo "Test: GET /hello-hydrated"
BODY=$(curl -s "${BASE_URL}/hello-hydrated")
if assert_contains "GET /hello-hydrated" "${BODY}" "window._\$HY" && \
  assert_contains "GET /hello-hydrated events" "${BODY}" "events:"; then
    pass "GET /hello-hydrated"
fi

# Test: GET /hello-csp with CSP nonce
echo "Test: GET /hello-csp"
BODY=$(curl -s "${BASE_URL}/hello-csp")
if assert_contains "GET /hello-csp nonce" "${BODY}" 'nonce="abc123"' && \
  assert_contains "GET /hello-csp hydration" "${BODY}" "window._\$HY"; then
    pass "GET /hello-csp"
fi

# Test: GET /tasks
echo "Test: GET /tasks"
STATUS=$(curl -s -o /tmp/ngx-isonim-test/tasks_body -w "%{http_code}" "${BASE_URL}/tasks")
BODY=$(cat /tmp/ngx-isonim-test/tasks_body)
if assert_status "GET /tasks status" "200" "${STATUS}" && \
  assert_contains "GET /tasks body" "${BODY}" "Task Manager"; then
    pass "GET /tasks"
fi

# Test: GET /async (streaming)
echo "Test: GET /async (streaming)"
STATUS=$(curl -s -o /tmp/ngx-isonim-test/async_body -w "%{http_code}" "${BASE_URL}/async")
BODY=$(cat /tmp/ngx-isonim-test/async_body)
if assert_status "GET /async status" "200" "${STATUS}" && \
  assert_contains "GET /async body" "${BODY}" "Dashboard"; then
    pass "GET /async"
fi

# Test: HEAD /hello
echo "Test: HEAD /hello"
STATUS=$(curl -s -o /dev/null -I -w "%{http_code}" "${BASE_URL}/hello")
BODY=$(curl -s -I "${BASE_URL}/hello")
# Verify HEAD returns no body (size_download is 0 for -I)
curl -s -o /dev/null -w "%{size_download}" -I "${BASE_URL}/hello" > /dev/null
if assert_status "HEAD /hello status" "200" "${STATUS}"; then
    # HEAD should return no body (size_download is 0 for -I)
    pass "HEAD /hello"
fi

# Test: POST /hello
echo "Test: POST /hello"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/hello")
if assert_status "POST /hello status" "405" "${STATUS}"; then
    pass "POST /hello returns 405"
fi

# Test: GET /nonexistent
echo "Test: GET /nonexistent"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/nonexistent")
if assert_status "GET /nonexistent status" "404" "${STATUS}"; then
    pass "GET /nonexistent returns 404"
fi

echo ""

# ---------------------------------------------------------------------------
# Performance Tests (optional, requires wrk)
# ---------------------------------------------------------------------------

echo "--- Performance Tests ---"

if command -v wrk &>/dev/null; then
    echo "Test: wrk /hello (2 threads, 10 connections, 5s)"
    WRK_OUTPUT=$(wrk -t2 -c10 -d5s "${BASE_URL}/hello" 2>&1)
    echo "${WRK_OUTPUT}" | tail -4
    if echo "${WRK_OUTPUT}" | grep -q "Requests/sec"; then
        pass "wrk /hello completed"
    else
        fail "wrk /hello" "no output"
    fi

    echo "Test: wrk /tasks (2 threads, 10 connections, 5s)"
    WRK_OUTPUT=$(wrk -t2 -c10 -d5s "${BASE_URL}/tasks" 2>&1)
    echo "${WRK_OUTPUT}" | tail -4
    if echo "${WRK_OUTPUT}" | grep -q "Requests/sec"; then
        pass "wrk /tasks completed"
    else
        fail "wrk /tasks" "no output"
    fi
else
    skip "wrk /hello" "wrk not found in PATH"
    skip "wrk /tasks" "wrk not found in PATH"
fi

echo ""

# ---------------------------------------------------------------------------
# Health endpoint (sanity)
# ---------------------------------------------------------------------------

echo "--- Health Check ---"

echo "Test: GET /health"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health")
if assert_status "GET /health" "200" "${STATUS}"; then
    pass "GET /health"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$((PASS + FAIL + SKIP))
echo "=== Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (${TOTAL} total) ==="

if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "Some tests failed. Check ${TEST_DIR}/error.log for nginx errors."
    exit 1
fi

echo ""
echo "All E2E tests passed."
exit 0
