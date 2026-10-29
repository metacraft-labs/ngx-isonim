## test_long_stream.nim
##
## Long-lived streamed responses at isonim_rpc locations (spec/isonim-nginx.md,
## §The isonim_rpc Location: "Backpressure", "Buffer limit"), against real
## nginx with the real module (tests/e2e/harness.nim) and the apps of
## tests/e2e/apps/stream_app.nim.  One worker process.
##
## test_long_stream_memory_is_what_is_unsent
##   `stream_big` sends 128 MiB in 16 KiB flushed parts to a client that
##   reads as fast as it can, under `isonim_ssr_max_buffer_size 64k`.  The
##   worker's resident set, sampled every 20 ms while it streams, grows by
##   less than 32 MiB over its value before the request: the flushed parts
##   are freed once nginx has written them.
##   Vacuity guard: the client receives all 128 MiB, byte for byte (the
##   position-dependent pattern), with the terminating chunk; and the
##   sampler took samples while the body was in flight.
##   Negative control (the per-buffer limit): a single 128 KiB part over the
##   same 64 KiB limit is refused (500, nothing sent yet), logged.
##   Falsifying mutations (each run here, each must fail the bound or the
##   transfer): the flushed parts allocated in the request pool again
##   (`pool-buffers`, the module before this change) grows the worker by
##   about the whole body; the limit applied to the whole body again
##   (`whole-body-limit`) terminates the stream at 64 KiB.
##
## test_unsent_bytes_sees_a_slow_client
##   `stream_unsent` writes 16 KiB parts while its client, on a 4 KiB
##   receive buffer behind a 4 KiB send buffer (`sndbuf=4096`), reads
##   nothing.  The app stops as soon as the body writer's `unsentBytes`
##   exceeds 512 KiB: it has written less than 4 MiB (the 64 MiB cap it
##   would otherwise reach), and the unsent count it saw is over the
##   threshold.  The client then reads everything, and the app sees
##   `unsentBytes` fall to 0.
##   Vacuity guard: the client receives every byte the app reports written,
##   in the pattern; the app started and stopped (read through
##   `stream_stats`).
##   Falsifying mutation (run here): `unsentBytes` blind to what nginx holds
##   (`unsent-blind`: the module reports 0) lets the app write all 64 MiB.
##
## No mocks: real nginx, real sockets.  The only timing is the RSS sampler's
## period; no bound is a latency, so none is load-gated.  Every wait is for
## an event (bytes arriving, a stats value), with a deadline that only turns
## a hang into a failure.
##
## Run: nim c -r tests/e2e/test_long_stream.nim  (in the dev shell)

import std/[unittest, strutils, json, os, net, times, monotimes, asyncdispatch,
            asyncnet, posix]
import harness
import apps/stream_pattern

const
  LongSize = 128 * 1024 * 1024
  Part = 16 * 1024
  MaxGrowth = 32 * 1024 * 1024
  Threshold = 512 * 1024
  Cap = 64 * 1024 * 1024

let locations = """
    location /big/ {
      isonim_rpc on;
      isonim_rpc_app stream_big;
      isonim_rpc_timeout 0;
      isonim_ssr_max_buffer_size 64k;
    }
    location /unsent/ { isonim_rpc on; isonim_rpc_app stream_unsent; isonim_rpc_timeout 0; }
    location /stats/ { isonim_rpc on; isonim_rpc_app stream_stats; }
"""

proc rssOf(pid: int): int =
  ## The process's resident set in bytes (/proc/<pid>/status, VmRSS).
  for line in readFile("/proc/" & $pid & "/status").splitLines:
    if line.startsWith("VmRSS:"):
      return parseInt(line.splitWhitespace()[1]) * 1024
  -1

proc request(path: string): string =
  "GET " & path & " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"

type Decoded = object
  head: string
  body: string
  terminated: bool
  invalid: bool

proc decode(raw: string): Decoded =
  let sep = raw.find("\r\n\r\n")
  if sep < 0: return
  result.head = raw[0 ..< sep]
  var i = sep + 4
  while true:
    let eol = raw.find("\r\n", i)
    if eol < 0: return
    var size = 0
    try: size = fromHex[int](raw[i ..< eol].split(';')[0].strip())
    except ValueError:
      result.invalid = true
      return
    if size == 0:
      result.terminated = true
      return
    if raw.len < eol + 2 + size + 2: return
    result.body.add raw[eol + 2 ..< eol + 2 + size]
    i = eol + 2 + size + 2

proc matchesPattern(body: string; size: int): bool =
  if body.len != size: return false
  for i in 0 ..< size:
    if body[i] != patternByte(i): return false
  true

type LongRun = object
  received: Decoded
  samples: int
  maxGrowth: int

proc longStream(n: Nginx; path: string): LongRun =
  ## Streams `path` to a client that reads as fast as it can while the
  ## worker's RSS is sampled.
  let worker = n.workerPids[0]
  discard waitFor (proc (): Future[string] {.async.} =
    let s = newAsyncSocket(buffered = false)
    await s.connect("127.0.0.1", Port(n.port))
    await s.send(request("/stats/warm"))
    result = await s.recv(4096)
    s.close())()
  let base = rssOf(worker)
  var raw = newStringOfCap(LongSize + 1024 * 1024)
  var run = addr result
  proc sampler(done: ref bool) {.async.} =
    while not done[]:
      let g = rssOf(worker) - base
      inc run.samples
      if g > run.maxGrowth: run.maxGrowth = g
      await sleepAsync(20)
  proc client(done: ref bool) {.async.} =
    let s = newAsyncSocket(buffered = false)
    await s.connect("127.0.0.1", Port(n.port))
    await s.send(request(path))
    let deadline = getMonoTime() + initDuration(seconds = 300)
    while getMonoTime() < deadline:
      let got = await s.recv(1024 * 1024)
      if got.len == 0: break
      raw.add got
    s.close()
    done[] = true
  let done = new bool
  let sampling = sampler(done)
  waitFor client(done)
  waitFor sampling
  result.received = decode(raw)

