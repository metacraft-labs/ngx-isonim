## test_request.nim
##
## The request object renderers receive: query and cookie parsing, header
## lookup, Host and the raw values, and how the mock-mode module builds it
## from an nginx request.
##
## Mocks: `newMockRequest` stands in for `ngx_http_request_t` in the last
## suite only, to check the field mapping of `toSsrRequest`.  The real
## mapping from nginx is checked over real nginx by
## tests/e2e/test_request_context.nim.
##
## Compile with: nim c -r -d:isNginxTest tests/test_request.nim

import unittest
import ../src/nginx_types
import ../src/request
import ../src/handler

suite "Request - query parsing":
  test "pairs in order, repeated names kept":
    check parseQuery("a=1&b=2&a=3") == @[("a", "1"), ("b", "2"), ("a", "3")]

  test "plus and percent escapes are decoded":
    check parseQuery("q=hello+world&x=%41%2Fb%3d") ==
      @[("q", "hello world"), ("x", "A/b=")]

  test "names are decoded too":
    check parseQuery("a%20b=1") == @[("a b", "1")]

  test "only the first = splits":
    check parseQuery("k=v=w") == @[("k", "v=w")]

  test "missing value and empty pairs":
    check parseQuery("flag&&x=") == @[("flag", ""), ("x", "")]

  test "malformed escapes are kept literally":
    check decodeFormComponent("100%") == "100%"
    check decodeFormComponent("%zz%4") == "%zz%4"
    check decodeFormComponent("%4a") == "J"

  test "empty query":
    check parseQuery("").len == 0

suite "Request - cookie parsing":
  test "pairs with optional whitespace":
    var c: seq[(string, string)]
    parseCookieHeader("a=1;b=2;  c = 3 ", c)
    check c == @[("a", "1"), ("b", "2"), ("c", "3")]

  test "quoted values are unquoted":
    var c: seq[(string, string)]
    parseCookieHeader("sid=\"abc\"", c)
    check c == @[("sid", "abc")]

  test "pairs without a name or = are ignored":
    var c: seq[(string, string)]
    parseCookieHeader("=x; novalue; ok=1", c)
    check c == @[("ok", "1")]

  test "value may contain =":
    var c: seq[(string, string)]
    parseCookieHeader("tok=a=b==", c)
    check c == @[("tok", "a=b==")]

suite "Request - newSsrRequest":
  let req = newSsrRequest("GET", "/p", "/p?x=1&y=two+words", "x=1&y=two+words",
    @[("Host", "example.test:8080"), ("Cookie", "a=1; b=2"),
      ("X-Multi", "one"), ("cookie", "c=3"), ("x-multi", "two")],
    "10.0.0.7")

  test "raw fields are kept as given":
    check req.httpMethod == "GET"
    check req.path == "/p"
    check req.rawUri == "/p?x=1&y=two+words"
    check req.query == "x=1&y=two+words"
    check req.clientAddr == "10.0.0.7"
    check req.headers.len == 5

  test "Host comes from the Host header, as sent":
    check req.host == "example.test:8080"

  test "cookies come from every Cookie header, in order":
    check req.cookies == @[("a", "1"), ("b", "2"), ("c", "3")]
    check req.cookie("b") == "2"
    check req.cookie("c") == "3"
    check req.cookie("B") == ""          # names are case-sensitive
    check req.hasCookie("a")
    check not req.hasCookie("z")

  test "headers are looked up case-insensitively":
    check req.header("x-MULTI") == "one"
    check req.headerValues("X-Multi") == @["one", "two"]
    check req.hasHeader("HOST")
    check req.header("Missing") == ""

  test "query parameters":
    check req.queryParam("y") == "two words"
    check req.queryParam("missing", "dflt") == "dflt"
    check req.hasQueryParam("x")

  test "no Host header gives an empty host":
    let r = newSsrRequest("GET", "/", "/", "", @[], "")
    check r.host == ""
    check r.cookies.len == 0

suite "Request - built from an nginx request (mock mode)":
  test "every field maps from the request":
    let r = newMockRequest(uri = "/a/b", httpMethod = "HEAD")
    r.args = "k=v"
    r.unparsedUri = "/a/./b?k=v"
    r.addrText = "192.0.2.1"
    r.headers = @[("Host", "h.test"), ("Cookie", "s=1")]
    let req = toSsrRequest(r)
    check req.httpMethod == "HEAD"
    check req.path == "/a/b"
    check req.rawUri == "/a/./b?k=v"
    check req.query == "k=v"
    check req.clientAddr == "192.0.2.1"
    check req.host == "h.test"
    check req.cookie("s") == "1"
    check req.queryParam("k") == "v"
