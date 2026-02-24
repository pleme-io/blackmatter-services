{
  lib,
  config,
  pkgs,
  ...
}:
with lib;
let
  base = import ../lib/base.nix { inherit lib config pkgs; };
  cfg = config.blackmatter.components.microservices.gitea;
  
  # Development defaults
  devDefaults = {
    server = {
      DOMAIN = "localhost";
      HTTP_PORT = 3000;
      ROOT_URL = "http://localhost:3000/";
      OFFLINE_MODE = true;
    };
    session = {
      COOKIE_SECURE = false;
    };
    service = {
      DISABLE_REGISTRATION = false;
      ENABLE_NOTIFY_MAIL = false;
    };
    log = {
      LEVEL = "Debug";
    };
  };
  
  # Production defaults
  prodDefaults = {
    server = {
      DOMAIN = cfg.domain;
      HTTP_PORT = cfg.port;
      ROOT_URL = "https://${cfg.domain}/";
      OFFLINE_MODE = false;
      ENABLE_GZIP = true;
    };
    session = {
      COOKIE_SECURE = true;
      SESSION_LIFE_TIME = 86400;
    };
    service = {
      DISABLE_REGISTRATION = true;
      ENABLE_NOTIFY_MAIL = true;
      ENABLE_CAPTCHA = true;
    };
    security = {
      MIN_PASSWORD_LENGTH = 8;
      PASSWORD_COMPLEXITY = "lower,upper,digit,spec";
    };
    log = {
      LEVEL = "Error";
    };
    cache = {
      ENABLED = true;
      ADAPTER = "memory";
      INTERVAL = 60;
    };
  };
  
  # Final configuration
  finalConfig = base.patterns.mkModeConfig {
    inherit cfg devDefaults prodDefaults;
    extraConfig = cfg.extraSettings;
  };
  
  # Database configuration based on base patterns
  dbConfig = if cfg.database.type == "sqlite3" then {
    type = "sqlite3";
    path = "${cfg.dataDir}/data/gitea.db";
  } else {
    type = cfg.database.type;
    host = cfg.database.host;
    name = cfg.database.name;
    user = cfg.database.user;
    port = cfg.database.port;
  };
in {
  options.blackmatter.components.microservices.gitea = {
    enable = base.types.mkEnableOption "gitea";
    port = base.types.port // { default = 3000; };
    dataDir = base.types.dataDir // { default = "/var/lib/gitea"; };
    mode = base.types.mode;
    
    namespace = mkOption {
      type = types.str;
      default = "git";
      description = "Logical namespace for Gitea instance";
    };
    
    domain = mkOption {
      type = types.str;
      default = "git.example.com";
      description = "Domain name for Gitea (used in production mode)";
    };
    
    database = base.types.mkDatabaseOptions // {
      type = mkOption {
        type = types.enum [ "sqlite3" "mysql" "postgres" ];
        default = "sqlite3";
        description = "Database type";
      };
    };
    
    ssl = base.types.mkSslOptions;
    
    lfs = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Git LFS support";
      };
      
      contentPath = mkOption {
        type = types.str;
        default = "${cfg.dataDir}/lfs";
        description = "Path for LFS content storage";
      };
    };
    
    ssh = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable SSH access";
      };
      
      port = mkOption {
        type = types.port;
        default = 2222;
        description = "SSH port for git operations";
      };
    };
    
    extraSettings = mkOption {
      type = types.attrs;
      default = {};
      description = "Extra Gitea settings to merge";
    };
    
    package = mkOption {
      type = types.package;
      default = pkgs.gitea;
      description = "Gitea package to use";
    };
  };
  
  config = mkIf cfg.enable (mkMerge [
    # Service dependency assertions and warnings
    (base.patterns.mkMicroservice {
      name = "gitea";
      options = {};
      config = {};
    }).config
    
    {
      # Configure the main Gitea service
      services.gitea = {
        enable = true;
        inherit (cfg) package stateDir;
        database = dbConfig;
        lfs.enable = cfg.lfs.enable;
        settings = finalConfig // {
          repository = {
            ROOT = "${cfg.dataDir}/repositories";
          };
          lfs = mkIf cfg.lfs.enable {
            PATH = cfg.lfs.contentPath;
          };
          server = (finalConfig.server or {}) //
            (optionalAttrs cfg.ssh.enable {
              START_SSH_SERVER = true;
              SSH_PORT = cfg.ssh.port;
              SSH_LISTEN_PORT = cfg.ssh.port;
            }) //
            (optionalAttrs (cfg.mode == "prod" && cfg.ssl.enable) {
              PROTOCOL = "https";
              CERT_FILE = cfg.ssl.certificate;
              KEY_FILE = cfg.ssl.certificateKey;
            });
        };
      };
    
    # Create gitea user
    users = base.services.mkServiceUser {
      name = "gitea";
      home = cfg.dataDir;
      description = "Gitea service user";
    };
    
    # Ensure directories exist
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 gitea gitea -"
      "d ${cfg.dataDir}/custom 0750 gitea gitea -"
      "d ${cfg.dataDir}/custom/conf 0750 gitea gitea -"
      "d ${cfg.dataDir}/data 0750 gitea gitea -"
      "d ${cfg.dataDir}/repositories 0750 gitea gitea -"
    ] ++ optional cfg.lfs.enable
      "d ${cfg.lfs.contentPath} 0750 gitea gitea -";
    
    # Firewall configuration
    networking.firewall = {
      allowedTCPPorts = [ cfg.port ] ++ 
        optional cfg.ssh.enable cfg.ssh.port ++
        optional (cfg.mode == "prod") 443;
    };
    
    # Database automation
    services.mysql = mkIf (cfg.database.type == "mysql") {
      enable = true;
      package = mkDefault pkgs.mariadb;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [{
        name = cfg.database.user;
        ensurePermissions = { 
          "${cfg.database.name}.*" = "ALL PRIVILEGES"; 
        };
      }];
    };
    
    services.postgresql = mkIf (cfg.database.type == "postgres") {
      enable = true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [{
        name = cfg.database.user;
        ensureDBOwnership = true;
      }];
    };
    
      # Backup configuration for production
      services.restic.backups = mkIf (cfg.mode == "prod") {
        gitea = {
          paths = [ cfg.dataDir ];
          repository = "/backup/gitea";
          passwordFile = "/etc/restic/gitea-password";
          timerConfig = {
            OnCalendar = "daily";
          };
        };
      };
    }
  ]);
}