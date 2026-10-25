## serve.nim
##
## The request pipeline shared by the nginx module and its unit tests.
##
## `serve` takes one request, the app selected for its location, the
## location's options and a `ResponseSink` (the three operations that touch
## nginx: send the status and headers, send body bytes, log), and:
##
## 1. accepts only `GET` and `HEAD` (`405` otherwise);
## 2. runs the renderer with the request and a fresh `SsrResponse`;
## 3. appends the hydration bootstrap script carrying the response's CSP
##    nonce (when `isonim_ssr_hydration` is on);
## 4. enforces `isonim_ssr_max_buffer_size` on the body;
## 5. sends the response over the location's transport:
##    * **streaming**: the status and headers go out on the renderer's first
##      flush (or when it returns), every flush is sent at once with nginx's
##      `flush` flag, and the last buffer ends the chunked body;
##    * **buffered**: nothing is sent until the renderer returns; then the
##      status, the headers and `Content-Length`, and the body in one buffer.
##
## What the client sees when something fails:
##
## | Failure | Nothing sent yet | Headers already sent |
## | :--- | :--- | :--- |
## | renderer raises | `500` | connection closed, body truncated, logged |
## | body over the limit | `500`, logged | connection closed, body truncated, logged |
## | client gone (send failed) | — | request terminated, logged at info |
##
## `serve` returns what the nginx content handler must return: `NGX_OK` (or
## `NGX_AGAIN` while nginx still holds unsent bytes), `NGX_ERROR` to drop the
## connection, or an HTTP status for nginx to answer with its own error page.
##
## The transport itself (`Transport`: the pending bytes, the size limit, the
## commit point, `flush` and `endBody`) is exported: rpc.nim streams an async
## app's response through the same one, so both kinds of location put the
## same bytes and buffer flags on nginx's output chain.

import nginx_types, config, app_registry
import isonim/ssr/markers

type
  ServeOptions* = object
    ## The location configuration `serve` needs.
    appName*: string
    hydration*: bool
    mode*: TransportMode
    maxBufferSize*: int   ## bytes; 0 = unlimited

  ResponseSink* = object
    ## The transport's view of nginx.
    sendHeader*: proc(resp: SsrResponse; contentLength: int64): NgxInt
      ## Sends the status line and headers.  `contentLength < 0` means
      ## unknown (chunked).  Returns NGX_OK (or NGX_AGAIN), NGX_DONE when
      ## the response must have no body (HEAD, 204, 304), or NGX_ERROR /
      ## a status code on failure.
    sendBody*: proc(data: openArray[char]; flush, last: bool): NgxInt
      ## Passes bytes down the output filter chain.  NGX_ERROR means the
      ## connection is gone.
    log*: proc(level: NgxUint; msg: string)

  Transport* = ref object
    ## One response on its way to nginx: the body bytes accepted and not
    ## yet passed down, the size limit, and the commit point.  `serve` (SSR
    ## renderers) and rpc.nim (streaming async apps) drive the same one.
    resp: SsrResponse
    opts: ServeOptions
    sink: ResponseSink
    pending: string      ## accepted, not yet passed to nginx
    total: int           ## body bytes accepted so far
    headersSent: bool
    headerOnly: bool     ## nginx said: no body for this response
    lastRc*: NgxInt
      ## What nginx last answered (NGX_OK, or NGX_AGAIN while it holds
      ## unsent bytes).

proc hydrationScript*(nonce: string): string =
  ## The bootstrap script that records events until the client runtime
  ## hydrates (IsoNim's `generateHydrationScript`, the one its `hydrate`
  ## reads and replays), carrying this response's CSP nonce.
  generateHydrationScript(nonce = nonce)

proc newTransport*(resp: SsrResponse; opts: ServeOptions;
                   sink: ResponseSink): Transport =
  Transport(resp: resp, opts: opts, sink: sink, lastRc: NGX_OK)

proc committed*(t: Transport): bool =
  ## The status and headers were sent.
  t.headersSent

proc bodyBytes*(t: Transport): int =
  ## Body bytes accepted so far (what `isonim_ssr_max_buffer_size` bounds).
  t.total

proc restart*(t: Transport; resp: SsrResponse) =
  ## Drops everything accepted and starts over with `resp`; only before the
  ## commit point (a framework error replacing what a handler shaped).
  doAssert not t.headersSent, "restart after the commit point"
  t.resp = resp
  t.pending.setLen(0)
  t.total = 0

proc useResponse*(t: Transport; resp: SsrResponse) =
  ## The response whose status and headers the commit sends, when the
  ## handler replaced its context's (before the commit point only).
  if not t.headersSent:
    t.resp = resp

proc commit(t: Transport; contentLength: int64) =
  ## Sends the status and headers.  Called once, before the first body byte.
  t.resp.markCommitted()
  t.headersSent = true
  let rc = t.sink.sendHeader(t.resp, contentLength)
  if rc == NGX_DONE:
    t.headerOnly = true
    t.pending.setLen(0)
  elif rc == NGX_ERROR or rc > NGX_OK:
    raise newException(ClientConnectionError,
      "sending the response header failed (rc " & $rc & ")")
  else:
    t.lastRc = rc

