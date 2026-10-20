## t_boundary_channel.nim
##
## Interior-opened Boundary channels (src/boundary.nim and the
## `isonim_boundary*` directives of src/ngx_http_isonim_module.c) against a
## real nginx with eight worker processes and the real module
## (tests/e2e/harness.nim), spec/isonim-nginx.md, "Interior-Opened Boundary
## Channels" (milestone IFP-M23).
##
## The node under test has two listeners: the Boundary listener (TLS 1.3,
## HTTP/2, `ssl_verify_client on` against a per-app workload CA,
## `reuseport`, `isonim_boundary on`, `isonim_boundary_peer_class writer`),
## where the test peer opens channels; and a plain HTTP listener
## (`reuseport`) serving the test app `boundary_test`
## (tests/e2e/apps/boundary_app.nim), through which the test makes the
## worker's application call `boundaryCall` / `boundarySend` and read its
## channel pool.  Fresh connections spread over the workers (each has its
## own reuseport socket); a test opens them until it has seen every worker.
##
## * test_boundary_channel_round_trip: a `writer` peer covers every worker
##   with channels; calls from every worker get the peer's reply with the
##   same msg_id, the peer answering each batch of concurrent calls in
##   reverse order of arrival.  Negative control: an nginx built without
##   HTTP/2 makes the peer fail explicitly (and the module answers an
##   HTTP/1.1 channel request 505).  Mutant: replies matched to calls by
##   arrival order.
## * test_boundary_refuses_wrong_peer_class: a `serving` peer, a peer of
##   another app's CA and one without a client certificate get no channel
##   and no frame; the `writer` peer opens one in the same run.  Mutant: the
##   CA checked but not the class.
## * test_boundary_every_worker_covered: with `isonim_boundary_min_channels
##   2` the peer opens connections until the handshakes report two channels
##   in every slot, which the workers' own pools confirm; killing one
##   worker makes the peer reopen until it is covered again.  Mutant: the
##   handshake reports the node's total instead of the slot's count.
## * test_boundary_no_channel_fails_fast: with no peer, `boundaryCall` fails
##   with bcNoChannel before it returns, no file appears under the nginx
##   prefix (its temp paths included), and a peer that connects later
##   receives only what was sent after it connected.  Mutant: frames queued
##   for a future channel.
## * Also: the channel closes when the peer's certificate expires; a reload
##   keeps an old worker's channel until its call in flight is answered
##   (mutant: no hold, and the old worker exits with the call in flight); a
##   frame over `isonim_boundary_max_frame` closes the channel; and
##   `nginx -t` validates the directives.
##
## MOCKING POLICY.  The test peer (tests/integration/h2_peer.nim, a minimal
## HTTP/2 client) stands in for IsoNim Forum's write executor, the real
## Interior peer, which is built later (INF-M5) and depends on this module:
## the channel's contract is the module's, and the peer implements exactly
## its side of that contract (TLS with a workload certificate, one HTTP/2
## stream, the framing and the handshakes), so a double is the only way to
## test the node before its peer exists.  Everything else is real: nginx,
## its workers, its TLS and HTTP/2 stacks, the module.  The workload
## certificates are the test's own, made with the `openssl` CLI in the
## format of isonim-platform-control-plane.md §8.4 (URI SAN
## `spiffe://isonim-platform/app/{app}/class/{class}/node/{node}`): the
## platform's issuance (IFP-M22) is a separate milestone, and this module
## consumes certificates, it does not issue them.
##
## The certificates, the node, the app's calls and the peer's fleet of
## channels are in boundary_support.nim, which this test includes (and so
## does t_boundary_reload.nim).
##
## Synchronization, never sleeps: every wait is for a condition (a frame, a
## stream's end, a worker's pid, a status the app reports), polled on the
## event loop with a deadline.
##
## Run: nim c -r tests/integration/t_boundary_channel.nim  (in the dev
## shell; `just test-boundary`).  The negative control needs an nginx built
## without HTTP/2: `NGX_ISONIM_NGINX_NO_HTTP2` names its binary, otherwise
## the test builds the flake's `nginx-no-http2` with `nix build`.

