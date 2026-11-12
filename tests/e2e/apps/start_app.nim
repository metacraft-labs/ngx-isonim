## start_app.nim
##
## A background task started while the apps are registered, compiled into
## the end-to-end module (registered by e2e_apps.nim) and driven over real
## nginx by tests/e2e/test_worker_start.nim
## (spec/isonim-nginx.md, "Runtime start").
##
## With `START_TEST_DIR=<dir>` in the workers' environment (nginx's `env`
## directive), `registerStartApps` starts a task on the worker's event loop
## that first waits on a timer (20 ms) and then writes `<dir>/<pid>`: a
## worker that has written its file ran the task, timer included, on its
## own loop. The async app `start_test` answers JSON naming the worker's
## pid, whether its task has run and how many requests the app has served
## (this one included).

import std/[asyncdispatch, json, os, posix]
import isonim/server/context
import ../../../src/app_registry

var
  taskRan: bool
  served: int

proc background(dir: string) {.async.} =
  await sleepAsync(20)
  taskRan = true
  writeFile(dir / $getpid(), "ran")

proc registerStartApps*() =
  let dir = getEnv("START_TEST_DIR")
  if dir.len > 0:
    asyncCheck background(dir)
  registerAsyncApp("start_test", proc (ctx: RequestContext): Future[void] {.async.} =
    inc served
    ctx.respondJson(200, $(%*{"pid": int(getpid()), "task_ran": taskRan, "served": served})))
