## stream_pattern.nim
##
## What the streaming async apps of stream_app.nim send, shared with
## tests/e2e/test_async_streaming.nim, which checks it byte for byte.

const shellHtml* = "<!DOCTYPE html><html><body><h1 id=\"shell\">Shell</h1>"
  ## The shell `stream_await`, `stream_raise_after` and `stream_hang` flush.

proc patternByte*(i: int): char =
  ## The byte at offset `i` of a `stream_big` body: position-dependent, so
  ## a lost, repeated or reordered part changes the body.
  char(ord('a') + (i div 7 + i mod 13) mod 26)

proc patternBody*(size: int): string =
  ## The whole `stream_big` body of `size` bytes.
  result = newString(size)
  for i in 0 ..< size:
    result[i] = patternByte(i)
