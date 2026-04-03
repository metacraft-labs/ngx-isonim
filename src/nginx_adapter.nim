## nginx_adapter.nim
##
## faststreams OutputStreamVTable adapter for nginx.
##
## Translates OutputStream writes into ngx_buf_t allocations and
## ngx_http_output_filter calls. This is analogous to chronos_adapters.nim
## which wraps StreamTransport.
##
## When compiled with -d:isNginxTest, provides a mock implementation
## that uses the mock nginx types from nginx_types.nim to exercise the
## same write/flush/close lifecycle with real chain/buf tracking.

import nginx_types

const
  ## Default page size for chunking large writes. Matches nginx's
  ## typical page size and faststreams' default.
  nginxPageSize* = 4096

when not defined(isNginxTest):
  # --------------------------------------------------------------------------
  # Production mode — real faststreams + real nginx C functions.
  #
  # Uses the generic nginx_adapters from faststreams, wiring in real
  # nginx FFI callbacks for buffer allocation and output filtering.
  # --------------------------------------------------------------------------

  import faststreams/[outputs, buffers, nginx_adapters]
  export outputs, nginx_adapters

  type
    ## Holds nginx request context alongside the faststreams adapter.
    NginxRequestContext* = object
      request*: NgxHttpRequest
      pool*: NgxPool
      chainHead*: NgxChain
      chainTail*: NgxChain

  proc appendToChain(ctx: var NginxRequestContext; buf: NgxBuf) =
    ## Allocate an ngx_chain_t link from the pool and append buf to the chain.
    let link = cast[NgxChain](ngx_pcalloc(ctx.pool, csize_t(sizeof(NgxChainObj))))
    if link.isNil:
      raise newException(IOError, "nginx pool allocation failed for chain link")
    link.buf = buf
    link.next = nil
    if ctx.chainTail != nil:
      ctx.chainTail.next = link
    else:
      ctx.chainHead = link
    ctx.chainTail = link

  proc nginxOutput*(req: NgxHttpRequest; pool: NgxPool;
                    pageSize = defaultPageSize): OutputStreamHandle =
    ## Creates an OutputStream backed by nginx buffer chain via the
    ## faststreams nginx adapter. Each flush allocates ngx_buf_t
    ## entries from the request pool and calls ngx_http_output_filter.
    var ctx = NginxRequestContext(
      request: req,
      pool: pool,
      chainHead: nil,
      chainTail: nil,
    )

    proc flushCb(data: openArray[byte]) {.gcsafe, raises: [IOError].} =
      if data.len == 0:
        return
      let buf = ngx_create_temp_buf(ctx.pool, csize_t(data.len))
      if buf.isNil:
        raise newException(IOError, "nginx pool allocation failed for buffer")
      copyMem(buf.pos, unsafeAddr data[0], data.len)
      buf.last = cast[ptr byte](cast[uint](buf.pos) + uint(data.len))
      buf.memory = 1
      ctx.appendToChain(buf)
      let rc = ngx_http_output_filter(ctx.request, ctx.chainHead)
      if rc != NGX_OK:
        raise newException(IOError, "ngx_http_output_filter failed: " & $rc)
      ctx.chainHead = nil
      ctx.chainTail = nil

    proc closeCb() {.gcsafe, raises: [IOError].} =
      # Send a final empty buffer with last_buf set.
      let buf = cast[NgxBuf](ngx_pcalloc(ctx.pool, csize_t(sizeof(NgxBufObj))))
      if buf.isNil:
        raise newException(IOError, "nginx pool allocation failed for last buf")
      buf.last_buf = 1
      ctx.appendToChain(buf)
      let rc = ngx_http_output_filter(ctx.request, ctx.chainHead)
      if rc != NGX_OK:
        raise newException(IOError, "ngx_http_output_filter failed on close: " & $rc)
      ctx.chainHead = nil
      ctx.chainTail = nil

    nginx_adapters.nginxOutput(flushCb, closeCb, pageSize)

