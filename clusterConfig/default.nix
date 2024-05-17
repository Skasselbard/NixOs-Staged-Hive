{ nixpkgs, nixos-generators, home-manager, colmena, flake-utils, nixos-anywhere
}:
let
  pkgs = import nixpkgs {
    # the exact value of 'system' should be unimportant since we only use lib
    system = "x86_64-linux";
  };
  filters = import ./filters.nix { lib = pkgs.lib; };
  clusterlib = import ./lib.nix { lib = pkgs.lib; };

  forEachAttrIn = clusterlib.forEachAttrIn;
in with pkgs.lib;
let

  get = {

    interface = {
      ips = interfaceDefinition:
        let
          v4Adresses = lists.forEach interfaceDefinition.ipv4.addresses
            (addressDefinition: addressDefinition.address);
          v6Adresses = lists.forEach interfaceDefinition.ipv6.addresses
            (addressDefinition: addressDefinition.address);
        in lists.flatten [ v4Adresses v6Adresses ];

      definitions = machineConfig:
        lists.forEach (get.interface.names machineConfig) (interfaceName: {
          "${interfaceName}" = builtins.removeAttrs
            (builtins.getAttr interfaceName
              machineConfig.config.networking.interfaces) [ "subnetMask" ];
        });

      names = machineConfig:
        attrsets.attrNames machineConfig.config.networking.interfaces;
    };

    ips = machineConfig:
      let
        interfaces = attrsets.mergeAttrsList
          (lists.forEach (get.interface.definitions machineConfig) (interface:
            let
              interfaceName = (head (attrsets.attrNames interface));
              interfaceValue = (head (attrsets.attrValues interface));
            in { "${interfaceName}" = get.interface.ips interfaceValue; }));
      in {
        all = lists.flatten (attrsets.attrValues interfaces);
      } // interfaces;

    # returns a list with (unnamed) service Definitions from all services in the cluster config
    # config -> {{ [path], serviceConfig}, ...}
    services = config:
      attrsets.attrValues ( # to list
        attrsets.mergeAttrsList (attrsets.attrValues ( # remove cluster names
          forEachAttrIn config.domain.clusters (clusterName: clusterConfig:
            (forEachAttrIn clusterConfig.services
              (serviceName: serviceDefinition: {
                "config" = serviceDefinition.config;
                selectors =
                  (filters.toConfigAttrPaths serviceDefinition.selectors
                    clusterName config);
                roles = (forEachAttrIn serviceDefinition.roles (rolename: role:
                  filters.toConfigAttrPaths role clusterName config));
              }))))));

    machines = config:
      attrsets.mergeAttrsList (lists.flatten (attrsets.attrValues
        (forEachAttrIn config.domain.clusters
          (clusterName: clusterValue: clusterValue.machines))));
  };

  add = {

    # clusterconfig -> ((clusterName -> machineName -> machineConfig) -> machineConfigAttr) -> clusterconfig
    machineConfiguration = config: machineConfigFn: {
      domain = attrsets.recursiveUpdate config.domain {
        clusters = (forEachAttrIn config.domain.clusters
          (clusterName: clusterConfig: {
            machines = forEachAttrIn clusterConfig.machines
              (machineName: machineConfig:
                (machineConfigFn clusterName machineName machineConfig));
          }));
      };
    };

    nixosConfigurations = config:
      add.machineConfiguration config
      (clusterName: machineName: machineConfig: {
        nixosConfiguration =
          nixpkgs.lib.nixosSystem { modules = machineConfig.nixosModules; };
      });

    # clusterconfig -> ((clusterName -> machineName -> machineConfig) -> moduleAttr) -> clusterconfig
    nixosModule = config: moduleConfigFn:
      let
        domainAttr = config.domain;
        clusters = config.domain.clusters;
      in add.machineConfiguration config
      (clusterName: machineName: machineConfig: {
        nixosModules = (lists.flatten
          [ (moduleConfigFn clusterName machineName machineConfig) ])
          ++ machineConfig.nixosModules;
      });

  };

  evalCluster = clusterConfig:
    evalModules {
      modules = [
        ./deployment.nix
        ./options.nix
        {
          config = {
            # make flake functions from nixpkgs available for submodules
            _module.args = {
              inherit pkgs nixpkgs clusterlib colmena;
              lib = pkgs.lib;
            };
            # set the domain attribute for evaluation
            domain = clusterConfig.domain;
          };
        }
      ];
    };

  clusterAnnotation = config:

    # Add NixOs modules inferred by the cluster config to each Machines NixOs modules
    add.nixosModule config (clusterName: machineName: machineConfig:
      let

        clusterUsers = config.domain.clusters."${clusterName}".users;
        machineUsers = machineConfig.users;

        clusterhomeManagerModules = forEachAttrIn clusterUsers
          (n: userConfig: userConfig.homeManagerModules);
        machineHomeManagerModules = forEachAttrIn machineUsers
          (n: userConfig: userConfig.homeManagerModules);

        mergedHomeManagerModules = lists.flatten [
          (attrsets.attrValues clusterhomeManagerModules)
          (attrsets.attrValues machineHomeManagerModules)
        ];
        activateHomeManager = mergedHomeManagerModules != [ ];

      in [

        { # machine config
          networking.hostName = machineName;
          networking.domain = clusterName + "." + config.domain.suffix;
          nixpkgs.hostPlatform = mkDefault machineConfig.system;
        }

        # make different modules for cluster and user definitions so that the NixOs
        # module system handles the merging

        { # cluster users
          users.users =
            forEachAttrIn clusterUsers (n: userConfig: userConfig.systemConfig);
          # forEach user (homeManagerModules ++ userHMModules) -> if not empty -> enable HM
        }

        { # machine users
          users.users =
            forEachAttrIn machineUsers (n: userConfig: userConfig.systemConfig);
        }

      ] ++ (if activateHomeManager then [

        # homeManager config
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;

          # Use a set of all users to acces the homeManager module list for each user.
          # Ignore the actual definition for the user and access the module list directly.
          home-manager.users = forEachAttrIn (clusterUsers // machineUsers)
            (user: _ignore:
              let
                clusterModules = if clusterhomeManagerModules ? "${user}" then
                  clusterhomeManagerModules."${user}"
                else
                  [ ];
                machinModules = if machineHomeManagerModules ? "${user}" then
                  machineHomeManagerModules."${user}"
                else
                  [ ];
              in { imports = (clusterModules ++ machinModules); });
        }
      ] else
        [ ]));

  evalMachines = config: add.nixosConfigurations config;

  machineAnnotation = config:
    add.machineConfiguration config (clusterName: machineName: machineConfig: {
      annotations = {
        inherit clusterName machineName;
        ips = get.ips machineConfig.nixosConfiguration;
        fqdn = machineConfig.nixosConfiguration.config.networking.fqdn;
        # TODO: subnets?
      };
    });

  serviceAnnotation = with lists;
    config:
    let services = get.services config;
    in add.nixosModule config (clusterName: machineName: machineConfig:
      let
        # filter the service list for the ones that match the path of the current machine
        filteredServices = builtins.filter (service:
          (lists.any (filter:
            assert asserts.assertMsg (strings.hasPrefix "domain" filter)
              "Filter '${filter}' does not start with 'domain'. Filters need to be a path in the clusterConfig in the form like 'domain.clusterName.machineName'";
            filter == "domain.clusters.${clusterName}.machines.${machineName}")
            service.selectors)) services;
        # attrsets.mergeAttrsList # merge all matching services together
      in (lists.forEach filteredServices (service:
        # get the config closure and compute its result to form a complete NixosModule
        (service.config {
          selectors =
            service.selectors (filters.resolve service.selectors config);
          roles = service.roles;
          this = machineConfig.annotations; # machineConfig;
        }))));

  deploymentAnnotation = config:
    let machines = get.machines config;
    in config // attrsets.recursiveUpdate {

      nixosConfigurations = forEachAttrIn machines
        (machineName: machineConfig: machineConfig.nixosConfiguration);

      colmena = {
        meta.nixpkgs = import nixpkgs {
          system = "x86_64-linux"; # TODO: is this used for all machines?
          overlays = [ ];
        };
      } // forEachAttrIn machines (machineName: machineConfig: {
        deployment = machineConfig.deployment;
        imports = machineConfig.nixosModules;
      });

      apps = colmena.apps;
      # TODO: clusterconfig app as default

    }
    # The deployment options are generated for all system  configurations (by using flake utils)

    (flake-utils.lib.eachSystem flake-utils.lib.allSystems (system: {

      # buld an iso package for each machine configuration 
      packages = forEachAttrIn machines (machineName: machineConfig: {
        iso = nixos-generators.nixosGenerate
          ((build.bootImageNixosConfiguration machineConfig) // {
            format = "iso";
          });
        setup = let
          nixosConfig =
            machineConfig.nixosConfiguration.config.system.build.toplevel.outPath;
          formatScript =
            machineConfig.nixosConfiguration.config.partitioning.ephemeral_script;
        in pkgs.writeScriptBin "deploy" ''
          ${pkgs.nix}/bin/nix run path:${nixos-anywhere.outPath} -- -s ${formatScript.outPath} ${nixosConfig} ${machineConfig.deployment.targetUser}@${machineConfig.deployment.targetHost}
        '';
      });

      # # build executables for deployment that can be run with 'nix run'
      # apps = forEachAttrIn machines (machineName: machineConfig: {
      #   "setup-${machineName}" = {
      #     type = "app";
      #     program = ? run nixos anywhere;
      #   };
      #   # "deploy-${machioneName}" = ? run colmena upload-keys; run nixos-rebuild;
      # });
    }));

