## shm_table.nim
##
## Node-wide state for applications: a key/value table in an nginx
## shared-memory zone, shared by every worker of one nginx
## (spec/isonim-nginx.md, "Shared-Memory Zones for Applications").
##
## A zone is declared in the nginx configuration, in the `http` block:
##
## ```nginx
## isonim_shm_zone forum_routes size=8m max_value=1k;
## ```
##
## and an application binds it by name, usually in its `registerApps()`:
##
## ```nim
## let routes = shmTable("forum_routes")
## var value: seq[byte]
## let version = routes.get("example.org", value)     # Option[uint64]
## case routes.putIf("example.org", newValue, version.get(0)).kind
## of stored: discard
## of conflict: discard     # another worker stored first: re-read, decide again
## of tooLarge, full: discard
## ```
##
## The contract, as implemented here:
##
## * **Values are copied in and out.**  No pointer into the zone ever
##   reaches the caller, so eviction and other workers can never invalidate
##   what a caller holds.  Keys are 1 to 255 bytes, values at most the
##   zone's `max_value`; an empty key is a programming error (`ValueError`),
##   an oversized key or value answers `tooLarge` and changes nothing.
## * **Versions.**  Every store draws a 64-bit version from the zone's
##   counter, which starts at 1 and is never reused in the zone's lifetime,
##   so a deleted and re-created key never repeats one.  `putIf` stores
##   only at the version the caller read (`0`: only when absent).
## * **One lock per zone**: the slab pool's own mutex (`ngx_shmtx_t`), which
##   the nginx master releases when a worker dies holding it.  It is held
##   only inside this module, for a lookup, a copy and at most the
##   allocation and evictions of one store: never across application code
##   (the typed layer's encoders run before it is taken, its decoders after
##   it is released), an `await` or any I/O.
## * **Publication.**  A store writes its entry completely, then links it in
##   place of the old one with one pointer store, then frees the old one.  A
##   worker that dies before the link leaves the old entry (and at worst one
##   unreachable chunk until the zone is next recreated).
## * **Eviction.**  Entries form one least-recently-used list per zone
##   (`get` and every store move an entry to its head).  When the slab
##   allocator cannot satisfy a store, the store frees entries from the
##   tail, at most 16, retrying after each; a store that still finds no room
##   answers `full` and changes nothing.  A counter (`incr`) that is not 0
##   is kept off the list, so it is never evicted.
## * **Hashing.**  Keys are hashed with SipHash-2-4 under a random key drawn
##   when the zone is first bound, so request-derived keys (host names, ...)
##   cannot be chosen to collide in one chain while the lock is held.
##
## Compiled with `-d:isNginxTest` (the mock-mode unit tests) the zones are
## process-local arenas declared with `declareShmZoneForTest`, with the same
## table code over them; the lock then also checks that it is never taken
## twice, and `shmZoneLockedForTest` lets a test check that it is not held
## while an encoder or decoder runs.

import std/[options, os, sysrand]

export options

const
  shmHeaderFile = currentSourcePath().parentDir() / "ngx_http_isonim_shm.h"
    ## The layout shared with ngx_http_isonim_module.c.

  shmMagic = 0x4953484D5A4F4E45'u64      ## NGX_HTTP_ISONIM_SHM_MAGIC
  shmLayout = 1'u32                      ## NGX_HTTP_ISONIM_SHM_LAYOUT
  codecNameMax* = 64                     ## NGX_HTTP_ISONIM_SHM_CODEC_NAME_MAX

  maxKeyLen* = 255
    ## Keys are 1 to 255 bytes.
  maxEvictionsPerStore* = 16
    ## A store frees at most this many entries before it answers `full`.
  anyVersion* = high(uint64)
    ## `delete`'s default: whatever the entry's version.  Never a real
    ## version (they count up from 1).

