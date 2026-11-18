## test_reload_inflight.nim
##
## A graceful reload answers the requests its old workers hold, including a
## long-lived response (`isonim_rpc_timeout 0`) that has not sent its header
## yet, and never keeps an old worker for longer than
## `isonim_rpc_header_timeout`; once a response's header is sent, the header
## timeout no longer applies.
##
## nginx lets a gracefully exiting worker exit once only cancelable timers
## are left. `isonim_rpc_timeout`'s timer is not cancelable, so a request
## with one keeps its worker; a location with `isonim_rpc_timeout 0` (a
## stream) used to hold no timer at all, and a reload then closed the
## connection of a request that had not answered yet, before any response
## (a proxy in front reports that as 502). `isonim_rpc_header_timeout` is
## that request's timer until its header is sent.
##
## Before the header (`await_before_header`: the app awaits a byte on a
## socket this test holds before it writes anything):
## * test_inflight_request_answered_across_reload: SIGHUP; the new worker
##   serves; the old one is still alive a second later; the byte is sent and
##   the request is answered 200 by the old worker, which then exits.
## * test_header_wait_bounded_across_reload: the byte never sent, a 2 s
##   header timeout, two reloads: 504 `{"error":"timeout"}` at the bound, and
##   the first old worker gone within it.
## * test_header_timeout_without_reload: no reload: 504 after the bound, by
##   the worker that keeps serving, logged naming isonim_rpc_header_timeout.
## * test_client_gone_before_header: the client closes while its worker is
##   exiting: the worker goes at once (the request's cleanup removes the
##   timer), and the new worker serves the next held request.
## * test_default_header_timeout_across_reload: no isonim_rpc_header_timeout
##   (the 60 s default): the request is held across the reload and answered.
## After the header (`stream_await`: the app flushes a shell, then awaits a
## byte):
## * test_stream_outlives_header_timeout: a 1 s header timeout; 2.5 s later
##   the byte is sent and the stream completes 200 with its terminating
##   chunk; no timeout is logged.
## * test_reload_after_header_ends_stream: a reload after the header: the old
##   worker exits within 3 s and the stream ends unterminated, as before
##   this directive.
## * test_header_timeout_validated: `nginx -t` accepts 0 and rejects a value
##   that is not a time.
##
## FALSIFYING MUTATIONS (`buildMutant`), each a test of its own:
## * the header timer never armed (the old exit condition): the in-flight
##   request gets no 200 across the reload;
## * the timer not removed when the header is sent: the stream past its
##   header is cut at the header timeout, and a reload after the header keeps
##   the old worker;
## * a default of 0: the in-flight request at a location without the
##   directive gets no 200 across the reload.
##
## Reads are one byte at a time: `Socket.recv(n, timeout)` waits for all n
## bytes, and a stream stays open.
##
## No mocks: real nginx, the real module, the e2e apps.
##
## Run: nim c -r tests/e2e/test_reload_inflight.nim  (in the dev shell)

import std/[unittest, strutils, net, os, times, monotimes]
import harness

const locations = """
    location /held/ {
        isonim_rpc on; isonim_rpc_app await_before_header;
        isonim_rpc_timeout 0; isonim_rpc_header_timeout 20s;
    }
    location /bounded/ {
        isonim_rpc on; isonim_rpc_app await_before_header;
        isonim_rpc_timeout 0; isonim_rpc_header_timeout 2s;
    }
    location /default/ {
        isonim_rpc on; isonim_rpc_app await_before_header;
        isonim_rpc_timeout 0;
    }
    location /stream1/ {
        isonim_rpc on; isonim_rpc_app stream_await;
        isonim_rpc_timeout 0; isonim_rpc_header_timeout 1s;
    }
    location /stream20/ {
        isonim_rpc on; isonim_rpc_app stream_await;
        isonim_rpc_timeout 0; isonim_rpc_header_timeout 20s;
    }
"""

type Held = object
  listener, app, client: Socket
  port: int

