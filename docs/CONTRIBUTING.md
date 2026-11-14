# Contributing to ngx-isonim

## Prerequisites

- **Nix** with flakes enabled (`experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`)
- **The metacraft workspace** with sibling repos checked out:
  - `isonim` -- the IsoNim reactive framework (SSR renderer, DSL, signals)
  - `nim-faststreams` -- streaming I/O library used by the nginx adapter
  - `nim-stew` -- Nim utility library
- **direnv** for automatic Nix dev shell activation (recommended)

## Getting Started

```bash
cd ngx-isonim
direnv allow          # activates the Nix dev shell automatically
just test             # run unit tests (mock mode, no nginx required)
just test-isonim      # run SSR E2E tests (needs ../isonim)
```

If you don't use direnv, you can enter the dev shell manually with `nix develop`.

## Project Structure

```
ngx-isonim/
  src/
    ngx_http_isonim_module.c   # C entry point -- module registration, directives
    ngx_http_baseline_module.c # Pure-C baseline module for benchmark comparison
    handler.nim                # Request handler (method validation, rendering, response)
    nginx_adapter.nim          # faststreams OutputStreamVTable adapter for nginx
    nginx_types.nim            # nginx C API bindings (ngx_buf_t, ngx_chain_t, etc.)
    config.nim                 # Directive parsing (isonim_ssr, isonim_ssr_app, etc.)
    app_registry.nim           # App name -> renderer lookup table
    apps.nim                   # Default app registrations (production mode only)
  tests/
    test_adapter.nim           # Adapter unit tests
    test_handler.nim           # Handler logic tests
    test_config.nim            # Config parsing tests
    test_streaming_handler.nim # Streaming path tests
    test_e2e_integration.nim   # E2E integration tests (mock mode)
    test_isonim_e2e.nim        # Full IsoNim SSR E2E tests
  nix/
    nginx-dev-headers.nix      # Extracts configured nginx headers for compilation
    ngx-isonim-module.nix      # Builds the .so module
    nginx-with-isonim.nix      # Wraps nginx binary with the module loaded
  benchmarks/
    ssr_profile.nim            # SSR pipeline phase profiler
    run-wrk.sh                 # wrk benchmark runner script
    results/                   # Benchmark output (gitignored)
  scripts/                     # Auxiliary scripts
  flake.nix                    # Nix flake (inputs, packages, dev shell)
  Justfile                     # Build, test, and benchmark commands
  nim.cfg                      # Nim compiler configuration
```

## Building

### Local development build

```bash
just build
```

Runs `scripts/build-module.sh release`, producing
`build/ngx_http_isonim_module.so` (the Nim side plus the C module file, ORC
memory management). Requires `$NGX_DEV_HEADERS` to point at nginx
development headers (set automatically by the Nix dev shell).
`just build-debug` builds the same module in debug mode, and
`just build-e2e` with the apps the end-to-end tests drive.

### Nix-based build

```bash
just build-nix
```

Builds the module through Nix with local sibling overrides. Produces
`result/lib/ngx_http_isonim_module.so`.

### nginx binary with module loaded

```bash
just build-nginx
```

Builds a complete nginx binary that loads the isonim module. Output in
`result-nginx/bin/nginx-isonim`.

### Baseline module

```bash
just build-baseline
```

Builds a pure-C baseline nginx module that serves a static HTML response.
Used as a performance reference point -- the baseline represents the best
possible latency for an nginx content handler with no framework overhead.

## Testing

### Unit tests (mock mode)

```bash
just test
```

Runs all unit tests with `-d:isNginxTest`. In this mode, nginx C types
(`ngx_buf_t`, `ngx_chain_t`, etc.) are replaced with mock Nim types, so
tests can run without nginx headers or a running nginx instance. This
covers the adapter, handler, config parsing, and streaming handler.

### IsoNim SSR E2E tests

```bash
just test-isonim
```

Runs end-to-end tests that exercise the full rendering pipeline: IsoNim
reactive core, DSL, SSR renderer, and faststreams output. Requires the
`../isonim`, `../nim-faststreams`, and `../nim-stew` sibling repos.

### End-to-end tests (real nginx)

```bash
just test-e2e
```

Builds the module with the e2e apps and runs `tests/e2e/`: the curl smoke
test, request context and response shaping, per-response CSP nonces, the
buffer limit, and the streaming handler under a debug build.

### All tests

```bash
just test-all
```

Runs the unit, integration, IsoNim SSR and end-to-end tests.

### The `-d:isNginxTest` flag

The codebase uses `when defined(isNginxTest)` to switch between mock types
and real nginx C bindings. When writing new tests, always compile with
`-d:isNginxTest` so that nginx types are mocked. Production builds omit
this flag and link against real nginx headers.

## Running nginx

### Start servers

```bash
just start-isonim      # IsoNim module on port 8088
just start-baseline    # Baseline module on port 8089
just start-all         # Both servers
```

### Test a running server

```bash
curl http://127.0.0.1:8088/    # IsoNim SSR response
curl http://127.0.0.1:8089/    # Baseline static response
```

