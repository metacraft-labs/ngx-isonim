## test_single_process.nim
##
## nginx with `master_process off` (one process, no workers), against a real
## nginx and the real module (tests/e2e/harness.nim). In that mode nginx
## serves no request after a SIGHUP reconfiguration, with or without the
## module: it reruns only its configuration (ngx_init_cycle) in the running
## process, never the event module's per-process start that gives a cycle
## its connections and puts its listening sockets in the event loop (nginx
## 1.28.3, src/os/unix/ngx_process_cycle.c, ngx_single_process_cycle). A
## request then gets no HTTP response (measured: nothing, or nginx's own
## "worker_connections are not enough" alert on the socket). The module
## cannot change that, so it says it:
##
## * test_single_process_warns_at_start_and_on_reconfiguration: the warning
##   line is in the error log exactly once after the start, the module
##   answers, and after a SIGHUP the error line is logged (and the warning
##   still appears once: it is per start, not per cycle).
## * the CONTROL, plain nginx without the module: it answers before the
##   SIGHUP and gives no HTTP response after it. When a future nginx serves again
##   after a single-process reconfiguration, this control fails, and the
##   limitation (the module's warning and error, and spec/isonim-nginx.md's
##   note) is to be removed.
## * mutant: no warning at start: the warning count is 0 and the first test's
##   assertion fails.
##
## Synchronization: the error log is polled with a deadline; the control's
## "no HTTP response" is a request whose first line, if any arrives within
## 3 s, is not an HTTP status line.
##
## No mocks: real nginx, the real module.
##
## Run: nim c -r tests/e2e/test_single_process.nim  (in the dev shell)

import std/[unittest, os, strutils, monotimes, times, net]
import harness

const
  locations = """
    location /start/ { isonim_rpc on; isonim_rpc_app start_test; }
    location /plain/ { return 200 "plain\n"; }
"""
  single = "master_process off;\n"
  warning = "isonim: master_process is off: nginx stops serving requests after a SIGHUP reconfiguration in this " &
            "mode; restart nginx to apply a new configuration"
  reloadError = "isonim: SIGHUP reconfiguration with master_process off: nginx does not serve requests after it in " &
                "this mode; restart nginx"

proc statusLine(n: Nginx; path: string; timeoutMs = 3000): string =
  ## The status line of a GET, or "" when nothing answers within the timeout.
  let s = newSocket()
  defer: s.close()
  try:
    s.connect("127.0.0.1", Port(n.port), timeout = timeoutMs)
    s.send("GET " & path & " HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
    result = s.recvLine(timeout = timeoutMs)
  except TimeoutError, OSError:
    result = ""

proc waitLog(n: Nginx; text: string; deadlineMs = 10_000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  while getMonoTime() < deadline:
    if text in n.errorLogText: return true
    sleep(20)
  text in n.errorLogText

proc sighup(n: var Nginx) =
  n.reload(n.httpConf)

proc warnedRun(module: string): tuple[warnings, after: int, answered: string, reloadLogged: bool] =
  var n = startNginx(module, locations, mainConf = single)
  defer: n.stop()
  result.answered = n.statusLine("/start/")
  discard n.waitLog(warning, 2000)
  result.warnings = n.errorLogText.count(warning)
  n.sighup()
  result.reloadLogged = n.waitLog(reloadError)
  result.after = n.errorLogText.count(warning)

suite "single process":
  test "test_single_process_warns_at_start_and_on_reconfiguration":
    let r = warnedRun(testModule())
    check r.answered.startsWith("HTTP/1.1 200")
    check r.warnings == 1
    check r.reloadLogged
    check r.after == 1

  test "control: plain nginx serves no request after a single-process SIGHUP":
    var n = startNginx("", locations.replace(
      "    location /start/ { isonim_rpc on; isonim_rpc_app start_test; }\n", ""), mainConf = single)
    defer: n.stop()
    check n.statusLine("/plain/").startsWith("HTTP/1.1 200")
    n.sighup()
    check n.waitLog("reconfiguring")
    sleep(500)
    let after = n.statusLine("/plain/")
    if after.startsWith("HTTP/"):
      echo "    nginx now serves after a single-process reconfiguration (", after,
        "): remove the module's warning and error and the documented limitation"
    else:
      echo "    after the SIGHUP, the first line nginx sent: ", (if after.len > 0: after else: "(none)")
    check not after.startsWith("HTTP/")

  test "mutant: no warning at start":
    let m = buildMutant("no-single-warning", "src/ngx_http_isonim_module.c",
      """        ngx_log_error(NGX_LOG_WARN, cycle->log, 0,
                      NGX_HTTP_ISONIM_SINGLE_WARNING);""", "")
    let r = warnedRun(m)
    check r.warnings == 0            # the first test's assertion fails
