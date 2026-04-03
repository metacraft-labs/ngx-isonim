# ngx-isonim build targets

# Compile the nginx module .so (via Nix or direct nim c)
build:
    nim c \
      --mm:orc \
      --noMain \
      --app:lib \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/core" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/event" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/http" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/http/modules" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/os/unix" \
      --passC:"-I$NGX_DEV_HEADERS/include/nginx/objs" \
      -o:build/ngx_http_isonim_module.so \
      src/handler.nim

# Run unit tests (mock mode, no real nginx needed)
test:
    nim c -r -d:isNginxTest tests/test_adapter.nim
    nim c -r -d:isNginxTest tests/test_handler.nim
    nim c -r -d:isNginxTest tests/test_config.nim
    nim c -r -d:isNginxTest tests/test_streaming_handler.nim

# Run E2E integration tests (mock mode, no real nginx needed)
test-e2e-integration:
    nim c -r -d:isNginxTest tests/test_e2e_integration.nim

# Run IsoNim SSR tests (requires isonim source in ../isonim)
test-isonim:
    nim c -r -d:isServer --path:../isonim/src tests/test_isonim_e2e.nim

# Run all tests: unit + E2E integration (no real nginx needed)
test-all: test test-e2e-integration

# Run E2E tests against real nginx (requires nix build .#nginx-with-isonim)
test-e2e:
    bash tests/e2e/test_e2e.sh

# Remove nimcache and build artifacts
clean:
    rm -rf nimcache build
    rm -f tests/test_adapter tests/test_handler tests/test_config
    rm -f tests/test_streaming_handler tests/test_e2e_integration
    rm -f tests/test_isonim_e2e
    rm -rf tests/nimcache
