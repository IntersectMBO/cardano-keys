{
  description = "cardano-keys";

  inputs = {
    # hackageNix, haskellNix, CHaP and ghc-wasm-meta are pinned so the
    # toolchain derivations (and their cache hits, e.g. the GHC 9.14 haddock
    # compiler) stay stable.
    # Bump the pins deliberately, not via a blanket `nix flake update`.
    hackageNix = {
      url = "github:input-output-hk/hackage.nix/a69c841fe2cbb3571739018f9efb7f533279fb15";
      flake = false;
    };
    haskellNix = {
      url = "github:input-output-hk/haskell.nix/f7de4ec666e8eee071ffb885410cce19d7081fcc";
      inputs.hackage.follows = "hackageNix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # blst fails to build for x86_64-darwin
    # nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    nixpkgs.url = "github:NixOS/nixpkgs/11cb3517b3af6af300dd6c055aeda73c9bf52c48";
    unstable.url = "nixpkgs/nixos-unstable";
    iohkNix.url = "github:input-output-hk/iohk-nix";
    flake-utils.url = "github:hamishmack/flake-utils/hkm/nested-hydraJobs";
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    # non-flake nix compatibility
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages/13d0f23cf6af9ea55194b91f6947c0a2aeb522d9";
      flake = false;
    };

    hls = {
      url = "github:haskell/haskell-language-server/2.14.0.0";
      flake = false;
    };

    cardano-dev.url = "github:input-output-hk/cardano-dev";

    # wasm specific inputs
    wasm-nixpkgs.follows = "ghc-wasm-meta/nixpkgs";
    ghc-wasm-meta.url = "gitlab:haskell-wasm/ghc-wasm-meta/c662c34d608dc9d2ff599b007f2e3c46138efaab?host=gitlab.haskell.org";
  };

  outputs = inputs: let
    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    # see flake `variants` below for alternative compilers
    # this is used to build cardano-node on linux, so we test against it
    stableCompiler = "ghc967";
    # this is our main compiler for development
    defaultCompiler = "ghc9124";
    # Used for cross compilation for windows.
    crossCompilerVersion = defaultCompiler;
    # Used for haddock generation (avoids GHC 9.12 tyConStupidTheta panic)
    haddockCompiler = "ghc914";
  in
    inputs.flake-utils.lib.eachSystem supportedSystems (
      system: let
        # setup our nixpkgs with the haskell.nix overlays, and the iohk-nix
        # overlays...
        nixpkgs = let
          unstableOverlay = final: prev: {
            unstable = import inputs.unstable {
              inherit system;
              inherit (inputs.haskellNix) config;
            };
          };
        in
          import inputs.nixpkgs {
            overlays = [
              unstableOverlay
              # iohkNix.overlays.crypto provide libsodium-vrf, libblst and libsecp256k1.
              inputs.iohkNix.overlays.crypto
              # haskellNix.overlay can be configured by later overlays, so need to come before them.
              inputs.haskellNix.overlay
              # configure haskell.nix to use iohk-nix crypto librairies.
              inputs.iohkNix.overlays.haskell-nix-crypto
            ];
            inherit system;
            inherit (inputs.haskellNix) config;
          };
        inherit (nixpkgs) lib;

        pre-commit-check = inputs.pre-commit-hooks.lib.${nixpkgs.system}.run {
          src = ./.;
          hooks = {
            alejandra.enable = true;
            cabal-gild = {
              enable = true;
              entry = let
                script = nixpkgs.writeShellScript "precommit-cabal-gild" ''
                  for file in "$@"; do
                      cabal-gild --io="$file"
                  done
                '';
              in
                builtins.toString script;
              files = "\\.cabal$";
            };
            prettify = {
              enable = true;
              entry = "scripts/githooks/haskell-style-lint";
              types = ["haskell"];
            };
          };
        };

        # We use cabalProject' to ensure we don't build the plan for
        # all systems.
        cabalProject = nixpkgs.haskell-nix.cabalProject' ({config, ...}: {
          src = ./.;
          name = "cardano-keys";
          compiler-nix-name = lib.mkDefault defaultCompiler;

          # we also want cross compilation to windows on linux (and only with default compiler).
          crossPlatforms = p:
            lib.optional (system == "x86_64-linux" && config.compiler-nix-name == crossCompilerVersion)
            p.mingwW64;

          # CHaP input map, so we can find CHaP packages (needs to be more
          # recent than the index-state we set!). Can be updated with
          #
          #  nix flake lock --update-input CHaP
          #
          inputMap = {
            "https://chap.intersectmbo.org/" = inputs.CHaP;
          };
          # Also currently needed to make `nix flake lock --update-input CHaP` work.
          cabalProjectLocal = ''
            repository cardano-haskell-packages-local
              url: file:${inputs.CHaP}
              secure: True
            active-repositories: hackage.haskell.org, cardano-haskell-packages-local
          '';

          shell.packages = p: [
            # Packages in this repo
            p.cardano-keys
          ];
          # tools we want in our shell, from hackage
          shell.tools =
            {
              cabal = "3.16.1.0";
            }
            // lib.optionalAttrs (config.compiler-nix-name == defaultCompiler) {
              # tools that work only with default compiler
              ghcid = "0.8.9";
              cabal-gild = "1.7.0.1";
              fourmolu = "0.18.0.0";
              haskell-language-server = {
                src = inputs.hls;
                configureArgs = "--disable-benchmarks --disable-tests";
              };
              hlint = "3.10";
            };
          # and from nixpkgs or other inputs
          shell.nativeBuildInputs = with nixpkgs; [
            gh
            git
            jq
            yq-go
            unstable.actionlint
            shellcheck
            blst
            inputs.cardano-dev.packages.${system}.herald
            (writeShellScriptBin "haskell-language-server-wrapper" ''exec haskell-language-server "$@"'')
          ];
          # disable Hoogle until someone request it
          shell.withHoogle = false;
          # Skip cross compilers for the shell
          shell.crossPlatforms = _: [];
          shell.shellHook = ''
            export PATH="${nixpkgs.nix}/bin:$PATH"
            ${pre-commit-check.shellHook}
            export PATH="$(git rev-parse --show-toplevel)/scripts/devshell:$PATH"
          '';

          # package customizations as needed. Where cabal.project is not
          # specific enough, or doesn't allow setting these.
          modules = [
            ({...}: {
              packages.cardano-keys = {
                configureFlags = ["--ghc-option=-Werror"];
              };
            })
          ];
        });
        # ... and construct a flake from the cabal project
        flake = cabalProject.flake {
          # build/test the other supported compilers on every system: CI's
          # github-page workflow uses `.#ghc914`, and developers are not all
          # on x86_64-linux.
          variants = let
            # on windows we're using defaultCompiler only - stableCompiler makes ghc-iserv flaky
            osDependentStableCompiler =
              if nixpkgs.stdenv.hostPlatform.isWindows
              then defaultCompiler
              else stableCompiler;
          in
            lib.genAttrs [osDependentStableCompiler crossCompilerVersion haddockCompiler] (compiler-nix-name: {
              inherit compiler-nix-name;
            });
        };
        # wasm shell
        wasmShell = let
          wasm-pkgs = inputs.wasm-nixpkgs.legacyPackages.${system};
          wasi-sdk = inputs.ghc-wasm-meta.packages.${system}.wasi-sdk;
          wasm = {
            libsodium =
              wasm-pkgs.callPackage ./nix/libsodium.nix {inherit wasi-sdk;};
            secp256k1 = (wasm-pkgs.callPackage ./nix/secp256k1.nix {inherit wasi-sdk;}).overrideAttrs (_: {
              src = nixpkgs.secp256k1.src;
            });
            blst =
              (wasm-pkgs.callPackage ./nix/blst.nix {
                inherit wasi-sdk;
                version = nixpkgs.blst.version;
              }).overrideAttrs (_: {
                src = nixpkgs.blst.src;
              });
          };
        in
          lib.optionalAttrs (system != "x86_64-darwin") {
            wasm = wasm-pkgs.mkShell {
              packages = [
                wasm-pkgs.pkg-config
                wasm-pkgs.curl
                wasm-pkgs.git
                inputs.ghc-wasm-meta.packages.${system}.all_9_10
                wasm.libsodium
                wasm.secp256k1
                wasm.blst
              ];
            };
          };
        flakeWithWasmShell = nixpkgs.lib.recursiveUpdate flake {
          devShells = wasmShell;
          hydraJobs = {devShells = wasmShell;};
        };
      in
        nixpkgs.lib.recursiveUpdate flakeWithWasmShell rec {
          project = cabalProject;
          # add a required job, that's basically all hydraJobs.
          hydraJobs =
            nixpkgs.callPackages inputs.iohkNix.utils.ciJobsAggregates
            {
              ciJobs =
                flakeWithWasmShell.hydraJobs
                // {
                  # This ensure hydra send a status for the required job (even if no change other than commit hash)
                  revision = nixpkgs.writeText "revision" (inputs.self.rev or "dirty");
                };
            };
          legacyPackages = {
            inherit cabalProject nixpkgs;
            # also provide hydraJobs through legacyPackages to allow building without system prefix:
            inherit hydraJobs;
          };
          devShells = let
            # profiling shell
            profilingShell = p: {
              # `nix develop .#profiling` (or `.#ghc927.profiling): a shell with profiling enabled
              profiling = (p.appendModule {modules = [{enableLibraryProfiling = true;}];}).shell;
            };
          in
            profilingShell cabalProject;
          # formatter used by nix fmt
          formatter = nixpkgs.alejandra;
        }
    );

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
    allow-import-from-derivation = true;
  };
}
