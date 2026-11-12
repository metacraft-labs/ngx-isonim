## boundary.nim
##
## Interior-opened Boundary channels: the frames, the handshakes and the
## calls an application makes over them
## (spec/isonim-nginx.md, "Interior-Opened Boundary Channels").
##
## An Interior peer (IsoNim Forum's write executor) opens every connection
## to the node's Boundary listener and holds one HTTP/2 stream open on it
## (`POST /_boundary/v1/channel`).  The C side (ngx_http_isonim_module.c)
## checks the peer's workload class, answers `200` and keeps both bodies
## open; this module sees the stream as a channel: bytes in, frames out.
## A connection belongs to the worker that accepted it, so the channels a
## worker holds are its own pool, and an application's calls from that
## worker travel on them.
##
## Frames, both ways: a 4-byte big-endian length and that many bytes, at
## most `isonim_boundary_max_frame`.  The first frame each way is a
## handshake (JSON):
##
## * the node's: `{"protocol": 1, "node_id", "worker_slot", "workers",
##   "channels_in_slot", "min_channels", "max_frame"}`, sent as soon as the
##   channel opens.  `channels_in_slot` counts the channels of this worker,
##   this one included, so the peer knows when every slot has
##   `min_channels`;
## * the peer's: `{"peer_id": <string>, "cells": [<string>...]}`.  A channel
##   carries calls only once it has arrived (the channel is then *live*).
##
## Every later frame is a JSON object whose top-level `msg_id` (a string or
## an integer) the application chooses: `boundaryCall` completes with the
## peer's frame carrying the same `msg_id`, whatever order replies arrive
## in.  A peer frame whose `msg_id` matches no call in flight (a reply that
## came after its call timed out) is dropped and logged.
##
## Failures (`BoundaryError.kind`):
##
## * `bcNoChannel`: the worker has no live channel.  The call's future is
##   already failed when `boundaryCall` returns: nothing is queued for a
##   channel that does not exist yet, and nothing is written to disk;
## * `bcLost`: the channel the frame was sent on closed before the reply;
## * `bcTimeout`: the deadline passed first.  A late reply is dropped.
##
## The module never resends: a caller that may resend (with its own
## idempotency key) does so itself.
##
## The pool logic is transport-independent: `openChannel`, `channelData`
## and `channelClosed` take a `Transport` (the C side's stream in nginx, a
## recorder in the mock-mode tests, tests/test_boundary.nim).  The nginx
## glue (`nim_boundary_open`, `nim_boundary_data`, `nim_boundary_closed`)
## is at the end.

{.used.}   # handler.nim imports it for its nim_boundary_* entry points alone

import std/[asyncdispatch, json, monotimes, times, tables, strutils]
import nginx_types

export asyncdispatch

type
  BoundaryErrorKind* = enum
    bcNoChannel   ## the worker has no live channel
    bcLost        ## the channel closed before the reply
    bcTimeout     ## the deadline passed before the reply

  BoundaryError* = object of CatchableError
    ## How a Boundary call or send failed.
    kind*: BoundaryErrorKind

  SendResult* = enum
    srSent        ## handed to the stream (written, or queued behind its
                  ## flow-control window)
    srClosing     ## the channel is closing and takes no more frames
    srFailed      ## the stream failed

  Transport* = object
    ## How a channel's frames reach the wire.
    send*: proc(frame: openArray[byte]): SendResult
      ## One whole frame, its length prefix included.
    close*: proc()
      ## Ends the channel (later; `channelClosed` follows).

  BoundaryChannel* = ref object
    ## One channel of this worker.
    transport: Transport
    nodeId*: string          ## this node, from its own certificate
    peerNode*: string        ## the peer, from its certificate
    peerId*: string          ## from the peer's handshake
    cells*: seq[string]      ## from the peer's handshake
    live*: bool              ## the peer's handshake arrived
    closing: bool            ## its end was asked for (`closeChannel`)
    closed*: bool            ## it is gone (`channelClosed`)
    maxFrame*: int
    inbuf: seq[byte]         ## bytes of an incomplete frame
    inpos: int               ## start of the unparsed bytes in `inbuf`

  PendingCall = ref object
    key: string
    channel: BoundaryChannel
    fut: Future[seq[byte]]

const protocolVersion* = 1

