## test_streaming_handler.nim
##
## The streaming transport (`isonim_ssr_mode streaming`, the default):
## when the status and headers go out, how flushes map to nginx buffers
## (each one with nginx's `flush` flag, the end with `last_buf`), the order
## of the shell, Suspense boundaries and the hydration script, and the
## legacy onChunk/onComplete renderers.
##
## Mocks: the pipeline runs over handler.nim's recording sink, standing in
## for nginx's header and output filters (see test_handler.nim).  Over real
## nginx, tests/e2e/test_streaming_debug.sh checks the wire.
##
## Compile with: nim c -r -d:isNginxTest tests/test_streaming_handler.nim

import unittest
import std/[strutils, sequtils]
import ../src/nginx_types
import ../src/handler
import e2e/apps/hello
import e2e/apps/async_app

proc getReq(meth = "GET"): SsrRequest =
  newSsrRequest(meth, "/", "/", "", @[], "127.0.0.1")

proc streaming(hydration = false): ServeOptions =
  ServeOptions(appName: "app", hydration: hydration, mode: tmStreaming)

proc parts(chunks: seq[string]): AppEntry =
  ## A renderer that writes and flushes each chunk in turn.
  streamingApp(proc(req: SsrRequest; resp: SsrResponse; body: ResponseBody) =
    for c in chunks:
      body.write(c)
      body.flush())

suite "Streaming - commit point":
  test "headers_go_out_on_the_first_flush_not_before":
    var committedBeforeFlush, committedAfterFlush: bool
    let app = streamingApp(proc(req: SsrRequest; resp: SsrResponse;
                                body: ResponseBody) =
      resp.status = 201
      body.write("<shell>")
      committedBeforeFlush = resp.committed
      body.flush()
      committedAfterFlush = resp.committed)
    let rec = serveRecorded(getReq(), app, streaming())
    check not committedBeforeFlush
    check committedAfterFlush
    check rec.status == 201

  test "status_and_headers_set_before_the_first_flush_are_sent":
    let app = streamingApp(proc(req: SsrRequest; resp: SsrResponse;
                                body: ResponseBody) =
      resp.status = 404
      resp.setHeader("Cache-Control", "no-store")
      resp.setCookie("a", "1")
      body.write("<shell>")
      body.flush()
      body.write("<rest>"))
    let rec = serveRecorded(getReq(), app, streaming())
    check rec.status == 404
    check rec.headers == @[("Cache-Control", "no-store"), ("Set-Cookie", "a=1")]
    check rec.contentLength == -1          # chunked
    check rec.body == "<shell><rest>"

  test "a_renderer_that_never_flushes_is_committed_when_it_returns":
    let app = streamingApp(proc(req: SsrRequest; resp: SsrResponse;
                                body: ResponseBody) =
      body.write("<all>"))
    let rec = serveRecorded(getReq(), app, streaming())
    check rec.rc == NGX_OK
    check rec.contentLength == -1
    check rec.sends.len == 1
    check rec.sends[0].data == "<all>"
    check rec.sends[0].last and rec.sends[0].flush

  test "string_renderer_on_streaming_transport":
    let rec = serveRecorded(getReq(), stringApp(
      proc(req: SsrRequest; resp: SsrResponse): string = "<p>x</p>"), streaming())
    check rec.rc == NGX_OK
    check rec.contentLength == -1
    check rec.body == "<p>x</p>"
    check rec.sends[^1].last

suite "Streaming - buffers":
  test "each_flush_is_one_buffer_with_the_flush_flag":
    let rec = serveRecorded(getReq(), parts(@["<a>", "<b>", "<c>"]), streaming())
    check rec.sends.mapIt(it.data) == @["<a>", "<b>", "<c>", ""]
    check rec.sends[0 .. 2].allIt(it.flush and not it.last)

  test "the_response_ends_with_one_last_buffer":
    let rec = serveRecorded(getReq(), parts(@["<a>", "<b>"]), streaming())
    check rec.sends.countIt(it.last) == 1
    check rec.sends[^1].last

  test "an_empty_flush_sends_nothing":
    let app = streamingApp(proc(req: SsrRequest; resp: SsrResponse;
                                body: ResponseBody) =
      body.flush()
      body.flush()
      body.write("<a>")
      body.flush())
    let rec = serveRecorded(getReq(), app, streaming())
    check rec.headersSent
    check rec.sends.mapIt(it.data) == @["<a>", ""]

  test "shell_boundaries_and_hydration_script_in_order":
    let rec = serveRecorded(getReq(), parts(@[
      "<html><body><!--B1--><!--B2-->", "<template id=\"B1\"></template>",
      "<template id=\"B2\"></template>", "</body></html>"]),
      streaming(hydration = true))
    let d = rec.sends.mapIt(it.data)
    check d[0].startsWith("<html>")
    check d[1].contains("B1") and d[2].contains("B2")
    check d[3] == "</body></html>"
    check d[4].startsWith("<script nonce=") and "window._$HY" in d[4]
    check rec.sends[4].last
    check rec.body.find("window._$HY") > rec.body.find("B2")

  test "HEAD_runs_the_renderer_but_sends_no_body":
    let rec = serveRecorded(getReq("HEAD"), parts(@["<a>", "<b>"]),
                            streaming(hydration = true))
    check rec.rc == NGX_OK
    check rec.headersSent
    check rec.status == 200
    check rec.sends.len == 0

suite "Streaming - legacy onChunk/onComplete renderers":
  test "each_chunk_is_written_and_flushed":
    registerStreamingApp("async_dashboard", asyncStreamingApp)
    let rec = serveRecorded(getReq(), lookupApp("async_dashboard"), streaming())
    check rec.rc == NGX_OK
    check rec.sends.len == 5    # four chunks + the last buffer
    check rec.sends[0].data.contains("<h1>Dashboard</h1>")
    check rec.sends[1].data.contains("Data loaded: 42 items")
    check rec.sends[3].data == "</body></html>"
    check rec.sends[0 .. 3].allIt(it.flush)

  test "single_chunk_app":
    registerStreamingApp("hello", helloStreamingApp)
    let rec = serveRecorded(getReq(), lookupApp("hello"), streaming())
    check rec.body == "<html><body><h1>Hello from IsoNim</h1></body></html>"

  test "legacy_app_raising_after_its_shell_terminates":
    proc failing(onChunk: proc(chunk: string), onComplete: proc()) =
      onChunk("<html><body><h1>Shell</h1></body></html>")
      raise newException(ValueError, "boundary resolution failed")
    registerStreamingApp("failing", failing)
    let rec = serveRecorded(getReq(), lookupApp("failing"), streaming())
    check rec.rc == NGX_ERROR
    check rec.body.contains("<h1>Shell</h1>")
    check not rec.sends.anyIt(it.last)

  test "legacy_app_raising_before_its_shell_is_500":
    proc failing(onChunk: proc(chunk: string), onComplete: proc()) =
      raise newException(ValueError, "shell render failed")
    registerStreamingApp("failing", failing)
    let rec = serveRecorded(getReq(), lookupApp("failing"), streaming())
    check rec.rc == NGX_HTTP_INTERNAL_SERVER_ERROR
    check not rec.headersSent
