{
  description = "SBCL-only concurrency toolkit built directly on sb-thread, using CL-DATE-KIT durations and CL-BOUNDARY-KIT clock injection for deadline arithmetic";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The org's own "crane for Common Lisp/ASDF": turns this repository's
    # .asd into a Nix derivation and generates the whole PACKAGE_STANDARD.md
    # output table (packages/checks/apps/devShells/formatter/overlays) from
    # one mkPackageFlake call below, instead of hand-rolling each of them.
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

    # Real, main-system dependencies (cl-concurrent-kit.asd's :depends-on):
    # cl-boundary-kit supplies the injectable clock behind %DEADLINE-FROM-TIMEOUT
    # and %SECONDS-UNTIL-DEADLINE (src/primitives.lisp's *CLOCK*), cl-date-kit
    # supplies the DURATION type every public :TIMEOUT argument now accepts.
    # v2.3.0 is the first cl-boundary-kit tag whose flake.nix actually builds
    # packages.<system>.cl-boundary-kit (earlier tags wired cl-host-kit-runtime
    # with lispLibs instead of a cl.fromDerivation-wrapped lispDependencies
    # entry, so the package itself never built -- see Serena memory
    # cl-boundary-kit-upstream-flake-bug).
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

    # cl-cli is a benchmark-tooling-only dependency, reached the same way
    # cl-weave is: through benchmarkScript's CL_SOURCE_REGISTRY below, never
    # through cl-concurrent-kit's own lispDependencies. It gives
    # benchmarks/run-benchmarks.lisp real --only/SCALE argument parsing,
    # replacing two arguments (checks.benchmark's positional "1",
    # apps.benchmark's forwarded "$@") the script used to silently ignore.
    cl-cli = {
      url = "github:nerima-lisp/cl-cli/v1.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
      # cl-cli's own flake.nix pins cl-nix-forge as a real (flake=true)
      # input at its own, older tag. Without this override, that transitive
      # pin enters this project's flake.lock as a second, stale copy of
      # cl-nix-forge alongside the top-level one above -- same pattern as
      # nixpkgs.follows on every input here, just one level deeper.
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };

    # cl-cli v1.2.0 added a cl-host-kit dependency of its own under SBCL.
    # cl-cli's own flake.nix does not re-export that input as a full flake
    # (only as a plain source tree, with no packages output reachable
    # through cl-cli.inputs.cl-host-kit), so it needs its own top-level
    # input here -- reached both by benchmark-tooling (same as cl-weave/
    # cl-cli) and, since cl-boundary-kit itself depends on cl-host-kit
    # too, by checks.coverage-lcov's CL_SOURCE_REGISTRY below. v0.3.1, not
    # v0.2.5: matches cl-boundary-kit's own pin, and v0.2.5's own flake.nix
    # declares only x86_64-linux in `systems` (aarch64-darwin arrived in
    # v0.3.1) -- checks.coverage-lcov runs on every declared system, unlike
    # checks.benchmark/apps.benchmark below (deliberately x86_64-linux-only
    # for a different, cl-cli-side reason), so pinning at v0.2.5 here broke
    # `nix flake check` outright on aarch64-darwin.
    cl-host-kit = {
      url = "github:nerima-lisp/cl-host-kit/v0.3.1";
      inputs.nixpkgs.follows = "nixpkgs";
      # Same transitive-duplication fix as cl-cli.inputs.cl-nix-forge above:
      # cl-host-kit's own flake.nix pins both cl-weave and cl-nix-forge as
      # real flakes at its own tags.
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
      # x86_64-linux is what CI gates; aarch64-darwin is the development
      # machine. Every per-system output -- packages, checks, apps AND devShells
      # -- comes from this one list, so leaving aarch64-darwin out takes `nix
      # build` and `nix develop` off the development machine as well. That trade
      # was made on 2026-08-01 and reverted on 2026-08-02; aarch64-darwin carries
      # no CI gate, which PACKAGE_STANDARD.md's "systems" section accepts
      # explicitly. aarch64-linux and x86_64-darwin are nobody's verification and
      # are not declared.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
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

      # Real, main-system dependencies -- cl-concurrent-kit.asd's own
      # :depends-on -- unlike lispCheckDependencies below, these reach every
      # consumer of the library, not just this repo's own test suite.
      lispDependencies = ctx: [
        cl-boundary-kit.packages.${ctx.system}.cl-boundary-kit
        cl-date-kit.packages.${ctx.system}.cl-date-kit
      ];

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
        # cl-cli (v1.2.0, the latest published release -- see flake.nix's
        # own cl-cli input comment) declares only x86_64-linux in its own
        # `systems`; it added aarch64-darwin support only after that
        # release. checks.benchmark/apps.benchmark below reference
        # cl-cli.packages.${ctx.system}.cl-cli directly (not through
        # lispDependencies, so mkPackageFlake's own per-system resolution
        # can't skip it for us), so evaluating them on aarch64-darwin fails
        # with "attribute 'aarch64-darwin' missing" -- confirmed
        # reproducible on origin/main before this branch's own changes, so
        # this is a pre-existing gap, not a regression. Scoping both
        # outputs to x86_64-linux only is the honest fix, consistent with
        # this file's own "aarch64-darwin carries no CI gate" acceptance
        # above; revisit once cl-cli publishes a release with
        # aarch64-darwin support.
        // nixpkgs.lib.optionalAttrs (ctx.system == "x86_64-linux") {
          # `nix build .#benchmark` / `nix run .#benchmark`: a microbenchmark
          # suite over the primitives this branch's perf work targets
          # (atomic counters, buffered channels, SELECT, the executor).
          # checks.benchmark only smoke-tests that it still runs and reports
          # sane numbers; it is not a performance gate -- SCALE 0.1 keeps it
          # fast without leaving the --ONLY/SCALE argument path unexercised.
          checks.benchmark =
            pkgs.runCommand "cl-concurrent-kit-benchmark-smoke"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                ];
                CL_CONCURRENT_KIT_SOURCE_ROOT = self;
                # cl-concurrent-kit itself, cl-weave:benchmark, and cl-cli
                # (and cl-cli's own cl-host-kit dependency) are all loaded
                # directly by the script (not just the test system), so their
                # own store paths -- including cl-concurrent-kit's own
                # lispDependencies, cl-boundary-kit/cl-date-kit -- must be on
                # the source registry too -- see the :inherit-configuration
                # source-registry form in benchmarks/run-benchmarks.lisp.
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
