## handler.nim
##
## The Nim side of the nginx content handler, and the root module of the
## shared object.
##
## `ngx_http_isonim_handler` (C) checks that the location is enabled,
## discards the request body and calls `nim_handle_request` with a view of
## the request and the location's configuration.  This module turns the view
## into an `SsrRequest`, looks the app up, and runs the shared pipeline
## (`serve.serve`) over a sink that calls back into the C helpers.
##
## Compiled with `-d:isNginxTest` the module instead provides
## `serveRecorded` / `serveMockRequest`: the same pipeline over a recording
## sink, so the unit tests exercise the code nginx runs.

import nginx_types
import config
import app_registry
import serve

export config, app_registry, serve

when defined(isNginxTest):
  type
    RecordedSend* = object
      ## One sendBody call.
      data*: string
      flush*: bool
      last*: bool

    RecordedResponse* = object
      ## Everything the pipeline handed to the (recording) sink.
      rc*: NgxInt
        ## What the content handler would return to nginx.
      headersSent*: bool
      status*: int
      contentType*: string
      contentLength*: int64
      headers*: seq[(string, string)]
      body*: string
        ## The concatenated body bytes that were sent.
      sends*: seq[RecordedSend]
      log*: seq[(NgxUint, string)]

    RecordingOptions* = object
      failBodySendAt*: int
        ## 1-based index of the sendBody call that fails as if the client
        ## had gone away (NGX_ERROR); 0 = never.

  proc serveRecorded*(req: SsrRequest; app: AppEntry; opts: ServeOptions;
                      recording = RecordingOptions()): RecordedResponse =
    ## Runs the pipeline over a sink that records what it is given and
    ## behaves as nginx does for HEAD, 204 and 304 (no body).
    var rec: RecordedResponse
    let recPtr = addr rec
    var sendCount = 0
    let sink = ResponseSink(
      sendHeader: proc(resp: SsrResponse; contentLength: int64): NgxInt =
        doAssert not recPtr.headersSent, "headers sent twice"
        recPtr.headersSent = true
        recPtr.status = resp.status
        recPtr.contentType = resp.contentType
        recPtr.contentLength = contentLength
        recPtr.headers = resp.wireHeaders
        if req.httpMethod == "HEAD" or resp.status in [204, 304]:
          NGX_DONE
        else:
          NGX_OK,
      sendBody: proc(data: openArray[char]; flush, last: bool): NgxInt =
        doAssert recPtr.headersSent, "body sent before the headers"
        inc sendCount
        if recording.failBodySendAt == sendCount:
          return NGX_ERROR
        var s = newString(data.len)
        if data.len > 0:
          copyMem(addr s[0], unsafeAddr data[0], data.len)
        recPtr.sends.add RecordedSend(data: s, flush: flush, last: last)
        recPtr.body.add s
        NGX_OK,
      log: proc(level: NgxUint; msg: string) =
        recPtr.log.add((level, msg)),
    )
    rec.rc = serve(req, app, opts, sink)
    rec

  proc toSsrRequest*(r: NgxHttpRequest): SsrRequest =
    ## The SsrRequest nim_handle_request would build from this request.
    let raw =
      if r.unparsedUri.len > 0: r.unparsedUri
      elif r.args.len > 0: r.uri & "?" & r.args
      else: r.uri
    newSsrRequest(r.httpMethod, r.uri, raw, r.args, r.headers, r.addrText)

  proc serveMockRequest*(conf: IsoNimLocConf; r: NgxHttpRequest;
                         recording = RecordingOptions()): RecordedResponse =
    ## What the module does for request `r` at a location configured as
    ## `conf`: look the app up by `isonim_ssr_app` and serve it.
    serveRecorded(toSsrRequest(r), lookupApp(conf.appName),
                  serveOptions(conf), recording)