proc send(t: Transport; flush, last: bool) =
  if t.headerOnly:
    t.pending.setLen(0)
    return
  let rc =
    if t.pending.len > 0:
      t.sink.sendBody(t.pending.toOpenArray(0, t.pending.high), flush, last)
    else:
      var empty: array[0, char]
      t.sink.sendBody(empty, flush, last)
  t.pending.setLen(0)
  if rc == NGX_ERROR:
    raise newException(ClientConnectionError,
      "sending the response body failed; the client connection is gone")
  t.lastRc = rc

proc write*(t: Transport; data: openArray[char]) =
  ## Accepts body bytes; they reach nginx on the next `flush` or `endBody`.
  if t.resp.isRedirect:
    raise newException(ValueError,
      "the response is a redirect to " & t.resp.location &
      "; a redirect carries no body")
  if t.opts.maxBufferSize > 0 and
      t.total + data.len > t.opts.maxBufferSize:
    raise newException(ResponseTooLargeError,
      "the response body exceeds isonim_ssr_max_buffer_size (" &
      $t.opts.maxBufferSize & " bytes)")
  t.total += data.len
  if not t.headerOnly and data.len > 0:
    let old = t.pending.len
    t.pending.setLen(old + data.len)
    copyMem(addr t.pending[old], unsafeAddr data[0], data.len)

proc flush*(t: Transport) =
  ## Streaming transport: commits the response (chunked) on the first call,
  ## then passes what is pending to nginx with its `flush` flag.  Buffered:
  ## nothing.
  if t.opts.mode == tmBuffered:
    return
  if not t.headersSent:
    t.commit(if t.resp.isRedirect: 0 else: -1)
  if t.pending.len > 0:
    t.send(flush = true, last = false)

proc endBody*(t: Transport; whole: bool) =
  ## Ends the response with nginx's last buffer.  A response not committed
  ## yet goes out with `Content-Length` when `whole`, chunked otherwise; a
  ## redirect goes out with no body.
  if t.resp.isRedirect:
    t.pending.setLen(0)
    if not t.headersSent:
      t.commit(0)
    t.send(flush = false, last = true)
    return
  let wasCommitted = t.headersSent
  if not t.headersSent:
    t.commit(if whole: int64(t.pending.len) else: -1)
  t.send(flush = t.opts.mode == tmStreaming and (wasCommitted or not whole),
         last = true)

proc finish(t: Transport) =
  ## The renderer returned: hydration script, then the end of the body.
  if t.opts.hydration and not t.resp.isRedirect:
    let script = hydrationScript(t.resp.cspNonce)
    t.write(script.toOpenArray(0, script.high))
  t.endBody(whole = t.opts.mode == tmBuffered)

proc serve*(req: SsrRequest; app: AppEntry; opts: ServeOptions;
            sink: ResponseSink): NgxInt =
  ## Handles one request.  See the module documentation.
  if req.httpMethod notin ["GET", "HEAD"]:
    return NGX_HTTP_NOT_ALLOWED

  if app.isNil:
    sink.log(NGX_LOG_ERR, "no app is registered as \"" & opts.appName &
      "\" (isonim_ssr_app)")
    return NGX_HTTP_INTERNAL_SERVER_ERROR

  if app.kind == akAsync:
    sink.log(NGX_LOG_ERR, "app \"" & opts.appName & "\" is an async app; " &
      "serve it at an isonim_rpc location (isonim_rpc_app)")
    return NGX_HTTP_INTERNAL_SERVER_ERROR

  let resp = newSsrResponse()
  let st = newTransport(resp, opts, sink)
  let body = newResponseBody(
    proc(data: openArray[char]) = st.write(data),
    proc() = st.flush())

  try:
    case app.kind
    of akString:
      let html = app.render(req, resp)
      if not resp.isRedirect:
        st.write(html.toOpenArray(0, html.high))
    of akStreaming:
      app.renderStream(req, resp, body)
    of akAsync:
      discard   # refused above
    st.finish()
    return st.lastRc
  except CatchableError as e:
    # A write through the faststreams view surfaces as IOError; the
    # original error is kept on the body.
    let cause: ref CatchableError = if body.failure != nil: body.failure else: e
    let where = " (app \"" & opts.appName & "\", " & req.httpMethod & " " &
      req.rawUri & ")"
    if cause of ClientConnectionError:
      sink.log(NGX_LOG_INFO, cause.msg & where)
      return NGX_ERROR
    let outcome =
      if st.headersSent: "; response terminated after the headers were sent"
      else: "; responding 500"
    if cause of ResponseTooLargeError:
      sink.log(NGX_LOG_ERR, cause.msg & where & outcome)
    else:
      sink.log(NGX_LOG_ERR, "renderer raised " & $cause.name & ": " &
        cause.msg & where & outcome)
    return if st.headersSent: NGX_ERROR else: NGX_HTTP_INTERNAL_SERVER_ERROR

proc serveOptions*(conf: IsoNimLocConf): ServeOptions =
  ServeOptions(appName: conf.appName, hydration: conf.hydrationEnabled,
               mode: conf.mode, maxBufferSize: conf.maxBufferSize)
