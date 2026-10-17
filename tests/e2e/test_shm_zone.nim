## test_shm_zone.nim
##
## Application shared-memory zones (src/shm_table.nim, the
## `isonim_shm_zone` directive) against a real nginx with four worker
## processes and the real module (tests/e2e/harness.nim), driving the async
## apps of tests/e2e/apps/shm_app.nim over HTTP
## (spec/isonim-nginx.md, "Shared-Memory Zones for Applications").
##
## * test_shm_zone_is_shared_by_every_worker: a value stored through one
##   worker is read, with its version, by every worker; a key never stored
##   is absent in every worker; an app that binds an undeclared zone gets
##   500 with the zone named in the error log (and so does every request of
##   a worker whose registration binds one).
## * test_shm_compare_and_set_under_contention: 64 concurrent clients
##   increment one value 10,000 times by read and putIf, retrying on
##   conflict; 200 concurrent incr calls against high 50.
## * test_shm_eviction_bounds_the_zone: a 64k zone receives ten times its
##   size in distinct keys while one key is read between every store and a
##   counter is held at 3; then a value one byte over max_value.
## * test_shm_zone_across_reload: an unchanged reload keeps the contents and
##   the old and new workers share the zone; a changed size or max_value
##   starts empty; a changed codec version fails the typed bind.  A reload
##   that changes max_value and then fails leaves the next reload, of the
##   original configuration, unaffected; a successful one has the master
##   unmap the old segment.
## * test_shm_lock_survives_a_worker_dying_inside_it: a worker blocked by the
##   test-build store hook inside the zone's lock is killed by its pid (read
##   from the hook, checked to be a child of our nginx master); nginx's
##   master releases the lock and the other workers answer within 1 s.
## * isonim_shm_zone is validated by nginx -t.
##
## Each test runs its falsifying mutation (`buildMutant`) as a test of its
## own, named "mutant: ...": a per-process table, putIf without its version
## comparison, eviction from the most-recently-used end, every zone declared
## noreuse, the old zone marked noreuse while a configuration that may still
## fail is read, and a lock of the module's own instead of the slab pool's
## mutex.  tests/e2e/test_shm_asan.sh runs the tests without the mutants
## against a module built with AddressSanitizer and UBSan.
##
## Spreading requests over the workers: tests 1, 2 and 4 listen with
## `reuseport`, so each worker has its own listening socket and the kernel
## hashes every new connection to one of them; a test opens fresh
## connections until it has seen each worker's pid (bounded).  The
## worker-death test listens without `reuseport`, so that the blocked
## worker, which no longer waits in epoll, takes no connections.
##
## Synchronization, never sleeps: the worker-death test learns that the hook
## holds the lock from the FIFO the hook writes its pid to, and the master's
## release from its error log; the reload test waits for our master's
## children to be replaced, and the held request learns of its release from
## the zone itself.  The only waits are polls of such conditions, each with
## a deadline.
##
## No mocks: real nginx, real workers, real shared memory.
##
## Run: nim c -r tests/e2e/test_shm_zone.nim  (in the dev shell)

import std/[unittest, strutils, json, os, osproc, times, monotimes, net,
            asyncdispatch, asyncnet, posix, sets, tables, algorithm, sequtils,
            streams]
import harness

const
  workers = 4
  shmLocations = """
    location /shm/ { isonim_rpc on; isonim_rpc_app shm_test; isonim_rpc_timeout 60s; }
    location /other/ { isonim_rpc on; isonim_rpc_app shm_undeclared; }
"""

# ---------------------------------------------------------------------------
# A minimal HTTP/1.1 client (keep-alive), synchronous and asynchronous.  The
# module answers isonim_rpc requests with Content-Length, which is all it
# needs to read.
# ---------------------------------------------------------------------------

type
  Reply = object
    status: int
    body: string
    json: JsonNode        ## nil when the body is not JSON

  Conn = object
    sock: Socket
    port: int
    open: bool

proc toReply(status: int; body: string): Reply =
  result = Reply(status: status, body: body)
  try:
    result.json = parseJson(body)
  except CatchableError:
    result.json = nil

proc requestText(meth, path, body: string): string =
  meth & " " & path & " HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: " &
    $body.len & "\r\n\r\n" & body

proc parseStatus(line: string): int =
  let parts = line.split(' ')
  if parts.len < 2 or not parts[0].startsWith("HTTP/"):
    raise newException(IOError, "bad status line: " & line)
  parseInt(parts[1])

proc connect(port: int): Conn =
  result = Conn(sock: newSocket(), port: port, open: true)
  result.sock.connect("127.0.0.1", Port(port), timeout = 5000)

proc close(c: var Conn) =
  if c.open:
    c.sock.close()
    c.open = false

proc sendRequest(c: var Conn; meth, path: string; body = "") =
  if not c.open:
    c = connect(c.port)
  c.sock.send(requestText(meth, path, body))

