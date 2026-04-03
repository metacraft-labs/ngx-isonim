## handler.nim
##
## nginx content handler and module registration.
## This file is compiled as part of the nginx module .so.
##
## The handler is called by nginx for configured routes. It runs
## renderToString and writes the output through the nginx output
## chain via the OutputStream abstraction.
##
## M3 flow:
##   1. Validate HTTP method (GET/HEAD only, else 405)
##   2. Validate configuration
##   3. Look up app renderer by name from config
##   4. Call the app renderer to get HTML
##   5. Optionally append hydration script
##   6. Set Content-Type and Content-Length headers
##   7. For HEAD requests, return headers only (no body)
##   8. Write body via the adapter
##   9. Return appropriate status code

import std/times
import nginx_types
import config
import nginx_adapter
import app_registry

type
  RequestInfo* = object
    ## Extracted request information passed to the app.
    uri*: string
    httpMethod*: string
    headers*: seq[(string, string)]

  HandlerResult* = object
    ## Result of handling a request.
    statusCode*: int
    headers*: seq[(string, string)]
    body*: string
    chunks*: seq[string]

  StreamingMetrics* = object
    ## Timing and size metrics for streaming SSR responses.
    ttfbMs*: float   ## Time from request start to first flush
    totalMs*: float  ## Time from request start to close
    chunkCount*: int ## Number of chunks emitted
    totalBytes*: int ## Total bytes across all chunks

proc handleSsrRequest*(conf: IsoNimLocConf; reqInfo: RequestInfo;
    app: AppRenderer): HandlerResult =
  ## Core SSR handler logic, independent of nginx.
  ## This is testable without nginx headers.
  ##
  ## 1. Validates HTTP method
  ## 2. Validates configuration
  ## 3. Calls the app renderer
  ## 4. Optionally appends hydration script placeholder
  ## 5. Sets Content-Type and Content-Length headers
  ## 6. For HEAD requests, headers only (empty body)
  ## 7. Returns the complete response

  # Method validation: only GET and HEAD allowed
  if reqInfo.httpMethod notin ["GET", "HEAD"]:
    return HandlerResult(
      statusCode: NGX_HTTP_NOT_ALLOWED.int,
      body: "Method Not Allowed",
    )

  if not conf.isValid():
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: invalid configuration",
    )

  if app == nil:
    return HandlerResult(
      statusCode: NGX_HTTP_NOT_FOUND.int,
      body: "IsoNim SSR: app not found",
    )

  var html: string
  try:
    html = app()
  except CatchableError:
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: render error",
    )

  # Append hydration script if enabled
  if conf.hydrationEnabled:
    var script = "<script"
    if conf.scriptNonce.len > 0:
      script.add " nonce=\"" & conf.scriptNonce & "\""
    script.add ">window._$HY={events:[\"click\",\"input\"],completed:new WeakSet,registry:new Map};</script>"
    html = html & script

  let isHead = reqInfo.httpMethod == "HEAD"
  let responseBody = if isHead: "" else: html

  result = HandlerResult(
    statusCode: NGX_HTTP_OK.int,
    headers: @[
      ("Content-Type", "text/html; charset=utf-8"),
      ("Content-Length", $html.len),
    ],
    body: responseBody,
    chunks: if isHead: @[] else: @[html],
  )

proc handleStreamingSsrRequest*(conf: IsoNimLocConf; reqInfo: RequestInfo;
    app: AppRenderer;
    onChunk: proc(chunk: string)): HandlerResult =
  ## Streaming SSR handler. Renders the app and calls onChunk for each
  ## piece of output. This simulates what the real nginx handler would
  ## do: write each chunk to an ngx_buf_t and flush via output_filter.
  if reqInfo.httpMethod notin ["GET", "HEAD"]:
    return HandlerResult(
      statusCode: NGX_HTTP_NOT_ALLOWED.int,
      body: "Method Not Allowed",
    )

  if not conf.isValid():
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: invalid configuration",
    )

  if app == nil:
    return HandlerResult(
      statusCode: NGX_HTTP_NOT_FOUND.int,
      body: "IsoNim SSR: app not found",
    )

  var chunks: seq[string] = @[]

  var html: string
  try:
    html = app()
  except CatchableError:
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: render error",
    )

  # Emit the rendered HTML as a chunk
  chunks.add(html)
  onChunk(html)

  # Append hydration script if enabled
  if conf.hydrationEnabled:
    var script = "<script"
    if conf.scriptNonce.len > 0:
      script.add " nonce=\"" & conf.scriptNonce & "\""
    script.add ">window._$HY={events:[\"click\",\"input\"],completed:new WeakSet,registry:new Map};</script>"
    chunks.add(script)
    onChunk(script)
    html = html & script

  result = HandlerResult(
    statusCode: NGX_HTTP_OK.int,
    headers: @[
      ("Content-Type", "text/html; charset=utf-8"),
    ],
    body: html,
    chunks: chunks,
  )