type
  ShmZoneError* = object of CatchableError
    ## A zone that cannot be bound: not declared by `isonim_shm_zone`, with
    ## another layout, or (typed tables) another codec.  The message names
    ## the zone.

  ShmPutKind* = enum
    stored      ## the value was stored; `version` is its new version
    conflict    ## (`putIf`) the entry was at `currentVersion`, not the expected one
    tooLarge    ## the key or the value is over its bound; nothing changed
    full        ## no room even after evicting; nothing changed

  ShmPut* = object
    ## What a store answered.
    case kind*: ShmPutKind
    of stored:
      version*: uint64
    of conflict:
      currentVersion*: uint64    ## 0: the key is absent
    of tooLarge, full:
      discard

  ShmIncrKind* = enum
    counted       ## the counter now holds `value`
    outOfRange    ## the result would leave `[low, high]`; the counter holds `current`
    notCounter    ## the key holds a value `put` stored, not a counter; nothing changed
    tooLarge      ## the key is over 255 bytes; nothing changed
    full          ## the counter is new and there is no room; nothing changed

  ShmIncr* = object
    ## What `incr` answered.
    case kind*: ShmIncrKind
    of counted:
      value*: int64
    of outOfRange:
      current*: int64
    of notCounter, tooLarge, full:
      discard

  ShmStats* = object
    ## A zone's counters, read under its lock.
    entries*: uint64
    bytesUsed*: uint64        ## the slab pool's pages in use, in bytes
    bytesFree*: uint64        ## its free pages, in bytes
    entryBytes*: uint64       ## bytes allocated for entries
    stores*: uint64           ## put, putIf and incr calls that changed the zone
    evictions*: uint64
    refusedFull*: uint64
    refusedTooLarge*: uint64
    lockWaits*: uint64        ## lock acquisitions that found it held
    size*: uint64             ## the zone's size=
    maxValue*: uint64         ## the zone's max_value=

  ShmHeader {.importc: "ngx_http_isonim_shm_header_t", header: shmHeaderFile,
              bycopy.} = object
    magic: uint64
    layout: uint32
    codec_set: uint32
    size: uint64
    max_value: uint64
    hash_k0: uint64
    hash_k1: uint64
    next_version: uint64
    buckets: pointer
    nbuckets: uint64
    lru_head: pointer
    lru_tail: pointer
    entries: uint64
    entry_bytes: uint64
    stores: uint64
    evictions: uint64
    refused_full: uint64
    refused_too_large: uint64
    lock_waits: uint64
    codec_version: uint32
    codec_name_len: uint32
    codec_name: array[codecNameMax, char]

  ShmZoneInfo {.importc: "ngx_http_isonim_shm_info_t", header: shmHeaderFile,
                bycopy.} = object
    pool: pointer
    data: ptr pointer
    size: uint64
    max_value: uint64

  ShmEntry = object
    ## One entry in the zone, followed by its key (padded to 8 bytes) and
    ## its value.  Only this module reads or writes it.
    hnext: ptr ShmEntry       ## hash chain
    lprev: ptr ShmEntry       ## towards the head (more recently used)
    lnext: ptr ShmEntry       ## towards the tail
    version: uint64
    hash: uint64
    allocSize: uint64
    valueLen: uint32
    keyLen: uint16
    counter: uint8            ## 1: created by `incr` (8-byte signed value)
    inLru: uint8              ## 1: on the least-recently-used list

  ShmTable* = object
    ## A worker's handle on a zone.  Valid for the worker's lifetime.
    name: string
    pool: pointer
    hdr: ptr ShmHeader
    maxValue: int
    size: uint64

static:
  doAssert sizeof(ShmEntry) mod 8 == 0

proc name*(t: ShmTable): string = t.name
  ## The zone's name.
proc maxValue*(t: ShmTable): int = t.maxValue
  ## The zone's max_value=, in bytes.
proc isBound*(t: ShmTable): bool = not t.hdr.isNil
  ## False for a default-initialized handle.

# ---------------------------------------------------------------------------
# The zone primitives: nginx's (ngx_http_isonim_module.c), or a mock arena
# ---------------------------------------------------------------------------

when not defined(isNginxTest):
  proc ngx_http_isonim_shm_find(name: ptr char; len: csize_t;
                                info: ptr ShmZoneInfo): int
    {.importc, cdecl.}
  proc ngx_http_isonim_shm_lock(pool: pointer): int {.importc, cdecl.}
  proc ngx_http_isonim_shm_unlock(pool: pointer) {.importc, cdecl.}
  proc ngx_http_isonim_shm_alloc(pool: pointer; size: csize_t): pointer
    {.importc, cdecl.}
  proc ngx_http_isonim_shm_free(pool, p: pointer) {.importc, cdecl.}
  proc ngx_http_isonim_shm_pages(pool: pointer; total, free: ptr uint64)
    {.importc, cdecl.}

  proc findZone(name: string; info: var ShmZoneInfo): bool =
    if name.len == 0: return false
    ngx_http_isonim_shm_find(unsafeAddr name[0], csize_t(name.len),
                             addr info) == 0

  proc zoneLock(pool: pointer): bool = ngx_http_isonim_shm_lock(pool) != 0
  proc zoneUnlock(pool: pointer) = ngx_http_isonim_shm_unlock(pool)
  proc zoneAlloc(pool: pointer; size: int): pointer =
    ngx_http_isonim_shm_alloc(pool, csize_t(size))
  proc zoneFree(pool, p: pointer) = ngx_http_isonim_shm_free(pool, p)
  proc zonePages(pool: pointer): tuple[total, free: uint64] =
    ngx_http_isonim_shm_pages(pool, addr result.total, addr result.free)

