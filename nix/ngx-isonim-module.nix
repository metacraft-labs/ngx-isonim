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
}:

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

    # Build Nim --passC flags from the include dirs
    NGX_NIM_PASSC=""
    for dir in $(find ${nginxDevHeaders}/include/nginx -type f -name '*.h' -printf '%h\n' | sort -u); do
      NGX_NIM_PASSC="$NGX_NIM_PASSC --passC:-I$dir"
    done

    # 1. Compile Nim handler to C
    #    --path flags provide nim-faststreams and nim-stew (its dependency).
    #    --noMain + --app:lib: no main(), produce a shared library.
    #    --mm:orc: deterministic GC for long-lived nginx workers.
    nim c \
      --mm:orc \
      --noMain \
      --app:lib \
      --nimcache:nimcache \
      --path:"${faststreamsPath}" \
      --path:"${stewPath}" \
      --passC:"-fPIC" \
      $NGX_NIM_PASSC \
      src/handler.nim

    # 2. Compile the C module registration file
    cc -c -fPIC \
      $NGX_INCLUDES \
      -o ngx_http_isonim_module.o \
      src/ngx_http_isonim_module.c

    # 3. Link into shared library
    cc -shared -o ngx_http_isonim_module.so \
      ngx_http_isonim_module.o \
      nimcache/*.o \
      -lpcre2-8 -lssl -lcrypto -lz
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp ngx_http_isonim_module.so $out/lib/
  '';
}