else:
  # When compiled with --noMain --app:lib, the Nim runtime (GC, module init
  # code) is not initialized automatically.  NimMain() must run exactly once
  # before any Nim code; nim_module_init does that on the first request.
  import nginx_http_adapter
  import apps

  type
    RequestView {.bycopy.} = object
      ## Mirrors ngx_http_isonim_request_view_t (ngx_http_isonim_module.c).
      httpMethod: NgxStr
      uri: NgxStr
      args: NgxStr
      unparsedUri: NgxStr
      addrText: NgxStr
      headers: NgxListPart

  proc NimMain() {.importc.}

  proc nimModuleInit*() {.exportc: "nim_module_init", cdecl.} =
    ## Called once per worker, from C, before the first request.
    NimMain()
    registerDefaultApps()

  proc logTo(r: NgxHttpRequest; level: NgxUint; msg: string) =
    if msg.len > 0:
      ngx_http_isonim_log(r, level, unsafeAddr msg[0], csize_t(msg.len))

  proc nginxSink(r: NgxHttpRequest): ResponseSink =
    ResponseSink(
      sendHeader: proc(resp: SsrResponse; contentLength: int64): NgxInt =
        let wire = resp.wireHeaders
        var hdrs = newSeq[NgxIsonimHeader](wire.len)
        for i in 0 ..< wire.len:
          # Point into `wire` itself, which outlives the C call; the C
          # side copies into the request pool.  (A `for (k, v) in wire`
          # loop would hand out addresses of per-iteration copies.)
          # Names are validated non-empty tokens; an empty value goes
          # as a nil pointer with length 0.
          hdrs[i] = NgxIsonimHeader(
            key: unsafeAddr wire[i][0][0], keyLen: csize_t(wire[i][0].len),
            value: (if wire[i][1].len > 0: unsafeAddr wire[i][1][0] else: nil),
            valueLen: csize_t(wire[i][1].len))
        let ct = resp.contentType
        ngx_http_isonim_send_header(r, NgxUint(resp.status),
          unsafeAddr ct[0], csize_t(ct.len), contentLength,
          (if hdrs.len > 0: addr hdrs[0] else: nil), NgxUint(hdrs.len)),
      sendBody: proc(data: openArray[char]; flush, last: bool): NgxInt =
        ngx_http_isonim_send_body(r,
          (if data.len > 0: unsafeAddr data[0] else: nil),
          csize_t(data.len), NgxInt(ord(flush)), NgxInt(ord(last))),
      log: proc(level: NgxUint; msg: string) =
        logTo(r, level, msg),
    )

  proc buildRequest(view: ptr RequestView): SsrRequest =
    var headers: seq[(string, string)]
    for (k, v) in walkHeaders(view.headers):
      headers.add((ngxStrToString(k), ngxStrToString(v)))
    newSsrRequest(
      httpMethod = ngxStrToString(view.httpMethod),
      path = ngxStrToString(view.uri),
      rawUri = ngxStrToString(view.unparsedUri),
      query = ngxStrToString(view.args),
      headers = headers,
      clientAddr = ngxStrToString(view.addrText))

  proc nimHandleRequest*(r: NgxHttpRequest; view: ptr RequestView;
                         viewSize: csize_t;
                         appName: ptr char; appNameLen: csize_t;
                         hydration: NgxInt; buffered: NgxInt;
                         maxBufferSize: csize_t): NgxInt
      {.exportc: "nim_handle_request", cdecl.} =
    ## Called by the C content handler for every request at an enabled
    ## location.  Returns what the handler returns to nginx.
    if viewSize != csize_t(sizeof(RequestView)):
      logTo(r, NGX_LOG_ERR, "request view size mismatch between C (" &
        $viewSize & ") and Nim (" & $sizeof(RequestView) & ")")
      return NGX_HTTP_INTERNAL_SERVER_ERROR
    # Nothing may escape into nginx's C frames.  serve() handles every
    # CatchableError itself; this catches what is left (a Defect in a
    # debug build, e.g. an index error in an app) so one bad request
    # cannot take the worker down with it.
    try:
      var name = newString(int(appNameLen))
      if appNameLen > 0:
        copyMem(addr name[0], appName, int(appNameLen))
      let opts = ServeOptions(
        appName: name,
        hydration: hydration != 0,
        mode: if buffered != 0: tmBuffered else: tmStreaming,
        maxBufferSize: int(maxBufferSize))
      serve(buildRequest(view), lookupApp(name), opts, nginxSink(r))
    except Exception as e:
      logTo(r, NGX_LOG_ERR, "unhandled " & $e.name & ": " & e.msg)
      NGX_ERROR
