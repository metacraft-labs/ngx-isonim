## async_loop.nim
##
## Nim's event loop (std/asyncdispatch) inside the nginx worker's.
##
## An nginx worker is one thread running nginx's event loop; IsoNim server
## functions and async apps are `{.async.}` procs whose futures are
## completed by asyncdispatch's dispatcher.  The worker never blocks in
## that dispatcher.  Instead nginx drives it:
##
## * the dispatcher's selector is an epoll descriptor, readable whenever a
##   descriptor registered with it (an AsyncSocket, ...) is ready.  The
##   module watches it as a level-triggered read event
##   (`ngx_http_isonim_async_watch_fd`);
## * one nginx timer is armed for the dispatcher's next due timer
##   (`sleepAsync`, `withTimeout`) or, when callbacks are queued, for the
##   next turn (`ngx_http_isonim_async_arm`);
## * either event, and every entry from nginx that may have completed or
##   started a future (`nim_handle_rpc`, the rpc timeout), runs `pump`:
##   `poll(0)` until nothing is due, then re-arms the timer.
##
## `poll(0)` never waits (a zero timeout to epoll_wait), so the worker is
## never held up by Nim; and a pending future costs nothing but its memory.

when defined(isNginxTest):
  {.error: "async_loop.nim is the nginx integration; mock tests drive " &
    "asyncdispatch with poll/waitFor directly".}

import std/[asyncdispatch, heapqueue, deques, monotimes, times, selectors]
import nginx_types

const maxRoundsPerPump = 64
  ## Bounds one pump, so a callback that keeps scheduling callbacks cannot
  ## starve nginx; what is left runs on the next turn.

proc logCycle(level: NgxUint; msg: string) =
  if msg.len > 0:
    ngx_http_isonim_log_cycle(level, unsafeAddr msg[0], csize_t(msg.len))

proc startAsyncLoop*() =
  ## Hooks the dispatcher's descriptor into the worker's event loop.  Called
  ## once per worker (nim_module_init).
  let fd = getGlobalDispatcher().getIoHandler().getFd()
  if ngx_http_isonim_async_watch_fd(NgxInt(fd)) != NGX_OK:
    logCycle(NGX_LOG_ERR, "cannot watch the asyncdispatch selector (fd " &
      $fd & "); only timer-driven futures will complete")

proc due(p: PDispatcher): bool =
  p.callbacks.len > 0 or
    (p.timers.len > 0 and p.timers[0].finishAt <= getMonoTime())

proc pump*() =
  ## Runs what is ready, then arms the timer for what is not.
  let p = getGlobalDispatcher()
  var rounds = 0
  while hasPendingOperations() and rounds < maxRoundsPerPump:
    try:
      poll(0)
    except CatchableError as e:
      # A callback raised (e.g. asyncCheck of a failed future).  The
      # request it belonged to answers for itself; log and go on.
      logCycle(NGX_LOG_ERR, "event loop callback raised " & $e.name & ": " &
        e.msg)
    inc rounds
    if not p.due:
      break
  if p.callbacks.len > 0:
    ngx_http_isonim_async_arm(0)
  elif p.timers.len > 0:
    let ms = (p.timers[0].finishAt - getMonoTime()).inMilliseconds
    ngx_http_isonim_async_arm(NgxInt(max(ms + 1, 1)))
  else:
    ngx_http_isonim_async_arm(-1)

proc nimAsyncPump*() {.exportc: "nim_async_pump", cdecl.} =
  ## Called from C: the loop's timer or descriptor fired.
  try:
    pump()
  except Exception as e:
    logCycle(NGX_LOG_ERR, "unhandled " & $e.name & " in the event loop: " & e.msg)