proc readReply(c: var Conn; timeoutMs = 20_000): Reply =
  ## Reads one answer; raises TimeoutError when it does not come in time.
  let status = parseStatus(c.sock.recvLine(timeout = timeoutMs))
  var length = 0
  var closing = false
  while true:
    let line = c.sock.recvLine(timeout = timeoutMs)
    if line == "\r\n" or line.len == 0:
      break
    let colon = line.find(':')
    if colon > 0:
      let name = line[0 ..< colon].strip.toLowerAscii
      let value = line[colon + 1 .. ^1].strip
      if name == "content-length": length = parseInt(value)
      elif name == "connection" and value.toLowerAscii == "close": closing = true
  let body = if length > 0: c.sock.recv(length, timeout = timeoutMs) else: ""
  if closing:
    c.close()
  toReply(status, body)

proc send(c: var Conn; meth, path: string; body = "";
          timeoutMs = 20_000): Reply =
  c.sendRequest(meth, path, body)
  c.readReply(timeoutMs)

proc oneShot(port: int; meth, path: string; body = ""): Reply =
  ## One request on a new connection (which reuseport hashes to a worker).
  var c = connect(port)
  try:
    result = c.send(meth, path, body)
  finally:
    c.close()

type AConn = ref object
  sock: AsyncSocket
  port: int

proc aconnect(port: int): Future[AConn] {.async.} =
  result = AConn(sock: newAsyncSocket(), port: port)
  await result.sock.connect("127.0.0.1", Port(port))

proc asend(c: AConn; meth, path: string; body = ""): Future[Reply] {.async.} =
  await c.sock.send(requestText(meth, path, body))
  let status = parseStatus(await c.sock.recvLine())
  var length = 0
  var closing = false
  while true:
    let line = await c.sock.recvLine()
    if line == "\r\n" or line.len == 0:
      break
    let colon = line.find(':')
    if colon > 0:
      let name = line[0 ..< colon].strip.toLowerAscii
      let value = line[colon + 1 .. ^1].strip
      if name == "content-length": length = parseInt(value)
      elif name == "connection" and value.toLowerAscii == "close": closing = true
  let body = if length > 0: await c.sock.recv(length) else: ""
  if closing:
    c.sock.close()
    c.sock = newAsyncSocket()
    await c.sock.connect("127.0.0.1", Port(c.port))
  return toReply(status, body)

proc pidOf(r: Reply): int =
  doAssert r.json != nil, "not a JSON answer (" & $r.status & "): " & r.body
  r.json["pid"].getInt

proc versionOf(r: Reply; field = "version"): uint64 =
  uint64(r.json[field].getBiggestInt)

proc startShm(module: string; httpConf: string; mainConf = "";
              reuseport = true): Nginx =
  startNginx(module, shmLocations, workerProcesses = workers,
    httpConf = "  keepalive_requests 1000000;\n" & httpConf,
    mainConf = mainConf, listenOptions = (if reuseport: "reuseport" else: ""))

proc mutant(name, file, original, replacement: string): string =
  buildMutant(name, file, original, replacement)

# ---------------------------------------------------------------------------
# test_shm_zone_is_shared_by_every_worker
# ---------------------------------------------------------------------------

type Sharing = object
  writerPid: int
  version: uint64
  workerPids: seq[int]
  stored: Table[int, Reply]      ## a worker's first answer for the stored key
  absent: Table[int, Reply]      ## its first answer for a key never stored

proc observeSharing(n: Nginx): Sharing =
  result.workerPids = n.workerPids
  let w = oneShot(n.port, "POST", "/shm/put?zone=shared_a&key=k1", "value-1")
  doAssert w.status == 200 and w.json["result"].getStr == "stored", w.body
  result.writerPid = w.pidOf
  result.version = w.versionOf
  var tries = 0
  while (result.stored.len < workers or result.absent.len < workers) and
        tries < 4000:
    inc tries
    let r = oneShot(n.port, "GET", "/shm/get?zone=shared_a&key=k1")
    if r.pidOf notin result.stored: result.stored[r.pidOf] = r
    let a = oneShot(n.port, "GET", "/shm/get?zone=shared_a&key=never_stored")
    if a.pidOf notin result.absent: result.absent[a.pidOf] = a

const sharingConf = "  isonim_shm_zone shared_a size=1m;\n"

