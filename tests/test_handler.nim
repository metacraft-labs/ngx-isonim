## test_handler.nim
##
## Handler logic tests using mock nginx.
## Compile with: nim c -r -d:isNginxTest tests/test_handler.nim

import unittest
import std/strutils
import ../src/nginx_types
import ../src/config
import ../src/app_registry
import ../src/handler
import e2e/apps/hello

# ---------------------------------------------------------------------------
# App Registry tests
# ---------------------------------------------------------------------------

suite "App Registry":
  setup:
    clearApps()

  test "register_and_lookup":
    registerApp("hello", helloApp)
    let renderer = getApp("hello")
    check renderer != nil
    check renderer().contains("Hello from IsoNim")

  test "lookup_nonexistent_returns_nil":
    let renderer = getApp("does-not-exist")
    check renderer == nil

  test "clear_removes_all_apps":
    registerApp("a", helloApp)
    registerApp("b", taskManagerApp)
    clearApps()
    check getApp("a") == nil
    check getApp("b") == nil

  test "overwrite_existing_app":
    registerApp("app", helloApp)
    registerApp("app", taskManagerApp)
    let renderer = getApp("app")
    check renderer != nil
    check renderer().contains("Task Manager")


# ---------------------------------------------------------------------------
# Handler - SSR Request (existing M2 tests, updated for M3)
# ---------------------------------------------------------------------------

suite "Handler - SSR Request":
  test "valid_config_returns_200":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let app: AppRenderer = proc(): string =
      "<div><h1>Hello from IsoNim SSR</h1></div>"
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("<div>")
    check res.body.contains("<h1>Hello from IsoNim SSR</h1>")
    check res.body.contains("</div>")

  test "hydration_script_included_when_enabled":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let app: AppRenderer = proc(): string =
      "<div>content</div>"
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("<script>")
    check res.body.contains("window._$HY")

  test "no_hydration_script_when_disabled":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let app: AppRenderer = proc(): string =
      "<div>content</div>"
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check not res.body.contains("window._$HY")

  test "csp_nonce_included_in_script":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = true,
      scriptNonce = "r4nd0m",
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let app: AppRenderer = proc(): string =
      "<div>content</div>"
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body.contains("nonce=\"r4nd0m\"")

  test "invalid_config_returns_500":
    let conf = parseLocConf(enabled = true, appName = "")
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let app: AppRenderer = proc(): string =
      "should not render"
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 500
    check res.body.contains("invalid configuration")

  test "render_error_returns_500":
    let conf = parseLocConf(enabled = true, appName = "test-app")
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let app: AppRenderer = proc(): string =
      raise newException(ValueError, "render failed")
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 500
    check res.body.contains("render error")

  test "content_type_header_set":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let app: AppRenderer = proc(): string =
      "<div>content</div>"
    let res = handleSsrRequest(conf, reqInfo, app)

    var hasContentType = false
    for (k, v) in res.headers:
      if k == "Content-Type" and v == "text/html; charset=utf-8":
        hasContentType = true
    check hasContentType

  test "content_length_header_matches_body":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let app: AppRenderer = proc(): string =
      "<div>content</div>"
    let res = handleSsrRequest(conf, reqInfo, app)

    var contentLength = ""
    for (k, v) in res.headers:
      if k == "Content-Length":
        contentLength = v
    check contentLength == $res.body.len

  test "app_nil_returns_404":
    let conf = parseLocConf(
      enabled = true,
      appName = "missing-app",
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let res = handleSsrRequest(conf, reqInfo, nil)

    check res.statusCode == 404
    check res.body.contains("app not found")

  test "post_request_returns_405":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "POST", headers: @[])
    let app: AppRenderer = proc(): string =
      "should not render"
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 405
    check res.body.contains("Method Not Allowed")

  test "put_request_returns_405":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "PUT", headers: @[])
    let app: AppRenderer = proc(): string =
      "should not render"
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 405

  test "head_request_returns_200_with_headers_no_body":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "HEAD", headers: @[])
    let htmlContent = "<div>content</div>"
    let app: AppRenderer = proc(): string =
      htmlContent
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body == ""  # HEAD: no body
    check res.chunks.len == 0  # HEAD: no chunks
    # Headers still set (including Content-Length for the full body)
    var hasContentType = false
    var contentLength = ""
    for (k, v) in res.headers:
      if k == "Content-Type":
        hasContentType = true
      if k == "Content-Length":
        contentLength = v
    check hasContentType
    check contentLength == $htmlContent.len

  test "head_request_with_hydration_content_length_includes_script":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "HEAD", headers: @[])
    let app: AppRenderer = proc(): string =
      "<div>content</div>"
    let res = handleSsrRequest(conf, reqInfo, app)

    check res.statusCode == 200
    check res.body == ""
    # Content-Length should account for the hydration script
    var contentLength = 0
    for (k, v) in res.headers:
      if k == "Content-Length":
        contentLength = parseInt(v)
    check contentLength > "<div>content</div>".len  # script was included in length


