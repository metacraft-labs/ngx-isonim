## t_boundary_reload.nim
##
## test_boundary_listener_reloads_renewed_certificate (milestone IFP-M24;
## spec/isonim-nginx.md, "Interior-Opened Boundary Channels", Lifetime):
## the node's own workload certificate lives an hour and is renewed at
## two-thirds of that (isonim-platform-control-plane.md §8.4); the renewal
## reaches the Boundary listener by the renewal signal, a reload of nginx
## (the node agent runs the node's reload command once the new certificate
## and key are in place), and no channel outlives the certificate it was
## opened on.
##
## The node is a real nginx with eight workers and the real module
## (boundary_support.nim, shared with t_boundary_channel.nim), its Boundary
## listener's `ssl_certificate` and `ssl_certificate_key` two files the test
## replaces on renewal, as the node agent does: the key first, then the
## certificate, each by a rename.  The first certificate lives
## `firstLifetime` seconds.
##
## * The renewal reaches new channels: with a peer's channels covering every
##   worker and two calls in flight on detached requests (the peer holds
##   their replies), the certificate is renewed and nginx signalled.  New
##   channels see the renewed certificate (its serial, read from each new
##   connection's handshake), the call answered after the reload completes
##   on its old worker, and the call never answered loses its channel at
##   the old certificate's notAfter (`bcLost`), long before its own
##   deadline: no channel is open on the old certificate past its notAfter.
##   After it, a call from every worker is answered over the renewed
##   certificate.  Every new worker holds `min_channels` live channels
##   (its own status, read through the app) within a second of the signal, so a write refused `503`
##   (`Retry-After: 1`, IsoNim-Forum.md §3.8.2) while a new worker had none
##   succeeds on its retry, and a call through every new worker then
##   succeeds.
## * Negative control: without the renewal signal (the certificate files
##   replaced, nginx not signalled: what a node does that reads its
##   certificate only when nginx starts), the run fails explicitly when the
##   old certificate expires: a verifying peer's new channel fails its TLS
##   handshake on the expired certificate, and a peer that does not verify
##   the node is refused `503` by the module itself.
## * Fail closed: a renewal whose new key does not match its certificate is
##   refused by nginx's reload (the old workers keep serving the old
##   certificate), and at the old certificate's notAfter every channel on it
##   is closed and no new channel opens.
## * Mutant: the module not enforcing its own certificate's notAfter
##   (`ngx_http_isonim_boundary_ends` returning the peer's alone) keeps the
##   channel of the unanswered call open on the old certificate until the
##   call's deadline, and fails the first case.
##
## MOCKING POLICY.  As t_boundary_channel.nim's (its header): the test peer
## (h2_peer.nim) stands in for IsoNim Forum's write executor, and the
## workload certificates are the test's own, made with the `openssl` CLI in
## the format of isonim-platform-control-plane.md §8.4; the renewal signal is
## the SIGHUP the platform's node agent sends through the node's reload
## command (isonim-platform control-plane/src/node_agent.nim, tested there
## against the control plane's own CA), sent here by the test.  Everything
## else is real: nginx, its workers and their reload, TLS, HTTP/2, the
## module.
##
## Synchronization, never sleeps: every wait is for a condition (a frame, a
## stream's end, a worker set, a log line, a moment on the clock that a
## certificate expires at), polled on the event loop with a deadline.
##
## Run: nim c -r tests/integration/t_boundary_reload.nim  (in the dev
## shell; `just test-boundary-reload`, part of `just test-e2e`).

import std/[unittest, asyncdispatch, httpclient, json, os, osproc, strutils,
            tables, sets, sequtils, times, monotimes, net, posix, math]
import ../e2e/harness
import h2_peer

include boundary_support

const
  firstLifetime = 30          ## seconds the first certificate lives
  closeSlack = 2.0            ## seconds after a notAfter a close may take

type
  RenewalMode = enum
    rmSignal       ## the certificate renewed and nginx signalled
    rmNoSignal     ## the files replaced, nginx not signalled
    rmInvalid      ## a renewal whose key is not its certificate's, signalled

  RenewalRun = object
    failures: seq[string]           ## what the case requires and did not get
    oldSerial, newSerial: string
    firstOnOld: bool                ## every first channel was opened on the old certificate
    renewedSerials: seq[string]     ## what new channels saw after the renewal
    reloadRefused: bool             ## nginx logged the refused reload
    lostFailedLogged: bool
    doneOk: bool
    oldOpenPastExpiry: int          ## channels on the old certificate open after it
    verifyingAfter: string          ## "ok <serial>" or "error <why>"
    nonVerifyingAfter: int          ## the status a non-verifying peer got after expiry
    nonVerifyingSaw: string         ## the serial it was presented ("old", "new")
    recoverSeconds: float           ## from the renewal signal until every new
                                    ##   worker holds min_channels live channels
    afterReloadOk: bool             ## a call through every new worker then succeeded

