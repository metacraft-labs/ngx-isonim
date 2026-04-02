## test_config.nim
##
## Config parsing and validation tests.
## Compile with: nim c -r -d:isNginxTest tests/test_config.nim

import unittest
import ../src/config

suite "Config - Default":
  test "default_config_values":
    let conf = defaultLocConf()
    check not conf.enabled
    check conf.appName == ""
    check conf.maxBufferSize == 0
    check conf.hydrationEnabled
    check conf.scriptNonce == ""

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
