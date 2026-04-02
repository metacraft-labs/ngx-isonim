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

# Run E2E tests against real nginx
test-e2e:
    bash tests/e2e/test_e2e.sh

# Remove nimcache and build artifacts
clean:
    rm -rf nimcache build
    rm -f tests/test_adapter tests/test_handler tests/test_config
    rm -rf tests/nimcache
