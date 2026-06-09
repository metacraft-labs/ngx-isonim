## SSR Pipeline Profiler
##
## Measures each phase of the IsoNim server-side rendering pipeline
## to identify where time is spent per request.
##
## Usage: just profile-ssr
## Output: terminal summary + benchmarks/results/ssr_profile.json

import std/[times, stats, strformat, strutils, json, os]
import isonim/core/[owner, signals, computation]
import isonim/ssr/[renderer, markers, escape]
import isonim/dsl/ui

type
  Task = object
    id: int
    text: string
    done: bool

  PhaseResult = object
    name: string
    meanUs: float
    minUs: float
    maxUs: float
    stddevUs: float
    iterations: int

const taskData: array[5, Task] = [
  Task(id: 1, text: "Learn IsoNim reactive framework", done: true),
  Task(id: 2, text: "Build nginx SSR module", done: true),
  Task(id: 3, text: "Write E2E tests", done: false),
  Task(id: 4, text: "Deploy to production", done: false),
  Task(id: 5, text: "Celebrate!", done: false),
]

var results: seq[PhaseResult]

proc bench(name: string, n: int, body: proc()): PhaseResult =
  for i in 0 ..< 500: body()  # warmup
  var rs: RunningStat
  for i in 0 ..< n:
    let t0 = cpuTime()
    body()
    rs.push((cpuTime() - t0) * 1_000_000.0)
  result = PhaseResult(
    name: name, meanUs: rs.mean, minUs: rs.min,
    maxUs: rs.max, stddevUs: rs.standardDeviation,
    iterations: n)

proc printResult(r: PhaseResult) =
  echo fmt"{r.name:<50s} {r.meanUs:>7.2f} us  (min={r.minUs:.2f}  std={r.stddevUs:.1f})"

let N = parseInt(getEnv("BENCH_N", "50000"))

echo "=== SSR Pipeline Profile ==="
echo fmt"iterations: {N}   flags: -d:release -d:danger --opt:speed"
echo ""

results.add bench("1. resetHydrationCounter", N, proc() =
  resetHydrationCounter())
printResult(results[^1])

results.add bench("2. createRoot + dispose (empty)", N, proc() =
  createRoot do (dispose: proc()): dispose())
printResult(results[^1])

results.add bench("3. createRoot + 1 signal + dispose", N, proc() =
  createRoot do (dispose: proc()):
    let s = createSignal(0)
    discard s.val
    dispose())
printResult(results[^1])

results.add bench("4. createRoot + signal + memo + dispose", N, proc() =
  createRoot do (dispose: proc()):
    let ts = createSignal(@taskData)
    let ac = createMemo do () -> int:
      var c = 0
      for t in ts.val:
        if not t.done: inc c
      c
    discard ac.val
    dispose())
printResult(results[^1])

results.add bench("5. uiString (static, no signals)", N, proc() =
  discard uiString:
    tdiv(class = "app"):
      header: h1: text "Title"
      section: ul:
        li: text "Item 1"
        li: text "Item 2"
        li: text "Item 3"
      footer: p: text "Footer")
printResult(results[^1])

results.add bench("6. uiString (5 items, forIn)", N, proc() =
  let ts = @taskData
  discard uiString:
    ul(class = "task-list"):
      forIn(ts):
        li(class = if item.done: "task completed" else: "task"):
          input(`type` = "checkbox", checked = $item.done)
          span(class = "task-text"): text item.text
          button(class = "remove"): text "x")
printResult(results[^1])

results.add bench("7. renderToString (full task app)", N, proc() =
  discard renderToString do () -> string:
    let ts = createSignal(@taskData)
    let ac = createMemo do () -> int:
      var c = 0
      for t in ts.val:
        if not t.done: inc c
      c
    uiString:
      tdiv(class = "app"):
        header(class = "page-header"):
          h1: text "IsoNim Task Manager"
          p(class = "subtitle"): text "Served by nginx + IsoNim SSR"
        section(class = "task-section"):
          tdiv(class = "task-header"):
            h2: text "Tasks"
            span(class = "count"): text $ac.val & " active"
          ul(class = "task-list"):
            forIn(ts.val):
              li(class = if item.done: "task completed" else: "task"):
                input(`type` = "checkbox", checked = $item.done)
                span(class = "task-text"): text item.text
                button(class = "remove"): text "x"
        footer(class = "app-footer"):
          p: text "Powered by IsoNim + nginx")
printResult(results[^1])

results.add bench("8. generateHydrationScript", N, proc() =
  discard generateHydrationScript())
printResult(results[^1])

results.add bench("9. FULL: render + hydration + alloc/copy", N, proc() =
  let rendered = renderToString(proc(): string =
    let ts = createSignal(@taskData)
    let ac = createMemo do () -> int:
      var c = 0
      for t in ts.val:
        if not t.done: inc c
      c
    uiString:
      tdiv(class = "app"):
        header(class = "page-header"):
          h1: text "IsoNim Task Manager"
          p(class = "subtitle"): text "Served by nginx + IsoNim SSR"
        section(class = "task-section"):
          tdiv(class = "task-header"):
            h2: text "Tasks"
            span(class = "count"): text $ac.val & " active"
          ul(class = "task-list"):
            forIn(ts.val):
              li(class = if item.done: "task completed" else: "task"):
                input(`type` = "checkbox", checked = $item.done)
                span(class = "task-text"): text item.text
                button(class = "remove"): text "x"
        footer(class = "app-footer"):
          p: text "Powered by IsoNim + nginx"
  ) & generateHydrationScript()
  let buf = alloc(rendered.len + 1)
  copyMem(buf, unsafeAddr rendered[0], rendered.len)
  dealloc(buf))
printResult(results[^1])

# Output size info
let sample = renderToString(proc(): string =
  let ts = createSignal(@taskData)
  let ac = createMemo do () -> int:
    var c = 0
    for t in ts.val:
      if not t.done: inc c
    c
  uiString:
    tdiv(class = "app"):
      header(class = "page-header"):
        h1: text "IsoNim Task Manager"
        p(class = "subtitle"): text "Served by nginx + IsoNim SSR"
      section(class = "task-section"):
        tdiv(class = "task-header"):
          h2: text "Tasks"
          span(class = "count"): text $ac.val & " active"
        ul(class = "task-list"):
          forIn(ts.val):
            li(class = if item.done: "task completed" else: "task"):
              input(`type` = "checkbox", checked = $item.done)
              span(class = "task-text"): text item.text
              button(class = "remove"): text "x"
      footer(class = "app-footer"):
        p: text "Powered by IsoNim + nginx"
) & generateHydrationScript()

echo ""
echo fmt"HTML output: {sample.len} bytes"
echo fmt"Theoretical max: {(1_000_000.0 / results[^1].meanUs).int} req/s (1 / phase 9)"
echo ""

# Write JSON results
let outDir = "benchmarks/results"
createDir(outDir)
var jResults = newJArray()
for r in results:
  jResults.add(%*{
    "name": r.name,
    "mean_us": r.meanUs,
    "min_us": r.minUs,
    "max_us": r.maxUs,
    "stddev_us": r.stddevUs,
    "iterations": r.iterations,
  })
let jDoc = %*{
  "type": "ssr_profile",
  "timestamp": $now(),
  "iterations": N,
  "html_bytes": sample.len,
  "phases": jResults,
}
writeFile(outDir / "ssr_profile.json", $jDoc)
echo fmt"Detailed results: {outDir}/ssr_profile.json"