var
  pool: seq[BoundaryChannel]
    ## This worker's open channels (live or awaiting the peer's
    ## handshake), in the order they opened.
  nextPick: int
    ## Round-robin position in `pool`.
  calls: OrderedTable[string, PendingCall]
    ## The calls in flight, by msg_id key (see `frameMsgId`).
  holdHook*: proc(on: bool) {.nimcall, gcsafe.}
    ## Told when calls in flight go from none to some and back (nginx: the
    ## hold that keeps an exiting worker alive until they are answered).
  logHook*: proc(level: NgxUint; msg: string) {.nimcall, gcsafe.}
    ## Where the module's log lines go (nginx: the worker's error log).

proc logLine(level: NgxUint; msg: string) =
  if logHook != nil:
    {.cast(gcsafe).}: logHook(level, msg)

proc boundaryError(kind: BoundaryErrorKind; msg: string): ref BoundaryError =
  result = newException(BoundaryError, msg)
  result.kind = kind

# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

proc encodeFrame*(payload: openArray[byte]): seq[byte] =
  ## The frame on the wire: a 4-byte big-endian length, then the payload.
  let n = payload.len
  result = newSeq[byte](4 + n)
  result[0] = byte((n shr 24) and 0xff)
  result[1] = byte((n shr 16) and 0xff)
  result[2] = byte((n shr 8) and 0xff)
  result[3] = byte(n and 0xff)
  if n > 0:
    copyMem(addr result[4], unsafeAddr payload[0], n)

proc toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toStr*(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)

# A JSON scanner just deep enough to find the top-level "msg_id" of an
# object without parsing the rest (RFC 8259; the frames reach 1 MiB, and
# the key is near the front of the forum's frames).

proc skipWs(f: openArray[byte]; i: var int) =
  while i < f.len and f[i] in {byte(' '), byte('\t'), byte('\n'), byte('\r')}:
    inc i

proc hexVal(c: byte): int =
  case char(c)
  of '0'..'9': int(c) - int('0')
  of 'a'..'f': int(c) - int('a') + 10
  of 'A'..'F': int(c) - int('A') + 10
  else: -1

proc addUtf8(s: var string; cp: int) =
  if cp < 0x80:
    s.add char(cp)
  elif cp < 0x800:
    s.add char(0xC0 or (cp shr 6))
    s.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    s.add char(0xE0 or (cp shr 12))
    s.add char(0x80 or ((cp shr 6) and 0x3F))
    s.add char(0x80 or (cp and 0x3F))
  else:
    s.add char(0xF0 or (cp shr 18))
    s.add char(0x80 or ((cp shr 12) and 0x3F))
    s.add char(0x80 or ((cp shr 6) and 0x3F))
    s.add char(0x80 or (cp and 0x3F))

proc scanString(f: openArray[byte]; i: var int; value: var string): bool =
  ## At a `"`: decodes the string into `value`, leaves `i` after it.
  if i >= f.len or f[i] != byte('"'):
    return false
  inc i
  value.setLen(0)
  while i < f.len:
    let c = f[i]
    if c == byte('"'):
      inc i
      return true
    if c < 0x20:
      return false
    if c != byte('\\'):
      value.add char(c)
      inc i
      continue
    inc i
    if i >= f.len:
      return false
    case char(f[i])
    of '"': value.add '"'
    of '\\': value.add '\\'
    of '/': value.add '/'
    of 'b': value.add '\b'
    of 'f': value.add '\f'
    of 'n': value.add '\n'
    of 'r': value.add '\r'
    of 't': value.add '\t'
    of 'u':
      if i + 4 >= f.len:
        return false
      var cp = 0
      for k in 1 .. 4:
        let h = hexVal(f[i + k])
        if h < 0:
          return false
        cp = cp * 16 + h
      i += 4
      if cp >= 0xD800 and cp <= 0xDBFF and i + 6 < f.len and
          f[i + 1] == byte('\\') and f[i + 2] == byte('u'):
        var lo = 0
        var ok = true
        for k in 3 .. 6:
          let h = hexVal(f[i + k])
          if h < 0:
            ok = false
            break
          lo = lo * 16 + h
        if ok and lo >= 0xDC00 and lo <= 0xDFFF:
          cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
          i += 6
      value.addUtf8(cp)
    else:
      return false
    inc i
  false

