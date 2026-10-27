## test_async_streaming.nim
##
## Streaming async apps at isonim_rpc locations (IFP-M30), against real
## nginx with the real module (tests/e2e/harness.nim) and the apps of
## tests/e2e/apps/stream_app.nim.  One worker process, so every request
## below is served by the same worker.
##
## test_async_app_streams_after_awaiting
##   `stream_await` flushes a shell, then awaits one byte on a socket this
##   test holds.  The test reads the shell off the wire BEFORE it writes the
##   byte (it synchronizes on the shell's arrival; no timer orders the
##   steps), then the rest and the terminating chunk follow.  While the app
##   awaits, another location of the same worker answers.  `stream_whole`,
##   which never flushes, is answered with `Content-Length` and its whole
##   body.  Negative controls: a handler that raises before its first flush
##   gets `500` with none of its body; one that raises after it gets a
##   terminated (unterminated-chunked) response and a log line; one that
##   flushes and never completes, under a 1 s `isonim_rpc_timeout`, gets a
##   response without its last chunk and a logged timeout, and the worker
##   serves the next request.  `HEAD` gets the headers only.
##   Falsifying mutation: sending the response only when the future
##   completes (the flush of rpc.nim's body writer commits nothing) keeps
##   the shell back until the byte is written; the shell does not arrive
##   within the deadline and the ordering check fails.
##
## test_async_streaming_backpressure_and_abort
##   A listener with a 4 KiB send buffer (`sndbuf=4096`), so the kernel
##   cannot absorb the body and nginx sees NGX_AGAIN.  50 clients with 4 KiB
##   receive buffers each read a 256 KiB streamed body at 16 KiB/s, 20 more
##   disconnect after 32 KiB while the producer is still writing, and a fast
##   client requests another location of the same worker every 500 ms.
##   Vacuity guards: every slow client receives the whole body byte for
##   byte; the release callback ran once for every request
##   (`rpcRequestsReleased`, read through `stream_stats`); the worker's
##   descriptor count returns to its baseline; every fast request's first
##   byte arrived and was timed.  The fast client's time to first byte,
##   measured on the CLIENT side (monotonic clock, from before `connect`
##   to the first response byte read), stays under 20 ms while the slow
##   clients stream.  It is timed on the client because nginx's
##   `$request_time` starts after the request has been read and uses
##   nginx's cached clock: a worker whose event loop is blocked has not
##   read the request yet, so `$request_time` cannot see the wait (a
##   producer blocking 15 ms after each flush gave a 23.9 s client wait and
##   a logged `$request_time` of 0.000; it is still printed, as a log line
##   only).  The bound is a latency bound, so it is reported NOT MEASURED,
##   never loosened, when the host is loaded (the 1-minute load average
##   per CPU above `MaxLoadPerCpu`, sampled before and after the run; the
##   convention of isonim-forum's tests/perf/t_boundary_budget.nim).
##   Negative control: the same body to a fast client arrives whole.
##   Falsifying mutations (each with 10 slow and 5 aborting clients, which
##   is enough to show the defect and halves the run): treating NGX_AGAIN as
##   sent (the unsent chain dropped) corrupts and truncates the slow
##   clients' bodies; not releasing the request on a client's disconnect
##   (the module's three places that notice it -- the read handler, the
##   write handler, and rpc.nim on a failed send -- each made to ignore it)
##   leaves the descriptor count above its baseline; a producer that
##   blocks the worker's event loop (`stream_big` calling `os.sleep(15)`
##   after each flush) makes the fast client's measured wait exceed the
##   bound by `SensitivityFactor` or more.  That last check is the
##   measurement's own vacuity guard and is NOT load-gated: load only
##   lengthens the mutant's wait, so it holds on a loaded host too, and it
##   fails whenever the timing cannot see a blocked event loop (as
##   `$request_time` cannot) -- even when the bound itself is NOT MEASURED.
##
## No mocks: real nginx, real sockets, real slow clients.  The pauses in
## the clients (16 KiB/s) and in the producer (`pause_ms`) are the load the
## test applies, not synchronization: every ordering the test asserts is
## established by data arriving.
##
## Run: nim c -r tests/e2e/test_async_streaming.nim  (in the dev shell)

