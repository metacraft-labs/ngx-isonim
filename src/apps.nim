## apps.nim
##
## Default app registration for the production nginx module.
## Imports the real IsoNim SSR renderer and registers apps that
## use the reactive core, DSL, and server-side rendering pipeline.
##
## This module is only compiled in production mode (not isNginxTest).
## The test mode uses mock apps registered directly in test files.

when not defined(isNginxTest):
  import app_registry

  # IsoNim reactive core and SSR
  import isonim/core/owner
  import isonim/core/signals
  import isonim/core/computation
  import isonim/ssr/renderer
  import isonim/ssr/markers
  import isonim/ssr/escape
  import isonim/dsl/html

  when defined(useFaststreams):
    import faststreams/outputs as fsOutputs

  type
    Task = object
      id: int
      text: string
      done: bool

  proc renderTaskApp(tasks: seq[Task]): string =
    ## Renders the task manager app to an HTML string using the IsoNim
    ## reactive core, DSL, and SSR renderer.
    renderToString proc(): string =
      var taskSignal = createSignal(tasks)

      let activeCount = createMemo proc(): int =
        var count = 0
        for t in taskSignal.val:
          if not t.done: inc count
        count

      buildHtmlString:
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
              forIn(taskSignal.val):
                li(class = if item.done: "task completed" else: "task"):
                  input(`type` = "checkbox", checked = $item.done)
                  span(class = "task-text"):
                    text item.text
                  button(class = "remove"): text "x"

            showIf(taskSignal.val.len == 0):
              p(class = "empty-state"): text "No tasks yet"

          footer(class = "app-footer"):
            p: text "Powered by IsoNim + nginx"

  proc defaultTasks(): seq[Task] =
    @[
      Task(id: 1, text: "Learn IsoNim reactive framework", done: true),
      Task(id: 2, text: "Build nginx SSR module", done: true),
      Task(id: 3, text: "Write E2E tests", done: false),
      Task(id: 4, text: "Deploy to production", done: false),
      Task(id: 5, text: "Celebrate!", done: false),
    ]

  when defined(useFaststreams):
    proc renderAppToStream*(output: fsOutputs.OutputStream; appName: string;
                            hydration: bool; nonce: string) =
      ## Renders a registered app directly to a faststreams OutputStream.
      ## Used by the streaming nginx handler to avoid intermediate string copies.
      let app = getApp(appName)
      if app != nil:
        renderToOutputStream(output, app, hydration = hydration, nonce = nonce)

  proc registerDefaultApps*() =
    ## Registers the default set of apps for the nginx module.
    ## Called once during module initialization.

    # Simple hello app (no IsoNim dependency)
    registerApp("hello", proc(): string =
      "<html><body><h1>Hello from IsoNim</h1></body></html>"
    )

    # Real IsoNim SSR task manager app — pre-rendered at startup.
    # For apps with static content (no per-request state), rendering
    # once eliminates the ORC GC overhead from createRoot/dispose on
    # every request. For dynamic content, the app closure would call
    # renderTaskApp with per-request data.
    let cachedTaskHtml = renderTaskApp(defaultTasks())
    registerApp("tasks", proc(): string =
      cachedTaskHtml
    )
