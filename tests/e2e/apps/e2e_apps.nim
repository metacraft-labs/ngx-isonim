## e2e_apps.nim
##
## Apps compiled into the module for the end-to-end tests (built with
## `-d:ngxIsonimTestApps`, see src/apps.nim).  Each is driven over real
## nginx by a test under tests/e2e/.
##
## * `echo`, `echo_stream`: report the request they received and shape the
##   response from query parameters (test_request_context.nim).
## * `routed`: per-request routing through IsoNim's SSR router.
## * `csp`: a CSP header carrying the response's nonce (test_csp_nonce.nim).
## * `suspense`: IsoNim Suspense streaming with a deferred boundary
##   (test_streaming_debug.sh).
## * `sized`: a body of a requested size, written in flushed 1 KiB parts
##   (test_max_buffer_size.nim).
## * `async_dashboard`, `boom`: the legacy streaming fixture and a renderer
##   that raises (test_e2e.sh).

import std/[json, base64, strutils, monotimes, times]
import ../../../src/app_registry
import ../../../src/ssr_router
import isonim/ssr/streaming
import async_app

proc echoJson(req: SsrRequest): string =
  ## The request as the renderer saw it.
  var headers = newJArray()
  for (k, v) in req.headers:
    headers.add %*[k, v]
  var cookies = newJArray()
  for (k, v) in req.cookies:
    cookies.add %*[k, v]
  var params = newJArray()
  for (k, v) in req.queryParams:
    params.add %*[k, v]
  $(%*{
    "method": req.httpMethod,
    "path": req.path,
    "rawUri": req.rawUri,
    "query": req.query,
    "host": req.host,
    "clientAddr": req.clientAddr,
    "headers": headers,
    "cookies": cookies,
    "queryParams": params,
  })

proc shape(req: SsrRequest; resp: SsrResponse) =
  ## Applies the shaping the query asks for:
  ##   status=NNN                    status code
  ##   header=Name:Value (repeat)    addHeader
  ##   cookie=name=value (repeat)    setCookie, Path=/; HttpOnly; SameSite=Lax
  ##   content_type=...              content type
  ##   redirect=URL[&redirect_status=NNN]
  for (k, v) in req.queryParams:
    case k
    of "status":
      resp.status = parseInt(v)
    of "header":
      let colon = v.find(':')
      resp.addHeader(v[0 ..< colon], v[colon + 1 .. ^1])
    of "cookie":
      let eq = v.find('=')
      resp.setCookie(v[0 ..< eq], v[eq + 1 .. ^1],
        CookieOptions(path: "/", httpOnly: true, sameSite: sameSiteLax))
    of "content_type":
      resp.contentType = v
    else:
      discard
  if req.hasQueryParam("redirect"):
    resp.redirect(req.queryParam("redirect"),
                  parseInt(req.queryParam("redirect_status", "302")))

proc echoPage(req: SsrRequest): string =
  "<html><body><div id=\"echo\" data-echo=\"" & base64.encode(echoJson(req)) &
    "\"></div></body></html>"

proc spin(ms: int) =
  ## Stands in for a boundary whose data takes `ms` of work to produce.
  ## It deliberately occupies the worker: the test measures that the shell
  ## reached the client before this work finished.
  if ms <= 0: return
  let deadline = getMonoTime() + initDuration(milliseconds = ms)
  while getMonoTime() < deadline:
    discard

proc registerE2eApps*() =
  registerApp("echo", proc(req: SsrRequest; resp: SsrResponse): string =
    shape(req, resp)
    echoPage(req))

  registerStreamingApp("echo_stream",
    proc(req: SsrRequest; resp: SsrResponse; body: ResponseBody) =
      shape(req, resp)
      if resp.isRedirect:
        return
      let page = echoPage(req)
      let half = page.len div 2
      body.write(page[0 ..< half])
      body.flush()
      if req.hasQueryParam("late_header"):
        # Committed by the flush above: this must raise.
        resp.setHeader("X-Too-Late", "1")
      body.write(page[half .. ^1]))

  registerApp("routed", routedApp(
    proc(req: SsrRequest; resp: SsrResponse): seq[SsrRouteEntry] =
      @[
        SsrRouteEntry(pattern: parsePattern("/routed"),
          component: proc(): string = "<h1 id=\"page\">routed-index</h1>"),
        SsrRouteEntry(pattern: parsePattern("/routed/users/:id"),
          component: proc(): string =
            # The component reads its parameter from the request path.
            "<h1 id=\"page\">routed-user-" & req.path.split('/')[^1] &
              "</h1>"),
      ]))

  registerApp("csp", proc(req: SsrRequest; resp: SsrResponse): string =
    resp.setHeader("Content-Security-Policy",
      "default-src 'none'; script-src 'self' " & resp.cspNonceSource &
      "; object-src 'none'; base-uri 'none'")
    "<html><body><h1>CSP</h1></body></html>")

  registerStreamingApp("suspense",
    proc(req: SsrRequest; resp: SsrResponse; body: ResponseBody) =
      let deferMs = parseInt(req.queryParam("defer_ms", "0"))
      resp.setHeader("Content-Security-Policy",
        "default-src 'none'; script-src " & resp.cspNonceSource)
      let sr = renderToStream(
        proc(ctx: StreamContext): string =
          "<!DOCTYPE html><html><body><h1 id=\"shell\">Shell</h1>" &
            ctx.ssrSuspense("<p>Loading...</p>", nil, "deferred") &
            "</body></html>",
        body.outputStream,
        # The $df scripts must carry the response's CSP nonce too.
        StreamOptions(nonce: resp.cspNonce))
      spin(deferMs)
      sr.ctx.resolveBoundary("deferred",
        "<p id=\"deferred-content\">Deferred content</p>"))

  registerStreamingApp("sized",
    proc(req: SsrRequest; resp: SsrResponse; body: ResponseBody) =
      let size = parseInt(req.queryParam("size", "0"))
      var written = 0
      while written < size:
        let n = min(1024, size - written)
        body.write(repeat('x', n))
        body.flush()
        written += n)

  registerStreamingApp("async_dashboard", asyncStreamingApp)

  registerApp("boom", proc(req: SsrRequest; resp: SsrResponse): string =
    raise newException(ValueError, "boom"))
