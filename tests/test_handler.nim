## test_handler.nim
##
## Handler logic tests using mock nginx.
## Compile with: nim c -r -d:isNginxTest tests/test_handler.nim

import unittest
import std/strutils
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
