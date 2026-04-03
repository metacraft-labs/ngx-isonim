{
  nginx,
}:

# Derive headers from the SAME nginx build that we'll use at runtime.
# The caller must pass in the nginx derivation that has --with-compat
# enabled (see flake.nix: nginxCompat). This ensures the module signature
# matches perfectly — nginx checks NGX_MODULE_SIGNATURE at load_module time.

nginx.overrideAttrs (old: {
  pname = "nginx-dev-headers";

  # Don't build the full nginx binary — just run configure for the headers.
  buildPhase = ''
    test -f objs/ngx_auto_config.h || { echo "ngx_auto_config.h not generated"; exit 1; }
  '';

  installPhase = ''
    mkdir -p $out/include/nginx
    cp -r src/core src/event src/http src/os $out/include/nginx/
    mkdir -p $out/include/nginx/objs
    cp objs/ngx_auto_config.h objs/ngx_auto_headers.h $out/include/nginx/objs/
  '';

  outputs = [ "out" ];
  disallowedReferences = [ ];
})