import std/[unittest, asyncdispatch, httpclient, json, os, osproc, strutils,
            tables, sets, sequtils, algorithm, times, monotimes, net, posix]
import ../e2e/harness
import h2_peer

include boundary_support

# ---------------------------------------------------------------------------
# test_boundary_channel_round_trip
# ---------------------------------------------------------------------------

type RoundTrip = object
  workerPids: seq[int]
  answers: Table[int, JsonNode]    ## by worker pid
  receivedPids: HashSet[int]
  arrival, replied: Table[string, seq[int]]
  alpns: HashSet[string]

proc roundTrip(module: string): RoundTrip =
  let n = startNode(module)
  defer: n.stop()
  let f = newFleet(n)
  waitFor f.cover()
  discard waitFor waitLive(n, f)
  result.answers = waitFor callEveryWorker(n, 4, "rt")
  result.workerPids = n.nginx.workerPids
  result.receivedPids = f.receivedPids
  result.arrival = f.arrival
  result.replied = f.replied
  for ch in f.chans:
    result.alpns.incl ch.conn.alpn
  waitFor f.closeAll()

proc roundTripFailures(r: RoundTrip): seq[string] =
  ## What the round trip's assertions found wrong (empty: none).
  if r.alpns != toHashSet(["h2"]):
    result.add "channels negotiated " & $r.alpns
  # Vacuity guard: every worker made calls (its pid in the frames the
  # peer received, and in an answer).
  if r.workerPids.len != workers:
    result.add "nginx runs " & $r.workerPids.len & " workers"
  if toHashSet(toSeq(r.answers.keys)) != toHashSet(r.workerPids):
    result.add "answers came from " & $toSeq(r.answers.keys) &
      ", the workers are " & $r.workerPids
  for p in r.workerPids:
    if p notin r.receivedPids:
      result.add "the peer received no frame from worker " & $p
  var slots: HashSet[int]
  for pid, a in r.answers:
    slots.incl a["slot"].getInt
    for res in a["results"]:
      let i = res["i"].getInt
      if not res["ok"].getBool:
        result.add "worker " & $pid & " call " & $i & " failed: " & $res
        continue
      let reply = res["reply"]
      if reply["i"].getInt != i or not reply["msg_id"].getStr.endsWith("-" & $i):
        result.add "worker " & $pid & " call " & $i & " got the wrong reply: " &
          $reply
      if reply["pid_seen"].getInt != pid:
        result.add "worker " & $pid & " call " & $i & " got another worker's " &
          "reply: " & $reply
  if slots.len != workers:
    result.add "answers came from slots " & $slots
  # The peer really answered out of order.
  var reordered = 0
  for b, arr in r.arrival:
    if arr.len >= 2 and b in r.replied:
      if r.replied[b] != reversed(arr):
        result.add "batch " & b & " was not answered in reverse"
      elif r.replied[b] != arr:
        inc reordered
  if reordered < workers:
    result.add "only " & $reordered & " batches were answered out of order"

proc noHttp2Nginx(): string =
  ## An nginx built without HTTP/2 (the flake's nginx-no-http2).
  result = getEnv("NGX_ISONIM_NGINX_NO_HTTP2")
  if result.len == 0:
    let (output, code) = execCmdEx("nix build --no-link --print-out-paths " &
      quoteShell(repoRoot & "#nginx-no-http2"))
    if code != 0:
      raise newException(OSError, "building nginx-no-http2 failed:\n" & output)
    result = output.strip.splitLines[^1] / "bin/nginx"

