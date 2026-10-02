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
  # See `undefinedDynamicLookup` above.  Empty on Linux.
  NGX_ISONIM_EXTRA_LDFLAGS = undefinedDynamicLookup;

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
