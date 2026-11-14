## ssr_router.nim
##
## Per-request routing for apps served by the module: the request's path
## selects the component through IsoNim's SSR router
## (isonim-routing-server-functions.md §SSR Routing).
##
## `routedApp(routes)` is an `SsrRenderer` for `registerApp`.  It renders
## the route matching `req.path` (nginx's decoded, normalized path) and
## answers a path no route matches with status `404` and the router's
## not-found fragment.

import isonim/routing/[ssr, match]
import app_registry

export ssr, match

proc routedApp*(buildRoutes: proc(req: SsrRequest; resp: SsrResponse):
                  seq[SsrRouteEntry]): SsrRenderer =
  ## Builds the route table per request, so components can close over the
  ## request (its cookies, its query) and the response (its status and
  ## headers).
  result = proc(req: SsrRequest; resp: SsrResponse): string =
    let routes = buildRoutes(req, resp)
    if not matchesRoute(routes, req.path):
      resp.status = 404
    renderRoute(routes, req.path)

proc routedApp*(routes: seq[SsrRouteEntry]): SsrRenderer =
  ## A fixed route table.
  routedApp(proc(req: SsrRequest; resp: SsrResponse): seq[SsrRouteEntry] =
    routes)