proc skipValue(f: openArray[byte]; i: var int): bool =
  ## Skips one JSON value of any kind (nested ones included).
  skipWs(f, i)
  if i >= f.len:
    return false
  var scratch: string
  case char(f[i])
  of '"':
    return scanString(f, i, scratch)
  of '{', '[':
    var depth = 0
    while i < f.len:
      let c = char(f[i])
      case c
      of '"':
        if not scanString(f, i, scratch):
          return false
        continue
      of '{', '[':
        inc depth
      of '}', ']':
        dec depth
        if depth == 0:
          inc i
          return true
      else:
        discard
      inc i
    return false
  else:
    # A number, true, false or null: up to the next delimiter.
    let start = i
    while i < f.len and char(f[i]) notin {',', '}', ']', ' ', '\t', '\n', '\r'}:
      inc i
    return i > start

proc frameMsgId*(f: openArray[byte]): string =
  ## The top-level `msg_id` of a JSON-object frame, as a key: `"s:"` and
  ## the decoded string, or `"n:"` and the integer's digits; `""` when the
  ## frame is not a JSON object or has no string or integer `msg_id`.  The
  ## first `msg_id` counts.
  var i = 0
  skipWs(f, i)
  if i >= f.len or f[i] != byte('{'):
    return ""
  inc i
  var key: string
  while true:
    skipWs(f, i)
    if i >= f.len or f[i] == byte('}'):
      return ""
    if not scanString(f, i, key):
      return ""
    skipWs(f, i)
    if i >= f.len or f[i] != byte(':'):
      return ""
    inc i
    skipWs(f, i)
    if key == "msg_id":
      if i < f.len and f[i] == byte('"'):
        var v: string
        if not scanString(f, i, v):
          return ""
        return "s:" & v
      let start = i
      if i < f.len and f[i] == byte('-'):
        inc i
      let digitsStart = i
      while i < f.len and char(f[i]) in Digits:
        inc i
      if i == digitsStart:
        return ""
      if i < f.len and char(f[i]) notin {',', '}', ' ', '\t', '\n', '\r'}:
        return ""    # a fraction or an exponent: not an integer
      return "n:" & toStr(f.toOpenArray(start, i - 1))
    if not skipValue(f, i):
      return ""
    skipWs(f, i)
    if i < f.len and f[i] == byte(','):
      inc i
    elif i < f.len and f[i] == byte('}'):
      return ""
    else:
      return ""

# ---------------------------------------------------------------------------
# The pool
# ---------------------------------------------------------------------------

proc boundaryChannelCount*(): int =
  ## This worker's open channels (live or awaiting the peer's handshake).
  pool.len

proc boundaryLiveChannelCount*(): int =
  ## This worker's live channels: those that carry calls.
  for ch in pool:
    if ch.live and not ch.closed and not ch.closing:
      inc result

proc boundaryCallsInFlight*(): int =
  calls.len

proc addCall(call: PendingCall) =
  calls[call.key] = call
  if calls.len == 1 and holdHook != nil:
    {.cast(gcsafe).}: holdHook(true)

proc removeCall(key: string) =
  if key in calls:
    calls.del(key)
    if calls.len == 0 and holdHook != nil:
      {.cast(gcsafe).}: holdHook(false)

proc sendFrame(ch: BoundaryChannel; payload: openArray[byte]): SendResult =
  if ch.closed or ch.closing:
    return srClosing
  let wire = encodeFrame(payload)
  {.cast(gcsafe).}:
    ch.transport.send(wire)

proc closeChannel(ch: BoundaryChannel; why: string) =
  ## Asks the transport to end the channel; `channelClosed` follows.
  if not ch.closed and not ch.closing:
    ch.closing = true
    logLine(NGX_LOG_WARN, "isonim boundary: closing the channel of peer " &
      "node \"" & ch.peerNode & "\": " & why)
    {.cast(gcsafe).}:
      ch.transport.close()

proc nextLiveChannel(): BoundaryChannel =
  ## Round robin over the live channels.
  if pool.len == 0:
    return nil
  for k in 0 ..< pool.len:
    let ch = pool[(nextPick + k) mod pool.len]
    if ch.live and not ch.closed and not ch.closing:
      nextPick = (nextPick + k + 1) mod pool.len
      return ch
  nil

proc openChannel*(transport: Transport; nodeId, peerNode: string;
                  workerSlot, workers, channelsInSlot, minChannels,
                  maxFrame: int): BoundaryChannel =
  ## A channel has opened (its `200` is sent): adds it to the pool and
  ## sends the node's handshake.
  result = BoundaryChannel(transport: transport, nodeId: nodeId,
                           peerNode: peerNode, maxFrame: maxFrame)
  pool.add result
  let hs = $(%*{"protocol": protocolVersion, "node_id": nodeId,
                "worker_slot": workerSlot, "workers": workers,
                "channels_in_slot": channelsInSlot,
                "min_channels": minChannels, "max_frame": maxFrame})
  if result.sendFrame(toBytes(hs)) != srSent:
    result.closeChannel("the handshake could not be sent")

