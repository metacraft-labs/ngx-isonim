## harness.nim
##
## Runs a real nginx with the real module for the end-to-end tests.
##
## * `testModule()` builds the module with the end-to-end apps compiled in
##   (scripts/build-module.sh, `-d:ngxIsonimTestApps`), or uses the one named
##   by `NGX_ISONIM_E2E_MODULE` (the Justfile builds it once for all tests).
## * `buildMutant()` builds the module from a copy of the sources with one
##   exact text replacement: the tests use it to show that an assertion
##   fails when the behaviour it guards is broken (falsifying mutations).
##   A file under `isonim/` (e.g. `isonim/src/isonim/server/response.nim`)
##   is mutated in a copy of the isonim sibling's `src/`, which the mutant
##   is then built against.
## * `startNginx()` starts nginx on a free port in a private prefix with the
##   given `location` blocks, and waits until it accepts connections.
## * `testConfig()` runs `nginx -t` on such a configuration; `reload()`
##   rewrites it and sends our master SIGHUP, `waitForWorkers()` waits until
##   the reload has replaced the workers; `workerPids()` are our master's
##   children (read from /proc, so only processes we started are named).
## * `curl()` runs curl and returns its exit code, output and stderr.
##
## Needs `nginx`, `curl` and `NGX_DEV_HEADERS` from the dev shell.  Nothing
## here is mocked: these tests exist to check the module over the wire.

import std/[os, osproc, strutils, net, times, monotimes, streams]

const repoRoot* = currentSourcePath().parentDir.parentDir.parentDir

type
  Nginx* = object
    prefix*: string
    port*: int
    errorLog*: string
    pidFile*: string
    module*: string
    locations*: string
    workerProcesses*: int
    httpConf*: string
    mainConf*: string
    listenOptions*: string

  CurlResult* = object
    exitCode*: int
    output*: string
    stderr*: string

proc run(cmd: string; args: openArray[string]; workDir = ""): tuple[code: int, output: string] =
  let p = startProcess(cmd, workingDir = workDir, args = args,
                       options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (code, output)

proc buildModuleAt(root, mode, output: string; extra: seq[string]) =
  let (code, log) = run("bash", @[root / "scripts/build-module.sh", mode,
                        output] & extra, workDir = root)
  if code != 0:
    raise newException(OSError, "module build failed (" & mode & "):\n" &
      log[max(0, log.len - 4000) .. ^1])

proc testModule*(mode = "release"): string =
  ## The module with the end-to-end apps.  A release build comes from
  ## NGX_ISONIM_E2E_MODULE when set; otherwise it is built under build/e2e.
  if mode == "release" and existsEnv("NGX_ISONIM_E2E_MODULE"):
    return getEnv("NGX_ISONIM_E2E_MODULE")
  result = repoRoot / "build/e2e" / mode / "ngx_http_isonim_module.so"
  buildModuleAt(repoRoot, mode, result, @["-d:ngxIsonimTestApps"])

proc siblingPaths(isonimSrc = ""): string =
  let ws = repoRoot.parentDir
  [ws / "nim-faststreams", ws / "nim-stew",
   (if isonimSrc.len > 0: isonimSrc else: ws / "isonim/src"),
   ws / "nim-everywhere/src"].join(":")

proc buildMutant*(name, file, original, replacement: string): string =
  ## Builds the module from a copy of the sources in which `original`
  ## (which must occur exactly once in `file`, relative to the repository)
  ## is replaced by `replacement`.
  let root = getTempDir() / ("ngx-isonim-mutant-" & name & "-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  copyDir(repoRoot / "src", root / "src")
  copyDir(repoRoot / "scripts", root / "scripts")
  createDir(root / "tests/e2e")
  copyDir(repoRoot / "tests/e2e/apps", root / "tests/e2e/apps")
  copyFile(repoRoot / "nim.cfg", root / "nim.cfg")
  var isonimSrc = ""
  var path = root / file
  if file.startsWith("isonim/"):
    # The file is IsoNim's: mutate a copy of the sibling's src/.
    copyDir(repoRoot.parentDir / "isonim/src", root / "isonim/src")
    isonimSrc = root / "isonim/src"
    path = root / file
  let text = readFile(path)
  let n = text.count(original)
  if n != 1:
    raise newException(ValueError, "mutation '" & name & "': expected one " &
      "occurrence of the original text in " & file & ", found " & $n)
  writeFile(path, text.replace(original, replacement))
  putEnv("NGX_ISONIM_PATHS", siblingPaths(isonimSrc))
  try:
    result = root / "ngx_http_isonim_module.so"
    buildModuleAt(root, "release", result, @["-d:ngxIsonimTestApps"])
  finally:
    delEnv("NGX_ISONIM_PATHS")

proc freePort(): int =
  let s = newSocket()
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])
  s.close()

