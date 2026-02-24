{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  base = import ../lib/base.nix { inherit lib config pkgs; };
  cfg = config.blackmatter.components.microservices.postgres;
  
  # Development defaults
  devDefaults = {
    listen_addresses = "localhost";
    port = 5432;
    max_connections = 20;
    shared_buffers = "128MB";
    wal_level = "minimal";
    checkpoint_completion_target = 0.5;
    wal_buffers = "16MB";
    default_statistics_target = 100;
    log_statement = "all";
    log_min_duration_statement = 0;
    log_line_prefix = "%t [%p-%l] %q%u@%d ";
  };
  
  # Production defaults
  prodDefaults = {
    listen_addresses = "*";
    port = 5432;
    max_connections = 100;
    shared_buffers = "256MB";
    effective_cache_size = "1GB";
    maintenance_work_mem = "64MB";
    checkpoint_completion_target = 0.7;
    wal_buffers = "16MB";
    default_statistics_target = 100;
    random_page_cost = 1.1;
    effective_io_concurrency = 200;
    work_mem = "4MB";
    min_wal_size = "1GB";
    max_wal_size = "4GB";
    log_min_duration_statement = 1000;
    log_checkpoints = true;
    log_connections = true;
    log_disconnections = true;
    log_lock_waits = true;
    log_temp_files = 0;
    log_autovacuum_min_duration = 0;
    log_error_verbosity = "terse";
    log_line_prefix = "%t [%p-%l] %q%u@%d ";
  };
  
  # Final configuration
  finalConfig = base.patterns.mkModeConfig {
    inherit cfg devDefaults prodDefaults;
    extraConfig = cfg.extraConfig;
  };
  
  # Get config value
  get = base.helpers.mkConfigGetter finalConfig;
  
  # Generate postgresql.conf content
  postgresqlConf = concatStringsSep "\n" (
    mapAttrsToList (name: value: "${name} = ${toString value}") finalConfig
  );
in {
  options.blackmatter.components.microservices.postgres = {
    enable = base.types.mkEnableOption "postgres";
    port = base.types.port // { default = 5432; };
    dataDir = base.types.dataDir // { default = "/var/lib/postgresql"; };
    mode = base.types.mode;
    
    namespace = mkOption {
      type = types.str;
      default = "default";
      description = "Namespace for the PostgreSQL systemd service name";
    };
    
    databases = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of databases to create automatically";
    };
    
    users = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Username";
          };
          
          ensureDBOwnership = mkOption {
            type = types.bool;
            default = false;
            description = "Grant ownership of databases with matching names";
          };
          
          ensurePermissions = mkOption {
            type = types.attrsOf types.str;
            default = {};
            description = "Permissions to grant";
          };
        };
      });
      default = [];
      description = "List of users to create automatically";
    };
    
    extraConfig = mkOption {
      type = types.attrs;
      default = {};
      description = "Extra PostgreSQL configuration";
    };
    
    package = mkOption {
      type = types.package;
      default = pkgs.postgresql_15;
      description = "PostgreSQL package to use";
    };
    
    authentication = mkOption {
      type = types.lines;
      default = "";
      description = "Contents of pg_hba.conf authentication file";
    };
    
    identMap = mkOption {
      type = types.lines;
      default = "";
      description = "Contents of pg_ident.conf identification file";
    };
    
    initialScript = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "SQL script to run on first startup";
    };
  };
  
  config = mkIf cfg.enable (mkMerge [
    # Service dependency assertions and warnings  
    (base.patterns.mkMicroservice {
      name = "postgres";
      options = {};
      config = {};
    }).config
    
    {
    # Use NixOS's built-in PostgreSQL service
    services.postgresql = {
      enable = true;
      inherit (cfg) package dataDir;
      
      port = cfg.port;
      
      # Configuration
      settings = finalConfig;
      
      # Ensure databases
      ensureDatabases = cfg.databases;
      
      # Ensure users
      ensureUsers = cfg.users;
      
      # Authentication configuration
      authentication = mkIf (cfg.authentication != "") cfg.authentication;
      identMap = mkIf (cfg.identMap != "") cfg.identMap;
      initialScript = cfg.initialScript;
    };
    
    # Create postgres user using base patterns
    users = base.services.mkServiceUser {
      name = "postgres";
      group = "postgres";
      home = cfg.dataDir;
      description = "PostgreSQL server user";
    };
    
    # Firewall configuration
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    
    # Backup configuration for production
    services.postgresqlBackup = mkIf (cfg.mode == "prod") {
      enable = true;
      databases = cfg.databases;
      startAt = "*-*-* 01:15:00";
      location = "/backup/postgresql";
      pgdumpOptions = "-Cc";
    };
    
    # Performance tuning for production
    boot.kernel.sysctl = mkIf (cfg.mode == "prod") {
      # Increase shared memory for PostgreSQL
      "kernel.shmmax" = 268435456;
      "kernel.shmall" = 2097152;
      
      # Network tuning
      "net.core.rmem_default" = 262144;
      "net.core.rmem_max" = 16777216;
      "net.core.wmem_default" = 262144;
      "net.core.wmem_max" = 16777216;
    };
    
    # Monitoring for production
    services.prometheus.exporters.postgres = mkIf (cfg.mode == "prod") {
      enable = true;
      dataSourceName = "user=prometheus host=/run/postgresql sslmode=disable";
    };
    
    # Log rotation
    services.logrotate.settings.postgresql = {
      files = [ "/var/log/postgresql/*.log" ];
      frequency = "daily";
      rotate = 10;
      copytruncate = true;
      compress = true;
      notifempty = true;
    };
    }
  ]);
}