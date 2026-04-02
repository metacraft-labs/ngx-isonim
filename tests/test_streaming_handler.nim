## test_streaming_handler.nim
##
## Streaming SSR handler tests (M4).
## Compile with: nim c -r -d:isNginxTest tests/test_streaming_handler.nim

import unittest
import std/strutils
import ../src/nginx_types
import ../src/config
import ../src/app_registry
import ../src/nginx_adapter
import ../src/handler

# ---------------------------------------------------------------------------
# Simulated streaming app fixtures
# ---------------------------------------------------------------------------

proc streamingHelloApp*(onChunk: proc(chunk: string), onComplete: proc()) =
  ## Simulates a streaming app with one Suspense boundary.
  ## Shell is flushed first, then the boundary resolves.
  onChunk("<html><body><h1>Hello</h1><!--suspense-placeholder-1--></body></html>")
  onChunk("<script>document.querySelector('[data-hk=\"1\"]').innerHTML='<p>Loaded!</p>'</script>")
  onComplete()

proc streamingMultiBoundaryApp*(onChunk: proc(chunk: string), onComplete: proc()) =
  ## Simulates a streaming app with three Suspense boundaries.
  onChunk("<html><body><h1>App</h1><!--B1--><!--B2--><!--B3--></body></html>")
  onChunk("<script>document.querySelector('[data-hk=\"1\"]').innerHTML='<p>B1</p>'</script>")
  onChunk("<script>document.querySelector('[data-hk=\"2\"]').innerHTML='<p>B2</p>'</script>")
  onChunk("<script>document.querySelector('[data-hk=\"3\"]').innerHTML='<p>B3</p>'</script>")
  onComplete()

proc streamingShellOnlyApp*(onChunk: proc(chunk: string), onComplete: proc()) =
  ## Simulates a streaming app with no Suspense boundaries — just the shell.
  onChunk("<html><body><h1>Static</h1></body></html>")
  onComplete()

proc streamingShellErrorApp*(onChunk: proc(chunk: string), onComplete: proc()) =
  ## Simulates an app that throws during shell render (before any chunks).
  raise newException(ValueError, "shell render failed")

proc streamingBoundaryErrorApp*(onChunk: proc(chunk: string), onComplete: proc()) =
  ## Simulates an app that throws during boundary resolution (after shell).
  onChunk("<html><body><h1>Shell</h1></body></html>")
  raise newException(ValueError, "boundary resolution failed")

proc makeStreamingSlowApp*(chunks: seq[string]): StreamingAppRenderer =
  ## Returns a streaming app that emits the given chunks in order.
  return proc(onChunk: proc(chunk: string), onComplete: proc()) =
    for chunk in chunks:
      onChunk(chunk)
    onComplete()

# ---------------------------------------------------------------------------
# Helper: create a stream + request pair for testing
# ---------------------------------------------------------------------------

proc newTestStream(): tuple[req: NgxHttpRequest, stream: NginxOutputStream] =
  let req = newMockRequest(uri = "/", httpMethod = "GET")
  let stream = newNginxOutputStream(req)
  (req, stream)

# ---------------------------------------------------------------------------
# Shell emission tests
# ---------------------------------------------------------------------------

suite "Streaming Handler - Shell Emission":
  setup:
    resetMockState()
    clearApps()

  test "shell_flushed_as_first_chunk":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    check res.chunks.len >= 2
    check res.chunks[0].contains("<html>")
    check res.chunks[0].contains("<h1>Hello</h1>")

  test "shell_chunk_reaches_stream_before_subsequent_chunks":
    ## Each chunk triggers a separate write+flush on the adapter.
    ## We verify by checking the mock output filter was called at least once
    ## per chunk (each flush calls output_filter).
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()
    resetMockState()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    # 2 content chunks + close = at least 3 output_filter calls
    # (each flush + close calls output_filter)
    check mockOutputFilterCalls >= 3

  test "ttfb_metric_records_shell_flush_time":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    check metrics.ttfbMs >= 0.0
    check metrics.ttfbMs <= metrics.totalMs


