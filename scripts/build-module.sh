#!/usr/bin/env bash
#
# Builds ngx_http_isonim_module.so, the dynamic module nginx loads.
#
# This is the one place the module's compile and link steps are written down.
# The Nix derivation (nix/ngx-isonim-module.nix) runs it, and so do the
# end-to-end tests, which need a debug build that Nix does not produce by
# default.
#
# Usage:
#   scripts/build-module.sh <release|debug> <output.so> [extra nim args...]
#
# An application is compiled in with -d:ngxIsonimAppModule=<absolute path of
# a .nim file exporting registerApps()> (src/apps.nim); its directory's
# siblings resolve as usual, and the module's own sources (app_registry,
# ssr_router, ...) are importable by name.
#
# Environment:
#   NGX_DEV_HEADERS   configured nginx headers (set by the dev shell and by
#                     nix/nginx-dev-headers.nix). Required.
#   NGX_ISONIM_PATHS  colon-separated Nim --path roots for faststreams, stew,
#                     isonim/src and nim-everywhere/src. Defaults to the
#                     sibling checkouts of the workspace.
#   NGX_ISONIM_NIMCACHE  intermediate directory. Defaults to
#                     .nimcache/module-<mode> inside the checkout.
#   NGX_ISONIM_EXTRA_LDFLAGS  extra flags for the final link (the Darwin
#                     derivation passes -Wl,-undefined,dynamic_lookup).
#   NGX_ISONIM_EXTRA_CFLAGS  extra flags for every C compile, the module's
#                     and Nim's (`just test-e2e-asan` passes
#                     -fsanitize=address).
#
# Modes:
#   release  -d:release -d:danger --opt:speed, C at -O2 (what production runs)
#   debug    Nim's default debug build: runtime checks, stack traces and line
#            directives on; C at -O0 -g.  The streaming handler must work here
#            too (tests/e2e/test_streaming_debug.sh).

set -euo pipefail

MODE="${1:?usage: build-module.sh <release|debug> <output.so> [nim args...]}"
OUT="${2:?usage: build-module.sh <release|debug> <output.so> [nim args...]}"
shift 2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${NGX_DEV_HEADERS:?NGX_DEV_HEADERS must point at the configured nginx headers}"

DEFAULT_PATHS="${ROOT}/../nim-faststreams:${ROOT}/../nim-stew:${ROOT}/../isonim/src:${ROOT}/../nim-everywhere/src"
IFS=':' read -r -a NIM_PATHS <<<"${NGX_ISONIM_PATHS:-${DEFAULT_PATHS}}"

NIMCACHE="${NGX_ISONIM_NIMCACHE:-${ROOT}/.nimcache/module-${MODE}}"

case "${MODE}" in
release)
  NIM_MODE_FLAGS=(-d:release -d:danger --opt:speed)
  CC_MODE_FLAGS=(-O2)
  ;;
debug)
  NIM_MODE_FLAGS=(--debugger:native)
  CC_MODE_FLAGS=(-O0 -g -U_FORTIFY_SOURCE)
  ;;
*)
  echo "build-module.sh: unknown mode '${MODE}' (expected release or debug)" >&2
  exit 2
  ;;
esac

# nginx headers are spread over src/{core,event,http,os}/... with nested
# directories (event/quic, http/v2, http/v3, ...).  Every directory holding a
# header goes on the include path.
NGX_INCLUDES=()
NGX_NIM_PASSC=()
while IFS= read -r dir; do
  NGX_INCLUDES+=("-I${dir}")
  NGX_NIM_PASSC+=("--passC:-I${dir}")
done < <(find "${NGX_DEV_HEADERS}/include/nginx" -type f -name '*.h' -printf '%h\n' | sort -u)

# The module's own sources are on the path too, so that an application
# module compiled in with -d:ngxIsonimAppModule=<file> can import them by
# name (app_registry, ssr_router; see src/apps.nim).
NIM_PATH_FLAGS=("--path:${ROOT}/src")
for p in "${NIM_PATHS[@]}"; do
  NIM_PATH_FLAGS+=("--path:${p}")
done

EXTRA_LD=()
if [ -n "${NGX_ISONIM_EXTRA_LDFLAGS:-}" ]; then
  # shellcheck disable=SC2206 # deliberately split into separate flags
  EXTRA_LD=(${NGX_ISONIM_EXTRA_LDFLAGS})
fi
NIM_EXTRA_PASSL=()
for f in "${EXTRA_LD[@]}"; do
  NIM_EXTRA_PASSL+=("--passL:${f}")
done
EXTRA_CC=()
if [ -n "${NGX_ISONIM_EXTRA_CFLAGS:-}" ]; then
  # shellcheck disable=SC2206 # deliberately split into separate flags
  EXTRA_CC=(${NGX_ISONIM_EXTRA_CFLAGS})
fi
NIM_EXTRA_PASSC=()
for f in "${EXTRA_CC[@]}"; do
  NIM_EXTRA_PASSC+=("--passC:${f}")
done

rm -rf "${NIMCACHE}"
mkdir -p "${NIMCACHE}" "$(dirname "${OUT}")"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# 1. The Nim side (handler.nim and everything it imports) to C objects.
#    --noMain --app:lib: no main(); NimMain is called from nim_module_init.
#    --mm:orc: deterministic deallocation for long-lived workers.
#    The asyncBackend/isServer/useFaststreams defines repeat nim.cfg so a
#    copy of src/ without it (tests/e2e/harness.nim mutants) builds the same.
nim c \
  --mm:orc \
  --noMain \
  --app:lib \
  "${NIM_MODE_FLAGS[@]}" \
  --nimcache:"${NIMCACHE}" \
  -d:asyncBackend=nginx \
  -d:isServer \
  -d:useFaststreams \
  "${NIM_PATH_FLAGS[@]}" \
  --passC:-fPIC \
  "${NIM_EXTRA_PASSC[@]}" \
  "${NIM_EXTRA_PASSL[@]}" \
  "${NGX_NIM_PASSC[@]}" \
  -o:"${WORK}/nim-side.so" \
  "$@" \
  "${ROOT}/src/handler.nim"

# 2. The C module definition (directives, handlers, postconfiguration).
cc -c -fPIC "${CC_MODE_FLAGS[@]}" "${EXTRA_CC[@]}" -Wall -Werror=implicit-function-declaration \
  "${NGX_INCLUDES[@]}" \
  -o "${WORK}/ngx_http_isonim_module.o" \
  "${ROOT}/src/ngx_http_isonim_module.c"

# 3. One shared object.  nginx symbols stay undefined and are resolved
#    against the nginx executable at load_module time.
cc -shared "${CC_MODE_FLAGS[@]}" "${EXTRA_LD[@]}" -o "${OUT}" \
  "${WORK}/ngx_http_isonim_module.o" \
  "${NIMCACHE}"/*.o \
  -lpcre2-8 -lssl -lcrypto -lz

echo "built ${OUT} (${MODE})"
