{
  description = "ngx-isonim - nginx native SSR module for IsoNim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Nim libraries — pinned to GitHub, overridable locally via .env:
    #   NIX_FLAKE_OVERRIDE_INPUTS='nim-faststreams=path:../nim-faststreams nim-stew=path:../nim-stew isonim=path:../isonim nim-everywhere=path:../nim-everywhere'
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
    nim-everywhere = {
      url = "github:metacraft-labs/nim-everywhere";
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
      nim-everywhere,
      git-hooks,
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
        # Override locally via .env: NIX_FLAKE_OVERRIDE_INPUTS='nim-faststreams=path:../nim-faststreams nim-stew=path:../nim-stew isonim=path:../isonim nim-everywhere=path:../nim-everywhere'
        faststreamsPath = nim-faststreams;
        stewPath = nim-stew;
        isOnimPath = "${isonim}/src";
        nimEverywherePath = "${nim-everywhere}/src";

        moduleArgs = {
          inherit
            nginxDevHeaders
            faststreamsPath
            stewPath
            isOnimPath
            nimEverywherePath
            ;
        };

        # The .so module derivation (release, the production build).
        ngxIsOnimModule = pkgs.callPackage ./nix/ngx-isonim-module.nix moduleArgs;

        # The same module built in debug mode, and with the apps the
        # end-to-end tests drive (tests/e2e/apps/e2e_apps.nim).
        ngxIsOnimModuleDebug = pkgs.callPackage ./nix/ngx-isonim-module.nix (
          moduleArgs // { buildMode = "debug"; }
        );
        ngxIsOnimModuleE2e = pkgs.callPackage ./nix/ngx-isonim-module.nix (
          moduleArgs // { withTestApps = true; }
        );

        # Pure C baseline module for performance comparison.
        baselineModule = pkgs.callPackage ./nix/baseline-module.nix {
          inherit nginxDevHeaders;
        };

        # A complete nginx binary with the module pre-loaded for E2E testing.
        nginxWithIsonim = pkgs.callPackage ./nix/nginx-with-isonim.nix {
          nginx = nginxCompat;
          inherit ngxIsOnimModule;
        };

        # nginx with baseline module for benchmarking.
        nginxBaseline =
          let
            baselineConf = pkgs.writeTextFile {
              name = "nginx-baseline.conf";
              text = ''
                load_module ${baselineModule}/lib/ngx_http_baseline_module.so;
                worker_processes 1;
                error_log /tmp/ngx-baseline-test/error.log;
                pid /tmp/ngx-baseline-test/nginx.pid;
                events { worker_connections 256; }
                http {
                  access_log off;
                  server {
                    listen 8089;
                    location / { }
                  }
                }
              '';
            };
          in
          pkgs.writeShellScriptBin "nginx-baseline" ''
            mkdir -p /tmp/ngx-baseline-test
            exec ${nginxCompat}/bin/nginx -c ${baselineConf} -p /tmp/ngx-baseline-test "$@"
          '';
        # git-hooks.nix installs `.pre-commit-config.yaml` and git hooks into
        # `git rev-parse --show-toplevel` of the directory the shell is entered
        # from, so `nix develop /path/to/<this repo>` run inside another checkout
        # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
        # only when that toplevel is this repository, recognised by a `flake.nix`
        # identical to the one this shell was evaluated from; anything it cannot
        # establish counts as another repository, so it fails safe.
        # tests/test_dev_shell_writes_nothing_elsewhere.sh
        ownRepoOnly = script: ''
          _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
          if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
            && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
              = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
          ${script}
          # git-hooks.nix's installer leaves core.hooksPath as the RELATIVE
          # `.git/hooks`, in the config every worktree shares. A linked worktree
          # cannot resolve it (there `.git` is a file), so git silently runs no
          # hooks there. Point it at the common hooks directory instead.
          if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
            ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
          fi
          fi
          unset _own_repo_root
        '';

        # The repo's pre-commit hooks. Entering the default dev shell from inside
        # this repository writes the (gitignored) .pre-commit-config.yaml symlink
        # and installs them; CI's shared lint workflow runs the same set from this
        # shell.
        preCommit = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            check-added-large-files.enable = true;
            check-merge-conflicts.enable = true;
          };
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
            # Headers and libraries the module links against: the
            # configured nginx headers include <crypt.h>, <pcre2.h>,
            # <openssl/*.h> and <zlib.h>.  scripts/build-module.sh needs
            # them to build the module outside Nix (the debug build of
            # tests/e2e/test_streaming_debug.sh).
            pkgs.pcre2
            pkgs.openssl
            pkgs.zlib
            pkgs.libxcrypt
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
            ${ownRepoOnly preCommit.shellHook}
            echo "ngx-isonim dev shell"
            echo "  nim $(nim --version 2>&1 | head -1)"
            echo "  nginx $(nginx -v 2>&1)"
            echo "  nginx headers: $NGX_DEV_HEADERS"
          '';
        };

        packages = {
          module = ngxIsOnimModule;
          module-debug = ngxIsOnimModuleDebug;
          module-e2e = ngxIsOnimModuleE2e;
          baseline = baselineModule;
          nginx-with-isonim = nginxWithIsonim;
          nginx-baseline = nginxBaseline;
          default = ngxIsOnimModule;
        };

        apps.test-e2e = {
          type = "app";
          program = "${pkgs.writeShellScript "test-e2e" ''
            export PATH="${nginxCompat}/bin:${pkgs.curl}/bin:${pkgs.wrk}/bin:$PATH"
            export NGX_ISONIM_E2E_MODULE=${ngxIsOnimModuleE2e}/lib/ngx_http_isonim_module.so
            exec ${pkgs.bash}/bin/bash ${./tests/e2e}/test_e2e.sh "$@"
          ''}";
        };
      }
    );
}