proc failCall(call: PendingCall; kind: BoundaryErrorKind; msg: string) =
  removeCall(call.key)
  if not call.fut.finished:
    call.fut.fail(boundaryError(kind, msg))

proc channelClosed*(ch: BoundaryChannel) =
  ## The channel is gone: out of the pool, its calls failed with `bcLost`.
  if ch.closed and ch notin pool:
    return
  ch.closed = true
  let at = pool.find(ch)
  if at >= 0:
    pool.delete(at)
    if nextPick > at:
      dec nextPick
    if pool.len > 0:
      nextPick = nextPick mod pool.len
    else:
      nextPick = 0
  var lost: seq[PendingCall]
  for call in calls.values:
    if call.channel == ch:
      lost.add call
  for call in lost:
    call.failCall(bcLost, "the Boundary channel closed before the reply " &
      "to msg_id " & call.key[2 .. ^1])

proc acceptPeerHandshake(ch: BoundaryChannel; payload: openArray[byte]) =
  var j: JsonNode
  try:
    j = parseJson(toStr(payload))
  except CatchableError:
    ch.closeChannel("the peer's handshake is not JSON")
    return
  if j.kind != JObject or j{"peer_id"}.isNil or j["peer_id"].kind != JString or
      j["peer_id"].getStr.len == 0 or j{"cells"}.isNil or
      j["cells"].kind != JArray:
    ch.closeChannel("the peer's handshake is not {peer_id, cells}")
    return
  var cells: seq[string]
  for c in j["cells"]:
    if c.kind != JString:
      ch.closeChannel("the peer's handshake names a cell that is not a string")
      return
    cells.add c.getStr
  ch.peerId = j["peer_id"].getStr
  ch.cells = cells
  ch.live = true

proc deliverReply(ch: BoundaryChannel; payload: openArray[byte]) =
  let key = frameMsgId(payload)
  let call = calls.getOrDefault(key)
  if call.isNil:
    logLine(NGX_LOG_INFO, "isonim boundary: dropped a frame from peer \"" &
      ch.peerId & "\" whose msg_id matches no call in flight" &
      (if key.len == 0: " (it has none)" else: " (" & key[2 .. ^1] & ")"))
    return
  removeCall(call.key)
  if not call.fut.finished:
    call.fut.complete(@payload)

proc handleFrame(ch: BoundaryChannel; payload: openArray[byte]) =
  if not ch.live:
    ch.acceptPeerHandshake(payload)
  else:
    ch.deliverReply(payload)

proc channelData*(ch: BoundaryChannel; data: openArray[byte]) =
  ## Bytes of the peer's request body: whole frames are handled, a partial
  ## one is kept for the next bytes.  A frame over `maxFrame` closes the
  ## channel (nothing more of it is read).
  if ch.closed or ch.closing or data.len == 0:
    return
  let old = ch.inbuf.len
  ch.inbuf.setLen(old + data.len)
  copyMem(addr ch.inbuf[old], unsafeAddr data[0], data.len)
  while not ch.closed and not ch.closing:
    let avail = ch.inbuf.len - ch.inpos
    if avail < 4:
      break
    let p = ch.inpos
    let n = (int(ch.inbuf[p]) shl 24) or (int(ch.inbuf[p + 1]) shl 16) or
            (int(ch.inbuf[p + 2]) shl 8) or int(ch.inbuf[p + 3])
    if n > ch.maxFrame:
      ch.closeChannel("a frame of " & $n & " bytes exceeds " &
        "isonim_boundary_max_frame (" & $ch.maxFrame & ")")
      ch.inbuf.setLen(0)
      ch.inpos = 0
      return
    if avail < 4 + n:
      break
    ch.inpos = p + 4 + n
    ch.handleFrame(ch.inbuf.toOpenArray(p + 4, p + 3 + n))
  # Keep only the unparsed tail.
  if ch.inpos >= ch.inbuf.len:
    ch.inbuf.setLen(0)
    ch.inpos = 0
  elif ch.inpos > 0 and ch.inpos * 2 >= ch.inbuf.len:
    let rest = ch.inbuf.len - ch.inpos
    moveMem(addr ch.inbuf[0], addr ch.inbuf[ch.inpos], rest)
    ch.inbuf.setLen(rest)
    ch.inpos = 0

