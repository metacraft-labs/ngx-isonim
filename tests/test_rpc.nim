## The isonim_rpc pipeline (rpc.nim) in mock mode: the code nginx runs once
## the request body is read, over a recording sink in place of nginx's
## header and output filters, with asyncdispatch driven by `poll` in place
## of the worker's event loop (async_loop.nim) and an asyncdispatch timer in
## place of the nginx timer for isonim_rpc_timeout.
##
## Covered here: the response of a server function and of an async app
## (status, headers, Content-Length body, finalization), failures (a
## raising handler or server function, an unknown or non-async app), the
## timeout, a request released by nginx while its handler runs, and that a
## slow handler does not hold up another; and the streaming of async apps
## (IFP-M30): the commit on the first flush, the chunk and last-buffer
## flags, whole responses, HEAD/204/304, failures and the size limit before
## and after the commit point, the timeout after it, a failed send, a
## released request, and the body writer's lifetime.  The body reading, the
## 413s, the worker's event loop, and the streaming over the wire
## (backpressure, slow and disconnecting clients) are covered against real
## nginx (tests/e2e/test_rpc.nim, tests/e2e/test_async_streaming.nim).
##
## Mocks: the recording sink stands in for nginx's header and output
## filters, and `poll` for the worker's event loop.  Justified because these
## tests pin down which bytes and buffer flags rpc.nim hands nginx, call by
## call, which the wire cannot show (nginx coalesces sends); the sink is the
## same `ResponseSink` interface the module drives, and every behaviour
## asserted here is also exercised end to end by the real-nginx tests named
## above.

import std/[unittest, json, strutils, sequtils, times, monotimes]
import ../src/[handler, nginx_types]
import isonim/server/[pragma, rpc]

proc add(a, b: int): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  return a + b

proc slowEcho(ms: int; s: string): Future[string] {.server(auth = aPublic, csrf = csrfAnon).} =
  await sleepAsync(ms)
  return s

proc broken(): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  raise newException(KeyError, "no such row")

proc subscribe(email: string): Future[bool] {.action(auth = aPublic, csrf = csrfAnon, target = "/thanks").} =
  return true

proc post(path, body: string; contentType = "application/json";
          browser = true; httpMethod = "POST"): SsrRequest =
  var h = @[("Host", "forum.test"), ("Origin", "https://forum.test"),
            ("Sec-Fetch-Site", "same-origin"),
            ("Cookie", anonCsrfCookieName & "=tok"),
            ("Content-Type", contentType)]
  if browser:
    h.add((csrfHeaderName, "tok"))
    h.add((contextHeaderName, "inc:1"))
  newSsrRequest(httpMethod, path, path, "", h, "127.0.0.1", body)

proc header(r: RecordedResponse; name: string): string =
  for (k, v) in r.headers:
    if cmpIgnoreCase(k, name) == 0: return v

proc logged(r: RpcRecording; part: string): bool =
  for (_, msg) in r.response.log:
    if part in msg: return true

suite "isonim_rpc - server functions":
  test "a call answers with the result, Content-Length and no-store":
    let r = serveRpcRecorded(post(addUrl, """{"a": 2, "b": 40}"""))
    check r.finished and r.finalRc == NGX_OK
    check r.response.status == 200
    check r.response.contentType == "application/json"
    check r.response.body == "42"
    check r.response.contentLength == 2
    check r.response.header("Cache-Control") == "private, no-cache, no-store, must-revalidate"
    check r.response.header(contextHeaderName) == "inc:1"
    check r.response.sends.len == 1 and r.response.sends[0].last

  test "the framework's refusals go out as JSON":
    let r = serveRpcRecorded(post(addUrl, "", httpMethod = "GET"))
    check r.response.status == 405
    check r.response.header("Allow") == "POST"
    check parseJson(r.response.body)["error"].getStr == "method_not_allowed"
    let csrf = serveRpcRecorded(post(addUrl, """{"a":1,"b":1}""", browser = false))
    check csrf.response.status == 403

  test "a raising server function is 500, logged with the error":
    let r = serveRpcRecorded(post(brokenUrl, "{}"))
    check r.response.status == 500
    check r.response.body == """{"error":"internal"}"""
    check r.logged("server function raised KeyError: no such row")

  test "a no-JS form submission of an action is a bodiless 303":
    let r = serveRpcRecorded(post(subscribeUrl, "email=a%40b&_csrf=tok",
      contentType = "application/x-www-form-urlencoded", browser = false))
    check r.response.status == 303
    check r.response.header("Location") == "/thanks"
    check r.response.contentLength == 0
    check r.response.body == ""

