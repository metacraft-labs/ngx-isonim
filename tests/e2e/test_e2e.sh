#!/usr/bin/env bash
#
# E2E test runner for ngx-isonim.
# Starts nginx, runs curl tests, stops nginx.
#
# For M0, this just verifies nginx starts and responds on the health endpoint.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="/tmp/ngx-isonim-test"
NGINX_CONF="${SCRIPT_DIR}/nginx.conf"

cleanup() {
    echo "Stopping nginx..."
    if [ -f "${TEST_DIR}/nginx.pid" ]; then
        kill "$(cat "${TEST_DIR}/nginx.pid")" 2>/dev/null || true
    fi
    rm -rf "${TEST_DIR}"
}

trap cleanup EXIT

echo "=== ngx-isonim E2E Tests ==="
echo ""

# Create temp directories
mkdir -p "${TEST_DIR}"/{client_body,proxy,fastcgi,uwsgi,scgi}

# Start nginx
echo "Starting nginx..."
nginx -c "${NGINX_CONF}" -p "${TEST_DIR}"
sleep 1

# Verify nginx is running
if ! kill -0 "$(cat "${TEST_DIR}/nginx.pid")" 2>/dev/null; then
    echo "FAIL: nginx did not start"
    cat "${TEST_DIR}/error.log" 2>/dev/null
    exit 1
fi
echo "  nginx started (pid $(cat "${TEST_DIR}/nginx.pid"))"

# Test 1: health endpoint
echo ""
echo "Test 1: Health endpoint..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8088/health)
if [ "${RESPONSE}" = "200" ]; then
    echo "  PASS: health endpoint returned 200"
else
    echo "  FAIL: health endpoint returned ${RESPONSE}"
    exit 1
fi

# Test 2: root endpoint
echo "Test 2: Root endpoint..."
BODY=$(curl -s http://localhost:8088/)
if echo "${BODY}" | grep -q "ngx-isonim"; then
    echo "  PASS: root endpoint returned expected content"
else
    echo "  FAIL: unexpected response: ${BODY}"
    exit 1
fi

echo ""
echo "=== All E2E tests passed ==="
