## test_request_context.nim
##
## test_renderer_receives_request_and_shapes_response (IFP-M1).
##
## Real nginx with the real module loaded (tests/e2e/harness.nim), driven by
## curl.  The `echo` and `echo_stream` apps (tests/e2e/apps/e2e_apps.nim)
## report the request they received and, per query parameter, set a status,
## headers, a cookie, a content type or a redirect.  Every scenario runs on
## four locations: each renderer kind on each transport
## (`isonim_ssr_mode buffered` and the default, streaming).
##
## * Vacuity guard: every request field arrives with the value curl sent
##   (compared with the request lines curl itself reports with -v), and
##   each status, header, cookie and redirect appears on the wire exactly
##   as set.
## * Negative control: a renderer that sets nothing gets 200 with the
##   default content type and none of the shaped headers.
## * Falsifying mutation: a module whose request object drops the Cookie
##   header fails the cookie-echo assertion (and only the request-field
##   assertions), built from the sources by `buildMutant`.
##
## No mocks.
##
## Run: nim c -r tests/e2e/test_request_context.nim  (in the dev shell)

import std/[unittest, json, base64, strutils, sequtils]
import harness

const locations = """
    location /ctx/b-string/ { isonim_ssr on; isonim_ssr_app echo;        isonim_ssr_mode buffered; }
    location /ctx/b-stream/ { isonim_ssr on; isonim_ssr_app echo_stream; isonim_ssr_mode buffered; }
    location /ctx/s-string/ { isonim_ssr on; isonim_ssr_app echo; }
    location /ctx/s-stream/ { isonim_ssr on; isonim_ssr_app echo_stream; }
    location /routed        { isonim_ssr on; isonim_ssr_app routed; }
"""

const variants = ["b-string", "b-stream", "s-string", "s-stream"]

proc sentRequestLines(stderr: string): seq[string] =
  ## The request curl sent, as `curl -v` reports it ("> " lines).
  for line in stderr.splitLines():
    if line.startsWith("> "):
      let l = line[2 .. ^1].strip(leading = false, chars = {'\r'})
      if l.len > 0: result.add l

proc echoOf(body: string): JsonNode =
  let marker = "data-echo=\""
  let s = body.find(marker)
  doAssert s >= 0, "no echo in body: " & body
  let start = s + marker.len
  parseJson(base64.decode(body[start ..< body.find('"', start)]))

proc pairs(node: JsonNode): seq[(string, string)] =
  for p in node:
    result.add((p[0].getStr, p[1].getStr))

proc checkRequestEcho(n: Nginx; variant: string): seq[string] =
  ## Returns the failed expectations (empty when everything arrived).
  let path = "/ctx/" & variant & "/./page"
  let query = "a=1&b=two+words&a=%C3%A9&empty="
  let r = curl(["-sS", "-v", "--path-as-is", "-i",
    "-H", "Host: forum.example.test:8443",
    "-H", "Cookie: sid=abc123; theme=dark",
    "-H", "X-Custom: Value  With  Spaces",
    "-H", "Accept-Language: en-GB, bg;q=0.8",
    "-A", "isonim-e2e/1.0",
    n.url(path & "?" & query)])
  if r.exitCode != 0:
    return @["curl failed: " & $r.exitCode & " " & r.stderr]
  let resp = splitResponse(r.output)
  let got = echoOf(resp.body)
  let sent = sentRequestLines(r.stderr)
  # sent[0] is the request line; the rest are the headers, in order.
  let reqLine = sent[0].split(' ')
  var sentHeaders: seq[(string, string)]
  for l in sent[1 .. ^1]:
    let c = l.find(':')
    sentHeaders.add((l[0 ..< c], l[c + 1 .. ^1].strip(trailing = false)))

  template want(cond: bool; what: string) =
    if not cond: result.add(variant & ": " & what)

  want got["method"].getStr == reqLine[0], "method " & $got["method"]
  want got["rawUri"].getStr == reqLine[1], "rawUri " & $got["rawUri"]
  want got["path"].getStr == "/ctx/" & variant & "/page", "path " & $got["path"]
  want got["query"].getStr == query, "query " & $got["query"]
  want got["queryParams"].pairs ==
    @[("a", "1"), ("b", "two words"), ("a", "é"), ("empty", "")],
    "queryParams " & $got["queryParams"]
  want got["headers"].pairs == sentHeaders,
    "headers " & $got["headers"] & " vs sent " & $sentHeaders
  want got["host"].getStr == "forum.example.test:8443", "host " & $got["host"]
  want got["clientAddr"].getStr == "127.0.0.1", "clientAddr " & $got["clientAddr"]
  want got["cookies"].pairs == @[("sid", "abc123"), ("theme", "dark")],
    "cookie echo " & $got["cookies"]

proc get(n: Nginx; path: string): tuple[r: CurlResult,
    statusLine: string, headers: seq[(string, string)], body: string] =
  let r = curl(["-sS", "-i", n.url(path)])
  let s = splitResponse(r.output)
  (r, s.statusLine, s.headers, s.body)

const shapedHeaderNames = ["Set-Cookie", "Cache-Control", "Vary",
  "Content-Security-Policy", "Location", "X-Shaped"]

