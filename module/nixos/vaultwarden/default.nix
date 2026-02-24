# Vaultwarden module with nginx reverse proxy, self-signed certs, and backups
{ lib, config, pkgs, ... }:
with lib;
let
  base = import ../lib/base.nix { inherit lib config pkgs; };
  cfg = config.blackmatter.components.microservices.vaultwarden;

  # Common vaultwarden settings with sensible defaults
  defaultSettings = {
    SIGNUPS_ALLOWED = false;
    INVITATIONS_ALLOWED = true;
    SHOW_PASSWORD_HINT = false;
    WEB_VAULT_ENABLED = true;
    ENABLE_DB_WAL = true;
    LOG_LEVEL = "info";
  };
in
{
  options.blackmatter.components.microservices.vaultwarden = {
    enable = base.types.mkEnableOption "Vaultwarden password manager";

    namespace = mkOption {
      type = types.str;
      default = "vaultwarden";
      description = "Logical namespace for vaultwarden instance";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.vaultwarden;
      description = "Vaultwarden package to use";
    };

    port = mkOption {
      type = types.port;
      default = 8222;
      description = "Port for Vaultwarden web interface";
    };

    domain = mkOption {
      type = types.str;
      default = "";
      description = "Domain for Vaultwarden instance (e.g., 'vault.example.local')";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/vaultwarden";
      description = "Data directory for Vaultwarden";
    };

    database = base.types.mkDatabaseOptions // {
      type = mkOption {
        type = types.enum [ "sqlite3" "mysql" "postgres" ];
        default = "sqlite3";
        description = "Database type for Vaultwarden";
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open firewall port for Vaultwarden";
    };

    nginx = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable nginx reverse proxy with TLS for Vaultwarden";
      };

      selfSignedCert = mkOption {
        type = types.bool;
        default = true;
        description = "Generate a self-signed certificate (for .local domains)";
      };
    };

    backup = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable automatic daily backups";
      };

      directory = mkOption {
        type = types.path;
        default = "/var/backup/vaultwarden";
        description = "Backup directory for Vaultwarden";
      };

      retention = mkOption {
        type = types.int;
        default = 7;
        description = "Number of backups to retain";
      };
    };

    settings = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = "Additional Vaultwarden configuration settings";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.nginx.enable -> cfg.domain != "";
        message = "blackmatter.components.microservices.vaultwarden.domain must be set when nginx is enabled";
      }
    ];

    # Vaultwarden service
    services.vaultwarden = {
      enable = true;
      inherit (cfg) package;
      config = mkMerge [
        defaultSettings
        {
          DOMAIN = if cfg.domain != "" then "https://${cfg.domain}" else "";
          ROCKET_ADDRESS = "0.0.0.0";
          ROCKET_PORT = cfg.port;
          WEBSOCKET_ENABLED = true;
          WEBSOCKET_ADDRESS = "0.0.0.0";
          WEBSOCKET_PORT = cfg.port + 1;
          DATA_FOLDER = cfg.dataDir;
          LOG_FILE = "${cfg.dataDir}/vaultwarden.log";
          # Database configuration
          DATABASE_URL = if cfg.database.type == "sqlite3"
            then "${cfg.dataDir}/db.sqlite3"
            else if cfg.database.type == "mysql"
            then "mysql://${cfg.database.user}@${cfg.database.host}/${cfg.database.name}"
            else "postgresql://${cfg.database.user}@${cfg.database.host}/${cfg.database.name}";
        }
        cfg.settings
      ];
    };

    # Nginx reverse proxy
    services.nginx = mkIf cfg.nginx.enable {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;

      virtualHosts."${cfg.domain}" = {
        forceSSL = true;
        enableACME = false;
        sslCertificate = "/etc/ssl/certs/vault.crt";
        sslCertificateKey = "/etc/ssl/private/vault.key";

        locations."/" = {
          proxyPass = "http://localhost:${toString cfg.port}";
          proxyWebsockets = true;
          extraConfig = ''
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header X-XSS-Protection "1; mode=block" always;
            add_header Referrer-Policy "same-origin" always;
            client_max_body_size 128M;
          '';
        };

        locations."/notifications/hub" = {
          proxyPass = "http://localhost:${toString (cfg.port + 1)}";
          proxyWebsockets = true;
        };

        locations."/notifications/hub/negotiate" = {
          proxyPass = "http://localhost:${toString cfg.port}";
        };
      };
    };

    # Self-signed certificate generation
    systemd.services.vault-cert = mkIf (cfg.nginx.enable && cfg.nginx.selfSignedCert) {
      description = "Generate self-signed certificate for Vaultwarden";
      wantedBy = [ "nginx.service" ];
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /etc/ssl/certs /etc/ssl/private
        if [ ! -f /etc/ssl/certs/vault.crt ]; then
          ${pkgs.openssl}/bin/openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/ssl/private/vault.key \
            -out /etc/ssl/certs/vault.crt \
            -subj "/CN=${cfg.domain}"
        fi
      '';
    };

    # Backup service
    systemd.services.vaultwarden-backup = mkIf cfg.backup.enable {
      description = "Backup Vaultwarden data";
      serviceConfig = {
        Type = "oneshot";
        User = "vaultwarden";
        Group = "vaultwarden";
      };
      script = ''
        mkdir -p ${cfg.backup.directory}
        cd ${cfg.dataDir}
        systemctl stop vaultwarden
        ${pkgs.gnutar}/bin/tar -czf ${cfg.backup.directory}/vaultwarden-$(date +%Y%m%d-%H%M%S).tar.gz .
        ls -t ${cfg.backup.directory}/vaultwarden-*.tar.gz | tail -n +${toString (cfg.backup.retention + 1)} | xargs rm -f
        systemctl start vaultwarden
      '';
    };

    systemd.timers.vaultwarden-backup = mkIf cfg.backup.enable {
      description = "Vaultwarden backup timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    # Firewall
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port (cfg.port + 1) ]
        ++ optionals cfg.nginx.enable [ 80 443 ];
    };

    # Create data and backup directories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 vaultwarden vaultwarden -"
    ] ++ optionals cfg.backup.enable [
      "d ${cfg.backup.directory} 0700 vaultwarden vaultwarden -"
    ];
  };
}
