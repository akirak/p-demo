{
  inputs = {
    p.url = "github:akirak/P/nix";
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      eachSystem =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f system (
            import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            }
          )
        );
    in
    {
      devShells = eachSystem (
        system: pkgs: {
          default = pkgs.mkShell {
            inputsFrom = [
              inputs.p.packages.${system}.default
            ];

            packages = [
              inputs.p.packages.${system}.default
              pkgs.vscode
            ];
          };
        }
      );
    };
}