suite "test_boundary_channel_round_trip":
  test "every worker's calls get the peer's replies, matched by msg_id":
    let r = roundTrip(testModule())
    let failures = roundTripFailures(r)
    if failures.len > 0:
      echo "    ", failures.join("\n    ")
    check failures.len == 0
    echo "    workers answered: ", r.answers.len, ", batches answered out of ",
      "order: ", toSeq(r.replied.keys).len

  test "negative control: nginx without HTTP/2 fails the peer explicitly":
    let bin = noHttp2Nginx()
    let (vout, _) = execCmdEx(quoteShell(bin) & " -V 2>&1")
    check not vout.contains("--with-http_v2_module")
    let oldPath = getEnv("PATH")
    putEnv("PATH", bin.parentDir & ":" & oldPath)
    var n: Node
    try:
      n = startNode(testModule(), http2 = false)
    finally:
      putEnv("PATH", oldPath)
    defer: n.stop()
    let f = newFleet(n)
    var failure = ""
    try:
      waitFor f.cover()
    except PeerError as e:
      failure = e.msg
    echo "    peer: ", failure
    check failure.contains("HTTP/2 was not negotiated")
    check failure.contains("\"http/1.1\"")
    check f.opened == 0
    # The module itself refuses a channel over HTTP/1.1.
    let c = curl(["-s", "-o", "/dev/null", "-w", "%{http_code}", "--http1.1",
      "--cacert", pki.ca.pem, "--cert", pki.writer.pem, "--key", pki.writer.key,
      "-X", "POST", "--data-binary", "", "https://127.0.0.1:" & $n.bport &
      "/_boundary/v1/channel"])
    check c.output == "505"
    check n.nginx.errorLogText.contains("a channel needs HTTP/2, the peer " &
      "sent HTTP/1.1")

  test "mutant: replies matched to calls by arrival order":
    let module = mutant("arrival-order", "src/boundary.nim",
      "  let call = calls.getOrDefault(key)",
      """  # MUTANT: the oldest call in flight takes the reply.
  var call: PendingCall
  for c in calls.values:
    call = c
    break""")
    let failures = roundTripFailures(roundTrip(module))
    echo "    mutant: ", failures.len, " failures, e.g. ",
      (if failures.len > 0: failures[0] else: "")
    check failures.anyIt("got the wrong reply" in it)

# ---------------------------------------------------------------------------
# test_boundary_refuses_wrong_peer_class
# ---------------------------------------------------------------------------

type Attempt = object
  name: string
  status: int
  frames: int
  ended: bool
  error: string

proc attempt(n: Node; name: string; cert: Cert): Attempt =
  ## One channel request with `cert` (none when empty): its status, and
  ## the Boundary frames it received before its stream ended.
  result.name = name
  let ctx = newPeerContext(cert.pem, cert.key, pki.ca.pem)
  try:
    let conn = waitFor connectPeer(ctx, "127.0.0.1", n.bport)
    result.status = waitFor conn.openStream("127.0.0.1:" & $n.bport)
    result.ended = waitFor conn.waitEnded(5_000)
    result.frames = conn.frames.len
    conn.close()
  except CatchableError as e:
    result.error = e.msg

proc refusals(module: string): seq[Attempt] =
  let n = startNode(module)
  defer: n.stop()
  result.add attempt(n, "serving", pki.serving)
  result.add attempt(n, "other app", pki.otherWriter)
  result.add attempt(n, "no certificate", Cert())
  result.add attempt(n, "writer", pki.writer)

suite "test_boundary_refuses_wrong_peer_class":
  test "serving, another app's CA and no certificate get no channel":
    let a = refusals(testModule())
    for x in a:
      echo "    ", x.name, ": status ", x.status, ", frames ", x.frames,
        (if x.error.len > 0: ", " & x.error else: "")
    # The serving peer is refused by the module, the others by nginx's
    # verification (400: certificate error / no certificate): none receives
    # a frame, and each stream ends.
    check a[0].status == 403 and a[0].frames == 0 and a[0].ended
    check a[1].status == 400 and a[1].frames == 0 and a[1].ended
    check a[2].status == 400 and a[2].frames == 0 and a[2].ended
    # Vacuity guard: the writer opens a channel in the same run (its
    # handshake is a frame, and the stream stays open).
    check a[3].status == 200 and a[3].frames == 1 and not a[3].ended

  test "mutant: the CA checked but not the class":
    let module = mutant("ca-only", "src/ngx_http_isonim_module.c",
      """    if (cls.len != iscf->peer_class.len
        || ngx_strncmp(cls.data, iscf->peer_class.data, cls.len) != 0)
    {""",
      """    if (0) {   /* MUTANT: any class of the app's CA */""")
    let a = refusals(module)
    echo "    mutant: serving peer status ", a[0].status, ", frames ", a[0].frames
    check a[0].status == 200 and a[0].frames >= 1

# ---------------------------------------------------------------------------
# test_boundary_every_worker_covered
# ---------------------------------------------------------------------------