proc handleStreamingRequest*(conf: IsoNimLocConf; reqInfo: RequestInfo;
    stream: NginxOutputStream;
    streamingApp: StreamingAppRenderer): tuple[result: HandlerResult, metrics: StreamingMetrics] =
  ## Streaming SSR handler.
  ## 1. Validates config, looks up streaming app
  ## 2. Sets Transfer-Encoding: chunked
  ## 3. Flushes shell HTML immediately (TTFB)
  ## 4. Each Suspense boundary resolution flushes a replacement script chunk
  ## 5. Hydration script appended after all boundaries resolve
  ## 6. Close stream

  let startTime = cpuTime()
  var metrics = StreamingMetrics()
  var firstChunkFlushed = false

  # Method validation: only GET and HEAD allowed
  if reqInfo.httpMethod notin ["GET", "HEAD"]:
    let elapsed = (cpuTime() - startTime) * 1000.0
    metrics.totalMs = elapsed
    return (
      result: HandlerResult(
        statusCode: NGX_HTTP_NOT_ALLOWED.int,
        body: "Method Not Allowed",
      ),
      metrics: metrics,
    )

  if not conf.isValid():
    let elapsed = (cpuTime() - startTime) * 1000.0
    metrics.totalMs = elapsed
    return (
      result: HandlerResult(
        statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
        body: "IsoNim SSR: invalid configuration",
      ),
      metrics: metrics,
    )

  if streamingApp == nil:
    let elapsed = (cpuTime() - startTime) * 1000.0
    metrics.totalMs = elapsed
    return (
      result: HandlerResult(
        statusCode: NGX_HTTP_NOT_FOUND.int,
        body: "IsoNim SSR: app not found",
      ),
      metrics: metrics,
    )

  let isHead = reqInfo.httpMethod == "HEAD"
  var chunks: seq[string] = @[]
  var totalBody = ""
  var hadError = false

  proc onChunk(chunk: string) =
    chunks.add(chunk)
    totalBody.add(chunk)
    metrics.chunkCount += 1
    metrics.totalBytes += chunk.len

    if not isHead:
      try:
        stream.write(chunk)
        stream.flush()
      except CatchableError:
        hadError = true

    if not firstChunkFlushed:
      metrics.ttfbMs = (cpuTime() - startTime) * 1000.0
      firstChunkFlushed = true

  var completed = false
  proc onComplete() =
    completed = true

  try:
    streamingApp(onChunk, onComplete)
  except CatchableError:
    if chunks.len == 0:
      # Error during shell render — no chunks sent yet
      let elapsed = (cpuTime() - startTime) * 1000.0
      metrics.totalMs = elapsed
      return (
        result: HandlerResult(
          statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
          body: "IsoNim SSR: render error",
        ),
        metrics: metrics,
      )
    else:
      # Error during boundary resolution — partial result + error chunk
      let errorChunk = "<script>console.error('IsoNim SSR: streaming error during boundary resolution')</script>"
      chunks.add(errorChunk)
      totalBody.add(errorChunk)
      metrics.chunkCount += 1
      metrics.totalBytes += errorChunk.len
      if not isHead:
        try:
          stream.write(errorChunk)
          stream.flush()
        except CatchableError:
          discard

  # Append hydration script if enabled and we had at least one chunk
  if conf.hydrationEnabled and chunks.len > 0:
    var script = "<script"
    if conf.scriptNonce.len > 0:
      script.add " nonce=\"" & conf.scriptNonce & "\""
    script.add ">window._$HY={events:[\"click\",\"input\"],completed:new WeakSet,registry:new Map};</script>"
    chunks.add(script)
    totalBody.add(script)
    metrics.chunkCount += 1
    metrics.totalBytes += script.len
    if not isHead:
      try:
        stream.write(script)
        stream.flush()
      except CatchableError:
        discard

  # Close the stream
  if not isHead:
    try:
      stream.close()
    except CatchableError:
      discard

  metrics.totalMs = (cpuTime() - startTime) * 1000.0

  let headers = @[
    ("Content-Type", "text/html; charset=utf-8"),
    ("Transfer-Encoding", "chunked"),
  ]

  return (
    result: HandlerResult(
      statusCode: NGX_HTTP_OK.int,
      headers: headers,
      body: if isHead: "" else: totalBody,
      chunks: if isHead: @[] else: chunks,
    ),
    metrics: metrics,
  )

