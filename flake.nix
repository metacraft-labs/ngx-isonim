{
  description = "ngx-isonim - nginx native SSR module for IsoNim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Nim libraries — pinned to GitHub, overridable locally via .env:
    #   NIX_FLAKE_OVERRIDE_INPUTS='nim-faststreams=path:../nim-faststreams nim-stew=path:../nim-stew isonim=path:../isonim'
    nim-faststreams = {
      url = "github:metacraft-labs/nim-faststreams";
      flake = false;
    };
    nim-stew = {
      url = "github:status-im/nim-stew";
      flake = false;
    };
    isonim = {
      url = "github:metacraft-labs/isonim";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nim-faststreams,
      nim-stew,
      isonim,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        isLinux = pkgs.lib.hasSuffix "linux" system;

        # Custom nginx with --with-compat enabled for dynamic module support.
        # The stock nixpkgs nginx does NOT include --with-compat, so
        # load_module will reject any .so due to signature mismatch.
        # We rebuild nginx with the flag added — this is the binary used
        # for E2E testing and the headers are derived from it.
        nginxCompat = pkgs.nginx.overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [
            "--with-compat"
          ];
        });

        # Configured nginx headers derived from the compat build.
        nginxDevHeaders = pkgs.callPackage ./nix/nginx-dev-headers.nix {
          nginx = nginxCompat;
        };

        # Nim library paths from flake inputs.
        # Override locally via .env: NIX_FLAKE_OVERRIDE_INPUTS='nim-faststreams=path:../nim-faststreams nim-stew=path:../nim-stew isonim=path:../isonim'
        faststreamsPath = nim-faststreams;
        stewPath = nim-stew;
        isOnimPath = "${isonim}/src";

        # The .so module derivation.
        ngxIsOnimModule = pkgs.callPackage ./nix/ngx-isonim-module.nix {
          inherit
            nginxDevHeaders
            faststreamsPath
            stewPath
            isOnimPath
            ;
        };

        # A complete nginx binary with the module pre-loaded for E2E testing.
        nginxWithIsonim = pkgs.callPackage ./nix/nginx-with-isonim.nix {
          nginx = nginxCompat;
          inherit ngxIsOnimModule;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.nim
            pkgs.nimble
            pkgs.just
            pkgs.curl
            pkgs.wrk
            pkgs.jq
            nginxCompat
          ]
          ++ pkgs.lib.optionals isLinux [
            pkgs.strace
            pkgs.valgrind
          ];

          # Nim needs to find nginx headers at compile time.
          NGX_DEV_HEADERS = "${nginxDevHeaders}";

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.pcre2
            pkgs.openssl
            pkgs.zlib
          ];

          shellHook = ''
            echo "ngx-isonim dev shell"
            echo "  nim $(nim --version 2>&1 | head -1)"
            echo "  nginx $(nginx -v 2>&1)"
            echo "  nginx headers: $NGX_DEV_HEADERS"
          '';
        };

        packages = {
          module = ngxIsOnimModule;
          nginx-with-isonim = nginxWithIsonim;
          default = ngxIsOnimModule;
        };

        apps.test-e2e = {
          type = "app";
          program = "${pkgs.writeShellScript "test-e2e" ''
            export PATH="${nginxWithIsonim}/bin:${pkgs.curl}/bin:$PATH"
            exec ${./tests/e2e/test_e2e.sh} "$@"
          ''}";
        };
      }
    );
}
