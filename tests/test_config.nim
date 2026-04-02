## test_config.nim
##
## Config parsing, directive parsing, merge, and validation tests.
## Compile with: nim c -r -d:isNginxTest tests/test_config.nim

import unittest
import ../src/config

suite "Config - Default":
  test "default_config_values":
    let conf = defaultLocConf()
    check not conf.enabled
    check not conf.enabledSet
    check conf.appName == ""
    check not conf.appNameSet
    check conf.maxBufferSize == 0
    check not conf.maxBufferSizeSet
    check conf.hydrationEnabled
    check not conf.hydrationSet
    check conf.scriptNonce == ""
    check not conf.scriptNonceSet

  test "default_config_is_valid":
    check defaultLocConf().isValid()


suite "Config - Parsing":
  test "parse_enabled_with_app":
    let conf = parseLocConf(
      enabled = true,
      appName = "my-app",
    )
    check conf.enabled
    check conf.appName == "my-app"
    check conf.hydrationEnabled  # default
    check conf.maxBufferSize == 0  # default
    check conf.scriptNonce == ""  # default

  test "parse_all_fields":
    let conf = parseLocConf(
      enabled = true,
      appName = "my-app",
      maxBufferSize = 1024 * 1024,
      hydrationEnabled = true,
      scriptNonce = "abc123",
    )
    check conf.enabled
    check conf.appName == "my-app"
    check conf.maxBufferSize == 1024 * 1024
    check conf.hydrationEnabled
    check conf.scriptNonce == "abc123"

  test "parse_disabled":
    let conf = parseLocConf(enabled = false)
    check not conf.enabled

  test "parse_hydration_disabled":
    let conf = parseLocConf(
      enabled = true,
      appName = "app",
      hydrationEnabled = false,
    )
    check not conf.hydrationEnabled


suite "Config - Validation":
  test "disabled_config_always_valid":
    let conf = parseLocConf(enabled = false, appName = "")
    check conf.isValid()

  test "enabled_without_app_name_invalid":
    let conf = parseLocConf(enabled = true, appName = "")
    check not conf.isValid()

  test "enabled_with_app_name_valid":
    let conf = parseLocConf(enabled = true, appName = "my-app")
    check conf.isValid()

  test "negative_buffer_size_invalid":
    let conf = parseLocConf(
      enabled = true,
      appName = "my-app",
      maxBufferSize = -1,
    )
    check not conf.isValid()

  test "zero_buffer_size_valid":
    let conf = parseLocConf(
      enabled = true,
      appName = "my-app",
      maxBufferSize = 0,
    )
    check conf.isValid()

  test "positive_buffer_size_valid":
    let conf = parseLocConf(
      enabled = true,
      appName = "my-app",
      maxBufferSize = 4096,
    )
    check conf.isValid()


suite "Config - Directive Parsing (individual directives)":
  test "parse_flag_on":
    check parseFlagDirective("on") == true

  test "parse_flag_off":
    check parseFlagDirective("off") == false

  test "parse_flag_invalid":
    expect ConfigError:
      discard parseFlagDirective("yes")

  test "parse_flag_empty":
    expect ConfigError:
      discard parseFlagDirective("")

  test "parse_string_valid":
    check parseStringDirective("my-app") == "my-app"

  test "parse_string_empty_raises":
    expect ConfigError:
      discard parseStringDirective("")

  test "parse_size_valid":
    check parseSizeDirective("4096") == 4096

  test "parse_size_zero":
    check parseSizeDirective("0") == 0

  test "parse_size_negative_raises":
    expect ConfigError:
      discard parseSizeDirective("-1")

  test "parse_size_non_numeric_raises":
    expect ConfigError:
      discard parseSizeDirective("abc")

  test "parse_size_large":
    check parseSizeDirective("1048576") == 1048576


