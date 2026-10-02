## app_registry.nim
##
## Registry mapping app names (`isonim_ssr_app <name>`) to renderers.
##
## A renderer receives the request and the response it may shape:
##
## * `SsrRenderer` returns the whole body as a string;
## * `SsrStreamingRenderer` writes the body through a `ResponseBody`,
##   flushing as parts become ready (the shell first, then Suspense
##   boundaries).
##
## Either kind works on either transport (`isonim_ssr_mode streaming` or
## `buffered`): the transport decides how the bytes travel, the renderer
## decides what they are.
##
## The renderer signatures of earlier versions (`proc(): string` and
## `proc(onChunk, onComplete)`) are still accepted by `registerApp` and
## `registerStreamingApp`, adapted to the new ones; such renderers simply
## ignore the request and leave the response at its defaults.
##
## An *async app* (`registerAsyncApp`) is an IsoNim `RequestHandler`: it
## receives a `RequestContext` (request with body, response, session, CSRF
## verdict) and completes a future, leaving the response in the context.
## It is served at an `isonim_rpc` location named by `isonim_rpc_app`
## (rpc.nim); a route manifest's `manifestApp` is one.

import std/tables
import request, response, response_body
import isonim/server/context

export request, response, response_body, context

type
  SsrRenderer* = proc(req: SsrRequest; resp: SsrResponse): string
    ## Renders the whole body.

  SsrStreamingRenderer* = proc(req: SsrRequest; resp: SsrResponse;
                               body: ResponseBody)
    ## Writes the body through `body`; returning ends the response.

  AppRenderer* = proc(): string
    ## Earlier signature, kept so existing apps compile unchanged.

  StreamingAppRenderer* = proc(onChunk: proc(chunk: string), onComplete: proc())
    ## Earlier streaming signature: each `onChunk` is written and flushed.

  AppKind* = enum
    akString     ## an SsrRenderer
    akStreaming  ## an SsrStreamingRenderer
    akAsync      ## a RequestHandler, for isonim_rpc locations

  AppEntry* = ref object
    ## A registered app.
    case kind*: AppKind
    of akString:
      render*: SsrRenderer
    of akStreaming:
      renderStream*: SsrStreamingRenderer
    of akAsync:
      handle*: RequestHandler

var appRegistry: Table[string, AppEntry]

proc stringApp*(renderer: SsrRenderer): AppEntry =
  AppEntry(kind: akString, render: renderer)

proc streamingApp*(renderer: SsrStreamingRenderer): AppEntry =
  AppEntry(kind: akStreaming, renderStream: renderer)

proc adapt*(renderer: AppRenderer): SsrRenderer =
  ## Wraps an argument-less renderer.
  if renderer.isNil: return nil
  result = proc(req: SsrRequest; resp: SsrResponse): string = renderer()

proc adapt*(renderer: StreamingAppRenderer): SsrStreamingRenderer =
  ## Wraps an onChunk/onComplete renderer: every chunk is written and
  ## flushed, so each one reaches the client as soon as it is produced.
  if renderer.isNil: return nil
  result = proc(req: SsrRequest; resp: SsrResponse; body: ResponseBody) =
    renderer(
      proc(chunk: string) =
        body.write(chunk)
        body.flush(),
      proc() = discard)

proc registerApp*(name: string; renderer: SsrRenderer) =
  ## Registers a string renderer under `name`, replacing any app there.
  if renderer.isNil:
    raise newException(ValueError, "nil renderer for app '" & name & "'")
  appRegistry[name] = stringApp(renderer)

proc registerApp*(name: string; renderer: AppRenderer) =
  registerApp(name, adapt(renderer))

proc registerStreamingApp*(name: string; renderer: SsrStreamingRenderer) =
  ## Registers a streaming renderer under `name`, replacing any app there.
  if renderer.isNil:
    raise newException(ValueError, "nil renderer for app '" & name & "'")
  appRegistry[name] = streamingApp(renderer)

proc registerStreamingApp*(name: string; renderer: StreamingAppRenderer) =
  registerStreamingApp(name, adapt(renderer))

proc registerAsyncApp*(name: string; handler: RequestHandler) =
  ## Registers an async app under `name`, replacing any app there.  Serve
  ## it with `isonim_rpc on; isonim_rpc_app <name>;`.
  if handler.isNil:
    raise newException(ValueError, "nil handler for app '" & name & "'")
  appRegistry[name] = AppEntry(kind: akAsync, handle: handler)

proc lookupApp*(name: string): AppEntry =
  ## The app registered under `name`, or nil.
  appRegistry.getOrDefault(name, nil)

proc clearApps*() =
  ## Removes every registered app.  Used by tests.
  appRegistry.clear()
