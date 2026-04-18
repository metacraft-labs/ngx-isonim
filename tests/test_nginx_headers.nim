## test_nginx_headers.nim
##
## Unit tests for zero-copy nginx header access.
## Compile with: nim c -r -d:isNginxTest tests/test_nginx_headers.nim

import unittest
import ../src/nginx_types
import ../src/nginx_http_adapter
import ../src/nginx_adapter

suite "nginx Zero-Copy Headers":
  test "test_nginx_header_view_no_copy":
    # Build a mock header list
    var headers = @[
      ("Content-Type", "application/json"),
      ("X-Request-Id", "abc123")
    ]
    let parts = buildMockHeaderList(headers)

    # Find header by name -- the value should point into the original string memory
    let ctValue = findHeader(parts, "Content-Type")
    check ngxStrEquals(ctValue, "application/json")
    check not ngxStrEquals(ctValue, "text/html")

    # Case-insensitive lookup
    let ctValue2 = findHeader(parts, "content-type")
    check ngxStrEquals(ctValue2, "application/json")

  test "test_nginx_response_stream_to_chain":
    # Use the existing mock output stream
    resetMockState()
    let req = newMockRequest("/test", "GET")
    let stream = newNginxOutputStream(req)

    stream.write("Hello, ")
    stream.write("World!")
    stream.flush()

    # Verify the output went through the mock chain
    check mockOutputFilterCalls >= 1

    stream.close()

  test "header iteration walks all entries":
    var headers = @[
      ("Host", "example.com"),
      ("Accept", "text/html"),
      ("Accept-Encoding", "gzip")
    ]
    let parts = buildMockHeaderList(headers)

    var count = 0
    for (k, v) in walkHeaders(parts):
      count += 1
    check count == 3

  test "ngxStr comparison and conversion":
    var s = "hello world"
    let ngxs = MockNgxStr(data: cast[ptr byte](addr s[0]), len: s.len)

    check ngxStrEquals(ngxs, "hello world")
    check not ngxStrEquals(ngxs, "hello")
    check ngxStrStartsWith(ngxs, "hello")
    check not ngxStrStartsWith(ngxs, "world")

    let owned = ngxStrToString(ngxs)
    check owned == "hello world"

  test "findHeader returns empty NgxStr for missing header":
    var headers = @[
      ("Host", "example.com"),
    ]
    let parts = buildMockHeaderList(headers)

    let missing = findHeader(parts, "X-Missing")
    check missing.data == nil
    check missing.len == 0

  test "ngxStrToOpenArray passes correct view":
    var s = "test data"
    let ngxs = MockNgxStr(data: cast[ptr byte](addr s[0]), len: s.len)

    var viewLen = 0
    var viewContent = ""
    ngxStrToOpenArray(ngxs, proc(view: openArray[byte]) =
      viewLen = view.len
      for b in view:
        viewContent.add(char(b))
    )
    check viewLen == 9
    check viewContent == "test data"

  test "ngxStrToOpenArray handles empty string":
    let ngxs = MockNgxStr(data: nil, len: 0)

    var callbackCalled = false
    ngxStrToOpenArray(ngxs, proc(view: openArray[byte]) =
      callbackCalled = true
      check view.len == 0
    )
    check callbackCalled

  test "multi-part header list iteration":
    # Build two linked parts to test multi-part walking
    var headers1 = @[("Host", "example.com")]
    var headers2 = @[("Accept", "text/html")]
    let part1 = buildMockHeaderList(headers1)
    let part2 = buildMockHeaderList(headers2)
    part1.next = part2

    var count = 0
    for (k, v) in walkHeaders(part1):
      count += 1
    check count == 2

    # findHeader should search across parts
    let host = findHeader(part1, "Host")
    check ngxStrEquals(host, "example.com")
    let accept = findHeader(part1, "Accept")
    check ngxStrEquals(accept, "text/html")
