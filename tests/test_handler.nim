## test_handler.nim
##
## The request pipeline (serve.nim) the module runs for every request:
## the app registry, method handling, response shaping on both transports,
## the hydration script and its CSP nonce, isonim_ssr_max_buffer_size, and
## what happens when a renderer or the client fails.
##
## Mocks: the pipeline runs over the recording sink of handler.nim
## (`serveRecorded`), which stands in for nginx's header and output filters.
## It is the only part replaced: the pipeline code is the one the module
## runs.  The same behaviour is checked over real nginx by the tests under
## tests/e2e/.
##
## Compile with: nim c -r -d:isNginxTest tests/test_handler.nim

import unittest
import std/[strutils, sequtils, base64]
import ../src/nginx_types
import ../src/handler
import e2e/apps/hello

proc getReq(path = "/", meth = "GET"; query = "";
            headers: seq[(string, string)] = @[]): SsrRequest =
  newSsrRequest(meth, path, (if query.len > 0: path & "?" & query else: path),
                query, headers, "127.0.0.1")

proc opts(mode = tmBuffered; hydration = false; maxBufferSize = 0;
          appName = "app"): ServeOptions =
  ServeOptions(appName: appName, hydration: hydration, mode: mode,
               maxBufferSize: maxBufferSize)

proc page(html: string): AppEntry =
  stringApp(proc(req: SsrRequest; resp: SsrResponse): string = html)

proc header(rec: RecordedResponse; name: string): seq[string] =
  for (k, v) in rec.headers:
    if cmpIgnoreCase(k, name) == 0:
      result.add v

proc nonceOf(body: string): string =
  ## The nonce attribute of the hydration script.
  let start = body.find("<script nonce=\"")
  doAssert start >= 0, "no nonced script in: " & body
  let s = start + "<script nonce=\"".len
  body[s ..< body.find('"', s)]

const bothModes = [tmBuffered, tmStreaming]

# ---------------------------------------------------------------------------

suite "App Registry":
  setup:
    clearApps()

  test "register_and_lookup_string_app":
    registerApp("hello", proc(req: SsrRequest; resp: SsrResponse): string =
      "hi " & req.path)
    let app = lookupApp("hello")
    check app != nil
    check app.kind == akString
    check app.render(getReq("/x"), newSsrResponse()) == "hi /x"

  test "legacy_argumentless_renderer_is_adapted":
    registerApp("hello", helloApp)
    let app = lookupApp("hello")
    check app.kind == akString
    check app.render(getReq(), newSsrResponse()).contains("Hello from IsoNim")

  test "lookup_nonexistent_returns_nil":
    check lookupApp("does-not-exist") == nil

  test "clear_removes_all_apps":
    registerApp("a", helloApp)
    registerStreamingApp("b", helloStreamingApp)
    clearApps()
    check lookupApp("a") == nil
    check lookupApp("b") == nil

  test "one_namespace_last_registration_wins":
    registerApp("app", helloApp)
    registerStreamingApp("app", helloStreamingApp)
    check lookupApp("app").kind == akStreaming
    registerApp("app", taskManagerApp)
    check lookupApp("app").kind == akString
    check lookupApp("app").render(getReq(), newSsrResponse()).contains("Task Manager")

  test "nil_renderer_is_rejected":
    expect ValueError:
      registerApp("x", SsrRenderer(nil))
    expect ValueError:
      registerStreamingApp("x", SsrStreamingRenderer(nil))

# ---------------------------------------------------------------------------

suite "Pipeline - methods and app lookup":
  test "only_GET_and_HEAD_are_served":
    for m in ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"]:
      for mode in bothModes:
        let rec = serveRecorded(getReq(meth = m), page("x"), opts(mode))
        check rec.rc == NGX_HTTP_NOT_ALLOWED
        check not rec.headersSent

  test "unknown_app_is_500_and_logged":
    let rec = serveRecorded(getReq(), nil, opts(appName = "ghost"))
    check rec.rc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check not rec.headersSent
    check rec.log.len == 1
    check rec.log[0][0] == NGX_LOG_ERR
    check "ghost" in rec.log[0][1]