import std/[unittest, strutils, json, os, osproc, net, nativesockets,
            times, monotimes, asyncdispatch, asyncnet, posix]
import harness
import apps/stream_pattern

const
  MaxLoadPerCpu = 1.0
    ## Above this 1-minute load average per CPU a latency bound measures
    ## the host, not the module (isonim-forum tests/perf/t_boundary_budget.nim).
  TtfbBoundMs = 20.0
    ## The fast client's client-side time to first byte.
  SensitivityFactor = 10.0
    ## The event-loop-blocking mutant's worst client-side wait must exceed
    ## the bound by this factor: a wide margin, so that a measurement that
    ## only partly sees the blocked loop does not pass as sensitive.
  BigSize = 256 * 1024
  wholeBody = "<p>whole-1</p><p>whole-2</p><p>whole-3</p>"

var notMeasured = 0

proc loadPerCpu(): float =
  ## The 1-minute load average per CPU; +inf when unreadable, so an unknown
  ## load is never taken for an idle host.
  try: parseFloat(readFile("/proc/loadavg").splitWhitespace()[0]) /
         float(max(1, countProcessors()))
  except CatchableError: Inf

# ---------------------------------------------------------------------------
# HTTP/1.1 on the wire
# ---------------------------------------------------------------------------

type
  Decoded = object
    body: string
    terminated: bool   ## the zero-size chunk and its blank line arrived
    invalid: bool      ## the framing is not chunked encoding

  Head = object
    complete: bool
    statusLine: string
    headers: seq[(string, string)]
    bodyStart: int

proc parseHead(raw: string): Head =
  let sep = raw.find("\r\n\r\n")
  if sep < 0:
    return
  result.complete = true
  result.bodyStart = sep + 4
  let lines = raw[0 ..< sep].split("\r\n")
  result.statusLine = lines[0]
  for line in lines[1 .. ^1]:
    let colon = line.find(':')
    if colon > 0:
      result.headers.add((line[0 ..< colon], line[colon + 1 .. ^1].strip()))

proc decodeChunked(raw: string; start: int): Decoded =
  ## The body carried by `raw[start .. ^1]` so far (complete chunks only).
  var i = start
  while true:
    let eol = raw.find("\r\n", i)
    if eol < 0:
      return
    let sizeText = raw[i ..< eol].split(';')[0].strip()
    if sizeText.len == 0 or sizeText.len > 8 or
        not sizeText.allCharsInSet(HexDigits):
      result.invalid = true
      return
    let size = parseHexInt(sizeText)
    if size == 0:
      result.terminated = raw.len >= eol + 4 and raw[eol + 2 .. eol + 3] == "\r\n"
      return
    if eol + 2 + size + 2 > raw.len:
      return
    result.body.add raw[eol + 2 ..< eol + 2 + size]
    if raw[eol + 2 + size .. eol + 3 + size] != "\r\n":
      result.invalid = true
      return
    i = eol + 4 + size

proc isChunked(head: Head): bool =
  for (k, v) in head.headers:
    if cmpIgnoreCase(k, "Transfer-Encoding") == 0 and v == "chunked":
      return true

proc bodySoFar(raw: string; head: Head): string =
  ## The body bytes received so far (decoded when chunked).
  if head.isChunked: decodeChunked(raw, head.bodyStart).body
  else: raw[head.bodyStart .. ^1]

proc request(path: string; extra = ""): string =
  "GET " & path & " HTTP/1.1\r\nHost: 127.0.0.1\r\n" & extra &
    "Connection: close\r\n\r\n"

proc readable(s: Socket; deadline: MonoTime): bool =
  ## Whether the socket has something to read (data, a closed peer, or on
  ## a listener a connection to accept) before `deadline`.
  let left = (deadline - getMonoTime()).inMilliseconds
  if left <= 0:
    return false
  var pfd = TPollfd(fd: cint(s.getFd), events: POLLIN)
  let ready = posix.poll(addr pfd, 1, cint(left))
  if ready < 0:
    raiseOSError(osLastError())
  ready > 0

