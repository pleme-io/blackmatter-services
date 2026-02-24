{
  description = "Blackmatter Services - NixOS and Home-Manager microservice modules";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/d6c71932130818840fc8fe9509cf50be8c64634f";
  };
  outputs = { self, nixpkgs }: {
    nixosModules.default = import ./module/nixos;
    homeManagerModules.default = import ./module/home-manager;
  };
}
