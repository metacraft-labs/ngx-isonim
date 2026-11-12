## response.nim
##
## How a renderer shapes the response: IsoNim's `SsrResponse`
## (isonim/server/response.nim), shared with server functions and the route
## manifest's dispatch.  The transport (serve.nim, rpc.nim) sends what it
## holds before the first body byte and then marks it committed.

import isonim/server/response
export response