suite "test_renderer_receives_request_and_shapes_response":
  let module = testModule()
  let n = startNginx(module, locations)

  test "every request field arrives with the value curl sent":
    for v in variants:
      let failures = checkRequestEcho(n, v)
      check failures.len == 0
      if failures.len > 0: echo failures.join("\n")

  test "status, headers, cookies and content type appear on the wire as set":
    let q = "?status=201" &
      "&header=Cache-Control:private,%20no-cache,%20must-revalidate" &
      "&header=Vary:Cookie&header=Vary:Accept-Language" &
      "&header=Content-Security-Policy:default-src%20'none'" &
      "&header=X-Shaped:a%20b" &
      "&cookie=sid=abc123&cookie=theme=dark" &
      "&content_type=application/xhtml%2Bxml;%20charset=utf-8"
    for v in variants:
      let (r, statusLine, headers, body) = n.get("/ctx/" & v & "/p" & q)
      check r.exitCode == 0
      check statusLine == "HTTP/1.1 201 Created"
      check headers.headerValues("Cache-Control") ==
        @["private, no-cache, must-revalidate"]
      check headers.headerValues("Vary") == @["Cookie", "Accept-Language"]
      check headers.headerValues("Content-Security-Policy") == @["default-src 'none'"]
      check headers.headerValues("X-Shaped") == @["a b"]
      check headers.headerValues("Set-Cookie") == @[
        "sid=abc123; Path=/; HttpOnly; SameSite=Lax",
        "theme=dark; Path=/; HttpOnly; SameSite=Lax"]
      check headers.headerValues("Content-Type") ==
        @["application/xhtml+xml; charset=utf-8"]
      check "data-echo=" in body
      if v.startsWith("b-"):
        check headers.headerValues("Content-Length") == @[$body.len]
      else:
        check headers.headerValues("Transfer-Encoding") == @["chunked"]

  test "error statuses chosen by the renderer":
    for v in variants:
      for code in [404, 410, 503]:
        let (r, statusLine, _, body) = n.get("/ctx/" & v & "/p?status=" & $code)
        check r.exitCode == 0
        check statusLine.startsWith("HTTP/1.1 " & $code & " ")
        check "data-echo=" in body   # the renderer's body, not nginx's page

  test "204 and 304 from the renderer go out without a body":
    for v in variants:
      for code in [204, 304]:
        let (r, statusLine, headers, body) = n.get("/ctx/" & v &
          "/p?status=" & $code & "&header=X-Shaped:kept")
        check r.exitCode == 0
        check statusLine.startsWith("HTTP/1.1 " & $code & " ")
        check headers.headerValues("X-Shaped") == @["kept"]
        check body == ""

  test "redirects: status, Location, cookies and no body":
    for v in variants:
      for code in [301, 302, 303, 307, 308]:
        let (r, statusLine, headers, body) = n.get("/ctx/" & v &
          "/p?redirect=/next%3Fx%3D1&redirect_status=" & $code &
          "&cookie=flash=saved")
        check r.exitCode == 0
        check statusLine.startsWith("HTTP/1.1 " & $code & " ")
        check headers.headerValues("Location") == @["/next?x=1"]
        check headers.headerValues("Set-Cookie") ==
          @["flash=saved; Path=/; HttpOnly; SameSite=Lax"]
        check headers.headerValues("Content-Length") == @["0"]
        check body == ""

  test "negative control: a renderer that sets nothing gets 200 text/html":
    for v in variants:
      let (r, statusLine, headers, body) = n.get("/ctx/" & v & "/p")
      check r.exitCode == 0
      check statusLine == "HTTP/1.1 200 OK"
      check headers.headerValues("Content-Type") == @["text/html; charset=utf-8"]
      for name in shapedHeaderNames:
        check headers.headerValues(name).len == 0
      check "data-echo=" in body

  test "shaping after the first streamed flush is refused and logged":
    let r = curl(["-sS", "-i", n.url("/ctx/s-stream/p?late_header=1")])
    check r.exitCode == 18          # transfer closed with data outstanding
    check r.output.startsWith("HTTP/1.1 200 OK")
    check "X-Too-Late" notin r.output
    check "ResponseCommittedError" in n.errorLogText

  test "the SSR router selects the component from the request path":
    block:
      let (_, statusLine, _, body) = n.get("/routed")
      check statusLine == "HTTP/1.1 200 OK"
      check "routed-index" in body
    block:
      let (_, statusLine, _, body) = n.get("/routed/users/42")
      check statusLine == "HTTP/1.1 200 OK"
      check "routed-user-42" in body
    block:
      let (_, statusLine, _, body) = n.get("/routed/nope")
      check statusLine == "HTTP/1.1 404 Not Found"
      check "404 Not Found" in body

  test "falsifying mutation: dropping the Cookie header fails the cookie echo":
    let mutant = buildMutant("drop-cookie", "src/handler.nim",
      "      headers.add((ngxStrToString(k), ngxStrToString(v)))",
      "      if ngxStrToString(k) != \"Cookie\":\n" &
      "        headers.add((ngxStrToString(k), ngxStrToString(v)))")
    let m = startNginx(mutant, locations)
    try:
      for v in variants:
        let failures = checkRequestEcho(m, v)
        check failures.anyIt("cookie echo" in it)
        # Only the request-field assertions can fail: the mutation does
        # not touch shaping.
        check failures.allIt("cookie echo" in it or "headers" in it)
    finally:
      m.stop()

  test "no worker crashed and nothing was logged above error":
    n.stop()
    let log = n.errorLogText
    check "[alert]" notin log
    check "[crit]" notin log
    check "[emerg]" notin log
    check "exited on signal" notin log
