## handler.nim
##
## nginx content handler and module registration.
## This file is compiled as part of the nginx module .so.
##
## The handler is called by nginx for configured routes. It runs
## renderToString and writes the output through the nginx output
## chain via the OutputStream abstraction.

import nginx_types
import config
import nginx_adapter

type
  AppRenderer* = proc(): string
    ## Application render function. Returns the HTML string for the page.

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

proc handleSsrRequest*(conf: IsoNimLocConf; reqInfo: RequestInfo;
    app: AppRenderer): HandlerResult =
  ## Core SSR handler logic, independent of nginx.
  ## This is testable without nginx headers.
  ##
  ## 1. Validates configuration
  ## 2. Calls the app renderer
  ## 3. Optionally appends hydration script placeholder
  ## 4. Returns the complete response
  if not conf.isValid():
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: invalid configuration",
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

  result = HandlerResult(
    statusCode: NGX_HTTP_OK.int,
    headers: @[
      ("Content-Type", "text/html; charset=utf-8"),
    ],
    body: html,
    chunks: @[html],
  )

proc handleStreamingSsrRequest*(conf: IsoNimLocConf; reqInfo: RequestInfo;
    app: AppRenderer;
    onChunk: proc(chunk: string)): HandlerResult =
  ## Streaming SSR handler. Renders the app and calls onChunk for each
  ## piece of output. This simulates what the real nginx handler would
  ## do: write each chunk to an ngx_buf_t and flush via output_filter.
  if not conf.isValid():
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: invalid configuration",
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

when defined(isNginxTest):
  ## Test-mode entry point.  Mirrors the production nimHandleRequest but
  ## works with MockRequest and the test-mode NginxOutputStream.
  ##
  ## The test-mode version extracts URI, method, and headers from the
  ## mock request, builds an IsoNimLocConf, and runs the SSR handler.
  ## It also creates an NginxOutputStream so tests can verify the
  ## output-chain lifecycle.

  var
    testAppRenderer*: AppRenderer = nil
      ## Tests inject the app renderer here before calling nimHandleRequest.
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
    ## 1. Extract request info from the mock request
    ## 2. Look up app name from testLocConf
    ## 3. Create an NginxOutputStream from the mock request
    ## 4. Run the SSR handler
    ## 5. Write output through the stream and flush
    ## 6. Return NGX_OK or the appropriate error code
    let reqInfo = extractRequestInfo(r)

    if testAppRenderer == nil:
      return NGX_ERROR

    let conf = testLocConf
    let res = handleSsrRequest(conf, reqInfo, testAppRenderer)
    lastHandlerResult = res

    if res.statusCode != NGX_HTTP_OK.int:
      return NgxInt(res.statusCode)

    # Create an output stream and write the response body through it.
    let stream = newNginxOutputStream(r)
    resetMockState()  # Clear mock counters before our writes.

    stream.write(res.body)
    stream.flush()
    stream.close()

    return NGX_OK

else:
  ## Real nginx entry point. Exported as C function for the nginx module.
  proc nimHandleRequest*(req: NgxHttpRequest): NgxInt
      {.exportc: "nim_handle_request", cdecl.} =
    ## Called by nginx for configured routes.
    ## In a real deployment, this would:
    ## 1. Extract request info from ngx_http_request_t
    ## 2. Look up the app renderer from module config
    ## 3. Create an nginx-backed OutputStream
    ## 4. Call handleSsrRequest or handleStreamingSsrRequest
    ## 5. Return the appropriate nginx status code
    return NGX_OK
