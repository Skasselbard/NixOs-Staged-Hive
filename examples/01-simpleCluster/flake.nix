{
  inputs = {

    # Import nixpkgs
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";

    # Import clusterConfig flake
    # Change this import to the github url
    clusterConfigFlake = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "path:../..";
    };

    # Import disko to configure partitioning
    disko = {
      url = "github:nix-community/disko/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = inputs@{ self, nixpkgs, clusterConfigFlake, ... }:

    let # imports

      # build for 64bit linux
      system = "x86_64-linux";

      # The filters are used to resolve hosts when expanding the ClusterConfig
      filters = clusterConfigFlake.lib.filters;

      # To separate cluster configurations from other configurations (e.g. machines)
      # it is advisable to keep the configurations separate and import it in a variable.
      # This keeps the cluster config much more readable.
      configurations = import "${self}/../00-exampleConfigs/";
      secrets = configurations.secrets;
      machines = configurations.machines;
    in let

      # The given clusterConfig has to be expanded with the buildCluster function.
      # This function will generate nixos machines and packages e.g. for deployment
      clusterConfig = clusterConfigFlake.lib.buildCluster {

        # load clusterConfig modules
        # part of the default modules are:
        #   - The HomeManager module to include home manager modules to user configurations
        #   - A Nixos-Anywhere module for initial deoplyment
        #   - A colmena module for system updates and secret depployment
        modules = [ clusterConfigFlake.clusterConfigModules.default ];

        domain = {

          # every cluster has a suffix for fqdn generation
          # usually this will be a toplevel domain
          suffix = "com";

          clusters = {

            # the cluster name will also be used for fqdn generation
            example = {

              # Optional:
              # We add the static dns service we imported with cluster modules.
              # It will append all static ips from the configured hosts to the ``/etc/hosts`` file.
              # The ips from these hosts will be resolveble with the host name
              services = {
                dns = {
                  # All machines matching this filters (all machines in the cluster)
                  # will be added to the hosts file.
                  roles.hosts = [ filters.clusterMachines ];

                  # All machines matching this filters (all machines in the cluster)
                  # will be extended with the dns service configuration
                  selectors = [ filters.clusterMachines ];

                  # load the service definition for the static dns
                  definition = clusterConfigFlake.clusterServices.staticDns;
                };
              };

              # Define the root user in the cluster and no other users
              # Users have two configurations
              # 1. HomeManager configurations -> a list of nixos-style modules
              # 2. System configuration -> added to users.users.<name>
              users = {

                # Configuration for the root user.
                # 'root' will be the <name> part in users.users.<name> in this example
                root = {
                  homeManagerModules = [ ];

                  systemConfig = {

                    extraGroups = [ "wheel" ];

                    # 'root'
                    hashedPassword = secrets.pswdHash.root;

                    # add your ssh public key for ssh access
                    openssh.authorizedKeys.keys = [ secrets.ssh.publicKey ];
                  };

                };

              };

              # Define a two vms in the cluster
              machines = {

                vm0 = {
                  inherit system;
                  # load the system configuration for this vm
                  nixosModules = [
                    machines.vm0 # machine configuration
                    inputs.disko.nixosModules.default # make the disko attribute available in the machine config
                  ];

                  deployment = {

                    # Deploy to a machine with this address
                    # You may have to lookup the ip from a running machine, e.g. if you use dhcp
                    # The deployment address can be a url and is allowed to differ
                    # from configurations in the machine configuration.
                    # This way you can deploy to an existing host and change its configuration.
                    targetHost = "192.168.100.10";

                    # Format the entire machine with disko on initial deployment
                    formatScript = "disko";
                  };

                };

                vm1 = {
                  inherit system;
                  nixosModules =
                    [ machines.vm1 inputs.disko.nixosModules.default ];

                  deployment = { formatScript = "disko"; };

                };

              };
            };

          };

        };
      };

      # DO NOT FORGET!
    in clusterConfig; # use the generated cluster config as the flake content
}
