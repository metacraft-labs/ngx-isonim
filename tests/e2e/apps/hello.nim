## hello.nim
##
## Simple SSR test apps: return static HTML pages.
## Used for E2E and unit testing of the nginx module.

proc helloApp*(): string =
  ## Returns a simple hello page for testing.
  "<html><body><h1>Hello from IsoNim</h1></body></html>"

proc taskManagerApp*(): string =
  ## Returns a task manager page for testing multiple apps.
  "<html><body><h1>Task Manager</h1><ul><li>Task 1</li></ul></body></html>"

proc renderHelloApp*(): string =
  ## Legacy E2E test app: returns a full HTML page.
  result = """<!DOCTYPE html>
<html>
<head><title>Hello from IsoNim</title></head>
<body>
  <div id="app">
    <h1>Hello from IsoNim</h1>
    <p>This page was server-rendered by the ngx-isonim nginx module.</p>
  </div>
</body>
</html>"""
