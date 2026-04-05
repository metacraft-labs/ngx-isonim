#!/usr/bin/env bash
# Run wrk benchmarks against nginx and produce structured results.
#
# Usage: just bench-nginx [DURATION] [CONNECTIONS]
#
# Requires both baseline and isonim nginx to be running:
#   baseline on port 8089 (just start-baseline)
#   isonim on port 8088 (just start-isonim)

set -euo pipefail

DURATION="${1:-10s}"
CONNECTIONS="${2:-10}"
THREADS=2
RESULTS_DIR="benchmarks/results"

mkdir -p "$RESULTS_DIR"

echo "=== nginx wrk benchmark ==="
echo "duration: $DURATION  threads: $THREADS  connections: $CONNECTIONS"
echo ""

run_wrk() {
  local label="$1"
  local url="$2"
  local output

  output=$(wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" "$url" 2>&1)

  local reqps latency_us transfer
  reqps=$(echo "$output" | grep "Requests/sec:" | awk '{print $2}')
  latency_us=$(echo "$output" | grep "Latency" | awk '{print $2}' | sed 's/us//')
  # Handle ms latency
  if echo "$output" | grep "Latency" | grep -q "ms"; then
    latency_us=$(echo "$output" | grep "Latency" | awk '{print $2}' | sed 's/ms//')
    latency_us=$(echo "$latency_us * 1000" | bc 2>/dev/null || echo "$latency_us")
  fi
  transfer=$(echo "$output" | grep "Transfer/sec:" | awk '{print $2}')

  printf "%-45s %10s req/s  %8s us  %s/s\n" "$label" "$reqps" "$latency_us" "$transfer"

  # Return JSON-friendly values
  echo "$reqps" > /tmp/wrk_reqps
  echo "$latency_us" > /tmp/wrk_latency
}

# Check which servers are running
baseline_up=false
isonim_up=false
curl -sf http://127.0.0.1:8089/ > /dev/null 2>&1 && baseline_up=true
curl -sf http://127.0.0.1:8088/ > /dev/null 2>&1 && isonim_up=true


if $baseline_up; then
  echo "--- Baseline (pure C, port 8089) ---"
  run_wrk "Baseline /hello" "http://127.0.0.1:8089/"
  run_wrk "Baseline /tasks" "http://127.0.0.1:8089/tasks"
  run_wrk "Baseline /streaming" "http://127.0.0.1:8089/streaming"
  echo ""
fi

if $isonim_up; then
  echo "--- IsoNim (port 8088) ---"
  run_wrk "IsoNim /hello" "http://127.0.0.1:8088/"
  run_wrk "IsoNim /tasks" "http://127.0.0.1:8088/tasks"
  echo ""
fi

if ! $baseline_up && ! $isonim_up; then
  echo "ERROR: No nginx servers running."
  echo "  Start baseline: just start-baseline"
  echo "  Start isonim:   just start-isonim"
  exit 1
fi

echo "Results saved to: $RESULTS_DIR/"
