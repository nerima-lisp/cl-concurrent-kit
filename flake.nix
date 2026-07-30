{
  description = "Dependency-free, SBCL-only concurrency toolkit built directly on sb-thread";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # cl-weave is a test-only dependency (see cl-concurrent-kit.asd), so only
    # its source tree is needed here, not its flake outputs.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.0.1";
      flake = false;
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      cl-weave,
      treefmt-nix,
      ...
    }:
    let
      # The flake never advertises a platform nobody verifies. Both of these
      # are verified: x86_64-linux by CI, aarch64-darwin by the maintainer's
      # `nix flake check` on every local run.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # CL_SOURCE_REGISTRY for the test/dev environment.
      sourceRegistry = "${cl-weave}//:${self}//";

      # A first-class Nix input keeps the app and the CI check on the exact
      # same coverage runner, rather than duplicating the invocation.
      coverageScript = builtins.path {
        path = ./run-coverage.lisp;
        name = "cl-concurrent-kit-coverage-runner";
      };

      coverageVerifier = builtins.path {
        path = ./scripts/verify-lcov.pl;
        name = "cl-concurrent-kit-coverage-verifier";
      };

      benchmarkScript = builtins.path {
        path = ./benchmarks/run-benchmarks.lisp;
        name = "cl-concurrent-kit-benchmark-runner";
      };

      # Single source of truth for the package version: the `:version` form in
      # cl-concurrent-kit.asd. Nix regexes are whole-string anchored and `.`
      # never spans newlines, so the version is extracted line-by-line rather
      # than with one multi-line match.
      version =
        let
          lines = nixpkgs.lib.splitString "\n" (builtins.readFile ./cl-concurrent-kit.asd);
          versionLine = builtins.head (
            builtins.filter (line: builtins.match "[[:space:]]*:version \"[^\"]*\"" line != null) lines
          );
        in
        builtins.head (builtins.match "[[:space:]]*:version \"([^\"]*)\"" versionLine);

      # treefmt drives `nix fmt` and the `checks.<system>.formatting` gate.
      # Scope is Nix only: YAML formatters mangle the GitHub Actions `on:` key
      # and Markdown reformatting would churn the whole docs tree.
      treefmtEval = forAllSystems (
        system:
        treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
        }
      );
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          cl-concurrent-kit = pkgs.sbcl.buildASDFSystem {
            pname = "cl-concurrent-kit";
            inherit version;
            src = self;
            systems = [ "cl-concurrent-kit" ];
          };
          default = cl-concurrent-kit;

          # Rendered documentation site (Material for MkDocs). Built fully
          # offline: Material for MkDocs bundles all of its assets, so no
          # network access is required inside the Nix sandbox. --strict
          # promotes broken links and unlisted pages to build failures.
          docs = pkgs.stdenvNoCC.mkDerivation {
            pname = "cl-concurrent-kit-docs";
            inherit version;
            src = pkgs.lib.fileset.toSource {
              root = ./docs;
              fileset = pkgs.lib.fileset.unions [
                ./docs/mkdocs.yml
                ./docs/src
              ];
            };
            nativeBuildInputs = [ pkgs.python3Packages.mkdocs-material ];
            buildPhase = ''
              runHook preBuild
              mkdocs build --strict --config-file mkdocs.yml --site-dir "$out"
              runHook postBuild
            '';
            dontInstall = true;
            meta = {
              description = "Rendered MkDocs (Material) documentation for cl-concurrent-kit";
              homepage = "https://github.com/nerima-lisp/cl-concurrent-kit";
              license = pkgs.lib.licenses.mit;
            };
          };
        }
      );

      # `nix fmt` entry point.
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # Granularity lives here, NOT in extra GitHub Actions jobs.
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default =
            pkgs.runCommand "cl-concurrent-kit-tests"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                ];
                CL_SOURCE_REGISTRY = sourceRegistry;
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME" "$out"
                timeout --signal=KILL 90s sbcl --script ${self}/run-tests.lisp
                  touch "$out/passed"
              '';

          benchmark =
            pkgs.runCommand "cl-concurrent-kit-benchmark-smoke"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                  pkgs.perl
                ];
                CL_CONCURRENT_KIT_SOURCE_ROOT = self;
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                timeout --signal=KILL 90s sbcl --script ${benchmarkScript} 1 > "$out"
                perl -F'\t' -ane '
                  chomp;
                  if ($. == 1) {
                    die "unexpected benchmark header\n"
                      unless @F == 5
                        && $F[0] eq "name"
                        && $F[1] eq "iterations"
                        && $F[2] eq "operations"
                        && $F[3] eq "seconds"
                          && $F[4] =~ /\Aoperations-per-second\s*\z/;
                    } elsif ($. <= 5) {
                      die "unexpected benchmark row\n"
                        unless @F == 5
                          && $F[0] eq ($. == 2 ? "atomic-counter-incf" : $. == 3 ? "buffered-channel-round-trip" : $. == 4 ? "select-ready-recv" : "executor-submit-await")
                        && $F[1] == 1
                        && $F[2] > 0
                        && $F[3] > 0
                        && $F[4] > 0;
                  } else {
                    die "unexpected extra benchmark output\n";
                  }
                    END { die "benchmark output must contain one header and four rows\n" unless $. == 5; }
                ' "$out"
              '';

          coverage =
            pkgs.runCommand "cl-concurrent-kit-coverage"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                  pkgs.perl
                ];
                CL_SOURCE_REGISTRY = sourceRegistry;
                CL_CONCURRENT_KIT_SOURCE_ROOT = self;
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                timeout --signal=KILL 600s sbcl --script ${coverageScript} "$out"
                test -s "$out/html/cover-index.html"
                perl ${coverageVerifier} "$out/lcov.info" ${self}
              '';

          formatting = treefmtEval.${system}.config.build.check self;

          docs = self.packages.${system}.docs;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          test = pkgs.writeShellApplication {
            name = "cl-concurrent-kit-test";
            runtimeInputs = [
              pkgs.sbcl
              pkgs.coreutils
            ];
            text = ''
              export CL_SOURCE_REGISTRY="${sourceRegistry}"
              exec timeout --signal=KILL 90s sbcl --script ${self}/run-tests.lisp
            '';
          };
          coverage = pkgs.writeShellApplication {
            name = "cl-concurrent-kit-coverage";
            runtimeInputs = [
              pkgs.sbcl
              pkgs.coreutils
              pkgs.perl
            ];
            text = ''
              export CL_SOURCE_REGISTRY="${sourceRegistry}"
              export CL_CONCURRENT_KIT_SOURCE_ROOT="${self}"
              if [ "$#" -ne 1 ]; then
                printf '%s\\n' 'Usage: cl-concurrent-kit-coverage OUTPUT-DIRECTORY' >&2
                exit 2
              fi
              output_directory="$1"
              timeout --signal=KILL 600s sbcl --script ${coverageScript} "$output_directory"
              test -s "$output_directory/html/cover-index.html"
              test -s "$output_directory/lcov.info"
              perl ${coverageVerifier} "$output_directory/lcov.info" ${self}
            '';
          };
          benchmark = pkgs.writeShellApplication {
            name = "cl-concurrent-kit-benchmark";
            runtimeInputs = [
              pkgs.sbcl
              pkgs.coreutils
            ];
            text = ''
              unset CL_SOURCE_REGISTRY
              export CL_CONCURRENT_KIT_SOURCE_ROOT="${self}"
              exec timeout --signal=KILL 120s sbcl --script ${benchmarkScript} "$@"
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${test}/bin/cl-concurrent-kit-test";
          };
          test = {
            type = "app";
            program = "${test}/bin/cl-concurrent-kit-test";
          };
          coverage = {
            type = "app";
            program = "${coverage}/bin/cl-concurrent-kit-coverage";
          };
          benchmark = {
            type = "app";
            program = "${benchmark}/bin/cl-concurrent-kit-benchmark";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [ pkgs.sbcl ];
            CL_SOURCE_REGISTRY = sourceRegistry;
          };
        }
      );
    };
}
