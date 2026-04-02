## hello.nim
##
## Simple SSR test app: returns static HTML pages.
## Used for E2E and unit testing of the nginx module.

proc helloApp*(): string =
  ## Returns a simple hello page for testing.
  "<html><body><h1>Hello from IsoNim</h1></body></html>"

proc helloStreamingApp*(onChunk: proc(chunk: string), onComplete: proc()) =
  ## Streaming version of the hello app — emits the page in one chunk.
  onChunk("<html><body><h1>Hello from IsoNim</h1></body></html>")
  onComplete()

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