# ---------------------------------------------------------------------------

suite "Pipeline - buffered transport":
  test "body_with_content_length_in_one_last_buffer":
    let rec = serveRecorded(getReq(), page("<h1>Hi</h1>"), opts(tmBuffered))
    check rec.rc == NGX_OK
    check rec.status == 200
    check rec.contentType == "text/html; charset=utf-8"
    check rec.contentLength == "<h1>Hi</h1>".len
    check rec.body == "<h1>Hi</h1>"
    check rec.sends.len == 1
    check rec.sends[0].last

  test "content_length_includes_the_hydration_script":
    let rec = serveRecorded(getReq(), page("<p>x</p>"),
                            opts(tmBuffered, hydration = true))
    check rec.body.startsWith("<p>x</p><script nonce=")
    check rec.body.endsWith("</script><!--xs-->")   # IsoNim's bootstrap
    check rec.contentLength == rec.body.len

  test "streaming_renderer_on_buffered_transport_is_sent_whole":
    let app = streamingApp(proc(req: SsrRequest; resp: SsrResponse;
                                body: ResponseBody) =
      body.write("<a>")
      body.flush()
      check not resp.committed   # buffered: flush sends nothing
      body.write("<b>"))
    let rec = serveRecorded(getReq(), app, opts(tmBuffered))
    check rec.body == "<a><b>"
    check rec.contentLength == 6
    check rec.sends.len == 1

  test "HEAD_sends_headers_with_the_GET_content_length_and_no_body":
    let get = serveRecorded(getReq(), page("<h1>Hi</h1>"),
                            opts(tmBuffered, hydration = true))
    let head = serveRecorded(getReq(meth = "HEAD"), page("<h1>Hi</h1>"),
                             opts(tmBuffered, hydration = true))
    check head.rc == NGX_OK
    check head.headersSent
    check head.contentLength == get.contentLength
    check head.body == ""
    check head.sends.len == 0

# ---------------------------------------------------------------------------

suite "Pipeline - hydration script and CSP nonce":
  test "script_present_only_when_enabled":
    for mode in bothModes:
      check "window._$HY" in serveRecorded(getReq(), page("x"),
        opts(mode, hydration = true)).body
      check "window._$HY" notin serveRecorded(getReq(), page("x"),
        opts(mode, hydration = false)).body

  test "script_nonce_is_128_random_bits_per_response":
    var nonces: seq[string]
    for i in 0 ..< 200:
      let rec = serveRecorded(getReq(), page("x"),
        opts(if i mod 2 == 0: tmBuffered else: tmStreaming, hydration = true))
      let n = nonceOf(rec.body)
      check base64.decode(n).len == 16
      nonces.add n
    check nonces.deduplicate.len == nonces.len

  test "script_nonce_equals_the_nonce_the_renderer_put_in_its_header":
    let app = stringApp(proc(req: SsrRequest; resp: SsrResponse): string =
      resp.setHeader("Content-Security-Policy",
                     "script-src " & resp.cspNonceSource)
      "<p>csp</p>")
    for mode in bothModes:
      let rec = serveRecorded(getReq(), app, opts(mode, hydration = true))
      check rec.header("Content-Security-Policy") ==
        @["script-src 'nonce-" & nonceOf(rec.body) & "'"]

# ---------------------------------------------------------------------------

