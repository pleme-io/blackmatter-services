{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  base = import ../lib/base.nix { inherit lib config pkgs; };
  cfg = config.blackmatter.components.microservices.traefik;
  
  # Development defaults
  devDefaults = {
    api = {
      insecure = true;
      dashboard = true;
    };
    entryPoints = {
      traefik = {
        address = ":8081";
      };
      web = {
        address = ":8080";
      };
      websecure = {
        address = ":8443";
        http.tls = true;
      };
    };
    log = {
      level = "DEBUG";
    };
  };
  
  # Production defaults
  prodDefaults = {
    api = {
      insecure = false;
      dashboard = false;
    };
    entryPoints = {
      web = {
        address = ":80";
        http.redirections.entryPoint = {
          to = "websecure";
          scheme = "https";
        };
      };
      websecure = {
        address = ":443";
        http.tls = {
          certResolver = "default";
        };
      };
    };
    log = {
      level = "ERROR";
    };
    certificatesResolvers.default.acme = {
      email = cfg.acmeEmail;
      storage = "/var/lib/traefik/acme.json";
      httpChallenge.entryPoint = "web";
    };
  };
  
  # Final configuration
  finalConfig = base.patterns.mkModeConfig {
    inherit cfg devDefaults prodDefaults;
    extraConfig = cfg.extraConfig;
  };
  
  # Get config value
  get = base.helpers.mkConfigGetter finalConfig;
  
  # Generate self-signed certificates for development
  devCerts = pkgs.runCommand "traefik-dev-certs" {
    buildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out
    
    # Generate self-signed certificate for *.local
    openssl req -x509 -newkey rsa:4096 -nodes \
      -keyout $out/key.pem \
      -out $out/cert.pem \
      -days 365 \
      -subj "/CN=*.local"
  '';
in {
  options.blackmatter.components.microservices.traefik = {
    enable = base.types.mkEnableOption "traefik";
    # Use enhanced validation for port - will validate range and uniqueness
    port = base.types.validatedPort "traefik" // { default = 80; };
    # Use enhanced validation for dataDir - will check for conflicts
    dataDir = base.types.validatedDataDir "traefik" "/var/lib/traefik";
    mode = base.types.mode;
    
    namespace = mkOption {
      type = types.str;
      default = "default";
      description = "Namespace for the Traefik service";
    };
    
    # Enhanced email validation for ACME
    acmeEmail = mkOption {
      type = types.strMatching "^[^@]+@[^@]+\\.[^@]+$";
      default = "admin@example.com";  
      description = "Valid email address for ACME certificate generation";
      example = "ssl-admin@yourdomain.com";
    };
    
    # Additional ports for Traefik (API, secure)
    apiPort = mkOption {
      type = types.port;
      default = 8081;
      description = "Port for Traefik API/Dashboard";
    };
    
    httpsPort = mkOption {
      type = types.port;
      default = 443;
      description = "Port for HTTPS traffic";
    };
    
    extraConfig = mkOption {
      type = types.attrs;
      default = {};
      description = "Extra Traefik configuration";
    };
    
    package = mkOption {
      type = types.package;
      default = pkgs.traefik;
      description = "Traefik package to use";
    };
  };
  
  config = mkIf cfg.enable (mkMerge [
    # Service dependency assertions and warnings  
    (base.patterns.mkMicroservice {
      name = "traefik";
      options = {};
      config = {};
    }).config
    
    # Validation and warnings
    {
      assertions = [
        {
          assertion = cfg.port != cfg.apiPort && cfg.port != cfg.httpsPort && cfg.apiPort != cfg.httpsPort;
          message = "Traefik ports must be unique: main=${toString cfg.port}, api=${toString cfg.apiPort}, https=${toString cfg.httpsPort}";
        }
        {
          assertion = cfg.port >= 1024 || cfg.port == 80 || cfg.port == 443;
          message = "Traefik main port ${toString cfg.port} should be 80, 443, or >= 1024";
        }
        {
          assertion = !(cfg.mode == "prod" && cfg.acmeEmail == "admin@example.com");
          message = "Traefik in production mode requires a real email address for ACME, not the default";
        }
      ];
      
      warnings = [
        (mkIf (cfg.mode == "dev" && cfg.port == 443) 
          "Traefik using port 443 in dev mode - may conflict with other services")
        (mkIf (cfg.mode == "prod" && cfg.apiPort == 8081)
          "Traefik API port 8081 is commonly used - consider changing for production security")  
      ];
    }
    
    # Main configuration
    {
    # Create traefik user
    users = base.services.mkServiceUser {
      name = "traefik";
      home = cfg.dataDir;
      description = "Traefik service user";
    };
    
    # Ensure data directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 traefik traefik -"
    ];
    
    # Configuration files
    environment.etc = {
      "traefik/traefik.yml".text = builtins.toJSON finalConfig;
    } // optionalAttrs (cfg.mode == "dev") {
      "traefik/certs/cert.pem".source = "${devCerts}/cert.pem";
      "traefik/certs/key.pem".source = "${devCerts}/key.pem";
    };
    
    # Create systemd service
    systemd.services."${cfg.namespace}-traefik" = base.services.mkSystemdService {
      name = "traefik";
      description = "Traefik reverse proxy and load balancer";
      exec = "${cfg.package}/bin/traefik --configfile=/etc/traefik/traefik.yml";
      user = "traefik";
      group = "traefik";
      serviceConfig = {
        AmbientCapabilities = "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
        NoNewPrivileges = true;
        LimitNPROC = 512;
        LimitNOFILE = 1048576;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "full";
        ReadWritePaths = [ cfg.dataDir ];
      };
    };
    
    # Open firewall ports
    networking.firewall.allowedTCPPorts = mkIf (cfg.mode == "prod") [ 80 443 ];
    
    # Development mode: configure dnsmasq for *.local
    services.dnsmasq = mkIf (cfg.mode == "dev") {
      enable = true;
      settings = {
        address = [ "/local/127.0.0.1" ];
      };
    };
    }
  ]);
}