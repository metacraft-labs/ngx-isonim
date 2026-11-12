## test_e2e_integration.nim
##
## The module's request flow end to end, short of nginx itself: a request
## as nginx parsed it, the location configuration, the app registry, the
## pipeline, and the response the sink receives.  Mirrors the scenarios
## tests/e2e/test_e2e.sh runs over real nginx, plus a throughput check.
##
## Mocks: `newMockRequest` stands in for `ngx_http_request_t` and the
## recording sink for nginx's filters (handler.nim `serveMockRequest`).  The
## pipeline and the request mapping are the module's own code.
##
## Compile with: nim c -r -d:isNginxTest tests/test_e2e_integration.nim

import unittest
import std/[strutils, times]
import ../src/nginx_types
import ../src/handler
import e2e/apps/hello
import e2e/apps/counter
import e2e/apps/task_manager
import e2e/apps/async_app

proc conf(app: string; hydration = false; mode = tmStreaming;
          maxBufferSize = 0): IsoNimLocConf =
  parseLocConf(enabled = true, appName = app, hydrationEnabled = hydration,
               mode = mode, maxBufferSize = maxBufferSize)

proc request(uri: string; meth = "GET"; args = "";
             headers: seq[(string, string)] = @[]): NgxHttpRequest =
  result = newMockRequest(uri = uri, httpMethod = meth)
  result.args = args
  result.headers = headers

proc registerFixtures() =
  clearApps()
  registerApp("hello", helloApp)
  registerApp("task_manager", proc(): string = taskManagerDetailApp())
  registerApp("custom_tasks", proc(req: SsrRequest; resp: SsrResponse): string =
    taskManagerDetailApp(req.queryParam("tasks").split(',')))
  registerApp("counter", proc(req: SsrRequest; resp: SsrResponse): string =
    counterApp(parseInt(req.queryParam("count", "0"))))
  registerStreamingApp("async_dashboard", asyncStreamingApp)

suite "E2E Integration - Hello App":
  setup:
    registerFixtures()

  test "GET /hello returns 200 with the page":
    for mode in [tmStreaming, tmBuffered]:
      let rec = serveMockRequest(conf("hello", mode = mode), request("/hello"))
      check rec.rc == NGX_OK
      check rec.status == 200
      check rec.contentType == "text/html; charset=utf-8"
      check rec.body == "<html><body><h1>Hello from IsoNim</h1></body></html>"

  test "buffered Content-Length matches the body":
    let rec = serveMockRequest(conf("hello", hydration = true, mode = tmBuffered),
                               request("/hello"))
    check rec.contentLength == rec.body.len
    check rec.body.len > "<html><body><h1>Hello from IsoNim</h1></body></html>".len

  test "streaming responses are chunked (no Content-Length)":
    let rec = serveMockRequest(conf("hello"), request("/hello"))
    check rec.contentLength == -1

  test "HEAD returns the headers and no body":
    let rec = serveMockRequest(conf("hello", mode = tmBuffered),
                               request("/hello", "HEAD"))
    check rec.rc == NGX_OK
    check rec.status == 200
    check rec.contentLength == "<html><body><h1>Hello from IsoNim</h1></body></html>".len
    check rec.body == ""

  test "POST, PUT and DELETE return 405":
    for m in ["POST", "PUT", "DELETE"]:
      check serveMockRequest(conf("hello"), request("/hello", m)).rc ==
        NGX_HTTP_NOT_ALLOWED

suite "E2E Integration - apps reading the request":
  setup:
    registerFixtures()

  test "task manager renders the tasks from the query":
    let rec = serveMockRequest(conf("custom_tasks"),
      request("/tasks", args = "tasks=Alpha,Beta"))
    check "<li>Alpha</li><li>Beta</li>" in rec.body
    check "2 items" in rec.body

  test "default task manager":
    let rec = serveMockRequest(conf("task_manager"), request("/tasks"))
    check "<li>Task 1</li>" in rec.body
    check "3 items" in rec.body

  test "counter renders the count from the query":
    check "Count: 0" in serveMockRequest(conf("counter"), request("/c")).body
    check "Count: 41" in serveMockRequest(conf("counter"),
      request("/c", args = "count=41")).body

suite "E2E Integration - Streaming":
  setup:
    registerFixtures()

  test "async dashboard emits the shell, then the boundaries, then the end":
    let rec = serveMockRequest(conf("async_dashboard", hydration = true),
                               request("/async"))
    check rec.rc == NGX_OK
    check rec.sends[0].data.contains("<h1>Dashboard</h1>")
    check rec.sends[1].data.contains("Data loaded: 42 items")
    check rec.sends[2].data.contains("Loaded at server time")
    check rec.sends[3].data == "</body></html>"
    check rec.sends[4].data.startsWith("<script nonce=")
    check rec.sends[4].last

  test "streaming without hydration ends with an empty last buffer":
    let rec = serveMockRequest(conf("async_dashboard"), request("/async"))
    check rec.sends[^1].data == ""
    check rec.sends[^1].last
    check "window._$HY" notin rec.body

suite "E2E Integration - Error Scenarios":
  setup:
    registerFixtures()

  test "unregistered app returns 500":
    let rec = serveMockRequest(conf("nonexistent"), request("/x"))
    check rec.rc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check "nonexistent" in rec.log[0][1]

  test "app render failure returns 500":
    registerApp("failing", proc(): string = raise newException(ValueError, "x"))
    check serveMockRequest(conf("failing"), request("/f")).rc ==
      NGX_HTTP_INTERNAL_SERVER_ERROR

  test "over the size limit returns 500 on the buffered transport":
    let rec = serveMockRequest(
      conf("hello", mode = tmBuffered, maxBufferSize = 10), request("/hello"))
    check rec.rc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check not rec.headersSent

suite "E2E Integration - Performance":
  setup:
    registerFixtures()

  test "1000 buffered requests complete in under 1 second":
    let c = conf("hello", hydration = true, mode = tmBuffered)
    let start = cpuTime()
    for i in 0 ..< 1000:
      check serveMockRequest(c, request("/hello")).rc == NGX_OK
    let elapsed = (cpuTime() - start) * 1000.0
    echo "  1000 buffered requests: ", elapsed.formatFloat(ffDecimal, 1), " ms"
    check elapsed < 1000.0

  test "1000 streaming requests complete in under 2 seconds":
    let c = conf("async_dashboard", hydration = true)
    let start = cpuTime()
    for i in 0 ..< 1000:
      check serveMockRequest(c, request("/async")).rc == NGX_OK
    let elapsed = (cpuTime() - start) * 1000.0
    echo "  1000 streaming requests: ", elapsed.formatFloat(ffDecimal, 1), " ms"
    check elapsed < 2000.0
