## h2_peer.nim
##
## A minimal HTTP/2 client (RFC 9113) over TLS with a client certificate:
## the test peer that opens Interior-opened Boundary channels to a real
## nginx running the module (tests/integration/t_boundary_channel.nim).
## It stands in for IsoNim Forum's write executor, which does not exist yet
## (INF-M5); see the test's header for why a test peer is the right double.
##
## One connection carries one stream, the channel: `POST
## /_boundary/v1/channel`, its request body (the peer's frames) and its
## response body (the node's frames) both kept open.  What the client
## implements is what that needs and nothing more:
##
## * TLS with ALPN offering `h2` and `http/1.1`.  A server that selects
##   anything but `h2` fails the connection with `PeerError` saying which
##   protocol it chose: the peer never falls back to HTTP/1.1;
## * the connection preface and SETTINGS (push off, a 1 GiB initial
##   window), SETTINGS and PING acknowledgements, WINDOW_UPDATE both ways
##   (the client returns every byte of window it consumes at once, and
##   waits for the server's window before it sends), RST_STREAM and GOAWAY;
## * request headers in HPACK without the dynamic table and without
##   Huffman coding (RFC 7541 §6.1, §6.2.2: indexed and literal-without-
##   indexing fields).  Of the response headers only `:status` is decoded:
##   nginx writes it as the first field of the block, as an indexed field or
##   a literal with the indexed name `:status` and three raw digits
##   (ngx_http_v2_filter_module.c), so no dynamic table or Huffman decoder
##   is needed to read it;
## * the Boundary framing on the stream's bodies: a 4-byte big-endian
##   length and that many bytes (spec/isonim-nginx.md, "Interior-Opened
##   Boundary Channels").

import std/[asyncdispatch, asyncnet, net, openssl, strutils, times, monotimes]

type
  PeerError* = object of CatchableError

  PeerConn* = ref object
    sock: AsyncSocket
    sslCtx: SslContext
    alpn*: string            ## the protocol the server selected
    status*: int             ## the response's :status (0: none yet)
    rstCode*: int            ## the RST_STREAM error code (-1: none)
    goaway*: bool
    ended*: bool             ## the stream or the connection is over
    endReason*: string
    frames*: seq[string]     ## every Boundary frame received, in order
    readIdx*: int            ## frames consumed by `nextFrame`
    rx: string               ## response body bytes not yet framed
    dataBytes*: int          ## response body bytes received in total
    connSendWindow: int
    streamSendWindow: int
    peerMaxFrame: int
    event: Future[void]      ## completed (and replaced) on every change
    writing: Future[void]    ## the last write, so writes never interleave
    reader: Future[void]

const
  streamId = 1'u32
  ourWindow = 1 shl 30
  frameData = 0'u8
  frameHeaders = 1'u8
  frameRst = 3'u8
  frameSettings = 4'u8
  framePing = 6'u8
  frameGoaway = 7'u8
  frameWindowUpdate = 8'u8
  flagEndStream = 0x1'u8
  flagAck = 0x1'u8
  flagEndHeaders = 0x4'u8
  flagPadded = 0x8'u8
  flagPriority = 0x20'u8

proc newEvent(): Future[void] = newFuture[void]("h2 peer event")

proc wake(p: PeerConn) =
  let ev = p.event
  p.event = newEvent()
  if not ev.finished:
    ev.complete()

proc finish(p: PeerConn; why: string) =
  if not p.ended:
    p.ended = true
    p.endReason = why
  p.wake()

proc be32(n: int): string =
  result = newString(4)
  result[0] = char((n shr 24) and 0xff)
  result[1] = char((n shr 16) and 0xff)
  result[2] = char((n shr 8) and 0xff)
  result[3] = char(n and 0xff)

proc frameHeader(length: int; kind, flags: uint8; stream: uint32): string =
  result = newString(9)
  result[0] = char((length shr 16) and 0xff)
  result[1] = char((length shr 8) and 0xff)
  result[2] = char(length and 0xff)
  result[3] = char(kind)
  result[4] = char(flags)
  result[5] = char((stream shr 24) and 0x7f)
  result[6] = char((stream shr 16) and 0xff)
  result[7] = char((stream shr 8) and 0xff)
  result[8] = char(stream and 0xff)

