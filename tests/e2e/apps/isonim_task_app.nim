## A realistic IsoNim SSR task manager app for E2E testing.
## Uses the actual isonim reactive core, DSL, and SSR renderer.
## Compiled with -d:isServer for SSR mode.

import isonim/core/owner
import isonim/core/signals
import isonim/core/computation
import isonim/ssr/renderer
import isonim/ssr/markers
import isonim/ssr/escape
import isonim/dsl/ui

type
  Task* = object
    id*: int
    text*: string
    done*: bool

proc renderTaskApp*(tasks: seq[Task]): string =
  ## Renders the task manager app to an HTML string with hydration markers.
  renderToString proc(): string =
    var taskSignal = createSignal(tasks)
    var filter = createSignal("all")

    let activeCount = createMemo proc(): int =
      var count = 0
      for t in taskSignal.val:
        if not t.done: inc count
      count

    ui:
      tdiv(class = "app"):
        header(class = "page-header"):
          h1: text "IsoNim Task Manager"
          p(class = "subtitle"):
            text "Served by nginx + IsoNim SSR"

        section(class = "task-section"):
          tdiv(class = "task-header"):
            h2: text "Tasks"
            span(class = "count"):
              text $activeCount.val & " active"

          ul(class = "task-list"):
            for item in taskSignal.val:
              li(class = if item.done: "task completed" else: "task"):
                input(`type` = "checkbox", checked = $item.done)
                span(class = "task-text"):
                  text item.text
                button(class = "remove"): text "x"

          if taskSignal.val.len == 0:
            p(class = "empty-state"): text "No tasks yet"

        footer(class = "app-footer"):
          p: text "Powered by IsoNim + nginx"

proc renderTaskAppWithHydration*(tasks: seq[Task], nonce: string = ""): string =
  let html = renderTaskApp(tasks)
  let script = generateHydrationScript(nonce = nonce)
  html & script

proc defaultTasks*(): seq[Task] =
  @[
    Task(id: 1, text: "Learn IsoNim reactive framework", done: true),
    Task(id: 2, text: "Build nginx SSR module", done: true),
    Task(id: 3, text: "Write E2E tests", done: false),
    Task(id: 4, text: "Deploy to production", done: false),
    Task(id: 5, text: "Celebrate!", done: false),
  ]
