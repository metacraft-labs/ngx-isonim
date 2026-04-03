{
  stdenv,
  nim,
  nginxDevHeaders,
  pcre2,
  openssl,
  zlib,
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
  ];

  buildPhase = ''
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
      --passC:"-I${nginxDevHeaders}/include/nginx/core" \
      --passC:"-I${nginxDevHeaders}/include/nginx/event" \
      --passC:"-I${nginxDevHeaders}/include/nginx/http" \
      --passC:"-I${nginxDevHeaders}/include/nginx/http/modules" \
      --passC:"-I${nginxDevHeaders}/include/nginx/os/unix" \
      --passC:"-I${nginxDevHeaders}/include/nginx/objs" \
      src/handler.nim

    # 2. Compile the C module registration file
    cc -c -fPIC \
      -I${nginxDevHeaders}/include/nginx/core \
      -I${nginxDevHeaders}/include/nginx/event \
      -I${nginxDevHeaders}/include/nginx/http \
      -I${nginxDevHeaders}/include/nginx/http/modules \
      -I${nginxDevHeaders}/include/nginx/os/unix \
      -I${nginxDevHeaders}/include/nginx/objs \
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
