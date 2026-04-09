{
  description = "HyperConsole - A strictly better superconsole";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        haskellPackages = pkgs.haskellPackages.override {
          overrides = final: prev: {
            hyperconsole = final.callCabal2nix "hyperconsole" ./. { };
          };
        };

        # Extract individual components
        hyperconsole = haskellPackages.hyperconsole;
      in
      {
        packages = {
          default = hyperconsole;
          hyperconsole = hyperconsole;

          # Demo executable
          demo = pkgs.haskell.lib.justStaticExecutables (
            pkgs.haskell.lib.overrideCabal hyperconsole (old: {
              # Only build the demo executable
            })
          );

          # Benchmarks
          bench = pkgs.haskell.lib.doBenchmark hyperconsole;
        };

        # Apps for `nix run`
        apps = {
          default = {
            type = "app";
            program = "${hyperconsole}/bin/hyperconsole-demo";
          };
          demo = {
            type = "app";
            program = "${hyperconsole}/bin/hyperconsole-demo";
          };
          bench = {
            type = "app";
            program = "${pkgs.haskell.lib.doBenchmark hyperconsole}/bin/hyperconsole-bench";
          };
        };

        devShells.default = haskellPackages.shellFor {
          packages = p: [ p.hyperconsole ];
          buildInputs = with pkgs; [
            haskellPackages.cabal-install
            haskellPackages.haskell-language-server
            haskellPackages.hlint
            haskellPackages.ormolu
          ];
        };

        checks = {
          hyperconsole = hyperconsole;
        };
      }
    );
}
