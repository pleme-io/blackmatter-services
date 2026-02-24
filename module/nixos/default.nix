{
  lib,
  config,
  # pkgs,
  ...
}:
with lib; let
  cfg = config.blackmatter.components.microservices;
in {
  imports = [
    ./application_reverse_proxy
    ./supervisord
    
    # Refactored services using base patterns (tested and working)
    ./minio
    ./consul
    ./cockpit
    ./vaultwarden
    ./traefik
    ./haproxy
    ./gitea
    ./postgres
    
    # Other services (commented out until attribute conflicts resolved)
    # ./jitsi
    # ./home-assistant
    # ./fractal
    # ./element-desktop
    # ./sogo
    # ./proxysql
    # ./nomad
    # ./matrix-synapse
    # ./matomo
    # ./mastodon
    # ./lamb
    # ./keycloak
  ];

  options = {
    blackmatter = {
      components = {
        microservices = {
          enable = mkEnableOption "microservices";
        };
      };
    };
  };

  # in case we do find anything global about microservices
  config = mkMerge [
    (mkIf cfg.enable {})
  ];
}
