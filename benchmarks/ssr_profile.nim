## Profiles each phase of the IsoNim SSR pipeline individually
## to identify where time is spent in the nginx request handler.
##
## Compile: nim c -d:release -d:danger --opt:speed -d:isServer \
##          --path:../isonim/src -r benchmarks/ssr_profile.nim

import std/[times, stats, strformat, strutils]
import isonim/core/[owner, signals, computation]
import isonim/ssr/[renderer, markers, escape]
import isonim/dsl/html

type
  Task = object
    id: int
    text: string
    done: bool

const taskData: array[5, Task] = [
  Task(id: 1, text: "Learn IsoNim reactive framework", done: true),
  Task(id: 2, text: "Build nginx SSR module", done: true),
  Task(id: 3, text: "Write E2E tests", done: false),
  Task(id: 4, text: "Deploy to production", done: false),
  Task(id: 5, text: "Celebrate!", done: false),
]

proc bench(name: string, n: int, body: proc()) =
  for i in 0 ..< 200: body()  # warmup
  var rs: RunningStat
  for i in 0 ..< n:
    let t0 = cpuTime()
    body()
    rs.push((cpuTime() - t0) * 1_000_000.0)
  echo fmt"{name:<45s} {rs.mean:>7.2f} us  (min={rs.min:.2f} max={rs.max:.1f} std={rs.standardDeviation:.1f})"

const N = 50_000

echo "=== SSR Pipeline Profiling (", N, " iterations, -d:release -d:danger) ==="
echo ""

bench("1. resetHydrationCounter", N):
  resetHydrationCounter()

bench("2. createRoot + dispose (empty)", N):
  createRoot proc(dispose: proc()) =
    dispose()

bench("3. createRoot + 1 signal + dispose", N):
  createRoot proc(dispose: proc()) =
    let s = createSignal(0)
    discard s.val
    dispose()

bench("4. createRoot + signal + memo + dispose", N):
  createRoot proc(dispose: proc()) =
    let ts = createSignal(@taskData)
    let ac = createMemo proc(): int =
      var c = 0
      for t in ts.val:
        if not t.done: inc c
      c
    discard ac.val
    dispose()

bench("5. buildHtmlString (static, no signals)", N):
  discard buildHtmlString:
    tdiv(class = "app"):
      header: h1: text "Title"
      section: ul:
        li: text "Item 1"
        li: text "Item 2"
        li: text "Item 3"
      footer: p: text "Footer"

bench("6. buildHtmlString (5 items, forIn)", N):
  let ts = @taskData
  discard buildHtmlString:
    ul(class = "task-list"):
      forIn(ts):
        li(class = if item.done: "task completed" else: "task"):
          input(`type` = "checkbox", checked = $item.done)
          span(class = "task-text"): text item.text
          button(class = "remove"): text "x"

bench("7. renderToString (full task app)", N):
  discard renderToString proc(): string =
    let ts = createSignal(@taskData)
    let ac = createMemo proc(): int =
      var c = 0
      for t in ts.val:
        if not t.done: inc c
      c
    buildHtmlString:
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

bench("8. generateHydrationScript", N):
  discard generateHydrationScript()

# Simulate the full handler pipeline
bench("9. FULL: render + hydration + alloc/copy", N):
  let rendered = renderToString(proc(): string =
    let ts = createSignal(@taskData)
    let ac = createMemo proc(): int =
      var c = 0
      for t in ts.val:
        if not t.done: inc c
      c
    buildHtmlString:
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
  dealloc(buf)

echo ""
echo "=== Summary ==="
echo "Phases 1-4: reactive scope setup/teardown"
echo "Phases 5-6: HTML string generation"
echo "Phase 7:    full SSR render (1+2+3+4+5+6 combined)"
echo "Phase 8:    hydration script"
echo "Phase 9:    full handler pipeline (7+8+alloc/copy)"
echo ""
echo "nginx overhead = wrk latency - phase 9 mean"
echo "(accounts for TCP, HTTP parsing, output filter, etc.)"
