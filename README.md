# ngx-isonim

nginx dynamic module that serves IsoNim SSR responses directly from nginx
worker processes.

The module compiles IsoNim applications (Nim C target) into a shared library
loaded by nginx, handling HTTP requests via nginx's event-driven async I/O.

## Architecture

The key integration piece is a faststreams `OutputStreamVTable` adapter that
translates `OutputStream.write` calls into `ngx_buf_t` allocations and
`ngx_http_output_filter` calls. This makes nginx the third async backend
alongside Chronos and asyncdispatch.

## Build

```bash
# Enter dev shell
direnv allow   # or: nix develop

# Build the module
just build

# Run unit tests (mock mode, no real nginx needed)
just test

# Run E2E tests against real nginx
just test-e2e
```

## Project Structure

```
src/
  nginx_types.nim         # nginx C API bindings
  config.nim              # Directive parsing
  nginx_adapter.nim       # faststreams OutputStreamVTable for nginx
  handler.nim             # Request handler
  ngx_http_isonim_module.c  # Module registration (C boilerplate)
tests/
  test_adapter.nim        # Adapter unit tests
  test_handler.nim        # Handler logic tests
  test_config.nim         # Config parsing tests
  e2e/                    # E2E tests against real nginx
nix/
  nginx-dev-headers.nix   # Extracts configured nginx headers
  ngx-isonim-module.nix   # Builds the .so module
  nginx-with-isonim.nix   # Wraps nginx with the module
```

## nginx Directives

```nginx
location /app {
    isonim_ssr on;
    isonim_ssr_app my_app;
    isonim_ssr_hydration on;
    isonim_ssr_script_nonce "abc123";
    isonim_ssr_max_buffer_size 1048576;
}
```
