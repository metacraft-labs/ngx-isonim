{
  lib,
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
  # "release" (production) or "debug" (Nim checks and stack traces on).
  buildMode ? "release",
  # Compile in the apps the end-to-end tests drive (tests/e2e/apps).
  withTestApps ? false,
}:

stdenv.mkDerivation {
  pname = "ngx-isonim-module" + lib.optionalString (buildMode != "release") "-${buildMode}"
    + lib.optionalString withTestApps "-e2e";
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

  # scripts/build-module.sh holds the compile and link steps; the dev shell
  # and the end-to-end tests run the same script.
  NGX_DEV_HEADERS = "${nginxDevHeaders}";
  NGX_ISONIM_PATHS = "${faststreamsPath}:${stewPath}:${isOnimPath}:${nimEverywherePath}";
  NGX_ISONIM_NIMCACHE = "nimcache";
  # No extra link flags: on Darwin the script itself passes
  # -Wl,-undefined,dynamic_lookup (nginx symbols resolve at load_module time),
  # so `just build` in the dev shell links exactly as this derivation does.

  buildPhase = ''
    patchShebangs scripts/build-module.sh
    export HOME=$TMPDIR
    scripts/build-module.sh ${buildMode} ngx_http_isonim_module.so \
      ${lib.optionalString withTestApps "-d:ngxIsonimTestApps"}
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp ngx_http_isonim_module.so $out/lib/
  '';
}
