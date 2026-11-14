{
  description = "SBCL-only concurrency toolkit built directly on sb-thread, using CL-DATE-KIT durations and an injectable SBCL clock for deadline arithmetic";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Builds the ASDF system and provides the package, checks, apps, devShell,
    # formatter, and documentation outputs used below.
    cl-nix-forge = {
      url = "github:nerima-lisp/cl-nix-forge/v0.5.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # cl-weave is a test-only dependency (see cl-concurrent-kit.asd's
    # cl-concurrent-kit/test system), reached through
    # lispCheckDependencies below -- never through the package's own
    # lispDependencies, so a consumer building only the library never fetches
    # or builds it.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    cl-date-kit = {
      url = "github:nerima-lisp/cl-date-kit/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Benchmark-only source dependency, loaded from its ASDF system by the runner.
    cl-cli = {
      url = "github:nerima-lisp/cl-cli/v1.2.0";
      flake = false;
    };

    # Benchmark-only source dependency required by cl-cli's SBCL host integration.
    cl-host-kit = {
      url = "github:nerima-lisp/cl-host-kit/v0.3.1";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      cl-nix-forge,
      cl-weave,
      cl-date-kit,
      treefmt-nix,
      cl-cli,
      cl-host-kit,
      ...
    }:
    let
      # CI runs on x86_64-linux; local development also supports aarch64-darwin.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      # mkPackageFlake resolves outputs for every system from this library.
      cl = cl-nix-forge.lib.${nixpkgs.lib.head systems};

      # A first-class Nix input keeps the benchmark app and its CI smoke
      # check on the exact same runner, rather than duplicating the
      # invocation.
      benchmarkScript = builtins.path {
        path = ./benchmarks/run-benchmarks.lisp;
        name = "cl-concurrent-kit-benchmark-runner";
      };

      # This repository's own coverage runner and lcov invariant checker
      # (see run-coverage.lisp and scripts/verify-lcov.pl), kept alongside
      # cl-nix-forge's generic `mkCoverageReport` below rather than in place
      # of it: VERIFY-LCOV enforces this project's own per-file coverage
      # threshold, which a generic report does not know to check.
      coverageScript = builtins.path {
        path = ./run-coverage.lisp;
        name = "cl-concurrent-kit-coverage-runner";
      };

      coverageVerifier = builtins.path {
        path = ./scripts/verify-lcov.pl;
        name = "cl-concurrent-kit-coverage-verifier";
      };

      meta = {
        description = "SBCL-only concurrency toolkit built directly on sb-thread, using CL-DATE-KIT durations and an injectable SBCL clock for deadline arithmetic";
        homepage = "https://github.com/nerima-lisp/cl-concurrent-kit";
        license = nixpkgs.lib.licenses.mit;
      };
    in
    cl.mkPackageFlake {
      inherit
        self
        nixpkgs
        systems
        meta
        ;
      pname = "cl-concurrent-kit";
      asd = ./cl-concurrent-kit.asd;
      root = ./.;

      # Runtime dependencies from cl-concurrent-kit.asd.
      lispDependencies = ctx: [
        cl-date-kit.packages.${ctx.system}.cl-date-kit
      ];

      # Test-only ASDF dependency; use the library package, not its CLI.
      lispCheckDependencies = ctx: [ cl-weave.packages.${ctx.system}.cl-weave ];

      docs.root = ./docs;

      # Format Nix only; other formats are handled by their own project tools.
      treefmt.evalModule = treefmt-nix.lib.evalModule;

      extraOutputs =
        ctx:
        let
          pkgs = nixpkgs.legacyPackages.${ctx.system};
        in
        {
          # Coverage report and check for this package's own sources.
          packages.coverage = ctx.cl.mkCoverageReport { drv = ctx.package; };
          checks.coverage = ctx.cl.mkCoverageReport { drv = ctx.package; };

          # Enforce the project's per-file coverage threshold.
          checks.coverage-lcov =
            pkgs.runCommand "cl-concurrent-kit-coverage-lcov"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                  pkgs.perl
                ];
                CL_CONCURRENT_KIT_SOURCE_ROOT = self;
                # The test system adds cl-weave to the library's runtime dependency.
                CL_SOURCE_REGISTRY = "${cl-weave.packages.${ctx.system}.cl-weave}//:${
                  cl-date-kit.packages.${ctx.system}.cl-date-kit
                }//";
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME" "$out"
                timeout --signal=KILL 600s sbcl --script ${coverageScript} "$out"
                test -s "$out/html/cover-index.html"
                perl ${coverageVerifier} "$out/lcov.info" ${self}
              '';

        }
        # Benchmark tooling currently supports x86_64-linux only.
        // nixpkgs.lib.optionalAttrs (ctx.system == "x86_64-linux") {
          # Benchmark smoke test; SCALE 0.1 keeps the check short.
          checks.benchmark =
            pkgs.runCommand "cl-concurrent-kit-benchmark-smoke"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                ];
                CL_CONCURRENT_KIT_SOURCE_ROOT = self;
                # The benchmark script loads these systems directly.
                CL_SOURCE_REGISTRY = "${cl-weave.packages.${ctx.system}.cl-weave}//:${cl-cli}//:${cl-host-kit}//:${
                  cl-date-kit.packages.${ctx.system}.cl-date-kit
                }//";
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                timeout --signal=KILL 90s sbcl --script ${benchmarkScript} 0.1 > "$out"
                test -s "$out"
              '';

          apps.benchmark = {
            type = "app";
            program =
              (pkgs.writeShellApplication {
                name = "cl-concurrent-kit-benchmark";
                runtimeInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                ];
                text = ''
                  export CL_CONCURRENT_KIT_SOURCE_ROOT="${self}"
                  export CL_SOURCE_REGISTRY="${cl-weave.packages.${ctx.system}.cl-weave}//:${cl-cli}//:${cl-host-kit}//:${
                    cl-date-kit.packages.${ctx.system}.cl-date-kit
                  }//"
                  exec timeout --signal=KILL 120s sbcl --script ${benchmarkScript} "$@"
                '';
              })
              + "/bin/cl-concurrent-kit-benchmark";
          };
        };
    };
}
