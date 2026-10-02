## rpc_app.nim
##
## Server functions and an async app compiled into the end-to-end module
## (registered by e2e_apps.nim), driven over real nginx by
## tests/e2e/test_rpc.nim.  Their endpoints are `/api/rpc_app/<proc>`.
##
## * `sum`: the plain round trip.
## * `bodySize`: the length of a (large) argument.
## * `sleepThen`: suspends in `sleepAsync`, so the worker must serve other
##   requests meanwhile; also the isonim_rpc_timeout case.  `sleepingNow`
##   tells how many are suspended.
## * `whoAmI`: what the request context holds (request, session, CSRF).
## * `selfFetch`: an AsyncSocket request to this same nginx, which only
##   completes if the worker keeps serving while the socket waits (the
##   dispatcher's descriptor in the worker's event loop).
## * `fails`: raises.
## * the async app `rpc_echo`: any method, the body echoed.

import std/[asyncdispatch, asyncnet, json, strutils]
import isonim/server/[pragma, rpc, context]
import ../../../src/app_registry

type Who* = object
  subject*: string
  path*: string
  csrf*: string
  clientAddr*: string

proc sum(a, b: int): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  return a + b

proc bodySize(data: string): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  return data.len

var sleeping: int
  ## How many `sleepThen` calls are suspended right now.

proc sleepThen(ms: int; tag: string): Future[string]
    {.server(auth = aPublic, csrf = csrfAnon).} =
  inc sleeping
  try:
    await sleepAsync(ms)
  finally:
    dec sleeping
  return tag

proc sleepingNow(): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  ## Lets a test wait until a `sleepThen` is in its handler.
  return sleeping

proc whoAmI(ctx: RequestContext): Future[Who] {.server(auth = aSession).} =
  return Who(subject: ctx.session.subject, path: ctx.request.path,
             csrf: $ctx.csrf, clientAddr: ctx.request.clientAddr)

proc selfFetch(port: int; path: string): Future[string]
    {.server(auth = aPublic, csrf = csrfAnon).} =
  let sock = newAsyncSocket()
  await sock.connect("127.0.0.1", Port(port))
  await sock.send("GET " & path & " HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
  var response = ""
  while true:
    let chunk = await sock.recv(4096)
    if chunk.len == 0: break
    response.add chunk
  sock.close()
  let sep = response.find("\r\n\r\n")
  return if sep < 0: "" else: response[sep + 4 .. ^1]

proc fails(): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  raise newException(ValueError, "rpc_app.fails was called")

proc registerRpcApps*() =
  serverHooks.resolveSession = proc(req: SsrRequest): Future[Session] {.async.} =
    if req.cookie("sid") == "alice":
      return Session(subject: "alice", csrfToken: "alice-csrf")
    return nil
  registerAsyncApp("rpc_echo", proc(ctx: RequestContext): Future[void] {.async.} =
    ctx.respondJson(200, $(%*{"method": ctx.request.httpMethod,
                              "path": ctx.request.path,
                              "bodyLength": ctx.request.body.len})))
