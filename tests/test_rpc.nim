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
## slow handler does not hold up another.  The body reading, the 413s, and
## the worker's event loop are covered against real nginx
## (tests/e2e/test_rpc.nim).

import std/[unittest, json, strutils, times, monotimes]
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