suite "test_shm_zone_is_shared_by_every_worker":
  test "every worker reads what one worker stored; undeclared zones are refused":
    let module = testModule()
    let n = startShm(module, sharingConf)
    defer: n.stop()
    let s = observeSharing(n)
    # Vacuity guard: four distinct workers answered, each with the value
    # and its version.
    check s.workerPids.len == workers
    check s.stored.len == workers
    check toHashSet(toSeq(s.stored.keys)) == toHashSet(s.workerPids)
    for pid, r in s.stored:
      check r.json["found"].getBool
      check r.json["value"].getStr == "value-1"
      check r.versionOf == s.version
    # Negative control: a key never stored is absent in every worker.
    check s.absent.len == workers
    for pid, r in s.absent:
      check not r.json["found"].getBool
    # The app that binds an undeclared zone: 500, the zone named.
    for i in 0 ..< 16:
      let r = oneShot(n.port, "GET", "/other/x")
      check r.status == 500
    check n.errorLogText.contains("ShmZoneError: shared-memory zone " &
      "\"not_declared_zone\" is not declared")

  test "a zone bound at registration that is not declared fails every request":
    let module = testModule()
    # The twin: the same registration-time bind of a declared zone works.
    block:
      let n = startShm(module, "  isonim_shm_zone registration_zone size=64k;\n",
        mainConf = "env SHM_TEST_BIND_AT_REGISTRATION=registration_zone;")
      defer: n.stop()
      check oneShot(n.port, "GET", "/shm/pid").status == 200
    let n = startShm(module, sharingConf,
      mainConf = "env SHM_TEST_BIND_AT_REGISTRATION=registration_zone;")
    defer: n.stop()
    for i in 0 ..< 12:
      check oneShot(n.port, "GET", "/shm/pid").status == 500
    check n.errorLogText.contains("registering the applications failed: " &
      "ShmZoneError: shared-memory zone \"registration_zone\" is not declared")

  test "mutant: a per-process table instead of the zone":
    let module = mutant("per-process-table", "src/ngx_http_isonim_module.c",
      "        sp = (ngx_slab_pool_t *) zc->shm_zone->shm.addr;  /* the zone itself */",
      """        {
            /* MUTANT: a private, per-process pool of the zone's size. */
            static ngx_slab_pool_t  *priv;
            if (priv == NULL) {
                priv = mmap(NULL, zc->size, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
                priv->end = (u_char *) priv + zc->size;
                priv->min_shift = 3;
                priv->addr = priv;
                ngx_shmtx_create(&priv->mutex, &priv->lock, NULL);
                ngx_slab_init(priv);
            }
            sp = priv;
        }""")
    let n = startShm(module, sharingConf)
    defer: n.stop()
    let s = observeSharing(n)
    check s.stored.len == workers
    # The falsified property: every worker but the writer answers absent.
    for pid, r in s.stored:
      if pid == s.writerPid:
        check r.json["found"].getBool
      else:
        check not r.json["found"].getBool

# ---------------------------------------------------------------------------
# test_shm_compare_and_set_under_contention
# ---------------------------------------------------------------------------

type Contention = object
  stored, conflicts, putIfCalls: int
  final: int

proc contend(n: Nginx; clients, total: int; key: string): Contention =
  ## `clients` keep-alive clients increment `key` `total` times by read and
  ## putIf with the version read, retrying on conflict.  Each increment is
  ## claimed before it is attempted, so exactly `total` succeed.
  var c: Contention
  var claimed = 0
  let path = "/shm/get?zone=cas&key=" & key
  proc client(): Future[void] {.async.} =
    let conn = await aconnect(n.port)
    while claimed < total:
      inc claimed
      while true:
        let g = await conn.asend("GET", path)
        doAssert g.status == 200, g.body
        var version = 0'u64
        var value = 0
        if g.json["found"].getBool:
          version = g.versionOf
          value = parseInt(g.json["value"].getStr)
        let p = await conn.asend("POST", "/shm/putif?zone=cas&key=" & key &
          "&expected=" & $version, $(value + 1))
        inc c.putIfCalls
        case p.json["result"].getStr
        of "stored":
          inc c.stored
          break
        of "conflict":
          inc c.conflicts
        else:
          raise newException(IOError, "unexpected putIf answer: " & p.body)
    conn.sock.close()
  var futures: seq[Future[void]]
  for i in 0 ..< clients:
    futures.add client()
  let everyone = all(futures)
  doAssert waitFor(everyone.withTimeout(300_000)), "the clients did not finish"
  let g = oneShot(n.port, "GET", path)
  c.final = parseInt(g.json["value"].getStr)
  c

type Counting = object
  counted: seq[int]
  outOfRange: int
  final: int

proc countConcurrently(n: Nginx; calls, high: int): Counting =
  var r: Counting
  proc one(): Future[void] {.async.} =
    let conn = await aconnect(n.port)
    let a = await conn.asend("POST", "/shm/incr?zone=cas&key=admission" &
      "&delta=1&low=0&high=" & $high)
    case a.json["result"].getStr
    of "counted": r.counted.add a.json["value"].getInt
    of "outOfRange": inc r.outOfRange
    else: raise newException(IOError, "unexpected incr answer: " & a.body)
    conn.sock.close()
  var futures: seq[Future[void]]
  for i in 0 ..< calls:
    futures.add one()
  doAssert waitFor(all(futures).withTimeout(120_000)), "incr calls did not finish"
  let f = oneShot(n.port, "POST", "/shm/incr?zone=cas&key=admission" &
    "&delta=0&low=0&high=" & $high)
  r.final = f.json["value"].getInt
  r

const casConf = "  isonim_shm_zone cas size=1m;\n"

