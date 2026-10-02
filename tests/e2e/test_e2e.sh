#!/usr/bin/env bash
#
# E2E smoke test for ngx-isonim: a real nginx with the module loaded,
# checked with curl.
#
# Uses the module named by NGX_ISONIM_E2E_MODULE, or builds one with the
# end-to-end apps (scripts/build-module.sh release ... -d:ngxIsonimTestApps).
# Needs nginx and curl on PATH (the dev shell provides both); wrk is
# optional.
#
# Usage (in the dev shell):
#   bash tests/e2e/test_e2e.sh
#
# Exits 0 if all tests pass, 1 otherwise.  No mocks.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR="$(mktemp -d)"

PASS=0
FAIL=0
SKIP=0

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

# shellcheck disable=SC2329
cleanup() {
  if [ -f "${TEST_DIR}/nginx.pid" ]; then
    kill "$(cat "${TEST_DIR}/nginx.pid")" 2>/dev/null || true
  fi
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
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
  if [ "$3" = "$2" ]; then return 0; fi
  fail "$1" "expected status $2, got $3"
  return 1
}

assert_contains() {
  if grep -qF -- "$3" <<<"$2"; then return 0; fi
  fail "$1" "body missing '$3'"
  return 1
}

assert_not_contains() {
  if ! grep -qF -- "$3" <<<"$2"; then return 0; fi
  fail "$1" "body unexpectedly contains '$3'"
  return 1
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# Writes the template config for prefix $1 with extra location text $2.
write_conf() {
  local prefix=$1 extra=${2:-}
  mkdir -p "${prefix}"/{client_body,proxy,fastcgi,uwsgi,scgi}
  local line
  while IFS= read -r line; do
    if [[ "${line}" == *"@EXTRA@"* ]]; then
      printf '        %s\n' "${extra}"
      continue
    fi
    line=${line//@MODULE@/${MODULE}}
    line=${line//@PREFIX@/${prefix}}
    line=${line//@PORT@/${PORT}}
    printf '%s\n' "${line}"
  done <"${SCRIPT_DIR}/nginx.conf" >"${prefix}/nginx.conf"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

echo "=== ngx-isonim E2E Tests ==="
echo ""

MODULE="${NGX_ISONIM_E2E_MODULE:-}"
if [ -z "${MODULE}" ]; then
  MODULE="${TEST_DIR}/ngx_http_isonim_module.so"
  echo "Building the module..."
  if ! "${ROOT}/scripts/build-module.sh" release "${MODULE}" -d:ngxIsonimTestApps \
    >"${TEST_DIR}/build.log" 2>&1; then
    tail -40 "${TEST_DIR}/build.log"
    echo "FATAL: module build failed"
    exit 1
  fi
fi

PORT=0
for _ in $(seq 1 50); do
  candidate=$((20000 + RANDOM % 30000))
  if ! port_open "${candidate}"; then
    PORT=${candidate}
    break
  fi
done
BASE_URL="http://127.0.0.1:${PORT}"

write_conf "${TEST_DIR}"
echo "Starting nginx..."
if ! nginx -c "${TEST_DIR}/nginx.conf" -p "${TEST_DIR}" -e "${TEST_DIR}/error.log" \
  </dev/null >"${TEST_DIR}/start.log" 2>&1; then
  cat "${TEST_DIR}/start.log" "${TEST_DIR}/error.log" 2>/dev/null
  echo "FATAL: nginx did not start"
  exit 1
fi
for _ in $(seq 1 200); do
  port_open "${PORT}" && break
  sleep 0.05
done
if ! port_open "${PORT}"; then
  echo "FATAL: nginx did not open port ${PORT}"
  cat "${TEST_DIR}/error.log"
  exit 1
fi
echo "  nginx started (pid $(cat "${TEST_DIR}/nginx.pid"), port ${PORT})"
echo ""

# ---------------------------------------------------------------------------
# Basic Tests
# ---------------------------------------------------------------------------

echo "--- Basic Tests ---"

echo "Test: GET /hello"
STATUS=$(curl -s -o "${TEST_DIR}/hello_body" -w "%{http_code}" "${BASE_URL}/hello")
BODY=$(cat "${TEST_DIR}/hello_body")
if assert_status "GET /hello status" "200" "${STATUS}" &&
  assert_contains "GET /hello body" "${BODY}" "Hello from IsoNim" &&
  assert_contains "GET /hello html" "${BODY}" "<html>"; then
  pass "GET /hello"
fi

echo "Test: GET /hello Content-Type"
CONTENT_TYPE=$(curl -s -o /dev/null -w "%{content_type}" "${BASE_URL}/hello")
if [ "${CONTENT_TYPE}" = "text/html; charset=utf-8" ]; then
  pass "GET /hello Content-Type"
else
  fail "GET /hello Content-Type" "expected text/html; charset=utf-8, got ${CONTENT_TYPE}"
fi

echo "Test: streaming is the default transport, buffered on request"
HEADERS=$(curl -s -D - -o /dev/null "${BASE_URL}/hello")
BHEADERS=$(curl -s -D - -o /dev/null "${BASE_URL}/hello-buffered")
if assert_contains "default transport" "${HEADERS}" "Transfer-Encoding: chunked" &&
  assert_contains "buffered transport" "${BHEADERS}" "Content-Length: 52"; then
  pass "transports"
fi

echo "Test: GET /hello without hydration (no script tag)"
BODY=$(curl -s "${BASE_URL}/hello")
if assert_not_contains "GET /hello no hydration" "${BODY}" 'window._$HY'; then
  pass "GET /hello no hydration"
fi

echo "Test: GET /hello-hydrated"
BODY=$(curl -s "${BASE_URL}/hello-hydrated")
if assert_contains "GET /hello-hydrated" "${BODY}" 'window._$HY' &&
  assert_contains "GET /hello-hydrated events" "${BODY}" "events:" &&
  assert_contains "GET /hello-hydrated nonce" "${BODY}" '<script nonce="'; then
  pass "GET /hello-hydrated"
fi

echo "Test: the script nonce differs between two responses"
N1=$(curl -s "${BASE_URL}/hello-hydrated" | sed -n 's/.*<script nonce="\([^"]*\)".*/\1/p')
N2=$(curl -s "${BASE_URL}/hello-hydrated" | sed -n 's/.*<script nonce="\([^"]*\)".*/\1/p')
if [ -n "${N1}" ] && [ ${#N1} -eq 24 ] && [ "${N1}" != "${N2}" ]; then
  pass "per-response nonce (${N1} != ${N2})"
else
  fail "per-response nonce" "got '${N1}' and '${N2}'"
fi

echo "Test: GET /tasks (real IsoNim SSR app)"
STATUS=$(curl -s -o "${TEST_DIR}/tasks_body" -w "%{http_code}" "${BASE_URL}/tasks")
BODY=$(cat "${TEST_DIR}/tasks_body")
if assert_status "GET /tasks status" "200" "${STATUS}" &&
  assert_contains "GET /tasks title" "${BODY}" "IsoNim Task Manager" &&
  assert_contains "GET /tasks task-list" "${BODY}" "task-list" &&
  assert_contains "GET /tasks active count" "${BODY}" "3 active" &&
  assert_contains "GET /tasks hydration" "${BODY}" 'window._$HY'; then
  pass "GET /tasks"
fi

echo "Test: GET /async (legacy streaming app)"
STATUS=$(curl -s -o "${TEST_DIR}/async_body" -w "%{http_code}" "${BASE_URL}/async")
BODY=$(cat "${TEST_DIR}/async_body")
if assert_status "GET /async status" "200" "${STATUS}" &&
  assert_contains "GET /async body" "${BODY}" "Dashboard" &&
  assert_contains "GET /async boundary" "${BODY}" "Data loaded: 42 items"; then
  pass "GET /async"
fi

echo "Test: HEAD /hello-buffered"
HEAD_OUT=$(curl -s -I -w "%{http_code} %{size_download}" "${BASE_URL}/hello-buffered")
if assert_contains "HEAD status" "${HEAD_OUT}" "200 0" &&
  assert_contains "HEAD length" "${HEAD_OUT}" "Content-Length: 52"; then
  pass "HEAD /hello-buffered"
fi

echo "Test: POST /hello"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/hello")
if assert_status "POST /hello status" "405" "${STATUS}"; then
  pass "POST /hello returns 405"
fi

echo "Test: a renderer that raises"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/boom")
if assert_status "GET /boom" "500" "${STATUS}" &&
  grep -q 'renderer raised ValueError: boom' "${TEST_DIR}/error.log"; then
  pass "GET /boom returns 500 and logs the error"
fi

echo "Test: an unknown app"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/unknown-app")
if assert_status "GET /unknown-app" "500" "${STATUS}" &&
  grep -q 'no app is registered as "no_such_app"' "${TEST_DIR}/error.log"; then
  pass "GET /unknown-app returns 500 and logs the name"
fi

echo "Test: GET /nonexistent"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/nonexistent")
if assert_status "GET /nonexistent status" "404" "${STATUS}"; then
  pass "GET /nonexistent returns 404"
fi

echo ""

# ---------------------------------------------------------------------------
# Configuration rejected by nginx -t
# ---------------------------------------------------------------------------

echo "--- Configuration ---"

check_rejected() {
  # $1 = name, $2 = location text, $3 = expected message
  CONF_N=$((${CONF_N:-0} + 1))
  local dir="${TEST_DIR}/conf-${CONF_N}"
  write_conf "${dir}" "$2"
  local out
  out=$(nginx -t -c "${dir}/nginx.conf" -p "${dir}" -e "${dir}/error.log" 2>&1)
  if [ $? -ne 0 ] && grep -qF -- "$3" <<<"${out}"; then
    pass "nginx -t rejects $1"
  else
    fail "nginx -t rejects $1" "${out}"
  fi
}

check_rejected "the removed fixed nonce directive" \
  'location /x { isonim_ssr on; isonim_ssr_app hello; isonim_ssr_script_nonce abc123; }' \
  'unknown directive "isonim_ssr_script_nonce"'
check_rejected "isonim_ssr on without an app" \
  'location /x { isonim_ssr on; }' \
  '"isonim_ssr on" requires "isonim_ssr_app"'
check_rejected "an unknown isonim_ssr_mode" \
  'location /x { isonim_ssr on; isonim_ssr_app hello; isonim_ssr_mode chunked; }' \
  'invalid value "chunked"'
check_rejected "a negative isonim_ssr_max_buffer_size" \
  'location /x { isonim_ssr on; isonim_ssr_app hello; isonim_ssr_max_buffer_size -1; }' \
  'invalid value'

echo ""

# ---------------------------------------------------------------------------
# Performance (optional, requires wrk)
# ---------------------------------------------------------------------------

echo "--- Performance Tests ---"

if command -v wrk &>/dev/null; then
  for path in /hello /tasks; do
    echo "Test: wrk ${path} (2 threads, 10 connections, 5s)"
    WRK_OUTPUT=$(wrk -t2 -c10 -d5s "${BASE_URL}${path}" 2>&1)
    echo "${WRK_OUTPUT}" | tail -4
    if grep -q "Requests/sec" <<<"${WRK_OUTPUT}" &&
      ! grep -q "Non-2xx" <<<"${WRK_OUTPUT}" &&
      ! grep -q "Socket errors" <<<"${WRK_OUTPUT}"; then
      pass "wrk ${path} completed without errors"
    else
      fail "wrk ${path}" "${WRK_OUTPUT}"
    fi
  done
else
  skip "wrk /hello" "wrk not found in PATH"
  skip "wrk /tasks" "wrk not found in PATH"
fi

echo ""

# ---------------------------------------------------------------------------
# Health endpoint and worker health
# ---------------------------------------------------------------------------

echo "--- Health Check ---"

echo "Test: GET /health"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health")
if assert_status "GET /health" "200" "${STATUS}"; then
  pass "GET /health"
fi

if ! grep -qE "exited on signal|\[alert\]|\[emerg\]|\[crit\]" "${TEST_DIR}/error.log"; then
  pass "no worker crashed"
else
  fail "worker health" "$(grep -E "exited on signal|\[alert\]|\[emerg\]|\[crit\]" "${TEST_DIR}/error.log" | head -3)"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$((PASS + FAIL + SKIP))
echo "=== Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (${TOTAL} total) ==="

if [ "${FAIL}" -gt 0 ]; then
  echo ""
  echo "Some tests failed. nginx error log:"
  tail -20 "${TEST_DIR}/error.log"
  exit 1
fi

echo ""
echo "All E2E tests passed."
exit 0
