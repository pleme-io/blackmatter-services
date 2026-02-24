# Service dependency management system
{ lib, config, ... }:
with lib;
rec {
  # Service dependency definitions
  serviceDependencies = {
    # Database services (no dependencies)
    postgres = {
      provides = [ "database.postgres" ];
      requires = [];
      after = [];
      conflicts = [];
    };
    
    redis = {
      provides = [ "database.redis" "cache" ];
      requires = [];
      after = [];
      conflicts = [];
    };
    
    # Web services requiring database
    gitea = {
      provides = [ "git.server" "web.service" ];
      requires = [ "database.postgres" ];  # Can use sqlite but postgres recommended
      after = [ "postgres" ];
      conflicts = [];
      optional = [ "reverse_proxy" ];
    };
    
    mastodon = {
      provides = [ "social.server" "web.service" ];
      requires = [ "database.postgres" "database.redis" ];
      after = [ "postgres" "redis" ];
      conflicts = [];
      optional = [ "reverse_proxy" ];
    };
    
    matrix-synapse = {
      provides = [ "chat.server" "web.service" ];
      requires = [ "database.postgres" ];
      after = [ "postgres" ];
      conflicts = [];
      optional = [ "reverse_proxy" ];
    };
    
    vaultwarden = {
      provides = [ "password.manager" "web.service" ];
      requires = [];  # Can use sqlite
      after = [];
      conflicts = [];
      optional = [ "database.postgres" "reverse_proxy" ];
    };
    
    # Reverse proxy services
    traefik = {
      provides = [ "reverse_proxy" "load_balancer" ];
      requires = [];
      after = [];
      conflicts = [ "haproxy" "nginx" ];
      optional = [];
    };
    
    haproxy = {
      provides = [ "reverse_proxy" "load_balancer" ];
      requires = [];
      after = [];
      conflicts = [ "traefik" "nginx" ];
      optional = [];
    };
    
    nginx = {
      provides = [ "reverse_proxy" "web.server" ];
      requires = [];
      after = [];
      conflicts = [ "traefik" "haproxy" ];
      optional = [];
    };
    
    # Monitoring services
    prometheus = {
      provides = [ "monitoring.metrics" ];
      requires = [];
      after = [];
      conflicts = [];
      optional = [];
    };
    
    grafana = {
      provides = [ "monitoring.visualization" ];
      requires = [];
      after = [];
      conflicts = [];
      optional = [ "monitoring.metrics" ];
    };
    
    # Authentication services
    keycloak = {
      provides = [ "auth.server" "sso" ];
      requires = [ "database.postgres" ];
      after = [ "postgres" ];
      conflicts = [];
      optional = [ "reverse_proxy" ];
    };
    
    # Container orchestration
    consul = {
      provides = [ "service.discovery" "kv.store" ];
      requires = [];
      after = [];
      conflicts = [];
      optional = [];
    };
    
    nomad = {
      provides = [ "container.orchestration" ];
      requires = [];
      after = [];
      conflicts = [ "kubernetes" ];
      optional = [ "service.discovery" ];
    };
    
    # Media services
    jellyfin = {
      provides = [ "media.server" ];
      requires = [];
      after = [];
      conflicts = [ "plex" "emby" ];
      optional = [ "reverse_proxy" ];
    };
    
    # Home automation
    home-assistant = {
      provides = [ "home.automation" ];
      requires = [];
      after = [];
      conflicts = [];
      optional = [ "database.postgres" "reverse_proxy" ];
    };
  };
  
  # Get enabled services from config
  getEnabledServices = config:
    let
      microservices = config.blackmatter.components.microservices;
    in
      filter (service: 
        hasAttr service microservices && 
        microservices.${service}.enable or false
      ) (attrNames serviceDependencies);
  
  # Resolve dependencies for a service
  resolveDependencies = service: enabledServices:
    let
      deps = serviceDependencies.${service} or {};
      required = deps.requires or [];
      after = deps.after or [];
      
      # Find services that provide required capabilities
      findProviders = capability:
        filter (s: elem capability (serviceDependencies.${s}.provides or [])) enabledServices;
      
      # Get all required service providers
      requiredServices = flatten (map findProviders required);
      
      # Services that should start after this one
      afterServices = filter (s: elem s enabledServices) after;
      
    in {
      inherit service;
      requires = requiredServices;
      after = afterServices;
      provides = deps.provides or [];
      conflicts = deps.conflicts or [];
      optional = deps.optional or [];
    };
  
  # Detect circular dependencies using topological sort
  detectCircularDependencies = serviceDeps:
    let
      # Build adjacency list
      adjList = listToAttrs (map (dep: {
        name = dep.service;
        value = dep.requires ++ dep.after;
      }) serviceDeps);
      
      # DFS to detect cycles
      hasCycle = visited: path: node:
        if elem node path then
          throw "Circular dependency detected: ${concatStringsSep " → " (path ++ [node])}"
        else if elem node visited then
          false
        else
          any (hasCycle (visited ++ [node]) (path ++ [node])) (adjList.${node} or []);
      
      allNodes = map (dep: dep.service) serviceDeps;
    in
      any (hasCycle [] []) allNodes;
  
  # Topological sort for startup order
  topologicalSort = serviceDeps:
    let
      # Build adjacency list and in-degree count
      nodes = map (dep: dep.service) serviceDeps;
      edges = flatten (map (dep: 
        map (req: { from = req; to = dep.service; }) dep.requires
      ) serviceDeps);
      
      adjList = listToAttrs (map (node: {
        name = node;
        value = map (e: e.to) (filter (e: e.from == node) edges);
      }) nodes);
      
      inDegree = listToAttrs (map (node: {
        name = node;
        value = length (filter (e: e.to == node) edges);
      }) nodes);
      
      # Kahn's algorithm
      kahnSort = queue: result: remaining:
        if queue == [] then
          if remaining == [] then result
          else throw "Cannot resolve dependencies - circular dependency exists"
        else
          let
            current = head queue;
            neighbors = adjList.${current} or [];
            
            # Decrease in-degree of neighbors
            newInDegree = foldl' (acc: neighbor:
              acc // { ${neighbor} = (acc.${neighbor} or 0) - 1; }
            ) inDegree neighbors;
            
            # Find new nodes with in-degree 0
            newQueue = (tail queue) ++ filter (n: newInDegree.${n} == 0) 
              (filter (n: n != current) remaining);
            
            newRemaining = filter (n: n != current) remaining;
          in
            kahnSort newQueue (result ++ [current]) newRemaining;
      
      # Start with nodes that have no dependencies
      initialQueue = filter (node: inDegree.${node} == 0) nodes;
    in
      kahnSort initialQueue [] nodes;
  
  # Validate service configuration
  validateServiceConfig = config:
    let
      enabledServices = getEnabledServices config;
      serviceDeps = map (s: resolveDependencies s enabledServices) enabledServices;
      
      # Check for missing dependencies
      missingDeps = flatten (map (dep:
        let
          missing = filter (req: !(elem req enabledServices)) dep.requires;
        in
          if missing != [] then
            [{ service = dep.service; missing = missing; }]
          else []
      ) serviceDeps);
      
      # Check for conflicts
      conflicts = flatten (map (dep:
        let
          conflicting = filter (conf: elem conf enabledServices) dep.conflicts;
        in
          if conflicting != [] then
            [{ service = dep.service; conflicting = conflicting; }]
          else []
      ) serviceDeps);
      
      # Check circular dependencies
      circularCheck = detectCircularDependencies serviceDeps;
      
    in {
      inherit enabledServices serviceDeps;
      valid = missingDeps == [] && conflicts == [];
      missingDependencies = missingDeps;
      conflictingServices = conflicts;
      startupOrder = if missingDeps == [] && conflicts == [] then
        topologicalSort serviceDeps
      else [];
    };
  
  # Generate systemd service dependencies
  generateSystemdDeps = service: config:
    let
      enabledServices = getEnabledServices config;
      deps = resolveDependencies service enabledServices;
    in {
      wants = deps.requires;
      after = deps.requires ++ deps.after;
      conflicts = deps.conflicts;
    };
  
  # Service dependency assertions
  mkDependencyAssertions = config:
    let
      validation = validateServiceConfig config;
    in [
      {
        assertion = validation.valid;
        message = "Service dependency validation failed:\n" +
          optionalString (validation.missingDependencies != []) (
            "Missing dependencies:\n" +
            concatStringsSep "\n" (map (m: 
              "  ${m.service} requires: ${concatStringsSep ", " m.missing}"
            ) validation.missingDependencies) + "\n"
          ) +
          optionalString (validation.conflictingServices != []) (
            "Conflicting services:\n" +
            concatStringsSep "\n" (map (c:
              "  ${c.service} conflicts with: ${concatStringsSep ", " c.conflicting}"
            ) validation.conflictingServices)
          );
      }
    ];
  
  # Service dependency warnings
  mkDependencyWarnings = config:
    let
      enabledServices = getEnabledServices config;
      serviceDeps = map (s: resolveDependencies s enabledServices) enabledServices;
      
      # Warn about missing optional dependencies
      missingOptional = flatten (map (dep:
        let
          missing = filter (opt: !(elem opt enabledServices)) dep.optional;
          providers = flatten (map (opt:
            filter (s: elem opt (serviceDependencies.${s}.provides or [])) 
              (attrNames serviceDependencies)
          ) missing);
        in
          if missing != [] then
            ["${dep.service} could benefit from: ${concatStringsSep ", " providers}"]
          else []
      ) serviceDeps);
      
    in missingOptional;
  
  # Helper to automatically enable dependencies
  autoEnableDependencies = requestedServices:
    let
      # Recursively resolve all dependencies
      resolveDepsRecursive = services: resolved:
        let
          newDeps = flatten (map (s:
            let deps = serviceDependencies.${s} or {};
            in deps.requires or []
          ) services);
          
          allServices = unique (services ++ newDeps);
          unresolved = filter (s: !(elem s resolved)) allServices;
        in
          if unresolved == [] then resolved
          else resolveDepsRecursive unresolved allServices;
          
      allRequired = resolveDepsRecursive requestedServices [];
    in allRequired;
}