suite "test_shm_compare_and_set_under_contention":
  test "putIf never loses an update; incr never leaves its range":
    let module = testModule()
    let n = startShm(module, casConf)
    defer: n.stop()
    let c = contend(n, 64, 10_000, "value")
    echo "    contention: ", c
    # Vacuity guard: at least 1% of the putIf calls met a conflict.
    check c.conflicts * 100 >= c.putIfCalls
    # Negative control: the final value is the number of stored answers.
    check c.stored == 10_000
    check c.final == c.stored
    # 200 concurrent incr calls against high 50.
    let k = countConcurrently(n, 200, 50)
    check k.counted.len == 50
    check k.outOfRange == 150
    check k.final == 50
    check sorted(k.counted) == toSeq(1 .. 50)
    let st = oneShot(n.port, "GET", "/shm/stats?zone=cas")
    echo "    stats: ", st.json["stats"]
    check st.json["stats"]["lockWaits"].getInt > 0
    # Negative control: one client never conflicts.
    let solo = contend(n, 1, 500, "solo")
    check solo.conflicts == 0
    check solo.stored == 500
    check solo.final == 500

  test "mutant: putIf without its version comparison":
    let module = mutant("putif-no-compare", "src/shm_table.nim",
      "      if current != expected:",
      "      if false and current != expected:")
    let n = startShm(module, casConf)
    defer: n.stop()
    let c = contend(n, 64, 10_000, "value")
    echo "    contention (mutant): ", c
    check c.stored == 10_000
    # The falsified property: updates were lost.
    check c.final < c.stored

# ---------------------------------------------------------------------------
# test_shm_eviction_bounds_the_zone
# ---------------------------------------------------------------------------

type Eviction = object
  stores: int
  hotMisses: int            ## reads of the hot key that found it absent
  maxBytesUsed: int
  overSize: bool            ## a sample's bytes used + free exceeded the size
  final: JsonNode           ## stats after the stores
  hot, counter, first, last: Reply
  oversized: Reply
  hotAfter: Reply
  statsAfter: JsonNode

proc driveEviction(n: Nginx): Eviction =
  const zoneSize = 64 * 1024
  const valueSize = 600
  var c = connect(n.port)
  defer: c.close()
  let inc3 = c.send("POST", "/shm/incr?zone=small&key=counter&delta=3&low=0&high=100")
  doAssert inc3.json["result"].getStr == "counted", inc3.body
  let hp = c.send("POST", "/shm/put?zone=small&key=hot", "hot-value")
  doAssert hp.json["result"].getStr == "stored", hp.body
  var written = 0
  var i = 0
  while written < 10 * zoneSize:
    let v = repeat(char(ord('a') + i mod 26), valueSize)
    let p = c.send("POST", "/shm/put?zone=small&key=k" & $i, v)
    doAssert p.json["result"].getStr == "stored", "store " & $i & ": " & p.body
    written += valueSize
    inc result.stores
    let h = c.send("GET", "/shm/get?zone=small&key=hot")
    if not h.json["found"].getBool:
      inc result.hotMisses
    let s = c.send("GET", "/shm/stats?zone=small").json["stats"]
    result.maxBytesUsed = max(result.maxBytesUsed, s["bytesUsed"].getInt)
    if s["bytesUsed"].getInt + s["bytesFree"].getInt > zoneSize:
      result.overSize = true
    inc i
  result.final = c.send("GET", "/shm/stats?zone=small").json["stats"]
  result.hot = c.send("GET", "/shm/get?zone=small&key=hot")
  result.counter = c.send("GET", "/shm/get?zone=small&key=counter")
  result.first = c.send("GET", "/shm/get?zone=small&key=k0")
  result.last = c.send("GET", "/shm/get?zone=small&key=k" & $(i - 1))
  # One byte over max_value (4k, the default).
  result.oversized = c.send("POST", "/shm/put?zone=small&key=hot",
                            repeat('x', 4096 + 1))
  result.hotAfter = c.send("GET", "/shm/get?zone=small&key=hot")
  result.statsAfter = c.send("GET", "/shm/stats?zone=small").json["stats"]

proc counterValue(r: Reply): int64 =
  ## A counter's 8 bytes, little-endian.
  let raw = r.json["value"].getStr
  doAssert raw.len == 8, "a counter holds 8 bytes, not " & $raw.len
  for j in countdown(7, 0):
    result = (result shl 8) or int64(ord(raw[j]))

const smallConf = "  isonim_shm_zone small size=64k;\n"

