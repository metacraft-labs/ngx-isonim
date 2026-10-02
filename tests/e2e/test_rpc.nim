## test_rpc.nim
##
## isonim_rpc locations against real nginx with the real module
## (tests/e2e/harness.nim), driving the server functions and the async app
## of tests/e2e/apps/rpc_app.nim with curl.  One worker process, so every
## request below is served by the same worker.
##
## Covered: the round trip and its response; bodies read from memory and
## from nginx's temporary file (1 MiB); isonim_rpc_max_body_size by
## Content-Length and for a chunked body (413), the chunked one refused
## while it is being read (with `client_max_body_size 0`: the 413 arrives
## before the client has finished sending, after at most one read buffer
## past the limit); 405 and CSRF refusals; the
## request context (session, path, client address, CSRF verdict);
## isonim_rpc_timeout (504); a client that goes away mid-handler; an
## AsyncSocket request from a server function to this same nginx; an async
## app (isonim_rpc_app) on any method; and that a slow server function does
## not hold up the worker.
##
## Falsifying mutations (`buildMutant`): the handler run synchronously in
## the content phase (nim_handle_rpc polls Nim's event loop until the
## handler is done) fails the concurrency probe; a body filter that never
## refuses (the limit checked only once the whole body is read) fails the
## refused-while-reading test (no 413 while the body is unfinished).
##
## No mocks.
##
## Run: nim c -r tests/e2e/test_rpc.nim  (in the dev shell)

import std/[unittest, strutils, json, os, osproc, streams, times, monotimes,
            net, re]
import harness

const locations = """
    location /api/ {
      isonim_rpc on;
      isonim_rpc_max_body_size 1100k;
      isonim_rpc_timeout 1s;
      client_max_body_size 8m;
    }
    location /app/ { isonim_rpc on; isonim_rpc_app rpc_echo; }
    location /capped/ {
      isonim_rpc on;
      isonim_rpc_app rpc_echo;
      isonim_rpc_max_body_size 64k;
      client_max_body_size 0;
      client_body_buffer_size 16k;
    }
    location /nobody/ { isonim_rpc on; isonim_rpc_app no_such_app; }
    location /health { return 200 "ok"; }
"""

const anonToken = "e2e-anon-token"

proc rpcArgs(n: Nginx; path: string; extra: openArray[string] = []): seq[string] =
  ## curl arguments for a POST as the generated client sends it.
  let origin = "http://127.0.0.1:" & $n.port
  # `Expect:` keeps curl from waiting for a 100 Continue on large bodies.
  @["-sS", "-i", "-X", "POST", "-H", "Expect:",
    "-H", "Content-Type: application/json",
    "-H", "Origin: " & origin,
    "-H", "Sec-Fetch-Site: same-origin",
    "-H", "X-CSRF-Token: " & anonToken,
    "-H", "X-Isonim-Context: inc-e2e:1",
    "-H", "Cookie: __Host-Anon-CSRF=" & anonToken] & @extra & @[n.url(path)]

proc call(n: Nginx; fn, body: string; extra: openArray[string] = []):
    tuple[status: string, headers: seq[(string, string)], body: string] =
  let r = curl(n.rpcArgs("/api/rpc_app/" & fn, @["--data-binary", body] & @extra))
  doAssert r.exitCode == 0, "curl failed: " & r.stderr
  let resp = splitResponse(r.output)
  (resp.statusLine, resp.headers, resp.body)

proc bodyFile(name: string; size: int): string =
  ## A JSON body `{"data": "xxx..."}` whose string is `size` bytes.
  result = getTempDir() / ("ngx-isonim-rpc-" & $getCurrentProcessId() & "-" & name)
  writeFile(result, "{\"data\":\"" & repeat('x', size) & "\"}")

type ConcurrencyProbe = object
  sawSleeping: bool      ## the slow call was observed inside its handler
  fastMs: int            ## latency of /health + sum, sent while it slept
  slowStillRunning: bool ## the slow call had not finished by then
  slowBody: string

proc probeConcurrency(n: Nginx): ConcurrencyProbe =
  ## Starts a server function that sleeps 800 ms, waits (bounded) until it
  ## is inside its handler, then times a /health and a `sum` request.
  let origin = "http://127.0.0.1:" & $n.port
  let slow = startProcess("curl", args = @["-sS", "-X", "POST",
    "-H", "Content-Type: application/json", "-H", "Origin: " & origin,
    "-H", "Sec-Fetch-Site: same-origin", "-H", "X-CSRF-Token: " & anonToken,
    "-H", "Cookie: __Host-Anon-CSRF=" & anonToken,
    "--data-binary", """{"ms": 800, "tag": "slow"}""",
    n.url("/api/rpc_app/sleepThen")], options = {poUsePath})
  let deadline = getMonoTime() + initDuration(seconds = 3)
  while getMonoTime() < deadline:
    # Each poll is itself a request the worker serves while sleepThen is
    # suspended (or not, under the mutation: then it waits).
    let r = n.call("sleepingNow", "{}", ["--max-time", "3"])
    if r.body.strip == "1":
      result.sawSleeping = true
      break
  let t0 = getMonoTime()
  let h = curl(["-sS", "--max-time", "5", n.url("/health")])
  let s = n.call("sum", """{"a": 1, "b": 2}""", ["--max-time", "5"])
  result.fastMs = int((getMonoTime() - t0).inMilliseconds)
  doAssert h.output == "ok" and s.body == "3",
    "the fast requests failed: " & h.output & " / " & s.body
  result.slowStillRunning = slow.running
  result.slowBody = slow.outputStream.readAll()
  discard slow.waitForExit()
  slow.close()