# ---------------------------------------------------------------------------
# Suspense boundary tests
# ---------------------------------------------------------------------------

suite "Streaming Handler - Suspense Boundaries":
  setup:
    resetMockState()
    clearApps()

  test "multiple_chunks_flushed_in_order":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-multi",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingMultiBoundaryApp)

    check res.statusCode == 200
    check res.chunks.len == 4  # shell + 3 boundaries
    check res.chunks[0].contains("<html>")
    check res.chunks[1].contains("data-hk=\"1\"")
    check res.chunks[2].contains("data-hk=\"2\"")
    check res.chunks[3].contains("data-hk=\"3\"")

  test "each_chunk_triggers_separate_flush":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-multi",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()
    resetMockState()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingMultiBoundaryApp)

    check res.statusCode == 200
    # 4 content flushes + 1 close = 5 output_filter calls
    check mockOutputFilterCalls >= 5

  test "boundary_replacement_scripts_have_correct_format":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    # Second chunk is the boundary replacement script
    check res.chunks[1].startsWith("<script>")
    check res.chunks[1].endsWith("</script>")
    check res.chunks[1].contains("innerHTML")

  test "configurable_chunk_sequence":
    let chunks = @[
      "<html><body><!--P1--><!--P2--></body></html>",
      "<script>fill(1)</script>",
      "<script>fill(2)</script>",
    ]
    let app = makeStreamingSlowApp(chunks)
    let conf = parseLocConf(
      enabled = true,
      appName = "custom",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 200
    check res.chunks.len == 3
    check res.chunks[0] == chunks[0]
    check res.chunks[1] == chunks[1]
    check res.chunks[2] == chunks[2]


# ---------------------------------------------------------------------------
# Completion tests
# ---------------------------------------------------------------------------

suite "Streaming Handler - Completion":
  setup:
    resetMockState()
    clearApps()

  test "hydration_script_appended_after_all_boundaries":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    # Last chunk should be the hydration script
    check res.chunks[^1].contains("window._$HY")

  test "hydration_script_with_nonce":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = true,
      scriptNonce = "test-nonce-42",
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    check res.chunks[^1].contains("nonce=\"test-nonce-42\"")

  test "no_hydration_script_when_disabled":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    for chunk in res.chunks:
      check not chunk.contains("window._$HY")

  test "stream_closed_after_completion":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()
    resetMockState()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    # The close() call sends a lastBuf chain through output_filter.
    # Total calls: 2 content flushes + 1 close = 3
    check mockOutputFilterCalls >= 3

  test "shell_only_app_completes_correctly":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-static",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingShellOnlyApp)

    check res.statusCode == 200
    check res.chunks.len == 1
    check res.chunks[0].contains("<h1>Static</h1>")


# ---------------------------------------------------------------------------
# Error handling tests
# ---------------------------------------------------------------------------

suite "Streaming Handler - Error Handling":
  setup:
    resetMockState()
    clearApps()

  test "app_throws_during_shell_render_returns_500":
    let conf = parseLocConf(
      enabled = true,
      appName = "broken-shell",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingShellErrorApp)

    check res.statusCode == 500
    check res.body.contains("render error")

  test "app_throws_during_boundary_resolution_partial_result":
    let conf = parseLocConf(
      enabled = true,
      appName = "broken-boundary",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingBoundaryErrorApp)

    # Should still return 200 since shell was already sent
    check res.statusCode == 200
    # First chunk is the shell
    check res.chunks[0].contains("<h1>Shell</h1>")
    # Error chunk appended
    check res.chunks[^1].contains("streaming error")

  test "invalid_config_returns_500_before_streaming":
    let conf = parseLocConf(enabled = true, appName = "")
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 500
    check res.body.contains("invalid configuration")

  test "nil_streaming_app_returns_404":
    let conf = parseLocConf(
      enabled = true,
      appName = "missing",
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, nil)

    check res.statusCode == 404
    check res.body.contains("app not found")

  test "post_request_returns_405":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
    )
    let reqInfo = RequestInfo(uri: "/post", httpMethod: "POST", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 405

  test "put_request_returns_405":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
    )
    let reqInfo = RequestInfo(uri: "/put", httpMethod: "PUT", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 405


# ---------------------------------------------------------------------------
# Metrics tests
# ---------------------------------------------------------------------------

suite "Streaming Handler - Metrics":
  setup:
    resetMockState()
    clearApps()

  test "chunk_count_matches_onChunk_calls":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-multi",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingMultiBoundaryApp)

    check res.statusCode == 200
    check metrics.chunkCount == 4  # shell + 3 boundaries

  test "chunk_count_includes_hydration_script":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    # 2 app chunks + 1 hydration script = 3
    check metrics.chunkCount == 3

  test "total_bytes_matches_sum_of_chunk_sizes":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    var expectedBytes = 0
    for chunk in res.chunks:
      expectedBytes += chunk.len
    check metrics.totalBytes == expectedBytes

  test "ttfb_positive_and_less_than_total":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    check metrics.ttfbMs >= 0.0
    check metrics.totalMs >= metrics.ttfbMs

  test "total_bytes_zero_for_error_before_streaming":
    let conf = parseLocConf(enabled = true, appName = "")
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 500
    check metrics.totalBytes == 0
    check metrics.chunkCount == 0


# ---------------------------------------------------------------------------
# Chunked transfer encoding tests
# ---------------------------------------------------------------------------

suite "Streaming Handler - Chunked Transfer Encoding":
  setup:
    resetMockState()
    clearApps()

  test "transfer_encoding_chunked_header_set":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    var hasTransferEncoding = false
    for (k, v) in res.headers:
      if k == "Transfer-Encoding" and v == "chunked":
        hasTransferEncoding = true
    check hasTransferEncoding

  test "content_length_not_set":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    var hasContentLength = false
    for (k, v) in res.headers:
      if k == "Content-Length":
        hasContentLength = true
    check not hasContentLength

  test "content_type_header_set":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    var hasContentType = false
    for (k, v) in res.headers:
      if k == "Content-Type" and v == "text/html; charset=utf-8":
        hasContentType = true
    check hasContentType


# ---------------------------------------------------------------------------
# HEAD request tests
# ---------------------------------------------------------------------------

suite "Streaming Handler - HEAD Requests":
  setup:
    resetMockState()
    clearApps()

  test "head_request_returns_200_no_body":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "HEAD", headers: @[])
    let (req, stream) = newTestStream()
    resetMockState()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, streamingHelloApp)

    check res.statusCode == 200
    check res.body == ""
    check res.chunks.len == 0
    # No body written means no output_filter calls for body (only close)
    # Actually HEAD skips both write and close in our impl
    check mockOutputFilterCalls == 0