suite "test_shm_eviction_bounds_the_zone":
  test "a full zone evicts its least recently used entries, never a counter":
    let module = testModule()
    let n = startShm(module, smallConf)
    defer: n.stop()
    let e = driveEviction(n)
    echo "    stores: ", e.stores, ", max bytes used: ", e.maxBytesUsed,
      ", final: ", e.final
    # Vacuity guard: evictions happened; the bytes used never exceeded the
    # zone's size at any sample.
    check e.final["evictions"].getInt > 0
    check e.maxBytesUsed <= 64 * 1024
    check not e.overSize
    # Negative control: the key read throughout and the non-zero counter
    # are still there; the earliest unread key is gone, the latest is not.
    check e.hotMisses == 0
    check e.hot.json["found"].getBool
    check e.hot.json["value"].getStr == "hot-value"
    check e.counter.json["found"].getBool
    check e.counter.counterValue == 3
    check not e.first.json["found"].getBool
    check e.last.json["found"].getBool
    # The oversized value answers tooLarge and changes nothing.
    check e.oversized.json["result"].getStr == "tooLarge"
    check e.hotAfter.json["value"].getStr == "hot-value"
    check e.hotAfter.versionOf == e.hot.versionOf
    check e.statsAfter["stores"].getInt == e.final["stores"].getInt
    check e.statsAfter["refusedTooLarge"].getInt ==
      e.final["refusedTooLarge"].getInt + 1

  test "mutant: eviction from the most recently used end":
    let module = mutant("evict-mru", "src/shm_table.nim",
      "    var victim = h.tailEntry",
      "    var victim = h.headEntry")
    let n = startShm(module, smallConf)
    defer: n.stop()
    let e = driveEviction(n)
    check e.final["evictions"].getInt > 0
    # The falsified property: the key read throughout was evicted.
    check e.hotMisses > 0

# ---------------------------------------------------------------------------
# test_shm_zone_across_reload
# ---------------------------------------------------------------------------

proc reloadConf(size = "1m"; maxValue = ""): string =
  "  isonim_shm_zone reload_z size=" & size &
    (if maxValue.len > 0: " max_value=" & maxValue else: "") & ";\n" &
    "  isonim_shm_zone typed_z size=1m;\n"

proc sampleWorkers(n: Nginx; path: string): Table[int, Reply] =
  ## One answer from each worker (fresh connections), at most 4000 tries.
  var tries = 0
  while result.len < workers and tries < 4000:
    inc tries
    let r = oneShot(n.port, "GET", path)
    if r.pidOf notin result:
      result[r.pidOf] = r

proc sharedMappings(pid: int): int =
  ## How many shared mappings (`rw-s`) process `pid` has: nginx maps each
  ## zone's segment once in its master.
  for line in readFile("/proc/" & $pid & "/maps").splitLines:
    let fields = line.splitWhitespace
    if fields.len >= 2 and fields[1] == "rw-s":
      inc result

proc codecEnv(version: int): string =
  "env SHM_TEST_CODEC_VERSION=" & $version & ";"

