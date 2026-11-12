## test_boundary.nim
##
## The channel pool of src/boundary.nim in mock mode (`-d:isNginxTest`):
## framing, the handshakes, msg_id matching, round robin over live
## channels, and the three failures, over a recording `Transport` in place
## of the C side's HTTP/2 stream.  The stream itself (nginx, TLS, HTTP/2,
## the workers) is tested end to end by
## tests/integration/t_boundary_channel.nim.
##
## MOCKING POLICY: the recording transport replaces nginx's output chain
## only; every rule of the pool runs as it does in the module, and the
## asyncdispatch event loop is the real one.

import std/[unittest, json, monotimes, times, asyncdispatch, strutils]
import ../src/boundary

type Recorder = ref object
  sent: seq[seq[byte]]       ## whole frames, length prefix included
  closes: int
  refuse: SendResult         ## what send answers (srSent by default)

proc transport(r: Recorder): Transport =
  Transport(
    send: proc(frame: openArray[byte]): SendResult =
      if r.refuse != srSent:
        return r.refuse
      r.sent.add @frame
      srSent,
    close: proc() = inc r.closes)

proc payload(frame: seq[byte]): string =
  ## A recorded frame's payload, its length prefix checked.
  let n = (int(frame[0]) shl 24) or (int(frame[1]) shl 16) or
          (int(frame[2]) shl 8) or int(frame[3])
  doAssert n == frame.len - 4
  toStr(frame.toOpenArray(4, frame.high))

proc open(r: Recorder; slot = 0; inSlot = 1; maxFrame = 1024 * 1024):
    BoundaryChannel =
  openChannel(r.transport, "edge-1", "writer-1", slot, 8, inSlot, 2, maxFrame)

proc handshake(ch: BoundaryChannel; peer = "writer-1") =
  ch.channelData(encodeFrame(toBytes($(%*{"peer_id": peer,
                                          "cells": ["cell-1"]}))))

proc reply(ch: BoundaryChannel; msgId: JsonNode; extra = "") =
  ch.channelData(encodeFrame(toBytes($(%*{"msg_id": msgId, "x": extra}))))

proc call(id: string; ms = 1000): Future[seq[byte]] =
  boundaryCall(toBytes($(%*{"v": 1, "msg_id": id})),
               initDuration(milliseconds = ms))

proc drain() =
  ## Runs the callbacks that are due (completions), not the timers.
  for _ in 0 ..< 8:
    try:
      poll(0)
    except ValueError:      # nothing registered at all
      break

proc drainAll() =
  ## Runs everything, the call deadlines included.
  while hasPendingOperations():
    poll(5)