# ---------------------------------------------------------------------------
# App Registry integration tests
# ---------------------------------------------------------------------------

suite "Streaming Handler - App Registry":
  setup:
    resetMockState()
    clearApps()

  test "register_and_lookup_streaming_app":
    registerStreamingApp("hello-stream", streamingHelloApp)
    let app = getStreamingApp("hello-stream")
    check app != nil

  test "lookup_nonexistent_streaming_app_returns_nil":
    let app = getStreamingApp("no-such-app")
    check app == nil

  test "clear_removes_streaming_apps":
    registerStreamingApp("a", streamingHelloApp)
    registerStreamingApp("b", streamingMultiBoundaryApp)
    clearApps()
    check getStreamingApp("a") == nil
    check getStreamingApp("b") == nil

  test "streaming_and_sync_registries_are_independent":
    registerApp("myapp", proc(): string = "<div>sync</div>")
    registerStreamingApp("myapp", streamingHelloApp)
    let syncApp = getApp("myapp")
    let streamApp = getStreamingApp("myapp")
    check syncApp != nil
    check streamApp != nil
    check syncApp() == "<div>sync</div>"

  test "registered_streaming_app_works_with_handler":
    registerStreamingApp("hello-stream", streamingHelloApp)
    let app = getStreamingApp("hello-stream")
    let conf = parseLocConf(
      enabled = true,
      appName = "hello-stream",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 200
    check res.chunks.len == 2
    check res.body.contains("<h1>Hello</h1>")
