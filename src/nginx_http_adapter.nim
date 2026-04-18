## nginx_http_adapter.nim
##
## Zero-copy header access for nginx HTTP requests.
##
## Bridges nginx's ngx_str_t / ngx_list_t header structures to Nim
## without copying. Provides comparison, prefix matching, iteration,
## and explicit copy-to-string when ownership is needed.
##
## When compiled with -d:isNginxTest, operates on MockNgxStr / MockListPart.

import std/strutils
import nginx_types

proc ngxStrToOpenArray*(s: NgxStr, cb: proc(view: openArray[byte])) =
  ## Pass an ngx_str_t as a borrowed openArray[byte] to a callback.
  ## The view is valid only during the callback -- cannot escape.
  var empty: array[0, byte]
  when defined(isNginxTest):
    if s.len > 0 and s.data != nil:
      cb(toOpenArray(cast[ptr UncheckedArray[byte]](s.data), 0, s.len - 1))
    else:
      cb(empty)
  else:
    if s.len > 0 and s.data != nil:
      cb(toOpenArray(cast[ptr UncheckedArray[byte]](s.data), 0, int(s.len) - 1))
    else:
      cb(empty)

proc ngxStrEquals*(s: NgxStr, expected: string): bool =
  ## Compare an ngx_str_t with a Nim string without copying.
  when defined(isNginxTest):
    if s.len != expected.len: return false
    if s.len == 0: return true
    equalMem(s.data, unsafeAddr expected[0], s.len)
  else:
    if int(s.len) != expected.len: return false
    if s.len == 0: return true
    equalMem(s.data, unsafeAddr expected[0], int(s.len))

proc ngxStrStartsWith*(s: NgxStr, prefix: string): bool =
  ## Check if an ngx_str_t starts with the given prefix without copying.
  when defined(isNginxTest):
    if s.len < prefix.len: return false
    if prefix.len == 0: return true
    equalMem(s.data, unsafeAddr prefix[0], prefix.len)
  else:
    if int(s.len) < prefix.len: return false
    if prefix.len == 0: return true
    equalMem(s.data, unsafeAddr prefix[0], prefix.len)

proc ngxStrToString*(s: NgxStr): string =
  ## Explicit copy to owned string. Use only when storage is needed.
  when defined(isNginxTest):
    if s.len > 0 and s.data != nil:
      result = newString(s.len)
      copyMem(addr result[0], s.data, s.len)
    else:
      result = ""
  else:
    if s.len > 0 and s.data != nil:
      result = newString(int(s.len))
      copyMem(addr result[0], s.data, int(s.len))
    else:
      result = ""

iterator walkHeaders*(part: NgxListPart): (NgxStr, NgxStr) =
  ## Walk an nginx header list without copying.
  ## Each iteration yields (key, value) as NgxStr views.
  when defined(isNginxTest):
    var cur = part
    while cur != nil:
      for elt in cur.elts:
        yield (elt.key, elt.value)
      cur = cur.next
  else:
    var cur = part
    while cur != nil:
      let elts = cast[ptr UncheckedArray[NgxTableEltObj]](cur.elts)
      for i in 0 ..< int(cur.nelts):
        yield (elts[i].key, elts[i].value)
      cur = cur.next

proc findHeader*(part: NgxListPart, name: string): NgxStr =
  ## Find a header by name (case-insensitive) in an nginx header list.
  for (k, v) in walkHeaders(part):
    let kStr = ngxStrToString(k)
    if cmpIgnoreCase(kStr, name) == 0:
      return v
  when defined(isNginxTest):
    return MockNgxStr(data: nil, len: 0)
  else:
    return NgxStr(data: nil, len: 0)

proc buildMockHeaderList*(headers: var seq[(string, string)]): MockListPart =
  ## Build a mock nginx header list. The headers seq must stay alive
  ## for the lifetime of the returned list (openArray-like borrowing).
  var part = MockListPart(elts: @[], next: nil)
  for i in 0 ..< headers.len:
    var elt = MockTableElt()
    if headers[i][0].len > 0:
      elt.key = MockNgxStr(data: cast[ptr byte](addr headers[i][0][0]), len: headers[i][0].len)
    if headers[i][1].len > 0:
      elt.value = MockNgxStr(data: cast[ptr byte](addr headers[i][1][0]), len: headers[i][1].len)
    part.elts.add(elt)
  return part
