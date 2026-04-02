## nginx_types.nim
##
## nginx C API type bindings for the IsoNim nginx module.
##
## When compiled with -d:isNginxTest, provides mock implementations
## for unit testing without real nginx headers.

when not defined(isNginxTest):
  # Real nginx bindings — requires nginx dev headers at compile time.

  type
    NgxInt* = cint
    NgxUint* = cuint

    NgxPoolObj {.importc: "ngx_pool_t", header: "<ngx_core.h>", incompleteStruct.} = object
    NgxPool* = ptr NgxPoolObj
      ## nginx memory pool (ngx_pool_t).

    NgxBufObj* {.importc: "ngx_buf_t", header: "<ngx_core.h>".} = object
      ## nginx buffer (ngx_buf_t).
      pos* {.importc: "pos".}: ptr byte
        ## Start of data to send.
      last* {.importc: "last".}: ptr byte
        ## End of data to send.
      last_buf* {.importc: "last_buf".}: cuint
        ## 1 if this is the last buffer in the response.
      memory* {.importc: "memory".}: cuint
        ## 1 if the buffer is in memory (not file).
    NgxBuf* = ptr NgxBufObj

    NgxChainObj* {.importc: "ngx_chain_t", header: "<ngx_core.h>".} = object
      ## nginx buffer chain (ngx_chain_t). Linked list of buffers.
      buf* {.importc: "buf".}: NgxBuf
      next* {.importc: "next".}: NgxChain
    NgxChain* = ptr NgxChainObj

    NgxHttpRequestObj {.importc: "ngx_http_request_t",
        header: "<ngx_http.h>", incompleteStruct.} = object
    NgxHttpRequest* = ptr NgxHttpRequestObj
      ## nginx HTTP request (ngx_http_request_t).

  # nginx memory allocation
  proc ngx_palloc*(pool: NgxPool; size: csize_t): pointer
    {.importc: "ngx_palloc", header: "<ngx_core.h>".}

  proc ngx_pcalloc*(pool: NgxPool; size: csize_t): pointer
    {.importc: "ngx_pcalloc", header: "<ngx_core.h>".}

  proc ngx_create_temp_buf*(pool: NgxPool; size: csize_t): NgxBuf
    {.importc: "ngx_create_temp_buf", header: "<ngx_core.h>".}

  # nginx HTTP output
  proc ngx_http_output_filter*(r: NgxHttpRequest; chain: NgxChain): NgxInt
    {.importc: "ngx_http_output_filter", header: "<ngx_http.h>".}

  proc ngx_http_send_header*(r: NgxHttpRequest): NgxInt
    {.importc: "ngx_http_send_header", header: "<ngx_http.h>".}

else:
  # Mock implementations for testing.

  type
    NgxInt* = cint
    NgxUint* = cuint

    MockBuf* = ref object
      ## Mock buffer representing an ngx_buf_t.
      ## Fields mirror the real struct for faithful testing.
      data*: seq[byte]
        ## Raw buffer storage (analogous to the memory behind pos..last).
      pos*: int
        ## Start offset of valid data within `data`.
      last*: int
        ## End offset of valid data within `data` (exclusive).
      lastBuf*: bool
        ## True if this is the final buffer in the response.
      memory*: bool
        ## True if buffer is in-memory (not file-backed).

    MockChainLink* = ref object
      ## Mock chain link representing an ngx_chain_t node.
      buf*: MockBuf
      next*: MockChainLink

    MockPool* = ref object
      ## Mock nginx memory pool. Tracks allocations for test assertions.
      allocations*: int
      failNextAlloc*: bool
        ## When true, the next allocation returns nil / raises, simulating
        ## pool exhaustion.

    MockRequest* = ref object
      ## Mock nginx request.
      pool*: MockPool
      uri*: string
      httpMethod*: string
      headers*: seq[(string, string)]

    # Type aliases matching the real API names.
    NgxPool* = MockPool
    NgxBuf* = MockBuf
    NgxChain* = MockChainLink
    NgxHttpRequest* = MockRequest

  proc newMockPool*(): MockPool =
    MockPool(allocations: 0, failNextAlloc: false)

  proc newMockRequest*(uri: string = "/"; httpMethod: string = "GET"): MockRequest =
    MockRequest(
      pool: newMockPool(),
      uri: uri,
      httpMethod: httpMethod,
      headers: @[],
    )

  proc ngx_palloc*(pool: MockPool; size: csize_t): pointer =
    if pool.failNextAlloc:
      pool.failNextAlloc = false
      return nil
    inc pool.allocations
    result = alloc0(size)

  proc ngx_pcalloc*(pool: MockPool; size: csize_t): pointer =
    if pool.failNextAlloc:
      pool.failNextAlloc = false
      return nil
    inc pool.allocations
    result = alloc0(size)

  proc ngx_create_temp_buf*(pool: MockPool; size: csize_t): MockBuf =
    ## Creates a mock buffer with `size` bytes of backing storage.
    ## The pos starts at 0 and last starts at 0 (empty). Callers
    ## fill it by copying data and advancing `last`.
    if pool.failNextAlloc:
      pool.failNextAlloc = false
      return nil
    inc pool.allocations
    MockBuf(
      data: newSeq[byte](size),
      pos: 0,
      last: 0,
      lastBuf: false,
      memory: true,
    )

  # Mock output filter — records calls and the chain passed.
  var mockOutputFilterCalls*: int = 0
  var mockOutputFilterLastChain*: MockChainLink = nil
  var mockOutputFilterReturnCode*: NgxInt = 0

  proc ngx_http_output_filter*(r: MockRequest; chain: MockChainLink): NgxInt =
    inc mockOutputFilterCalls
    mockOutputFilterLastChain = chain
    result = mockOutputFilterReturnCode

  proc ngx_http_send_header*(r: MockRequest): NgxInt =
    result = 0  # NGX_OK

  proc resetMockState*() =
    mockOutputFilterCalls = 0
    mockOutputFilterLastChain = nil
    mockOutputFilterReturnCode = 0

  # Helper: count the number of links in a chain.
  proc chainLen*(chain: MockChainLink): int =
    var cur = chain
    while cur != nil:
      inc result
      cur = cur.next

  # Helper: collect all buf data from a chain as a string.
  proc chainData*(chain: MockChainLink): string =
    var cur = chain
    while cur != nil:
      if cur.buf != nil and cur.buf.last > cur.buf.pos:
        for i in cur.buf.pos ..< cur.buf.last:
          result.add(char(cur.buf.data[i]))
      cur = cur.next

  # Helper: check if any buf in the chain has lastBuf set.
  proc hasLastBuf*(chain: MockChainLink): bool =
    var cur = chain
    while cur != nil:
      if cur.buf != nil and cur.buf.lastBuf:
        return true
      cur = cur.next
    return false

const
  ## nginx return codes.
  NGX_OK*: NgxInt = 0
  NGX_ERROR*: NgxInt = -1
  NGX_DECLINED*: NgxInt = -5

  ## HTTP status codes.
  NGX_HTTP_OK*: NgxInt = 200
  NGX_HTTP_NOT_FOUND*: NgxInt = 404
  NGX_HTTP_NOT_ALLOWED*: NgxInt = 405
  NGX_HTTP_INTERNAL_SERVER_ERROR*: NgxInt = 500