type Coverage = object
  failures: seq[string]
  connections: int
  reconnections: int
  killedSlot: int

proc agreement(f: Fleet; statuses: Table[int, JsonNode]; label: string): seq[string] =
  ## Per slot, the handshakes' count, the peer's own channels, the worker's
  ## pool (and the C side's count, and the node's shared count) must agree,
  ## and reach min_channels.
  let own = f.openPerSlot
  for s in 0 ..< workers:
    if s notin statuses:
      result.add label & ": slot " & $s & " never answered"
      continue
    let st = statuses[s]
    let pool = st["channels"].getInt
    if pool < f.minChannels:
      result.add label & ": slot " & $s & " holds " & $pool & " channel(s)"
    if f.reported.getOrDefault(s) != pool:
      result.add label & ": slot " & $s & " handshakes report " &
        $f.reported.getOrDefault(s) & ", its pool holds " & $pool
    if own.getOrDefault(s) != pool:
      result.add label & ": slot " & $s & " the peer holds " &
        $own.getOrDefault(s) & ", the pool " & $pool
    if st["attached"].getInt != pool:
      result.add label & ": slot " & $s & " C side counts " &
        $st["attached"].getInt
    if st["node"].len != workers or st["node"][s].getInt != pool:
      result.add label & ": slot " & $s & " node counts " & $st["node"]

proc coverage(module: string): Coverage =
  let n = startNode(module, extra = "    isonim_boundary_min_channels 2;\n")
  defer: n.stop()
  let f = newFleet(n)
  waitFor f.cover()
  result.connections = f.opened
  var statuses = waitFor waitLive(n, f)
  result.failures.add agreement(f, statuses, "covered")
  if f.minChannels != 2:
    result.failures.add "min_channels reported " & $f.minChannels
  # Kill one worker (a child of our own master): its channels die with it.
  result.killedSlot = 3
  let victim = statuses[3]["pid"].getInt
  doAssert victim in n.nginx.workerPids
  discard posix.kill(Pid(victim), SIGKILL)
  for ch in f.chans:
    if ch.slot == 3:
      doAssert waitFor ch.conn.waitEnded(10_000)
      waitFor ch.serving

  if f.reported.getOrDefault(3) >= 2:
    result.failures.add "slot 3 still reported covered after its worker died"
  let before = f.opened
  waitFor f.cover()
  result.reconnections = f.opened - before
  statuses = waitFor waitLive(n, f)
  result.failures.add agreement(f, statuses, "re-covered")
  if statuses[3]["pid"].getInt == victim:
    result.failures.add "slot 3 is still served by the killed worker"
  waitFor f.closeAll()

suite "test_boundary_every_worker_covered":
  test "the peer covers every slot, and covers a lost one again":
    let c = coverage(testModule())
    if c.failures.len > 0:
      echo "    ", c.failures.join("\n    ")
    check c.failures.len == 0
    echo "    connections to cover: ", c.connections, ", to re-cover slot ",
      c.killedSlot, ": ", c.reconnections
    check c.reconnections >= 2

  test "mutant: the handshake reports the node's total":
    let module = mutant("node-total", "src/ngx_http_isonim_module.c",
      """static ngx_uint_t
ngx_http_isonim_boundary_channels_in_slot(void)
{
    return ngx_http_isonim_boundary_nchannels;
}""",
      """static ngx_uint_t
ngx_http_isonim_boundary_channels_in_slot(void)
{
    /* MUTANT: the node's total over every slot. */
    ngx_atomic_t  *slots = ngx_http_isonim_boundary_slots();
    ngx_uint_t     i, total = 0;

    for (i = 0; i < ngx_http_isonim_boundary_workers(); i++) {
        total += slots[i];
    }
    return total;
}""")
    let c = coverage(module)
    echo "    mutant: ", c.failures.len, " failures, e.g. ",
      (if c.failures.len > 0: c.failures[0] else: "")
    check c.failures.anyIt("channel(s)" in it)

# ---------------------------------------------------------------------------
# test_boundary_no_channel_fails_fast
# ---------------------------------------------------------------------------

