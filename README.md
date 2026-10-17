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
  handler.nim             # Nim entry points (nim_handle_request, nim_handle_rpc)
  serve.nim               # The SSR pipeline (shared with the unit tests)
  rpc.nim                 # The isonim_rpc pipeline (server functions, async apps)
  async_loop.nim          # Nim's event loop (asyncdispatch) inside the worker's
  request.nim             # SsrRequest (IsoNim's isonim/server/request)
  response.nim            # SsrResponse (IsoNim's isonim/server/response)
  response_body.nim       # ResponseBody: the streaming writer
  app_registry.nim        # App name -> renderer or async app
  apps.nim                # Apps compiled in (and -d:ngxIsonimAppModule=<file>)
  ssr_router.nim          # routedApp: per-request routing via IsoNim's SSR router
  config.nim              # Directive model
  shm_table.nim           # Shared-memory zones: shmTable, ShmTypedTable
  ngx_http_isonim_shm.h   # The zone header's layout (C and Nim)
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

# IsoNim server functions (POST <rpcPrefix>/<module>/<proc>), or with
# isonim_rpc_app an async app such as a route manifest's dispatch.
location /api/v1/rpc/ {
    isonim_rpc on;
    isonim_rpc_max_body_size 1m;      # default 1m; larger bodies get 413
    isonim_rpc_timeout 60s;           # default 60s; then 504
}
location / {
    isonim_rpc on;
    isonim_rpc_app forum;             # registerAsyncApp("forum", manifestApp(...))
}
```

An application is compiled into the module with
`scripts/build-module.sh release out.so -d:ngxIsonimAppModule=/abs/app.nim`;
the module calls the app module's `registerApps()`.

Node-wide state shared by every worker lives in a shared-memory zone,
declared in the `http` block and bound by name (`src/shm_table.nim`):

```nginx
http {
    # name: [a-z0-9_]{1,64}; size: 64k..4g; max_value: default 4k, <= size/4
    isonim_shm_zone forum_routes size=8m max_value=1k;
}
```

```nim
import shm_table
let routes = shmTable("forum_routes")          # ShmZoneError if undeclared
var value: string
let version = routes.get("example.org", value)  # Option[uint64]; value copied out
case routes.putIf("example.org", "cell-7", version.get(0)).kind
of stored: discard
of conflict: discard                            # another worker stored first
of tooLarge, full: discard
discard routes.incr("admitted:inst-1", 1, 0, 500)  # bounded counter
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

See `isonim-specs/spec/isonim-nginx.md` for the full contract.
