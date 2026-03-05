# blackmatter-services

NixOS and Home-Manager microservice modules with built-in dependency resolution, cross-service validation, and dev/prod mode switching. Provides a declarative way to compose infrastructure services (databases, reverse proxies, object storage, monitoring, and more) on NixOS systems, with automatic port conflict detection, circular dependency checking, and systemd service ordering.

## Architecture

```
blackmatter-services
  module/
    nixos/                      # NixOS system-level service modules
      lib/
        base.nix                # Shared option types, patterns, and helpers
        dependencies.nix        # Service dependency graph + topological sort
        validation.nix          # Port/domain/SSL/database validators
      application_reverse_proxy # Composite: Traefik + Consul + Nomad
      supervisord/              # Process manager (supervisord)
      minio/                    # Object storage (MinIO)
      consul/                   # Service discovery (Consul)
      cockpit/                  # Web admin panel (Cockpit)
      vaultwarden/              # Password manager (Vaultwarden)
      traefik/                  # Reverse proxy / load balancer (Traefik)
      haproxy/                  # Reverse proxy / load balancer (HAProxy)
      gitea/                    # Git server (Gitea)
      postgres/                 # PostgreSQL with dev/prod tuning profiles
      ...                       # Additional services (jitsi, keycloak, etc.)
    home-manager/               # User-level service modules
      goomba_user_service/      # Generic systemd user service runner
      minio/                    # MinIO via goomba user service
      attic/                    # Nix binary cache (Attic)
      grafana/                  # Dashboard visualization (Grafana)
      envoy/                    # Service proxy (Envoy)
      influxdb/                 # Time-series database (InfluxDB)
      vector/                   # Log/metrics pipeline (Vector)
      ...
```

All NixOS services live under the `blackmatter.components.microservices.*` option namespace. The library layer (`lib/`) provides shared infrastructure that every service module can use.

## Features