proc recvSome(s: Socket; deadline: MonoTime): string =
  ## What the socket has now (up to 64 KiB), waiting for it until
  ## `deadline` (TimeoutError); "" when the peer closed.  `net.recv` with a
  ## size waits for all of it, so this reads the descriptor directly.
  if not s.readable(deadline):
    raise newException(TimeoutError, "deadline passed")
  result = newString(65536)
  let n = posix.recv(s.getFd, addr result[0], 65536, 0)
  if n < 0:
    raiseOSError(osLastError())
  result.setLen(n)

# ---------------------------------------------------------------------------
# test_async_app_streams_after_awaiting
# ---------------------------------------------------------------------------

const awaitLocations = """
    location /await/ { isonim_rpc on; isonim_rpc_app stream_await; }
    location /whole/ { isonim_rpc on; isonim_rpc_app stream_whole; }
    location /before/ { isonim_rpc on; isonim_rpc_app stream_raise_before; }
    location /after/ { isonim_rpc on; isonim_rpc_app stream_raise_after; }
    location /hang/ {
      isonim_rpc on;
      isonim_rpc_app stream_hang;
      isonim_rpc_timeout 1s;
    }
    location /big/ { isonim_rpc on; isonim_rpc_app stream_big; }
"""

type AwaitRun = object
  shellFirst: bool        ## the shell arrived before the byte was written
  restEarly: bool         ## "rest:" arrived before the byte was written
  chunked: bool
  contentLength: bool
  otherServed: bool       ## another location answered while the app awaited
  appConnected: bool      ## the app connected to the test's socket in time
  body: string
  terminated: bool
  invalid: bool

proc awaitScenario(n: Nginx; deadlineMs = 10_000): AwaitRun =
  let listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  let port = int(listener.getLocalAddr()[1])
  let c = newSocket()
  c.connect("127.0.0.1", Port(n.port))
  c.send(request("/await/page?port=" & $port))
  var raw = ""
  var head: Head
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  # 1. The shell, before anything is written to the app's socket.
  try:
    while true:
      let got = c.recvSome(deadline)
      if got.len == 0: break
      raw.add got
      head = parseHead(raw)
      if head.complete and shellHtml in bodySoFar(raw, head):
        result.shellFirst = true
        break
  except TimeoutError:
    discard
  head = parseHead(raw)
  if head.complete:
    result.restEarly = "rest:" in bodySoFar(raw, head)
  # 2. While the app awaits: another location of the same worker answers.
  let other = curl(["-sS", "--max-time", "5", n.url("/whole/x")])
  result.otherServed = other.exitCode == 0 and other.output == wholeBody
  # 3. The byte the app awaits (its connection is in the listener's
  #    backlog, or arrives now).  An app that never connects (e.g. the
  #    worker crashed) fails the run at the deadline instead of hanging it.
  var app: Socket
  if listener.readable(getMonoTime() + initDuration(milliseconds = deadlineMs)):
    listener.accept(app)
    result.appConnected = true
    app.send("Z")
  # 4. The rest and the terminating chunk.
  try:
    while true:
      let got = c.recvSome(getMonoTime() + initDuration(milliseconds = deadlineMs))
      if got.len == 0: break
      raw.add got
  except TimeoutError:
    discard
  if result.appConnected:
    app.close()
  c.close()
  listener.close()
  head = parseHead(raw)
  if head.complete:
    for (k, v) in head.headers:
      if cmpIgnoreCase(k, "Transfer-Encoding") == 0 and v == "chunked":
        result.chunked = true
      if cmpIgnoreCase(k, "Content-Length") == 0:
        result.contentLength = true
    if result.chunked:
      let d = decodeChunked(raw, head.bodyStart)
      result.body = d.body
      result.terminated = d.terminated
      result.invalid = d.invalid
    else:
      result.body = raw[head.bodyStart .. ^1]

