## app_registry.nim
##
## Registry mapping app names to render functions.
## The handler looks up the app by name from the location config
## and calls the corresponding renderer to produce HTML.

import std/tables

type
  AppRenderer* = proc(): string
    ## Returns rendered HTML for the page.

  StreamingAppRenderer* = proc(onChunk: proc(chunk: string), onComplete: proc())
    ## Streaming renderer that calls onChunk for each piece of output.
    ## Calls onComplete when all content (including Suspense boundaries) is done.
    ## The shell is the first chunk (TTFB).
    ## Subsequent chunks are Suspense boundary replacements.

var appRegistry: Table[string, AppRenderer]
var streamingAppRegistry: Table[string, StreamingAppRenderer]

proc registerApp*(name: string, renderer: AppRenderer) =
  ## Register an app renderer under the given name.
  appRegistry[name] = renderer

proc getApp*(name: string): AppRenderer =
  ## Look up a registered app by name.
  ## Returns nil if no app is registered under that name.
  if name in appRegistry:
    return appRegistry[name]
  return nil

proc registerStreamingApp*(name: string, renderer: StreamingAppRenderer) =
  ## Register a streaming app renderer under the given name.
  streamingAppRegistry[name] = renderer

proc getStreamingApp*(name: string): StreamingAppRenderer =
  ## Look up a registered streaming app by name.
  ## Returns nil if no streaming app is registered under that name.
  if name in streamingAppRegistry:
    return streamingAppRegistry[name]
  return nil

proc clearApps*() =
  ## Remove all registered apps. Used by tests for cleanup.
  appRegistry.clear()
  streamingAppRegistry.clear()
