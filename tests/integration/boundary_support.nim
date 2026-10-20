## boundary_support.nim
##
## The fixtures the Boundary channel integration tests share
## (t_boundary_channel.nim, t_boundary_reload.nim), included by each (an
## `include`, so the tests keep using them as their own): the workload
## certificates, the node (a real nginx with the module, its app listener
## and its Boundary listener), the test app's calls, and the test peer's
## fleet of channels.  The mocking policy that covers them is stated in
## each test's header: the peer (h2_peer.nim) stands in for the Interior
## write executor, and the certificates are the test's own, made with the
## `openssl` CLI in the format of isonim-platform-control-plane.md §8.4.

const
  workers = 8
  appLocations = "    location /b/ { isonim_rpc on; isonim_rpc_app boundary_test; " &
    "isonim_rpc_timeout 60s; }\n"

# ---------------------------------------------------------------------------
# Workload certificates (isonim-platform-control-plane.md §8.4)
# ---------------------------------------------------------------------------

type
  Cert = object
    pem, key: string

  Pki = object
    dir: string
    ca: Cert                ## the forum app's workload CA
    node: Cert              ## the serving node's own (server) certificate
    writer: Cert            ## a write executor's (class writer)
    serving: Cert           ## another serving node's (class serving)
    otherCa: Cert           ## another app's workload CA
    otherWriter: Cert       ## a writer of that other app

proc sh(cmd: string) =
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(OSError, "failed (" & $code & "): " & cmd & "\n" & output)

proc makeCa(dir, name: string): Cert =
  result = Cert(pem: dir / name & ".pem", key: dir / name & ".key")
  sh("openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes" &
     " -keyout " & quoteShell(result.key) & " -out " & quoteShell(result.pem) &
     " -subj /CN=" & name & " -days 2" &
     " -addext basicConstraints=critical,CA:TRUE" &
     " -addext keyUsage=critical,keyCertSign,cRLSign 2>&1")

proc issue(dir, name: string; ca: Cert; app, class, node: string;
           notAfter = ""): Cert =
  ## A workload certificate: the URI SAN of §8.4, ExtendedKeyUsage client
  ## and server; valid for a day, or until `notAfter` (YYYYMMDDHHMMSSZ).
  result = Cert(pem: dir / name & ".pem", key: dir / name & ".key")
  let csr = dir / name & ".csr"
  let ext = dir / name & ".ext"
  writeFile(ext, "basicConstraints=CA:FALSE\n" &
    "keyUsage=critical,digitalSignature\n" &
    "extendedKeyUsage=serverAuth,clientAuth\n" &
    "subjectAltName=URI:spiffe://isonim-platform/app/" & app & "/class/" &
    class & "/node/" & node & ",DNS:localhost,IP:127.0.0.1\n")
  sh("openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes" &
     " -keyout " & quoteShell(result.key) & " -out " & quoteShell(csr) &
     " -subj /CN=" & node & " 2>&1")
  sh("openssl x509 -req -in " & quoteShell(csr) & " -CA " & quoteShell(ca.pem) &
     " -CAkey " & quoteShell(ca.key) & " -set_serial 0x" &
     toHex(int64(getMonoTime().ticks) and 0x7fffffffffff) &
     " -out " & quoteShell(result.pem) & " -extfile " & quoteShell(ext) &
     (if notAfter.len > 0: " -not_after " & notAfter else: " -days 1") & " 2>&1")

proc makePki(): Pki =
  result.dir = getTempDir() / ("ngx-isonim-pki-" & $getCurrentProcessId())
  removeDir(result.dir)
  createDir(result.dir)
  let d = result.dir
  result.ca = makeCa(d, "forum-ca")
  result.node = issue(d, "node", result.ca, "forum", "serving", "edge-node-1")
  result.writer = issue(d, "writer", result.ca, "forum", "writer", "writer-1")
  result.serving = issue(d, "serving", result.ca, "forum", "serving", "edge-node-2")
  result.otherCa = makeCa(d, "chat-ca")
  result.otherWriter = issue(d, "other-writer", result.otherCa, "chat",
                             "writer", "chat-writer-1")

let pki = makePki()

# ---------------------------------------------------------------------------
# The node: nginx with the app listener and the Boundary listener
# ---------------------------------------------------------------------------

