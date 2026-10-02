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
## (async_loop.nim) completes it.  Then:
##
## * the response the handler left in the context (status, headers,
##   cookies, redirect, body) is sent with `Content-Length`, and the
##   request finalized;
## * a handler that raised (an app), or whose server function raised
##   (`ctx.failure`), is logged; the client gets `500`
##   `{"error":"internal"}`;
## * a handler still running when `isonim_rpc_timeout` expires: the client
##   gets `504` `{"error":"timeout"}` (logged), and the handler's result,
##   when it comes, is dropped;
## * a client that went away: nginx terminates the request, the state is
##   released (`gone`), and the result is dropped.
##
## `startRpc` / `run` / `timeout` are the transport-independent core; the
## nginx glue (`nim_handle_rpc`, `nim_rpc_timeout`, `nim_rpc_released`) is
## in handler.nim, and the mock-mode tests drive the same core over a
## recording sink.

import std/asyncdispatch
import isonim/server/rpc as isonimRpc
import nginx_types, app_registry, serve

export asyncdispatch

type
  RpcState* = ref object
    ctx*: RequestContext
    app: AppEntry          ## nil: the server-function registry
    appName: string
    sink: ResponseSink
    finish: proc(rc: NgxInt)
    done*: bool            ## the response was sent (or the request failed)
    gone*: bool            ## nginx released the request
    timedOut*: bool

proc where(st: RpcState): string =
  " (" & st.ctx.request.httpMethod & " " & st.ctx.request.rawUri &
    (if st.appName.len > 0: ", app \"" & st.appName & "\"" else: "") & ")"

proc sendResponse(st: RpcState): NgxInt =
  ## Sends the context's response with Content-Length; returns what the
  ## request is finalized with.
  let resp = st.ctx.response
  let body = if resp.isRedirect: "" else: st.ctx.responseBody
  resp.markCommitted()
  let rc = st.sink.sendHeader(resp, int64(body.len))
  if rc == NGX_DONE:
    return NGX_OK          # HEAD, 204, 304: no body
  if rc == NGX_ERROR or rc > NGX_OK:
    return rc
  let brc =
    if body.len > 0: st.sink.sendBody(body.toOpenArray(0, body.high), false, true)
    else:
      var empty: array[0, char]
      st.sink.sendBody(empty, false, true)
  brc

proc respondFresh(st: RpcState; status: int; error: string) =
  ## Replaces whatever the handler shaped with a framework error.
  st.ctx.response = newSsrResponse()
  st.ctx.responseBody.setLen(0)
  st.ctx.respondError(status, error)

proc deliver(st: RpcState) =
  var rc: NgxInt
  try:
    rc = st.sendResponse()
  except CatchableError as e:
    # E.g. a header the handler set is invalid: nothing was sent yet.
    st.sink.log(NGX_LOG_ERR, "invalid response: " & e.msg & st.where)
    rc = NGX_HTTP_INTERNAL_SERVER_ERROR
  st.finish(rc)

proc complete(st: RpcState; fut: Future[void]) =
  if st.done or st.gone:
    return
  st.done = true
  if fut.failed:
    st.sink.log(NGX_LOG_ERR, "handler raised " & $fut.error.name & ": " &
      fut.error.msg & st.where)
    st.respondFresh(500, "internal")
  elif st.ctx.failure != nil:
    st.sink.log(NGX_LOG_ERR, "server function raised " &
      $st.ctx.failure.name & ": " & st.ctx.failure.msg & st.where)
  st.deliver()

proc timeout*(st: RpcState) =
  ## `isonim_rpc_timeout` expired before the handler completed.
  if st.done or st.gone:
    return
  st.done = true
  st.timedOut = true
  st.sink.log(NGX_LOG_ERR, "the handler did not complete within " &
    "isonim_rpc_timeout; responding 504" & st.where)
  st.respondFresh(504, "timeout")
  st.deliver()

proc release*(st: RpcState) =
  ## nginx released the request: nothing may touch it any more.
  st.gone = true

proc startRpc*(req: SsrRequest; appName: string; sink: ResponseSink;
               finish: proc(rc: NgxInt)): RpcState =
  ## The state of one request; `run` starts its handler.
  RpcState(ctx: newRequestContext(req), appName: appName, sink: sink,
           finish: finish)

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
  var fut: Future[void]
  try:
    fut = if st.app.isNil: dispatchRpc(st.ctx) else: st.app.handle(st.ctx)
  except CatchableError as e:
    fut = newFuture[void]("isonim rpc")
    fut.fail(e)
  fut.addCallback(proc() {.gcsafe.} =
    {.cast(gcsafe).}:
      st.complete(fut))
