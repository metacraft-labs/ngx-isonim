## request.nim
##
## The request object every renderer receives: IsoNim's `SsrRequest`
## (isonim/server/request.nim), which renderers, server functions and the
## route manifest's dispatch share.  `nim_handle_request` and
## `nim_handle_rpc` (handler.nim, rpc.nim) build it from nginx's parse of
## the request.

import isonim/server/request
export request
