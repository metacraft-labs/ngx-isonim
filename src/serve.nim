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

import nginx_types, config, app_registry

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

  ServeState = ref object
    req: SsrRequest
    resp: SsrResponse
    opts: ServeOptions
    sink: ResponseSink
    pending: string      ## accepted, not yet passed to nginx
    total: int           ## body bytes accepted so far
    headersSent: bool
    headerOnly: bool     ## nginx said: no body for this response
    lastRc: NgxInt

proc hydrationScript*(nonce: string): string =
  ## The bootstrap script that records events until the client runtime
  ## hydrates, carrying this response's CSP nonce.
  "<script nonce=\"" & nonce & "\">window._$HY={events:[\"click\",\"input\"]," &
    "completed:new WeakSet,registry:new Map};</script>"

proc commit(st: ServeState; contentLength: int64) =
  ## Sends the status and headers.  Called once, before the first body byte.
  st.resp.markCommitted()
  st.headersSent = true
  let rc = st.sink.sendHeader(st.resp, contentLength)
  if rc == NGX_DONE:
    st.headerOnly = true
    st.pending.setLen(0)
  elif rc == NGX_ERROR or rc > NGX_OK:
    raise newException(ClientConnectionError,
      "sending the response header failed (rc " & $rc & ")")
  else:
    st.lastRc = rc

proc send(st: ServeState; flush, last: bool) =
  if st.headerOnly:
    st.pending.setLen(0)
    return
  let rc =
    if st.pending.len > 0:
      st.sink.sendBody(st.pending.toOpenArray(0, st.pending.high), flush, last)
    else:
      var empty: array[0, char]
      st.sink.sendBody(empty, flush, last)
  st.pending.setLen(0)
  if rc == NGX_ERROR:
    raise newException(ClientConnectionError,
      "sending the response body failed; the client connection is gone")
  st.lastRc = rc

proc write(st: ServeState; data: openArray[char]) =
  if st.resp.isRedirect:
    raise newException(ValueError,
      "the response is a redirect to " & st.resp.location &
      "; a redirect carries no body")
  if st.opts.maxBufferSize > 0 and
      st.total + data.len > st.opts.maxBufferSize:
    raise newException(ResponseTooLargeError,
      "the response body exceeds isonim_ssr_max_buffer_size (" &
      $st.opts.maxBufferSize & " bytes)")
  st.total += data.len
  if not st.headerOnly and data.len > 0:
    let old = st.pending.len
    st.pending.setLen(old + data.len)
    copyMem(addr st.pending[old], unsafeAddr data[0], data.len)

proc flush(st: ServeState) =
  if st.opts.mode == tmBuffered:
    return
  if not st.headersSent:
    st.commit(if st.resp.isRedirect: 0 else: -1)
  if st.pending.len > 0:
    st.send(flush = true, last = false)

proc finish(st: ServeState) =
  ## The renderer returned: hydration script, then the end of the body.
  if st.resp.isRedirect:
    st.pending.setLen(0)
    if not st.headersSent:
      st.commit(0)
    st.send(flush = false, last = true)
    return
  if st.opts.hydration:
    let script = hydrationScript(st.resp.cspNonce)
    st.write(script.toOpenArray(0, script.high))
  if not st.headersSent:
    st.commit(if st.opts.mode == tmBuffered: int64(st.pending.len) else: -1)
  st.send(flush = st.opts.mode == tmStreaming, last = true)

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

  let st = ServeState(req: req, resp: newSsrResponse(), opts: opts,
                      sink: sink, lastRc: NGX_OK)
  let body = newResponseBody(
    proc(data: openArray[char]) = st.write(data),
    proc() = st.flush())

  try:
    case app.kind
    of akString:
      let html = app.render(req, st.resp)
      if not st.resp.isRedirect:
        st.write(html.toOpenArray(0, html.high))
    of akStreaming:
      app.renderStream(req, st.resp, body)
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