# ---------------------------------------------------------------------------
# Handler - Streaming SSR
# ---------------------------------------------------------------------------

suite "Handler - Streaming SSR":
  test "streaming_produces_chunks":
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-app",
      hydrationEnabled = true,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    var receivedChunks: seq[string] = @[]
    let res = handleStreamingSsrRequest(conf, reqInfo,
      proc(): string =
        "<html><body><h1>Streaming</h1></body></html>"
      ,
      proc(chunk: string) =
        receivedChunks.add(chunk)
    )

    check res.statusCode == 200
    check receivedChunks.len >= 2  # HTML + hydration script
    check res.body.contains("<html>")
    check res.body.contains("window._$HY")

  test "streaming_invalid_config":
    let conf = parseLocConf(enabled = true, appName = "")
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let res = handleStreamingSsrRequest(conf, reqInfo,
      proc(): string = "should not render",
      proc(chunk: string) = discard,
    )

    check res.statusCode == 500

  test "streaming_without_hydration":
    let conf = parseLocConf(
      enabled = true,
      appName = "app",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    var receivedChunks: seq[string] = @[]
    let res = handleStreamingSsrRequest(conf, reqInfo,
      proc(): string = "<div>hello</div>",
      proc(chunk: string) = receivedChunks.add(chunk),
    )

    check res.statusCode == 200
    check receivedChunks.len == 1  # Just the HTML, no hydration script
    check not res.body.contains("window._$HY")

  test "streaming_nil_app_returns_404":
    let conf = parseLocConf(
      enabled = true,
      appName = "missing",
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let res = handleStreamingSsrRequest(conf, reqInfo,
      nil,
      proc(chunk: string) = discard,
    )

    check res.statusCode == 404

  test "streaming_post_returns_405":
    let conf = parseLocConf(
      enabled = true,
      appName = "app",
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "POST", headers: @[])
    let res = handleStreamingSsrRequest(conf, reqInfo,
      proc(): string = "nope",
      proc(chunk: string) = discard,
    )

    check res.statusCode == 405


# ---------------------------------------------------------------------------
# Handler - Request Info
# ---------------------------------------------------------------------------

suite "Handler - Request Info":
  test "request_info_constructable":
    let reqInfo = RequestInfo(
      uri: "/test",
      httpMethod: "GET",
      headers: @[("Accept", "text/html")],
    )
    check reqInfo.uri == "/test"
    check reqInfo.httpMethod == "GET"
    check reqInfo.headers.len == 1

  test "handler_result_constructable":
    let res = HandlerResult(
      statusCode: 200,
      headers: @[("Content-Type", "text/html")],
      body: "<html></html>",
      chunks: @["<html></html>"],
    )
    check res.statusCode == 200
    check res.body == "<html></html>"


# ---------------------------------------------------------------------------
# Handler - Full nimHandleRequest flow (C->Nim bridge with app registry)
# ---------------------------------------------------------------------------

suite "Handler - nimHandleRequest with App Registry":
  setup:
    resetMockState()
    clearApps()

  test "registered_app_returns_NGX_OK_and_correct_body":
    registerApp("hello", helloApp)
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let req = newMockRequest(uri = "/", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    check lastHandlerResult.statusCode == 200
    check lastHandlerResult.body.contains("Hello from IsoNim")

  test "registered_app_with_hydration":
    registerApp("hello", helloApp)
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = true,
    )
    let req = newMockRequest(uri = "/", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    check lastHandlerResult.body.contains("window._$HY")

  test "registered_app_without_hydration":
    registerApp("hello", helloApp)
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let req = newMockRequest(uri = "/", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    check not lastHandlerResult.body.contains("window._$HY")

  test "hydration_script_has_csp_nonce":
    registerApp("hello", helloApp)
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = true,
      scriptNonce = "abc123",
    )
    let req = newMockRequest(uri = "/", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    check lastHandlerResult.body.contains("nonce=\"abc123\"")

  test "unregistered_app_returns_404":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "no-such-app",
    )
    let req = newMockRequest(uri = "/", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_HTTP_NOT_FOUND

  test "app_render_failure_returns_500":
    registerApp("broken", proc(): string =
      raise newException(ValueError, "render crashed")
    )
    testLocConf = parseLocConf(
      enabled = true,
      appName = "broken",
    )
    let req = newMockRequest(uri = "/", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check lastHandlerResult.body.contains("render error")

  test "invalid_config_enabled_but_no_app_name_returns_500":
    testLocConf = parseLocConf(enabled = true, appName = "")
    let req = newMockRequest(uri = "/", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check lastHandlerResult.body.contains("invalid configuration")

  test "head_request_returns_NGX_OK_no_body_written":
    registerApp("hello", helloApp)
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let req = newMockRequest(uri = "/", httpMethod = "HEAD")
    resetMockState()
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    check lastHandlerResult.statusCode == 200
    check lastHandlerResult.body == ""
    # No body written, so no output filter calls from body writing
    check mockOutputFilterCalls == 0

  test "post_request_returns_405":
    registerApp("hello", helloApp)
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
    )
    let req = newMockRequest(uri = "/", httpMethod = "POST")
    let rc = nimHandleRequest(req)
    check rc == NGX_HTTP_NOT_ALLOWED

  test "content_length_matches_body":
    registerApp("hello", helloApp)
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let req = newMockRequest(uri = "/", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    var contentLength = ""
    for (k, v) in lastHandlerResult.headers:
      if k == "Content-Length":
        contentLength = v
    check contentLength == $lastHandlerResult.body.len

  test "content_type_is_text_html_charset_utf8":
    registerApp("hello", helloApp)
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let req = newMockRequest(uri = "/", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    var contentType = ""
    for (k, v) in lastHandlerResult.headers:
      if k == "Content-Type":
        contentType = v
    check contentType == "text/html; charset=utf-8"

  test "output_stream_writes_body":
    registerApp("hello", helloApp)
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let req = newMockRequest()
    resetMockState()
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    # The handler writes through the NginxOutputStream which calls
    # ngx_http_output_filter.  Check that the mock recorded the calls.
    check mockOutputFilterCalls >= 1  # flush + close


# ---------------------------------------------------------------------------
# Multiple Apps
# ---------------------------------------------------------------------------

suite "Handler - Multiple Apps":
  setup:
    resetMockState()
    clearApps()

  test "two_apps_config_selects_correct_one":
    registerApp("hello", helloApp)
    registerApp("tasks", taskManagerApp)

    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    let req = newMockRequest()
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    check lastHandlerResult.body.contains("Hello from IsoNim")
    check not lastHandlerResult.body.contains("Task Manager")

  test "change_config_app_name_renders_different_app":
    registerApp("hello", helloApp)
    registerApp("tasks", taskManagerApp)

    # First request: hello app
    testLocConf = parseLocConf(
      enabled = true,
      appName = "hello",
      hydrationEnabled = false,
    )
    var req = newMockRequest()
    var rc = nimHandleRequest(req)
    check rc == NGX_OK
    check lastHandlerResult.body.contains("Hello from IsoNim")

    # Second request: tasks app
    testLocConf = parseLocConf(
      enabled = true,
      appName = "tasks",
      hydrationEnabled = false,
    )
    req = newMockRequest()
    rc = nimHandleRequest(req)
    check rc == NGX_OK
    check lastHandlerResult.body.contains("Task Manager")
    check lastHandlerResult.body.contains("Task 1")
