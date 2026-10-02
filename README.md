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

# Run E2E tests against real nginx (builds the module with the test apps)
just test-e2e
```

## Project Structure

```
src/
  ngx_http_isonim_module.c  # Module registration, directives, C helpers
  handler.nim             # Nim entry point (nim_handle_request)
  serve.nim               # The request pipeline (shared with the unit tests)
  request.nim             # SsrRequest: what a renderer receives
  response.nim            # SsrResponse: status, headers, cookies, redirects, CSP nonce
  response_body.nim       # ResponseBody: the streaming writer
  app_registry.nim        # App name -> renderer
  ssr_router.nim          # routedApp: per-request routing via IsoNim's SSR router
  config.nim              # Directive model
  nginx_types.nim         # nginx C API bindings (and their mocks)
scripts/
  build-module.sh         # The module build (release or debug)
tests/
  test_*.nim              # Unit tests (mock mode)
  e2e/                    # E2E tests against real nginx
nix/
  nginx-dev-headers.nix   # Extracts configured nginx headers
  ngx-isonim-module.nix   # Builds the .so module (runs build-module.sh)
  nginx-with-isonim.nix   # Wraps nginx with the module
```

## nginx Directives

```nginx
location /app {
    isonim_ssr on;
    isonim_ssr_app my_app;
    isonim_ssr_hydration on;          # bootstrap script with a per-response CSP nonce
    isonim_ssr_mode streaming;        # default; or: buffered
    isonim_ssr_max_buffer_size 1m;    # 0 (default) = unlimited
}
```

## Writing an App

```nim
registerApp("my_app", proc(req: SsrRequest; resp: SsrResponse): string =
  if not req.hasCookie("sid"):
    resp.redirect("/login", 303)
    return ""
  resp.setHeader("Cache-Control", "private, no-cache, must-revalidate")
  resp.setHeader("Content-Security-Policy",
                 "script-src 'self' " & resp.cspNonceSource)
  "<h1>Hello " & req.queryParam("name", "world") & "</h1>")
```

See `isonim-specs/isonim-nginx.md` for the full contract.
