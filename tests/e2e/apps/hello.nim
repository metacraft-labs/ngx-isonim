## hello.nim
##
## Simple SSR test app: returns a static HTML page.
## Used for E2E testing of the nginx module.

proc renderHelloApp*(): string =
  ## Returns a simple HTML page for testing.
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
