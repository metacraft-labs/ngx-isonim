## stream_app.nim
##
## Async apps that stream their response (`ctx.bodyWriter`), compiled into
## the end-to-end module (registered by e2e_apps.nim) and driven over real
## nginx by tests/e2e/test_async_streaming.nim.
##
## * `stream_await`: flushes a shell, then connects to `127.0.0.1:<port>`
##   (a socket the test holds) and awaits one byte on it, then writes and
##   flushes the rest, which carries that byte.  The test sends the byte
##   only after it has received the shell.
## * `stream_whole`: writes its body through the writer and `ctx.write`
##   without ever flushing: answered whole, with `Content-Length`.
## * `stream_raise_before`: writes, then raises before any flush.
## * `stream_raise_after`: flushes a shell, then raises.
## * `stream_hang`: flushes a shell, then awaits a future nothing completes
##   (the `isonim_rpc_timeout` case).
## * `stream_big`: `size` bytes of `patternByte` in flushed parts of `part`
##   bytes, pausing `pause_ms` between parts (a producer that takes its
##   time, so that clients disconnect while the handler is still running).
## * `stream_stats`: how many isonim_rpc requests this worker has released.

import std/[asyncdispatch, asyncnet, strutils, json]
import isonim/server/context
import ../../../src/app_registry
import ../../../src/rpc
import stream_pattern

proc registerStreamApps*() =
  registerAsyncApp("stream_await", proc(ctx: RequestContext): Future[void] {.async.} =
    let body = ctx.bodyWriter
    body.write(shellHtml)
    body.flush()
    let port = parseInt(ctx.request.queryParam("port", "0"))
    let sock = newAsyncSocket()
    await sock.connect("127.0.0.1", Port(port))
    let got = await sock.recv(1)
    sock.close()
    body.write("<p id=\"rest\">rest:" & got & "</p></body></html>")
    body.flush())

  registerAsyncApp("stream_whole", proc(ctx: RequestContext): Future[void] {.async.} =
    let body = ctx.bodyWriter
    ctx.response.setHeader("X-Stream-App", "whole")
    body.write("<p>whole-1</p>")
    ctx.write("<p>whole-2</p>")
    body.write("<p>whole-3</p>"))

  registerAsyncApp("stream_raise_before", proc(ctx: RequestContext): Future[void] {.async.} =
    let body = ctx.bodyWriter
    body.write("<p>never sent</p>")
    raise newException(ValueError, "stream_raise_before raised"))

  registerAsyncApp("stream_raise_after", proc(ctx: RequestContext): Future[void] {.async.} =
    let body = ctx.bodyWriter
    body.write(shellHtml)
    body.flush()
    await sleepAsync(0)
    raise newException(ValueError, "stream_raise_after raised"))

  registerAsyncApp("stream_hang", proc(ctx: RequestContext): Future[void] {.async.} =
    let body = ctx.bodyWriter
    body.write(shellHtml)
    body.flush()
    await newFuture[void]("stream_hang: never completed"))

  registerAsyncApp("stream_big", proc(ctx: RequestContext): Future[void] {.async.} =
    let body = ctx.bodyWriter
    let size = parseInt(ctx.request.queryParam("size", "0"))
    let part = max(1, parseInt(ctx.request.queryParam("part", "8192")))
    let pauseMs = parseInt(ctx.request.queryParam("pause_ms", "0"))
    var buf = newString(part)
    var written = 0
    while written < size:
      let n = min(part, size - written)
      buf.setLen(n)
      for i in 0 ..< n:
        buf[i] = patternByte(written + i)
      body.write(buf)
      body.flush()
      written += n
      if pauseMs > 0 and written < size:
        await sleepAsync(pauseMs))

  registerAsyncApp("stream_stats", proc(ctx: RequestContext): Future[void] {.async.} =
    ctx.respondJson(200, $(%*{"released": rpcRequestsReleased()})))