suite "Pipeline - response shaping":
  test "renderer_that_sets_nothing_gets_200_and_the_default_type":
    for mode in bothModes:
      let rec = serveRecorded(getReq(), page("x"), opts(mode))
      check rec.status == 200
      check rec.contentType == "text/html; charset=utf-8"
      check rec.headers.len == 0

  test "status_headers_cookies_and_content_type_reach_the_sink":
    let app = stringApp(proc(req: SsrRequest; resp: SsrResponse): string =
      resp.status = 404
      resp.contentType = "application/xhtml+xml"
      resp.setHeader("Cache-Control", "private, no-cache, must-revalidate")
      resp.addHeader("Vary", "Cookie")
      resp.addHeader("Vary", "Accept-Language")
      resp.setCookie("sid", "abc", CookieOptions(path: "/", httpOnly: true))
      resp.setCookie("theme", "dark")
      "<p>gone</p>")
    for mode in bothModes:
      let rec = serveRecorded(getReq(), app, opts(mode))
      check rec.rc == NGX_OK
      check rec.status == 404
      check rec.contentType == "application/xhtml+xml"
      check rec.header("Cache-Control") == @["private, no-cache, must-revalidate"]
      check rec.header("Vary") == @["Cookie", "Accept-Language"]
      check rec.header("Set-Cookie") == @["sid=abc; Path=/; HttpOnly", "theme=dark"]
      check rec.body == "<p>gone</p>"

  test "redirects_send_status_location_cookies_and_no_body":
    for code in [301, 302, 303, 307, 308]:
      for mode in bothModes:
        let app = stringApp(proc(req: SsrRequest; resp: SsrResponse): string =
          resp.setCookie("flash", "ok")
          resp.redirect("/next", code)
          "<p>this body is not sent</p>")
        let rec = serveRecorded(getReq(), app, opts(mode, hydration = true))
        check rec.rc == NGX_OK
        check rec.status == code
        check rec.header("Location") == @["/next"]
        check rec.header("Set-Cookie") == @["flash=ok"]
        check rec.contentLength == 0
        check rec.body == ""
        check rec.sends.len == 1 and rec.sends[0].last

  test "writing_a_body_after_redirect_is_an_error":
    let app = streamingApp(proc(req: SsrRequest; resp: SsrResponse;
                                body: ResponseBody) =
      resp.redirect("/x")
      body.write("oops"))
    let rec = serveRecorded(getReq(), app, opts(tmStreaming))
    check rec.rc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check not rec.headersSent
    check "redirect" in rec.log[0][1]

  test "204_and_304_go_out_without_a_body":
    for code in [204, 304]:
      for mode in bothModes:
        let app = stringApp(proc(req: SsrRequest; resp: SsrResponse): string =
          resp.status = code
          "")
        let rec = serveRecorded(getReq(), app, opts(mode, hydration = true))
        check rec.rc == NGX_OK
        check rec.status == code
        check rec.sends.len == 0

  test "invalid_shaping_fails_the_request_before_anything_is_sent":
    let app = stringApp(proc(req: SsrRequest; resp: SsrResponse): string =
      resp.setHeader("X-Echo", req.queryParam("v"))
      "x")
    let rec = serveRecorded(getReq(query = "v=a%0D%0ASet-Cookie:+x=1"), app,
                            opts(tmBuffered))
    check rec.rc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check not rec.headersSent
    check "ValueError" in rec.log[0][1]

# ---------------------------------------------------------------------------

suite "Pipeline - renderer failures":
  test "raise_before_anything_is_sent_is_500_and_logged":
    let app = stringApp(proc(req: SsrRequest; resp: SsrResponse): string =
      resp.setHeader("X-Never", "sent")
      raise newException(ValueError, "render failed"))
    for mode in bothModes:
      let rec = serveRecorded(getReq(), app, opts(mode))
      check rec.rc == NGX_HTTP_INTERNAL_SERVER_ERROR
      check not rec.headersSent
      check rec.log.len == 1
      check "render failed" in rec.log[0][1]
      check "responding 500" in rec.log[0][1]

  test "raise_after_the_first_flush_terminates_the_response":
    let app = streamingApp(proc(req: SsrRequest; resp: SsrResponse;
                                body: ResponseBody) =
      body.write("<shell>")
      body.flush()
      raise newException(ValueError, "boundary failed"))
    let rec = serveRecorded(getReq(), app, opts(tmStreaming, hydration = true))
    check rec.rc == NGX_ERROR
    check rec.headersSent
    check rec.body == "<shell>"
    check not rec.sends.anyIt(it.last)
    check "boundary failed" in rec.log[0][1]
    check "terminated" in rec.log[0][1]

  test "shaping_after_commit_raises_and_terminates":
    let app = streamingApp(proc(req: SsrRequest; resp: SsrResponse;
                                body: ResponseBody) =
      body.write("<shell>")
      body.flush()
      resp.setHeader("X-Late", "1"))
    let rec = serveRecorded(getReq(), app, opts(tmStreaming))
    check rec.rc == NGX_ERROR
    check rec.header("X-Late").len == 0
    check "ResponseCommittedError" in rec.log[0][1]

  test "client_gone_mid_stream_stops_rendering":
    var reachedAfter = false
    let app = streamingApp(proc(req: SsrRequest; resp: SsrResponse;
                                body: ResponseBody) =
      body.write("<a>")
      body.flush()
      body.write("<b>")
      body.flush()          # this send fails
      reachedAfter = true)
    let rec = serveRecorded(getReq(), app, opts(tmStreaming),
                            RecordingOptions(failBodySendAt: 2))
    check rec.rc == NGX_ERROR
    check not reachedAfter
    check rec.log[0][0] == NGX_LOG_INFO
    check "client connection" in rec.log[0][1]