suite "test_async_app_streams_after_awaiting":
  let n = startNginx(testModule(), awaitLocations)

  test "the shell is on the wire before the awaited byte; the rest follows":
    let r = n.awaitScenario()
    echo "    ", r
    check r.appConnected
    check r.shellFirst
    check not r.restEarly
    check r.chunked
    check not r.contentLength
    check r.otherServed
    check r.body == shellHtml & "<p id=\"rest\">rest:Z</p></body></html>"
    check r.terminated
    check not r.invalid

  test "a handler that never flushes: Content-Length and the whole body":
    let r = curl(["-sS", "-i", n.url("/whole/x")])
    let resp = splitResponse(r.output)
    check resp.statusLine == "HTTP/1.1 200 OK"
    check resp.headers.headerValues("Content-Length") == @[$wholeBody.len]
    check resp.headers.headerValues("Transfer-Encoding").len == 0
    check resp.headers.headerValues("X-Stream-App") == @["whole"]
    check resp.body == wholeBody

  test "negative control: raising before the first flush is 500, no partial body":
    let r = curl(["-sS", "-i", n.url("/before/x")])
    let resp = splitResponse(r.output)
    check resp.statusLine == "HTTP/1.1 500 Internal Server Error"
    check resp.body == """{"error":"internal"}"""
    check "never sent" notin r.output
    check "stream_raise_before raised" in n.errorLogText

  test "negative control: raising after the first flush terminates the response":
    let r = curl(["-sS", "--max-time", "10", n.url("/after/x")])
    check r.exitCode == 18          # transfer closed with data outstanding
    check r.output == shellHtml
    let log = n.errorLogText
    check "stream_raise_after raised" in log
    check "response terminated after the headers were sent" in log

  test "negative control: isonim_rpc_timeout after the commit point":
    let t0 = getMonoTime()
    let r = curl(["-sS", "--max-time", "10", n.url("/hang/x")])
    let ms = (getMonoTime() - t0).inMilliseconds
    check r.exitCode == 18
    check r.output == shellHtml
    check ms >= 900
    check "the handler did not complete within isonim_rpc_timeout; " &
      "response terminated after the headers were sent" in n.errorLogText
    # The worker serves the next request.
    check curl(["-sS", "--max-time", "5", n.url("/whole/y")]).output == wholeBody

  test "HEAD: the commit sends the headers only":
    let r = curl(["-sS", "-i", "--head", "--max-time", "10",
                  n.url("/big/x?size=20000&part=4096")])
    let resp = splitResponse(r.output)
    check r.exitCode == 0
    check resp.statusLine == "HTTP/1.1 200 OK"
    check resp.body == ""

  test "falsifying mutation: sending only on completion holds the shell back":
    let mutant = buildMutant("no-stream-flush", "src/rpc.nim",
      "    st.drainContextBody()\n    st.transport.flush())",
      "    discard)")
    let m = startNginx(mutant, awaitLocations)
    let r = m.awaitScenario(deadlineMs = 5_000)
    m.stop()
    echo "    mutant: ", r
    check not r.shellFirst
    # The mutant still answers, whole, once the byte arrives: the defect
    # is the ordering, which is what the check above sees.
    check r.contentLength

  n.stop()
  test "no alert in the log":
    check "[alert]" notin n.errorLogText

# ---------------------------------------------------------------------------
# test_async_streaming_backpressure_and_abort
# ---------------------------------------------------------------------------

const backpressureLocations = """
    location /big/ {
      isonim_rpc on;
      isonim_rpc_app stream_big;
      isonim_rpc_timeout 120s;
    }
    location /fast/ {
      isonim_rpc on;
      isonim_rpc_app stream_whole;
      access_log fast.log isonim_timing;
    }
    location /stats/ { isonim_rpc on; isonim_rpc_app stream_stats; }
"""
const backpressureHttp = "  log_format isonim_timing '$request_time';"

const bigPath = "/big/b?size=" & $BigSize & "&part=8192&pause_ms=20"

type
  ClientResult = object
    received: int          ## raw bytes
    body: string
    terminated: bool
    invalid: bool
    status: string

  BackpressureRun = object
    slow: seq[ClientResult]
    aborted: int           ## aborting clients that got their 32 KiB
    fastOk: int
    fastClientMs: seq[float]   ## client-side time to first byte, per request
    fastServerMs: seq[float]   ## nginx's $request_time (a log line only)
    baselineFds: int
    fdsAfter: int
    fdsAtBaseline: bool
    releasedExpected: int
    releasedSeen: int
    loadBefore, loadAfter: float

