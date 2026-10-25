#!/usr/bin/env bash
#
# The shared-memory zone end-to-end tests (test_shm_zone.nim, without the
# mutants) against a module built with AddressSanitizer and
# UndefinedBehaviorSanitizer, nginx running with libasan preloaded (nginx
# itself is not instrumented; its allocations go through ASan's allocator,
# so a module or Nim access out of bounds of a heap object or to a freed
# one is reported).
#
# Covers every copy into and out of a zone (get, put, putIf, incr, the typed
# layer), the bounds on keys and on max_value, eviction, reloads that keep
# or replace a zone, and a worker killed inside the zone's lock.  The zone
# itself is mmap'd shared memory, which ASan does not track: the bounds
# there are the table's own (src/shm_table.nim), checked by these tests and
# by tests/test_shm_table.nim.
#
# Fails if ASan or UBSan reports anything.  Debug build with -d:useMalloc,
# so that Nim's own objects are malloc'd and visible to ASan too.
#
# Run in the dev shell: bash tests/e2e/test_shm_asan.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ngx-isonim-shm-asan.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

LIBASAN="$(cc -print-file-name=libasan.so)"
if [ ! -e "${LIBASAN}" ]; then
  echo "test_shm_asan.sh: the C compiler has no libasan.so" >&2
  exit 1
fi

MODULE="${ROOT}/build/e2e/asan-ubsan/ngx_http_isonim_module.so"
NGX_ISONIM_EXTRA_CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer" \
NGX_ISONIM_EXTRA_LDFLAGS="-fsanitize=address,undefined" \
NGX_ISONIM_NIMCACHE="${ROOT}/.nimcache/module-asan-ubsan" \
  bash "${ROOT}/scripts/build-module.sh" debug "${MODULE}" \
    -d:ngxIsonimTestApps -d:useMalloc >"${WORK}/build.log" 2>&1 ||
  { tail -40 "${WORK}/build.log"; exit 1; }

# Vacuity guard: the module really is instrumented with both sanitizers.
# (nm's output is captured first: `nm | grep -q` under pipefail fails when
# grep exits at the first match and nm then dies of SIGPIPE.)
DYNSYMS="$(nm -D "${MODULE}")"
for sym in __asan_init __ubsan_handle; do
  if ! grep -q "${sym}" <<<"${DYNSYMS}"; then
    echo "test_shm_asan.sh: the module has no ${sym}* symbol" >&2
    exit 1
  fi
done

# The harness starts `nginx` from PATH: this one preloads ASan.
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/nginx" <<WRAP
#!/usr/bin/env bash
export LD_PRELOAD="${LIBASAN}"
export ASAN_OPTIONS="detect_leaks=0:log_path=${WORK}/asan:verify_asan_link_order=0"
export UBSAN_OPTIONS="print_stacktrace=1:log_path=${WORK}/ubsan"
exec "$(command -v nginx)" "\$@"
WRAP
chmod +x "${WORK}/bin/nginx"
# Vacuity guard: the ASan runtime really initializes inside that nginx.
asan_help="$(LD_PRELOAD="${LIBASAN}" ASAN_OPTIONS=help=1 "$(command -v nginx)" -v 2>&1 || true)"
if [[ "${asan_help}" != *"Available flags for AddressSanitizer"* ]]; then
  echo "test_shm_asan.sh: ASan does not initialize in nginx" >&2
  exit 1
fi

nim c --hints:off -o:"${ROOT}/build/e2e/test_shm_asan" "${ROOT}/tests/e2e/test_shm_zone.nim" \
  >"${WORK}/test-build.log" 2>&1 || { tail -40 "${WORK}/test-build.log"; exit 1; }

PATH="${WORK}/bin:${PATH}" NGX_ISONIM_E2E_MODULE="${MODULE}" \
  "${ROOT}/build/e2e/test_shm_asan" \
    "every worker reads*" "a zone bound at registration*" \
    "putIf never loses*" "a full zone evicts*" "an unchanged reload*" "a reload that fails*" \
    "isonim_shm_zone is validated*" "the master releases*"

if find "${WORK}" -maxdepth 1 \( -name 'asan*' -o -name 'ubsan*' \) | grep -q .; then
  echo "A sanitizer reported:" >&2
  cat "${WORK}"/asan* "${WORK}"/ubsan* 2>/dev/null >&2
  exit 1
fi
echo "test_shm_asan.sh: no AddressSanitizer or UBSan reports"
