## test_adapter.nim
##
## Unit tests for the nginx faststreams adapter using mock mode.
## Tests exercise the full OutputStreamVTable lifecycle (write/flush/close)
## using mock nginx types that track buf allocations, chain structure,
## and output filter calls.
##
## Compile with: nim c -r -d:isNginxTest tests/test_adapter.nim

import unittest
import std/strutils
import ../src/nginx_types
import ../src/nginx_adapter


suite "nginx Adapter - Write":
  setup:
    resetMockState()

  test "write_allocates_buf_with_correct_size":
    ## Write data and verify a buf is allocated with the right data size.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("Hello")

    check ns.chainHead != nil
    check ns.chainHead.buf != nil
    check ns.chainHead.buf.data.len == 5  # buf allocated for 5 bytes
    check ns.chainHead.buf.pos == 0
    check ns.chainHead.buf.last == 5
    check ns.chainHead.buf.memory == true

  test "write_copies_correct_data":
    ## Verify the actual bytes written match the source data.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("Hello")

    let buf = ns.chainHead.buf
    var got = ""
    for i in buf.pos ..< buf.last:
      got.add(char(buf.data[i]))
    check got == "Hello"

  test "empty_write_no_buf_allocated":
    ## An empty write does not allocate a buf or modify the chain.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("")

    check ns.chainHead.isNil
    check req.pool.allocations == 0

  test "multiple_writes_correct_chain_length":
    ## Multiple writes produce the correct number of bufs in the chain.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("chunk1")
    ns.write("chunk2")
    ns.write("chunk3")
    ns.write("chunk4")
    ns.write("chunk5")

    check chainLen(ns.chainHead) == 5

  test "multiple_writes_correct_data":
    ## Multiple writes produce a chain whose concatenated data is correct.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("Hello")
    ns.write(" ")
    ns.write("World")

    check chainData(ns.chainHead) == "Hello World"

  test "write_tracks_pool_allocations":
    ## Each write allocates exactly one buf from the pool.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    check req.pool.allocations == 0
    ns.write("a")
    check req.pool.allocations == 1
    ns.write("b")
    check req.pool.allocations == 2


suite "nginx Adapter - Flush":
  setup:
    resetMockState()

  test "flush_calls_output_filter":
    ## Flush calls ngx_http_output_filter exactly once.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("data")
    ns.flush()

    check mockOutputFilterCalls == 1

  test "flush_passes_chain_to_output_filter":
    ## Flush passes the chain head to ngx_http_output_filter.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("abc")
    ns.write("def")

    # Capture the chain before flush clears it.
    let chain = ns.chainHead
    check chainLen(chain) == 2

    ns.flush()
    # The mock records the last chain passed to output_filter.
    check mockOutputFilterLastChain == chain

  test "flush_resets_chain":
    ## After flush, the chain head and tail are nil.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("data")
    ns.flush()

    check ns.chainHead.isNil
    check ns.chainTail.isNil

  test "flush_on_empty_chain_is_noop":
    ## Flushing with no pending writes does not call output_filter.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.flush()

    check mockOutputFilterCalls == 0

  test "write_flush_write_flush_resets_between_flushes":
    ## Chain resets between flushes — each flush sees only the writes
    ## since the last flush.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    ns.write("first")
    ns.flush()
    check mockOutputFilterCalls == 1
    let firstChain = mockOutputFilterLastChain
    check chainLen(firstChain) == 1
    check chainData(firstChain) == "first"

    ns.write("second")
    ns.write("third")
    ns.flush()
    check mockOutputFilterCalls == 2
    let secondChain = mockOutputFilterLastChain
    check chainLen(secondChain) == 2
    check chainData(secondChain) == "secondthird"

  test "flush_error_raises_ioerror":
    ## If ngx_http_output_filter returns an error code, flush raises IOError.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("data")

    mockOutputFilterReturnCode = NGX_ERROR
    expect(IOError):
      ns.flush()


