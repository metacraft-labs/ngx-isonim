## rpc.nim
##
## `isonim_rpc` locations: requests whose body nginx has read
## (ngx_http_read_client_request_body) and that an asynchronous IsoNim
## handler answers.
##
## The handler is the server-function registry (isonim's `dispatchRpc`:
## `POST <rpcPrefix>/<module>/<proc>`), or the async app named by
## `isonim_rpc_app` (e.g. a route manifest's `manifestApp`).  Either gets a
## `RequestContext` and returns a future; the worker goes on serving other
## connections while it is pending, and Nim's event loop
## (async_loop.nim) completes it.
##
## The response goes out through the transport of serve.nim (`Transport`),
## in one of two ways:
##
## * **whole** (a handler that never flushes): when the future completes,
##   what the handler left in the context (status, headers, cookies,
##   redirect, body) is sent with `Content-Length`;
## * **streamed**: an async app writes through the context's body writer
##   (`ctx.bodyWriter`, a `ResponseBody`, with `outputStream` for
##   faststreams).  Its first `flush` commits the status and headers and
##   switches the response to chunked; every flush is passed to nginx at
##   once with the `flush` flag; the future's completion sends the last
##   buffer.  Whatever the handler put in `ctx.responseBody` (isonim's
##   `ctx.write`, `respondJson`) is part of the same body, in the order it
##   was written.  Bytes nginx cannot send yet stay in its output chain and
##   the C module's write handler sends them as the socket drains, so a
##   slow client never blocks the event loop.  For `HEAD`, `204` and `304`
##   the commit sends the headers only and later writes are discarded.
##   `isonim_ssr_max_buffer_size` bounds each buffer between two flushes, not
##   the whole body, and the body writer's `unsentBytes` reports what the
##   client has not read yet (the transport's unflushed bytes plus what
##   nginx holds), so a handler can stream for as long as it likes and
##   bound a slow client itself (spec/isonim-nginx.md, "Backpressure",
##   "Buffer limit").  The C module frees each flushed buffer once nginx
##   has written it, so such a stream's memory is what is unsent.
##
## Then the request is finalized.  What the client sees when something
## fails:
##
## | Failure | Nothing sent yet | After the commit point |
## | :--- | :--- | :--- |
## | handler raises (an app) / its server function raised | `500` `{"error":"internal"}`, logged | response terminated without its last chunk, logged |
## | a buffer over `isonim_ssr_max_buffer_size` | `500` `{"error":"internal"}`, logged naming the limit | response terminated, logged naming the limit |
## | `isonim_rpc_timeout` expires | `504` `{"error":"timeout"}`, logged | response terminated without its last chunk, logged |
## | client gone | request terminated by nginx (`499`); the result is dropped | the next write or flush raises `ClientConnectionError`; the request is released |
##
## After the request has ended (timed out, or released by nginx) every write
## and flush of the handler raises `ClientConnectionError`, so a handler
## still running stops at its next write without touching the request.  The
## writer stays on the context for that reason: it is set once, in `run`,
## and never cleared.
##
## `startRpc` / `run` / `timeout` / `release` are the transport-independent
## core; the nginx glue (`nim_handle_rpc`, `nim_rpc_timeout`,
## `nim_rpc_released`) is in handler.nim, and the mock-mode tests drive the
## same core over a recording sink.

import std/asyncdispatch
import isonim/server/rpc as isonimRpc
import nginx_types, config, app_registry, serve

export asyncdispatch

type
  RpcOptions* = object
    ## The location configuration an isonim_rpc request needs.
    maxBufferSize*: int   ## isonim_ssr_max_buffer_size; 0 = unlimited
    hydration*: bool      ## isonim_ssr_hydration (for the app to read)

  RpcState* = ref object
    ctx*: RequestContext
    app: AppEntry          ## nil: the server-function registry
    appName: string
    opts: RpcOptions
    sink: ResponseSink
    transport: Transport
    body*: ResponseBody    ## the handler's body writer
    finish: proc(rc: NgxInt)
    done*: bool            ## the response was ended (or the request failed)
    gone*: bool            ## nginx released the request
    timedOut*: bool
    failure: ref CatchableError
      ## A write or flush that failed (the client went away, the limit):
      ## the response cannot be completed normally any more.

