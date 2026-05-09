# ngx-isonim build and test targets

# --- Build ---

# Compile the nginx module .so (via Nix or direct nim c)
build:
    nim c \
      --mm:orc \
      --noMain \
      --app:lib \
      -d:useFaststreams \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/core" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/event" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/http" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/http/modules" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/os/unix" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/objs" \
      -o:build/ngx_http_isonim_module.so \
      src/handler.nim

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

# Run unit tests (mock mode, no real nginx needed)
test:
    nim c -r -d:isNginxTest tests/test_adapter.nim
    nim c -r -d:isNginxTest tests/test_handler.nim
    nim c -r -d:isNginxTest tests/test_config.nim
    nim c -r -d:isNginxTest tests/test_streaming_handler.nim

# Run E2E integration tests (mock mode)
test-e2e-integration:
    nim c -r -d:isNginxTest tests/test_e2e_integration.nim

# Run IsoNim SSR tests (requires ../isonim)
test-isonim:
    nim c -r -d:isServer -d:asyncBackend=none --path:../isonim/src --path:../nim-everywhere/src --path:../nim-faststreams --path:../nim-stew tests/test_isonim_e2e.nim

# Run all tests
test-all: test test-e2e-integration

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
    rm -f tests/test_isonim_e2e
    rm -rf tests/nimcache benchmarks/nimcache