suite "test_shm_zone_across_reload":
  test "an unchanged reload keeps the zone; a changed one starts empty":
    let module = testModule()
    var n = startShm(module, reloadConf(), mainConf = codecEnv(1))
    defer: n.stop()
    check oneShot(n.port, "POST", "/shm/put?zone=reload_z&key=a", "alpha").status == 200
    check oneShot(n.port, "POST", "/shm/put?zone=reload_z&key=b", "beta").status == 200
    check oneShot(n.port, "POST", "/shm/tput?zone=typed_z&key=t", "typed-1").json["result"].getStr == "stored"

    # A request held open on an old worker across the reload.
    let held = startProcess("curl", args = @["-sS", "--max-time", "60",
      n.url("/shm/hold?zone=reload_z&release=go")], options = {poUsePath})
    var holder = 0
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while holder == 0:
      let r = oneShot(n.port, "GET", "/shm/get?zone=reload_z&key=holder")
      if r.json["found"].getBool:
        holder = parseInt(r.json["value"].getStr)
      elif getMonoTime() > deadline:
        raise newException(OSError, "the held request never started")
    let gen0 = n.workerPids
    check holder in gen0

    # 1. Unchanged configuration.
    n.reload(reloadConf())
    let gen1 = n.waitForWorkers(gen0, keep = @[holder])
    let answers1 = n.sampleWorkers("/shm/get?zone=reload_z&key=a")
    # Vacuity guard: every accepting worker was replaced.
    check answers1.len == workers
    for pid, r in answers1:
      check pid in gen1 and pid notin gen0
      # Negative control: the new workers read the stored values.
      check r.json["found"].getBool and r.json["value"].getStr == "alpha"
    check oneShot(n.port, "GET", "/shm/get?zone=reload_z&key=b").json["value"].getStr == "beta"
    check processAlive(holder)
    # Released by a new worker, the held request finishes on its old one,
    # and what it stored there is read by a new one.
    let rel = oneShot(n.port, "POST", "/shm/put?zone=reload_z&key=go", "1")
    check rel.pidOf in gen1
    check held.waitForExit(30_000) == 0
    let heldAnswer = parseJson(held.outputStream.readAll())
    held.close()
    check heldAnswer["pid"].getInt == holder
    let fromOld = oneShot(n.port, "GET", "/shm/get?zone=reload_z&key=old_store")
    check fromOld.pidOf in gen1
    check fromOld.json["value"].getStr == "from-old-" & $holder
    let typed1 = oneShot(n.port, "GET", "/shm/tget?zone=typed_z&key=t")
    check typed1.json["value"].getStr == "typed-1"

    # 2. The zone's size changed: the new workers see an empty zone; the
    #    unchanged typed zone keeps its contents.
    n.reload(reloadConf(size = "2m"))
    let gen2 = n.waitForWorkers(gen1)
    let answers2 = n.sampleWorkers("/shm/get?zone=reload_z&key=a")
    check answers2.len == workers
    for pid, r in answers2:
      check pid in gen2 and pid notin gen1
      check not r.json["found"].getBool
    check oneShot(n.port, "GET", "/shm/tget?zone=typed_z&key=t").json["value"].getStr == "typed-1"

    # 3. Its max_value changed (size unchanged): empty again.
    check oneShot(n.port, "POST", "/shm/put?zone=reload_z&key=a", "alpha-2").status == 200
    n.reload(reloadConf(size = "2m", maxValue = "8k"))
    let gen3 = n.waitForWorkers(gen2)
    let answers3 = n.sampleWorkers("/shm/get?zone=reload_z&key=a")
    check answers3.len == workers
    for pid, r in answers3:
      check pid in gen3 and pid notin gen2
      check not r.json["found"].getBool
    check n.errorLogText.contains("isonim_shm_zone \"reload_z\" starts empty")

    # 4. The typed table's codec version changed: the bind fails and the
    #    error names the zone; the unchanged raw zone keeps its contents.
    check oneShot(n.port, "POST", "/shm/put?zone=reload_z&key=a", "alpha-3").status == 200
    n.reload(reloadConf(size = "2m", maxValue = "8k"), mainConf = codecEnv(2))
    let gen4 = n.waitForWorkers(gen3)
    for i in 0 ..< 16:
      check oneShot(n.port, "GET", "/shm/tget?zone=typed_z&key=t").status == 500
    check n.errorLogText.contains("ShmZoneError: shared-memory zone " &
      "\"typed_z\" holds values of codec e2e-strings version 1, not " &
      "e2e-strings version 2")
    let raw4 = n.sampleWorkers("/shm/get?zone=reload_z&key=a")
    check raw4.len == workers
    for pid, r in raw4:
      check pid in gen4
      check r.json["value"].getStr == "alpha-3"

  test "mutant: every zone declared noreuse":
    let module = mutant("noreuse", "src/ngx_http_isonim_module.c",
      "    shm_zone->init = ngx_http_isonim_shm_init;",
      "    shm_zone->init = ngx_http_isonim_shm_init;\n    shm_zone->noreuse = 1;")
    var n = startShm(module, reloadConf(), mainConf = codecEnv(1))
    defer: n.stop()
    check oneShot(n.port, "POST", "/shm/put?zone=reload_z&key=a", "alpha").status == 200
    let gen0 = n.workerPids
    n.reload(reloadConf())
    let gen1 = n.waitForWorkers(gen0)
    let answers = n.sampleWorkers("/shm/get?zone=reload_z&key=a")
    check answers.len == workers
    # The falsified property: the unchanged reload lost the stored values.
    for pid, r in answers:
      check pid in gen1
      check not r.json["found"].getBool

  test "a reload that fails leaves the next one unaffected":
    # A reload whose configuration changes a zone's max_value and then
    # fails (here: an unknown directive after it) must leave the running
    # zone as it was, so that the next reload, of the original
    # configuration, reuses the segment and its new workers serve it.  Then
    # a max_value change that succeeds: the master unmaps the old segment
    # (its count of shared mappings is unchanged).
    let module = testModule()
    var n = startShm(module, reloadConf(), mainConf = codecEnv(1))
    defer: n.stop()
    check oneShot(n.port, "POST", "/shm/put?zone=reload_z&key=a", "alpha").status == 200
    let mappings0 = sharedMappings(n.masterPid)
    let gen0 = n.workerPids
    n.reload(reloadConf(maxValue = "8k") & "  no_such_directive_xyz on;\n")
    let refused = "unknown directive \"no_such_directive_xyz\""
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while not n.errorLogText.contains(refused) and getMonoTime() < deadline:
      sleep(10)
    # Vacuity guard: the reload was refused, and it changed no worker.
    check n.errorLogText.contains(refused)
    check n.workerPids == gen0
    n.reload(reloadConf())
    let gen1 = n.waitForWorkers(gen0)
    let answers = n.sampleWorkers("/shm/get?zone=reload_z&key=a")
    check answers.len == workers
    for pid, r in answers:
      check pid in gen1
      check r.json["found"].getBool and r.json["value"].getStr == "alpha"
    check not n.errorLogText.contains("exited on signal")
    # A max_value change that succeeds: empty, and the old segment unmapped
    # in the master (a new one replaced it).
    n.reload(reloadConf(maxValue = "8k"))
    let gen2 = n.waitForWorkers(gen1)
    let empty = n.sampleWorkers("/shm/get?zone=reload_z&key=a")
    check empty.len == workers
    for pid, r in empty:
      check pid in gen2
      check not r.json["found"].getBool
    check sharedMappings(n.masterPid) == mappings0
    check not n.errorLogText.contains("exited on signal")

  test "mutant: the old zone marked noreuse while the configuration is read":
    let module = mutant("old-noreuse-at-parse", "src/ngx_http_isonim_module.c",
      "            /* Never the old zone here: see above and init_module. */\n" &
      "            shm_zone->noreuse = 1;",
      "            shm_zone->noreuse = 1;\n            oshm[i].noreuse = 1;")
    var n = startShm(module, reloadConf(), mainConf = codecEnv(1))
    defer: n.stop()
    check oneShot(n.port, "POST", "/shm/put?zone=reload_z&key=a", "alpha").status == 200
    let gen0 = n.workerPids
    n.reload(reloadConf(maxValue = "8k") & "  no_such_directive_xyz on;\n")
    let refused = "unknown directive \"no_such_directive_xyz\""
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while not n.errorLogText.contains(refused) and getMonoTime() < deadline:
      sleep(10)
    check n.errorLogText.contains(refused)
    n.reload(reloadConf())
    # The falsified property: the master unmapped the segment the new
    # cycle reuses, so the new workers cannot serve the zone (they, or the
    # master, die).  Fresh connections, at most 20, each bounded by 5 s.
    let fresh = "/shm/get?zone=reload_z&key=a"
    var served = 0
    for i in 0 ..< 20:
      let r = curl(["-sS", "--max-time", "5", n.url(fresh)])
      if r.exitCode == 0 and r.output.contains("\"alpha\""):
        inc served
    check served < 20

  # Not part of the reload test proper, but behind it: test_e2e.sh and
  # this file assume what nginx -t refuses.
  test "isonim_shm_zone is validated by nginx -t":
    let module = testModule()
    proc t(conf: string): tuple[code: int, output: string] =
      testConfig(module, "    location / { return 200; }", httpConf = conf)
    check t("  isonim_shm_zone ok_zone size=64k;").code == 0
    check t("  isonim_shm_zone ok_zone size=1m max_value=256k;").code == 0
    let dup = t("  isonim_shm_zone z size=64k;\n  isonim_shm_zone z size=128k;")
    check dup.code != 0 and dup.output.contains("\"z\" is declared twice")
    let small = t("  isonim_shm_zone z size=63k;")
    check small.code != 0 and small.output.contains("outside 64k to 4g")
    let big = t("  isonim_shm_zone z size=5g;")
    check big.code != 0 and big.output.contains("outside 64k to 4g")
    let quarter = t("  isonim_shm_zone z size=64k max_value=17k;")
    check quarter.code != 0 and quarter.output.contains("at most a quarter")
    check t("  isonim_shm_zone z size=64k max_value=16k;").code == 0
    check t("  isonim_shm_zone z size=4g max_value=1g;").code == 0
    let zero = t("  isonim_shm_zone z size=64k max_value=0;")
    check zero.code != 0
    let name = t("  isonim_shm_zone Bad-Name size=64k;")
    check name.code != 0 and name.output.contains("may hold only [a-z0-9_]")
    let long = t("  isonim_shm_zone " & repeat('a', 65) & " size=64k;")
    check long.code != 0 and long.output.contains("1 to 64 characters")
    check t("  isonim_shm_zone " & repeat('a', 64) & " size=64k;").code == 0
    let nosize = t("  isonim_shm_zone z max_value=1k;")
    check nosize.code != 0 and nosize.output.contains("requires size=")
    let unknown = t("  isonim_shm_zone z size=64k colour=blue;")
    check unknown.code != 0 and unknown.output.contains("invalid isonim_shm_zone parameter")
    let inServer = testConfig(module,
      "    isonim_shm_zone z size=64k;\n    location / { return 200; }")
    check inServer.code != 0 and inServer.output.contains("not allowed here")

