{
  inputs = {
    nixpkgs.url = "nixpkgs";
    systems.url = "github:nix-systems/default-linux";
  };

  outputs = { self, nixpkgs, systems }: let
    forEachSystem = nixpkgs.lib.genAttrs (import systems);
  in
  {
    devShells = forEachSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) ocamlPackages;
    in {
      default = pkgs.mkShell {
        packages = [
          ocamlPackages.ocaml-lsp
          ocamlPackages.ocamlformat
        ];

        inputsFrom = [
          self.packages.${system}.proxy
        ];
      };
    });

    packages = forEachSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) ocamlPackages;
      memfd = ocamlPackages.buildDunePackage rec {
        pname = "memfd";
        version = "0.1.0";

        src = pkgs.fetchurl {
          url = "https://github.com/gborough/memfd/releases/download/${version}/memfd-${version}.tbz";
          hash = "sha256-B4rpkPbAkkq/KUaTqR4AxwyQYqklvhgPl97jy6FbuVg=";
        };
      };
    in {
      proxy =
        # Based on build rule in nixpkgs, by qyliss and sternenseemann
        ocamlPackages.buildDunePackage {
          pname = "wayland-proxy-virtwl";
          version = "dev";

          src = ./.;

          nativeBuildInputs = [
            pkgs.pkg-config
          ];

          buildInputs = [ pkgs.libdrm ] ++ (with ocamlPackages; [
            dune-configurator
            eio_main
            ppx_cstruct
            xmlm  #wayland    (vendored)
            cmdliner
            logs
            memfd
          ]);
        };

      default = self.packages.${system}.proxy;
    });
  };
}
