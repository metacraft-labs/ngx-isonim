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

    NgxPool* = ptr object
      ## Opaque nginx memory pool (ngx_pool_t).

    NgxBuf* = ptr object
      ## nginx buffer (ngx_buf_t). Key fields:
      ##   pos: ptr byte      — start of data to send
      ##   last: ptr byte     — end of data to send
      ##   last_buf: cint     — 1 if this is the last buffer in the response
      ##   memory: cint       — 1 if the buffer is in memory (not file)

    NgxChain* = ptr object
      ## nginx buffer chain (ngx_chain_t). Linked list:
      ##   buf: NgxBuf
      ##   next: NgxChain

    NgxHttpRequest* = ptr object
      ## Opaque nginx HTTP request (ngx_http_request_t).

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
      data*: string
      lastBuf*: bool

    MockChainLink* = ref object
      ## Mock chain link representing an ngx_chain_t node.
      buf*: MockBuf
      next*: MockChainLink

    MockPool* = ref object
      ## Mock nginx memory pool.
      allocations*: int

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
    MockPool(allocations: 0)

  proc newMockRequest*(uri: string = "/"; httpMethod: string = "GET"): MockRequest =
    MockRequest(
      pool: newMockPool(),
      uri: uri,
      httpMethod: httpMethod,
      headers: @[],
    )

  proc ngx_palloc*(pool: MockPool; size: csize_t): pointer =
    inc pool.allocations
    result = alloc0(size)

  proc ngx_pcalloc*(pool: MockPool; size: csize_t): pointer =
    inc pool.allocations
    result = alloc0(size)

  proc ngx_create_temp_buf*(pool: MockPool; size: csize_t): MockBuf =
    inc pool.allocations
    MockBuf(data: newString(0), lastBuf: false)

  # Mock output filter — just returns OK.
  var mockOutputFilterCalls*: int = 0
  var mockOutputFilterLastChain*: MockChainLink = nil

  proc ngx_http_output_filter*(r: MockRequest; chain: MockChainLink): NgxInt =
    inc mockOutputFilterCalls
    mockOutputFilterLastChain = chain
    result = 0  # NGX_OK

  proc ngx_http_send_header*(r: MockRequest): NgxInt =
    result = 0  # NGX_OK

  proc resetMockState*() =
    mockOutputFilterCalls = 0
    mockOutputFilterLastChain = nil

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