var releasedCount {.threadvar.}: int

proc rpcRequestsReleased*(): int =
  ## How many isonim_rpc requests nginx has released in this worker
  ## (`release`): the end of every request, finished or terminated.
  releasedCount

proc where(st: RpcState): string =
  " (" & st.ctx.request.httpMethod & " " & st.ctx.request.rawUri &
    (if st.appName.len > 0: ", app \"" & st.appName & "\"" else: "") & ")"

proc ended(st: RpcState): bool =
  st.done or st.gone

proc checkLive(st: RpcState) =
  ## A write after the request ended, or after a failed write, raises.
  if st.gone:
    raise newException(ClientConnectionError,
      "the request was released (the client went away)")
  if st.done:
    raise newException(ClientConnectionError,
      "the response was already ended" &
      (if st.timedOut: " (isonim_rpc_timeout)" else: ""))
  if st.failure != nil:
    raise st.failure

proc drainContextBody(st: RpcState) =
  ## Moves what the handler put in `ctx.responseBody` into the transport, so
  ## that it keeps its place in the body.
  st.transport.useResponse(st.ctx.response)
  if st.ctx.response.isRedirect and not st.transport.committed:
    # A redirect carries no body: what the handler wrote before redirecting
    # is dropped, as it always was.
    st.ctx.responseBody.setLen(0)
  if st.ctx.responseBody.len > 0:
    let pending = move st.ctx.responseBody
    st.ctx.responseBody = ""
    st.transport.write(pending.toOpenArray(0, pending.high))

proc guarded(st: RpcState; op: proc()) =
  ## Runs a transport operation; a failure is remembered (later writes
  ## raise it again) and raised.
  st.checkLive()
  try:
    op()
  except CatchableError as e:
    if st.failure.isNil:
      st.failure = e
    raise

proc bodyWrite(st: RpcState; data: openArray[char]) =
  st.checkLive()
  try:
    st.drainContextBody()
    st.transport.write(data)
  except CatchableError as e:
    if st.failure.isNil:
      st.failure = e
    raise

proc bodyFlush(st: RpcState) =
  st.guarded(proc() =
    st.drainContextBody()
    st.transport.flush())

proc bodyUnsent(st: RpcState): int =
  ## What the handler wrote that the client has not read (raises, as a
  ## write does, once the request has ended).
  st.checkLive()
  st.ctx.responseBody.len + st.transport.unsentBytes

proc fail(st: RpcState; status: int; error: string) =
  ## Replaces whatever the handler shaped with a framework error (only
  ## before the commit point).
  st.ctx.response = newSsrResponse()
  st.ctx.responseBody.setLen(0)
  st.ctx.respondError(status, error)
  st.transport.restart(st.ctx.response)

proc terminate(st: RpcState; level: NgxUint; msg: string) =
  ## Ends a committed response without its last chunk: nginx closes the
  ## connection, so the client sees an unterminated chunked body.
  st.sink.log(level, msg & "; response terminated after the headers were " &
    "sent" & st.where)
  st.finish(NGX_ERROR)

proc deliver(st: RpcState) =
  ## Ends the response: the rest of the body and the last buffer (with
  ## `Content-Length` when nothing was sent yet).
  var rc: NgxInt
  try:
    st.drainContextBody()
    st.transport.endBody(whole = true)
    rc = st.transport.lastRc
  except ClientConnectionError as e:
    st.sink.log(NGX_LOG_INFO, e.msg & st.where)
    rc = NGX_ERROR
  except CatchableError as e:
    if st.transport.committed:
      st.terminate(NGX_LOG_ERR, (if e of ResponseTooLargeError: e.msg
        else: "invalid response: " & e.msg))
      return
    # E.g. a header the handler set is invalid, or the body is over the
    # limit: nothing was sent yet.
    st.sink.log(NGX_LOG_ERR, (if e of ResponseTooLargeError: e.msg
      else: "invalid response: " & e.msg) & "; responding 500" & st.where)
    try:
      st.fail(500, "internal")
      st.transport.endBody(whole = true)
      rc = st.transport.lastRc
    except CatchableError:
      rc = NGX_HTTP_INTERNAL_SERVER_ERROR
  st.finish(rc)

