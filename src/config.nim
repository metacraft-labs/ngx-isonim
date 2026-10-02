## config.nim
##
## Configuration directive parsing for the nginx IsoNim module.
## Handles `isonim_ssr` directives in nginx.conf to configure
## which routes are handled by the SSR module.
##
## The C module (ngx_http_isonim_module.c) uses nginx's built-in
## set handlers (ngx_conf_set_flag_slot, etc.) to populate its own
## ngx_http_isonim_loc_conf_t struct.  On the Nim side we mirror
## that struct as IsoNimLocConf and provide:
##
##   - defaultLocConf()  — NGX_CONF_UNSET-equivalent defaults
##   - parseLocConf()    — build a config from parsed directive values
##   - mergeLocConf()    — child-inherits-parent merge (same semantics
##                         as the C merge_loc_conf callback)
##   - parseDirective*() — parse individual directive value strings
##   - isValid()         — post-merge validation

import std/strutils

type
  DirectiveKind* = enum
    ## The five nginx directives that control the IsoNim module.
    dkSsr             ## isonim_ssr on|off
    dkSsrApp          ## isonim_ssr_app <name>
    dkSsrHydration    ## isonim_ssr_hydration on|off
    dkSsrMode         ## isonim_ssr_mode streaming|buffered
    dkSsrMaxBufSize   ## isonim_ssr_max_buffer_size <size>

  TransportMode* = enum
    ## How the response body travels (`isonim_ssr_mode`).
    tmStreaming = "streaming"
      ## Chunked; each renderer flush goes to the client at once.  Default.
    tmBuffered = "buffered"
      ## The whole body is rendered first and sent with Content-Length.

  DirectiveValue* = object
    ## A parsed directive: its kind and the raw string value from nginx.conf.
    kind*: DirectiveKind
    value*: string

  IsoNimLocConf* = object
    ## Per-location configuration for the IsoNim nginx module.
    ## Fields use Option-like sentinels: enabledSet / hydrationSet /
    ## maxBufferSizeSet track whether the value was explicitly provided
    ## so that mergeLocConf can decide whether to inherit from parent.
    enabled*: bool
    enabledSet*: bool
    appName*: string
    appNameSet*: bool
    ## Max response body size in bytes (0 = unlimited).
    maxBufferSize*: int
    maxBufferSizeSet*: bool
    ## Whether to include hydration script in SSR output.
    hydrationEnabled*: bool
    hydrationSet*: bool
    ## Streaming (default) or buffered transport.
    mode*: TransportMode
    modeSet*: bool

  ConfigError* = object of CatchableError
    ## Raised when a directive value cannot be parsed.

proc defaultLocConf*(): IsoNimLocConf =
  ## Returns the default per-location configuration.
  ## All *Set flags are false, meaning "not configured".
  ## Default values match the C merge_loc_conf defaults:
  ##   enabled = false, hydrationEnabled = true, maxBufferSize = 0,
  ##   mode = streaming.
  IsoNimLocConf(
    enabled: false,
    enabledSet: false,
    appName: "",
    appNameSet: false,
    maxBufferSize: 0,
    maxBufferSizeSet: false,
    hydrationEnabled: true,
    hydrationSet: false,
    mode: tmStreaming,
    modeSet: false,
  )

proc parseLocConf*(enabled: bool; appName: string = "";
    maxBufferSize: int = 0; hydrationEnabled: bool = true;
    mode: TransportMode = tmStreaming): IsoNimLocConf =
  ## Convenience constructor that sets all fields as "explicitly configured".
  ## This is the primary way tests and the handler build configs.
  IsoNimLocConf(
    enabled: enabled,
    enabledSet: true,
    appName: appName,
    appNameSet: appName.len > 0,
    maxBufferSize: maxBufferSize,
    maxBufferSizeSet: true,
    hydrationEnabled: hydrationEnabled,
    hydrationSet: true,
    mode: mode,
    modeSet: true,
  )

# ----------------------------------------------------------------
# Individual directive parsers
# ----------------------------------------------------------------

proc parseFlagDirective*(value: string): bool =
  ## Parse a flag directive value ("on"/"off").
  ## Raises ConfigError for invalid values.
  case value
  of "on":  true
  of "off": false
  else:
    raise newException(ConfigError,
      "invalid flag value: \"" & value & "\" (expected \"on\" or \"off\")")

