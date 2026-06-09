{
  description = "Blackmatter Services — NixOS and home-manager microservice modules";

  inputs = {
    nixpkgs.follows = "substrate/nixpkgs";
    substrate = {
      url = "github:pleme-io/substrate";
    };
  };

  outputs = inputs @ { self, nixpkgs, substrate, ... }:
    (import "${substrate}/lib/blackmatter-component-flake.nix") {
      inherit self nixpkgs;
      name = "blackmatter-services";
      description = "NixOS + home-manager service modules (daemons, scheduled tasks, health probes)";
      modules.nixos = ./module/nixos;
      modules.homeManager = ./module/home-manager;
    };
}
