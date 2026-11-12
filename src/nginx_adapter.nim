## nginx_adapter.nim
##
## A model of the nginx output chain for unit tests (mock mode only).
##
## The production module does not use it: the response pipeline
## (serve.nim) sends status and headers through
## `ngx_http_isonim_send_header` and body bytes through
## `ngx_http_isonim_send_body` (ngx_http_isonim_module.c), and streaming
## renderers that want a faststreams `OutputStream` get one from
## `ResponseBody.outputStream` (response_body.nim), built on
## nim-faststreams' `nginx_adapters`.
##
## This module keeps the write / flush / close lifecycle over the mock
## nginx types (buffer allocation from the pool, chain building, output
## filter calls, last_buf on close) that tests/test_adapter.nim exercises.

import nginx_types

const
  ## Default page size for chunking large writes. Matches nginx's
  ## typical page size and faststreams' default.
  nginxPageSize* = 4096

when not defined(isNginxTest):
  {.error: "nginx_adapter.nim is the mock-mode output chain; compile with -d:isNginxTest".}

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
