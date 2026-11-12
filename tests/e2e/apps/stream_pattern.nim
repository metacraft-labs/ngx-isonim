## stream_pattern.nim
##
## What the streaming async apps of stream_app.nim send, shared with
## tests/e2e/test_async_streaming.nim and tests/e2e/test_long_stream.nim,
## which check it byte for byte.

const shellHtml* = "<!DOCTYPE html><html><body><h1 id=\"shell\">Shell</h1>"
  ## The shell `stream_await`, `stream_raise_after` and `stream_hang` flush.

proc patternByte*(i: int): char =
  ## The byte at offset `i` of a `stream_big` body: position-dependent, so
  ## a lost, repeated or reordered part changes the body.  The reference
  ## definition: the tests compare what arrives against it, byte by byte.
  char(ord('a') + (i div 7 + i mod 13) mod 26)

const
  PatternPeriod* = 7 * 26
    ## `patternByte(i + PatternPeriod) == patternByte(i)`: `i div 7` grows by
    ## 26, which `mod 26` removes, and 182 is a multiple of 13, so `i mod 13`
    ## is unchanged.
  TileRepeats = 64
    ## Periods per tile, so that `patternFill` copies about 11 KiB per
    ## `copyMem` instead of 182 bytes.

proc makeTile(): string =
  result = newString(PatternPeriod * TileRepeats)
  for i in 0 ..< result.len:
    result[i] = patternByte(i)

let patternTile = makeTile()
  ## The pattern from offset 0, `TileRepeats` periods long, built once when
  ## the module is initialized (a `let`, not a `const`: `copyMem` needs its
  ## address).

proc patternFill*(dst: var openArray[char]; offset: int) =
  ## Fills `dst` with the pattern's bytes from `offset` on, i.e.
  ## `dst[k] = patternByte(offset + k)`, by block copies of the
  ## precomputed tile.
  ##
  ## The apps fill their buffers with this rather than calling `patternByte`
  ## per byte: the apps run inside nginx, and under the AddressSanitizer
  ## build (tests/e2e/test_rpc_asan.sh) every Nim call goes through ASan's
  ## `__tls_get_addr` interception, so a per-byte call made the fixture,
  ## not the module, the cost the latency measurements saw.
  assert offset >= 0
  var i = 0
  var phase = offset mod PatternPeriod
  while i < dst.len:
    let n = min(patternTile.len - phase, dst.len - i)
    copyMem(addr dst[i], unsafeAddr patternTile[phase], n)
    i += n
    phase = 0

proc patternBody*(size: int): string =
  ## The whole `stream_big` body of `size` bytes, from the reference
  ## `patternByte` (deliberately not `patternFill`: the tests compare what
  ## the apps produced with `patternFill` against it).
  result = newString(size)
  for i in 0 ..< size:
    result[i] = patternByte(i)
