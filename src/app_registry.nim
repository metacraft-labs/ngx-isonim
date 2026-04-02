## app_registry.nim
##
## Registry mapping app names to render functions.
## The handler looks up the app by name from the location config
## and calls the corresponding renderer to produce HTML.

import std/tables

type
  AppRenderer* = proc(): string
    ## Returns rendered HTML for the page.

var appRegistry: Table[string, AppRenderer]

proc registerApp*(name: string, renderer: AppRenderer) =
  ## Register an app renderer under the given name.
  appRegistry[name] = renderer

proc getApp*(name: string): AppRenderer =
  ## Look up a registered app by name.
  ## Returns nil if no app is registered under that name.
  if name in appRegistry:
    return appRegistry[name]
  return nil

proc clearApps*() =
  ## Remove all registered apps. Used by tests for cleanup.
  appRegistry.clear()