suite "Config - Directive Parsing (parseDirective + applyDirective)":
  test "parse_and_apply_isonim_ssr_on":
    let dv = parseDirective(dkSsr, "on")
    check dv.kind == dkSsr
    check dv.value == "on"
    var conf = defaultLocConf()
    applyDirective(conf, dv)
    check conf.enabled == true
    check conf.enabledSet == true

  test "parse_and_apply_isonim_ssr_off":
    let dv = parseDirective(dkSsr, "off")
    var conf = defaultLocConf()
    applyDirective(conf, dv)
    check conf.enabled == false
    check conf.enabledSet == true

  test "parse_and_apply_isonim_ssr_app":
    let dv = parseDirective(dkSsrApp, "my-app")
    var conf = defaultLocConf()
    applyDirective(conf, dv)
    check conf.appName == "my-app"
    check conf.appNameSet == true

  test "parse_and_apply_isonim_ssr_hydration":
    let dv = parseDirective(dkSsrHydration, "off")
    var conf = defaultLocConf()
    applyDirective(conf, dv)
    check conf.hydrationEnabled == false
    check conf.hydrationSet == true

  test "parse_and_apply_isonim_ssr_script_nonce":
    let dv = parseDirective(dkSsrScriptNonce, "abc123")
    var conf = defaultLocConf()
    applyDirective(conf, dv)
    check conf.scriptNonce == "abc123"
    check conf.scriptNonceSet == true

  test "parse_and_apply_isonim_ssr_max_buffer_size":
    let dv = parseDirective(dkSsrMaxBufSize, "8192")
    var conf = defaultLocConf()
    applyDirective(conf, dv)
    check conf.maxBufferSize == 8192
    check conf.maxBufferSizeSet == true

  test "invalid_flag_directive_raises":
    expect ConfigError:
      discard parseDirective(dkSsr, "maybe")

  test "invalid_size_directive_raises":
    expect ConfigError:
      discard parseDirective(dkSsrMaxBufSize, "notanumber")


suite "Config - Merge":
  test "child_overrides_parent_enabled":
    let parent = parseLocConf(enabled = true, appName = "parent-app")
    let child = parseLocConf(enabled = false, appName = "child-app")
    let merged = mergeLocConf(parent, child)
    check merged.enabled == false
    check merged.appName == "child-app"

  test "unset_child_inherits_from_parent":
    let parent = parseLocConf(
      enabled = true,
      appName = "parent-app",
      hydrationEnabled = false,
      scriptNonce = "parent-nonce",
      maxBufferSize = 2048,
    )
    let child = defaultLocConf()  # all unset
    let merged = mergeLocConf(parent, child)
    check merged.enabled == true
    check merged.appName == "parent-app"
    check merged.hydrationEnabled == false
    check merged.scriptNonce == "parent-nonce"
    check merged.maxBufferSize == 2048

  test "child_partial_override":
    let parent = parseLocConf(
      enabled = true,
      appName = "parent-app",
      hydrationEnabled = true,
      scriptNonce = "parent-nonce",
      maxBufferSize = 1024,
    )
    # Child only sets appName
    var child = defaultLocConf()
    child.appName = "child-app"
    child.appNameSet = true
    let merged = mergeLocConf(parent, child)
    check merged.appName == "child-app"
    check merged.enabled == true        # inherited
    check merged.hydrationEnabled == true  # inherited
    check merged.scriptNonce == "parent-nonce"  # inherited
    check merged.maxBufferSize == 1024   # inherited

  test "both_unset_uses_defaults":
    let parent = defaultLocConf()
    let child = defaultLocConf()
    let merged = mergeLocConf(parent, child)
    check merged.enabled == false
    check merged.appName == ""
    check merged.hydrationEnabled == true  # default
    check merged.maxBufferSize == 0
    check merged.scriptNonce == ""

  test "merge_preserves_set_flags":
    let parent = parseLocConf(enabled = true, appName = "app")
    let child = defaultLocConf()
    let merged = mergeLocConf(parent, child)
    check merged.enabledSet == true  # inherited from parent
    check merged.appNameSet == true