proc parseStringDirective*(value: string): string =
  ## Parse a string directive value. Must not be empty.
  ## Raises ConfigError for empty strings.
  if value.len == 0:
    raise newException(ConfigError, "directive value must not be empty")
  value

proc parseSizeDirective*(value: string): int =
  ## Parse a size directive value: a non-negative integer of bytes,
  ## optionally with nginx's `k`/`K` (x1024) or `m`/`M` (x1048576) suffix,
  ## as `ngx_conf_set_size_slot` accepts it.
  ## Raises ConfigError for anything else.
  var digits = value
  var multiplier = 1
  if value.len > 0 and value[^1] in {'k', 'K', 'm', 'M'}:
    multiplier = if value[^1] in {'k', 'K'}: 1024 else: 1024 * 1024
    digits = value[0 ..< ^1]
  var n: int
  try:
    n = parseInt(digits)
  except ValueError:
    raise newException(ConfigError,
      "invalid size value: \"" & value & "\" (expected a non-negative integer)")
  if n < 0:
    raise newException(ConfigError,
      "size must be non-negative, got: " & $n)
  if n > high(int) div multiplier:
    raise newException(ConfigError, "size too large: " & value)
  n * multiplier

proc parseModeDirective*(value: string): TransportMode =
  ## Parse `isonim_ssr_mode` ("streaming" or "buffered").
  case value
  of "streaming": tmStreaming
  of "buffered": tmBuffered
  else:
    raise newException(ConfigError,
      "invalid isonim_ssr_mode: \"" & value &
      "\" (expected \"streaming\" or \"buffered\")")

proc parseDirective*(kind: DirectiveKind; value: string): DirectiveValue =
  ## Parse a directive of the given kind.  Validates the value format
  ## and returns a DirectiveValue.  Raises ConfigError on invalid input.
  case kind
  of dkSsr, dkSsrHydration:
    discard parseFlagDirective(value)  # validate
  of dkSsrApp:
    discard parseStringDirective(value)
  of dkSsrMode:
    discard parseModeDirective(value)
  of dkSsrMaxBufSize:
    discard parseSizeDirective(value)
  DirectiveValue(kind: kind, value: value)

proc applyDirective*(conf: var IsoNimLocConf; dv: DirectiveValue) =
  ## Apply a parsed directive to a configuration struct.
  case dv.kind
  of dkSsr:
    conf.enabled = parseFlagDirective(dv.value)
    conf.enabledSet = true
  of dkSsrApp:
    conf.appName = dv.value
    conf.appNameSet = true
  of dkSsrHydration:
    conf.hydrationEnabled = parseFlagDirective(dv.value)
    conf.hydrationSet = true
  of dkSsrMode:
    conf.mode = parseModeDirective(dv.value)
    conf.modeSet = true
  of dkSsrMaxBufSize:
    conf.maxBufferSize = parseSizeDirective(dv.value)
    conf.maxBufferSizeSet = true

# ----------------------------------------------------------------
# Merge (same semantics as the C merge_loc_conf)
# ----------------------------------------------------------------

proc mergeLocConf*(parent, child: IsoNimLocConf): IsoNimLocConf =
  ## Merge parent and child location configs.
  ## Child values override parent values.  Unset child fields inherit
  ## from parent.  If neither is set, the field keeps its default.
  result = child
  if not child.enabledSet:
    if parent.enabledSet:
      result.enabled = parent.enabled
      result.enabledSet = true
  if not child.appNameSet:
    if parent.appNameSet:
      result.appName = parent.appName
      result.appNameSet = true
  if not child.hydrationSet:
    if parent.hydrationSet:
      result.hydrationEnabled = parent.hydrationEnabled
      result.hydrationSet = true
  if not child.maxBufferSizeSet:
    if parent.maxBufferSizeSet:
      result.maxBufferSize = parent.maxBufferSize
      result.maxBufferSizeSet = true
  if not child.modeSet:
    if parent.modeSet:
      result.mode = parent.mode
      result.modeSet = true

proc isValid*(conf: IsoNimLocConf): bool =
  ## Validates the configuration.
  if not conf.enabled:
    return true  # Disabled config is always valid
  if conf.appName.len == 0:
    return false  # Must have an app name when enabled
  if conf.maxBufferSize < 0:
    return false
  return true