# ---------------------------------------------------------------------------
# test_shm_lock_survives_a_worker_dying_inside_it
# ---------------------------------------------------------------------------

type Death = object
  victimPid: int
  hookLogged: bool
  victimWasOurs: bool
  masterReleased: bool
  answeredInTime: int        ## requests answered within 1 s of the kill
  late: int                  ## requests not answered within 1 s
  values: seq[string]        ## what the gets read (before any other put)
  otherPids: HashSet[int]

proc readHookPid(fifo: string; timeoutMs: int): int =
  ## Waits (poll(2), bounded) for the hook to write its pid to the FIFO.
  let fd = posix.open(cstring(fifo), O_RDONLY or O_NONBLOCK)
  doAssert fd >= 0, "cannot open the FIFO"
  defer: discard posix.close(fd)
  var line = ""
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while not line.endsWith("\n"):
    let left = int((deadline - getMonoTime()).inMilliseconds)
    if left <= 0:
      raise newException(OSError, "the store hook never reported (FIFO)")
    var pfd = TPollfd(fd: fd, events: POLLIN)
    if posix.poll(addr pfd, 1, cint(left)) > 0:
      var buf: array[64, char]
      let got = posix.read(fd, addr buf[0], buf.len)
      if got > 0:
        for i in 0 ..< got: line.add buf[i]
  parseInt(line.strip)

