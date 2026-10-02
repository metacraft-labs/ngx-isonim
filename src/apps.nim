## apps.nim
##
## The apps compiled into the production module.  `registerDefaultApps`
## runs once per worker, from `nim_module_init`.
##
## Built with `-d:ngxIsonimTestApps`, the module also registers the apps the
## end-to-end tests drive (tests/e2e/apps/e2e_apps.nim).
##
## Built with `-d:ngxIsonimAppModule=<path to a .nim file>`, the module
## compiles that application module in and calls its exported
## `registerApps()` (after the built-in apps): this is how an application
## (its renderers, async apps, route manifest, server functions and
## `serverHooks`) gets into the module without editing it.  For example
## `scripts/build-module.sh release out.so -d:ngxIsonimAppModule=$PWD/app.nim`.
##
## Not compiled in mock mode (`-d:isNginxTest`): the unit tests register
## their own apps.

when not defined(isNginxTest):
  import app_registry

  # IsoNim reactive core and SSR
  import isonim/core/signals
  import isonim/core/computation
  import isonim/ssr/renderer
  import isonim/ssr/escape
  import isonim/dsl/ui

  when defined(ngxIsonimTestApps):
    import ../tests/e2e/apps/e2e_apps

  const ngxIsonimAppModule {.strdefine.} = ""
    ## An application module compiled into the module (see above).

  when ngxIsonimAppModule.len > 0:
    import std/macros

    macro importAppModule(): untyped =
      nnkImportStmt.newTree(nnkInfix.newTree(ident"as",
        newLit(ngxIsonimAppModule), ident"applicationModule"))

    importAppModule()

  type
    Task = object
      id: int
      text: string
      done: bool

  proc renderTaskApp(tasks: seq[Task]): string =
    ## Renders the task manager app to an HTML string using the IsoNim
    ## reactive core, DSL, and SSR renderer.
    renderToString do () -> string:
      var taskSignal = createSignal(tasks)

      let activeCount = createMemo do () -> int:
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

  proc defaultTasks(): seq[Task] =
    @[
      Task(id: 1, text: "Learn IsoNim reactive framework", done: true),
      Task(id: 2, text: "Build nginx SSR module", done: true),
      Task(id: 3, text: "Write E2E tests", done: false),
      Task(id: 4, text: "Deploy to production", done: false),
      Task(id: 5, text: "Celebrate!", done: false),
    ]

  proc registerDefaultApps*() =
    ## Registers the apps of the production module.

    # Simple hello app (no IsoNim dependency)
    registerApp("hello", proc(): string =
      "<html><body><h1>Hello from IsoNim</h1></body></html>"
    )

    # Real IsoNim SSR task manager app — renders on every request.
    registerApp("tasks", proc(): string =
      renderTaskApp(defaultTasks())
    )

    when defined(ngxIsonimTestApps):
      registerE2eApps()

    when ngxIsonimAppModule.len > 0:
      applicationModule.registerApps()