suite "isonim_rpc - async apps":
  setup:
    clearApps()
    registerAsyncApp("echo", proc(ctx: RequestContext): Future[void] {.async.} =
      await sleepAsync(1)
      ctx.response.setHeader("X-Echo", ctx.request.httpMethod)
      ctx.respondJson(201, $(%*{"body": ctx.request.body})))
    registerAsyncApp("raises", proc(ctx: RequestContext): Future[void] {.async.} =
      ctx.response.setHeader("X-Partial", "1")
      raise newException(ValueError, "bad state"))
    registerApp("ssr", proc(): string = "<p>ssr</p>")

  test "the app's response goes out as it left it":
    let r = serveRpcRecorded(post("/anything", "hello"), "echo")
    check r.response.status == 201
    check r.response.header("X-Echo") == "POST"
    check parseJson(r.response.body) == %*{"body": "hello"}

  test "an app that raises is 500, without what it had shaped":
    let r = serveRpcRecorded(post("/x", ""), "raises")
    check r.response.status == 500
    check r.response.header("X-Partial") == ""
    check r.logged("handler raised ValueError: bad state")

  test "an unknown app, or one that is not async, is 500 and logged":
    let u = serveRpcRecorded(post("/x", ""), "nope")
    check u.finalRc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check not u.response.headersSent
    check u.logged("no app is registered as \"nope\"")
    let s = serveRpcRecorded(post("/x", ""), "ssr")
    check s.finalRc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check s.logged("is not an async app")

suite "isonim_rpc - timeout, release, concurrency":
  test "a handler past isonim_rpc_timeout gets 504; its late result is dropped":
    let r = startRpcRecorded(post(slowEchoUrl, """{"ms": 300, "s": "late"}"""),
                             timeoutMs = 50)
    while not r.finished: poll(10)
    check r.response.status == 504
    check r.response.body == """{"error":"timeout"}"""
    check r.logged("isonim_rpc_timeout")
    # Let the handler finish: it must not respond (or finalize) again.
    while hasPendingOperations(): poll(10)
    check r.response.sends.len == 1
    check "late" notin r.response.body

  test "a request nginx released is never answered":
    let r = startRpcRecorded(post(slowEchoUrl, """{"ms": 50, "s": "x"}"""))
    r.state.release()
    while hasPendingOperations(): poll(10)
    check not r.finished
    check not r.response.headersSent

  test "a slow handler does not hold up another":
    let start = getMonoTime()
    let slow = startRpcRecorded(post(slowEchoUrl, """{"ms": 300, "s": "slow"}"""))
    let fast = startRpcRecorded(post(addUrl, """{"a": 1, "b": 2}"""))
    var fastAt = Duration()
    while not (slow.finished and fast.finished):
      poll(5)
      if fast.finished and fastAt == Duration(): fastAt = getMonoTime() - start
    check fast.response.body == "3"
    check slow.response.body == "\"slow\""
    check fastAt < initDuration(milliseconds = 150)
    check getMonoTime() - start >= initDuration(milliseconds = 300)