suite "nginx Adapter - Close":
  setup:
    resetMockState()

  test "close_sets_last_buf_flag":
    ## Close appends a buf with lastBuf=true and flushes.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("body")
    ns.close()

    check mockOutputFilterCalls == 1
    check mockOutputFilterLastChain != nil
    check hasLastBuf(mockOutputFilterLastChain)

  test "close_includes_pending_writes":
    ## Close flushes any pending writes along with the last_buf marker.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("data")
    ns.close()

    let chain = mockOutputFilterLastChain
    check chainLen(chain) == 2  # data buf + last_buf sentinel
    check chainData(chain) == "data"
    # Last link should have lastBuf set.
    var lastLink = chain
    while lastLink.next != nil:
      lastLink = lastLink.next
    check lastLink.buf.lastBuf == true

  test "close_without_writes_sends_last_buf_only":
    ## Close on an empty stream still sends the last_buf marker.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.close()

    check mockOutputFilterCalls == 1
    let chain = mockOutputFilterLastChain
    check chainLen(chain) == 1
    check chain.buf.lastBuf == true

  test "close_after_flush_sends_last_buf":
    ## If writes were already flushed, close sends only the last_buf.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)
    ns.write("body")
    ns.flush()
    check mockOutputFilterCalls == 1

    ns.close()
    check mockOutputFilterCalls == 2
    let chain = mockOutputFilterLastChain
    check chainLen(chain) == 1
    check chain.buf.lastBuf == true

  test "close_error_raises_ioerror":
    ## If ngx_http_output_filter fails during close, IOError is raised.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    mockOutputFilterReturnCode = NGX_ERROR
    expect(IOError):
      ns.close()


suite "nginx Adapter - Large Write Chunking":
  setup:
    resetMockState()

  test "large_write_chunked_creates_multiple_bufs":
    ## Writing data larger than page size with writeChunked splits into
    ## multiple bufs, each at most chunkSize bytes.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    # Create a string larger than the default page size.
    let data = 'A'.repeat(nginxPageSize * 3 + 100)
    ns.writeChunked(data)

    # Should be 4 bufs: 3 full pages + 1 partial.
    check chainLen(ns.chainHead) == 4

    # Verify total data is preserved.
    check chainData(ns.chainHead) == data

  test "large_write_chunked_with_custom_chunk_size":
    ## Chunked write with a small chunk size for testing.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    ns.writeChunked("abcdefghij", chunkSize = 3)

    # "abc", "def", "ghi", "j" = 4 bufs
    check chainLen(ns.chainHead) == 4
    check chainData(ns.chainHead) == "abcdefghij"

  test "large_write_exact_multiple_of_chunk_size":
    ## Data exactly divisible by chunk size produces exact number of bufs.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    ns.writeChunked("abcdef", chunkSize = 3)

    check chainLen(ns.chainHead) == 2
    check chainData(ns.chainHead) == "abcdef"

  test "chunked_write_then_flush_and_close":
    ## Full lifecycle with chunked writes.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    ns.writeChunked("Hello World!", chunkSize = 5)
    # "Hello", " Worl", "d!" = 3 bufs
    check chainLen(ns.chainHead) == 3

    ns.flush()
    check mockOutputFilterCalls == 1
    check chainData(mockOutputFilterLastChain) == "Hello World!"

    ns.close()
    check mockOutputFilterCalls == 2
    check hasLastBuf(mockOutputFilterLastChain)


suite "nginx Adapter - Pool Allocation Failure":
  setup:
    resetMockState()

  test "write_pool_failure_raises_ioerror":
    ## If ngx_create_temp_buf returns nil (pool exhausted), write raises IOError.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    req.pool.failNextAlloc = true
    expect(IOError):
      ns.write("data")

  test "write_after_pool_failure_recovery":
    ## After a pool failure, subsequent writes succeed if the pool recovers.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    req.pool.failNextAlloc = true
    var raised = false
    try:
      ns.write("data")
    except IOError:
      raised = true
    check raised

    # Pool recovered — next write should succeed.
    ns.write("ok")
    check ns.chainHead != nil
    check chainData(ns.chainHead) == "ok"