# ---------------------------------------------------------------------------

suite "Pipeline - isonim_ssr_max_buffer_size":
  proc sized(n: int; flushEvery = 1024): AppEntry =
    streamingApp(proc(req: SsrRequest; resp: SsrResponse; body: ResponseBody) =
      var left = n
      while left > 0:
        let k = min(flushEvery, left)
        body.write(repeat('x', k))
        body.flush()
        left -= k)

  test "a_body_exactly_at_the_limit_is_served_whole":
    for mode in bothModes:
      let rec = serveRecorded(getReq(), sized(4096), opts(mode, maxBufferSize = 4096))
      check rec.rc == NGX_OK
      check rec.body.len == 4096
      check rec.sends[^1].last

  test "buffered_over_the_limit_is_500_with_nothing_sent":
    for app in [sized(4097), page(repeat('y', 4097))]:
      let rec = serveRecorded(getReq(), app, opts(tmBuffered, maxBufferSize = 4096))
      check rec.rc == NGX_HTTP_INTERNAL_SERVER_ERROR
      check not rec.headersSent
      check rec.sends.len == 0
      check "isonim_ssr_max_buffer_size" in rec.log[0][1]

  test "streaming_over_the_limit_is_terminated_and_logged":
    let rec = serveRecorded(getReq(), sized(4097), opts(tmStreaming, maxBufferSize = 4096))
    check rec.rc == NGX_ERROR
    check rec.headersSent
    check rec.body.len == 4096          # the parts that fit were sent
    check not rec.sends.anyIt(it.last)  # never completed
    check rec.log[0][0] == NGX_LOG_ERR
    check "isonim_ssr_max_buffer_size (4096 bytes)" in rec.log[0][1]
    check "terminated" in rec.log[0][1]

  test "streaming_over_the_limit_before_the_first_flush_is_500":
    let rec = serveRecorded(getReq(), page(repeat('y', 5000)),
                            opts(tmStreaming, maxBufferSize = 4096))
    check rec.rc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check not rec.headersSent

  test "the_hydration_script_counts_against_the_limit":
    let body = repeat('z', 4000)
    # The bootstrap with a 24-character nonce, exactly as served.
    let script = hydrationScript(repeat('n', 24)).len
    let ok = serveRecorded(getReq(), page(body),
      opts(tmBuffered, hydration = true, maxBufferSize = 4000 + script))
    check ok.rc == NGX_OK
    check ok.body.len == 4000 + script
    let tooBig = serveRecorded(getReq(), page(body),
      opts(tmBuffered, hydration = true, maxBufferSize = 4000 + script - 1))
    check tooBig.rc == NGX_HTTP_INTERNAL_SERVER_ERROR

  test "zero_means_unlimited":
    let rec = serveRecorded(getReq(), sized(300_000), opts(tmStreaming))
    check rec.rc == NGX_OK
    check rec.body.len == 300_000