const
  cappedLimit = 64 * 1024     ## isonim_rpc_max_body_size of /capped/
  cappedBuffer = 16 * 1024    ## its client_body_buffer_size

proc unfinishedChunkedBody(n: Nginx; total: int): string =
  ## Sends `total` bytes of a chunked body to /capped/x in 8 KiB chunks and
  ## never sends the terminating chunk; returns the status line of whatever
  ## nginx answers within 5 s ("" if nothing).
  let s = newSocket()
  defer: s.close()
  s.connect("127.0.0.1", Port(n.port), timeout = 2000)
  s.send("POST /capped/x HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
         "Content-Type: application/octet-stream\r\n" &
         "Transfer-Encoding: chunked\r\n\r\n")
  let chunk = repeat('x', 8192)
  var sent = 0
  try:
    while sent < total:
      s.send(toHex(chunk.len).strip(chars = {'0'}, trailing = false) &
             "\r\n" & chunk & "\r\n")
      sent += chunk.len
  except OSError:
    discard   # nginx answered and closed; the status line is what counts
  try:
    result = s.recvLine(timeout = 5000)
  except TimeoutError:
    result = ""

proc refusedAfter(log: string): seq[int] =
  ## The byte counts of the body filter's refusals in the error log.
  for m in log.findAll(re"after \d+ bytes read; refused while reading"):
    result.add parseInt(m.split(' ')[1])

