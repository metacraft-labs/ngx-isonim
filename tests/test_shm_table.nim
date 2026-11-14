## test_shm_table.nim
##
## The shared-memory table's operations (src/shm_table.nim) in mock mode:
## the same table code over a process-local arena instead of an nginx zone
## (declareShmZoneForTest).  The arena is a mock of the slab pool, justified
## here: these tests check the table's own rules (bounds, versions,
## compare-and-set, counters, eviction order, the typed layer's codec check,
## lock discipline and that no entry leaks), which do not depend on which
## allocator answers; the arena refuses an allocation over its byte budget
## as the slab allocator does when it has no room.  Sharing between
## processes, the slab pool's mutex, worker death and reloads are covered
## against real nginx by tests/e2e/test_shm_zone.nim.
##
## The arena's lock also asserts that it is never taken twice and never
## released when not held, and every allocation and free asserts that the
## lock is held.
##
## Run: nim c -r -d:isNginxTest tests/test_shm_table.nim

import std/[unittest, strutils]
import ../src/shm_table

proc bytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc text(b: seq[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

type Upper = object
  ## A toy format with nim-serialization's calling convention.

proc encode(F: type Upper; x: string): string = x.toUpperAscii
proc decode(F: type Upper; input: seq[byte]; T: type string): string =
  var t = newString(input.len)
  for i, x in input: t[i] = char(x)
  t.toLowerAscii

var hookCalls: int
  ## How often the store hook ran (a nimcall hook cannot capture).

proc fresh(name: string; size = 64 * 1024; maxValue = 4096): ShmTable =
  declareShmZoneForTest(name, size, maxValue)
  shmTable(name)

proc counterOf(t: ShmTable; key: string): int64 =
  var v: seq[byte]
  doAssert t.get(key, v).isSome
  doAssert v.len == 8
  for j in countdown(7, 0):
    result = (result shl 8) or int64(v[j])

suite "SipHash-2-4":
  test "the reference vectors (Aumasson and Bernstein, appendix A)":
    var k0, k1: uint64
    for i in 0 .. 7:
      k0 = k0 or (uint64(i) shl (8 * i))
      k1 = k1 or (uint64(i + 8) shl (8 * i))
    var msg: seq[byte]
    check sipHash24(k0, k1, msg) == 0x726fdb47dd0e0e31'u64
    for i in 0 ..< 15: msg.add byte(i)
    check sipHash24(k0, k1, msg) == 0xa129ca6149be45e5'u64

suite "binding":
  setup: clearShmZonesForTest()

  test "a zone that is not declared raises ShmZoneError naming it":
    expect ShmZoneError:
      discard shmTable("nowhere")
    try:
      discard shmTable("nowhere")
    except ShmZoneError as e:
      check e.msg.contains("\"nowhere\"")
      check e.msg.contains("isonim_shm_zone")

  test "two binds share one table":
    let a = fresh("shared")
    let b = shmTable("shared")
    check a.put("k", "v").kind == stored
    var v: string
    check b.get("k", v).isSome and v == "v"
    check shmZoneAllocationsForTest("shared") == 3   # header, chains, entry

suite "get, put, putIf, delete":
  setup: clearShmZonesForTest()

  test "versions count up and are never reused, even after a delete":
    let t = fresh("v")
    let p1 = t.put("a", "1")
    let p2 = t.put("a", "2")
    let p3 = t.put("b", "x")
    check p1.kind == stored and p2.kind == stored and p3.kind == stored
    check p1.version < p2.version and p2.version < p3.version
    check t.delete("a")
    let p4 = t.put("a", "3")
    check p4.version > p3.version
    var v: string
    check t.get("a", v) == some(p4.version)
    check v == "3"

  test "putIf stores only at the expected version":
    let t = fresh("cas")
    check t.putIf("k", "first", 0).kind == stored         # 0: only when absent
    let again = t.putIf("k", "second", 0)
    check again.kind == conflict
    var v: seq[byte]
    let current = t.get(bytes("k"), v).get
    check again.currentVersion == current
    let stale = t.putIf("k", "x", current + 1)
    check stale.kind == conflict and stale.currentVersion == current
    let ok = t.putIf("k", "third", current)
    check ok.kind == stored and ok.version > current
    let absent = t.putIf("other", "x", 5)
    check absent.kind == conflict and absent.currentVersion == 0
    check t.get(bytes("k"), v).isSome and v.text == "third"

  test "delete at a version":
    let t = fresh("del")
    let p = t.put("k", "v")
    check not t.delete("k", p.version + 1)
    check t.delete("k", p.version)
    check not t.delete("k")
    var v: string
    check t.get("k", v).isNone

  test "values are copied in and out":
    let t = fresh("copy")
    var input = bytes("original")
    check t.put(bytes("k"), input).kind == stored
    input[0] = byte('X')
    var output: seq[byte]
    discard t.get(bytes("k"), output)
    check output.text == "original"
    output[0] = byte('Y')
    var again: seq[byte]
    discard t.get(bytes("k"), again)
    check again.text == "original"

  test "an absent key leaves the destination as it was":
    let t = fresh("absent")
    var v = bytes("untouched")
    check t.get(bytes("nope"), v).isNone
    check v.text == "untouched"

  test "an empty value is stored and read back empty":
    let t = fresh("empty")
    check t.put("k", "").kind == stored
    var v = bytes("x")
    check t.get(bytes("k"), v).isSome
    check v.len == 0

suite "bounds":
  setup: clearShmZonesForTest()

  test "keys are 1 to 255 bytes":
    let t = fresh("keys")
    expect ValueError:
      discard t.put("", "v")
    expect ValueError:
      var v: string
      discard t.get("", v)
    expect ValueError:
      discard t.incr("", 1, 0, 10)
    expect ValueError:
      discard t.delete("")
    check t.put(repeat('k', 255), "v").kind == stored
    check t.put(repeat('k', 256), "v").kind == tooLarge
    check t.putIf(repeat('k', 256), "v", 0).kind == tooLarge
    check t.incr(repeat('k', 256), 1, 0, 10).kind == tooLarge
    var v: string
    check t.get(repeat('k', 256), v).isNone
    check not t.delete(repeat('k', 256))
    check t.stats.refusedTooLarge == 3

  test "a value over max_value answers tooLarge and changes nothing":
    let t = fresh("values", maxValue = 1000)
    let p = t.put("k", repeat('a', 1000))
    check p.kind == stored
    let before = t.stats
    check t.put("k", repeat('b', 1001)).kind == tooLarge
    check t.putIf("k", repeat('b', 1001), p.version).kind == tooLarge
    var v: string
    check t.get("k", v) == some(p.version)
    check v == repeat('a', 1000)
    let after = t.stats
    check after.stores == before.stores
    check after.refusedTooLarge == before.refusedTooLarge + 2
    check after.entries == before.entries

suite "incr":
  setup: clearShmZonesForTest()

  test "absent counts as 0; the range bounds the result":
    let t = fresh("ctr")
    let a = t.incr("n", 3, 0, 5)
    check a.kind == counted and a.value == 3
    let b = t.incr("n", 3, 0, 5)
    check b.kind == outOfRange and b.current == 3
    check t.incr("n", 2, 0, 5).value == 5
    check t.incr("n", -6, 0, 5).kind == outOfRange
    check t.incr("n", -5, 0, 5).value == 0
    check t.counterOf("n") == 0
    let neg = t.incr("m", -1, 0, 5)
    check neg.kind == outOfRange and neg.current == 0
    var v: string
    check t.get("m", v).isNone          # a refused incr creates nothing

  test "overflow is out of range, never a wrap":
    let t = fresh("ovf")
    check t.incr("n", high(int64), low(int64), high(int64)).value == high(int64)
    let o = t.incr("n", 1, low(int64), high(int64))
    check o.kind == outOfRange and o.current == high(int64)
    check t.incr("m", low(int64), low(int64), high(int64)).value == low(int64)
    check t.incr("m", -1, low(int64), high(int64)).kind == outOfRange

  test "low above high is a programming error":
    let t = fresh("lowhigh")
    expect ValueError:
      discard t.incr("n", 1, 5, 4)

  test "a value put stored is not a counter; put replaces a counter":
    let t = fresh("kinds")
    check t.put("p", "text").kind == stored
    check t.incr("p", 1, 0, 10).kind == notCounter
    check t.incr("c", 7, 0, 10).value == 7
    check t.counterOf("c") == 7
    check t.put("c", "now text").kind == stored
    check t.incr("c", 1, 0, 10).kind == notCounter

  test "every incr draws a new version":
    let t = fresh("ver")
    discard t.incr("c", 1, 0, 10)
    var v: seq[byte]
    let v1 = t.get(bytes("c"), v).get
    discard t.incr("c", 1, 0, 10)
    check t.get(bytes("c"), v).get > v1

suite "eviction":
  setup: clearShmZonesForTest()

  test "a full zone evicts from the least-recently-used end":
    let t = fresh("lru", size = 64 * 1024)
    let value = repeat('v', 1000)
    check t.put("hot", "h").kind == stored
    for i in 0 ..< 400:
      check t.put("k" & $i, value).kind == stored
      var v: string
      check t.get("hot", v).isSome          # read between every store
    let s = t.stats
    check s.evictions > 0
    check s.bytesUsed <= s.size
    var v: string
    check t.get("hot", v).isSome
    check t.get("k0", v).isNone
    check t.get("k399", v).isSome

  test "a counter that is not 0 is never evicted; at 0 it is":
    let t = fresh("ctrs", size = 64 * 1024)
    check t.incr("held", 3, 0, 10).value == 3
    check t.incr("zero", 1, 0, 10).value == 1
    check t.incr("zero", -1, 0, 10).value == 0
    for i in 0 ..< 400:
      check t.put("k" & $i, repeat('v', 1000)).kind == stored
    check t.counterOf("held") == 3
    var v: string
    check t.get("zero", v).isNone

  test "at most 16 evictions per store, then full and the key unchanged":
    let t = fresh("bound", size = 64 * 1024, maxValue = 16 * 1024)
    # Fill the zone with small entries, then ask for one that needs more
    # room than 16 of them free.
    var i = 0
    while true:
      let before = t.stats.evictions
      check t.put("s" & $i, repeat('s', 16)).kind == stored
      if t.stats.evictions > before: break
      inc i
    check t.put("big", "old").kind == stored
    let evictionsBefore = t.stats.evictions
    let entriesBefore = t.stats.entries
    let r = t.put("big", repeat('b', 16 * 1024))
    check r.kind == full
    let s = t.stats
    check s.evictions - evictionsBefore == 16
    check s.entries == entriesBefore - 16
    check s.refusedFull == 1
    var v: string
    check t.get("big", v).isSome and v == "old"

  test "only counters left: full":
    let t = fresh("onlyctr", size = 64 * 1024)
    var i = 0
    while t.incr("c" & $i, 1, 0, 10).kind == counted:
      inc i
    check i > 10
    check t.incr("c" & $i, 1, 0, 10).kind == full
    check t.put("x", "y").kind == full
    check t.stats.evictions == 0

  test "no entry leaks through replacing, evicting and deleting":
    let t = fresh("leaks", size = 64 * 1024)
    for i in 0 ..< 300:
      discard t.put("k" & $(i mod 70), repeat('v', 500 + i mod 300))
      discard t.incr("c" & $(i mod 5), 1, 0, 1000)
    for i in 0 ..< 70:
      discard t.delete("k" & $i)
    for i in 0 ..< 5:
      discard t.delete("c" & $i)
    let s = t.stats
    check s.entries == 0
    check s.entryBytes == 0
    check shmZoneAllocationsForTest("leaks") == 2   # header and chains

suite "lock discipline":
  setup: clearShmZonesForTest()

  test "the store hook runs inside the lock, before the entry is linked":
    let t = fresh("hook")
    hookCalls = 0
    shmStoreHook = proc(zone: string) {.nimcall, gcsafe.} =
      {.cast(gcsafe).}:
        doAssert zone == "hook"
        doAssert shmZoneLockedForTest("hook")
        inc hookCalls
    check t.put("k", "v").kind == stored
    check t.putIf("k", "w", 0).kind == conflict     # no store, no hook
    shmStoreHook = nil
    check hookCalls == 1
    check not shmZoneLockedForTest("hook")

  test "an operation that raises releases the lock":
    let t = fresh("raise")
    shmStoreHook = proc(zone: string) {.nimcall, gcsafe.} =
      raise newException(IOError, "hook failed")
    expect IOError:
      discard t.put("k", "v")
    shmStoreHook = nil
    check not shmZoneLockedForTest("raise")
    check t.put("k", "v").kind == stored

suite "the typed layer":
  setup: clearShmZonesForTest()

  proc encodeStr(s: string): seq[byte] =
    doAssert not shmZoneLockedForTest("typed"), "an encoder ran under the lock"
    bytes(s)
  proc encodeInt(x: int): seq[byte] =
    doAssert not shmZoneLockedForTest("typed"), "an encoder ran under the lock"
    bytes($x)
  proc decodeInt(b: openArray[byte]): int =
    doAssert not shmZoneLockedForTest("typed"), "a decoder ran under the lock"
    parseInt(text(@b))

  test "round trip, with the codec recorded at the first bind":
    declareShmZoneForTest("typed", 64 * 1024)
    let t = shmTypedTable[string, int]("typed", "ints", 1, encodeStr, encodeInt,
                                       decodeInt)
    let p = t.put("a", 42)
    check p.kind == stored
    let e = t.get("a")
    check e.isSome and e.get.value == 42 and e.get.version == p.version
    check t.putIf("a", 43, p.version).kind == stored
    check t.putIf("a", 44, p.version).kind == conflict
    check t.get("a").get.value == 43
    check t.get("b").isNone
    check t.delete("a")
    # The same codec binds again.
    let again = shmTypedTable[string, int]("typed", "ints", 1, encodeStr,
                                           encodeInt, decodeInt)
    check again.put("b", 1).kind == stored

  test "another codec version or name is refused, naming the zone":
    declareShmZoneForTest("typed", 64 * 1024)
    discard shmTypedTable[string, int]("typed", "ints", 1, encodeStr, encodeInt,
                                       decodeInt)
    try:
      discard shmTypedTable[string, int]("typed", "ints", 2, encodeStr,
                                         encodeInt, decodeInt)
      check false
    except ShmZoneError as err:
      check err.msg.contains("\"typed\"")
      check err.msg.contains("ints version 1, not ints version 2")
    expect ShmZoneError:
      discard shmTypedTable[string, int]("typed", "other", 1, encodeStr,
                                         encodeInt, decodeInt)
    # A raw bind does not check codecs.
    check shmTable("typed").isBound

  test "a codec name is 1 to 64 bytes":
    declareShmZoneForTest("typed", 64 * 1024)
    expect ValueError:
      discard shmTypedTable[string, int]("typed", "", 1, encodeStr, encodeInt,
                                         decodeInt)
    expect ValueError:
      discard shmTypedTable[string, int]("typed", repeat('n', 65), 1,
                                         encodeStr, encodeInt, decodeInt)
    discard shmTypedTable[string, int]("typed", repeat('n', 64), 1, encodeStr,
                                       encodeInt, decodeInt)

  test "a nim-serialization style format (Format.encode, Format.decode)":
    declareShmZoneForTest("fmt", 64 * 1024)
    let t = shmTypedTable[string, string]("fmt", Upper, 3)
    check t.put("k", "hello").kind == stored
    var raw: string
    check t.table.get("K", raw).isSome and raw == "HELLO"
    check t.get("k").get.value == "hello"
    expect ShmZoneError:
      discard shmTypedTable[string, string]("fmt", Upper, 4)
