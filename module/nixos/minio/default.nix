# Refactored MinIO module using base patterns
{ lib, config, pkgs, ... }:
with lib;
let
  base = import ../lib/base.nix { inherit lib config pkgs; };
  cfg = config.blackmatter.components.microservices.minio;
in
{
  options.blackmatter.components.microservices.minio = {
    enable = base.types.mkEnableOption "MinIO object storage";
    
    dataDir = mkOption {
      type = types.listOf types.str;
      default = [ "/var/lib/minio" ];
      description = "Data directories for MinIO storage";
    };
    
    rootCredentialsFile = mkOption {
      type = types.package;
      default = pkgs.writeText "creds" ''
        MINIO_ROOT_USER=admin
        MINIO_ROOT_PASSWORD=letmein1234!
      '';
      description = "File containing root credentials";
    };
    
    host = mkOption {
      type = types.str;
      default = "minio";
      description = "Hostname for MinIO";
    };
    
    listenAddress = mkOption {
      type = types.str;
      default = ":9000";
      description = "Listen address for MinIO API";
    };
    
    consoleAddress = mkOption {
      type = types.str;
      default = ":9001";
      description = "Listen address for MinIO console";
    };
  };
  
  config = mkIf cfg.enable {
    services.minio = {
      enable = true;
      dataDir = cfg.dataDir;
      rootCredentialsFile = cfg.rootCredentialsFile;
      listenAddress = cfg.listenAddress;
      consoleAddress = cfg.consoleAddress;
    };
    
    networking.hosts = {
      "127.0.0.1" = [ cfg.host ];
    };
    
    networking.firewall.allowedTCPPorts = [ 9000 9001 ];
  };
}