proc smallRcvbuf(s: AsyncSocket) =
  var size: cint = 4096
  discard posix.setsockopt(SocketHandle(s.getFd), SOL_SOCKET, SO_RCVBUF,
                           addr size, SockLen(sizeof(size)))

proc slowClient(port: int; bytesPerSec: int; deadline: MonoTime):
    Future[ClientResult] {.async.} =
  let s = newAsyncSocket(buffered = false)
  s.smallRcvbuf()
  await s.connect("127.0.0.1", Port(port))
  await s.send(request(bigPath))
  var raw = ""
  let t0 = getMonoTime()
  while getMonoTime() < deadline:
    let got = await s.recv(1024)
    if got.len == 0: break
    raw.add got
    # Hold the pace: no more than bytesPerSec on average.
    let due = int(raw.len * 1000 div bytesPerSec)
    let elapsed = int((getMonoTime() - t0).inMilliseconds)
    if due > elapsed:
      await sleepAsync(due - elapsed)
  s.close()
  result.received = raw.len
  let head = parseHead(raw)
  if head.complete:
    result.status = head.statusLine
    let d = decodeChunked(raw, head.bodyStart)
    result.body = d.body
    result.terminated = d.terminated
    result.invalid = d.invalid

proc abortingClient(port: int; afterBytes: int; deadline: MonoTime):
    Future[bool] {.async.} =
  ## Reads `afterBytes` of the response, then closes the connection.
  let s = newAsyncSocket(buffered = false)
  s.smallRcvbuf()
  await s.connect("127.0.0.1", Port(port))
  await s.send(request(bigPath))
  var got = 0
  while got < afterBytes and getMonoTime() < deadline:
    let part = await s.recv(4096)
    if part.len == 0: break
    got += part.len
  s.close()
  got >= afterBytes

proc fetch(port: int; path: string): Future[string] {.async.} =
  let s = newAsyncSocket(buffered = false)
  await s.connect("127.0.0.1", Port(port))
  await s.send(request(path))
  var raw = ""
  while true:
    let part = await s.recv(4096)
    if part.len == 0: break
    raw.add part
  s.close()
  raw

proc bodyOf(raw: string): string =
  let head = parseHead(raw)
  if head.complete: bodySoFar(raw, head) else: ""

proc fetchTimed(port: int; path: string): Future[(string, float)] {.async.} =
  ## The response, and the client-side wait for its first byte in ms
  ## (`NaN` when the connection closed before one): from before `connect`
  ## to the first byte read, on the monotonic clock.  This includes the
  ## time the request waits for the worker's event loop to accept and read
  ## it, which nginx's `$request_time` does not see.
  let s = newAsyncSocket(buffered = false)
  let t0 = getMonoTime()
  await s.connect("127.0.0.1", Port(port))
  await s.send(request(path))
  var raw = await s.recv(1)
  let ms = if raw.len > 0: float((getMonoTime() - t0).inMicroseconds) / 1000.0
           else: NaN
  if raw.len > 0:
    while true:
      let part = await s.recv(4096)
      if part.len == 0: break
      raw.add part
  s.close()
  (raw, ms)

proc fastClient(port: int; count: int; run: ptr BackpressureRun) {.async.} =
  for i in 0 ..< count:
    let (raw, ms) = await fetchTimed(port, "/fast/f" & $i)
    if raw.len > 0:
      run.fastClientMs.add ms
    if raw.startsWith("HTTP/1.1 200") and raw.bodyOf == wholeBody:
      inc run.fastOk
    await sleepAsync(500)

proc stats(port: int): int =
  parseJson(waitFor(fetch(port, "/stats/s")).bodyOf)["released"].getInt

proc fdCount(pid: int): int =
  for _ in walkDir("/proc/" & $pid & "/fd"):
    inc result

