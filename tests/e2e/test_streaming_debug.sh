#!/usr/bin/env bash
#
# test_streaming_handler_default_in_debug_build (IFP-M1).
#
# Builds the module in debug mode (Nim's default checks and stack traces, C
# at -O0 -g), starts nginx WITHOUT choosing a handler (no isonim_ssr_mode,
# so the default applies), and requests a page with a deferred Suspense
# boundary 500 times: 270 sequential, 20 timed, 150 concurrent (6 batches of
# 25), and 30 that the client aborts mid-response, each followed by a normal
# request that must be served once the worker has finished the aborted one.
#
# Vacuity guard: every completed response is chunked and ends with the
# terminating chunk; the shell arrives before the deferred content (in byte
# order on every response, and in time on the timed ones: the boundary's
# data takes 150 ms to produce, and the shell must reach the client at least
# 100 ms before the deferred content); no request hangs past a 5 s timeout;
# and the worker's open file descriptor count returns to its baseline.
#
# The hang this guards against: until IFP-M1 the streaming path never sent
# the last buffer (nor the flush flag), so nginx finished the request with
# the chunked body unterminated and the client waited forever.  That
# happened in debug and release builds alike.
#
# The `suspense` app (tests/e2e/apps/e2e_apps.nim) renders the shell with
# IsoNim's renderToStream, spins for `defer_ms` (standing in for slow data;
# it is the time the test measures, not a synchronisation), then resolves
# the boundary.
#
# No mocks: real nginx, real module, real curl.
#
# Run in the dev shell: bash tests/e2e/test_streaming_debug.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
MODULE="${WORK}/ngx_http_isonim_module.so"
PASS=0
FAIL=0

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

cleanup() {
  if [ -f "${WORK}/nginx.pid" ]; then
    kill "$(cat "${WORK}/nginx.pid")" 2>/dev/null || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# Polls (every 50 ms, up to $1 seconds) until "$2" succeeds.
wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  while ! "$@"; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then return 1; fi
    sleep 0.05
  done
}

echo "=== test_streaming_handler_default_in_debug_build ==="

# --- Debug build -----------------------------------------------------------

echo "Building the module (debug)..."
if ! "${ROOT}/scripts/build-module.sh" debug "${MODULE}" -d:ngxIsonimTestApps \
  >"${WORK}/build.log" 2>&1; then
  tail -40 "${WORK}/build.log"
  echo "FATAL: debug build failed"
  exit 1
fi
if grep -q "DEBUG BUILD" "${WORK}/build.log"; then
  pass "the module was built in debug mode"
else
  fail "the build log does not show a debug build"
fi

# --- nginx, no handler chosen ---------------------------------------------

PORT=0
for _ in $(seq 1 50); do
  candidate=$((20000 + RANDOM % 30000))
  if ! port_open "${candidate}"; then
    PORT=${candidate}
    break
  fi
done
mkdir -p "${WORK}"/{client_body,proxy,fastcgi,uwsgi,scgi}
cat >"${WORK}/nginx.conf" <<EOF
load_module ${MODULE};
worker_processes 1;
error_log ${WORK}/error.log info;
pid ${WORK}/nginx.pid;
events { worker_connections 1024; }
http {
  access_log off;
  client_body_temp_path ${WORK}/client_body;
  proxy_temp_path ${WORK}/proxy;
  fastcgi_temp_path ${WORK}/fastcgi;
  uwsgi_temp_path ${WORK}/uwsgi;
  scgi_temp_path ${WORK}/scgi;
  server {
    listen 127.0.0.1:${PORT};
    # No isonim_ssr_mode: the module's default transport is under test.
    location /page { isonim_ssr on; isonim_ssr_app suspense; }
  }
}
EOF
if ! nginx -c "${WORK}/nginx.conf" -p "${WORK}" -e "${WORK}/error.log" \
  </dev/null >"${WORK}/start.log" 2>&1; then
  cat "${WORK}/start.log" "${WORK}/error.log"
  echo "FATAL: nginx did not start"
  exit 1
fi
if ! wait_for 10 port_open "${PORT}"; then
  echo "FATAL: nginx did not open port ${PORT}"
  exit 1
fi
MASTER="$(cat "${WORK}/nginx.pid")"
WORKER="$(pgrep -P "${MASTER}" | head -1)"
fd_count() { find "/proc/${WORKER}/fd" -mindepth 1 -maxdepth 1 | wc -l; }
BASELINE="$(fd_count)"
echo "  nginx on port ${PORT}, worker ${WORKER}, ${BASELINE} open fds"
URL="http://127.0.0.1:${PORT}/page"

# Checks one completed response: $1 = curl exit code, $2 = headers file,
# $3 = raw (still chunk-encoded) body file.  Prints the failure, if any.
check_response() {
  local rc=$1 headers=$2 body=$3
  if [ "${rc}" -ne 0 ]; then
    echo "curl exit ${rc} (28 = hung past 5 s)"
    return 1
  fi
  if ! head -1 "${headers}" | grep -q "^HTTP/1.1 200"; then
    echo "status: $(head -1 "${headers}")"
    return 1
  fi
  if ! grep -qi "^Transfer-Encoding: chunked" "${headers}"; then
    echo "not chunked"
    return 1
  fi
  if [ "$(tail -c 5 "${body}" | od -An -c | tr -d ' ')" != '0\r\n\r\n' ]; then
    echo "no terminating chunk"
    return 1
  fi
  local shell deferred
  shell=$(grep -abo 'id="shell"' "${body}" | head -1 | cut -d: -f1)
  deferred=$(grep -abo 'id="deferred-content"' "${body}" | head -1 | cut -d: -f1)
  if [ -z "${shell}" ] || [ -z "${deferred}" ] || [ "${shell}" -ge "${deferred}" ]; then
    echo "shell (${shell:-missing}) not before deferred content (${deferred:-missing})"
    return 1
  fi
  return 0
}