proc derOf(pem: string): string =
  let derFile = pem & ".der"
  sh("openssl x509 -in " & quoteShell(pem) & " -outform DER -out " & quoteShell(derFile) & " 2>&1")
  readFile(derFile)

proc serialOf(pem: string): string =
  let (o, code) = execCmdEx("openssl x509 -in " & quoteShell(pem) & " -noout -serial")
  doAssert code == 0, o
  o.strip.split('=')[^1].toLowerAscii

proc install(src: Cert; live: Cert) =
  ## The node agent's order: the key, then the certificate, each by rename.
  for (a, b) in [(src.key, live.key), (src.pem, live.pem)]:
    copyFile(a, b & ".tmp")
    moveFile(b & ".tmp", b)

proc waitUntil(f: Fleet; t: float) =
  ## Until the clock reads `t` (epoch seconds), on the event loop.
  while epochTime() < t:
    discard waitFor f.chans[0].conn.waitChangeFor(
      max(1, min(200, int((t - epochTime()) * 1000))))

proc renewalRun(module: string; mode: RenewalMode): RenewalRun =
  let d = pki.dir / ("renewal-" & $mode & "-" & $getCurrentProcessId())
  removeDir(d)
  createDir(d)
  let notAfter1 = epochTime() + float(firstLifetime)
  let v1 = issue(d, "node-v1", pki.ca, "forum", "serving", "edge-node-1",
    notAfter = fromUnixFloat(notAfter1).utc.format("yyyyMMddHHmmss") & "Z")
  let notAfter1Exact = notAfter1.floor    # whole seconds, as issued
  let live = Cert(pem: d / "live.pem", key: d / "live.key")
  install(v1, live)
  result.oldSerial = serialOf(v1.pem)
  let oldDer = derOf(v1.pem)
  var n = startNode(module, nodeCert = live)
  defer: n.stop()
  let f = newFleet(n)
  waitFor f.cover()
  discard waitFor waitLive(n, f)
  result.firstOnOld = f.chans.allIt(it.conn.serverCertDer == oldDer)
  if not result.firstOnOld:
    result.failures.add "a first channel did not see the first certificate"

  # Two calls in flight, each on a request that is already over, so only
  # the module's hold keeps their workers through a reload.
  f.holdReplies = true
  let done = waitFor appCall(n.nginx.port, "/b/detached?batch=held-done&timeout_ms=60000")
  let lost = waitFor appCall(n.nginx.port, "/b/detached?batch=held-lost&timeout_ms=60000")
  let holders = @[done["pid"].getInt, lost["pid"].getInt].deduplicate
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while (f.batches.getOrDefault("held-done").len < 1 or
         f.batches.getOrDefault("held-lost").len < 1) and getMonoTime() < deadline:
    discard waitFor f.chans[0].conn.waitChangeFor(50)
  if f.batches.getOrDefault("held-done").len != 1 or
      f.batches.getOrDefault("held-lost").len != 1:
    result.failures.add "the peer never received the calls"
    return
  let lostOn = f.batches["held-lost"][0][0]
  let old = n.nginx.workerPids

  # The renewal.
  let v2 = issue(d, "node-v2", pki.ca, "forum", "serving", "edge-node-1")
  result.newSerial = serialOf(v2.pem)
  let newDer = derOf(v2.pem)
  case mode
  of rmSignal, rmNoSignal:
    install(v2, live)
  of rmInvalid:
    let stray = issue(d, "stray", pki.ca, "forum", "serving", "edge-node-1")
    install(Cert(pem: v2.pem, key: stray.key), live)
  let signalledAt = epochTime()
  if mode in {rmSignal, rmInvalid}:
    n.nginx.reload(n.nginx.httpConf)          # the renewal signal: SIGHUP
  if mode == rmSignal:
    try:
      discard n.nginx.waitForWorkers(old, keep = holders)
    except OSError as e:
      result.failures.add "the reload did not complete: " & e.msg
      return
    # New connections reach the new workers only; they see the renewal.
    f.reported.clear()
    let before = f.chans.len
    waitFor f.cover()
    # The window a renewal opens: until every new worker holds min_channels
    # LIVE channels (the worker has read the peer's handshake, which follows
    # the node's handshake the peer counts in `cover` by a scheduling
    # delay), a write reaching one without a channel is refused
    # `bcNoChannel` at once, which the forum answers `503` with
    # `Retry-After: 1` (IsoNim-Forum.md §3.8.2); live within that second,
    # the client's retry succeeds.  (Not waitLive: the channels held on old
    # workers share slot numbers with the new workers'.  The app port
    # reaches the new workers only.)
    let liveDeadline = getMonoTime() + initDuration(seconds = 10)
    while true:
      let st = waitFor statusAll(n)
      if toSeq(st.values).allIt(it["pid"].getInt notin old and
                                it["live"].getInt >= f.minChannels):
        break
      if getMonoTime() > liveDeadline:
        result.failures.add "a new worker never held min_channels live channels: " & $st
        break
    result.recoverSeconds = epochTime() - signalledAt
    if result.recoverSeconds >= 1.0:
      result.failures.add "every new worker held min_channels channels only " &
        formatFloat(result.recoverSeconds, ffDecimal, 2) & " s after the renewal signal"
    for ch in f.chans[before .. ^1]:
      result.renewedSerials.add(
        if ch.conn.serverCertDer == newDer: result.newSerial
        elif ch.conn.serverCertDer == oldDer: result.oldSerial
        else: "other")
    if result.renewedSerials.len == 0 or
        result.renewedSerials.anyIt(it != result.newSerial):
      result.failures.add "a new channel after the renewal saw " &
        $result.renewedSerials.deduplicate & ", not the renewed " & result.newSerial
    # The call answered after the reload completes on its old worker.
    waitFor f.replyBatch("held-done")
    let okLine = "boundary_test: detached call held-done (pid " & $done["pid"].getInt & "): ok"
    let logDeadline = getMonoTime() + initDuration(seconds = 10)
    while not n.nginx.errorLogText.contains(okLine) and getMonoTime() < logDeadline:
      discard waitFor f.chans[0].conn.waitChangeFor(50)
    result.doneOk = n.nginx.errorLogText.contains(okLine)
    # From here the peer answers every call (the unanswered one has no
    # reply coming: its batch arrived while replies were held).
    f.holdReplies = false
    if not result.doneOk:
      result.failures.add "the call in flight across the reload was not answered"
    # A write through every new worker, over the renewed channels.
    let fresh = waitFor callEveryWorker(n, 1, "after-reload")
    result.afterReloadOk = fresh.len > 0 and
      toSeq(fresh.values).allIt(it["results"][0]["ok"].getBool)
    if not result.afterReloadOk:
      var peerSide: seq[string]
      for ch in f.chans:
        peerSide.add $ch.slot & (if ch.ended: ":ended" else: ":open") &
          (if ch.conn.serverCertDer == newDer: ":new" else: ":old")
      result.failures.add "a call through a new worker after the renewal failed: " & $fresh &
        "; the peer's channels (slot:state:certificate) " & $peerSide &
        "; the workers' status " & $(waitFor statusAll(n))
  elif mode == rmInvalid:
    let logDeadline = getMonoTime() + initDuration(seconds = 10)
    while not n.nginx.errorLogText.contains("key values mismatch") and
        getMonoTime() < logDeadline:
      discard waitFor f.chans[0].conn.waitChangeFor(50)
    result.reloadRefused = n.nginx.errorLogText.contains("key values mismatch") and
      n.nginx.workerPids.toHashSet == old.toHashSet

  # The old certificate's notAfter, and a moment after it.
  f.waitUntil(notAfter1Exact + closeSlack)
  for ch in f.chans:
    if ch.conn.serverCertDer == oldDer and not ch.conn.ended:
      inc result.oldOpenPastExpiry
  if result.oldOpenPastExpiry > 0:
    result.failures.add $result.oldOpenPastExpiry & " channels on the old " &
      "certificate outlived its notAfter"
  if not lostOn.conn.ended:
    result.failures.add "the channel of the unanswered call is open past the " &
      "old certificate's notAfter"
  let lostLine = "boundary_test: detached call held-lost (pid " & $lost["pid"].getInt & "): failed"
  let lostDeadline = getMonoTime() + initDuration(seconds = 5)
  while not n.nginx.errorLogText.contains(lostLine) and getMonoTime() < lostDeadline:
    discard waitFor f.chans[0].conn.waitChangeFor(50)
  result.lostFailedLogged = n.nginx.errorLogText.contains(lostLine)
  if not result.lostFailedLogged:
    result.failures.add "the unanswered call did not fail with its channel at the " &
      "old certificate's notAfter"

  # After the old notAfter: a verifying peer, and one that does not verify.
  try:
    let conn = waitFor connectPeer(f.ctx, "127.0.0.1", n.bport)
    let st = waitFor conn.openStream(f.authority)
    result.verifyingAfter = "ok " & (if conn.serverCertDer == newDer: result.newSerial
                                     elif conn.serverCertDer == oldDer: result.oldSerial
                                     else: "other") & " " & $st
    conn.close()
  except CatchableError as e:
    # The handshake's own error (asyncdispatch prefixes its traceback).
    result.verifyingAfter = "error " & e.msg.split("Exception message: ")[^1].strip
  if not result.verifyingAfter.startsWith("ok " & result.newSerial & " 200"):
    result.failures.add "after the old certificate's notAfter, a new channel " &
      "failed: " & result.verifyingAfter
  let blind = newPeerContext(pki.writer.pem, pki.writer.key, pki.ca.pem,
                             verifyServer = false)
  try:
    let conn = waitFor connectPeer(blind, "127.0.0.1", n.bport)
    result.nonVerifyingAfter = waitFor conn.openStream(f.authority)
    result.nonVerifyingSaw = (if conn.serverCertDer == newDer: "new"
                              elif conn.serverCertDer == oldDer: "old" else: "other")
    conn.close()
  except CatchableError:
    result.nonVerifyingAfter = -1
  if mode == rmSignal:
    f.reported.clear()
    waitFor f.cover()
    let after = waitFor callEveryWorker(n, 1, "after-expiry")
    for pid, a in after:
      if not a["results"][0]["ok"].getBool:
        result.failures.add "after the old certificate's notAfter: " & $a
  waitFor f.closeAll()

