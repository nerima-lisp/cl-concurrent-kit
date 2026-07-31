{
  description = "Dependency-free, SBCL-only concurrency toolkit built directly on sb-thread";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The org's own "crane for Common Lisp/ASDF": turns this repository's
    # .asd into a Nix derivation and generates the whole PACKAGE_STANDARD.md
    # output table (packages/checks/apps/devShells/formatter/overlays) from
    # one mkPackageFlake call below, instead of hand-rolling each of them.
    cl-nix-forge = {
      url = "github:nerima-lisp/cl-nix-forge/v0.4.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # cl-weave is a test-only dependency (see cl-concurrent-kit.asd's
    # cl-concurrent-kit/test system), reached through
    # lispCheckDependencies below -- never through the package's own
    # lispDependencies, so a consumer building only the library never fetches
    # or builds it.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      cl-nix-forge,
      cl-weave,
      treefmt-nix,
      ...
    }:
    let
      # The only platform this repository verifies. CI builds and tests
      # x86_64-linux and nothing else, so the flake declares nothing else: a
      # platform whose only gate was a maintainer remembering to run
      # `nix flake check` by hand was never actually gated.
      #
      # Consequence, accepted deliberately on 2026-08-01: mkPackageFlake
      # generates EVERY per-system output from this one list -- packages,
      # checks, apps and devShells alike -- so dropping aarch64-darwin also
      # drops devShells.aarch64-darwin. `nix develop` and `nix build` therefore
      # do not work on macOS; development happens on Linux. See
      # PACKAGE_STANDARD.md, section "systems".
      systems = [
        "x86_64-linux"
      ];

      # mkPackageFlake spans every declared system on its own (it takes
      # `systems` and resolves a `pkgs`/`cl` per entry via `nixpkgs`), so it
      # only needs to be reached through ONE system's instantiation of the
      # library -- not called once per system here. Any entry of `systems`
      # would do; the first is as good as any other.
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
        description = "Dependency-free, SBCL-only concurrency toolkit built directly on sb-thread";
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

      # cl-weave's own flake (built with this same mkPackageFlake) exports
      # the ASDF system itself as packages.<system>.cl-weave, distinct from
      # packages.default (its delivered CLI) -- taking the CLI here would
      # pull in a binary the test suite never runs.
      lispCheckDependencies = ctx: [ cl-weave.packages.${ctx.system}.cl-weave ];

      docs.root = ./docs;

      # PACKAGE_STANDARD.md scopes treefmt to Nix and only Nix (the default
      # module mkPackageFlake applies when `module` is omitted): a YAML
      # formatter mangles GitHub Actions' `on:` key, and reformatting the
      # whole docs tree on every touch would drown real review in noise.
      treefmt.evalModule = treefmt-nix.lib.evalModule;

      extraOutputs =
        ctx:
        let
          pkgs = nixpkgs.legacyPackages.${ctx.system};
        in
        {
          # `nix build .#coverage`: an sb-cover HTML report instrumenting this
          # package's own sources (never cl-weave's), driven by the same
          # run-tests.lisp checks.default already runs. Exposed as both a
          # package (to actually look at the report) and a check (so a
          # regression that stops the suite from exercising some file shows up
          # as a red `nix flake check`, not just a quieter coverage number).
          packages.coverage = ctx.cl.mkCoverageReport { drv = ctx.package; };
          checks.coverage = ctx.cl.mkCoverageReport { drv = ctx.package; };

          # This project's own coverage runner and lcov verifier, layered on
          # top of the generic report above: it fails the build outright if
          # any source file falls under this project's own coverage bar,
          # rather than only rendering a number someone has to remember to look at.
          checks.coverage-lcov =
            pkgs.runCommand "cl-concurrent-kit-coverage-lcov"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                  pkgs.perl
                ];
                CL_CONCURRENT_KIT_SOURCE_ROOT = self;
                # run-coverage.lisp runs cl-concurrent-kit/test (ASDF:TEST-SYSTEM)
                # to gather coverage, which depends on cl-weave -- same
                # source-registry requirement as checks.benchmark above.
                CL_SOURCE_REGISTRY = "${cl-weave.packages.${ctx.system}.cl-weave}//";
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME" "$out"
                timeout --signal=KILL 600s sbcl --script ${coverageScript} "$out"
                test -s "$out/html/cover-index.html"
                perl ${coverageVerifier} "$out/lcov.info" ${self}
              '';

          # `nix build .#benchmark` / `nix run .#benchmark`: a microbenchmark
          # suite over the primitives this branch's perf work targets
          # (atomic counters, buffered channels, SELECT, the executor).
          # checks.benchmark only smoke-tests that it still runs and reports
          # sane numbers; it is not a performance gate.
          checks.benchmark =
            pkgs.runCommand "cl-concurrent-kit-benchmark-smoke"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                ];
                CL_CONCURRENT_KIT_SOURCE_ROOT = self;
                # cl-weave:benchmark is loaded directly by the script (not
                # just the test system), so its own store path must be on
                # the source registry too -- see the :inherit-configuration
                # source-registry form in benchmarks/run-benchmarks.lisp.
                CL_SOURCE_REGISTRY = "${cl-weave.packages.${ctx.system}.cl-weave}//";
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                timeout --signal=KILL 90s sbcl --script ${benchmarkScript} 1 > "$out"
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
                  export CL_SOURCE_REGISTRY="${cl-weave.packages.${ctx.system}.cl-weave}//"
                  exec timeout --signal=KILL 120s sbcl --script ${benchmarkScript} "$@"
                '';
              })
              + "/bin/cl-concurrent-kit-benchmark";
          };
        };
    };
}
