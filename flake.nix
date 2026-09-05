{
  description = "SBCL-only concurrency toolkit built directly on sb-thread, using CL-DATE-KIT durations and CL-BOUNDARY-KIT clock injection for deadline arithmetic";

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

    # Runtime dependencies for the injectable clock and DURATION timeout type.
    cl-boundary-kit = {
      url = "github:nerima-lisp/cl-boundary-kit/v2.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-weave.follows = "cl-weave";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
      inputs.treefmt-nix.follows = "treefmt-nix";
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

    # Benchmark-only dependency, loaded through benchmarkScript's registry.
    cl-cli = {
      url = "github:nerima-lisp/cl-cli/v1.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
      # Reuse the top-level flake input to avoid a duplicate transitive pin.
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };

    # Transitive dependency needed by cl-cli and cl-boundary-kit.
    cl-host-kit = {
      url = "github:nerima-lisp/cl-host-kit/v0.3.1";
      inputs.nixpkgs.follows = "nixpkgs";
      # Reuse the top-level versions for transitive dependencies.
      inputs.cl-weave.follows = "cl-weave";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      cl-nix-forge,
      cl-weave,
      cl-boundary-kit,
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
        description = "SBCL-only concurrency toolkit built directly on sb-thread, using CL-DATE-KIT durations and CL-BOUNDARY-KIT clock injection for deadline arithmetic";
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
        cl-boundary-kit.packages.${ctx.system}.cl-boundary-kit
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
                # run-coverage.lisp runs cl-concurrent-kit/test (ASDF:TEST-SYSTEM),
                # which loads cl-concurrent-kit itself -- so this needs its own
                # main-system dependencies (cl-boundary-kit, cl-date-kit) on the
                # registry in addition to cl-weave, same requirement as
                # checks.benchmark/apps.benchmark below. cl-host-kit is
                # cl-boundary-kit's OWN ASDF dependency (its real-boundary
                # backend), not cl-concurrent-kit's -- ASDF still resolves
                # cl-boundary-kit's full :depends-on chain even when loading
                # it as a prebuilt package, so cl-host-kit must be reachable
                # here too, exactly as checks.benchmark already needs it for
                # cl-cli's own cl-host-kit dependency.
                CL_SOURCE_REGISTRY = "${cl-weave.packages.${ctx.system}.cl-weave}//:${
                  cl-boundary-kit.packages.${ctx.system}.cl-boundary-kit
                }//:${cl-date-kit.packages.${ctx.system}.cl-date-kit}//:${
                  cl-host-kit.packages.${ctx.system}.cl-host-kit
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
                CL_SOURCE_REGISTRY = "${cl-weave.packages.${ctx.system}.cl-weave}//:${
                  cl-cli.packages.${ctx.system}.cl-cli
                }//:${cl-host-kit.packages.${ctx.system}.cl-host-kit}//:${
                  cl-boundary-kit.packages.${ctx.system}.cl-boundary-kit
                }//:${cl-date-kit.packages.${ctx.system}.cl-date-kit}//";
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
                  export CL_SOURCE_REGISTRY="${cl-weave.packages.${ctx.system}.cl-weave}//:${
                    cl-cli.packages.${ctx.system}.cl-cli
                  }//:${cl-host-kit.packages.${ctx.system}.cl-host-kit}//:${
                    cl-boundary-kit.packages.${ctx.system}.cl-boundary-kit
                  }//:${cl-date-kit.packages.${ctx.system}.cl-date-kit}//"
                  exec timeout --signal=KILL 120s sbcl --script ${benchmarkScript} "$@"
                '';
              })
              + "/bin/cl-concurrent-kit-benchmark";
          };
        };
    };
}