proc write(p: PeerConn; data: string): Future[void] {.async.} =
  ## Writes in order: each write waits for the one before it.
  let before = p.writing
  let mine = newFuture[void]("h2 peer write")
  p.writing = mine
  if before != nil and not before.finished:
    yield before
  try:
    if not p.sock.isClosed:
      await p.sock.send(data)
  finally:
    mine.complete()

proc sendFrame(p: PeerConn; kind, flags: uint8; stream: uint32;
               payload: string): Future[void] =
  p.write(frameHeader(payload.len, kind, flags, stream) & payload)

proc hpackLiteral(nameIndex: int; value: string): string =
  ## A literal field without indexing, indexed name, raw value
  ## (RFC 7541 §6.2.2); `nameIndex` < 15 + 128, `value` < 127 bytes.
  if nameIndex < 15:
    result.add char(nameIndex)
  else:
    result.add char(0x0f)
    result.add char(nameIndex - 15)
  result.add char(value.len)
  result.add value

proc parseStatus(hb: string): int =
  ## The :status of a response header block (see the module's header).
  var i = 0
  while i < hb.len and (uint8(hb[i]) and 0xe0) == 0x20:
    inc i                       # dynamic table size updates
  if i >= hb.len:
    return -1
  let b = uint8(hb[i])
  if (b and 0x80) != 0:
    case int(b and 0x7f)
    of 8: return 200
    of 9: return 204
    of 10: return 206
    of 11: return 304
    of 12: return 400
    of 13: return 404
    of 14: return 500
    else: return -1
  let idx =
    if (b and 0xc0) == 0x40: int(b and 0x3f)
    elif (b and 0xf0) == 0x00 or (b and 0xf0) == 0x10: int(b and 0x0f)
    else: -1
  if idx != 8 or i + 4 >= hb.len:
    return -1
  let lenByte = uint8(hb[i + 1])
  if (lenByte and 0x80) != 0 or int(lenByte) != 3:
    return -1
  try:
    parseInt(hb[i + 2 .. i + 4])
  except ValueError:
    -1

proc takeFrames(p: PeerConn) =
  while p.rx.len >= 4:
    let n = (int(uint8(p.rx[0])) shl 24) or (int(uint8(p.rx[1])) shl 16) or
            (int(uint8(p.rx[2])) shl 8) or int(uint8(p.rx[3]))
    if p.rx.len < 4 + n:
      break
    p.frames.add p.rx[4 ..< 4 + n]
    p.rx = p.rx[4 + n .. ^1]