else:
  proc c_malloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
  proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

  type
    MockZone = ref object
      ## A process-local stand-in for a zone: a byte budget over malloc.
      name: string
      size, maxValue: uint64
      capacity, used: uint64
      data: pointer            ## pool->data
      locked: bool
      allocations: int

  var mockZones: seq[MockZone]

  const mockOverhead = 4096'u64
    ## What a real zone loses to the slab pool's own structures, roughly.

  proc declareShmZoneForTest*(name: string; size: int; maxValue = 4096) =
    ## Declares a mock zone, as `isonim_shm_zone name size= max_value=`
    ## would.  Test builds only.
    for z in mockZones:
      doAssert z.name != name, "zone declared twice: " & name
    mockZones.add MockZone(name: name, size: uint64(size),
      maxValue: uint64(maxValue), capacity: uint64(size) - mockOverhead)

  proc clearShmZonesForTest*() =
    ## Forgets every mock zone (their memory is not reclaimed).
    mockZones.setLen(0)

  proc shmZoneLockedForTest*(name: string): bool =
    ## Whether the mock zone's lock is held right now.
    for z in mockZones:
      if z.name == name: return z.locked

  proc shmZoneAllocationsForTest*(name: string): int =
    ## Live allocations in the mock zone (header, buckets and entries).
    for z in mockZones:
      if z.name == name: return z.allocations

  proc findZone(name: string; info: var ShmZoneInfo): bool =
    for z in mockZones:
      if z.name == name:
        info.pool = cast[pointer](z)
        info.data = addr z.data
        info.size = z.size
        info.max_value = z.maxValue
        return true

  proc zoneLock(pool: pointer): bool =
    let z = cast[MockZone](pool)
    doAssert not z.locked, "the zone's lock was taken twice"
    z.locked = true
    false

  proc zoneUnlock(pool: pointer) =
    let z = cast[MockZone](pool)
    doAssert z.locked, "the zone's lock was released while not held"
    z.locked = false

  proc zoneAlloc(pool: pointer; size: int): pointer =
    let z = cast[MockZone](pool)
    doAssert z.locked, "allocation outside the zone's lock"
    let total = uint64(size) + 16
    if z.used + total > z.capacity: return nil
    let p = c_malloc(csize_t(total))
    if p.isNil: return nil
    cast[ptr uint64](p)[] = total
    z.used += total
    inc z.allocations
    cast[pointer](cast[uint](p) + 16)

  proc zoneFree(pool, p: pointer) =
    let z = cast[MockZone](pool)
    doAssert z.locked, "free outside the zone's lock"
    let base = cast[pointer](cast[uint](p) - 16)
    z.used -= cast[ptr uint64](base)[]
    dec z.allocations
    c_free(base)

  proc zonePages(pool: pointer): tuple[total, free: uint64] =
    let z = cast[MockZone](pool)
    (z.capacity, z.capacity - z.used)

when defined(ngxIsonimTestApps) or defined(isNginxTest):
  var shmStoreHook*: proc(zone: string) {.nimcall, gcsafe.}
    ## Test builds only (`-d:ngxIsonimTestApps`, mock mode): called inside
    ## the zone's lock in the middle of a store, after its entry is written
    ## and before it is linked.  The worker-death test blocks here.

# ---------------------------------------------------------------------------
# SipHash-2-4 (https://cr.yp.to/siphash/siphash-20120918.pdf)
# ---------------------------------------------------------------------------

proc rotl(x: uint64; b: int): uint64 {.inline.} =
  (x shl b) or (x shr (64 - b))

