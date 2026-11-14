## boundary_app.nim
##
## The async app `boundary_test` over Interior-opened Boundary channels
## (src/boundary.nim), compiled into the end-to-end module (registered by
## e2e_apps.nim) and driven over real nginx by
## tests/integration/t_boundary_channel.nim, whose test peer opens the
## channels.  It is served at an ordinary `isonim_rpc` location of a plain
## HTTP listener; every answer is JSON naming the worker's `pid` and
## `slot`.  The operation is the last path segment:
##
## * `status`: this worker's channels as its pool counts them (`channels`,
##   `live`), as the C side counts them (`attached`), the node's per-slot
##   counts (`node`) and the calls in flight (`inflight`);
## * `call` (`?n=&batch=&timeout_ms=`): makes `n` concurrent
##   `boundaryCall`s, frame `i` being `{"msg_id": "<batch>-<i>", "batch",
##   "n", "i", "pid", "slot"}`, and answers each one's outcome in order:
##   `{"i", "immediate", "ok", "reply"}` or `{"i", "immediate", "ok":
##   false, "error": "bcNoChannel" | "bcLost" | "bcTimeout"}`.
##   `immediate` says whether the call's future was already finished when
##   `boundaryCall` returned;
## * `send` (`?tag=`): one `boundarySend` of `{"kind": "send", "tag",
##   "pid", "slot"}`: `{"ok": true}` or `{"ok": false, "error"}`;
## * `detached` (`?batch=&timeout_ms=`): starts one call (frame as for
##   `call`, `n` 1) that outlives the request: the answer comes at once,
##   and the call's outcome goes to the error log as `boundary_test:
##   detached call <batch> (pid <pid>): ok` or `... failed: <error>`.  No
##   HTTP request (and so none of its timers) is left in the worker while
##   it is in flight.

import std/[asyncdispatch, json, posix, strutils, times]
import isonim/server/context
import ../../../src/app_registry
import ../../../src/boundary
import ../../../src/nginx_types

proc logLine(msg: string) =
  ngx_http_isonim_log_cycle(NGX_LOG_ERR, unsafeAddr msg[0], csize_t(msg.len))

proc outcome(i: int; immediate: bool; f: Future[seq[byte]]): JsonNode =
  result = %*{"i": i, "immediate": immediate}
  if f.failed:
    result["ok"] = %false
    let e = f.readError
    if e of BoundaryError:
      result["error"] = %($(ref BoundaryError)(e).kind)
    else:
      result["error"] = %(e.msg)
  else:
    result["ok"] = %true
    result["reply"] = parseJson(toStr(f.read))

proc handleBoundary(ctx: RequestContext): Future[void] {.async.} =
  let req = ctx.request
  let op = req.path.split('/')[^1]
  let pid = int(getpid())
  let slot = boundaryWorkerSlot()
  var answer = %*{"pid": pid, "slot": slot}
  case op
  of "status":
    answer["workers"] = %boundaryWorkers()
    answer["channels"] = %boundaryChannelCount()
    answer["attached"] = %boundaryAttachedChannels()
    answer["live"] = %boundaryLiveChannelCount()
    answer["node"] = %boundaryNodeChannels()
    answer["inflight"] = %boundaryCallsInFlight()
  of "call":
    let n = parseInt(req.queryParam("n", "1"))
    let batch = req.queryParam("batch", "b")
    let timeout = initDuration(milliseconds =
      parseInt(req.queryParam("timeout_ms", "10000")))
    var futs: seq[Future[seq[byte]]]
    var immediate: seq[bool]
    for i in 0 ..< n:
      let frame = $(%*{"msg_id": batch & "-" & $i, "batch": batch, "n": n,
                       "i": i, "pid": pid, "slot": slot})
      let f = boundaryCall(toBytes(frame), timeout)
      futs.add f
      immediate.add f.finished
    for f in futs:
      if not f.finished:
        yield f
    var results = newJArray()
    for i, f in futs:
      results.add outcome(i, immediate[i], f)
    answer["results"] = results
  of "detached":
    let batch = req.queryParam("batch", "d")
    let timeout = initDuration(milliseconds =
      parseInt(req.queryParam("timeout_ms", "30000")))
    let frame = $(%*{"msg_id": batch & "-0", "batch": batch, "n": 1, "i": 0,
                     "pid": pid, "slot": slot})
    let f = boundaryCall(toBytes(frame), timeout)
    f.addCallback(proc() {.gcsafe.} =
      {.cast(gcsafe).}:
        let what = "boundary_test: detached call " & batch & " (pid " & $pid &
          "): " & (if f.failed: "failed: " & f.readError.msg else: "ok")
        logLine(what))
    answer["started"] = %true
  of "send":
    let frame = $(%*{"kind": "send", "tag": req.queryParam("tag", ""),
                     "pid": pid, "slot": slot})
    try:
      boundarySend(toBytes(frame))
      answer["ok"] = %true
    except BoundaryError as e:
      answer["ok"] = %false
      answer["error"] = %($e.kind)
  else:
    ctx.respondJson(404, $(%*{"error": "unknown operation " & op}))
    return
  ctx.respondJson(200, $answer)

proc registerBoundaryApps*() =
  registerAsyncApp("boundary_test", handleBoundary)
