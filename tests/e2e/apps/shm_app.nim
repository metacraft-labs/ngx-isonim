## shm_app.nim
##
## Async apps over application shared-memory zones (src/shm_table.nim),
## compiled into the end-to-end module (registered by e2e_apps.nim) and
## driven over real nginx by tests/e2e/test_shm_zone.nim.
##
## `shm_test` (at an `isonim_rpc` location, any method) answers JSON that
## always names the worker's pid.  The operation is the last path segment;
## the zone is `?zone=`, the key `?key=`, a stored value the request body:
##
## * `pid`: just the pid;
## * `get`: `found`, `version`, `value`;
## * `put`, `putif` (`?expected=`): `result` (stored, conflict, tooLarge,
##   full) and `version` or `currentVersion`;
## * `incr` (`?delta=&low=&high=`): `result` and `value` or `current`;
## * `delete` (`?expected=` optional): `deleted`;
## * `stats`: the zone's ShmStats;
## * `tget`, `tput`: the same through a typed table whose codec version is
##   the environment's `SHM_TEST_CODEC_VERSION` (default 1; nginx passes it
##   with the `env` directive, so a reload can change it without a new
##   module build, which would get a new zone anyway);
## * `hold` (`?release=`): stores the worker's pid under `holder`, then
##   waits (polling the zone on the event loop, at most 30 s) until the key
##   `release` exists, stores `old_store` = `from-old-<pid>` and answers:
##   the request a reload test holds open on an old worker;
## * `die` (`?fifo=`): arms the test-build store hook and stores the body
##   under `key`.  Inside the zone's lock, before the entry is linked, the
##   hook logs `shm test hook: inside the lock of zone "<zone>" (pid <pid>)`,
##   writes its pid to the FIFO (blocking until the test reads it) and then
##   blocks forever: the test kills the worker by that pid.
##
## `shm_undeclared` binds the zone `not_declared_zone`, which no test
## configuration declares, on every request: its requests answer 500 with
## the zone named in the error log.
##
## With `SHM_TEST_BIND_AT_REGISTRATION=<zone>` in the workers' environment,
## `registerShmApps` binds that zone while the apps are registered, so a
## zone missing from the configuration fails the worker's registration.

import std/[asyncdispatch, json, os, posix, strutils, tables, times, monotimes]
import isonim/server/context
import ../../../src/app_registry
import ../../../src/shm_table
import ../../../src/nginx_types

var zoneTables: Table[string, ShmTable]
  ## This worker's handles, by zone name.

proc tableOf(zone: string): ShmTable =
  if zone notin zoneTables:
    zoneTables[zone] = shmTable(zone)
  zoneTables[zone]

proc codecVersion(): uint32 =
  uint32(parseInt(getEnv("SHM_TEST_CODEC_VERSION", "1")))

proc strBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc bytesStr(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

var typedTables: Table[string, ShmTypedTable[string, string]]

proc typedOf(zone: string): ShmTypedTable[string, string] =
  if zone notin typedTables:
    typedTables[zone] = shmTypedTable[string, string](zone, "e2e-strings",
      codecVersion(), strBytes, strBytes, bytesStr)
  typedTables[zone]

proc putJson(r: ShmPut): JsonNode =
  result = %*{"result": $r.kind}
  case r.kind
  of stored: result["version"] = %r.version
  of conflict: result["currentVersion"] = %r.currentVersion
  of tooLarge, full: discard

proc logCycle(msg: string) =
  ngx_http_isonim_log_cycle(NGX_LOG_ERR, unsafeAddr msg[0], csize_t(msg.len))

var dieFifo: string
  ## Where the armed hook reports its pid.

proc dieInsideLock(zone: string) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let pid = getpid()
    logCycle("shm test hook: inside the lock of zone \"" & zone & "\" (pid " &
      $pid & ")")
    # Blocks until the test opens the FIFO for reading.
    let fd = posix.open(cstring(dieFifo), O_WRONLY)
    if fd >= 0:
      let line = $pid & "\n"
      discard posix.write(fd, unsafeAddr line[0], line.len)
      discard posix.close(fd)
    while true:
      discard posix.pause()

proc handleShm(ctx: RequestContext): Future[void] {.async.} =
  let req = ctx.request
  let op = req.path.split('/')[^1]
  let zone = req.queryParam("zone", "")
  let key = req.queryParam("key", "")
  var answer = %*{"pid": int(getpid())}
  case op
  of "pid":
    discard
  of "get":
    var value: string
    let version = tableOf(zone).get(key, value)
    answer["found"] = %version.isSome
    if version.isSome:
      answer["version"] = %version.get
      answer["value"] = %value
  of "put":
    for k, v in putJson(tableOf(zone).put(key, req.body)): answer[k] = v
  of "putif":
    let expected = parseBiggestUInt(req.queryParam("expected", "0"))
    for k, v in putJson(tableOf(zone).putIf(key, req.body, uint64(expected))):
      answer[k] = v
  of "incr":
    let r = tableOf(zone).incr(key, parseBiggestInt(req.queryParam("delta")),
      parseBiggestInt(req.queryParam("low")),
      parseBiggestInt(req.queryParam("high")))
    answer["result"] = %($r.kind)
    case r.kind
    of counted: answer["value"] = %r.value
    of outOfRange: answer["current"] = %r.current
    else: discard
  of "delete":
    let expected =
      if req.hasQueryParam("expected"):
        uint64(parseBiggestUInt(req.queryParam("expected")))
      else: anyVersion
    answer["deleted"] = %tableOf(zone).delete(key, expected)
  of "stats":
    let s = tableOf(zone).stats
    answer["stats"] = %*{"entries": s.entries, "bytesUsed": s.bytesUsed,
      "bytesFree": s.bytesFree, "entryBytes": s.entryBytes,
      "stores": s.stores, "evictions": s.evictions,
      "refusedFull": s.refusedFull, "refusedTooLarge": s.refusedTooLarge,
      "lockWaits": s.lockWaits, "size": s.size, "maxValue": s.maxValue}
  of "tget":
    let e = typedOf(zone).get(key)
    answer["found"] = %e.isSome
    if e.isSome:
      answer["value"] = %e.get.value
      answer["version"] = %e.get.version
  of "tput":
    for k, v in putJson(typedOf(zone).put(key, req.body)): answer[k] = v
  of "hold":
    let t = tableOf(zone)
    let pid = $getpid()
    discard t.put("holder", pid)
    let release = req.queryParam("release")
    let deadline = getMonoTime() + initDuration(seconds = 30)
    var scratch: seq[byte]
    while t.get(release, scratch).isNone:
      if getMonoTime() > deadline:
        raise newException(IOError, "hold: never released")
      await sleepAsync(5)
    for k, v in putJson(t.put("old_store", "from-old-" & pid)): answer[k] = v
  of "die":
    dieFifo = req.queryParam("fifo")
    let t = tableOf(zone)
    shmStoreHook = dieInsideLock
    discard t.put(key, req.body)
  else:
    ctx.respondJson(404, $(%*{"error": "unknown operation " & op}))
    return
  ctx.respondJson(200, $answer)

proc registerShmApps*() =
  let atRegistration = getEnv("SHM_TEST_BIND_AT_REGISTRATION")
  if atRegistration.len > 0:
    discard shmTable(atRegistration)
  registerAsyncApp("shm_test", handleShm)
  registerAsyncApp("shm_undeclared",
    proc(ctx: RequestContext): Future[void] {.async.} =
      discard tableOf("not_declared_zone")
      ctx.respondJson(200, "{}"))
