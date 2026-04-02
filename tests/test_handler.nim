## test_handler.nim
##
## Handler logic tests using mock nginx.
## Compile with: nim c -r -d:isNginxTest tests/test_handler.nim

import unittest
import std/strutils
import ../src/nginx_types
import ../src/config
import ../src/handler

suite "Handler - SSR Request":
  test "valid_config_returns_200":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let res = handleSsrRequest(conf, reqInfo, proc(): string =
      "<div><h1>Hello from IsoNim SSR</h1></div>"
    )

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
    let res = handleSsrRequest(conf, reqInfo, proc(): string =
      "<div>content</div>"
    )

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
    let res = handleSsrRequest(conf, reqInfo, proc(): string =
      "<div>content</div>"
    )

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
    let res = handleSsrRequest(conf, reqInfo, proc(): string =
      "<div>content</div>"
    )

    check res.statusCode == 200
    check res.body.contains("nonce=\"r4nd0m\"")

  test "invalid_config_returns_500":
    let conf = parseLocConf(enabled = true, appName = "")
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let res = handleSsrRequest(conf, reqInfo, proc(): string =
      "should not render"
    )

    check res.statusCode == 500
    check res.body.contains("invalid configuration")

  test "render_error_returns_500":
    let conf = parseLocConf(enabled = true, appName = "test-app")
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let res = handleSsrRequest(conf, reqInfo, proc(): string =
      raise newException(ValueError, "render failed")
    )

    check res.statusCode == 500
    check res.body.contains("render error")

  test "content_type_header_set":
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = false,
    )
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    let res = handleSsrRequest(conf, reqInfo, proc(): string =
      "<div>content</div>"
    )

    var hasContentType = false
    for (k, v) in res.headers:
      if k == "Content-Type" and "text/html" in v:
        hasContentType = true
    check hasContentType


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


suite "Handler - C→Nim Bridge (nimHandleRequest)":
  setup:
    resetMockState()

  test "nimHandleRequest_returns_NGX_OK_for_valid_request":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "bridge-app",
      hydrationEnabled = false,
    )
    testAppRenderer = proc(): string =
      "<div>Bridge OK</div>"
    let req = newMockRequest(uri = "/test", httpMethod = "GET")
    let rc = nimHandleRequest(req)
    check rc == NGX_OK

  test "nimHandleRequest_returns_error_for_nil_renderer":
    testLocConf = parseLocConf(enabled = true, appName = "app")
    testAppRenderer = nil
    let req = newMockRequest()
    let rc = nimHandleRequest(req)
    check rc == NGX_ERROR

  test "nimHandleRequest_returns_error_for_invalid_config":
    testLocConf = parseLocConf(enabled = true, appName = "")
    testAppRenderer = proc(): string = "should not render"
    let req = newMockRequest()
    let rc = nimHandleRequest(req)
    check rc == NGX_HTTP_INTERNAL_SERVER_ERROR

  test "nimHandleRequest_extracts_uri_and_method":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "extract-app",
      hydrationEnabled = false,
    )
    testAppRenderer = proc(): string =
      "<div>extracted</div>"
    let req = newMockRequest(uri = "/api/data", httpMethod = "POST")
    req.headers = @[("Content-Type", "application/json")]
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    # Verify the handler actually processed the request
    check lastHandlerResult.statusCode == 200
    check lastHandlerResult.body.contains("extracted")

  test "nimHandleRequest_extracts_headers_from_mock":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "header-app",
      hydrationEnabled = false,
    )
    testAppRenderer = proc(): string = "<div>headers</div>"
    let req = newMockRequest(uri = "/")
    req.headers = @[
      ("Accept", "text/html"),
      ("X-Custom", "value"),
    ]
    let reqInfo = extractRequestInfo(req)
    check reqInfo.uri == "/"
    check reqInfo.httpMethod == "GET"
    check reqInfo.headers.len == 2
    check reqInfo.headers[0] == ("Accept", "text/html")
    check reqInfo.headers[1] == ("X-Custom", "value")

  test "nimHandleRequest_creates_output_stream":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "stream-app",
      hydrationEnabled = false,
    )
    testAppRenderer = proc(): string =
      "<div>streamed</div>"
    let req = newMockRequest()
    resetMockState()
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    # The handler writes through the NginxOutputStream which calls
    # ngx_http_output_filter.  Check that the mock recorded the calls.
    check mockOutputFilterCalls >= 1  # flush + close

  test "nimHandleRequest_response_headers_via_handler_result":
    testLocConf = parseLocConf(
      enabled = true,
      appName = "resp-app",
      hydrationEnabled = false,
    )
    testAppRenderer = proc(): string = "<div>response</div>"
    let req = newMockRequest()
    let rc = nimHandleRequest(req)
    check rc == NGX_OK
    # Verify the handler result contains the Content-Type header.
    var foundContentType = false
    for (k, v) in lastHandlerResult.headers:
      if k == "Content-Type" and "text/html" in v:
        foundContentType = true
    check foundContentType