proc sipHash24*(k0, k1: uint64; data: openArray[byte]): uint64 =
  ## SipHash-2-4 of `data` under the key (k0, k1), both little-endian
  ## halves of the 128-bit key.
  var
    v0 = 0x736f6d6570736575'u64 xor k0
    v1 = 0x646f72616e646f6d'u64 xor k1
    v2 = 0x6c7967656e657261'u64 xor k0
    v3 = 0x7465646279746573'u64 xor k1
  template sipRound() =
    v0 += v1; v1 = rotl(v1, 13); v1 = v1 xor v0; v0 = rotl(v0, 32)
    v2 += v3; v3 = rotl(v3, 16); v3 = v3 xor v2
    v0 += v3; v3 = rotl(v3, 21); v3 = v3 xor v0
    v2 += v1; v1 = rotl(v1, 17); v1 = v1 xor v2; v2 = rotl(v2, 32)
  let blocks = data.len div 8
  for i in 0 ..< blocks:
    var m = 0'u64
    for j in 0 .. 7:
      m = m or (uint64(data[i * 8 + j]) shl (8 * j))
    v3 = v3 xor m
    sipRound()
    sipRound()
    v0 = v0 xor m
  var b = uint64(data.len and 0xff) shl 56
  for j in 0 ..< data.len mod 8:
    b = b or (uint64(data[blocks * 8 + j]) shl (8 * j))
  v3 = v3 xor b
  sipRound()
  sipRound()
  v0 = v0 xor b
  v2 = v2 xor 0xff
  sipRound()
  sipRound()
  sipRound()
  sipRound()
  v0 xor v1 xor v2 xor v3

# ---------------------------------------------------------------------------
# Entries and their lists (all with the zone's lock held)
# ---------------------------------------------------------------------------

proc align8(n: int): int {.inline.} = (n + 7) and not 7

proc entrySize(keyLen, valueLen: int): int =
  sizeof(ShmEntry) + align8(keyLen) + valueLen

proc keyPtr(e: ptr ShmEntry): ptr UncheckedArray[byte] {.inline.} =
  cast[ptr UncheckedArray[byte]](cast[uint](e) + uint(sizeof(ShmEntry)))

proc valuePtr(e: ptr ShmEntry): ptr UncheckedArray[byte] {.inline.} =
  cast[ptr UncheckedArray[byte]](cast[uint](e) + uint(sizeof(ShmEntry)) +
    uint(align8(int(e.keyLen))))

proc counterPtr(e: ptr ShmEntry): ptr int64 {.inline.} =
  ## A counter's value: 8 bytes at an 8-aligned offset, so that it is
  ## written with one aligned store.
  cast[ptr int64](e.valuePtr)

proc chains(h: ptr ShmHeader): ptr UncheckedArray[ptr ShmEntry] {.inline.} =
  cast[ptr UncheckedArray[ptr ShmEntry]](h.buckets)

proc headEntry(h: ptr ShmHeader): ptr ShmEntry {.inline.} =
  cast[ptr ShmEntry](h.lru_head)

proc tailEntry(h: ptr ShmHeader): ptr ShmEntry {.inline.} =
  cast[ptr ShmEntry](h.lru_tail)

proc bucketOf(h: ptr ShmHeader; hash: uint64): int {.inline.} =
  int(hash and (h.nbuckets - 1))

proc keyEquals(e: ptr ShmEntry; key: openArray[byte]): bool =
  if int(e.keyLen) != key.len: return false
  equalMem(e.keyPtr, unsafeAddr key[0], key.len)

proc lookup(h: ptr ShmHeader; hash: uint64; key: openArray[byte]): ptr ShmEntry =
  var e = h.chains[h.bucketOf(hash)]
  while e != nil:
    if e.hash == hash and e.keyEquals(key):
      return e
    e = e.hnext
  nil

proc lruRemove(h: ptr ShmHeader; e: ptr ShmEntry) =
  if e.inLru == 0: return
  if e.lprev != nil: e.lprev.lnext = e.lnext
  else: h.lru_head = e.lnext
  if e.lnext != nil: e.lnext.lprev = e.lprev
  else: h.lru_tail = e.lprev
  e.lprev = nil
  e.lnext = nil
  e.inLru = 0

proc lruPushHead(h: ptr ShmHeader; e: ptr ShmEntry) =
  e.lprev = nil
  e.lnext = h.headEntry
  if e.lnext != nil: e.lnext.lprev = e
  h.lru_head = e
  if h.lru_tail == nil: h.lru_tail = e
  e.inLru = 1

proc evictable(e: ptr ShmEntry): bool {.inline.} =
  ## A counter that is not 0 is never evicted.
  e.counter == 0 or e.counterPtr[] == 0

proc placeInLru(h: ptr ShmHeader; e: ptr ShmEntry) =
  ## Puts `e` at the head of the list, or keeps it off the list when it is
  ## a counter that is not 0.
  h.lruRemove(e)
  if e.evictable:
    h.lruPushHead(e)

