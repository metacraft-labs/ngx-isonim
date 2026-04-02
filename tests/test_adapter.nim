## test_adapter.nim
##
## Unit tests for the nginx faststreams adapter using mock mode.
## Compile with: nim c -r -d:isNginxTest tests/test_adapter.nim

import unittest
import ../src/nginx_types
import ../src/nginx_adapter

suite "nginx Adapter - Mock Stream":
  setup:
    resetMockState()

  test "write_data_collected_in_mock_chain":
    ## Write data and verify it is collected in mock chunks.
    let stream = newMockNginxOutputStream()
    stream.write("Hello")
    stream.write(" World")

    check stream.chunks.len == 2
    check stream.chunks[0] == "Hello"
    check stream.chunks[1] == " World"
    check stream.getOutput() == "Hello World"

  test "flush_sets_flushed_flag":
    ## Flush marks the stream as flushed.
    let stream = newMockNginxOutputStream()
    stream.write("data")
    check not stream.flushed
    stream.flush()
    check stream.flushed
    check stream.flushCount == 1

  test "close_sets_closed_flag":
    ## Close marks the stream as closed.
    let stream = newMockNginxOutputStream()
    stream.write("data")
    check not stream.closed
    stream.close()
    check stream.closed

  test "multiple_writes_correct_chunk_count":
    ## Multiple writes produce the correct number of chunks.
    let stream = newMockNginxOutputStream()
    stream.write("chunk1")
    stream.write("chunk2")
    stream.write("chunk3")
    stream.write("chunk4")
    stream.write("chunk5")

    check stream.chunks.len == 5
    check stream.getOutput() == "chunk1chunk2chunk3chunk4chunk5"

  test "empty_write_no_chunk_added":
    ## An empty write does not add a chunk.
    let stream = newMockNginxOutputStream()
    stream.write("")
    check stream.chunks.len == 0
    stream.write("data")
    stream.write("")
    check stream.chunks.len == 1

  test "multiple_flushes":
    ## Multiple flushes increment the flush count.
    let stream = newMockNginxOutputStream()
    stream.write("a")
    stream.flush()
    stream.write("b")
    stream.flush()
    check stream.flushCount == 2

  test "write_after_flush":
    ## Writing after flush continues to accumulate chunks.
    let stream = newMockNginxOutputStream()
    stream.write("before")
    stream.flush()
    stream.write("after")
    check stream.chunks.len == 2
    check stream.getOutput() == "beforeafter"

  test "full_lifecycle":
    ## Test the full write-flush-close lifecycle.
    let stream = newMockNginxOutputStream()
    stream.write("<html>")
    stream.write("<body>Hello</body>")
    stream.flush()
    stream.write("</html>")
    stream.close()

    check stream.chunks.len == 3
    check stream.flushed
    check stream.closed
    check stream.getOutput() == "<html><body>Hello</body></html>"


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
    ## Mock create_temp_buf returns a MockBuf.
    let pool = newMockPool()
    let buf = ngx_create_temp_buf(pool, 256)
    check buf != nil
    check buf.data == ""
    check not buf.lastBuf
    check pool.allocations == 1

  test "mock_output_filter":
    ## Mock output filter tracks calls.
    let req = newMockRequest("/test")
    check mockOutputFilterCalls == 0
    discard ngx_http_output_filter(req, nil)
    check mockOutputFilterCalls == 1

  test "mock_request_creation":
    ## Mock request has expected defaults.
    let req = newMockRequest("/hello", "POST")
    check req.uri == "/hello"
    check req.httpMethod == "POST"
    check req.pool != nil
    check req.headers.len == 0