proc backpressureScenario(n: Nginx; slowClients, abortingClients: int;
                          fastRequests = 20): BackpressureRun =
  let worker = n.workerPids[0]
  # Warm up (first request of the worker initializes Nim), then baselines.
  discard waitFor fetch(n.port, "/fast/warm")
  discard stats(n.port)
  result.baselineFds = fdCount(worker)
  let released0 = stats(n.port)
  result.loadBefore = loadPerCpu()
  let deadline = getMonoTime() + initDuration(seconds = 60)
  var slow: seq[Future[ClientResult]]
  var aborting: seq[Future[bool]]
  for i in 0 ..< slowClients:
    slow.add slowClient(n.port, 16 * 1024, deadline)
  for i in 0 ..< abortingClients:
    aborting.add abortingClient(n.port, 32 * 1024, deadline)
  var run = addr result
  let fast = fastClient(n.port, fastRequests, run)
  for f in slow:
    result.slow.add waitFor f
  for f in aborting:
    if waitFor f: inc result.aborted
  waitFor fast
  result.loadAfter = loadPerCpu()
  # Every request released: the 0th stats request, the slow, aborting and
  # fast ones, and the k-1 polls before poll k.
  let requests = slowClients + abortingClients + fastRequests
  let releaseDeadline = getMonoTime() + initDuration(seconds = 10)
  var k = 0
  while true:
    inc k
    result.releasedSeen = stats(n.port)
    result.releasedExpected = released0 + requests + k
    result.fdsAfter = fdCount(worker)
    result.fdsAtBaseline = result.fdsAfter == result.baselineFds
    if (result.releasedSeen == result.releasedExpected and
        result.fdsAtBaseline) or getMonoTime() > releaseDeadline:
      break
    sleep(100)
  for line in readFile(n.prefix / "fast.log").splitLines():
    if line.strip.len > 0:
      result.fastServerMs.add parseFloat(line.strip) * 1000.0
  # The log also holds the warm-up request.
  if result.fastServerMs.len > 0:
    result.fastServerMs.delete(0)

proc summary(r: BackpressureRun): string =
  var whole = 0
  for c in r.slow:
    if c.terminated and not c.invalid and c.body.len == BigSize: inc whole
  "slow whole " & $whole & "/" & $r.slow.len & ", aborted " & $r.aborted &
    ", fast ok " & $r.fastOk & ", fast client TTFB max " &
    (if r.fastClientMs.len > 0: $max(r.fastClientMs) & " ms" else: "-") &
    " (nginx $request_time max " &
    (if r.fastServerMs.len > 0: $max(r.fastServerMs) & " ms" else: "-") & ")" &
    ", fds " & $r.fdsAfter & " (baseline " & $r.baselineFds & ")" &
    ", released " & $r.releasedSeen & " (expected " & $r.releasedExpected & ")" &
    ", load/cpu " & formatFloat(r.loadBefore, ffDecimal, 2) & " / " &
    formatFloat(r.loadAfter, ffDecimal, 2)