proc portOpen(port: int): bool =
  let s = newSocket()
  try:
    s.connect("127.0.0.1", Port(port), timeout = 200)
    result = true
  except CatchableError:
    result = false
  finally:
    s.close()

proc childPids*(pid: int): seq[int] =
  ## The live processes whose parent is `pid` (from /proc/<pid>/stat).
  for kind, dir in walkDir("/proc"):
    let name = dir.extractFilename
    if name.len == 0 or not name.allCharsInSet(Digits):
      continue
    var stat = ""
    try:
      stat = readFile(dir / "stat")
    except IOError, OSError:
      continue
    # pid (comm) state ppid ...; comm may hold spaces and parentheses.
    let close = stat.rfind(')')
    if close < 0: continue
    let fields = stat[close + 2 .. ^1].splitWhitespace()
    if fields.len >= 2 and fields[0] != "Z" and fields[1] == $pid:
      result.add parseInt(name)

proc writeConf(n: Nginx) =
  writeFile(n.prefix / "nginx.conf", """
load_module $1;
worker_processes $2;
error_log $3 info;
pid $4;
$9
events { worker_connections 1024; }
http {
  access_log off;
  client_body_temp_path $5/client_body;
  proxy_temp_path $5/proxy;
  fastcgi_temp_path $5/fastcgi;
  uwsgi_temp_path $5/uwsgi;
  scgi_temp_path $5/scgi;
$8
  server {
    listen 127.0.0.1:$6$10;
$7
  }
}
""" % [n.module, $n.workerProcesses, n.errorLog, n.pidFile,
       n.prefix, $n.port, n.locations, n.httpConf, n.mainConf,
       (if n.listenOptions.len > 0: " " & n.listenOptions else: "")])

proc newPrefix(): string =
  result = getTempDir() / ("ngx-isonim-e2e-" & $getCurrentProcessId() &
                           "-" & $getMonoTime().ticks)
  createDir(result)
  for d in ["client_body", "proxy", "fastcgi", "uwsgi", "scgi"]:
    createDir(result / d)

proc startNginx*(module: string; locations: string;
                 workerProcesses = 1; httpConf = ""; mainConf = "";
                 listenOptions = ""): Nginx =
  ## Starts nginx with `locations` inside its only server block.
  ## `httpConf` goes into the http block (e.g. `isonim_shm_zone` lines),
  ## `mainConf` into the main context (e.g. `env` lines), `listenOptions`
  ## after the listen address (e.g. `reuseport`).
  result.prefix = newPrefix()
  result.port = freePort()
  result.errorLog = result.prefix / "error.log"
  result.pidFile = result.prefix / "nginx.pid"
  result.module = module
  result.locations = locations
  result.workerProcesses = workerProcesses
  result.httpConf = httpConf
  result.mainConf = mainConf
  result.listenOptions = listenOptions
  result.writeConf()
  let conf = result.prefix / "nginx.conf"
  # nginx daemonizes, and its master would keep any pipe it inherits open
  # (osproc's pipes leak into grandchildren), so a reader waiting for EOF
  # would wait for nginx to exit.  Start it through system() with its
  # output in a file instead.
  let startLog = result.prefix / "start.log"
  let code = execShellCmd("nginx -c " & quoteShell(conf) &
    " -p " & quoteShell(result.prefix) & " -e " & quoteShell(result.errorLog) &
    " < /dev/null > " & quoteShell(startLog) & " 2>&1")
  if code != 0:
    raise newException(OSError, "nginx failed to start:\n" &
      readFile(startLog) &
      (if fileExists(result.errorLog): readFile(result.errorLog) else: ""))
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while not portOpen(result.port):
    if getMonoTime() > deadline:
      raise newException(OSError, "nginx did not open port " & $result.port)
    sleep(20)
  # The listening sockets open before nginx daemonizes; its master writes
  # the pid file after.  Wait for it and for the master's workers, so that
  # masterPid and workerPids name them.
  while true:
    var pid = 0
    try:
      pid = parseInt(readFile(result.pidFile).strip())
    except IOError, ValueError:
      discard
    if pid > 0 and childPids(pid).len >= workerProcesses:
      break
    if getMonoTime() > deadline:
      raise newException(OSError, "nginx wrote no pid file, or started " &
        "fewer than " & $workerProcesses & " workers")
    sleep(20)