proc killInsideTheLock(n: Nginx): Death =
  var d: Death
  let before = oneShot(n.port, "POST", "/shm/put?zone=lockz&key=victim", "old-value")
  doAssert before.json["result"].getStr == "stored", before.body
  let fifo = n.prefix / "hook.fifo"
  doAssert mkfifo(cstring(fifo), 0o600) == 0, "mkfifo failed"
  # The request whose store the hook stops inside the lock.
  let dying = startProcess("curl", args = @["-sS", "--max-time", "60",
    "-X", "POST", "--data-binary", "new-value",
    n.url("/shm/die?zone=lockz&key=victim&fifo=" & fifo)],
    options = {poUsePath, poStdErrToStdOut})
  d.victimPid = readHookPid(fifo, 15_000)
  d.victimWasOurs = d.victimPid in n.workerPids
  d.hookLogged = n.errorLogText.contains(
    "shm test hook: inside the lock of zone \"lockz\" (pid " & $d.victimPid & ")")

  # Gets sent while the lock is held: they wait (in the other workers or
  # in the listen queue) until it is released.  Each is written to its own
  # connection now and read after the kill.
  var waiting: seq[Conn]
  for i in 0 ..< 6:
    var c = connect(n.port)
    c.sendRequest("GET", "/shm/get?zone=lockz&key=victim")
    waiting.add c

  let killedAt = getMonoTime()
  doAssert d.victimWasOurs, "the hook's pid is not one of our workers"
  doAssert posix.kill(Pid(d.victimPid), SIGKILL) == 0, "kill failed"

  proc settle(conns: var seq[Conn]): seq[Reply] =
    ## Reads every answer, counting those that come within 1 s of the kill.
    for c in conns.mitems:
      let left = 1000 - int((getMonoTime() - killedAt).inMilliseconds)
      try:
        if left <= 0:
          raise newException(TimeoutError, "late")
        result.add c.readReply(left)
        inc d.answeredInTime
      except TimeoutError:
        inc d.late
      c.close()
  for r in settle(waiting):
    d.values.add r.json["value"].getStr
    d.otherPids.incl r.pidOf
  var after: seq[Conn]
  for i in 0 ..< 6:
    var p = connect(n.port)
    p.sendRequest("POST", "/shm/put?zone=lockz&key=victim", "other-" & $i)
    after.add p
    var g = connect(n.port)
    g.sendRequest("GET", "/shm/get?zone=lockz&key=victim")
    after.add g
  for r in settle(after):
    d.otherPids.incl r.pidOf
  # The master's release, from its error log (bounded).
  let line = "shared memory zone \"lockz\" was locked by " & $d.victimPid
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while not n.errorLogText.contains(line) and getMonoTime() < deadline:
    sleep(10)
  d.masterReleased = n.errorLogText.contains(line)
  discard dying.waitForExit(5_000)
  dying.close()
  d

const lockConf = "  isonim_shm_zone lockz size=1m;\n"

suite "test_shm_lock_survives_a_worker_dying_inside_it":
  test "the master releases the lock of a worker killed inside it":
    let module = testModule()
    let n = startShm(module, lockConf, reuseport = false)
    defer: n.stop()
    let d = killInsideTheLock(n)
    echo "    death: ", d
    # Vacuity guard: the hook fired inside the lock, and nginx's master
    # logged the zone as locked by the dead worker's pid.
    check d.hookLogged
    check d.victimWasOurs
    check d.masterReleased
    # Negative control: every other request answered within 1 s of the
    # kill, and the key held the old or the new value, whole.
    check d.answeredInTime == 18
    check d.late == 0
    check d.values.len == 6
    for v in d.values:
      check v in ["old-value", "new-value"]
    check d.victimPid notin d.otherPids

  test "mutant: a lock of the module's own instead of the slab pool's mutex":
    let module = mutant("own-lock", "src/ngx_http_isonim_module.c",
      "    return &sp->mutex;",
      """    /* MUTANT: a lock of the module's own, which the master knows
     * nothing about: a spinlock on a word of the pool nothing else uses. */
    static ngx_shmtx_t  own;
    own.lock = (ngx_atomic_t *) &sp->lock.wait;
    own.spin = 2048;
#if (NGX_HAVE_POSIX_SEM)
    own.semaphore = 0;
#endif
    return &own;""")
    let n = startShm(module, lockConf, reuseport = false)
    defer: n.stop()
    let d = killInsideTheLock(n)
    echo "    death (mutant): ", d
    check d.hookLogged
    # The falsified property: the lock stays held after the kill, and the
    # next store does not answer within 1 s.
    check d.late > 0