suite "test_async_streaming_backpressure_and_abort":
  let n = startNginx(testModule(), backpressureLocations,
                     httpConf = backpressureHttp, listenOptions = "sndbuf=4096")
  let expected = patternBody(BigSize)

  test "negative control: a fast client receives the body whole":
    let raw = waitFor fetch(n.port, bigPath)
    let head = parseHead(raw)
    check head.statusLine == "HTTP/1.1 200 OK"
    let d = decodeChunked(raw, head.bodyStart)
    check d.terminated and not d.invalid
    check d.body == expected

  test "50 slow clients, 20 aborting, a fast one: whole bodies, released, fds back":
    let r = n.backpressureScenario(50, 20)
    echo "    ", r.summary
    check r.slow.len == 50
    for i, c in r.slow:
      check c.status == "HTTP/1.1 200 OK"
      check c.terminated
      check not c.invalid
      if c.body != expected:
        echo "    slow client ", i, ": ", c.body.len, " bytes, differs"
      check c.body == expected
    check r.aborted == 20
    check r.fastOk == 20
    check r.releasedSeen == r.releasedExpected
    check r.fdsAtBaseline
    check r.fastClientMs.len == 20
    let worst = if r.fastClientMs.len > 0: max(r.fastClientMs) else: Inf
    let load = max(r.loadBefore, r.loadAfter)
    if load > MaxLoadPerCpu:
      echo "    [NOT MEASURED] fast client's time to first byte < ",
        TtfbBoundMs, " ms (worst ", worst, " ms): the host's 1-minute load ",
        "average per CPU was ", formatFloat(load, ffDecimal, 2), " > ",
        formatFloat(MaxLoadPerCpu, ffDecimal, 2)
      inc notMeasured
    else:
      check worst < TtfbBoundMs

  n.stop()
  test "no alert in the log":
    check "[alert]" notin n.errorLogText

  test "falsifying mutation: NGX_AGAIN taken as sent truncates slow bodies":
    let mutant = buildMutant("again-as-sent", "src/ngx_http_isonim_module.c",
      "    if (rc != NGX_ERROR && !last) {\n        ngx_http_isonim_rpc_hold(r);\n    }",
      "    if (rc == NGX_AGAIN && !last && ngx_http_isonim_rpc_ctx(r) != NULL) {\n" &
      "        r->out = NULL;\n" &
      "        r->connection->buffered &= ~NGX_HTTP_WRITE_BUFFERED;\n" &
      "        rc = NGX_OK;\n    }")
    let m = startNginx(mutant, backpressureLocations,
                       httpConf = backpressureHttp, listenOptions = "sndbuf=4096")
    let r = m.backpressureScenario(10, 5, fastRequests = 4)
    m.stop()
    echo "    mutant: ", r.summary
    var whole = 0
    for c in r.slow:
      if c.terminated and not c.invalid and c.body == expected: inc whole
    check whole < r.slow.len

  test "falsifying mutation: no release on disconnect leaves descriptors open":
    let mutant = buildMutantFiles("no-release", [
      ("src/ngx_http_isonim_module.c",
       "    r->read_event_handler = ngx_http_test_reading;\n",
       "    r->read_event_handler = ngx_http_block_reading;\n"),
      ("src/ngx_http_isonim_module.c",
       "        /* The client went away: terminate; the pool cleanup releases the\n" &
       "         * Nim state. */\n        ngx_http_finalize_request(r, NGX_ERROR);\n",
       "        return;\n"),
      ("src/rpc.nim",
       "      st.sink.log(NGX_LOG_INFO, cause.msg & st.where)\n      st.finish(NGX_ERROR)\n",
       "      st.sink.log(NGX_LOG_INFO, cause.msg & st.where)\n")])
    let m = startNginx(mutant, backpressureLocations,
                       httpConf = backpressureHttp, listenOptions = "sndbuf=4096")
    let r = m.backpressureScenario(10, 5, fastRequests = 4)
    m.stop()
    echo "    mutant: ", r.summary
    check not r.fdsAtBaseline
    check r.releasedSeen < r.releasedExpected

  test "falsifying mutation: a producer blocking the event loop delays the fast client":
    # Not load-gated: a loaded host only lengthens the mutant's wait.  The
    # check fails when the timing cannot see a blocked event loop.
    let mutant = buildMutantEdits("blocking-producer",
      "tests/e2e/apps/stream_app.nim", [
        ("import std/[asyncdispatch, asyncnet, strutils, json]\n",
         "import std/[asyncdispatch, asyncnet, strutils, json, os]\n"),
        ("      body.flush()\n      written += n\n",
         "      body.flush()\n      os.sleep(15)\n      written += n\n")])
    let m = startNginx(mutant, backpressureLocations,
                       httpConf = backpressureHttp, listenOptions = "sndbuf=4096")
    let r = m.backpressureScenario(10, 5, fastRequests = 4)
    m.stop()
    echo "    mutant: ", r.summary
    check r.fastClientMs.len == 4
    let worst = if r.fastClientMs.len > 0: max(r.fastClientMs) else: 0.0
    check worst > SensitivityFactor * TtfbBoundMs

if notMeasured > 0:
  echo "NOT MEASURED: ", notMeasured,
    " latency assertion(s); the host was loaded (see above)"