proc show(r: RenewalRun) =
  echo "    old ", r.oldSerial, ", renewed ", r.newSerial, "; new channels saw ",
    r.renewedSerials.deduplicate, "; old open past notAfter ", r.oldOpenPastExpiry,
    "; after it: verifying peer ", r.verifyingAfter, ", non-verifying ",
    r.nonVerifyingAfter, " (presented the ", r.nonVerifyingSaw, " certificate)",
    "; re-covered ", formatFloat(r.recoverSeconds, ffDecimal, 3), " s after the signal"
  if r.failures.len > 0:
    echo "    failures: ", r.failures.join("\n      ")

suite "test_boundary_listener_reloads_renewed_certificate":
  test "the renewal reaches new channels; nothing outlives the old certificate":
    let r = renewalRun(testModule(), rmSignal)
    r.show
    check r.firstOnOld
    check r.renewedSerials.len > 0 and r.renewedSerials.allIt(it == r.newSerial)
    check r.doneOk
    check r.recoverSeconds > 0 and r.recoverSeconds < 1.0
    check r.afterReloadOk
    check r.lostFailedLogged
    check r.oldOpenPastExpiry == 0
    check r.nonVerifyingAfter == 200 and r.nonVerifyingSaw == "new"
    check r.failures.len == 0

  test "negative control: without the renewal signal the run fails at the old notAfter":
    let r = renewalRun(testModule(), rmNoSignal)
    r.show
    # It fails explicitly, on the expired certificate, not on anything else:
    # the verifying peer's handshake fails, and the node is still presenting
    # the old certificate.
    check r.failures.anyIt("after the old certificate's notAfter, a new channel failed" in it)
    check r.verifyingAfter.startsWith("error ")
    check r.nonVerifyingSaw == "old"
    # The module itself refuses a peer that does not verify it.
    check r.nonVerifyingAfter == 503
    check r.oldOpenPastExpiry == 0

  test "an invalid renewal fails closed":
    let r = renewalRun(testModule(), rmInvalid)
    r.show
    check r.reloadRefused
    check r.oldOpenPastExpiry == 0
    check r.lostFailedLogged
    check r.verifyingAfter.startsWith("error ")
    check r.nonVerifyingSaw == "old"
    check r.nonVerifyingAfter == 503

  test "mutant: the node's own certificate's notAfter not enforced":
    let module = buildMutant("own-expiry-ignored", "src/ngx_http_isonim_module.c",
      "    if (ch->own_not_after > 0 && ch->own_not_after < ch->peer_not_after) {",
      "    if (0) {   /* MUTANT: own notAfter ignored */")
    let r = renewalRun(module, rmSignal)
    r.show
    check r.failures.anyIt("outlived its notAfter" in it)
