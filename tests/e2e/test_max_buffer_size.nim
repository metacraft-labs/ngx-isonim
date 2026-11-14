## test_max_buffer_size.nim
##
## test_max_buffer_size_enforced (IFP-M1).
##
## Real nginx with the real module (tests/e2e/harness.nim).
## `isonim_ssr_max_buffer_size 64k` (65,536 bytes) on a streaming and a
## buffered location; the `sized` app writes the requested number of bytes
## in 1 KiB parts, flushing after each (hydration off, so the body is
## exactly the requested size).
##
## Vacuity guard: the 63 KB page is served whole on both transports; the
## 65 KB buffered page returns 500 with none of the page in the body; the
## 65 KB streamed page is cut off (the chunked body never completes and the
## connection closes) and the error log names the limit.
##
## No mocks.
##
## Run: nim c -r tests/e2e/test_max_buffer_size.nim  (in the dev shell)

import std/[unittest, strutils]
import harness

const
  limit = 64 * 1024
  under = 63 * 1024
  over = 65 * 1024

const locations = """
    location /stream { isonim_ssr on; isonim_ssr_app sized; isonim_ssr_hydration off; isonim_ssr_max_buffer_size 64k; }
    location /buffer { isonim_ssr on; isonim_ssr_app sized; isonim_ssr_hydration off; isonim_ssr_max_buffer_size 64k; isonim_ssr_mode buffered; }
    location /nolimit { isonim_ssr on; isonim_ssr_app sized; isonim_ssr_hydration off; }
"""

proc logLinesAbout(n: Nginx; marker: string): seq[string] =
  for line in n.errorLogText.splitLines():
    if marker in line and "isonim_ssr_max_buffer_size" in line:
      result.add line

suite "test_max_buffer_size_enforced":
  let module = testModule()
  let n = startNginx(module, locations)

  test "63 KB is served whole on both transports":
    for path in ["/stream", "/buffer"]:
      let r = curl(["-sS", "-i", n.url(path & "?size=" & $under)])
      check r.exitCode == 0
      let resp = splitResponse(r.output)
      check resp.statusLine == "HTTP/1.1 200 OK"
      check resp.body.len == under
      check resp.body == repeat('x', under)
      if path == "/buffer":
        check resp.headers.headerValues("Content-Length") == @[$under]
      else:
        check resp.headers.headerValues("Transfer-Encoding") == @["chunked"]

  test "65 KB buffered returns 500 with no partial body":
    let r = curl(["-sS", "-i", n.url("/buffer?size=" & $over & "&tag=buffered-over")])
    check r.exitCode == 0
    let resp = splitResponse(r.output)
    check resp.statusLine == "HTTP/1.1 500 Internal Server Error"
    check "xxxx" notin resp.body          # none of the page
    check "500 Internal Server Error" in resp.body   # nginx's own page
    let lines = n.logLinesAbout("buffered-over")
    check lines.len == 1
    check "[error]" in lines[0]
    check "responding 500" in lines[0]

  test "65 KB streamed is terminated and logged":
    let r = curl(["-sS", "-i", n.url("/stream?size=" & $over & "&tag=streamed-over")])
    # 18: the connection closed before the chunked body ended.
    check r.exitCode == 18
    let resp = splitResponse(r.output)
    check resp.statusLine == "HTTP/1.1 200 OK"
    check resp.headers.headerValues("Transfer-Encoding") == @["chunked"]
    check resp.body.len < over
    check resp.body.len <= limit
    check resp.body == repeat('x', resp.body.len)
    let lines = n.logLinesAbout("streamed-over")
    check lines.len == 1
    check "[error]" in lines[0]
    check "(65536 bytes)" in lines[0]
    check "terminated" in lines[0]

  test "without the directive the 65 KB page is served whole":
    let r = curl(["-sS", "-i", n.url("/nolimit?size=" & $over)])
    check r.exitCode == 0
    check splitResponse(r.output).body.len == over

  test "no worker crashed":
    n.stop()
    check "exited on signal" notin n.errorLogText
    check "[alert]" notin n.errorLogText