else:
  # --------------------------------------------------------------------------
  # Test mode — mock nginx types, no faststreams dependency.
  #
  # Implements the same write/flush/close lifecycle as the production adapter
  # but backed by mock types that track allocations, chain structure, and
  # output filter calls. This allows thorough unit testing of the adapter
  # logic without nginx headers or faststreams on the Nim path.
  # --------------------------------------------------------------------------

  type
    NginxOutputStream* = ref object
      ## Mock nginx output stream that exercises the real adapter lifecycle.
      ## Fields mirror the production NginxOutputStream.
      request*: NgxHttpRequest
      pool*: NgxPool
      chainHead*: NgxChain
      chainTail*: NgxChain

  proc appendToChain*(ns: NginxOutputStream; buf: NgxBuf) =
    ## Append a buffer to the output chain (same as production).
    let link = MockChainLink(buf: buf, next: nil)
    if ns.chainTail != nil:
      ns.chainTail.next = link
    else:
      ns.chainHead = link
    ns.chainTail = link

  proc write*(ns: NginxOutputStream; src: pointer; srcLen: Natural) =
    ## Write raw bytes. Allocates a mock buf from the pool, copies data,
    ## and appends to the chain. Mirrors writeNginxSync.
    if srcLen == 0:
      return
    let buf = ngx_create_temp_buf(ns.pool, csize_t(srcLen))
    if buf.isNil:
      raise newException(IOError, "nginx pool allocation failed for buffer")
    # Copy data into the mock buf's backing storage.
    let srcBytes = cast[ptr UncheckedArray[byte]](src)
    for i in 0 ..< srcLen:
      buf.data[i] = srcBytes[i]
    buf.last = srcLen
    buf.memory = true
    ns.appendToChain(buf)

  proc write*(ns: NginxOutputStream; data: string) =
    ## Convenience: write a string. Delegates to the raw pointer write.
    if data.len == 0:
      return
    ns.write(unsafeAddr data[0], data.len)

  proc writeChunked*(ns: NginxOutputStream; data: string;
      chunkSize: int = nginxPageSize) =
    ## Write data in chunks of at most `chunkSize` bytes. Each chunk gets
    ## its own buf in the chain, simulating how large writes would be
    ## split across multiple ngx_buf_t allocations.
    var offset = 0
    while offset < data.len:
      let remaining = data.len - offset
      let len = min(remaining, chunkSize)
      ns.write(unsafeAddr data[offset], len)
      offset += len

  proc flush*(ns: NginxOutputStream) =
    ## Flush the output chain by calling ngx_http_output_filter.
    ## Mirrors flushNginxSync.
    if ns.chainHead.isNil:
      return
    let rc = ngx_http_output_filter(ns.request, ns.chainHead)
    if rc != NGX_OK:
      raise newException(IOError, "ngx_http_output_filter failed: " & $rc)
    ns.chainHead = nil
    ns.chainTail = nil

  proc close*(ns: NginxOutputStream) =
    ## Close the stream by sending a final buf with lastBuf set.
    ## Mirrors closeNginxSync.
    let buf = MockBuf(
      data: @[],
      pos: 0,
      last: 0,
      lastBuf: true,
      memory: true,
    )
    ns.appendToChain(buf)
    let rc = ngx_http_output_filter(ns.request, ns.chainHead)
    if rc != NGX_OK:
      raise newException(IOError, "ngx_http_output_filter failed on close: " & $rc)
    ns.chainHead = nil
    ns.chainTail = nil

  proc newNginxOutputStream*(req: NgxHttpRequest): NginxOutputStream =
    ## Factory: creates a test-mode NginxOutputStream backed by the
    ## request's mock pool.
    NginxOutputStream(
      request: req,
      pool: req.pool,
      chainHead: nil,
      chainTail: nil,
    )

  proc newNginxOutputStream*(req: NgxHttpRequest;
      pool: NgxPool): NginxOutputStream =
    ## Factory with explicit pool (matches production nginxOutput signature).
    NginxOutputStream(
      request: req,
      pool: pool,
      chainHead: nil,
      chainTail: nil,
    )
