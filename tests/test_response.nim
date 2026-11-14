## test_response.nim
##
## The response a renderer shapes: status, content type, headers, cookies,
## redirects, header validation, the commit point, and the per-response CSP
## nonce.  Pure Nim; no mocks.
##
## Compile with: nim c -r -d:isNginxTest tests/test_response.nim

import unittest
import std/[base64, bitops, options, sets]
import ../src/response

suite "Response - defaults":
  test "200 with the HTML content type and no headers":
    let r = newSsrResponse()
    check r.status == 200
    check r.contentType == "text/html; charset=utf-8"
    check r.headers.len == 0
    check not r.isRedirect
    check not r.committed

suite "Response - status and content type":
  test "status can be set within 200..599":
    let r = newSsrResponse()
    r.status = 404
    check r.status == 404
    r.status = 599
    check r.status == 599

  test "1xx and out-of-range statuses are rejected":
    let r = newSsrResponse()
    for bad in [0, 100, 101, 199, 600, -1]:
      expect ValueError:
        r.status = bad
    check r.status == 200

  test "content type can be replaced but not emptied or split":
    let r = newSsrResponse()
    r.contentType = "application/json"
    check r.contentType == "application/json"
    expect ValueError:
      r.contentType = ""
    expect ValueError:
      r.contentType = "text/html\r\nX-Evil: 1"
    check r.contentType == "application/json"

suite "Response - headers":
  test "addHeader keeps duplicates, setHeader replaces them":
    let r = newSsrResponse()
    r.addHeader("Vary", "Cookie")
    r.addHeader("vary", "Accept-Language")
    check r.headers == @[("Vary", "Cookie"), ("vary", "Accept-Language")]
    r.setHeader("VARY", "Accept-Encoding")
    check r.headers == @[("VARY", "Accept-Encoding")]
    check r.header("vary") == "Accept-Encoding"

  test "removeHeader drops every header of the name":
    let r = newSsrResponse()
    r.addHeader("X-A", "1")
    r.addHeader("X-B", "2")
    r.addHeader("x-a", "3")
    r.removeHeader("X-A")
    check r.headers == @[("X-B", "2")]

  test "CR, LF and NUL in a value are rejected (no response splitting)":
    let r = newSsrResponse()
    for bad in ["a\r\nSet-Cookie: x=1", "a\nb", "a\rb", "a\0b", "a\x01b"]:
      expect ValueError:
        r.setHeader("X-Test", bad)
    r.setHeader("X-Tab", "a\tb")   # HTAB is allowed
    check r.header("X-Tab") == "a\tb"
    check r.headers.len == 1

  test "header names must be tokens":
    let r = newSsrResponse()
    for bad in ["", "Bad Name", "X:Y", "X\r\n", "Ünicode"]:
      expect ValueError:
        r.addHeader(bad, "v")
    check r.headers.len == 0

  test "headers the module owns are rejected":
    let r = newSsrResponse()
    for name in ["Content-Length", "transfer-encoding", "Connection",
                 "Content-Type", "Location", "Keep-Alive", "Upgrade"]:
      expect ValueError:
        r.setHeader(name, "x")
    check r.headers.len == 0

suite "Response - cookies":
  test "setCookie adds one Set-Cookie header per cookie":
    let r = newSsrResponse()
    r.setCookie("a", "1")
    r.setCookie("b", "2")
    check r.headers == @[("Set-Cookie", "a=1"), ("Set-Cookie", "b=2")]

  test "attributes in RFC 6265 form":
    check formatSetCookie("__Host-Session", "tok_123", CookieOptions(
        path: "/", maxAge: some(3600), secure: true, httpOnly: true,
        sameSite: sameSiteStrict)) ==
      "__Host-Session=tok_123; Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=Strict"
    check formatSetCookie("x", "", CookieOptions(domain: "ex.test",
        expires: "Thu, 01 Jan 1970 00:00:00 GMT", sameSite: sameSiteNone)) ==
      "x=; Domain=ex.test; Expires=Thu, 01 Jan 1970 00:00:00 GMT; SameSite=None"

  test "names must be tokens and values cookie-octets":
    for (n, v) in [("", "v"), ("a b", "v"), ("a;b", "v"), ("a", "v;w"),
                   ("a", "v w"), ("a", "v\"w"), ("a", "v,w"), ("a", "v\\w"),
                   ("a", "v\r\nX: 1")]:
      expect ValueError:
        discard formatSetCookie(n, v)

  test "attribute values cannot inject attributes":
    expect ValueError:
      discard formatSetCookie("a", "1", CookieOptions(path: "/; Domain=evil"))
    expect ValueError:
      discard formatSetCookie("a", "1", CookieOptions(domain: "x\r\ny"))

suite "Response - redirects":
  test "each redirect status sets the status and Location":
    for code in [301, 302, 303, 307, 308]:
      let r = newSsrResponse()
      r.redirect("/next?x=1", code)
      check r.isRedirect
      check r.status == code
      check r.location == "/next?x=1"
      check ("Location", "/next?x=1") in r.wireHeaders

  test "default redirect status is 302":
    let r = newSsrResponse()
    r.redirect("https://example.test/")
    check r.status == 302

  test "other statuses, empty and split locations are rejected":
    let r = newSsrResponse()
    for code in [200, 300, 304, 305, 306, 404]:
      expect ValueError:
        r.redirect("/x", code)
    expect ValueError:
      r.redirect("")
    expect ValueError:
      r.redirect("/x\r\nSet-Cookie: a=1")
    check not r.isRedirect

  test "headers and cookies set around a redirect go out with it":
    let r = newSsrResponse()
    r.setCookie("flash", "saved")
    r.redirect("/done", 303)
    r.setHeader("Cache-Control", "no-store")
    check r.wireHeaders == @[("Set-Cookie", "flash=saved"),
      ("Cache-Control", "no-store"), ("Location", "/done")]

suite "Response - commit point":
  test "every setter raises once the response is committed":
    let r = newSsrResponse()
    r.setHeader("X-Before", "1")
    r.markCommitted()
    expect ResponseCommittedError:
      r.status = 404
    expect ResponseCommittedError:
      r.contentType = "text/plain"
    expect ResponseCommittedError:
      r.setHeader("X-After", "1")
    expect ResponseCommittedError:
      r.addHeader("X-After", "1")
    expect ResponseCommittedError:
      r.removeHeader("X-Before")
    expect ResponseCommittedError:
      r.setCookie("a", "1")
    expect ResponseCommittedError:
      r.redirect("/x")
    check r.status == 200
    check r.headers == @[("X-Before", "1")]

suite "Response - CSP nonce":
  test "128 bits, base64, stable within one response":
    let r = newSsrResponse()
    let n = r.cspNonce
    check n.len == 24
    check base64.decode(n).len == 16
    check r.cspNonce == n
    check r.cspNonceSource == "'nonce-" & n & "'"

  test "only CSP base64-value characters":
    let n = newSsrResponse().cspNonce
    for c in n:
      check c in {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}

  test "10,000 responses get 10,000 distinct nonces":
    var seen = initHashSet[string]()
    for i in 0 ..< 10_000:
      seen.incl newSsrResponse().cspNonce
    check seen.len == 10_000

  test "bytes are not degenerate":
    # A broken generator (e.g. zero-filled) passes length checks; a CSPRNG
    # gives about half the bits set across many nonces.
    var ones, total = 0
    for i in 0 ..< 1000:
      for b in base64.decode(generateCspNonce()):
        ones += countSetBits(uint8(b))
        total += 8
    let ratio = ones / total
    check ratio > 0.45 and ratio < 0.55