in {

  inherit filters;

  # TODOs:
  # - conditionally include virtual interfaces (networking.interfaces.<name>.virtual = true) -> not useful for dns
  # - include dhcp hints for static dhcp ip -> known dhcp ips should be addable
  # tagging
  # - cluster annotations: fqdn, all ips, all machine names + fqdns, all service names, service selectors per service
  # cluster users
  # - define a set of users that will be deployed on all machines in the cluster (like services)
  # maybe the same with groups

  # a function that builds and evaluates the clusterconfig to apply directly on the cluster definition
  buildCluster = config:
    let
      # Step 1:
      # Evaluate the cluster to check for type conformity
      evaluatedCluster = (evalCluster config).config;

      # TODO: call module functions here including cluster annotation

      # Step 2:
      # Annotate all machines with data from the cluster config.
      # This includes:
      # - Hostnames: networking.hostname is set to the name of the machiene definition
      # - DomainName: networkinig.domain is set to clusterName.domainSuffix
      # - Hostplattform: pkgs.hostPlattform is set to the configured system in the machine configuration
      clusterAnnotatedCluster = clusterAnnotation evaluatedCluster;

      # Step 3:
      # Evaluate the nixosModules from all machines to generate a first NixosConfiguration.
      # This config will be overwritten later.
      machineEvaluatedCluster = evalMachines clusterAnnotatedCluster;

      # Step 4:
      # Annotate the cluster with data from the machine configurations
      # This includes:
      # - the used IP addresses
      # - the FQDN
      evalAnnotatedCluser = machineAnnotation machineEvaluatedCluster;

      # Step 5:
      # Add the service configurations to the modlues of the tergeted machines
      serviceAnnotatedCluster = serviceAnnotation evalAnnotatedCluser;

      # TODO: call module functions here (including the functions above?)

      # Step 6:
      # Evaluate the final NixosConfigurations that can be added as build targets
      nixosConfiguredCluster = evalMachines serviceAnnotatedCluster;

      # TODO: call module functions here including deployment function

      # Step 7:
      # Build the deployment scripts 
      deploymentAnnotatedCluster = deploymentAnnotation nixosConfiguredCluster;

    in deploymentAnnotatedCluster;

}