proc unlinkFromChain(h: ptr ShmHeader; e: ptr ShmEntry) =
  var link = addr h.chains[h.bucketOf(e.hash)]
  while link[] != nil and link[] != e:
    link = addr link[].hnext
  if link[] == e:
    link[] = e.hnext

proc removeEntry(t: ShmTable; e: ptr ShmEntry) =
  ## Unlinks `e` from its chain and the list, and frees it.
  let h = t.hdr
  h.unlinkFromChain(e)
  h.lruRemove(e)
  dec h.entries
  h.entry_bytes -= e.allocSize
  zoneFree(t.pool, e)

proc allocEntry(t: ShmTable; size: int; protect: ptr ShmEntry): ptr ShmEntry =
  ## Allocates `size` bytes, evicting from the least-recently-used end (at
  ## most `maxEvictionsPerStore` entries) while the slab allocator has no
  ## room.  `protect`, the entry this store replaces, is never evicted.
  ## nil: no room.
  let h = t.hdr
  var p = zoneAlloc(t.pool, size)
  var evicted = 0
  while p.isNil and evicted < maxEvictionsPerStore:
    var victim = h.tailEntry
    if victim == protect and victim != nil:
      victim = victim.lprev
    if victim.isNil:
      break
    t.removeEntry(victim)
    inc h.evictions
    inc evicted
    p = zoneAlloc(t.pool, size)
  cast[ptr ShmEntry](p)

proc publish(t: ShmTable; e, old: ptr ShmEntry) =
  ## Links the completely written entry `e` in place of `old` (nil: a new
  ## key), then frees `old`.  The single store to the chain link is the
  ## publication point.
  let h = t.hdr
  let b = h.bucketOf(e.hash)
  if old.isNil:
    e.hnext = h.chains[b]
    h.chains[b] = e
    inc h.entries
  else:
    e.hnext = old.hnext
    var link = addr h.chains[b]
    while link[] != old:
      link = addr link[].hnext
    link[] = e
    h.lruRemove(old)
    h.entry_bytes -= old.allocSize
    zoneFree(t.pool, old)
  h.entry_bytes += e.allocSize
  h.placeInLru(e)

template withZoneLock(t: ShmTable; body: untyped) =
  ## Runs `body` with the zone's lock held, and releases it whatever
  ## happens (`return` included).  `body` must be this module's code only.
  let waited = zoneLock(t.pool)
  try:
    if waited:
      inc t.hdr.lock_waits
    body
  finally:
    zoneUnlock(t.pool)

proc checkKey(key: openArray[byte]) =
  if key.len == 0:
    raise newException(ValueError, "shared-memory keys are 1 to " &
      $maxKeyLen & " bytes; the key is empty")

proc hashOf(t: ShmTable; key: openArray[byte]): uint64 {.inline.} =
  sipHash24(t.hdr.hash_k0, t.hdr.hash_k1, key)

proc requireBound(t: ShmTable) =
  if t.hdr.isNil:
    raise newException(ShmZoneError, "the shared-memory table is not " &
      "bound (use shmTable(name))")

# ---------------------------------------------------------------------------
# Binding
# ---------------------------------------------------------------------------

proc bucketCount(size: uint64): uint64 =
  ## One chain per KiB of zone, a power of two, at least 64.
  result = 64
  while result < size div 1024:
    result = result shl 1

proc shmTable*(name: string): ShmTable =
  ## The worker's handle on the zone `isonim_shm_zone <name>` declares.
  ## The first bind in the zone's lifetime sets up its header.  Raises
  ## `ShmZoneError` naming the zone when the configuration does not declare
  ## it, or when it cannot be set up.
  var info: ShmZoneInfo
  if not findZone(name, info):
    raise newException(ShmZoneError, "shared-memory zone \"" & name &
      "\" is not declared (isonim_shm_zone in the nginx configuration's " &
      "http block)")
  var seed: array[16, byte]
  if not urandom(seed):
    raise newException(ShmZoneError, "shared-memory zone \"" & name &
      "\": no randomness for its hash key")
  result = ShmTable(name: name, pool: info.pool, maxValue: int(info.max_value),
                    size: info.size)
  var failure = ""
  let waited = zoneLock(info.pool)
  try:
    var h = cast[ptr ShmHeader](info.data[])
    if h.isNil:
      h = cast[ptr ShmHeader](zoneAlloc(info.pool, sizeof(ShmHeader)))
      let nb = bucketCount(info.size)
      let b = if h.isNil: nil
              else: zoneAlloc(info.pool, int(nb) * sizeof(pointer))
      if h.isNil or b.isNil:
        if not h.isNil: zoneFree(info.pool, h)
        failure = "has no room for its table"
      else:
        zeroMem(h, sizeof(ShmHeader))
        zeroMem(b, int(nb) * sizeof(pointer))
        var k0, k1: uint64
        copyMem(addr k0, addr seed[0], 8)
        copyMem(addr k1, addr seed[8], 8)
        h.layout = shmLayout
        h.size = info.size
        h.max_value = info.max_value
        h.hash_k0 = k0
        h.hash_k1 = k1
        h.next_version = 1
        h.buckets = b
        h.nbuckets = nb
        h.magic = shmMagic
        # Last: the master's reload check reads the header once this is set.
        info.data[] = h
    elif h.magic != shmMagic or h.layout != shmLayout or
         h.size != info.size or h.max_value != info.max_value:
      failure = "holds a table of another layout, size or max_value"
    elif waited:
      inc h.lock_waits
    result.hdr = h
  finally:
    zoneUnlock(info.pool)
  if failure.len > 0:
    result.hdr = nil
    raise newException(ShmZoneError, "shared-memory zone \"" & name & "\" " &
      failure)

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

