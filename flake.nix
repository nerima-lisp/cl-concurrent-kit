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
      # Only platforms actually exercised: x86_64-linux by CI, aarch64-darwin
      # by the maintainer's own `nix flake check` runs.
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

      extraOutputs = ctx: {
        # `nix build .#coverage`: an sb-cover HTML report instrumenting this
        # package's own sources (never cl-weave's), driven by the same
        # run-tests.lisp checks.default already runs. Exposed as both a
        # package (to actually look at the report) and a check (so a
        # regression that stops the suite from exercising some file shows up
        # as a red `nix flake check`, not just a quieter coverage number).
        packages.coverage = ctx.cl.mkCoverageReport { drv = ctx.package; };
        checks.coverage = ctx.cl.mkCoverageReport { drv = ctx.package; };
      };
    };
}