fetch() {
  # $1 = name, $2 = query
  curl -sS --raw --max-time 5 -D "${WORK}/$1.h" -o "${WORK}/$1.b" "${URL}?$2" \
    2>"${WORK}/$1.err"
}

# --- 270 sequential --------------------------------------------------------

echo "--- 270 sequential requests ---"
bad=0
for i in $(seq 1 270); do
  fetch "seq" "defer_ms=0&i=${i}"
  rc=$?
  if ! why=$(check_response "${rc}" "${WORK}/seq.h" "${WORK}/seq.b"); then
    [ "${bad}" -lt 3 ] && echo "    request ${i}: ${why}"
    bad=$((bad + 1))
  fi
done
if [ "${bad}" -eq 0 ]; then pass "270 sequential responses complete, chunked, shell first"; else fail "${bad}/270 sequential responses"; fi

# --- 20 timed --------------------------------------------------------------

echo "--- 20 timed requests (boundary data takes 150 ms) ---"
bad=0
for i in $(seq 1 20); do
  # Each line is stamped when curl hands it over (-N: no buffering).
  curl -sS -N --raw --max-time 5 "${URL}?defer_ms=150&t=${i}" 2>/dev/null |
    while IFS= read -r line; do printf '%s %s\n' "${EPOCHREALTIME}" "${line}"; done \
      >"${WORK}/timed.txt"
  t_shell=$(grep -m1 'id="shell"' "${WORK}/timed.txt" | cut -d' ' -f1)
  t_deferred=$(grep -m1 'id="deferred-content"' "${WORK}/timed.txt" | cut -d' ' -f1)
  if [ -z "${t_shell}" ] || [ -z "${t_deferred}" ] ||
    ! awk -v a="${t_shell}" -v b="${t_deferred}" 'BEGIN { exit !(b - a >= 0.100) }'; then
    [ "${bad}" -lt 3 ] && echo "    request ${i}: shell at ${t_shell:-never}, deferred at ${t_deferred:-never}"
    bad=$((bad + 1))
  fi
done
if [ "${bad}" -eq 0 ]; then pass "the shell reached the client >= 100 ms before the deferred content (20/20)"; else fail "${bad}/20 timed responses"; fi

# --- 150 concurrent --------------------------------------------------------

echo "--- 150 concurrent requests (6 batches of 25) ---"
bad=0
for batch in $(seq 1 6); do
  pids=()
  for j in $(seq 1 25); do
    fetch "c${j}" "defer_ms=5&b=${batch}&j=${j}" &
    pids+=($!)
  done
  for j in $(seq 1 25); do
    wait "${pids[$((j - 1))]}"
    rc=$?
    if ! why=$(check_response "${rc}" "${WORK}/c${j}.h" "${WORK}/c${j}.b"); then
      [ "${bad}" -lt 3 ] && echo "    batch ${batch} request ${j}: ${why}"
      bad=$((bad + 1))
    fi
  done
done
if [ "${bad}" -eq 0 ]; then pass "150 concurrent responses complete, chunked, shell first"; else fail "${bad}/150 concurrent responses"; fi

# --- 30 aborted, each followed by a normal request -------------------------

echo "--- 30 requests aborted by the client mid-response ---"
bad=0
bad_after=0
for i in $(seq 1 30); do
  # The client gives up after 100 ms, while the worker is still producing
  # the boundary (300 ms): the shell has been sent, the rest has not.
  curl -sS --raw --max-time 0.1 -o "${WORK}/abort.b" "${URL}?defer_ms=300&a=${i}" 2>/dev/null
  rc=$?
  if [ "${rc}" -ne 28 ] || ! grep -q 'id="shell"' "${WORK}/abort.b" ||
    grep -q 'id="deferred-content"' "${WORK}/abort.b"; then
    [ "${bad}" -lt 3 ] && echo "    request ${i}: curl exit ${rc} (expected 28, aborted after the shell)"
    bad=$((bad + 1))
  fi
  # Served as soon as the worker has finished the abandoned render.
  fetch "after" "defer_ms=0&after=${i}"
  rc=$?
  if ! why=$(check_response "${rc}" "${WORK}/after.h" "${WORK}/after.b"); then
    [ "${bad_after}" -lt 3 ] && echo "    request after abort ${i}: ${why}"
    bad_after=$((bad_after + 1))
  fi
done
if [ "${bad}" -eq 0 ]; then pass "30 requests aborted after the shell arrived"; else fail "${bad}/30 aborts"; fi
if [ "${bad_after}" -eq 0 ]; then pass "a normal request after each abort is served (30/30)"; else fail "${bad_after}/30 requests after an abort"; fi

# --- Resources -------------------------------------------------------------

fds_at_baseline() { [ "$(fd_count)" -eq "${BASELINE}" ]; }
if wait_for 10 fds_at_baseline; then
  pass "worker fd count back to its baseline (${BASELINE})"
else
  fail "worker fd count $(fd_count), baseline ${BASELINE}"
  ls -l "/proc/${WORKER}/fd"
fi

if [ "$(pgrep -P "${MASTER}" | head -1)" = "${WORKER}" ] &&
  ! grep -qE "exited on signal|\[alert\]|\[emerg\]|\[crit\]" "${WORK}/error.log"; then
  pass "the worker never crashed"
else
  fail "worker restarted or nginx logged an alert"
  grep -E "exited on signal|\[alert\]|\[emerg\]|\[crit\]" "${WORK}/error.log" | head
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ]