type Node = object
  nginx: Nginx
  bport: int

proc boundaryServer(bport: int; extra = ""; http2 = true;
                    writerCa = pki.ca.pem; nodeCert = pki.node): string =
  ## The Boundary listener's server block; `nodeCert` is the node's own
  ## workload certificate (the files nginx reads at start and at a reload).
  "  server {\n" &
  "    listen 127.0.0.1:" & $bport & " ssl reuseport;\n" &
  (if http2: "    http2 on;\n" else: "") &
  "    ssl_certificate " & nodeCert.pem & ";\n" &
  "    ssl_certificate_key " & nodeCert.key & ";\n" &
  "    ssl_client_certificate " & writerCa & ";\n" &
  "    ssl_verify_client on;\n" &
  "    ssl_verify_depth 2;\n" &
  "    ssl_protocols TLSv1.3;\n" &
  "    isonim_boundary on;\n" &
  "    isonim_boundary_peer_class writer;\n" &
  extra &
  "  }\n"

proc startNode(module: string; extra = ""; http2 = true;
               nodeCert = pki.node): Node =
  result.bport = freePort()
  result.nginx = startNginx(module, appLocations, workerProcesses = workers,
    httpConf = "  keepalive_requests 1000000;\n" &
      boundaryServer(result.bport, extra, http2, nodeCert = nodeCert),
    listenOptions = "reuseport")

proc stop(n: Node) = n.nginx.stop()

proc mutant(name, file, original, replacement: string): string =
  buildMutant(name, file, original, replacement)

# ---------------------------------------------------------------------------
# The app, over plain HTTP: one fresh connection per request
# ---------------------------------------------------------------------------

proc appCall(port: int; path: string): Future[JsonNode] {.async.} =
  let c = newAsyncHttpClient()
  try:
    let r = await c.request("http://127.0.0.1:" & $port & path, HttpPost, "")
    let body = await r.body
    if r.code.int != 200:
      raise newException(IOError, "the app answered " & $r.code & ": " & body)
    result = parseJson(body)
  finally:
    c.close()

proc statusAll(n: Node): Future[Table[int, JsonNode]] {.async.} =
  ## Every worker's `status`, by slot (fresh connections until each of the
  ## eight slots has answered).
  var tries = 0
  while result.len < workers:
    inc tries
    if tries > 4000:
      raise newException(IOError, "only slots " & $toSeq(result.keys) &
        " answered")
    let j = await appCall(n.nginx.port, "/b/status")
    result[j["slot"].getInt] = j

proc callEveryWorker(n: Node; calls: int; prefix: string;
                     timeoutMs = 10_000): Future[Table[int, JsonNode]] {.async.} =
  ## `call` answers by worker pid, in waves of eight concurrent requests,
  ## until every worker has answered.
  var wave = 0
  while result.len < workers:
    inc wave
    if wave > 300:
      raise newException(IOError, "only workers " & $toSeq(result.keys) &
        " answered")
    var futs: seq[Future[JsonNode]]
    for k in 0 ..< workers:
      futs.add appCall(n.nginx.port, "/b/call?n=" & $calls & "&batch=" &
        prefix & "-" & $wave & "-" & $k & "&timeout_ms=" & $timeoutMs)
    for f in futs:
      let j = await f
      let pid = j["pid"].getInt
      if pid notin result:
        result[pid] = j

# ---------------------------------------------------------------------------
# The peer's fleet of channels, and its executor-like behaviour
# ---------------------------------------------------------------------------

type
  Chan = ref object
    conn: PeerConn
    slot: int
    hs: JsonNode
    ended: bool
    serving: Future[void]

  Fleet = ref object
    ctx: SslContext
    port: int
    authority: string
    peerId: string
    chans: seq[Chan]
    reported: Table[int, int]
      ## slot -> channels_in_slot of its latest handshake, less the
      ## channels of that slot lost since
    workers: int
    minChannels: int
    opened: int
    received: seq[JsonNode]               ## every frame after the handshakes
    receivedPids: HashSet[int]
    batches: Table[string, seq[(Chan, JsonNode)]]
    arrival: Table[string, seq[int]]
    replied: Table[string, seq[int]]
    holdReplies: bool