# ---------------------------------------------------------------------------
# The application's API
# ---------------------------------------------------------------------------

proc boundaryCall*(frame: openArray[byte]; deadline: MonoTime):
    Future[seq[byte]] =
  ## Sends `frame` (a JSON object with a string or integer top-level
  ## `msg_id`) on one of this worker's live channels and completes with the
  ## peer's reply carrying the same `msg_id`.  Fails with `BoundaryError`:
  ## `bcNoChannel` at once (the returned future is already failed) when the
  ## worker has no live channel, `bcLost` when that channel closes before
  ## the reply, `bcTimeout` at `deadline`.  Raises `ValueError` for a frame
  ## without a `msg_id`, one whose `msg_id` is already in flight in this
  ## worker, or one over the channel's `isonim_boundary_max_frame`.
  let fut = newFuture[seq[byte]]("boundaryCall")
  result = fut
  let key = frameMsgId(frame)
  if key.len == 0:
    raise newException(ValueError, "a Boundary call's frame must be a JSON " &
      "object with a string or integer msg_id")
  if key in calls:
    raise newException(ValueError, "msg_id " & key[2 .. ^1] &
      " is already in flight in this worker")
  let ch = nextLiveChannel()
  if ch.isNil:
    fut.fail(boundaryError(bcNoChannel, "this worker has no live Boundary " &
      "channel"))
    return
  if frame.len > ch.maxFrame:
    raise newException(ValueError, "a Boundary frame of " & $frame.len &
      " bytes exceeds isonim_boundary_max_frame (" & $ch.maxFrame & ")")
  let remaining = deadline - getMonoTime()
  if remaining <= DurationZero:
    fut.fail(boundaryError(bcTimeout, "the deadline has passed"))
    return
  let call = PendingCall(key: key, channel: ch, fut: fut)
  addCall(call)
  case ch.sendFrame(frame)
  of srSent:
    discard
  of srClosing:
    call.failCall(bcLost, "the Boundary channel is closing")
    return
  of srFailed:
    call.failCall(bcLost, "the Boundary channel failed")
    ch.closeChannel("a frame could not be sent")
    return
  let ms = max(1, int((remaining.inMicroseconds + 999) div 1000))
  sleepAsync(ms).addCallback(proc() {.gcsafe.} =
    {.cast(gcsafe).}:
      if calls.getOrDefault(key) == call:
        call.failCall(bcTimeout, "no reply to msg_id " & key[2 .. ^1] &
          " before the deadline"))

proc boundaryCall*(frame: openArray[byte]; timeout: Duration):
    Future[seq[byte]] =
  ## `boundaryCall` with a deadline `timeout` from now.
  boundaryCall(frame, getMonoTime() + timeout)

proc boundarySend*(frame: openArray[byte]) =
  ## Sends a frame that expects no reply on one of this worker's live
  ## channels.  Raises `BoundaryError` with `bcNoChannel` when the worker
  ## has none and `bcLost` when the channel could not take it (nothing is
  ## queued), `ValueError` for a frame over `isonim_boundary_max_frame`.
  let ch = nextLiveChannel()
  if ch.isNil:
    raise boundaryError(bcNoChannel, "this worker has no live Boundary channel")
  if frame.len > ch.maxFrame:
    raise newException(ValueError, "a Boundary frame of " & $frame.len &
      " bytes exceeds isonim_boundary_max_frame (" & $ch.maxFrame & ")")
  case ch.sendFrame(frame)
  of srSent:
    discard
  of srClosing:
    raise boundaryError(bcLost, "the Boundary channel is closing")
  of srFailed:
    ch.closeChannel("a frame could not be sent")
    raise boundaryError(bcLost, "the Boundary channel failed")

when defined(isNginxTest):
  proc resetBoundaryForTest*() =
    ## Forgets every channel and call (between mock-mode tests).
    pool.setLen(0)
    nextPick = 0
    calls.clear()