when defined(isNginxTest):
  ## Test-mode entry point.  Mirrors the production nimHandleRequest but
  ## works with MockRequest and the test-mode NginxOutputStream.
  ##
  ## The test-mode version extracts URI, method, and headers from the
  ## mock request, builds an IsoNimLocConf, and runs the SSR handler.
  ## It also creates an NginxOutputStream so tests can verify the
  ## output-chain lifecycle.

  var
    testLocConf*: IsoNimLocConf = defaultLocConf()
      ## Tests inject the location config here.
    lastHandlerResult*: HandlerResult
      ## After nimHandleRequest runs, the result is stored here for assertions.

  proc extractRequestInfo*(r: NgxHttpRequest): RequestInfo =
    ## Extract URI, method, and headers from a mock request.
    RequestInfo(
      uri: r.uri,
      httpMethod: r.httpMethod,
      headers: r.headers,
    )

  proc nimHandleRequest*(r: NgxHttpRequest): NgxInt
      {.exportc: "nim_handle_request", cdecl.} =
    ## Called from the C module handler (test mode).
    ##
    ## M3 flow:
    ## 1. Extract request info from the mock request
    ## 2. Validate HTTP method
    ## 3. Look up app renderer by name from testLocConf
    ## 4. Create an NginxOutputStream from the mock request
    ## 5. Run the SSR handler
    ## 6. Write output through the stream and flush
    ## 7. Return NGX_OK or the appropriate error code
    let reqInfo = extractRequestInfo(r)
    let conf = testLocConf

    # Look up app by name from the registry
    let app = getApp(conf.appName)

    let res = handleSsrRequest(conf, reqInfo, app)
    lastHandlerResult = res

    if res.statusCode != NGX_HTTP_OK.int:
      return NgxInt(res.statusCode)

    # For HEAD requests, skip body writing
    if res.body.len == 0:
      return NGX_OK

    # Create an output stream and write the response body through it.
    let stream = newNginxOutputStream(r)
    resetMockState()  # Clear mock counters before our writes.

    stream.write(res.body)
    stream.flush()
    stream.close()

    return NGX_OK

else:
  ## Real nginx entry points. The C handler calls nim_render_app to get
  ## the rendered HTML, then handles all nginx response plumbing in C.
  ## This avoids complex FFI with opaque nginx structs from Nim.

  # When compiled with --noMain --app:lib, the Nim runtime (GC, module
  # init code) is not automatically initialized. NimMain() must be called
  # exactly once before any Nim code runs. It's generated by the compiler.
  proc NimMain() {.importc.}

  proc nimModuleInit*() {.exportc: "nim_module_init", cdecl.} =
    ## Called once from C before the first request.
    ## Initializes the Nim runtime and registers default apps.
    NimMain()
    registerApp("hello", proc(): string =
      "<html><body><h1>Hello from IsoNim</h1></body></html>"
    )

  proc nimRenderApp*(appName: cstring, appNameLen: cint,
                    hydration: cint,
                    nonce: cstring, nonceLen: cint,
                    outHtml: ptr cstring, outLen: ptr cint): NgxInt
      {.exportc: "nim_render_app", cdecl.} =
    ## Render an app by name and return the HTML via out-parameters.
    ## The C caller is responsible for freeing *outHtml via nimFreeHtml.
    ##
    ## Parameters:
    ##   appName/appNameLen — app name from nginx config (not null-terminated)
    ##   hydration — 1 to append hydration script, 0 to skip
    ##   nonce/nonceLen — CSP script nonce (may be NULL/0)
    ##   outHtml/outLen — output: allocated HTML buffer and its length
    ##
    ## Returns NGX_OK on success, NGX_ERROR on failure.

    # Build a Nim string from the (data, len) pair.
    var name: string
    if appNameLen > 0 and appName != nil:
      name = newString(appNameLen)
      copyMem(addr name[0], appName, appNameLen)
    else:
      name = ""

    # Look up the app renderer.
    let app = getApp(name)
    if app == nil:
      return NGX_ERROR

    # Render the app.
    var html: string
    try:
      html = app()
    except CatchableError:
      return NGX_ERROR

    # Append hydration script if enabled.
    if hydration != 0:
      var script = "<script"
      if nonceLen > 0 and nonce != nil:
        var nonceStr = newString(nonceLen)
        copyMem(addr nonceStr[0], nonce, nonceLen)
        script.add " nonce=\"" & nonceStr & "\""
      script.add ">window._$HY={events:[\"click\",\"input\"],completed:new WeakSet,registry:new Map};</script>"
      html.add(script)

    # Allocate a C-compatible buffer for the response.
    # The C side frees it via nim_free_html.
    let buf = cast[cstring](alloc(html.len + 1))
    if html.len > 0:
      copyMem(buf, addr html[0], html.len)
    cast[ptr char](cast[uint](buf) + html.len.uint)[] = '\0'

    outHtml[] = buf
    outLen[] = html.len.cint
    return NGX_OK

  proc nimFreeHtml*(html: cstring) {.exportc: "nim_free_html", cdecl.} =
    ## Free an HTML buffer previously returned by nimRenderApp.
    if html != nil:
      dealloc(html)
