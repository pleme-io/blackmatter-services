{
  description = "Blackmatter Services - NixOS and Home-Manager microservice modules";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };
  outputs = { self, nixpkgs }: {
    nixosModules.default = import ./module/nixos;
    homeManagerModules.default = import ./module/home-manager;
  };
}