proc hold(n: Nginx; path: string): Held =
  ## Starts a request to `path` whose app connects back to a socket this
  ## test holds, and accepts that connection: the request is in flight, and
  ## the app awaits a byte from this test.
  result.listener = newSocket()
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(Port(0), "127.0.0.1")
  result.listener.listen()
  result.port = int(result.listener.getLocalAddr()[1])
  result.client = newSocket()
  result.client.connect("127.0.0.1", Port(n.port))
  result.client.send("GET " & path & "?port=" & $result.port & " HTTP/1.1\r\nHost: localhost\r\n" &
                     "Connection: close\r\n\r\n")
  var app: Socket
  new(app)
  result.listener.accept(app)
  result.app = app

proc readUntil(h: Held; needle: string; timeoutMs: int): string =
  ## What the client receives until `needle` (or the bound, or the close).
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline and needle notin result:
    var part = ""
    try: part = h.client.recv(1, 200)
    except TimeoutError: continue
    except OSError: break
    if part.len == 0: break
    result.add part

proc rest(h: Held; timeoutMs: int): (string, bool) =
  ## Everything until the server closes, and whether it closed within the
  ## bound.
  var s = ""
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    var part = ""
    try: part = h.client.recv(1, 200)
    except TimeoutError: continue
    except OSError: return (s, true)
    if part.len == 0: return (s, true)
    s.add part
  (s, false)

proc close(h: Held) =
  for s in [h.client, h.app, h.listener]:
    try: s.close() except CatchableError: discard

proc goneWithin(pid, ms: int): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = ms)
  while getMonoTime() < deadline:
    if not processAlive(pid): return true
    sleep(50)
  not processAlive(pid)

proc answeredAcrossReload(module, path: string): (string, bool, bool) =
  ## A request to `path` held across a reload: (its response, its old
  ## worker alive 1 s after the reload, the old worker gone within 5 s of
  ## the answer).
  var n = startNginx(module, locations)
  defer: n.stop()
  let h = hold(n, path)
  defer: h.close()
  let old = n.workerPids
  n.reload(n.httpConf)
  discard n.waitForWorkers(old, keep = old)
  sleep(1000)
  let aliveAfter = old.len == 1 and processAlive(old[0])
  try: h.app.send("x") except OSError: discard
  let (r, _) = h.rest(5_000)
  (r, aliveAfter, old.len == 1 and goneWithin(old[0], 5_000))

proc streamPastHeader(module: string): (string, string, bool, string) =
  ## A stream with a 1 s header timeout, its header read, the byte sent 2.5 s
  ## later: (the header, the rest, closed within the bound, the error log).
  var n = startNginx(module, locations)
  defer: n.stop()
  let h = hold(n, "/stream1/")
  defer: h.close()
  let head = h.readUntil("\r\n\r\n", 5_000)
  sleep(2_500)
  try: h.app.send("x") except OSError: discard
  let (r, closed) = h.rest(5_000)
  (head, r, closed, readFile(n.errorLog))

proc reloadAfterHeader(module: string): (string, bool, string, bool) =
  ## A stream with a 20 s header timeout, its header read, then a reload:
  ## (the header, the old worker gone within 3 s, the rest, closed).
  var n = startNginx(module, locations)
  defer: n.stop()
  let h = hold(n, "/stream20/")
  defer: h.close()
  let head = h.readUntil("\r\n\r\n", 5_000)
  let old = n.workerPids
  n.reload(n.httpConf)
  discard n.waitForWorkers(old, keep = old)
  let gone = old.len == 1 and goneWithin(old[0], 3_000)
  let (r, closed) = h.rest(3_000)
  (head, gone, r, closed)

