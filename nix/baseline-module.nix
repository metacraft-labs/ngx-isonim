{
  stdenv,
  nginxDevHeaders,
  pcre2,
  openssl,
  zlib,
  libxcrypt,
}:

# Pure C baseline module — no Nim, no faststreams.
# Builds in <1 second.

stdenv.mkDerivation {
  pname = "ngx-baseline-module";
  version = "0.1.0";
  src = ./..;

  buildInputs = [
    nginxDevHeaders
    pcre2
    openssl
    zlib
    libxcrypt
  ];

  buildPhase = ''
    # Find all nginx header directories
    NGX_INCLUDES=""
    for dir in $(find ${nginxDevHeaders}/include/nginx -type f -name '*.h' -printf '%h\n' | sort -u); do
      NGX_INCLUDES="$NGX_INCLUDES -I$dir"
    done

    cc -shared -fPIC -o ngx_http_baseline_module.so \
      $NGX_INCLUDES \
      src/ngx_http_baseline_module.c \
      -lpcre2-8 -lssl -lcrypto -lz
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp ngx_http_baseline_module.so $out/lib/
  '';
}