proc get*(t: ShmTable; key: openArray[byte]; dst: var seq[byte]): Option[uint64] =
  ## The entry's version, with its value copied into `dst`; `none` when the
  ## key is absent (`dst` is then left as it was).  Marks the entry
  ## recently used.  A counter's value is its 8 bytes, little-endian.
  t.requireBound()
  checkKey(key)
  if key.len > maxKeyLen:
    return none(uint64)
  let hash = t.hashOf(key)
  var found = false
  var corrupt = false
  var version = 0'u64
  t.withZoneLock:
    let e = t.hdr.lookup(hash, key)
    if e != nil and (int(e.valueLen) > t.maxValue or
        uint64(entrySize(int(e.keyLen), int(e.valueLen))) > e.allocSize):
      # Never happens with entries this module wrote (they are linked only
      # once complete); a copy out of an inconsistent one would read past it.
      corrupt = true
    elif e != nil:
      dst.setLen(int(e.valueLen))
      if e.valueLen > 0:
        copyMem(addr dst[0], e.valuePtr, int(e.valueLen))
      if e.inLru != 0:
        t.hdr.lruRemove(e)
        t.hdr.lruPushHead(e)
      version = e.version
      found = true
  if corrupt:
    raise newException(ShmZoneError, "shared-memory zone \"" & t.name &
      "\" holds an inconsistent entry")
  if found: some(version) else: none(uint64)

proc store(t: ShmTable; key, value: openArray[byte]; conditional: bool;
           expected: uint64): ShmPut =
  t.requireBound()
  checkKey(key)
  if key.len > maxKeyLen or value.len > t.maxValue:
    t.withZoneLock:
      inc t.hdr.refused_too_large
    return ShmPut(kind: tooLarge)
  let hash = t.hashOf(key)
  let size = entrySize(key.len, value.len)
  t.withZoneLock:
    let h = t.hdr
    let old = h.lookup(hash, key)
    if conditional:
      let current = if old.isNil: 0'u64 else: old.version
      if current != expected:
        return ShmPut(kind: conflict, currentVersion: current)
    let e = t.allocEntry(size, old)
    if e.isNil:
      inc h.refused_full
      return ShmPut(kind: full)
    zeroMem(e, sizeof(ShmEntry))
    e.hash = hash
    e.allocSize = uint64(size)
    e.keyLen = uint16(key.len)
    e.valueLen = uint32(value.len)
    copyMem(e.keyPtr, unsafeAddr key[0], key.len)
    if value.len > 0:
      copyMem(e.valuePtr, unsafeAddr value[0], value.len)
    e.version = h.next_version
    inc h.next_version
    when declared(shmStoreHook):
      if shmStoreHook != nil:
        shmStoreHook(t.name)
    t.publish(e, old)
    inc h.stores
    return ShmPut(kind: stored, version: e.version)

proc put*(t: ShmTable; key, value: openArray[byte]): ShmPut =
  ## Stores `value` under `key` unconditionally.
  t.store(key, value, false, 0)

proc putIf*(t: ShmTable; key, value: openArray[byte]; expected: uint64): ShmPut =
  ## Stores only when the entry's version is `expected` (`0`: only when the
  ## key is absent); otherwise answers `conflict` with the current version.
  t.store(key, value, true, expected)