suite "boundary frames":
  test "encodeFrame prefixes a big-endian length":
    check encodeFrame(toBytes("abc")) == @[0'u8, 0, 0, 3, 97, 98, 99]
    check encodeFrame(newSeq[byte](300))[0 .. 3] == @[0'u8, 0, 1, 44]

  test "frameMsgId finds the top-level msg_id only":
    check frameMsgId(toBytes("""{"v":1,"msg_id":"a-1","x":2}""")) == "s:a-1"
    check frameMsgId(toBytes("""{"msg_id": 42}""")) == "n:42"
    check frameMsgId(toBytes("""{"msg_id":-7,"b":1}""")) == "n:-7"
    check frameMsgId(toBytes("""{"a":{"msg_id":"inner"},"msg_id":"outer"}""")) ==
      "s:outer"
    check frameMsgId(toBytes("""{"a":["}", "\"msg_id\""],"msg_id":"x"}""")) == "s:x"
    check frameMsgId(toBytes("""{"msg\u005fid":"esc\n"}""")) == "s:esc\n"
    check frameMsgId(toBytes("""{"msg_id":"\ud83d\ude00"}""")) == "s:\u{1F600}"
    # Not a key: a float, a boolean, missing, not an object, malformed.
    check frameMsgId(toBytes("""{"msg_id":1.5}""")) == ""
    check frameMsgId(toBytes("""{"msg_id":true}""")) == ""
    check frameMsgId(toBytes("""{"id":"x"}""")) == ""
    check frameMsgId(toBytes("""["msg_id","x"]""")) == ""
    check frameMsgId(toBytes("""{"msg_id":"unterminated""")) == ""
    check frameMsgId(toBytes("")) == ""

suite "boundary channel pool":
  setup:
    resetBoundaryForTest()

  test "a channel sends the node's handshake and is live after the peer's":
    let r = Recorder()
    let ch = r.open(slot = 3, inSlot = 2)
    check r.sent.len == 1
    let hs = parseJson(payload(r.sent[0]))
    check hs["protocol"].getInt == 1
    check hs["node_id"].getStr == "edge-1"
    check hs["worker_slot"].getInt == 3
    check hs["workers"].getInt == 8
    check hs["channels_in_slot"].getInt == 2
    check hs["min_channels"].getInt == 2
    check hs["max_frame"].getInt == 1024 * 1024
    check boundaryChannelCount() == 1
    check boundaryLiveChannelCount() == 0
    ch.handshake()
    check ch.live and ch.peerId == "writer-1" and ch.cells == @["cell-1"]
    check boundaryLiveChannelCount() == 1

  test "a bad peer handshake closes the channel":
    let r = Recorder()
    let ch = r.open()
    ch.channelData(encodeFrame(toBytes("""{"peer":"x"}""")))
    check r.closes == 1 and not ch.live

  test "no live channel: bcNoChannel before boundaryCall returns":
    let r = Recorder()
    discard r.open()                       # open, but no peer handshake yet
    let f = call("a")
    check f.finished and f.failed
    check (ref BoundaryError)(f.readError).kind == bcNoChannel
    check r.sent.len == 1                  # the handshake only
    expect BoundaryError:
      boundarySend(toBytes("{}"))

  test "replies complete their calls by msg_id, in any order":
    let r = Recorder()
    let a = r.open()
    let b = r.open()
    a.handshake()
    b.handshake()
    var futs: seq[Future[seq[byte]]]
    for i in 0 ..< 4:
      futs.add call("m-" & $i)
    # Round robin: a, b, a, b (after the two handshakes).
    check r.sent.len == 6
    for i in 0 ..< 4:
      check frameMsgId(r.sent[2 + i].toOpenArray(4, r.sent[2 + i].high)) ==
        "s:m-" & $i
    check boundaryCallsInFlight() == 4
    for i in countdown(3, 0):
      (if i mod 2 == 0: a else: b).reply(%("m-" & $i), "r" & $i)
    drain()
    for i in 0 ..< 4:
      check futs[i].finished and not futs[i].failed
      check parseJson(toStr(futs[i].read))["x"].getStr == "r" & $i
    check boundaryCallsInFlight() == 0

  test "integer msg_ids, split frames and unknown replies":
    let r = Recorder()
    let ch = r.open()
    ch.handshake()
    let f = boundaryCall(toBytes("""{"msg_id": 7}"""),
                         initDuration(milliseconds = 1000))
    let wire = encodeFrame(toBytes("""{"msg_id":7,"ok":true}"""))
    let unknown = encodeFrame(toBytes("""{"msg_id":"nobody"}"""))
    # The unknown reply, then the real one byte by byte.
    ch.channelData(unknown)
    for b in wire:
      ch.channelData([b])
    drain()
    check f.finished and not f.failed
    check parseJson(toStr(f.read))["ok"].getBool

  test "a duplicate or missing msg_id is refused":
    let r = Recorder()
    let ch = r.open()
    ch.handshake()
    discard call("dup")
    expect ValueError:
      discard call("dup")
    expect ValueError:
      discard boundaryCall(toBytes("""{"v":1}"""), initDuration(seconds = 1))

  test "a channel that closes fails its calls with bcLost":
    let r = Recorder()
    let a = r.open()
    let b = r.open()
    a.handshake()
    b.handshake()
    let fa = call("on-a")
    let fb = call("on-b")
    channelClosed(a)
    drain()
    check fa.failed and (ref BoundaryError)(fa.readError).kind == bcLost
    check not fb.finished
    check boundaryChannelCount() == 1
    # Calls go to the remaining channel.
    let fc = call("on-b-2")
    check frameMsgId(r.sent[^1].toOpenArray(4, r.sent[^1].high)) == "s:on-b-2"
    b.reply(%"on-b")
    b.reply(%"on-b-2")
    drain()
    check fb.finished and not fb.failed and fc.finished and not fc.failed

  test "the deadline fails a call with bcTimeout, and a late reply is dropped":
    let r = Recorder()
    let ch = r.open()
    ch.handshake()
    let start = getMonoTime()
    let f = call("slow", 50)
    drainAll()
    check f.failed and (ref BoundaryError)(f.readError).kind == bcTimeout
    check getMonoTime() - start >= initDuration(milliseconds = 50)
    ch.reply(%"slow")
    drain()
    check boundaryCallsInFlight() == 0

  test "a channel that refuses the frame fails the call with bcLost":
    let r = Recorder()
    let ch = r.open()
    ch.handshake()
    r.refuse = srClosing
    let f = call("x")
    check f.failed and (ref BoundaryError)(f.readError).kind == bcLost
    check boundaryCallsInFlight() == 0
    r.refuse = srFailed
    let g = call("y")
    check g.failed and (ref BoundaryError)(g.readError).kind == bcLost
    check r.closes == 1                    # a failed stream is closed

  test "a frame over max_frame closes the channel":
    let r = Recorder()
    let ch = r.open(maxFrame = 1024)
    ch.handshake()
    ch.channelData([0'u8, 0, 4, 1])        # 1025 bytes announced
    check r.closes == 1
    check boundaryLiveChannelCount() == 0  # a closing channel takes no call
    let other = r.open(maxFrame = 1024)
    other.handshake()
    expect ValueError:
      discard boundaryCall(toBytes("""{"msg_id":"big","p":"""" &
        repeat('x', 2000) & "\"}"), initDuration(seconds = 1))

  test "the hold is on exactly while calls are in flight":
    var holds: seq[bool]
    holdHook = proc(on: bool) {.nimcall, gcsafe.} =
      {.cast(gcsafe).}: holds.add on
    defer: holdHook = nil
    let r = Recorder()
    let ch = r.open()
    ch.handshake()
    let f1 = call("h1")
    let f2 = call("h2")
    ch.reply(%"h1")
    ch.reply(%"h2")
    drain()
    check f1.finished and f2.finished
    check holds == @[true, false]