suite "nginx Adapter - Full Lifecycle":
  setup:
    resetMockState()

  test "write_flush_close_lifecycle":
    ## Test the complete write-flush-close lifecycle that mirrors
    ## how the production adapter drives ngx_http_output_filter.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    # Write HTML shell (first flush = TTFB).
    ns.write("<html><head><title>Test</title></head><body>")
    ns.flush()
    check mockOutputFilterCalls == 1
    check chainData(mockOutputFilterLastChain) == "<html><head><title>Test</title></head><body>"

    # Write body content.
    ns.write("<div>Hello World</div>")
    ns.flush()
    check mockOutputFilterCalls == 2
    check chainData(mockOutputFilterLastChain) == "<div>Hello World</div>"

    # Write closing tags and close.
    ns.write("</body></html>")
    ns.close()
    check mockOutputFilterCalls == 3
    check hasLastBuf(mockOutputFilterLastChain)

  test "streaming_ssr_simulation":
    ## Simulates a streaming SSR response: shell, suspense boundary,
    ## hydration script, close.
    let req = newMockRequest("/")
    let ns = newNginxOutputStream(req)

    # Shell (TTFB).
    ns.write("<!DOCTYPE html><html><body>")
    ns.write("<div id=\"app\"><!--$-->Loading...<!--/$-->")
    ns.flush()
    check mockOutputFilterCalls == 1

    # Suspense boundary resolves.
    ns.write("<script>_$RC('b0', '<p>Content</p>')</script>")
    ns.flush()
    check mockOutputFilterCalls == 2

    # Hydration script + close.
    ns.write("<script>window._$HY={}</script>")
    ns.write("</body></html>")
    ns.close()
    check mockOutputFilterCalls == 3
    check hasLastBuf(mockOutputFilterLastChain)


suite "nginx Adapter - Mock Types":
  setup:
    resetMockState()

  test "nginx_type_constants":
    ## Verify nginx type constants have correct values.
    check NGX_OK == 0.NgxInt
    check NGX_ERROR == (-1).NgxInt
    check NGX_DECLINED == (-5).NgxInt
    check NGX_HTTP_OK == 200.NgxInt
    check NGX_HTTP_NOT_FOUND == 404.NgxInt
    check NGX_HTTP_NOT_ALLOWED == 405.NgxInt
    check NGX_HTTP_INTERNAL_SERVER_ERROR == 500.NgxInt

  test "mock_pool_tracks_allocations":
    ## Mock pool tracks allocation count.
    let pool = newMockPool()
    check pool.allocations == 0
    discard ngx_palloc(pool, 64)
    check pool.allocations == 1
    discard ngx_pcalloc(pool, 128)
    check pool.allocations == 2

  test "mock_create_temp_buf":
    ## Mock create_temp_buf returns a MockBuf with correct initial state.
    let pool = newMockPool()
    let buf = ngx_create_temp_buf(pool, 256)
    check buf != nil
    check buf.data.len == 256
    check buf.pos == 0
    check buf.last == 0
    check not buf.lastBuf
    check buf.memory == true
    check pool.allocations == 1

  test "mock_output_filter":
    ## Mock output filter tracks calls.
    let req = newMockRequest("/test")
    check mockOutputFilterCalls == 0
    discard ngx_http_output_filter(req, nil)
    check mockOutputFilterCalls == 1

  test "mock_output_filter_configurable_return_code":
    ## Mock output filter can be configured to return error codes.
    let req = newMockRequest("/")
    mockOutputFilterReturnCode = NGX_ERROR
    let rc = ngx_http_output_filter(req, nil)
    check rc == NGX_ERROR

  test "mock_request_creation":
    ## Mock request has expected defaults.
    let req = newMockRequest("/hello", "POST")
    check req.uri == "/hello"
    check req.httpMethod == "POST"
    check req.pool != nil
    check req.headers.len == 0

  test "mock_pool_fail_next_alloc":
    ## Pool's failNextAlloc flag causes one allocation to fail, then resets.
    let pool = newMockPool()
    pool.failNextAlloc = true
    let buf = ngx_create_temp_buf(pool, 64)
    check buf.isNil
    # Flag auto-resets.
    let buf2 = ngx_create_temp_buf(pool, 64)
    check buf2 != nil

  test "chain_len_helper":
    ## chainLen correctly counts chain links.
    let c = MockChainLink(
      buf: nil,
      next: MockChainLink(
        buf: nil,
        next: MockChainLink(buf: nil, next: nil),
      ),
    )
    check chainLen(c) == 3
    check chainLen(nil) == 0

  test "reset_mock_state_clears_all":
    ## resetMockState clears global mock tracking variables.
    let req = newMockRequest("/")
    discard ngx_http_output_filter(req, nil)
    mockOutputFilterReturnCode = NGX_ERROR
    check mockOutputFilterCalls == 1

    resetMockState()
    check mockOutputFilterCalls == 0
    check mockOutputFilterLastChain.isNil
    check mockOutputFilterReturnCode == NGX_OK
