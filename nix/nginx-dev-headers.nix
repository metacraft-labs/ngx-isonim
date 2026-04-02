{
  stdenv,
  nginxSrc,
  pcre2,
  openssl,
  zlib,
}:

stdenv.mkDerivation {
  pname = "nginx-dev-headers";
  version = nginxSrc.version or "1.26";
  src = nginxSrc;

  buildInputs = [
    pcre2
    openssl
    zlib
  ];

  buildPhase = ''
    # Run configure with --with-compat to generate module-compatible headers.
    # --with-compat ensures the module ABI matches dynamic module loading.
    ./configure \
      --with-compat \
      --with-http_ssl_module \
      --with-pcre \
      --without-http_rewrite_module
  '';

  installPhase = ''
    mkdir -p $out/include/nginx
    # Copy source headers (core, event, http, os)
    cp -r src/core $out/include/nginx/
    cp -r src/event $out/include/nginx/
    cp -r src/http $out/include/nginx/
    cp -r src/os $out/include/nginx/
    # Copy auto-generated headers (ngx_auto_config.h, ngx_auto_headers.h)
    mkdir -p $out/include/nginx/objs
    cp objs/ngx_auto_config.h $out/include/nginx/objs/
    cp objs/ngx_auto_headers.h $out/include/nginx/objs/
  '';
}
