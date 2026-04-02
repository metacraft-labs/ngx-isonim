## async_app.nim
##
## Simulates an app with Suspense boundaries for streaming SSR.
## The shell is emitted immediately for fast TTFB, then each
## boundary resolves and sends a replacement script chunk.

proc asyncStreamingApp*(onChunk: proc(chunk: string), onComplete: proc()) =
  ## Streaming app that simulates a dashboard with Suspense boundaries.
  ## Shell (immediate TTFB)
  onChunk("""<html><body><h1>Dashboard</h1><div id="data">Loading...</div>""")
  ## Suspense boundary 1 resolves
  onChunk("""<script>document.getElementById('data').innerHTML='<p>Data loaded: 42 items</p>';</script>""")
  ## Suspense boundary 2 resolves
  onChunk("""<script>document.body.insertAdjacentHTML('beforeend','<footer>Loaded at server time</footer>');</script>""")
  onChunk("</body></html>")
  onComplete()