proc newFleet(n: Node; cert = pki.writer): Fleet =
  Fleet(ctx: newPeerContext(cert.pem, cert.key, pki.ca.pem), port: n.bport,
        authority: "127.0.0.1:" & $n.bport, peerId: "writer-1")

proc replyBatch(f: Fleet; b: string) {.async.} =
  ## Answers a batch in reverse order of arrival, each reply on the
  ## channel its call came in on.
  let items = f.batches[b]
  for k in countdown(items.high, 0):
    let (ch, j) = items[k]
    f.replied.mgetOrPut(b, @[]).add j["i"].getInt
    if not ch.ended:
      await ch.conn.sendBoundaryFrame($(%*{"msg_id": j["msg_id"], "i": j["i"],
        "pid_seen": j["pid"], "slot_seen": j["slot"], "via_slot": ch.slot}))

proc releaseReplies(f: Fleet) {.async.} =
  f.holdReplies = false
  for b, items in f.batches:
    if b notin f.replied and items.len == items[0][1]["n"].getInt:
      await f.replyBatch(b)

proc serve(f: Fleet; ch: Chan) {.async.} =
  try:
    while true:
      let j = parseJson(await ch.conn.nextFrame(timeoutMs = 600_000))
      f.received.add j
      if j.hasKey("pid"):
        f.receivedPids.incl j["pid"].getInt
      if j.hasKey("batch"):
        let b = j["batch"].getStr
        f.batches.mgetOrPut(b, @[]).add((ch, j))
        f.arrival.mgetOrPut(b, @[]).add j["i"].getInt
        if f.batches[b].len == j["n"].getInt and not f.holdReplies:
          await f.replyBatch(b)
  except CatchableError:
    discard
  ch.ended = true
  f.reported[ch.slot] = f.reported.getOrDefault(ch.slot) - 1

proc openOne(f: Fleet): Future[Chan] {.async.} =
  ## One more connection and channel; raises when the node refuses it.
  let conn = await connectPeer(f.ctx, "127.0.0.1", f.port)
  let st = await conn.openStream(f.authority)
  if st != 200:
    conn.close()
    raise newException(PeerError, "the node answered " & $st &
      " to the channel request")
  let hs = parseJson(await conn.nextFrame())
  doAssert hs["protocol"].getInt == 1, $hs
  let ch = Chan(conn: conn, slot: hs["worker_slot"].getInt, hs: hs)
  f.workers = hs["workers"].getInt
  f.minChannels = hs["min_channels"].getInt
  f.reported[ch.slot] = hs["channels_in_slot"].getInt
  await conn.sendBoundaryFrame($(%*{"peer_id": f.peerId, "cells": ["cell-1"]}))
  f.chans.add ch
  inc f.opened
  ch.serving = f.serve(ch)
  result = ch

proc covered(f: Fleet): bool =
  if f.workers == 0:
    return false
  for s in 0 ..< f.workers:
    if f.reported.getOrDefault(s) < f.minChannels:
      return false
  true

proc cover(f: Fleet; maxConnections = 800) {.async.} =
  ## Opens connections until the handshakes report `min_channels` in every
  ## worker slot (the peer's whole rule: it knows nothing else).
  while not f.covered:
    if f.opened >= maxConnections:
      raise newException(PeerError, "not covered after " & $f.opened &
        " connections: " & $f.reported)
    discard await f.openOne()

proc openPerSlot(f: Fleet): Table[int, int] =
  for ch in f.chans:
    if not ch.ended:
      result[ch.slot] = result.getOrDefault(ch.slot) + 1

proc waitLive(n: Node; f: Fleet): Future[Table[int, JsonNode]] {.async.} =
  ## Every worker's status once each of its channels has received the
  ## peer's handshake (the peer sends it right after the node's).
  let deadline = getMonoTime() + initDuration(seconds = 20)
  while true:
    result = await statusAll(n)
    var ok = true
    for s, st in result:
      if st["live"].getInt != st["channels"].getInt or
          st["channels"].getInt != f.openPerSlot.getOrDefault(s):
        ok = false
    if ok or getMonoTime() > deadline:
      return

proc closeAll(f: Fleet) {.async.} =
  for ch in f.chans:
    ch.conn.close()
  for ch in f.chans:
    if ch.serving != nil:
      await ch.serving