proc testConfig*(module: string; locations: string; httpConf = "";
                 mainConf = ""): tuple[code: int, output: string] =
  ## Runs `nginx -t` on a configuration like startNginx's.
  var n = Nginx(prefix: newPrefix(), port: freePort(), module: module,
                locations: locations, workerProcesses: 1, httpConf: httpConf,
                mainConf: mainConf)
  n.errorLog = n.prefix / "error.log"
  n.pidFile = n.prefix / "nginx.pid"
  n.writeConf()
  let outFile = n.prefix / "t.log"
  let code = execShellCmd("nginx -t -c " & quoteShell(n.prefix / "nginx.conf") &
    " -p " & quoteShell(n.prefix) & " -e " & quoteShell(n.errorLog) &
    " < /dev/null > " & quoteShell(outFile) & " 2>&1")
  (code, readFile(outFile))

proc masterPid*(n: Nginx): int =
  ## Our nginx master's pid, from its pid file.
  parseInt(readFile(n.pidFile).strip())

proc workerPids*(n: Nginx): seq[int] =
  ## Our master's children: its workers (accepting or shutting down).
  childPids(n.masterPid)

proc reload*(n: var Nginx; httpConf: string; mainConf = n.mainConf) =
  ## Rewrites the configuration and sends our master SIGHUP.  The caller
  ## waits for the new workers (`waitForWorkers`).
  n.httpConf = httpConf
  n.mainConf = mainConf
  n.writeConf()
  discard run("kill", ["-HUP", $n.masterPid])

proc waitForWorkers*(n: Nginx; old: seq[int]; keep: seq[int] = @[];
                     timeoutMs = 20_000): seq[int] =
  ## Waits until our master has `workerProcesses` workers none of which is
  ## in `old`, and every pid of `old` but those in `keep` has exited (a
  ## reload has completed).  Returns the new workers.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    let now = n.workerPids
    var fresh: seq[int]
    var oldLeft = false
    for p in now:
      if p in old:
        if p notin keep: oldLeft = true
      else:
        fresh.add p
    if fresh.len == n.workerProcesses and not oldLeft:
      return fresh
    if getMonoTime() > deadline:
      raise newException(OSError, "the reload did not complete: workers " &
        $now & ", old " & $old & ", kept " & $keep)
    sleep(10)

proc processAlive*(pid: int): bool =
  ## Whether `pid` exists and is not a zombie.
  var stat = ""
  try:
    stat = readFile("/proc/" & $pid & "/stat")
  except IOError, OSError:
    return false
  not stat.contains(") Z ")

proc stop*(n: Nginx) =
  ## Stops our nginx: SIGTERM to its master; if it has not exited within
  ## 10 s (e.g. a worker spins on a lock that is never released), SIGKILL
  ## to each of its workers (our master's children) and to the master.
  if not fileExists(n.pidFile):
    return
  var pid = 0
  try:
    pid = n.masterPid
  except ValueError, IOError:
    return
  discard run("kill", ["-TERM", $pid])
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while processAlive(pid) and getMonoTime() < deadline:
    sleep(20)
  if processAlive(pid):
    for child in childPids(pid):
      discard run("kill", ["-KILL", $child])
    discard run("kill", ["-KILL", $pid])
    let killDeadline = getMonoTime() + initDuration(seconds = 5)
    while processAlive(pid) and getMonoTime() < killDeadline:
      sleep(20)

proc url*(n: Nginx; path: string): string =
  "http://127.0.0.1:" & $n.port & path

proc errorLogText*(n: Nginx): string =
  if fileExists(n.errorLog): readFile(n.errorLog) else: ""

var curlCount = 0

proc curl*(args: openArray[string]): CurlResult =
  ## Runs curl; its stderr goes through a file (`--stderr`) so a verbose
  ## run cannot fill a pipe while stdout is being read.
  inc curlCount
  let errFile = getTempDir() / ("ngx-isonim-curl-" & $getCurrentProcessId() &
                                "-" & $curlCount & ".err")
  let p = startProcess("curl", args = @["--stderr", errFile] & @args,
                       options = {poUsePath})
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()
  p.close()
  result.stderr = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)

proc splitResponse*(raw: string): tuple[statusLine: string,
    headers: seq[(string, string)], body: string] =
  ## Splits `curl -i` output (one response) into its parts.
  let sep = raw.find("\r\n\r\n")
  let head = if sep < 0: raw else: raw[0 ..< sep]
  result.body = if sep < 0: "" else: raw[sep + 4 .. ^1]
  let lines = head.split("\r\n")
  result.statusLine = lines[0]
  for line in lines[1 .. ^1]:
    let colon = line.find(':')
    if colon > 0:
      result.headers.add((line[0 ..< colon], line[colon + 1 .. ^1].strip()))

proc headerValues*(headers: seq[(string, string)]; name: string): seq[string] =
  for (k, v) in headers:
    if cmpIgnoreCase(k, name) == 0:
      result.add v