proc filesUnder(dir: string): HashSet[string] =
  for path in walkDirRec(dir, yieldFilter = {pcFile, pcLinkToFile, pcDir,
                                             pcLinkToDir}):
    result.incl path

type NoChannel = object
  early: Table[int, JsonNode]
  late: Table[int, JsonNode]
  earlySends, lateSends: seq[JsonNode]
  newFiles: seq[string]
  frames: seq[JsonNode]
  workerPids: seq[int]

proc noChannel(module: string): NoChannel =
  let n = startNode(module)
  defer: n.stop()
  let before = filesUnder(n.nginx.prefix)
  result.early = waitFor callEveryWorker(n, 1, "early")
  for i in 0 ..< 16:
    result.earlySends.add waitFor appCall(n.nginx.port, "/b/send?tag=early")
  for p in filesUnder(n.nginx.prefix) - before:
    result.newFiles.add p
  let f = newFleet(n)
  waitFor f.cover()
  discard waitFor waitLive(n, f)
  result.late = waitFor callEveryWorker(n, 1, "late")
  for i in 0 ..< 16:
    result.lateSends.add waitFor appCall(n.nginx.port, "/b/send?tag=late")
  # The sends expect no reply: wait until the peer has all sixteen.
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while f.received.countIt(it{"kind"}.getStr == "send") < 16 and
      getMonoTime() < deadline:
    discard waitFor f.chans[0].conn.waitChangeFor(50)
  result.frames = f.received
  result.workerPids = n.nginx.workerPids
  waitFor f.closeAll()

proc noChannelFailures(r: NoChannel): seq[string] =
  if toHashSet(toSeq(r.early.keys)) != toHashSet(r.workerPids):
    result.add "early answers from " & $toSeq(r.early.keys)
  for pid, a in r.early:
    let res = a["results"][0]
    if res["ok"].getBool or res["error"].getStr != "bcNoChannel":
      result.add "worker " & $pid & " without a channel: " & $res
    if not res["immediate"].getBool:
      result.add "worker " & $pid & ": bcNoChannel was not immediate"
  for a in r.earlySends:
    if a["ok"].getBool or a["error"].getStr != "bcNoChannel":
      result.add "boundarySend without a channel: " & $a
  if r.newFiles.len > 0:
    result.add "new files under the prefix: " & $r.newFiles
  # Vacuity guard: the same call succeeds once a peer is connected ...
  if toHashSet(toSeq(r.late.keys)) != toHashSet(r.workerPids):
    result.add "late answers from " & $toSeq(r.late.keys)
  for pid, a in r.late:
    let res = a["results"][0]
    if not res["ok"].getBool:
      result.add "worker " & $pid & " with channels: " & $res
  for a in r.lateSends:
    if not a["ok"].getBool:
      result.add "boundarySend with channels: " & $a
  # ... and the peer saw exactly the frames sent after it connected.
  var sends = 0
  for fr in r.frames:
    if fr{"kind"}.getStr == "send":
      inc sends
      if fr["tag"].getStr != "late":
        result.add "the late peer received " & $fr
    elif not fr["batch"].getStr.startsWith("late-"):
      result.add "the late peer received " & $fr
  if sends != r.lateSends.len:
    result.add "the peer received " & $sends & " of " & $r.lateSends.len &
      " sends"
  if r.frames.len < r.late.len:
    result.add "the peer received " & $r.frames.len & " frames for " &
      $r.late.len & " answered calls"

suite "test_boundary_no_channel_fails_fast":
  test "no channel: bcNoChannel at once, nothing stored, nothing sent later":
    let r = noChannel(testModule())
    let failures = noChannelFailures(r)
    if failures.len > 0:
      echo "    ", failures.join("\n    ")
    check failures.len == 0
    echo "    frames the late peer received: ", r.frames.len

  test "mutant: frames queued for a future channel":
    let module = buildMutantEdits("queue-early", "src/boundary.nim", [
      ("""  let ch = nextLiveChannel()
  if ch.isNil:
    fut.fail(boundaryError(bcNoChannel, "this worker has no live Boundary " &
      "channel"))
    return""",
       """  let ch = nextLiveChannel()
  if ch.isNil:
    earlyFrames.add @frame   # MUTANT: kept for the first channel
    fut.fail(boundaryError(bcNoChannel, "this worker has no live Boundary " &
      "channel"))
    return"""),
      ("""  ch.peerId = j["peer_id"].getStr
  ch.cells = cells
  ch.live = true""",
       """  ch.peerId = j["peer_id"].getStr
  ch.cells = cells
  ch.live = true
  for early in earlyFrames:     # MUTANT: the queued frames go out now
    discard ch.sendFrame(early)
  earlyFrames.setLen(0)"""),
      ("""const protocolVersion* = 1
""", """const protocolVersion* = 1

var earlyFrames: seq[seq[byte]]   # MUTANT
""")])
    let failures = noChannelFailures(noChannel(module))
    echo "    mutant: ", failures.len, " failures, e.g. ",
      (if failures.len > 0: failures[0] else: "")
    check failures.anyIt("the late peer received" in it)

