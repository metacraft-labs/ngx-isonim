{
  stdenv,
  nim,
  nginxDevHeaders,
  pcre2,
  openssl,
  zlib,
  libxcrypt,
  faststreamsPath,
  stewPath,
  isOnimPath,
  nimEverywherePath,
}:

let
  # An nginx dynamic module is loaded BY the nginx executable and resolves
  # ngx_pcalloc / ngx_create_temp_buf / ngx_http_output_filter (and friends)
  # against it at load time -- they are deliberately absent from the module's
  # own link line.
  #
  # On ELF that is the default: a shared object may keep undefined symbols for
  # the loader to resolve.  Mach-O is the opposite -- every symbol must resolve
  # at link time unless the linker is told otherwise -- so on Darwin BOTH link
  # steps below (Nim's own `--app:lib` link, and the final `cc -shared`) fail
  # with "Undefined symbols for architecture arm64" naming exactly those nginx
  # entry points.  `-undefined dynamic_lookup` restores the ELF behaviour.
  #
  # Empty on Linux, so the Linux derivation is unchanged.
  undefinedDynamicLookup =
    if stdenv.isDarwin then "-Wl,-undefined,dynamic_lookup" else "";
in
stdenv.mkDerivation {
  pname = "ngx-isonim-module";
  version = "0.1.0";
  src = ./..;

  nativeBuildInputs = [ nim ];
  buildInputs = [
    nginxDevHeaders
    pcre2
    openssl
    zlib
    libxcrypt
  ];

  buildPhase = ''
    # Build -I flags for all nginx header subdirectories.
    # nginx headers are scattered across src/{core,event,http,os}/... with
    # nested subdirs (event/quic, http/v2, http/v3, etc.). Rather than
    # hard-coding each, find all directories containing .h files.
    NGX_INCLUDES=""
    for dir in $(find ${nginxDevHeaders}/include/nginx -type f -name '*.h' -printf '%h\n' | sort -u); do
      NGX_INCLUDES="$NGX_INCLUDES -I$dir"
    done

    # See `undefinedDynamicLookup` above.  Both are EMPTY on Linux, and an
    # unquoted empty expansion contributes no argument at all, so the Linux
    # command lines are byte-identical to before.
    NGX_UNDEF_LD="${undefinedDynamicLookup}"
    NGX_UNDEF_PASSL=${
      if undefinedDynamicLookup == "" then
        "\"\""
      else
        "--passL:${undefinedDynamicLookup}"
    }

    # Build Nim --passC flags from the include dirs
    NGX_NIM_PASSC=""
    for dir in $(find ${nginxDevHeaders}/include/nginx -type f -name '*.h' -printf '%h\n' | sort -u); do
      NGX_NIM_PASSC="$NGX_NIM_PASSC --passC:-I$dir"
    done

    # 1. Compile Nim handler to C
    #    --path flags provide nim-faststreams, nim-stew, isonim, and nim-everywhere.
    #    --noMain + --app:lib: no main(), produce a shared library.
    #    --mm:orc: deterministic GC for long-lived nginx workers.
    #    -d:isServer: enables SSR mode in isonim (buildHtmlString path).
    nim c \
      --mm:orc \
      --noMain \
      --app:lib \
      -d:release \
      -d:danger \
      --opt:speed \
      --nimcache:nimcache \
      -d:asyncBackend=nginx \
      -d:isServer \
      --path:"${faststreamsPath}" \
      --path:"${stewPath}" \
      --path:"${isOnimPath}" \
      --path:"${nimEverywherePath}" \
      --passC:"-fPIC" \
      $NGX_UNDEF_PASSL \
      $NGX_NIM_PASSC \
      src/handler.nim

    # 2. Compile the C module registration file
    cc -c -fPIC -O2 \
      $NGX_INCLUDES \
      -o ngx_http_isonim_module.o \
      src/ngx_http_isonim_module.c

    # 3. Link into shared library with LTO
    cc -shared -O2 $NGX_UNDEF_LD -o ngx_http_isonim_module.so \
      ngx_http_isonim_module.o \
      nimcache/*.o \
      -lpcre2-8 -lssl -lcrypto -lz
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp ngx_http_isonim_module.so $out/lib/
  '';
}