suite "isonim_rpc against real nginx":
  let module = testModule()
  let n = startNginx(module, locations)

  test "a server function call: 200, JSON, Content-Length, context echoed":
    let r = n.call("sum", """{"a": 20, "b": 22}""")
    check r.status == "HTTP/1.1 200 OK"
    check r.body == "42"
    check r.headers.headerValues("Content-Length") == @["2"]
    check r.headers.headerValues("Content-Type") == @["application/json"]
    check r.headers.headerValues("Cache-Control") ==
      @["private, no-cache, no-store, must-revalidate"]
    check r.headers.headerValues("X-Isonim-Context") == @["inc-e2e:1"]

  test "a 1 MiB argument arrives whole (read from nginx's temporary file)":
    let f = bodyFile("1m", 1024 * 1024)
    let r = n.call("bodySize", "@" & f)
    check r.status == "HTTP/1.1 200 OK"
    check r.body == $(1024 * 1024)
    removeFile(f)

  test "a body over isonim_rpc_max_body_size is 413 (Content-Length and chunked)":
    let f = bodyFile("1500k", 1500 * 1024)
    let r = n.call("bodySize", "@" & f)
    check r.status == "HTTP/1.1 413 Request Entity Too Large"
    let c = n.call("bodySize", "@" & f, ["-H", "Transfer-Encoding: chunked"])
    check c.status == "HTTP/1.1 413 Request Entity Too Large"
    check "exceeds isonim_rpc_max_body_size" in n.errorLogText
    removeFile(f)
    # Negative control: just under the limit is served.
    let g = bodyFile("1090k", 1090 * 1024)
    check n.call("bodySize", "@" & g).body == $(1090 * 1024)
    removeFile(g)

  test "a chunked body over the limit is refused while it is being read":
    # client_max_body_size 0: nginx itself would buffer any amount.  The
    # body is sent to twice the limit and left unfinished; the 413 must come
    # anyway, so nginx stopped reading at the limit instead of buffering the
    # whole body first.
    let earlier = refusedAfter(n.errorLogText).len
    let status = n.unfinishedChunkedBody(2 * cappedLimit)
    check status == "HTTP/1.1 413 Request Entity Too Large"
    let counts = refusedAfter(n.errorLogText)[earlier .. ^1]
    check counts.len == 1
    if counts.len == 1:
      echo "    refused after ", counts[0], " bytes (limit ", cappedLimit, ")"
      # Bounded: at most one read buffer past the limit was read.
      check counts[0] > cappedLimit
      check counts[0] <= cappedLimit + cappedBuffer
    # Negative control: a complete chunked body under the limit is served.
    let under = curl(["-sS", "-X", "POST", "-H", "Transfer-Encoding: chunked",
                      "-H", "Expect:", "--data-binary", repeat('y', 60 * 1024),
                      n.url("/capped/x")])
    check parseJson(under.output)["bodyLength"].getInt == 60 * 1024

  test "refusals: 405 for GET, 403 without the CSRF token, 404 unknown":
    let get = curl(["-sS", "-i", n.url("/api/rpc_app/sum")])
    let g = splitResponse(get.output)
    check g.statusLine == "HTTP/1.1 405 Not Allowed"
    check g.headers.headerValues("Allow") == @["POST"]
    check parseJson(g.body)["error"].getStr == "method_not_allowed"
    let r = curl(["-sS", "-i", "-X", "POST", "-H", "Content-Type: application/json",
                  "--data-binary", """{"a":1,"b":2}""", n.url("/api/rpc_app/sum")])
    let c = splitResponse(r.output)
    check c.statusLine == "HTTP/1.1 403 Forbidden"
    check parseJson(c.body)["error"].getStr == "csrf"
    check n.call("nope", "{}").status == "HTTP/1.1 404 Not Found"

  test "the request context: session, path, client address, CSRF verdict":
    let origin = "http://127.0.0.1:" & $n.port
    let r = curl(["-sS", "-X", "POST", "-H", "Content-Type: application/json",
      "-H", "Origin: " & origin, "-H", "Sec-Fetch-Site: same-origin",
      "-H", "X-CSRF-Token: alice-csrf", "-H", "Cookie: sid=alice",
      "--data-binary", "{}", n.url("/api/rpc_app/whoAmI")])
    check parseJson(r.output) == %*{"subject": "alice",
      "path": "/api/rpc_app/whoAmI", "csrf": "verified", "clientAddr": "127.0.0.1"}
    check n.call("whoAmI", "{}").status == "HTTP/1.1 401 Unauthorized"

  test "a raising server function is 500 and logged":
    let r = n.call("fails", "{}")
    check r.status == "HTTP/1.1 500 Internal Server Error"
    check r.body == """{"error":"internal"}"""
    check "rpc_app.fails was called" in n.errorLogText

  test "isonim_rpc_timeout: 504 after the timeout, logged":
    let t0 = getMonoTime()
    let r = n.call("sleepThen", """{"ms": 2500, "tag": "late"}""")
    let ms = (getMonoTime() - t0).inMilliseconds
    check r.status == "HTTP/1.1 504 Gateway Time-out"
    check r.body == """{"error":"timeout"}"""
    check ms >= 900 and ms < 2000
    check "isonim_rpc_timeout" in n.errorLogText

  test "a client that goes away mid-handler: the worker carries on":
    let r = curl(n.rpcArgs("/api/rpc_app/sleepThen",
      ["--max-time", "0.3", "--data-binary", """{"ms": 600, "tag": "gone"}"""]))
    check r.exitCode == 28                       # curl gave up
    # Wait (bounded) for the abandoned handler to finish.
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while n.call("sleepingNow", "{}").body.strip != "0" and getMonoTime() < deadline:
      discard
    check n.call("sum", """{"a": 2, "b": 2}""").body == "4"
    let log = n.errorLogText
    check "client prematurely closed connection" in log
    check "[alert]" notin log
    check "exited on signal" notin log

  test "an AsyncSocket request from a server function to this nginx":
    let r = n.call("selfFetch", """{"port": """ & $n.port & """, "path": "/health"}""")
    check r.status == "HTTP/1.1 200 OK"
    check r.body == "\"ok\""

  test "an async app (isonim_rpc_app) answers every method":
    for m in ["GET", "POST", "PUT", "DELETE"]:
      let r = curl(["-sS", "-X", m, "--data-binary", "abc", n.url("/app/x")])
      let j = parseJson(r.output)
      check j["method"].getStr == m
      check j["path"].getStr == "/app/x"
      check j["bodyLength"].getInt == 3
    let none = curl(["-sS", "-o", "/dev/null", "-w", "%{http_code}", n.url("/nobody/x")])
    check none.output == "500"
    check "no app is registered as \"no_such_app\"" in n.errorLogText

  test "a slow server function does not hold up the worker":
    let p = n.probeConcurrency()
    echo "    probe: ", p
    check p.sawSleeping
    check p.fastMs < 400
    check p.slowStillRunning
    check p.slowBody == "\"slow\""

  test "falsifying mutation: the handler run synchronously blocks the worker":
    let mutant = buildMutant("sync-rpc", "src/handler.nim",
      "      st.run()\n",
      "      st.run()\n      while not st.done: poll(20)\n")
    let m = startNginx(mutant, locations)
    let p = m.probeConcurrency()
    m.stop()
    echo "    mutant probe: ", p
    check not (p.sawSleeping and p.fastMs < 400 and p.slowStillRunning)
    check p.fastMs >= 400 or not p.sawSleeping

  test "falsifying mutation: no refusal while reading buffers the whole body":
    let mutant = buildMutant("no-body-filter", "src/ngx_http_isonim_module.c",
      "        if (ctx->body_read > (off_t) ctx->body_limit) {",
      "        if (0) {")
    let m = startNginx(mutant, locations)
    let status = m.unfinishedChunkedBody(2 * cappedLimit)
    m.stop()
    echo "    mutant status line: ", (if status.len > 0: status else: "(none in 5 s)")
    check status != "HTTP/1.1 413 Request Entity Too Large"

  n.stop()
  test "nginx stops promptly with the event loop hooked in":
    check "[alert]" notin n.errorLogText