- **Dependency resolution** -- declarative service dependency graph with topological sort for startup ordering, circular dependency detection (Kahn's algorithm), and automatic systemd `wants`/`after`/`conflicts` generation
- **Cross-service validation** -- port uniqueness checks across all enabled services, data directory conflict detection, domain format validation, database configuration consistency checks, and SSL certificate path validation
- **Dev/prod mode switching** -- services like PostgreSQL and Traefik ship with curated defaults for both development and production; set `mode = "dev"` or `mode = "prod"` to switch entire configuration profiles
- **Smart warnings** -- alerts for dev mode with production-looking domains, default example.com domains, unencrypted remote database connections, disabled SSL in production mode
- **Base patterns** -- `mkMicroservice` factory for consistent module structure, `mkModeConfig` for dev/prod branching, `mkSystemdService` for hardened systemd units, `mkServiceUser` for service accounts
- **Composite modules** -- `application_reverse_proxy` composes Traefik + Consul + Nomad under a single namespace
- **Home-Manager user services** -- `goomba_user_service` runs services as systemd user units with optional `systemd-nspawn` network isolation

## Installation

Add as a flake input:

```nix
{
  inputs = {
    blackmatter-services = {
      url = "github:pleme-io/blackmatter-services";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

### NixOS module

```nix
{ inputs, ... }: {
  imports = [ inputs.blackmatter-services.nixosModules.default ];
}
```

### Home-Manager module

```nix
{ inputs, ... }: {
  imports = [ inputs.blackmatter-services.homeManagerModules.default ];
}
```

## Usage

### PostgreSQL with dev/prod profiles

```nix
{
  blackmatter.components.microservices = {
    enable = true;
    postgres = {
      enable = true;
      mode = "prod";              # curated production defaults
      port = 5432;
      databases = [ "myapp" ];
      users = [{ name = "myapp"; ensureDBOwnership = true; }];
      authentication = ''
        local all all trust
        host  all all 127.0.0.1/32 md5
      '';
    };
  };
}
```

### Traefik reverse proxy

```nix
{
  blackmatter.components.microservices.traefik = {
    enable = true;
    mode = "prod";
    acmeEmail = "ssl@example.com";
    httpsPort = 443;
  };
}
```

### MinIO object storage

```nix
{
  blackmatter.components.microservices.minio = {
    enable = true;
    dataDir = [ "/data/minio" ];
    listenAddress = ":9000";
    consoleAddress = ":9001";
  };
}
```

### Composite application reverse proxy

```nix
{
  blackmatter.components.microservices.application_reverse_proxy = {
    enable = true;
    namespace = "myapp";
    traefik.enable = true;
    consul.enable = true;
  };
}
```

## Configuration

All services share a common option interface under `blackmatter.components.microservices.<service>`:

| Option | Type | Description |
|--------|------|-------------|
| `enable` | `bool` | Enable the service |
| `port` | `port` | Primary listen port (validated for range and uniqueness) |
| `dataDir` | `str` | Data directory (validated for conflicts) |
| `mode` | `enum` | `"dev"` or `"prod"` (where applicable) |
| `namespace` | `str` | Systemd service name prefix |
| `package` | `package` | Override the service package |

Additional service-specific options are documented in each module file.

## Dependency Graph

The dependency system tracks which services provide and require capabilities:

| Service | Provides | Requires |
|---------|----------|----------|
| `postgres` | `database.postgres` | -- |
| `gitea` | `git.server`, `web.service` | `database.postgres` |
| `mastodon` | `social.server`, `web.service` | `database.postgres`, `database.redis` |
| `traefik` | `reverse_proxy`, `load_balancer` | -- |
| `haproxy` | `reverse_proxy`, `load_balancer` | -- |
| `keycloak` | `auth.server`, `sso` | `database.postgres` |
| `consul` | `service.discovery`, `kv.store` | -- |

Conflicting services (e.g., traefik vs haproxy vs nginx) are automatically detected and produce build-time assertion failures.

## Development

```bash
# Check the flake builds
nix flake check

# Evaluate NixOS module in isolation
nix eval .#nixosModules.default --apply '(m: builtins.typeOf m)'

# Test a service configuration
nix eval --impure --expr '
  let pkgs = import <nixpkgs> {};
  in (pkgs.lib.evalModules {
    modules = [ (import ./module/nixos) { blackmatter.components.microservices.postgres.enable = true; } ];
  }).config
'
```

## Project Structure

```
flake.nix                           # Flake: exports nixosModules + homeManagerModules
module/
  nixos/
    default.nix                     # NixOS module entry point (imports all services)
    lib/
      base.nix                      # Shared types, patterns, helpers
      dependencies.nix              # Dependency graph, topological sort, assertions
      validation.nix                # Validators, enhanced option types, warnings
    postgres/default.nix            # PostgreSQL (dev/prod profiles, backup, monitoring)
    traefik/default.nix             # Traefik (ACME, dev certs, hardened systemd)
    minio/default.nix               # MinIO (object storage)
    consul/default.nix              # Consul (service discovery)
    haproxy/default.nix             # HAProxy (load balancer)
    ...
  home-manager/
    default.nix                     # Home-Manager module entry point
    goomba_user_service/default.nix # Generic user service runner (systemd-nspawn)
    minio/default.nix               # MinIO as user service
    attic/default.nix               # Attic binary cache
    grafana/default.nix             # Grafana dashboards
    ...
```

## Related Projects

- [blackmatter](https://github.com/pleme-io/blackmatter) -- Home-manager/nix-darwin module aggregator that consumes this repo
- [blackmatter-kubernetes](https://github.com/pleme-io/blackmatter-kubernetes) -- Kubernetes tooling and k3s modules
- [substrate](https://github.com/pleme-io/substrate) -- Reusable Nix build patterns
- [k8s](https://github.com/pleme-io/k8s) -- GitOps manifests (FluxCD)

## License

MIT
