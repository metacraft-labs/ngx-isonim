# ngx-isonim build and test targets

# --- Build ---

# Compile the nginx module .so (release) into build/
build:
    scripts/build-module.sh release build/ngx_http_isonim_module.so

# Compile the nginx module .so in debug mode (Nim checks, stack traces, -O0 -g)
build-debug:
    scripts/build-module.sh debug build/debug/ngx_http_isonim_module.so

# Compile the module with the apps the end-to-end tests drive
build-e2e:
    scripts/build-module.sh release build/e2e/release/ngx_http_isonim_module.so -d:ngxIsonimTestApps

# Build via Nix (produces result/lib/ngx_http_isonim_module.so)
build-nix:
    nix build .#module --override-input nim-faststreams path:../nim-faststreams --override-input isonim path:../isonim --override-input nim-everywhere path:../nim-everywhere

# Build nginx-with-isonim wrapper
build-nginx:
    nix build .#nginx-with-isonim --override-input nim-faststreams path:../nim-faststreams --override-input isonim path:../isonim --override-input nim-everywhere path:../nim-everywhere -o result-nginx

# Build baseline module
build-baseline:
    nix build .#nginx-baseline -o result-baseline

# --- Tests ---

# The request, response, request context and server-function modules are
# IsoNim's (isonim/server); the mock-mode tests compile against the sibling.
isonim_path := "--path:../isonim/src"

# Run unit tests (mock mode, no real nginx needed)
test:
    nim c -r -d:isNginxTest {{isonim_path}} tests/test_adapter.nim
    nim c -r -d:isNginxTest {{isonim_path}} tests/test_handler.nim
    nim c -r -d:isNginxTest {{isonim_path}} tests/test_config.nim
    nim c -r -d:isNginxTest {{isonim_path}} tests/test_streaming_handler.nim
    nim c -r -d:isNginxTest {{isonim_path}} tests/test_request.nim
    nim c -r -d:isNginxTest {{isonim_path}} tests/test_response.nim
    nim c -r -d:isNginxTest {{isonim_path}} tests/test_nginx_headers.nim
    nim c -r -d:isNginxTest {{isonim_path}} tests/test_rpc.nim
    nim c -r tests/test_nimcache_is_worktree_local.nim

# Run E2E integration tests (mock mode)
test-e2e-integration:
    nim c -r -d:isNginxTest {{isonim_path}} tests/test_e2e_integration.nim

# Run IsoNim SSR tests (requires ../isonim)
test-isonim:
    nim c -r -d:isServer -d:asyncBackend=none --path:../isonim/src --path:../nim-everywhere/src --path:../nim-faststreams --path:../nim-stew tests/test_isonim_e2e.nim

# Run the end-to-end tests: real nginx with the real module, driven by curl.
# One release build with the e2e apps serves all but the debug-build test,
# which builds its own debug module.
test-e2e: build-e2e
    #!/usr/bin/env bash
    set -euo pipefail
    export NGX_ISONIM_E2E_MODULE="$PWD/build/e2e/release/ngx_http_isonim_module.so"
    bash tests/e2e/test_e2e.sh
    for t in test_request_context test_csp_nonce test_max_buffer_size test_rpc; do
      nim c -r --hints:off -o:build/e2e/$t tests/e2e/$t.nim
    done
    bash tests/e2e/test_streaming_debug.sh
    bash tests/e2e/test_rpc_asan.sh

# The isonim_rpc end-to-end tests against a module built with
# AddressSanitizer (part of test-e2e)
test-e2e-asan:
    bash tests/e2e/test_rpc_asan.sh

# CI: `just test-e2e`, its full output also in test-logs/test-e2e.log
# (.github/workflows/e2e.yml uploads that directory).
ci-test-e2e:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    just test-e2e 2>&1 | tee test-logs/test-e2e.log

# Run all tests
test-all: test test-e2e-integration test-isonim test-e2e

# --- Server management ---

# Start baseline nginx (pure C, port 8089)
start-baseline: build-baseline
    @mkdir -p /tmp/ngx-baseline-test
    @pkill -f "nginx.*8089" 2>/dev/null || true
    @sleep 0.5
    ./result-baseline/bin/nginx-baseline 2>/dev/null
    @echo "Baseline running on http://127.0.0.1:8089/"

# Start isonim nginx (port 8088)
start-isonim: build-nginx
    @mkdir -p /tmp/ngx-isonim-test/{client_body,proxy,fastcgi,uwsgi,scgi,logs}
    @pkill -f "nginx.*8088" 2>/dev/null || true
    @sleep 0.5
    @rm -f /tmp/ngx-isonim-test/nginx.pid
    ./result-nginx/bin/nginx-isonim 2>/dev/null
    @echo "IsoNim running on http://127.0.0.1:8088/"

# Start both servers
start-all: start-baseline start-isonim

# Stop all nginx
stop:
    @pkill -f "nginx.*808[89]" 2>/dev/null || true
    @echo "Stopped."

# --- Profiling & Benchmarks ---

# Profile SSR pipeline phases (no nginx, pure Nim measurement)
profile-ssr:
    @mkdir -p benchmarks/results
    nim c -d:release -d:danger --opt:speed -d:isServer -d:asyncBackend=none \
      --path:../isonim/src --path:../nim-everywhere/src --path:../nim-faststreams --path:../nim-stew \
      -o:benchmarks/ssr_profile \
      benchmarks/ssr_profile.nim
    benchmarks/ssr_profile

# Run wrk against running servers (start them first with just start-all)
bench-nginx DURATION="10s" CONNECTIONS="10":
    bash benchmarks/run-wrk.sh {{DURATION}} {{CONNECTIONS}}

# Full benchmark: build, start, profile, wrk, stop
bench-all:
    @echo "=== Building ==="
    just build-baseline
    just build-nginx
    @echo ""
    @echo "=== SSR Pipeline Profile ==="
    just profile-ssr
    @echo ""
    @echo "=== Starting servers ==="
    just start-all
    @sleep 2
    @echo ""
    @echo "=== wrk Benchmark (10s, 10 connections) ==="
    just bench-nginx 10s 10
    @echo ""
    just stop

# Quick benchmark (5s, good for iteration)
bench-quick:
    just start-all
    @sleep 2
    just bench-nginx 5s 10
    just stop

# --- Cleanup ---

# Remove nimcache and build artifacts
clean:
    rm -rf nimcache build benchmarks/ssr_profile
    rm -f tests/test_adapter tests/test_handler tests/test_config
    rm -f tests/test_streaming_handler tests/test_e2e_integration
    rm -f tests/test_isonim_e2e tests/test_request tests/test_response
    rm -f tests/test_nginx_headers tests/test_nimcache_is_worktree_local
    rm -rf tests/nimcache benchmarks/nimcache

# Entering the dev shell from another git repository must write nothing there.
# Runs `nix develop`, so it is not part of the in-shell test recipes.
test-dev-shell:
    bash tests/test_dev_shell_writes_nothing_elsewhere.sh
