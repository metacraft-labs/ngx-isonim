## test_worker_start.nim
##
## The Nim runtime and the applications start with each worker, before its
## first request (spec/isonim-nginx.md, "Runtime start"), against a real
## nginx with two worker processes and the real module
## (tests/e2e/harness.nim), driving the background task and the async app
## `start_test` of tests/e2e/apps/start_app.nim.
##
## * test_worker_runs_app_tasks_from_its_start: with no request sent, each
##   worker runs the task its registration started (a 20 ms timer, then a
##   file named after the worker's pid): both workers' files appear. Then
##   the first request a worker serves reports that its task had already
##   run.
##   VACUITY GUARD: the files are named by our master's children (read from
##   /proc), and no request had been sent when they were read.
##
## Falsifying mutations, each a test of its own ("mutant: ..."): the
## runtime started lazily on the first request (the init_process call
## removed), and the runtime started without running the loop once (the
## `pump()` after the registration removed, so the task's timer is never
## armed). Under each, no worker writes its file before a request.
##
## Synchronization: polls of the files with a deadline; a mutant's run
## waits the same deadline for files that must not appear.
##
## No mocks: real nginx, real workers.
##
## Run: nim c -r tests/e2e/test_worker_start.nim  (in the dev shell)

import std/[unittest, json, os, strutils, times, monotimes, net, sets]
import harness

const
  workers = 2
  startLocations = """
    location /start/ { isonim_rpc on; isonim_rpc_app start_test; }
"""
  deadlineMs = 10_000

proc startedWorkers(dir: string; pids: seq[int]): HashSet[int] =
  ## The workers among `pids` whose task wrote its file.
  for pid in pids:
    if fileExists(dir / $pid): result.incl pid

proc waitStarted(n: Nginx; dir: string): tuple[pids: seq[int], started: HashSet[int]] =
  ## Polls until every worker wrote its file, at most `deadlineMs`.
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  while true:
    result.pids = n.workerPids
    result.started = startedWorkers(dir, result.pids)
    if result.started.len == workers or getMonoTime() > deadline: return
    sleep(20)

proc get(n: Nginx; path: string): JsonNode =
  let s = newSocket()
  defer: s.close()
  s.connect("127.0.0.1", Port(n.port), timeout = 5000)
  s.send("GET " & path & " HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
  var raw = ""
  while true:
    let chunk = s.recv(4096, timeout = 10_000)
    if chunk.len == 0: break
    raw.add chunk
  let sep = raw.find("\r\n\r\n")
  doAssert sep > 0 and raw.startsWith("HTTP/1.1 200"), "unexpected answer: " & raw
  parseJson(raw[sep + 4 .. ^1])

proc runStart(module: string): tuple[pids: seq[int], started: HashSet[int], first: JsonNode] =
  let dir = getTempDir() / ("ngx-isonim-start-" & $getCurrentProcessId() & "-" & $getMonoTime().ticks)
  createDir(dir)
  defer: removeDir(dir)
  var n = startNginx(module, startLocations, workerProcesses = workers,
                     mainConf = "env START_TEST_DIR=" & dir & ";\n")
  defer: n.stop()
  let (pids, started) = n.waitStarted(dir)
  result.pids = pids
  result.started = started
  # Only now the first request.
  result.first = n.get("/start/")

suite "worker start":
  test "test_worker_runs_app_tasks_from_its_start":
    let r = runStart(testModule())
    check r.pids.len == workers
    check r.started.len == workers
    check r.first{"task_ran"}.getBool
    check r.first{"served"}.getInt == 1
    check r.first{"pid"}.getInt in r.pids

  test "mutant: the runtime started lazily, on the first request":
    let m = buildMutant("lazy-start", "src/ngx_http_isonim_module.c",
      """        slots[ngx_worker] = 0;
    }
    ngx_http_isonim_init_nim();
    return NGX_OK;""", """        slots[ngx_worker] = 0;
    }
    return NGX_OK;""")
    let r = runStart(m)
    check r.pids.len == workers
    check r.started.len == 0            # the assertion above fails

  test "mutant: the runtime started without running the loop":
    let m = buildMutant("no-pump", "src/handler.nim",
      "    startAsyncLoop()\n    # Run what the registration queued and arm the timer for what waits, so\n" &
      "    # a background task an app started runs now, not at the first request.\n    pump()",
      "    startAsyncLoop()")
    let r = runStart(m)
    check r.pids.len == workers
    check r.started.len == 0            # the assertion above fails
