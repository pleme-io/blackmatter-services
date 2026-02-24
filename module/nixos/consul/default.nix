# Refactored Consul module using base patterns
{ lib, config, pkgs, ... }:
with lib;
let
  base = import ../lib/base.nix { inherit lib config pkgs; };
  cfg = config.blackmatter.components.microservices.consul;
  
  # Dev/prod configurations
  devDefaults = {
    bind_addr = "127.0.0.1";
    server = false;
    data_dir = "/tmp/consul";
    ui = true;
  };
  
  prodDefaults = {
    bind_addr = "0.0.0.0";
    server = true;
    data_dir = "/var/lib/consul";
    ui = false;
  };
  
  # Final configuration
  finalConfig = base.patterns.mkModeConfig {
    inherit cfg devDefaults prodDefaults;
    extraConfig = mkMerge [
      cfg.extraConfig
      {
        ports = {
          http = cfg.port;
        };
      }
    ];
  };
  
  # Helper to get config value
  get = name: fallback:
    if finalConfig ? ${name} then finalConfig.${name} else fallback;
    
  # Command generation
  defaultDevCommand = ''
    ${cfg.package}/bin/consul agent -dev \
      -bind=${get "bind_addr" "127.0.0.1"} \
      --data-dir=${get "data_dir" "/tmp/consul"} \
      --ui
  '';
  
  defaultProdCommand = ''
    ${cfg.package}/bin/consul agent -server \
      -bind=${get "bind_addr" "0.0.0.0"} \
      -config-dir=/etc/consul.d \
      --data-dir=${get "data_dir" "/var/lib/consul"}
  '';
  
  finalCommand = if cfg.command != "" then cfg.command
    else if cfg.mode == "dev" then defaultDevCommand
    else defaultProdCommand;
in
{
  options.blackmatter.components.microservices.consul = {
    enable = base.types.mkEnableOption "Consul service discovery";
    mode = base.types.mode;
    
    namespace = mkOption {
      type = types.str;
      default = "consul";
      description = "Namespace for the Consul service";
    };
    
    package = mkOption {
      type = types.package;
      default = pkgs.consul;
      description = "Consul package to use";
    };
    
    port = mkOption {
      type = types.port;
      default = 8500;
      description = "HTTP API port";
    };
    
    command = mkOption {
      type = types.str;
      default = "";
      description = "Override the default command";
    };
    
    extraConfig = mkOption {
      type = types.attrs;
      default = {};
      description = "Additional Consul configuration";
    };
  };
  
  config = mkIf cfg.enable {
    systemd.services."${cfg.namespace}-consul" = base.services.mkSystemdService {
      name = "${cfg.namespace}-consul";
      description = "Consul Service Discovery";
      exec = finalCommand;
      user = "consul";
      group = "consul";
      serviceConfig = {
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        KillMode = "process";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
    
    users.users.consul = {
      isSystemUser = true;
      group = "consul";
      home = get "data_dir" "/var/lib/consul";
      createHome = true;
    };
    
    users.groups.consul = {};
    
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}