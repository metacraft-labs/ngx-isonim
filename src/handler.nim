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

when not defined(isNginxTest):
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

when not defined(isNginxTest):
  ## Real nginx entry point. Exported as C function for the nginx module.
  proc nimHandleRequest*(req: NgxHttpRequest): NgxInt {.exportc, cdecl.} =
    ## Called by nginx for configured routes.
    ## In a real deployment, this would:
    ## 1. Extract request info from ngx_http_request_t
    ## 2. Look up the app renderer from module config
    ## 3. Create an nginx-backed OutputStream
    ## 4. Call handleSsrRequest or handleStreamingSsrRequest
    ## 5. Return the appropriate nginx status code
    return NGX_OK
