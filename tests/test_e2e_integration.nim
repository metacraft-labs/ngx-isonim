## test_e2e_integration.nim
##
## E2E integration tests that exercise the full handler pipeline
## (app registry -> handler -> adapter -> response) without a real
## nginx process.
##
## These tests simulate what the curl-based E2E tests would verify:
## status codes, Content-Type, body content, hydration markers, etc.
##
## Compile with: nim c -r -d:isNginxTest tests/test_e2e_integration.nim

import unittest
import std/[strutils, times]
import ../src/nginx_types
import ../src/config
import ../src/app_registry
import ../src/nginx_adapter
import ../src/handler
import e2e/apps/hello
import e2e/apps/counter
import e2e/apps/task_manager
import e2e/apps/async_app

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc newTestStream(): tuple[req: NgxHttpRequest, stream: NginxOutputStream] =
  let req = newMockRequest(uri = "/", httpMethod = "GET")
  let stream = newNginxOutputStream(req)
  (req, stream)

proc getHeader(res: HandlerResult; key: string): string =
  for (k, v) in res.headers:
    if k == key:
      return v
  return ""

proc hasHeader(res: HandlerResult; key: string; value: string): bool =
  for (k, v) in res.headers:
    if k == key and v == value:
      return true
  return false

# ---------------------------------------------------------------------------
# E2E Integration - Hello App
# ---------------------------------------------------------------------------

suite "E2E Integration - Hello App":
  setup:
    resetMockState()
    clearApps()
    registerApp("hello", helloApp)

  test "GET /hello returns 200 with HTML body":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "GET", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.hasHeader("Content-Type", "text/html; charset=utf-8")
    check res.body.contains("<h1>Hello from IsoNim</h1>")
    check res.body.contains("<html>")
    check res.body.contains("</html>")

  test "GET /hello Content-Length matches body length":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "GET", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.getHeader("Content-Length") == $res.body.len

  test "GET /hello without hydration has no script tag":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "GET", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check not res.body.contains("<script>")
    check not res.body.contains("window._$HY")

  test "HEAD /hello returns 200 with headers but empty body":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "HEAD", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body == ""
    check res.chunks.len == 0
    check res.hasHeader("Content-Type", "text/html; charset=utf-8")
    # Content-Length still set for HEAD
    let cl = res.getHeader("Content-Length")
    check cl.len > 0
    check parseInt(cl) > 0

  test "POST /hello returns 405":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "POST", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 405
    check res.body.contains("Method Not Allowed")

  test "full nimHandleRequest flow writes to output stream":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let req = newMockRequest(uri = "/hello", httpMethod = "GET")
    resetMockState()
    let rc = nimHandleRequest(req)

    check rc == NGX_OK
    check lastHandlerResult.statusCode == 200
    check lastHandlerResult.body.contains("Hello from IsoNim")
    # Output stream was used (flush + close = at least 2 output_filter calls)
    check mockOutputFilterCalls >= 1


# ---------------------------------------------------------------------------
# E2E Integration - Task Manager
# ---------------------------------------------------------------------------

suite "E2E Integration - Task Manager":
  setup:
    resetMockState()
    clearApps()
    registerApp("task_manager", proc(): string = taskManagerDetailApp())

  test "GET /tasks returns 200 with task list":
    let conf = parseLocConf(
      enabled = true,
      appName = "task_manager",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri:"/tasks", httpMethod: "GET", headers: @[])
    let app = getApp("task_manager")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("<h1>Task Manager</h1>")
    check res.body.contains("<li>Task 1</li>")
    check res.body.contains("<li>Task 2</li>")
    check res.body.contains("<li>Task 3</li>")
    check res.body.contains("3 items")

  test "GET /tasks has hydration script when enabled":
    let conf = parseLocConf(
      enabled = true,
      appName = "task_manager",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri:"/tasks", httpMethod: "GET", headers: @[])
    let app = getApp("task_manager")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("window._$HY")

  test "task manager with custom tasks":
    registerApp("task_manager_custom", proc(): string =
      taskManagerDetailApp(@["Buy milk", "Write code"]))
    let conf = parseLocConf(
      enabled = true,
      appName = "task_manager_custom",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/tasks", httpMethod: "GET", headers: @[])
    let app = getApp("task_manager_custom")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("Buy milk")
    check res.body.contains("Write code")
    check res.body.contains("2 items")

  test "full nimHandleRequest flow for task manager":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "task_manager",
      hydrationEnabled = true,
    )
    let req = newMockRequest(uri = "/tasks", httpMethod = "GET")
    resetMockState()
    let rc = nimHandleRequest(req)

    check rc == NGX_OK
    check lastHandlerResult.statusCode == 200
    check lastHandlerResult.body.contains("Task Manager")
    check lastHandlerResult.body.contains("window._$HY")


