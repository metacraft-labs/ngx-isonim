## counter.nim
##
## Counter app that demonstrates signal-driven state rendering.
## No IsoNim dependency — uses plain Nim for testing.

proc counterApp*(count: int = 0): string =
  ## Returns an HTML page displaying the given count.
  "<html><body><h1>Count: " & $count & "</h1><button>+1</button></body></html>"