proc incr*(t: ShmTable; key: openArray[byte]; delta, low, high: int64): ShmIncr =
  ## Adds `delta` to the 8-byte signed counter under `key` (absent counts as
  ## 0) only when the result stays within `[low, high]`; otherwise answers
  ## `outOfRange` with the current value.  A counter that is not 0 is never
  ## evicted.  The value is updated in place with one aligned 8-byte store.
  t.requireBound()
  checkKey(key)
  if low > high:
    raise newException(ValueError, "incr: low (" & $low & ") is above high (" &
      $high & ")")
  if key.len > maxKeyLen:
    t.withZoneLock:
      inc t.hdr.refused_too_large
    return ShmIncr(kind: tooLarge)
  let hash = t.hashOf(key)
  t.withZoneLock:
    let h = t.hdr
    var e = h.lookup(hash, key)
    if e != nil and e.counter == 0:
      return ShmIncr(kind: notCounter)
    let current = if e.isNil: 0'i64 else: e.counterPtr[]
    let overflows =
      (delta > 0 and current > high(int64) - delta) or
      (delta < 0 and current < low(int64) - delta)
    if overflows:
      return ShmIncr(kind: outOfRange, current: current)
    let next = current + delta
    if next < low or next > high:
      return ShmIncr(kind: outOfRange, current: current)
    if e.isNil:
      let size = entrySize(key.len, 8)
      e = t.allocEntry(size, nil)
      if e.isNil:
        inc h.refused_full
        return ShmIncr(kind: full)
      zeroMem(e, sizeof(ShmEntry))
      e.hash = hash
      e.allocSize = uint64(size)
      e.keyLen = uint16(key.len)
      e.valueLen = 8
      e.counter = 1
      copyMem(e.keyPtr, unsafeAddr key[0], key.len)
      e.counterPtr[] = next
      e.version = h.next_version
      inc h.next_version
      t.publish(e, nil)
    else:
      e.counterPtr[] = next
      e.version = h.next_version
      inc h.next_version
      h.placeInLru(e)
    inc h.stores
    return ShmIncr(kind: counted, value: next)

proc delete*(t: ShmTable; key: openArray[byte]; expected = anyVersion): bool =
  ## Removes the entry (only at version `expected` when given).  True when
  ## an entry was removed.
  t.requireBound()
  checkKey(key)
  if key.len > maxKeyLen:
    return false
  let hash = t.hashOf(key)
  t.withZoneLock:
    let e = t.hdr.lookup(hash, key)
    if e.isNil or (expected != anyVersion and e.version != expected):
      return false
    t.removeEntry(e)
    return true

proc stats*(t: ShmTable): ShmStats =
  ## The zone's counters.
  t.requireBound()
  t.withZoneLock:
    let h = t.hdr
    let pages = zonePages(t.pool)
    result = ShmStats(entries: h.entries,
      bytesUsed: pages.total - pages.free, bytesFree: pages.free,
      entryBytes: h.entry_bytes, stores: h.stores, evictions: h.evictions,
      refusedFull: h.refused_full, refusedTooLarge: h.refused_too_large,
      lockWaits: h.lock_waits, size: h.size, maxValue: h.max_value)

# String conveniences: keys and values as Nim strings (bytes, not text).

proc get*(t: ShmTable; key: string; dst: var seq[byte]): Option[uint64] =
  t.get(key.toOpenArrayByte(0, key.high), dst)

proc get*(t: ShmTable; key: string; dst: var string): Option[uint64] =
  ## As `get`, with the value copied into a string.
  var bytes: seq[byte]
  result = t.get(key.toOpenArrayByte(0, key.high), bytes)
  if result.isSome:
    dst.setLen(bytes.len)
    if bytes.len > 0:
      copyMem(addr dst[0], addr bytes[0], bytes.len)

proc put*(t: ShmTable; key, value: string): ShmPut =
  t.put(key.toOpenArrayByte(0, key.high), value.toOpenArrayByte(0, value.high))

proc putIf*(t: ShmTable; key, value: string; expected: uint64): ShmPut =
  t.putIf(key.toOpenArrayByte(0, key.high),
          value.toOpenArrayByte(0, value.high), expected)

proc incr*(t: ShmTable; key: string; delta, low, high: int64): ShmIncr =
  t.incr(key.toOpenArrayByte(0, key.high), delta, low, high)

proc delete*(t: ShmTable; key: string; expected = anyVersion): bool =
  t.delete(key.toOpenArrayByte(0, key.high), expected)

# ---------------------------------------------------------------------------
# The typed layer
# ---------------------------------------------------------------------------