proc readLoop(p: PeerConn) {.async.} =
  try:
    while true:
      let head = await p.sock.recv(9)
      if head.len < 9:
        p.finish("the connection closed")
        return
      let length = (int(uint8(head[0])) shl 16) or (int(uint8(head[1])) shl 8) or
                   int(uint8(head[2]))
      let kind = uint8(head[3])
      let flags = uint8(head[4])
      let stream = (uint32(uint8(head[5]) and 0x7f) shl 24) or
                   (uint32(uint8(head[6])) shl 16) or
                   (uint32(uint8(head[7])) shl 8) or uint32(uint8(head[8]))
      var payload = ""
      if length > 0:
        payload = await p.sock.recv(length)
        if payload.len < length:
          p.finish("the connection closed inside a frame")
          return
      case kind
      of frameData:
        var data = payload
        if (flags and flagPadded) != 0 and data.len > 0:
          let pad = int(uint8(data[0]))
          data = data[1 ..< data.len - pad]
        if stream == streamId:
          p.rx.add data
          p.dataBytes += data.len
          p.takeFrames()
        if length > 0:
          # Give back the window at once, for the connection and the stream.
          await p.sendFrame(frameWindowUpdate, 0, 0, be32(length))
          if stream == streamId and (flags and flagEndStream) == 0:
            await p.sendFrame(frameWindowUpdate, 0, streamId, be32(length))
        if stream == streamId and (flags and flagEndStream) != 0:
          p.finish("the node ended the stream")
        p.wake()
      of frameHeaders:
        if stream == streamId:
          var hb = payload
          if (flags and flagPadded) != 0 and hb.len > 0:
            let pad = int(uint8(hb[0]))
            hb = hb[1 ..< hb.len - pad]
          if (flags and flagPriority) != 0:
            hb = hb[5 .. ^1]
          if p.status == 0:
            p.status = parseStatus(hb)
          if (flags and flagEndStream) != 0:
            p.finish("the node ended the stream with its headers")
          p.wake()
      of frameRst:
        if stream == streamId:
          p.rstCode = (int(uint8(payload[0])) shl 24) or
            (int(uint8(payload[1])) shl 16) or (int(uint8(payload[2])) shl 8) or
            int(uint8(payload[3]))
          p.finish("RST_STREAM " & $p.rstCode)
      of frameSettings:
        if (flags and flagAck) == 0:
          var i = 0
          while i + 6 <= payload.len:
            let id = (int(uint8(payload[i])) shl 8) or int(uint8(payload[i + 1]))
            let v = (int(uint8(payload[i + 2])) shl 24) or
              (int(uint8(payload[i + 3])) shl 16) or
              (int(uint8(payload[i + 4])) shl 8) or int(uint8(payload[i + 5]))
            if id == 4:                  # SETTINGS_INITIAL_WINDOW_SIZE
              p.streamSendWindow += v - 65535
            elif id == 5:                # SETTINGS_MAX_FRAME_SIZE
              p.peerMaxFrame = v
            i += 6
          await p.sendFrame(frameSettings, flagAck, 0, "")
          p.wake()
      of framePing:
        if (flags and flagAck) == 0:
          await p.sendFrame(framePing, flagAck, 0, payload)
      of frameGoaway:
        p.goaway = true
        p.wake()
      of frameWindowUpdate:
        let inc = ((int(uint8(payload[0])) and 0x7f) shl 24) or
          (int(uint8(payload[1])) shl 16) or (int(uint8(payload[2])) shl 8) or
          int(uint8(payload[3]))
        if stream == 0:
          p.connSendWindow += inc
        elif stream == streamId:
          p.streamSendWindow += inc
        p.wake()
      else:
        discard
  except CatchableError as e:
    p.finish("reading failed: " & e.msg)

proc waitChange(p: PeerConn; deadline: MonoTime): Future[bool] =
  ## Completes with true at the next change, false at the deadline.  (Not
  ## asyncdispatch's `withTimeout`: it replaces the callbacks of the future
  ## it watches, so two waiters on one event would starve each other.)
  let res = newFuture[bool]("h2 peer wait")
  result = res
  let left = (deadline - getMonoTime()).inMilliseconds
  if left <= 0:
    res.complete(false)
    return
  p.event.addCallback(proc() =
    if not res.finished: res.complete(true))
  sleepAsync(int(left)).addCallback(proc() =
    if not res.finished: res.complete(false))

proc newPeerContext*(certFile, keyFile, caFile: string): SslContext =
  ## A TLS client context: the server is verified against `caFile`; the
  ## client presents `certFile` / `keyFile` (none when empty).  ALPN offers
  ## h2, then http/1.1, so that a server without HTTP/2 says so.
  result = newContext(verifyMode = CVerifyPeer, certFile = certFile,
                      keyFile = keyFile, caFile = caFile)
  const protos = "\x02h2\x08http/1.1"
  if SSL_CTX_set_alpn_protos(result.context, protos, cuint(protos.len)) != 0:
    raise newException(PeerError, "cannot set ALPN")