### Stop servers

```bash
just stop
```

## Profiling and Benchmarks

### SSR pipeline profiler

```bash
just profile-ssr
```

Measures each phase of the SSR pipeline (signal creation, memo evaluation,
DOM rendering, string serialization) in isolation. Outputs detailed timing
data to `benchmarks/results/ssr_profile.json`. This runs pure Nim code
without nginx -- useful for identifying bottlenecks in the rendering path.

### wrk benchmarks

```bash
just bench-nginx                    # default: 10s, 10 connections
just bench-nginx 30s 50             # custom duration and connections
```

Runs `wrk` HTTP load tests against running isonim and baseline servers.
Start the servers first with `just start-all`.

### Full benchmark cycle

```bash
just bench-all
```

Runs the complete cycle: build both modules, profile SSR, start servers,
run wrk benchmarks, and stop servers. Use this for reproducible benchmark
runs.

### Quick iteration

```bash
just bench-quick       # 5s benchmark, starts and stops servers automatically
```

### Interpreting results

Compare the isonim server (port 8088) against the baseline (port 8089).
The baseline represents the floor -- a pure-C handler serving static HTML
with zero framework overhead. The gap between baseline and isonim
throughput/latency shows the cost of the Nim rendering pipeline.

## Architecture

### Two transports

`isonim_ssr_mode` picks, per location, how the body travels:

1. **Streaming (default)** -- the status and headers go out on the
   renderer's first flush, each flush is sent to the client at once (nginx
   `flush` flag), and the response ends with `last_buf` (the terminating
   chunk).
2. **Buffered** -- the whole body is rendered first and sent with
   `Content-Length`.

Both run the same pipeline (`serve.nim`), which the unit tests also run
over a recording sink.

### Request flow

```
nginx request
  -> ngx_http_isonim_handler (C): location enabled? discard the body
    -> nim_handle_request (handler.nim): build the SsrRequest
      -> serve (serve.nim): method check, app lookup, render, hydration
         script with the per-response CSP nonce, max buffer size
        -> renderer(req, resp[, body])           (app_registry.nim)
        -> ngx_http_isonim_send_header / _send_body (C helpers)
          -> nginx header and output filters -> client
```

### Key abstractions

- **serve.nim** -- the request pipeline, shared by the module and the
  unit tests.
- **response_body.nim** -- the streaming writer; `outputStream` gives
  IsoNim's renderer a faststreams `OutputStream` (nim-faststreams'
  `nginx_adapters`), making nginx the third faststreams backend alongside
  Chronos and asyncdispatch.

- **app_registry.nim** -- a simple name-to-renderer lookup table. Apps
  register themselves at module init time.

- **config.nim** -- the directive model (`isonim_ssr`, `isonim_ssr_app`,
  `isonim_ssr_hydration`, `isonim_ssr_mode`, `isonim_ssr_max_buffer_size`)
  mirroring the C location configuration.

## Adding a New App

Register a renderer in `src/apps.nim`.  It receives the request and the
response it may shape:

```nim
registerApp("my_app", proc(req: SsrRequest; resp: SsrResponse): string =
  resp.setHeader("Cache-Control", "private, no-cache, must-revalidate")
  renderToString do () -> string:
    ui:
      tdiv(class = "my-app"):
        h1: text "Hello " & req.queryParam("name", "world")
)
```

A streaming renderer writes through a `ResponseBody`; IsoNim's Suspense
streaming takes its faststreams view:

```nim
registerStreamingApp("my_stream", proc(req: SsrRequest; resp: SsrResponse;
                                       body: ResponseBody) =
  let sr = renderToStream(shell, body.outputStream,
                          StreamOptions(nonce: resp.cspNonce))
  sr.ctx.resolveBoundary("b1", "<p>later</p>")
)
```

`routedApp(routes)` (src/ssr_router.nim) selects the component from the
request path with IsoNim's SSR router and answers unknown paths with 404.

Then configure the nginx location to serve it:

```nginx
location /my-app {
    isonim_ssr on;
    isonim_ssr_app my_app;
}
```

## Nix Flake

### Inputs

The flake pins three Nim library inputs from GitHub:

- `nim-faststreams` -- streaming I/O (metacraft-labs fork)
- `nim-stew` -- Nim utilities (status-im)
- `isonim` -- the IsoNim framework (metacraft-labs)

### Local overrides

To develop against local sibling checkouts instead of the pinned GitHub
revisions, create a `.env` file in the repo root:

```
NIX_FLAKE_OVERRIDE_INPUTS='nim-faststreams=path:../nim-faststreams nim-stew=path:../nim-stew isonim=path:../isonim'
```

This is picked up by `direnv-nix-flake-overrides` automatically.

### Packages

The flake exports several packages:

- `module` -- the `.so` shared library
- `baseline` -- the pure-C baseline module
- `nginx-with-isonim` -- nginx binary with isonim module loaded
- `nginx-baseline` -- nginx binary with baseline module loaded

## Cleanup

```bash
just clean             # remove nimcache, build artifacts, test binaries
```
