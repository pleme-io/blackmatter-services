{
  lib,
  config,
  pkgs,
  ...
}:
with lib;
let
  base = import ../lib/base.nix { inherit lib config pkgs; };
  cfg = config.blackmatter.components.microservices.haproxy;
  
  # Development defaults
  devDefaults = {
    global = {
      maxconn = 256;
      log = "127.0.0.1 local0";
      daemon = false;
    };
    defaults = {
      mode = "http";
      timeout = {
        connect = "5000ms";
        client = "50000ms";
        server = "50000ms";
      };
      option = [ "httplog" ];
    };
    frontend = {
      main = {
        bind = "*:${toString cfg.port}";
        default_backend = "servers";
      };
    };
    backend = {
      servers = {
        balance = "roundrobin";
        server = [ "server1 127.0.0.1:8080 check" ];
      };
    };
  };
  
  # Production defaults
  prodDefaults = {
    global = {
      maxconn = 4096;
      log = "/dev/log local0";
      daemon = true;
      stats = {
        socket = "/run/haproxy/admin.sock mode 660 level admin";
        timeout = "30s";
      };
    };
    defaults = {
      mode = "http";
      log = "global";
      option = [ "httplog" "dontlognull" "redispatch" ];
      retries = 3;
      timeout = {
        connect = "5000ms";
        client = "1m";
        server = "1m";
        check = "10s";
      };
      errorfile = {
        "400" = "/etc/haproxy/errors/400.http";
        "403" = "/etc/haproxy/errors/403.http";
        "404" = "/etc/haproxy/errors/404.http";
        "408" = "/etc/haproxy/errors/408.http";
        "500" = "/etc/haproxy/errors/500.http";
        "502" = "/etc/haproxy/errors/502.http";
        "503" = "/etc/haproxy/errors/503.http";
        "504" = "/etc/haproxy/errors/504.http";
      };
    };
    frontend = cfg.frontends;
    backend = cfg.backends;
  };
  
  # Final configuration based on mode
  finalConfig = base.patterns.mkModeConfig {
    inherit cfg devDefaults prodDefaults;
    extraConfig = cfg.extraConfig;
  };
  
  # Convert nix config to HAProxy format
  configToHAProxy = config: let
    renderValue = value:
      if isList value then concatStringsSep " " (map toString value)
      else if isAttrs value then 
        concatStringsSep "\n    " (mapAttrsToList (k: v: "${k} ${renderValue v}") value)
      else toString value;
    
    renderSection = name: attrs:
      "${name}\n" +
      concatStringsSep "\n" (mapAttrsToList (k: v: "    ${k} ${renderValue v}") attrs);
  in
    concatStringsSep "\n\n" (mapAttrsToList renderSection config);
in {
  options.blackmatter.components.microservices.haproxy = {
    enable = base.types.mkEnableOption "haproxy";
    port = base.types.port // { default = 80; };
    dataDir = base.types.dataDir // { default = "/var/lib/haproxy"; };
    mode = base.types.mode;
    
    configFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to custom HAProxy configuration file (overrides all other settings)";
    };
    
    frontends = mkOption {
      type = types.attrsOf types.attrs;
      default = {};
      description = "Frontend configurations for production mode";
    };
    
    backends = mkOption {
      type = types.attrsOf types.attrs;
      default = {};
      description = "Backend configurations for production mode";
    };
    
    extraConfig = mkOption {
      type = types.attrs;
      default = {};
      description = "Extra HAProxy configuration";
    };
    
    package = mkOption {
      type = types.package;
      default = pkgs.haproxy;
      description = "HAProxy package to use";
    };
    
    # DNS configuration options
    dnsEnabled = mkOption {
      type = types.bool;
      default = false;
      description = "Enable DNS configuration for HAProxy";
    };
    
    host = mkOption {
      type = types.str;
      default = "haproxy";
      description = "Hostname for HAProxy";
    };
    
    domain = mkOption {
      type = types.str;
      default = "local";
      description = "Domain for HAProxy";
    };
    
    localIp = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Local IP address for HAProxy";
    };
    
    dnsServer = mkOption {
      type = types.str;
      default = "8.8.8.8";
      description = "DNS server to use";
    };
  };
  
  config = mkIf cfg.enable {
    # Create haproxy user
    users = base.services.mkServiceUser {
      name = "haproxy";
      home = cfg.dataDir;
      description = "HAProxy service user";
    };
    
    # Ensure directories exist
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 haproxy haproxy -"
      "d /run/haproxy 0750 haproxy haproxy -"
      "d /etc/haproxy/errors 0755 root root -"
    ];
    
    # Configure HAProxy
    services.haproxy = {
      enable = true;
      config = if cfg.configFile != null
        then builtins.readFile cfg.configFile
        else configToHAProxy finalConfig;
    };
    
    # Configure DNS if enabled
    services.dnsmasq = mkIf cfg.dnsEnabled {
      enable = true;
      resolveLocalQueries = true;
      settings = {
        address = [ "/${cfg.host}.${cfg.domain}/${cfg.localIp}" ];
        server = [ cfg.dnsServer ];
      };
    };
    
    # Open firewall ports
    networking.firewall.allowedTCPPorts = [ cfg.port ] ++ 
      (if cfg.mode == "prod" then [ 443 ] else []);
  };
}