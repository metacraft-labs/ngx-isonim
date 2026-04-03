#!/usr/bin/env bash
# Collects ngx-isonim performance metrics for CI benchmark tracking.
# Output format: JSON array compatible with github-action-benchmark.
#
# Metrics:
#   - Module .so size (customSmallerIsBetter)
#   - Response sizes for /hello and /tasks endpoints (customSmallerIsBetter)
#
# Usage:
#   ./scripts/collect-metrics.sh              # All metrics
#   ./scripts/collect-metrics.sh --module     # Module size only
#   ./scripts/collect-metrics.sh --responses  # Response sizes only

set -euo pipefail

MODE="${1:---all}"

# Format bytes to human-readable string.
format_bytes() {
  local bytes=$1
  local unit_divisor=1
  local unit_suffix="B"
  local tenths=0

  if ((bytes >= 1073741824)); then
    unit_divisor=1073741824
    unit_suffix="GB"
  elif ((bytes >= 1048576)); then
    unit_divisor=1048576
    unit_suffix="MB"
  elif ((bytes >= 1024)); then
    unit_divisor=1024
    unit_suffix="KB"
  else
    printf "%d B" "$bytes"
    return
  fi

  tenths=$(((bytes * 10 + (unit_divisor / 2)) / unit_divisor))
  printf "%d.%d %s" "$((tenths / 10))" "$((tenths % 10))" "$unit_suffix"
}

# Output a single metric in JSON format.
# Args: name, value, unit, extra, is_first
output_metric() {
  local name=$1
  local value=$2
  local unit=$3
  local extra=$4
  local is_first=$5

  if [[ "$is_first" != "true" ]]; then
    printf ",\n"
  fi

  printf '  {\n'
  printf '    "name": "%s",\n' "$name"
  printf '    "unit": "%s",\n' "$unit"
  printf '    "value": %s,\n' "$value"
  printf '    "extra": "%s"\n' "$extra"
  printf '  }'
}

# Get file size in bytes (cross-platform).
get_file_size() {
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "0"
    return
  fi
  stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo "0"
}

collect_module_size() {
  local is_first="true"
  local module_so=""

  echo "["

  # Try Nix build result first, then common build output locations
  if [[ -f "result/lib/ngx_http_isonim_module.so" ]]; then
    module_so="result/lib/ngx_http_isonim_module.so"
  elif [[ -n "${NGX_ISONIM_MODULE:-}" ]] && [[ -f "$NGX_ISONIM_MODULE" ]]; then
    module_so="$NGX_ISONIM_MODULE"
  elif [[ -f "ngx_http_isonim_module.so" ]]; then
    module_so="ngx_http_isonim_module.so"
  fi

  if [[ -n "$module_so" ]]; then
    local size
    size=$(get_file_size "$module_so")
    local human
    human=$(format_bytes "$size")
    output_metric "ngx-isonim-module-size" "$size" "bytes" "$human (ngx_http_isonim_module.so)" "$is_first"
    is_first="false"
  else
    echo "Warning: Module .so not found. Run 'nix build' first." >&2
  fi

  echo ""
  echo "]"
}

collect_response_sizes() {
  local is_first="true"
  local base_url="${NGX_ISONIM_URL:-http://localhost:8088}"

  echo "["

  # Measure /hello response size
  local hello_size
  hello_size=$(curl -s -o /dev/null -w '%{size_download}' "$base_url/hello" 2>/dev/null || echo "0")
  if [[ "$hello_size" -gt 0 ]]; then
    local human
    human=$(format_bytes "$hello_size")
    output_metric "ngx-isonim-response-hello" "$hello_size" "bytes" "$human (/hello SSR response)" "$is_first"
    is_first="false"
  else
    echo "Warning: Could not fetch /hello from $base_url. Is nginx running?" >&2
  fi

  # Measure /tasks response size
  local tasks_size
  tasks_size=$(curl -s -o /dev/null -w '%{size_download}' "$base_url/tasks" 2>/dev/null || echo "0")
  if [[ "$tasks_size" -gt 0 ]]; then
    local human
    human=$(format_bytes "$tasks_size")
    output_metric "ngx-isonim-response-tasks" "$tasks_size" "bytes" "$human (/tasks SSR response)" "$is_first"
    is_first="false"
  else
    echo "Warning: Could not fetch /tasks from $base_url. Is nginx running?" >&2
  fi

  echo ""
  echo "]"
}

case "$MODE" in
  --module)
    collect_module_size
    ;;
  --responses)
    collect_response_sizes
    ;;
  --all)
    module_json=$(collect_module_size 2>/dev/null)
    response_json=$(collect_response_sizes 2>/dev/null)

    module_inner=$(echo "$module_json" | sed '1d;$d')
    response_inner=$(echo "$response_json" | sed '1d;$d')

    echo "["
    if [[ -n "$module_inner" ]] && [[ -n "$response_inner" ]]; then
      echo "$module_inner,"
      echo "$response_inner"
    elif [[ -n "$module_inner" ]]; then
      echo "$module_inner"
    elif [[ -n "$response_inner" ]]; then
      echo "$response_inner"
    fi
    echo "]"
    ;;
  --help|-h)
    echo "Usage: $0 [--module|--responses|--all]"
    exit 0
    ;;
  *)
    echo "Error: Unknown option: $MODE" >&2
    echo "Usage: $0 [--module|--responses|--all]" >&2
    exit 1
    ;;
esac