proc complete(st: RpcState; fut: Future[void]) =
  if st.ended:
    return
  st.done = true
  # A write through the faststreams view surfaces as IOError; the original
  # error is kept on the body.
  let raised: ref CatchableError =
    if not fut.failed: nil
    elif st.body.failure != nil: st.body.failure
    else: (ref CatchableError)(fut.error)
  let cause = if raised != nil: raised else: st.failure
  if cause != nil:
    if cause of ClientConnectionError:
      st.sink.log(NGX_LOG_INFO, cause.msg & st.where)
      st.finish(NGX_ERROR)
      return
    let what =
      if cause of ResponseTooLargeError: cause.msg
      else: "handler raised " & $cause.name & ": " & cause.msg
    if st.transport.committed:
      st.terminate(NGX_LOG_ERR, what)
      return
    st.sink.log(NGX_LOG_ERR, what & "; responding 500" & st.where)
    st.fail(500, "internal")
  elif st.ctx.failure != nil:
    st.sink.log(NGX_LOG_ERR, "server function raised " &
      $st.ctx.failure.name & ": " & st.ctx.failure.msg & st.where)
  st.deliver()

proc timeout*(st: RpcState) =
  ## `isonim_rpc_timeout` expired before the handler completed.
  if st.ended:
    return
  st.done = true
  st.timedOut = true
  if st.transport.committed:
    st.terminate(NGX_LOG_ERR,
      "the handler did not complete within isonim_rpc_timeout")
    return
  st.sink.log(NGX_LOG_ERR, "the handler did not complete within " &
    "isonim_rpc_timeout; responding 504" & st.where)
  st.fail(504, "timeout")
  st.deliver()

proc release*(st: RpcState) =
  ## nginx released the request: nothing may touch it any more.
  if not st.gone:
    inc releasedCount
  st.gone = true

proc startRpc*(req: SsrRequest; appName: string; sink: ResponseSink;
               finish: proc(rc: NgxInt); opts = RpcOptions()): RpcState =
  ## The state of one request; `run` starts its handler.
  let st = RpcState(ctx: newRequestContext(req), appName: appName,
                    opts: opts, sink: sink, finish: finish)
  st.transport = newTransport(st.ctx.response,
    ServeOptions(appName: appName, hydration: false, mode: tmStreaming,
                 maxBufferSize: opts.maxBufferSize, limitPerBuffer: true), sink)
  st.body = newResponseBody(
    proc(data: openArray[char]) = st.bodyWrite(data),
    proc() = st.bodyFlush(),
    proc(): int = st.bodyUnsent())
  st

proc hydrationEnabled*(st: RpcState): bool =
  ## The location's `isonim_ssr_hydration`.
  st.opts.hydration

proc run*(st: RpcState) =
  ## Starts the handler.  It completes on the event loop; when it already
  ## finished, the response goes out on the loop's next turn.
  if st.appName.len > 0:
    st.app = lookupApp(st.appName)
    if st.app.isNil or st.app.kind != akAsync:
      st.done = true
      st.sink.log(NGX_LOG_ERR, (if st.app.isNil: "no app is registered as \""
        else: "app \"") & st.appName & "\"" &
        (if st.app.isNil: " (isonim_rpc_app)" else: " is not an async app " &
          "(register it with registerAsyncApp)"))
      st.finish(NGX_HTTP_INTERNAL_SERVER_ERROR)
      return
    # The app's body writer and hydration flag, on IsoNim's context.  The
    # writer is never taken back: after the request has ended its writes
    # raise `ClientConnectionError` (`checkLive`), which stops a handler
    # still running.  A nil writer instead would make a streaming page fall
    # back to buffering into `ctx.responseBody`, silently, for no one.
    st.ctx.setBodyWriter(st.body)
    st.ctx.hydration = st.opts.hydration
  var fut: Future[void]
  try:
    fut = if st.app.isNil: dispatchRpc(st.ctx) else: st.app.handle(st.ctx)
  except CatchableError as e:
    fut = newFuture[void]("isonim rpc")
    fut.fail(e)
  fut.addCallback(proc() {.gcsafe.} =
    {.cast(gcsafe).}:
      st.complete(fut))
