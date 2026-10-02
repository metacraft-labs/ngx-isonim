## test_csp_nonce.nim
##
## test_csp_nonce_differs_per_response (IFP-M1).
##
## Real nginx with the real module (tests/e2e/harness.nim).  The `csp` app
## sets `Content-Security-Policy` with its response's nonce
## (`resp.cspNonceSource`); the module puts the nonce on the hydration
## bootstrap script.  The same location is requested 1,000 times.
##
## * Vacuity guard: every response carries a Content-Security-Policy header
##   whose nonce equals the bootstrap script's nonce attribute; all 1,000
##   nonces are distinct and each decodes to 16 bytes (128 bits).  The
##   Suspense page's $df scripts carry the same nonce as its header.
## * Falsifying mutation: a module whose nonce is a fixed value (as when
##   it was read from the location configuration) fails the distinctness
##   assertion while the header/script agreement still holds.
##
## No mocks.
##
## Run: nim c -r tests/e2e/test_csp_nonce.nim  (in the dev shell)

import std/[unittest, base64, strutils, sets]
import harness

const locations = """
    location /csp      { isonim_ssr on; isonim_ssr_app csp; }
    location /csp-b    { isonim_ssr on; isonim_ssr_app csp; isonim_ssr_mode buffered; }
    location /suspense { isonim_ssr on; isonim_ssr_app suspense; }
"""

type Sample = object
  headerNonce, scriptNonce: string

proc between(s, before, after: string): string =
  ## The text between the first `before` and the next `after`, or "".
  let a = s.find(before)
  if a < 0: return ""
  let start = a + before.len
  let e = s.find(after, start)
  if e < 0: "" else: s[start ..< e]

proc cspNonce(header: string): string =
  ## The nonce of the header's single 'nonce-…' source.
  if header.count("'nonce-") != 1: return ""
  between(header, "'nonce-", "'")

proc hydrationNonce(body: string): string =
  ## The nonce attribute of the _$HY bootstrap script.
  let i = body.find("window._$HY")
  if i < 0: return ""
  let tag = body.rfind("<script", last = i)
  if tag < 0: return ""
  between(body[tag ..< i], "nonce=\"", "\"")

proc fetchMany(n: Nginx; path: string; count: int): seq[Sample] =
  ## `count` sequential requests on one curl process (keep-alive), each
  ## response delimited by a marker written after it.
  var args = @["-sS", "-i", "-w", "\n--END-OF-RESPONSE--\n"]
  for i in 0 ..< count:
    args.add n.url(path & "?i=" & $i)
  let r = curl(args)
  doAssert r.exitCode == 0, "curl failed: " & r.stderr
  for raw in r.output.split("\n--END-OF-RESPONSE--\n"):
    if raw.len == 0: continue
    let resp = splitResponse(raw)
    var s: Sample
    let csp = resp.headers.headerValues("Content-Security-Policy")
    if csp.len == 1:
      s.headerNonce = cspNonce(csp[0])
    s.scriptNonce = hydrationNonce(resp.body)
    result.add s

proc distinctnessFailures(samples: seq[Sample]; expected: int): seq[string] =
  var seen = initHashSet[string]()
  for s in samples: seen.incl s.headerNonce
  if samples.len != expected:
    result.add "got " & $samples.len & " responses, expected " & $expected
  if seen.len != samples.len:
    result.add "distinctness: only " & $seen.len & " distinct nonces in " &
      $samples.len & " responses"

proc agreementFailures(samples: seq[Sample]): seq[string] =
  for i, s in samples:
    if s.headerNonce.len == 0:
      result.add "response " & $i & ": no nonce in the CSP header"
    elif s.headerNonce != s.scriptNonce:
      result.add "response " & $i & ": header nonce " & s.headerNonce &
        " != script nonce " & s.scriptNonce

proc entropyFailures(samples: seq[Sample]): seq[string] =
  for i, s in samples:
    let bytes = try: base64.decode(s.headerNonce) except ValueError: ""
    if bytes.len < 16:
      result.add "response " & $i & ": nonce " & s.headerNonce &
        " carries " & $(bytes.len * 8) & " bits"

suite "test_csp_nonce_differs_per_response":
  let module = testModule()
  let n = startNginx(module, locations)

  test "1,000 responses: header nonce = script nonce, all distinct, 128 bits":
    let samples = fetchMany(n, "/csp", 1000)
    let failures = agreementFailures(samples) & entropyFailures(samples) &
                   distinctnessFailures(samples, 1000)
    check failures.len == 0
    if failures.len > 0: echo failures[0 ..< min(10, failures.len)].join("\n")

  test "the buffered transport does the same":
    let samples = fetchMany(n, "/csp-b", 100)
    check (agreementFailures(samples) & entropyFailures(samples) &
           distinctnessFailures(samples, 100)).len == 0

  test "every script of a Suspense page carries the response's nonce":
    for i in 0 ..< 20:
      let r = curl(["-sS", "-i", n.url("/suspense")])
      check r.exitCode == 0
      let resp = splitResponse(r.output)
      let csp = resp.headers.headerValues("Content-Security-Policy")
      check csp.len == 1
      let nonce = cspNonce(csp[0])
      check nonce.len == 24
      check base64.decode(nonce).len == 16
      let scripts = resp.body.count("<script")
      check scripts == 3   # $df definition, the boundary's $df call, _$HY
      check resp.body.count("<script nonce=\"" & nonce & "\">") == scripts

  test "falsifying mutation: a fixed nonce fails the distinctness assertion":
    let mutant = buildMutant("fixed-nonce", "src/response.nim",
      "    r.nonce = generateCspNonce()",
      "    r.nonce = \"Zml4ZWQtcGVyLWxvY2F0aW9u\"  # as if from the location conf")
    let m = startNginx(mutant, locations)
    try:
      let samples = fetchMany(m, "/csp", 20)
      check distinctnessFailures(samples, 20).len > 0
      # The header and the script still agree: the distinctness assertion
      # is the one that catches this mutation.
      check agreementFailures(samples).len == 0
    finally:
      m.stop()

  test "no worker crashed":
    n.stop()
    check "exited on signal" notin n.errorLogText
    check "[alert]" notin n.errorLogText
