# Refactored Cockpit module using base patterns
{ lib, config, pkgs, ... }:
with lib;
let
  base = import ../lib/base.nix { inherit lib config pkgs; };
  cfg = config.blackmatter.components.microservices.cockpit;
in
{
  options.blackmatter.components.microservices.cockpit = {
    enable = base.types.mkEnableOption "Cockpit web-based server management";
    
    namespace = mkOption {
      type = types.str;
      default = "management";
      description = "Logical namespace for Cockpit instance";
    };
    
    package = mkOption {
      type = types.package;
      default = pkgs.cockpit;
      description = "Cockpit package to use";
    };
    
    port = mkOption {
      type = types.port;
      default = 9090;
      description = "Web interface port";
    };
    
    ssl = base.types.mkSslOptions;
    
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall port for Cockpit";
    };
    
    allowedOrigins = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of allowed origins for Cockpit";
    };
  };
  
  config = mkIf cfg.enable {
    services.cockpit = {
      enable = true;
      port = cfg.port;
      openFirewall = cfg.openFirewall;
      settings = {
        WebService = {
          Origins = lib.concatStringsSep " " cfg.allowedOrigins;
          ProtocolHeader = "X-Forwarded-Proto";
          LoginTitle = cfg.namespace;
        } // (if cfg.ssl.enable then {
          Certificate = cfg.ssl.certificate;
          Key = cfg.ssl.certificateKey;
        } else {});
      };
    };
    
    # ACME certificate if specified
    security.acme.certs = mkIf (cfg.ssl.enable && cfg.ssl.acmeHost != null) {
      "${cfg.ssl.acmeHost}" = {
        postRun = "systemctl restart cockpit";
      };
    };
    
    # Additional firewall rules if needed
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };
  };
}