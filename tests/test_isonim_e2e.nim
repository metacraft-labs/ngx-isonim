## test_isonim_e2e.nim
##
## E2E tests for the real IsoNim SSR task manager app.
## Verifies that the IsoNim reactive core, DSL, and SSR renderer
## produce correct HTML output with hydration markers.
##
## Compile with:
##   nim c -d:isServer --path:../isonim/src -r tests/test_isonim_e2e.nim

import unittest
import std/strutils
import e2e/apps/isonim_task_app

suite "IsoNim SSR E2E":
  test "renders task list with 5 items":
    let html = renderTaskApp(defaultTasks())
    check "IsoNim Task Manager" in html
    check "task-list" in html
    check "Learn IsoNim reactive framework" in html
    check "Deploy to production" in html
    check "3 active" in html  # 3 of 5 tasks are not done

  test "includes hydration script":
    let html = renderTaskAppWithHydration(defaultTasks())
    check "data-hk" in html  # Referenced in the hydration script
    check "_$HY" in html

  test "hydration script has CSP nonce":
    let html = renderTaskAppWithHydration(defaultTasks(), nonce = "test123")
    check "nonce=\"test123\"" in html

  test "empty task list shows empty state":
    let html = renderTaskApp(@[])
    check "No tasks yet" in html

  test "completed tasks have completed class":
    let html = renderTaskApp(defaultTasks())
    check "class=\"task completed\"" in html

  test "escapes HTML in task text":
    let tasks = @[Task(id: 1, text: "<script>alert('xss')</script>", done: false)]
    let html = renderTaskApp(tasks)
    check "&lt;script&gt;" in html
    check "<script>alert" notin html

  test "active tasks have task class without completed":
    let html = renderTaskApp(defaultTasks())
    check "class=\"task\"" in html

  test "renders subtitle with nginx SSR mention":
    let html = renderTaskApp(defaultTasks())
    check "Served by nginx + IsoNim SSR" in html

  test "renders footer":
    let html = renderTaskApp(defaultTasks())
    check "Powered by IsoNim + nginx" in html

  test "hydration script without nonce has no nonce attribute":
    let html = renderTaskAppWithHydration(defaultTasks())
    check "nonce=" notin html.split("_$HY")[0]  # No nonce before the hydration init