# ---------------------------------------------------------------------------
# Lifetime: certificate expiry, reload, frame size; nginx -t
# ---------------------------------------------------------------------------

type ReloadRun = object
  failures: seq[string]

proc reloadWithCallInFlight(module: string): ReloadRun =
  ## A call in flight on an old worker, detached from any HTTP request (so
  ## nothing but the module's hold keeps that worker), across a reload:
  ## the old worker must stay, with its channel, until the call is
  ## answered; then it exits, and the peer covers the new workers.
  var n = startNode(module)
  defer: n.stop()
  let f = newFleet(n)
  waitFor f.cover()
  discard waitFor waitLive(n, f)
  let old = n.nginx.workerPids
  f.holdReplies = true
  let started = waitFor appCall(n.nginx.port,
    "/b/detached?batch=held&timeout_ms=30000")
  let holder = started["pid"].getInt
  # The peer holds the call's frame (the call is in flight).
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while f.batches.getOrDefault("held").len < 1 and getMonoTime() < deadline:
    discard waitFor f.chans[0].conn.waitChangeFor(50)
  if f.batches.getOrDefault("held").len != 1:
    result.failures.add "the peer never received the call"
    return
  let heldOn = f.batches["held"][0][0]
  n.nginx.reload(n.nginx.httpConf)
  let fresh = n.nginx.waitForWorkers(old, keep = @[holder])
  # Every other old worker has exited (and its channels ended); the one
  # with the call in flight is still there, its channel open.
  for ch in f.chans:
    if ch.slot != heldOn.slot:
      discard waitFor ch.conn.waitEnded(10_000)
  if not processAlive(holder):
    result.failures.add "the old worker " & $holder &
      " exited with its call in flight"
  if heldOn.ended:
    result.failures.add "the channel of the call in flight ended"
  waitFor f.releaseReplies()
  let logDeadline = getMonoTime() + initDuration(seconds = 10)
  let okLine = "boundary_test: detached call held (pid " & $holder & "): ok"
  while not n.nginx.errorLogText.contains(okLine) and
      getMonoTime() < logDeadline:
    discard waitFor f.chans[0].conn.waitChangeFor(50)
  if not n.nginx.errorLogText.contains(okLine):
    result.failures.add "the call in flight was not answered on the old worker"
  # Its call answered, the old worker exits; the peer covers the new ones.
  try:
    discard n.nginx.waitForWorkers(old)
  except OSError as e:
    result.failures.add e.msg
  for ch in f.chans:
    discard waitFor ch.conn.waitEnded(10_000)
  for ch in f.chans:
    if not ch.ended:
      result.failures.add "a channel to an old worker outlived it"
  f.reported.clear()
  waitFor f.cover()
  discard waitFor waitLive(n, f)
  let after = waitFor callEveryWorker(n, 1, "after-reload")
  if toHashSet(toSeq(after.keys)) != toHashSet(fresh):
    result.failures.add "after the reload, answers from " & $toSeq(after.keys)
  for pid, a in after:
    if not a["results"][0]["ok"].getBool:
      result.failures.add "after the reload: " & $a
  waitFor f.closeAll()

