# Base microservice module with common patterns
{ lib, config, pkgs, ... }:
with lib;
let
  validation = import ./validation.nix { inherit lib config; };
  dependencies = import ./dependencies.nix { inherit lib config; };
in {
  # Common option types for microservices (enhanced with validation)
  types = {
    # Port option with validation (legacy - for backward compatibility)
    port = mkOption {
      type = types.port;
      description = "Port number for the service (1024-65535 recommended)";
    };
    
    # Enhanced port with validation
    validatedPort = serviceName: validation.enhancedTypes.validatedPort serviceName;
    
    # Data directory option (legacy)
    dataDir = mkOption {
      type = types.str;
      description = "Data directory for the service";
    };
    
    # Enhanced data directory with conflict checking  
    validatedDataDir = serviceName: defaultPath: validation.enhancedTypes.validatedDataDir serviceName defaultPath;
    
    # Host/bind address option
    listenAddress = mkOption {
      type = types.str;
      default = "localhost";
      description = "Address to bind the service to";
    };
    
    # Mode option for dev/prod
    mode = mkOption {
      type = types.enum [ "dev" "prod" ];
      default = "prod";
      description = "Service mode (dev or prod)";
    };
    
    # Enhanced domain with validation
    validatedDomain = serviceName: validation.enhancedTypes.validatedDomain serviceName;
    
    # Enable option (standard across all services)
    mkEnableOption = name: lib.mkEnableOption "Enable ${name} microservice";
    
    # SSL configuration options
    mkSslOptions = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable SSL/TLS";
      };
      
      certificate = mkOption {
        type = types.path;
        default = "/var/lib/acme/default/fullchain.pem";
        description = "Path to SSL certificate";
      };
      
      certificateKey = mkOption {
        type = types.path;
        default = "/var/lib/acme/default/key.pem";
        description = "Path to SSL private key";
      };
      
      acmeHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "ACME host to use for automatic certificates";
      };
    };
    
    # Database configuration options (legacy)
    mkDatabaseOptions = {
      type = mkOption {
        type = types.enum [ "sqlite3" "mysql" "postgres" "redis" ];
        default = "sqlite3";
        description = "Database type";
      };
      
      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "Database host";
      };
      
      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Database port (null for default)";
      };
      
      name = mkOption {
        type = types.str;
        default = "app";
        description = "Database name";
      };
      
      user = mkOption {
        type = types.str;
        default = "app";
        description = "Database user";
      };
      
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing database password";
      };
    };
    
    # Enhanced database configuration with validation
    validatedDatabase = validation.enhancedTypes.validatedDatabase;
  };
  
  # Helper functions
  helpers = {
    # Create a getter function for config values with fallback
    mkConfigGetter = config: name: fallback:
      if config ? ${name} then config.${name} else fallback;
  };
  
  # Common patterns for microservices
  patterns = {
    # Create a standard microservice module structure with validation and dependencies
    mkMicroservice = { name, options ? {}, config ? {} }:
      let
        cfg = config.blackmatter.components.microservices.${name};
        assertions = validation.mkMicroserviceAssertions name cfg;
        warnings = validation.mkServiceWarnings name cfg;
        depAssertions = dependencies.mkDependencyAssertions config;
        depWarnings = dependencies.mkDependencyWarnings config;
        systemdDeps = dependencies.generateSystemdDeps name config;
      in {
        options.blackmatter.components.microservices.${name} = mkMerge [
          {
            enable = mkEnableOption name;
          }
          options
        ];
        
        config = mkIf cfg.enable (mkMerge [
          # Add assertions and warnings
          {
            assertions = assertions ++ depAssertions;
            warnings = warnings ++ depWarnings;
          }
          # Add systemd dependencies
          {
            systemd.services.${name} = mkMerge [
              systemdDeps
              (config.systemd.services.${name} or {})
            ];
          }
          config
        ]);
      };
      
    # Create development/production mode pattern
    mkModeConfig = { cfg, devDefaults, prodDefaults, extraConfig ? {} }:
      mkMerge [
        (if cfg.mode == "dev" then devDefaults else prodDefaults)
        extraConfig
      ];
  };
  
  # Common service configurations
  services = {
    # Systemd service template with dependency resolution
    mkSystemdService = { name, description, exec, user ? name, group ? name, ... }@args:
      let
        systemdDeps = dependencies.generateSystemdDeps name config;
      in {
        description = description;
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ] ++ (systemdDeps.after or []);
        wants = systemdDeps.wants or [];
        conflicts = systemdDeps.conflicts or [];
        serviceConfig = {
          Type = "simple";
          User = user;
          Group = group;
          ExecStart = exec;
          Restart = "on-failure";
          RestartSec = "5s";
        } // (args.serviceConfig or {});
      };
      
    # Create user and group for a service
    mkServiceUser = { name, group ? name, home ? "/var/lib/${name}", description ? "${name} service user" }:
      {
        users.${name} = {
          isSystemUser = true;
          inherit group home description;
          createHome = true;
        };
        groups.${group} = {};
      };
  };
}