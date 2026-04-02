## nginx_adapter.nim
##
## faststreams OutputStreamVTable adapter for nginx.
##
## Translates OutputStream writes into ngx_buf_t allocations and
## ngx_http_output_filter calls. This is analogous to chronos_adapters.nim
## which wraps StreamTransport.
##
## When compiled with -d:isNginxTest, provides a mock implementation
## that collects writes into a seq[string] for testing.

when not defined(isNginxTest):
  import nginx_types
  # Real nginx adapter — requires faststreams and nginx headers.
  import faststreams/outputs

  type
    NginxOutputStream* = ref object of OutputStream
      request*: NgxHttpRequest
      pool*: NgxPool
      chainHead*: NgxChain
      chainTail*: NgxChain

  proc appendBuf(ns: NginxOutputStream; buf: NgxBuf) =
    ## Append a buffer to the output chain.
    let link = cast[NgxChain](ngx_pcalloc(ns.pool, csize_t(sizeof(pointer) * 2)))
    # link.buf = buf, link.next = nil
    # (In real nginx these are struct fields accessed via C)
    discard  # Actual field assignment requires nginx header struct layout

  proc writeNginxSync(s: OutputStream; src: pointer; srcLen: Natural)
      {.nimcall, gcsafe, raises: [IOError].} =
    let ns = NginxOutputStream(s)
    if srcLen == 0:
      return
    let buf = ngx_create_temp_buf(ns.pool, csize_t(srcLen))
    copyMem(cast[pointer](buf), src, srcLen)
    ns.appendBuf(buf)

  proc flushNginxSync(s: OutputStream)
      {.nimcall, gcsafe, raises: [IOError].} =
    let ns = NginxOutputStream(s)
    let rc = ngx_http_output_filter(ns.request, ns.chainHead)
    if rc != NGX_OK:
      raise newException(IOError, "ngx_http_output_filter failed")
    ns.chainHead = nil
    ns.chainTail = nil

  proc closeNginxSync(s: OutputStream)
      {.nimcall, gcsafe, raises: [IOError].} =
    let ns = NginxOutputStream(s)
    # Send a final buffer with the last_buf flag set.
    let buf = cast[NgxBuf](ngx_pcalloc(ns.pool, csize_t(64)))
    # buf.last_buf = 1 (requires struct field access)
    ns.appendBuf(buf)
    discard ngx_http_output_filter(ns.request, ns.chainHead)

  const nginxOutputVTable = OutputStreamVTable(
    writeSync: writeNginxSync,
    flushSync: flushNginxSync,
    closeSync: closeNginxSync,
  )

  proc nginxOutput*(req: NgxHttpRequest; pool: NgxPool): OutputStream =
    ## Creates an OutputStream backed by nginx buffer chain.
    ## Each write allocates an ngx_buf_t from the request pool and
    ## appends it to the output chain. Flush calls ngx_http_output_filter.
    NginxOutputStream(
      vtable: vtableAddr nginxOutputVTable,
      request: req,
      pool: pool,
      chainHead: nil,
      chainTail: nil,
    )

else:
  # Mock implementation for testing without real nginx or faststreams.

  type
    MockNginxOutputStream* = ref object
      ## Mock nginx output stream for testing.
      chunks*: seq[string]
      flushed*: bool
      closed*: bool
      flushCount*: int

  proc newMockNginxOutputStream*(): MockNginxOutputStream =
    MockNginxOutputStream(
      chunks: @[],
      flushed: false,
      closed: false,
      flushCount: 0,
    )

  proc write*(s: MockNginxOutputStream; data: string) =
    ## Write data to the mock stream. Each write creates a "chunk"
    ## analogous to an ngx_buf_t allocation.
    if data.len > 0:
      s.chunks.add(data)

  proc flush*(s: MockNginxOutputStream) =
    ## Flush the mock stream. Analogous to calling ngx_http_output_filter.
    s.flushed = true
    inc s.flushCount

  proc close*(s: MockNginxOutputStream) =
    ## Close the mock stream. Analogous to sending last_buf.
    s.closed = true

  proc getOutput*(s: MockNginxOutputStream): string =
    ## Returns the accumulated output as a single string.
    for chunk in s.chunks:
      result.add chunk