proc connectPeer*(ctx: SslContext; host: string; port: int;
                  timeoutMs = 10_000): Future[PeerConn] {.async.} =
  ## Connects and completes the TLS handshake and the HTTP/2 preface.
  ## Raises `PeerError` when the server did not select h2.
  let p = PeerConn(sslCtx: ctx, rstCode: -1, connSendWindow: 65535,
                   streamSendWindow: 65535, peerMaxFrame: 16384,
                   event: newEvent())
  p.sock = newAsyncSocket()
  let connected = p.sock.connect(host, Port(port))
  if not await withTimeout(connected, timeoutMs):
    p.sock.close()
    raise newException(PeerError, "connecting timed out")
  await connected
  wrapConnectedSocket(ctx, p.sock, handshakeAsClient, "")
  # The preface and our SETTINGS go first; the TLS handshake completes on
  # the way, so ALPN's outcome is known after this write.
  var settings = ""
  settings.add "\x00\x02" & be32(0)            # SETTINGS_ENABLE_PUSH 0
  settings.add "\x00\x04" & be32(ourWindow)    # SETTINGS_INITIAL_WINDOW_SIZE
  let w = p.write("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" &
    frameHeader(settings.len, frameSettings, 0, 0) & settings &
    frameHeader(4, frameWindowUpdate, 0, 0) & be32(ourWindow - 65535))
  if not await withTimeout(w, timeoutMs):
    p.sock.close()
    raise newException(PeerError, "the TLS handshake timed out")
  await w
  var proto: cstring
  var plen: cuint
  SSL_get0_alpn_selected(p.sock.sslHandle, addr proto, addr plen)
  p.alpn = if plen > 0: ($proto)[0 ..< int(plen)] else: ""
  if p.alpn != "h2":
    p.sock.close()
    raise newException(PeerError, "HTTP/2 was not negotiated: the server " &
      "selected " & (if p.alpn.len > 0: "\"" & p.alpn & "\"" else: "no protocol") &
      " by ALPN; the peer does not fall back to HTTP/1.1")
  p.reader = p.readLoop()
  result = p

proc openStream*(p: PeerConn; authority: string;
                 path = "/_boundary/v1/channel";
                 timeoutMs = 10_000): Future[int] {.async.} =
  ## Sends the channel request (headers only, the body stays open) and
  ## waits for the response's status (or the stream's end): returns the
  ## status, 0 when none came.
  var hb = ""
  hb.add char(0x83)                    # :method POST
  hb.add char(0x87)                    # :scheme https
  hb.add hpackLiteral(4, path)         # :path
  hb.add hpackLiteral(1, authority)    # :authority
  hb.add hpackLiteral(31, "application/octet-stream")   # content-type
  await p.sendFrame(frameHeaders, flagEndHeaders, streamId, hb)
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while p.status == 0 and not p.ended:
    if not await p.waitChange(deadline):
      break
  result = p.status

proc sendRaw*(p: PeerConn; bytes: string;
              timeoutMs = 10_000): Future[void] {.async.} =
  ## Sends request-body bytes as DATA frames, within the server's windows.
  var off = 0
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while off < bytes.len:
    if p.ended:
      raise newException(PeerError, "the channel is over: " & p.endReason)
    let room = min(min(p.connSendWindow, p.streamSendWindow), p.peerMaxFrame)
    if room <= 0:
      if not await p.waitChange(deadline):
        raise newException(PeerError, "no send window from the node")
      continue
    let n = min(room, bytes.len - off)
    p.connSendWindow -= n
    p.streamSendWindow -= n
    await p.sendFrame(frameData, 0, streamId, bytes[off ..< off + n])
    off += n

proc sendBoundaryFrame*(p: PeerConn; payload: string): Future[void] =
  ## One Boundary frame (length prefix and payload) on the request body.
  p.sendRaw(be32(payload.len) & payload)

proc nextFrame*(p: PeerConn; timeoutMs = 10_000): Future[string] {.async.} =
  ## The next Boundary frame from the node not yet consumed.  Raises
  ## `PeerError` when the channel ends or the time runs out first.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while p.readIdx >= p.frames.len:
    if p.ended:
      raise newException(PeerError, "the channel is over: " & p.endReason)
    if not await p.waitChange(deadline):
      raise newException(PeerError, "no frame from the node within " &
        $timeoutMs & " ms")
  result = p.frames[p.readIdx]
  inc p.readIdx

proc waitEnded*(p: PeerConn; timeoutMs = 10_000): Future[bool] {.async.} =
  ## Waits until the channel is over; false at the deadline.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while not p.ended:
    if not await p.waitChange(deadline):
      return false
  true

proc waitChangeFor*(p: PeerConn; timeoutMs: int): Future[bool] =
  ## Waits for the next change on the connection (a frame, its end, ...).
  p.waitChange(getMonoTime() + initDuration(milliseconds = timeoutMs))

proc close*(p: PeerConn) =
  if not p.sock.isClosed:
    p.sock.close()
  p.finish("closed by the peer")
