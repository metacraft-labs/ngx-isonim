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
## * `startNginx()` starts nginx on a free port in a private prefix with the
##   given `location` blocks, and waits until it accepts connections.
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

proc siblingPaths(): string =
  let ws = repoRoot.parentDir
  [ws / "nim-faststreams", ws / "nim-stew", ws / "isonim/src",
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
  let path = root / file
  let text = readFile(path)
  let n = text.count(original)
  if n != 1:
    raise newException(ValueError, "mutation '" & name & "': expected one " &
      "occurrence of the original text in " & file & ", found " & $n)
  writeFile(path, text.replace(original, replacement))
  putEnv("NGX_ISONIM_PATHS", siblingPaths())
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

proc startNginx*(module: string; locations: string;
                 workerProcesses = 1): Nginx =
  ## Starts nginx with `locations` inside its only server block.
  result.prefix = getTempDir() / ("ngx-isonim-e2e-" & $getCurrentProcessId() &
                                  "-" & $getMonoTime().ticks)
  createDir(result.prefix)
  for d in ["client_body", "proxy", "fastcgi", "uwsgi", "scgi"]:
    createDir(result.prefix / d)
  result.port = freePort()
  result.errorLog = result.prefix / "error.log"
  result.pidFile = result.prefix / "nginx.pid"
  let conf = result.prefix / "nginx.conf"
  writeFile(conf, """
load_module $1;
worker_processes $2;
error_log $3 info;
pid $4;
events { worker_connections 1024; }
http {
  access_log off;
  client_body_temp_path $5/client_body;
  proxy_temp_path $5/proxy;
  fastcgi_temp_path $5/fastcgi;
  uwsgi_temp_path $5/uwsgi;
  scgi_temp_path $5/scgi;
  server {
    listen 127.0.0.1:$6;
$7
  }
}
""" % [module, $workerProcesses, result.errorLog, result.pidFile,
       result.prefix, $result.port, locations])
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

proc stop*(n: Nginx) =
  if fileExists(n.pidFile):
    let pid = readFile(n.pidFile).strip()
    discard run("kill", ["-TERM", pid])
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while dirExists("/proc/" & pid) and getMonoTime() < deadline:
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
