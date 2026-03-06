# blackmatter-services

NixOS and home-manager modules for self-hosted microservices.

## Overview

Declarative NixOS and home-manager modules for running self-hosted infrastructure services. Each service gets its own subdirectory with enable options and configuration. NixOS modules cover server-side services; home-manager modules cover client-side tools.

## Flake Outputs

- `nixosModules.default` -- NixOS module at `blackmatter.components.microservices`
- `homeManagerModules.default` -- home-manager module at `blackmatter.components.microservices`

## Usage

```nix
{
  inputs.blackmatter-services.url = "github:pleme-io/blackmatter-services";
}
```

```nix
blackmatter.components.microservices.enable = true;
```

## Included Services (NixOS)

- MinIO, Consul, Cockpit, Vaultwarden
- Traefik, HAProxy (reverse proxies)
- Gitea, PostgreSQL
- Application reverse proxy, Supervisord

## Structure

- `module/nixos/` -- NixOS service modules (one directory per service)
- `module/home-manager/` -- home-manager client modules
