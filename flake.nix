{
  description = "poolboy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        haskellPackages = pkgs.haskellPackages;
      in
      rec
      {
        packages.poolboy =
          # activateBenchmark
          (haskellPackages.callCabal2nix "poolboy" ./poolboy {
            # Dependency overrides go here
          });

        packages.effectful-poolboy =
          # activateBenchmark
          (haskellPackages.callCabal2nix "effectful-poolboy" ./effectful-poolboy {
            poolboy = packages.poolboy;
          });

        defaultPackage = packages.poolboy;

        devShell =
          pkgs.mkShell {
            buildInputs = with haskellPackages; [
              haskell-language-server
              ghcid
              cabal-install
              haskell-ci
              ormolu
            ];
            inputsFrom = [
              self.defaultPackage.${system}.env
            ];
          };
      });
}
