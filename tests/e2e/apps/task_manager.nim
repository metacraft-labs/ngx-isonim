## task_manager.nim
##
## Task list app with multiple items.
## No IsoNim dependency — uses plain Nim for testing.

proc taskManagerDetailApp*(tasks: seq[string] = @["Task 1", "Task 2", "Task 3"]): string =
  ## Returns an HTML page displaying the given task list.
  var html = "<html><body><h1>Task Manager</h1><ul>"
  for task in tasks:
    html &= "<li>" & task & "</li>"
  html &= "</ul><p>" & $tasks.len & " items</p></body></html>"
  result = html