else:
  # -------------------------------------------------------------------------
  # nginx glue (ngx_http_isonim_module.c)
  # -------------------------------------------------------------------------

  proc ngx_http_isonim_boundary_send(channel: pointer; data: ptr byte;
      len: csize_t): NgxInt {.importc, cdecl.}
  proc ngx_http_isonim_boundary_close(channel: pointer) {.importc, cdecl.}
  proc ngx_http_isonim_boundary_hold(on: NgxInt) {.importc, cdecl.}
  proc ngx_http_isonim_boundary_worker_slot(): NgxUint {.importc, cdecl.}
  proc ngx_http_isonim_boundary_worker_count(): NgxUint {.importc, cdecl.}
  proc ngx_http_isonim_boundary_channel_count(): NgxUint {.importc, cdecl.}
  proc ngx_http_isonim_boundary_slot_count(slot: NgxUint): NgxInt
    {.importc, cdecl.}

  proc boundaryWorkerSlot*(): int =
    ## This worker's slot (nginx's worker number, 0-based).
    int(ngx_http_isonim_boundary_worker_slot())

  proc boundaryWorkers*(): int =
    ## The node's worker count (`worker_processes`).
    int(ngx_http_isonim_boundary_worker_count())

  proc boundaryAttachedChannels*(): int =
    ## The C side's count of this worker's channels (equals
    ## `boundaryChannelCount`).
    int(ngx_http_isonim_boundary_channel_count())

  proc boundaryNodeChannels*(): seq[int] =
    ## The channels of every worker slot of the node, from the node's
    ## shared per-slot counts; empty without an `isonim_boundary` server.
    for slot in 0 ..< boundaryWorkers():
      let n = ngx_http_isonim_boundary_slot_count(NgxUint(slot))
      if n < 0:
        return @[]
      result.add int(n)

  proc logCycle(level: NgxUint; msg: string) {.nimcall, gcsafe.} =
    if msg.len > 0:
      ngx_http_isonim_log_cycle(level, unsafeAddr msg[0], csize_t(msg.len))

  proc holdNginx(on: bool) {.nimcall, gcsafe.} =
    ngx_http_isonim_boundary_hold(NgxInt(ord(on)))

  proc nginxTransport(channel: pointer): Transport =
    Transport(
      send: proc(frame: openArray[byte]): SendResult =
        let rc = ngx_http_isonim_boundary_send(channel,
          unsafeAddr frame[0], csize_t(frame.len))
        if rc == NGX_OK: srSent
        elif rc == NGX_DECLINED: srClosing
        else: srFailed,
      close: proc() =
        ngx_http_isonim_boundary_close(channel))

  proc copyStr(p: ptr char; n: csize_t): string =
    result = newString(int(n))
    if n > 0:
      copyMem(addr result[0], p, int(n))

  proc nimBoundaryOpen*(channel: pointer; nodeId: ptr char; nodeIdLen: csize_t;
                        peerNode: ptr char; peerNodeLen: csize_t;
                        workerSlot, workers, channelsInSlot,
                        minChannels: NgxUint; maxFrame: csize_t): pointer
      {.exportc: "nim_boundary_open", cdecl.} =
    ## The C side opened a channel; returns its state (owned by the C side
    ## until `nim_boundary_closed`), nil when it could not be set up.
    logHook = logCycle
    holdHook = holdNginx
    try:
      let ch = openChannel(nginxTransport(channel), copyStr(nodeId, nodeIdLen),
        copyStr(peerNode, peerNodeLen), int(workerSlot), int(workers),
        int(channelsInSlot), int(minChannels), int(maxFrame))
      GC_ref(ch)
      result = cast[pointer](ch)
    except Exception as e:
      logCycle(NGX_LOG_ERR, "isonim boundary: opening a channel failed: " &
        $e.name & ": " & e.msg)
      result = nil

  proc nimBoundaryData*(state: pointer; data: ptr byte; len: csize_t)
      {.exportc: "nim_boundary_data", cdecl.} =
    let ch = cast[BoundaryChannel](state)
    try:
      channelData(ch, toOpenArray(cast[ptr UncheckedArray[byte]](data), 0,
                                  int(len) - 1))
    except Exception as e:
      logCycle(NGX_LOG_ERR, "isonim boundary: handling a frame raised " &
        $e.name & ": " & e.msg)
      ch.closeChannel("a frame could not be handled")

  proc nimBoundaryClosed*(state: pointer)
      {.exportc: "nim_boundary_closed", cdecl.} =
    let ch = cast[BoundaryChannel](state)
    try:
      channelClosed(ch)
    except Exception as e:
      logCycle(NGX_LOG_ERR, "isonim boundary: closing a channel raised " &
        $e.name & ": " & e.msg)
    GC_unref(ch)