suite "boundary channel lifetime":
  test "a channel closes when its peer certificate expires":
    let n = startNode(testModule())
    defer: n.stop()
    let expires = now().utc + initDuration(seconds = 6)
    let shortLived = issue(pki.dir, "writer-short", pki.ca, "forum", "writer",
      "writer-short", notAfter = expires.format("yyyyMMddHHmmss") & "Z")
    let f = newFleet(n, shortLived)
    let ch = waitFor f.openOne()
    let opened = now().utc
    check ch.hs["protocol"].getInt == 1
    check waitFor ch.conn.waitEnded(20_000)
    let closedAt = now().utc
    echo "    opened ", opened.format("HH:mm:ss"), ", expires ",
      expires.format("HH:mm:ss"), ", closed ", closedAt.format("HH:mm:ss"),
      " (", ch.conn.endReason, ")"
    # Not before its notAfter (whole seconds), and because of it.
    check closedAt >= expires - initDuration(seconds = 1)
    check n.nginx.errorLogText.contains("the peer certificate of node " &
      "\"writer-short\" expired; closing its channel")
    # A certificate already expired is refused outright (by nginx's
    # verification).
    let gone = attempt(n, "expired", shortLived)
    check gone.status == 400 and gone.frames == 0

  test "a reload keeps an old worker's channel until its call is answered":
    let r = reloadWithCallInFlight(testModule())
    if r.failures.len > 0:
      echo "    ", r.failures.join("\n    ")
    check r.failures.len == 0

  test "mutant: no hold keeps the exiting worker":
    let module = mutant("no-hold", "src/ngx_http_isonim_module.c",
      "    ngx_http_isonim_boundary_holding = on ? 1 : 0;",
      "    on = 0;   /* MUTANT: never held */\n" &
      "    ngx_http_isonim_boundary_holding = 0;")
    let r = reloadWithCallInFlight(module)
    echo "    mutant: ", r.failures.len, " failures, e.g. ",
      (if r.failures.len > 0: r.failures[0] else: "")
    check r.failures.anyIt("exited with its call in flight" in it)

  test "a frame over isonim_boundary_max_frame closes the channel":
    let n = startNode(testModule(), extra = "    isonim_boundary_max_frame 4k;\n")
    defer: n.stop()
    let f = newFleet(n)
    let ch = waitFor f.openOne()
    check ch.hs["max_frame"].getInt == 4096
    # Just the length prefix of a frame one byte over the limit.
    waitFor ch.conn.sendRaw("\x00\x00\x10\x01")
    check waitFor ch.conn.waitEnded(10_000)
    check n.nginx.errorLogText.contains("a frame of 4097 bytes exceeds " &
      "isonim_boundary_max_frame (4096)")

suite "isonim_boundary is validated by nginx -t":
  test "ssl_verify_client on and a peer class are required":
    let module = testModule()
    let p = freePort()
    proc t(server: string): tuple[code: int, output: string] =
      testConfig(module, appLocations, httpConf = server)
    let ok = t(boundaryServer(p))
    check ok.code == 0
    let optional = t(boundaryServer(p).replace("ssl_verify_client on;",
      "ssl_verify_client optional;"))
    check optional.code != 0
    check optional.output.contains("\"isonim_boundary on\" requires " &
      "\"ssl_verify_client on\"")
    let none = t(boundaryServer(p).replace("    ssl_verify_client on;\n", ""))
    check none.code != 0
    check none.output.contains("requires \"ssl_verify_client on\"")
    let noClass = t(boundaryServer(p).replace(
      "    isonim_boundary_peer_class writer;\n", ""))
    check noClass.code != 0
    check noClass.output.contains("requires \"isonim_boundary_peer_class\"")
    let badClass = t(boundaryServer(p, extra =
      "    isonim_boundary_peer_class Writer!;\n"))
    check badClass.code != 0
    let zero = t(boundaryServer(p, extra = "    isonim_boundary_min_channels 0;\n"))
    check zero.code != 0
    check zero.output.contains("isonim_boundary_min_channels")
    let small = t(boundaryServer(p, extra = "    isonim_boundary_max_frame 100;\n"))
    check small.code != 0
    check small.output.contains("isonim_boundary_max_frame")
    let wrongContext = testConfig(module,
      "    location /x { isonim_boundary on; }\n")
    check wrongContext.code != 0
    check wrongContext.output.contains("\"isonim_boundary\" directive is " &
      "not allowed here")