# ---------------------------------------------------------------------------
# E2E Integration - Counter App
# ---------------------------------------------------------------------------

suite "E2E Integration - Counter App":
  setup:
    resetMockState()
    clearApps()

  test "counter with default count":
    registerApp("counter", proc(): string = counterApp())
    let conf = parseLocConf(
      enabled = true,
      appName = "counter",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/counter", httpMethod: "GET", headers: @[])
    let app = getApp("counter")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("Count: 0")
    check res.body.contains("<button>+1</button>")

  test "counter with custom count":
    registerApp("counter_42", proc(): string = counterApp(42))
    let conf = parseLocConf(
      enabled = true,
      appName = "counter_42",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/counter", httpMethod: "GET", headers: @[])
    let app = getApp("counter_42")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("Count: 42")


# ---------------------------------------------------------------------------
# E2E Integration - Streaming
# ---------------------------------------------------------------------------

suite "E2E Integration - Streaming":
  setup:
    resetMockState()
    clearApps()

  test "hello streaming app emits single content chunk":
    registerStreamingApp("hello_stream", helloStreamingApp)
    let app = getStreamingApp("hello_stream")
    let conf = parseLocConf(
      enabled = true,
      appName = "hello_stream",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 200
    check res.hasHeader("Transfer-Encoding", "chunked")
    check res.chunks.len == 1
    check res.body.contains("Hello from IsoNim")
    check metrics.chunkCount == 1

  test "async dashboard streaming emits shell then boundaries":
    registerStreamingApp("async_dashboard", asyncStreamingApp)
    let app = getStreamingApp("async_dashboard")
    let conf = parseLocConf(
      enabled = true,
      appName = "async_dashboard",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri:"/async", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 200
    check res.hasHeader("Transfer-Encoding", "chunked")
    # 4 app chunks + 1 hydration script = 5
    check res.chunks.len == 5
    # Shell chunk contains the page structure
    check res.chunks[0].contains("<h1>Dashboard</h1>")
    check res.chunks[0].contains("Loading...")
    # Boundary 1 resolves with data
    check res.chunks[1].contains("Data loaded: 42 items")
    # Boundary 2 resolves with footer
    check res.chunks[2].contains("Loaded at server time")
    # Closing tag
    check res.chunks[3] == "</body></html>"
    # Last chunk is hydration script
    check res.chunks[4].contains("window._$HY")

  test "streaming TTFB metric is set":
    registerStreamingApp("async_dashboard", asyncStreamingApp)
    let app = getStreamingApp("async_dashboard")
    let conf = parseLocConf(
      enabled = true,
      appName = "async_dashboard",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/async", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 200
    check metrics.ttfbMs >= 0.0
    check metrics.totalMs >= metrics.ttfbMs
    check metrics.chunkCount == 4  # 4 app chunks, no hydration

  test "streaming with hydration script has nonce":
    registerStreamingApp("hello_stream", helloStreamingApp)
    let app = getStreamingApp("hello_stream")
    let conf = parseLocConf(
      enabled = true,
      appName = "hello_stream",
      hydrationEnabled = true,
      scriptNonce = "test-nonce-e2e",
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 200
    check res.chunks[^1].contains("nonce=\"test-nonce-e2e\"")
    check res.chunks[^1].contains("window._$HY")

  test "streaming without hydration has no script appended":
    registerStreamingApp("async_dashboard", asyncStreamingApp)
    let app = getStreamingApp("async_dashboard")
    let conf = parseLocConf(
      enabled = true,
      appName = "async_dashboard",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/async", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 200
    check res.chunks.len == 4  # Only app chunks, no hydration
    for chunk in res.chunks:
      check not chunk.contains("window._$HY")

  test "streaming Content-Type is text/html":
    registerStreamingApp("hello_stream", helloStreamingApp)
    let app = getStreamingApp("hello_stream")
    let conf = parseLocConf(
      enabled = true,
      appName = "hello_stream",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 200
    check res.hasHeader("Content-Type", "text/html; charset=utf-8")


# ---------------------------------------------------------------------------
# E2E Integration - Error Scenarios
# ---------------------------------------------------------------------------

suite "E2E Integration - Error Scenarios":
  setup:
    resetMockState()
    clearApps()

  test "unregistered app returns 404":
    let conf = parseLocConf(
      enabled = true,
      appName = "nonexistent",
    )
    let reqInfo = RequestInfo(uri:"/nonexistent", httpMethod: "GET", headers: @[])
    let app = getApp("nonexistent")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 404
    check res.body.contains("app not found")

  test "unregistered app via nimHandleRequest returns 404":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "nonexistent",
    )
    let req = newMockRequest(uri = "/nonexistent", httpMethod = "GET")
    let rc = nimHandleRequest(req)

    check rc == NGX_HTTP_NOT_FOUND

  test "invalid config (enabled but no app name) returns 500":
    let conf = parseLocConf(enabled = true, appName = "")
    let reqInfo = RequestInfo(uri:"/bad", httpMethod: "GET", headers: @[])
    let app: AppRenderer = proc(): string = "should not render"
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 500
    check res.body.contains("invalid configuration")

  test "POST method returns 405":
    registerApp("hello", helloApp)
    let conf = parseLocConf(enabled = true, appName = "hello")
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "POST", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 405

  test "PUT method returns 405":
    registerApp("hello", helloApp)
    let conf = parseLocConf(enabled = true, appName = "hello")
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "PUT", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 405

  test "DELETE method returns 405":
    registerApp("hello", helloApp)
    let conf = parseLocConf(enabled = true, appName = "hello")
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "DELETE", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 405

  test "app render failure returns 500":
    registerApp("broken", proc(): string =
      raise newException(ValueError, "render crashed"))
    let conf = parseLocConf(enabled = true, appName = "broken")
    let reqInfo = RequestInfo(uri:"/broken", httpMethod: "GET", headers: @[])
    let app = getApp("broken")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 500
    check res.body.contains("render error")

  test "streaming app nil returns 404":
    let conf = parseLocConf(enabled = true, appName = "missing")
    let reqInfo = RequestInfo(uri:"/missing", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()
    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, nil)

    check res.statusCode == 404

  test "streaming POST returns 405":
    registerStreamingApp("hello_stream", helloStreamingApp)
    let app = getStreamingApp("hello_stream")
    let conf = parseLocConf(enabled = true, appName = "hello_stream")
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "POST", headers: @[])
    let (req, stream) = newTestStream()
    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 405


# ---------------------------------------------------------------------------
# E2E Integration - Hydration
# ---------------------------------------------------------------------------

suite "E2E Integration - Hydration":
  setup:
    resetMockState()
    clearApps()
    registerApp("hello", helloApp)

  test "hydration enabled appends _$HY script":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri:"/hello-hydrated", httpMethod: "GET", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("window._$HY")
    check res.body.contains("events:[\"click\",\"input\"]")
    check res.body.contains("completed:new WeakSet")
    check res.body.contains("registry:new Map")

  test "hydration disabled has no _$HY script":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "GET", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check not res.body.contains("window._$HY")
    check not res.body.contains("<script>")

  test "CSP nonce included in hydration script":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = true,
      scriptNonce = "abc123",
    )
    let reqInfo = RequestInfo(uri:"/hello-csp", httpMethod: "GET", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("nonce=\"abc123\"")
    check res.body.contains("window._$HY")

  test "CSP nonce empty means no nonce attribute":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = true,
      scriptNonce = "",
    )
    let reqInfo = RequestInfo(uri:"/hello-hydrated", httpMethod: "GET", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("<script>window._$HY")
    check not res.body.contains("nonce=")

  test "hydration Content-Length includes script bytes":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri:"/hello-hydrated", httpMethod: "GET", headers: @[])
    let app = getApp("hello")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    let cl = parseInt(res.getHeader("Content-Length"))
    # Content-Length must account for both the HTML and the hydration script
    check cl == res.body.len
    check cl > helloApp().len  # Longer than HTML alone

  test "streaming hydration appended as last chunk":
    registerStreamingApp("hello_stream", helloStreamingApp)
    let app = getStreamingApp("hello_stream")
    let conf = parseLocConf(
      enabled = true,
      appName = "hello_stream",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "GET", headers: @[])
    let (req, stream) = newTestStream()

    let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)

    check res.statusCode == 200
    check res.chunks[^1].contains("window._$HY")
    # Hydration is the last chunk, not mixed into content
    check not res.chunks[0].contains("window._$HY")


# ---------------------------------------------------------------------------
# E2E Integration - Performance
# ---------------------------------------------------------------------------

suite "E2E Integration - Performance":
  setup:
    resetMockState()
    clearApps()
    registerApp("hello", helloApp)
    registerApp("task_manager", proc(): string = taskManagerDetailApp())
    registerStreamingApp("async_dashboard", asyncStreamingApp)

  test "1000 sync requests complete in under 1 second":
    let conf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri:"/hello", httpMethod: "GET", headers: @[])
    let app = getApp("hello")

    let start = cpuTime()
    for i in 0 ..< 1000:
      let res = handleSsrRequest(conf, reqInfo, app)
      check res.statusCode == 200
    let elapsed = (cpuTime() - start) * 1000.0

    echo "  1000 sync requests: ", elapsed.formatFloat(ffDecimal, 1), " ms"
    check elapsed < 1000.0  # Should complete well under 1 second

  test "1000 task manager requests complete in under 1 second":
    let conf = parseLocConf(
      enabled = true,
      appName = "task_manager",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri:"/tasks", httpMethod: "GET", headers: @[])
    let app = getApp("task_manager")

    let start = cpuTime()
    for i in 0 ..< 1000:
      let res = handleSsrRequest(conf, reqInfo, app)
      check res.statusCode == 200
    let elapsed = (cpuTime() - start) * 1000.0

    echo "  1000 task manager requests: ", elapsed.formatFloat(ffDecimal, 1), " ms"
    check elapsed < 1000.0

  test "1000 streaming requests complete in under 2 seconds":
    let conf = parseLocConf(
      enabled = true,
      appName = "async_dashboard",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri:"/async", httpMethod: "GET", headers: @[])
    let app = getStreamingApp("async_dashboard")

    let start = cpuTime()
    for i in 0 ..< 1000:
      resetMockState()
      let (req, stream) = newTestStream()
      let (res, metrics) = handleStreamingRequest(conf, reqInfo, stream, app)
      check res.statusCode == 200
    let elapsed = (cpuTime() - start) * 1000.0

    echo "  1000 streaming requests: ", elapsed.formatFloat(ffDecimal, 1), " ms"
    check elapsed < 2000.0

  test "nimHandleRequest throughput (1000 requests)":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )

    let start = cpuTime()
    for i in 0 ..< 1000:
      resetMockState()
      let req = newMockRequest(uri = "/hello", httpMethod = "GET")
      let rc = nimHandleRequest(req)
      check rc == NGX_OK
    let elapsed = (cpuTime() - start) * 1000.0

    echo "  1000 nimHandleRequest calls: ", elapsed.formatFloat(ffDecimal, 1), " ms"
    check elapsed < 2000.0
