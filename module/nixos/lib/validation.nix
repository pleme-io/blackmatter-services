# Validation helpers for blackmatter components
{ lib, config, ... }:
with lib;
rec {
  # Validation helper functions
  validators = {
    # Validate port ranges and conflicts
    validatePortRange = port: portName: serviceName:
      let
        isValidRange = port >= 1024 && port <= 65535;
        errorMsg = "Service '${serviceName}' ${portName} port ${toString port} must be between 1024-65535 (non-privileged range)";
      in {
        assertion = isValidRange;
        message = errorMsg;
      };
    
    # Validate port uniqueness across services  
    validatePortUniqueness = allPorts: serviceName: port:
      let
        otherPorts = filter (p: p.port == port && p.service != serviceName) allPorts;
        hasConflict = length otherPorts > 0;
        conflictingService = if hasConflict then (head otherPorts).service else "";
        errorMsg = "Port ${toString port} is already used by service '${conflictingService}', cannot assign to '${serviceName}'";
      in {
        assertion = !hasConflict;
        message = errorMsg;
      };
    
    # Validate domain name format
    validateDomain = domain: serviceName:
      let
        # Basic domain validation - contains at least one dot and valid characters
        isValidDomain = builtins.match "^[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$" domain != null;
        errorMsg = "Service '${serviceName}' domain '${domain}' is not a valid domain name format";
      in {
        assertion = isValidDomain;
        message = errorMsg;
      };
    
    # Validate file paths exist (for certificates, etc.)
    validatePath = path: pathName: serviceName:
      let
        errorMsg = "Service '${serviceName}' ${pathName} path '${path}' should be absolute and valid";
        isAbsolute = hasPrefix "/" path;
      in {
        assertion = isAbsolute;
        message = errorMsg;
      };
    
    # Validate database configuration consistency
    validateDatabase = dbConfig: serviceName:
      let
        needsPassword = elem dbConfig.type [ "mysql" "postgres" ];
        hasPasswordConfig = dbConfig.passwordFile != null;
        errorMsg = "Service '${serviceName}' database type '${dbConfig.type}' requires passwordFile to be set";
      in {
        assertion = !needsPassword || hasPasswordConfig;
        message = errorMsg;
      };
    
    # Validate SSL configuration consistency
    validateSsl = sslConfig: serviceName:
      let
        needsFiles = sslConfig.enable && sslConfig.acmeHost == null;
        hasCertFiles = needsFiles -> (sslConfig.certificate != null && sslConfig.certificateKey != null);
        errorMsg = "Service '${serviceName}' SSL enabled without ACME requires both certificate and certificateKey paths";
      in {
        assertion = !needsFiles || hasCertFiles;
        message = errorMsg;
      };
    
    # Validate data directory permissions and conflicts
    validateDataDir = dataDir: serviceName: allDataDirs:
      let
        otherServices = filter (d: d.dataDir == dataDir && d.service != serviceName) allDataDirs;
        hasConflict = length otherServices > 0;
        conflictingService = if hasConflict then (head otherServices).service else "";
        errorMsg = "Data directory '${dataDir}' is already used by service '${conflictingService}', cannot assign to '${serviceName}'";
      in {
        assertion = !hasConflict;
        message = errorMsg;
      };
  };
  
  # Collect all microservice configurations for cross-service validation
  getAllMicroservices = config:
    let
      microservices = config.blackmatter.components.microservices;
      serviceList = mapAttrsToList (name: cfg: {
        service = name;
        inherit (cfg) port dataDir;
        domain = cfg.domain or null;
      }) (filterAttrs (_: cfg: cfg.enable or false) microservices);
    in serviceList;
  
  # Generate assertions for a microservice
  mkMicroserviceAssertions = serviceName: serviceConfig:
    let
      allServices = getAllMicroservices config;
      allPorts = map (s: { inherit (s) service port; }) allServices;
      allDataDirs = map (s: { inherit (s) service dataDir; }) allServices;
      
      portValidation = validators.validatePortRange serviceConfig.port "main" serviceName;
      portUniqueness = validators.validatePortUniqueness allPorts serviceName serviceConfig.port;
      dataDirValidation = validators.validateDataDir serviceConfig.dataDir serviceName allDataDirs;
      domainValidation = optionalAttrs (serviceConfig ? domain && serviceConfig.domain != null) 
        (validators.validateDomain serviceConfig.domain serviceName);
      databaseValidation = optionalAttrs (serviceConfig ? database)
        (validators.validateDatabase serviceConfig.database serviceName);
      sslValidation = optionalAttrs (serviceConfig ? ssl)
        (validators.validateSsl serviceConfig.ssl serviceName);
      pathValidations = optionalAttrs (serviceConfig ? dataDir)
        (validators.validatePath serviceConfig.dataDir "dataDir" serviceName);
    in
    filter (a: a != {}) [
      portValidation
      portUniqueness  
      dataDirValidation
      domainValidation
      databaseValidation
      sslValidation
      pathValidations
    ];
  
  # Enhanced option types with validation
  enhancedTypes = {
    # Port with range validation
    validatedPort = serviceName: mkOption {
      type = types.port;
      description = "Port number for ${serviceName} (1024-65535)";
    };
    
    # Domain with format validation
    validatedDomain = serviceName: mkOption {
      type = types.str;
      description = "Valid domain name for ${serviceName} (e.g., service.example.com)";
      example = "${serviceName}.example.com";
    };
    
    # Data directory with conflict checking
    validatedDataDir = serviceName: defaultPath: mkOption {
      type = types.str;
      default = defaultPath;
      description = "Data directory for ${serviceName} (must be unique across services)";
    };
    
    # Database configuration with consistency checking
    validatedDatabase = mkOption {
      type = types.submodule {
        options = {
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
            description = "Database port";
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
            description = "Path to database password file (required for mysql/postgres)";
          };
        };
      };
      description = "Database configuration with validation";
    };
  };
  
  # Warnings for common misconfigurations
  warnings = {
    # Warn about development mode in production
    checkDevMode = serviceName: mode: domain:
      optional (mode == "dev" && hasSuffix ".com" domain) 
        "Service '${serviceName}' is in dev mode but domain '${domain}' looks like production";
    
    # Warn about default domains
    checkDefaultDomain = serviceName: domain:
      optional (hasInfix "example.com" domain)
        "Service '${serviceName}' is using default domain '${domain}', should be changed for production";
    
    # Warn about unencrypted databases
    checkDatabaseSecurity = serviceName: dbConfig:
      optional (elem dbConfig.type ["mysql" "postgres"] && dbConfig.host != "localhost")
        "Service '${serviceName}' database connection to '${dbConfig.host}' should use encryption";
    
    # Warn about disabled SSL in production
    checkSslInProduction = serviceName: sslConfig: mode:
      optional (mode == "prod" && !sslConfig.enable)
        "Service '${serviceName}' has SSL disabled in production mode - security risk";
  };
  
  # Generate all warnings for a service
  mkServiceWarnings = serviceName: serviceConfig:
    let
      modeWarnings = warnings.checkDevMode serviceName serviceConfig.mode (serviceConfig.domain or "");
      domainWarnings = optionals (serviceConfig ? domain) (warnings.checkDefaultDomain serviceName serviceConfig.domain);
      dbWarnings = optionals (serviceConfig ? database) (warnings.checkDatabaseSecurity serviceName serviceConfig.database);
      sslWarnings = optionals (serviceConfig ? ssl) (warnings.checkSslInProduction serviceName serviceConfig.ssl serviceConfig.mode);
    in
    flatten [ modeWarnings domainWarnings dbWarnings sslWarnings ];
}