proc stats(n: Nginx): JsonNode =
  let raw = waitFor (proc (): Future[string] {.async.} =
    let s = newAsyncSocket(buffered = false)
    await s.connect("127.0.0.1", Port(n.port))
    await s.send(request("/stats/s"))
    var r = ""
    while true:
      let part = await s.recv(4096)
      if part.len == 0: break
      r.add part
    s.close()
    return r)()
  parseJson(raw[raw.find("\r\n\r\n") + 4 .. ^1])["unsent"]

proc smallRcvbuf(s: AsyncSocket) =
  var size: cint = 4096
  discard posix.setsockopt(SocketHandle(s.getFd), SOL_SOCKET, SO_RCVBUF,
                           addr size, SockLen(sizeof(size)))

type UnsentRun = object
  stats: JsonNode
  drained: JsonNode
  received: Decoded

proc unsentScenario(n: Nginx): UnsentRun =
  ## A client that reads nothing until the app stopped, then everything.
  let s = newAsyncSocket(buffered = false)
  s.smallRcvbuf()
  waitFor s.connect("127.0.0.1", Port(n.port))
  waitFor s.send(request("/unsent/u?part=" & $Part & "&threshold=" & $Threshold &
                         "&limit=" & $Cap))
  let deadline = getMonoTime() + initDuration(seconds = 120)
  while getMonoTime() < deadline:
    result.stats = n.stats
    if result.stats{"stopped"}.getBool: break
    sleep(20)
  var raw = ""
  while getMonoTime() < deadline:
    let got = waitFor s.recv(1024 * 1024)
    if got.len == 0: break
    raw.add got
  s.close()
  result.received = decode(raw)
  while getMonoTime() < deadline:
    result.drained = n.stats
    if result.drained{"drained"}.getBool: break
    sleep(20)

suite "test_long_stream_memory_is_what_is_unsent":
  let module = testModule()
  let n = startNginx(module, locations)

  test "128 MiB in 16 KiB flushes: the worker grows by less than 32 MiB, the body arrives whole":
    let r = n.longStream("/big/b?size=" & $LongSize & "&part=" & $Part)
    echo "    samples ", r.samples, ", max growth ", r.maxGrowth div 1024, " KiB"
    check r.received.terminated and not r.received.invalid
    check r.received.body.matchesPattern(LongSize)
    check r.samples >= 3
    check r.maxGrowth < MaxGrowth

  test "negative control: one 128 KiB part over the 64 KiB per-buffer limit is refused, logged":
    let r = n.longStream("/big/b?size=" & $(256 * 1024) & "&part=" & $(128 * 1024))
    check r.received.head.startsWith("HTTP/1.1 500")
    check "exceeds isonim_ssr_max_buffer_size (65536 bytes)" in n.errorLogText

  n.stop()

  test "falsifying mutation: buffers in the request pool grow the worker by about the body":
    let mutant = buildMutant("pool-buffers", "src/ngx_http_isonim_module.c",
      "    if (len > 0 && ctx != NULL) {", "    if (len > 0 && ctx != NULL && 0) {")
    let m = startNginx(mutant, locations)
    let r = m.longStream("/big/b?size=" & $LongSize & "&part=" & $Part)
    m.stop()
    echo "    mutant: max growth ", r.maxGrowth div 1024, " KiB"
    check r.received.body.len == LongSize          # it streamed: the mutant's own guard
    check r.maxGrowth >= MaxGrowth                 # and the bound sees it

  test "falsifying mutation: the limit on the whole body stops the stream at 64 KiB":
    let mutant = buildMutant("whole-body-limit", "src/rpc.nim",
      "maxBufferSize: opts.maxBufferSize, limitPerBuffer: true), sink)",
      "maxBufferSize: opts.maxBufferSize, limitPerBuffer: false), sink)")
    let m = startNginx(mutant, locations)
    let r = m.longStream("/big/b?size=" & $(4 * 1024 * 1024) & "&part=" & $Part)
    m.stop()
    check not r.received.terminated
    check r.received.body.len <= 64 * 1024

suite "test_unsent_bytes_sees_a_slow_client":
  let module = testModule()

  test "the app stops on unsentBytes, then sees the client drain it":
    let n = startNginx(module, locations, listenOptions = "sndbuf=4096")
    let r = n.unsentScenario()
    n.stop()
    echo "    stopped at ", r.stats{"written"}.getInt div 1024, " KiB written, ",
      r.stats{"unsent"}.getInt div 1024, " KiB unsent"
    check r.stats{"started"}.getBool and r.stats{"stopped"}.getBool
    let written = r.stats{"written"}.getInt
    check written < 4 * 1024 * 1024
    check r.stats{"unsent"}.getInt > Threshold
    check r.received.terminated
    check r.received.body.matchesPattern(written)
    check r.drained{"drained"}.getBool

  test "falsifying mutation: unsentBytes blind to nginx lets the app write everything":
    let mutant = buildMutant("unsent-blind", "src/handler.nim",
      "int(ngx_http_isonim_rpc_unsent(r))", "0")
    let m = startNginx(mutant, locations, listenOptions = "sndbuf=4096")
    let r = m.unsentScenario()
    m.stop()
    echo "    mutant: stopped at ", r.stats{"written"}.getInt div 1024, " KiB written"
    check r.stats{"written"}.getInt >= Cap