suite "isonim_rpc - streaming async apps (IFP-M30)":
  # The pipeline of rpc.nim over the recording sink: what reaches nginx's
  # header and output filters, and when.  Backpressure, slow clients and
  # the wire are covered against real nginx (tests/e2e/test_async_streaming.nim).
  var gate: Future[void]
  setup:
    clearApps()
    gate = newFuture[void]("test gate")
    registerAsyncApp("stream", proc(ctx: RequestContext): Future[void] {.async.} =
      let body = ctx.bodyWriter
      ctx.response.setHeader("X-Stream", "1")
      body.write("<shell>")
      body.flush()
      await gate
      ctx.write("<ctx>")
      body.write("<rest>")
      body.flush()
      body.write("<tail>"))
    registerAsyncApp("whole", proc(ctx: RequestContext): Future[void] {.async.} =
      let body = ctx.bodyWriter
      body.write("<a>")
      ctx.write("<b>")
      body.write("<c>"))
    registerAsyncApp("late_header", proc(ctx: RequestContext): Future[void] {.async.} =
      let body = ctx.bodyWriter
      body.write("x")
      body.flush()
      ctx.response.setHeader("X-Late", "1"))
    registerAsyncApp("raise_after", proc(ctx: RequestContext): Future[void] {.async.} =
      let body = ctx.bodyWriter
      body.write("<shell>")
      body.flush()
      await gate
      raise newException(ValueError, "after the commit"))
    registerAsyncApp("raise_before", proc(ctx: RequestContext): Future[void] {.async.} =
      let body = ctx.bodyWriter
      body.write("<partial>")
      raise newException(ValueError, "before the commit"))
    registerAsyncApp("status", proc(ctx: RequestContext): Future[void] {.async.} =
      let body = ctx.bodyWriter
      ctx.response.status = parseInt(ctx.request.queryParam("s", "200"))
      body.write("dropped")
      body.flush()
      body.write("dropped too"))
    registerAsyncApp("big", proc(ctx: RequestContext): Future[void] {.async.} =
      let body = ctx.bodyWriter
      for i in 0 ..< 10:
        body.write(repeat('x', 100))
        body.flush())
    registerAsyncApp("keeps_writing", proc(ctx: RequestContext): Future[void] {.async.} =
      let body = ctx.bodyWriter
      body.write("<shell>")
      body.flush()
      await gate
      body.write("<more>"))

  test "the first flush commits chunked; flushes go out at once; completion ends it":
    let r = startRpcRecorded(post("/s", ""), "stream")
    check r.response.headersSent
    check r.response.contentLength == -1
    check r.response.header("X-Stream") == "1"
    check r.response.sends.len == 1
    check r.response.sends[0] == RecordedSend(data: "<shell>", flush: true, last: false)
    check not r.finished
    gate.complete()
    while not r.finished: poll(5)
    check r.finalRc == NGX_OK
    check r.response.body == "<shell><ctx><rest><tail>"
    check r.response.sends[^1].last
    check r.response.sends[^1].flush

  test "a handler that never flushes is answered whole with Content-Length":
    let r = serveRpcRecorded(post("/w", ""), "whole")
    check r.response.contentLength == 9
    check r.response.body == "<a><b><c>"
    check r.response.sends.len == 1
    check r.response.sends[0].last and not r.response.sends[0].flush

  test "shaping after the first flush is refused and terminates the response":
    let r = serveRpcRecorded(post("/l", ""), "late_header")
    check r.finalRc == NGX_ERROR
    check r.response.header("X-Late") == ""
    check r.logged("ResponseCommittedError")
    check r.logged("response terminated after the headers were sent")
    check not r.response.sends[^1].last

  test "raising after the commit point: terminated without the last buffer":
    let r = startRpcRecorded(post("/r", ""), "raise_after")
    gate.complete()
    while not r.finished: poll(5)
    check r.finalRc == NGX_ERROR
    check r.response.status == 200
    check r.response.body == "<shell>"
    check r.response.sends.allIt(not it.last)
    check r.logged("handler raised ValueError: after the commit")

  test "raising before the commit point: 500 without what was written":
    let r = serveRpcRecorded(post("/b", ""), "raise_before")
    check r.response.status == 500
    check r.response.body == """{"error":"internal"}"""
    check r.logged("before the commit")

  test "HEAD, 204 and 304: the commit sends the headers only, writes are dropped":
    let h = serveRpcRecorded(newSsrRequest("HEAD", "/h", "/h", "", @[],
                                           "127.0.0.1", ""), "status")
    check h.finalRc == NGX_OK
    check h.response.headersSent
    check h.response.sends.len == 0
    for s in ["204", "304"]:
      let r = serveRpcRecorded(newSsrRequest("GET", "/h", "/h?s=" & s, "s=" & s,
                                             @[], "127.0.0.1", ""), "status")
      check r.response.status == parseInt(s)
      check r.response.sends.len == 0
      check r.finalRc == NGX_OK

  test "isonim_ssr_max_buffer_size after the commit point terminates, logged":
    let r = serveRpcRecorded(post("/big", ""), "big",
                             opts = RpcOptions(maxBufferSize: 450))
    check r.finalRc == NGX_ERROR
    check r.response.body == repeat('x', 400)
    check r.logged("exceeds isonim_ssr_max_buffer_size (450 bytes)")
    let whole = serveRpcRecorded(post("/w", ""), "whole",
                                 opts = RpcOptions(maxBufferSize: 5))
    check whole.response.status == 500
    check whole.logged("exceeds isonim_ssr_max_buffer_size (5 bytes); responding 500")

  test "isonim_rpc_timeout after the commit point: terminated, logged, late writes raise":
    let r = startRpcRecorded(post("/k", ""), "keeps_writing", timeoutMs = 30)
    while not r.finished: poll(5)
    check r.finalRc == NGX_ERROR
    check r.logged("the handler did not complete within isonim_rpc_timeout; " &
                   "response terminated after the headers were sent")
    let sent = r.response.sends.len
    gate.complete()
    while hasPendingOperations(): poll(5)
    check r.response.sends.len == sent        # the late write never reached nginx

  test "a failed send fails the handler's flush with ClientConnectionError":
    let r = startRpcRecorded(post("/s", ""), "stream",
                             recording = RecordingOptions(failBodySendAt: 2))
    gate.complete()
    while not r.finished: poll(5)
    check r.finalRc == NGX_ERROR
    check r.logged("the client connection is gone")
    check r.response.body == "<shell>"

  test "a request released mid-stream: the next write raises, nothing is sent":
    var seen = ""
    registerAsyncApp("observe", proc(ctx: RequestContext): Future[void] {.async.} =
      let body = ctx.bodyWriter
      body.write("<shell>")
      body.flush()
      await gate
      try:
        body.write("<more>")
      except ClientConnectionError as e:
        seen = e.msg)
    let r = startRpcRecorded(post("/o", ""), "observe")
    let before = rpcRequestsReleased()
    r.state.release()
    check rpcRequestsReleased() == before + 1
    gate.complete()
    while hasPendingOperations(): poll(5)
    check "released" in seen
    check not r.finished
    check r.response.body == "<shell>"

  test "bodyWriter belongs to the running request only":
    var ctxSeen: RequestContext
    registerAsyncApp("keep_ctx", proc(ctx: RequestContext): Future[void] {.async.} =
      ctxSeen = ctx
      discard ctx.bodyWriter)
    discard serveRpcRecorded(post("/c", ""), "keep_ctx")
    expect ValueError:
      discard ctxSeen.bodyWriter
    expect ValueError:
      discard newRequestContext(post("/x", "")).bodyWriter

  test "hydrationEnabled carries the location's isonim_ssr_hydration":
    var seen: seq[bool]
    registerAsyncApp("hy", proc(ctx: RequestContext): Future[void] {.async.} =
      seen.add ctx.hydrationEnabled)
    discard serveRpcRecorded(post("/h", ""), "hy",
                             opts = RpcOptions(hydration: true))
    discard serveRpcRecorded(post("/h", ""), "hy",
                             opts = RpcOptions(hydration: false))
    check seen == @[true, false]