type
  ShmTypedTable*[K, V] = object
    ## A table whose keys and values are encoded by the application's
    ## codec.  The codec's name and version are recorded in the zone's
    ## header at the first typed bind and checked at every later one.
    table*: ShmTable
    encodeKey: proc(k: K): seq[byte]
    encodeValue: proc(v: V): seq[byte]
    decodeValue: proc(b: openArray[byte]): V

  ShmTypedEntry*[V] = object
    value*: V
    version*: uint64

proc bindCodec*(t: ShmTable; codecName: string; codecVersion: uint32) =
  ## Records the codec in the zone's header, or checks it against the one
  ## recorded.  Raises `ShmZoneError` naming the zone on a mismatch.
  t.requireBound()
  if codecName.len == 0 or codecName.len > codecNameMax:
    raise newException(ValueError, "a codec name is 1 to " & $codecNameMax &
      " bytes")
  var recorded = ""
  var recordedVersion = 0'u32
  var mismatch = false
  t.withZoneLock:
    let h = t.hdr
    if h.codec_set == 0:
      for i in 0 ..< codecName.len:
        h.codec_name[i] = codecName[i]
      h.codec_name_len = uint32(codecName.len)
      h.codec_version = codecVersion
      h.codec_set = 1
    else:
      recorded.setLen(int(min(h.codec_name_len, uint32(codecNameMax))))
      for i in 0 ..< recorded.len:
        recorded[i] = h.codec_name[i]
      recordedVersion = h.codec_version
      mismatch = recorded != codecName or recordedVersion != codecVersion
  if mismatch:
    raise newException(ShmZoneError, "shared-memory zone \"" & t.name &
      "\" holds values of codec " & recorded & " version " &
      $recordedVersion & ", not " & codecName & " version " & $codecVersion)

proc shmTypedTable*[K, V](name, codecName: string; codecVersion: uint32;
    encodeKey: proc(k: K): seq[byte];
    encodeValue: proc(v: V): seq[byte];
    decodeValue: proc(b: openArray[byte]): V): ShmTypedTable[K, V] =
  ## Binds the zone `name` with a codec of plain procs.  Raises
  ## `ShmZoneError` when the zone is not declared, or holds another codec
  ## name or version.
  if encodeKey.isNil or encodeValue.isNil or decodeValue.isNil:
    raise newException(ValueError, "shmTypedTable: nil codec proc")
  let t = shmTable(name)
  t.bindCodec(codecName, codecVersion)
  ShmTypedTable[K, V](table: t, encodeKey: encodeKey,
    encodeValue: encodeValue, decodeValue: decodeValue)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toBytes(s: seq[byte]): seq[byte] = s

proc shmTypedTable*[K, V](name: string; Format: typedesc;
                          codecVersion: uint32): ShmTypedTable[K, V] =
  ## Binds the zone `name` with a nim-serialization format (`Json`, ...):
  ## `Format.encode(x)` (a string or bytes) and `Format.decode(bytes, T)`.
  ## The codec's name is the format's type name.
  mixin encode, decode
  shmTypedTable[K, V](name, $Format, codecVersion,
    proc(k: K): seq[byte] = toBytes(Format.encode(k)),
    proc(v: V): seq[byte] = toBytes(Format.encode(v)),
    proc(b: openArray[byte]): V = Format.decode(@b, V))

proc get*[K, V](t: ShmTypedTable[K, V]; key: K): Option[ShmTypedEntry[V]] =
  ## The decoded value and its version, or `none`.  The decoder runs after
  ## the lock is released.
  let k = t.encodeKey(key)
  var bytes: seq[byte]
  let version = t.table.get(k, bytes)
  if version.isNone:
    return none(ShmTypedEntry[V])
  some(ShmTypedEntry[V](value: t.decodeValue(bytes), version: version.get))

proc put*[K, V](t: ShmTypedTable[K, V]; key: K; value: V): ShmPut =
  ## Encodes (before the lock is taken) and stores.
  let k = t.encodeKey(key)
  let v = t.encodeValue(value)
  t.table.put(k, v)

proc putIf*[K, V](t: ShmTypedTable[K, V]; key: K; value: V;
                  expected: uint64): ShmPut =
  let k = t.encodeKey(key)
  let v = t.encodeValue(value)
  t.table.putIf(k, v, expected)

proc delete*[K, V](t: ShmTypedTable[K, V]; key: K;
                   expected = anyVersion): bool =
  t.table.delete(t.encodeKey(key), expected)

proc stats*[K, V](t: ShmTypedTable[K, V]): ShmStats = t.table.stats
