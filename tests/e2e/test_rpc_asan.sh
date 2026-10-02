#!/usr/bin/env bash
#
# The isonim_rpc end-to-end tests (test_rpc.nim) against a module built with
# AddressSanitizer, nginx running with libasan preloaded (nginx itself is not
# instrumented; its allocations, request pools included, go through ASan's
# allocator, so a module or Nim access to a freed pool or a freed Nim object
# is reported).
#
# Covers the paths that finalize a request from inside Nim: the 504 of
# isonim_rpc_timeout (nim_rpc_timeout finalizes the request, which destroys
# its pool and runs nim_rpc_released while the timeout is still on the
# stack), a client that goes away mid-handler, 413 while reading, 500, and
# the plain round trip.  Fails if ASan reports anything.  The falsifying
# mutations of test_rpc.nim are not run here (they build release modules).
#
# Debug build with -d:useMalloc, so that Nim's own objects are malloc'd and
# their use after free is visible too.
#
# Run in the dev shell: bash tests/e2e/test_rpc_asan.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ngx-isonim-asan.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

LIBASAN="$(cc -print-file-name=libasan.so)"
if [ ! -e "${LIBASAN}" ]; then
  echo "test_rpc_asan.sh: the C compiler has no libasan.so" >&2
  exit 1
fi

MODULE="${ROOT}/build/e2e/asan/ngx_http_isonim_module.so"
NGX_ISONIM_EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer" \
NGX_ISONIM_EXTRA_LDFLAGS="-fsanitize=address" \
NGX_ISONIM_NIMCACHE="${ROOT}/.nimcache/module-asan" \
  bash "${ROOT}/scripts/build-module.sh" debug "${MODULE}" \
    -d:ngxIsonimTestApps -d:useMalloc >"${WORK}/build.log" 2>&1 ||
  { tail -40 "${WORK}/build.log"; exit 1; }

# The harness starts `nginx` from PATH: this one preloads ASan.
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/nginx" <<EOF
#!/usr/bin/env bash
export LD_PRELOAD="${LIBASAN}"
export ASAN_OPTIONS="detect_leaks=0:log_path=${WORK}/asan:verify_asan_link_order=0"
exec "$(command -v nginx)" "\$@"
EOF
chmod +x "${WORK}/bin/nginx"
# Vacuity guard: the ASan runtime really initializes inside that nginx.
asan_help="$(LD_PRELOAD="${LIBASAN}" ASAN_OPTIONS=help=1 "$(command -v nginx)" -v 2>&1 || true)"
if [[ "${asan_help}" != *"Available flags for AddressSanitizer"* ]]; then
  echo "test_rpc_asan.sh: ASan does not initialize in nginx" >&2
  exit 1
fi

nim c --hints:off -o:"${ROOT}/build/e2e/test_rpc_asan" "${ROOT}/tests/e2e/test_rpc.nim" \
  >"${WORK}/test-build.log" 2>&1 || { tail -40 "${WORK}/test-build.log"; exit 1; }

PATH="${WORK}/bin:${PATH}" NGX_ISONIM_E2E_MODULE="${MODULE}" \
  "${ROOT}/build/e2e/test_rpc_asan" \
    "a server function call*" "a 1 MiB*" "a body over*" "a chunked body*" \
    "a raising*" "isonim_rpc_timeout*" "a client that goes away*" \
    "an async app*" "a slow server*" "nginx stops*"

if find "${WORK}" -maxdepth 1 -name 'asan*' | grep -q .; then
  echo "AddressSanitizer reported:" >&2
  cat "${WORK}"/asan* >&2
  exit 1
fi
echo "test_rpc_asan.sh: no AddressSanitizer reports"