suite "test_reload_inflight":
  let module = testModule()

  test "test_inflight_request_answered_across_reload":
    let (r, aliveAfter, gone) = answeredAcrossReload(module, "/held/")
    check r.startsWith("HTTP/1.1 200")
    check "answered:x" in r
    check aliveAfter
    check gone

  test "test_header_wait_bounded_across_reload":
    var n = startNginx(module, locations)
    defer: n.stop()
    let h = hold(n, "/bounded/")
    defer: h.close()
    let old = n.workerPids
    let t0 = getMonoTime()
    n.reload(n.httpConf)
    let mid = n.waitForWorkers(old, keep = old)
    n.reload(n.httpConf)
    discard n.waitForWorkers(old & mid, keep = old)
    let (r, _) = h.rest(10_000)
    let tookMs = (getMonoTime() - t0).inMilliseconds
    checkpoint "after " & $tookMs & " ms: " & r.splitLines()[0]
    check r.startsWith("HTTP/1.1 504")
    check "\"timeout\"" in r
    check old.len == 1 and goneWithin(old[0], 2_000)
    check tookMs < 6_000

  test "test_header_timeout_without_reload":
    var n = startNginx(module, locations)
    defer: n.stop()
    let worker = n.workerPids
    let h = hold(n, "/bounded/")
    defer: h.close()
    let t0 = getMonoTime()
    let (r, _) = h.rest(10_000)
    let tookMs = (getMonoTime() - t0).inMilliseconds
    let log = readFile(n.errorLog)
    checkpoint "after " & $tookMs & " ms: " & r.splitLines()[0]
    check r.startsWith("HTTP/1.1 504")
    check tookMs >= 1_500 and tookMs < 5_000
    check n.workerPids == worker
    check "did not complete within isonim_rpc_header_timeout; responding 504" in log

  test "test_client_gone_before_header":
    var n = startNginx(module, locations)
    defer: n.stop()
    let h = hold(n, "/held/")
    let old = n.workerPids
    n.reload(n.httpConf)
    discard n.waitForWorkers(old, keep = old)
    sleep(500)
    check old.len == 1 and processAlive(old[0])
    h.close()
    check old.len == 1 and goneWithin(old[0], 3_000)
    let h2 = hold(n, "/held/")
    defer: h2.close()
    try: h2.app.send("y") except OSError: discard
    let (r2, _) = h2.rest(5_000)
    check r2.startsWith("HTTP/1.1 200") and "answered:y" in r2

  test "test_default_header_timeout_across_reload":
    let (r, aliveAfter, gone) = answeredAcrossReload(module, "/default/")
    check r.startsWith("HTTP/1.1 200") and "answered:x" in r
    check aliveAfter
    check gone

  test "test_stream_outlives_header_timeout":
    let (head, r, closed, log) = streamPastHeader(module)
    checkpoint "rest: " & r
    check head.startsWith("HTTP/1.1 200")
    check "rest:x" in r
    check r.endsWith("0\r\n\r\n")
    check closed
    check "did not complete within" notin log

  test "test_reload_after_header_ends_stream":
    let (head, gone, r, closed) = reloadAfterHeader(module)
    check head.startsWith("HTTP/1.1 200")
    check gone
    check closed
    check "rest:" notin r

  test "test_header_timeout_validated":
    let ok = testConfig(module, """
      location /a/ { isonim_rpc on; isonim_rpc_app await_before_header;
                     isonim_rpc_timeout 0; isonim_rpc_header_timeout 0; }
    """)
    check ok.code == 0
    let bad = testConfig(module, """
      location /a/ { isonim_rpc on; isonim_rpc_app await_before_header;
                     isonim_rpc_timeout 0; isonim_rpc_header_timeout soon; }
    """)
    check bad.code != 0

  test "falsifying mutation: the header timer never armed":
    let mutant = buildMutant("no_header_timer", "src/ngx_http_isonim_module.c",
      "    } else if (conf->rpc_header_timeout) {",
      "    } else if (0) {")
    let (r, _, _) = answeredAcrossReload(mutant, "/held/")
    # KILLED: the in-flight request's connection is closed before any
    # response once its worker exits.
    check not r.startsWith("HTTP/1.1 200")

  test "falsifying mutation: the timer not removed when the header is sent":
    let mutant = buildMutant("header_timer_kept", "src/ngx_http_isonim_module.c",
      "        if (ctx != NULL && ctx->kind == NGX_HTTP_ISONIM_CTX_RPC && ctx->header_timer) {",
      "        if (0) {")
    let (_, r, _, log) = streamPastHeader(mutant)
    let (_, gone, _, _) = reloadAfterHeader(mutant)
    # KILLED: the stream is cut at the header timeout, logged, and a reload
    # after the header keeps the old worker.
    check "rest:x" notin r
    check "did not complete within isonim_rpc_header_timeout" in log
    check not gone

  test "falsifying mutation: a default of 0":
    let mutant = buildMutant("header_default_0", "src/ngx_http_isonim_module.c",
      "                              prev->rpc_header_timeout, 60000);",
      "                              prev->rpc_header_timeout, 0);")
    let (r, _, _) = answeredAcrossReload(mutant, "/default/")
    # KILLED: without the default, the location holds no timer.
    check not r.startsWith("HTTP/1.1 200")
