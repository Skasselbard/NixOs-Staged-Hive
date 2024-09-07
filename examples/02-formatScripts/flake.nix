{
  inputs = {

    # Import nixpkgs
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

    # Import clusterConfig flake
    # Change this import to the github url
    clusterConfigFlake = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "path:../..";
    };

    # Import disko to configure partitioning
    # If you want to use disko for formatting, this option is required
    disko = {
      url = "github:nix-community/disko/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = inputs@{ self, nixpkgs, clusterConfigFlake, ... }:

    let # Definitions and imports

      system = "x86_64-linux";

      # import the pkgs attribute from the flake inputs
      pkgs = import nixpkgs { inherit system; };

      # The filters are used to resolve hosts when expanding the ClusterConfig
      filters = clusterConfigFlake.lib.filters;

      # Configuration from other Layers, e.g.: NixOs machine configurations
      configurations =
        (import "${self}/../00-exampleConfigs/") { inherit pkgs; };
      secrets = configurations.secrets;
      machines = configurations.machines;
    in let

      clusterConfig = clusterConfigFlake.lib.buildCluster {

        modules = [ clusterConfigFlake.clusterConfigModules.default ];

        domain = {
          suffix = "com";

          clusters = {

            # the cluster name will also be used for fqdn generation
            example = {

              services = {
                # Static DNS via /etc/hosts file
                dns = {
                  roles.hosts = [ filters.clusterMachines ];
                  selectors = [ filters.clusterMachines ];
                  definition = clusterConfigFlake.clusterServices.staticDns;
                };
              };

              users.root.systemConfig = {
                extraGroups = [ "wheel" ];
                # 'root'
                hashedPassword = secrets.pswdHash.root;
                openssh.authorizedKeys.keys = [ secrets.ssh.publicKey ];
              };

              machines = {

                vm0 = {
                  inherit system;
                  nixosModules = [
                    machines.vm0
                    # since this vm uses disko for mounting, we still need to include the NixOs module
                    inputs.disko.nixosModules.default
                  ];

                  deployment = {
                    targetHost = "192.168.122.200";

                    # If the deployment.format atribute is null (or unset)
                    # no script will be executed.
                    # This is intended for hosts that are already formatted or that you format
                    # manually from the boot iso.
                    # Installing over an already existing OS seems to work for this example,
                    # but it is not recommended.
                    formatScript = null;
                  };

                };

                vm1 = {
                  inherit system;
                  nixosModules =
                    [ machines.vm1 inputs.disko.nixosModules.default ];

                  deployment = {
                    targetHost = "192.168.122.201";
                    # If the deployment.format atribute is set to "disko"
                    # the script generated by disko (set with the `disko` configuration attribute)
                    # will be executed
                    # This requires a disko configuration and importing disko as flake input (as we do in the beginning of the file)
                    # See the disko dokumentation on how to define the diskoo attribute:
                    # https://github.com/nix-community/disko
                    formatScript = "disko";
                  };

                };

                vm2 = {
                  inherit system;
                  nixosModules =
                    [ machines.vm2 inputs.disko.nixosModules.default ];

                  deployment = {
                    targetHost = "192.168.122.202";

                    # You can define your own format script.
                    # You may also use this to run other scripting action before the installation.
                    # However, the intention behind this config is formatting.
                    #
                    # For this example we extract the script build with the disko configuration manually.
                    # This can come in handy if you want to use part of your disko configuiration 
                    # for formatting (e.g. the OS) but another part should not be touched (like data drives).
                    # You can then define multiple disko configurations
                    # (e.g. one for ephemeral OS and one for the persistent data)
                    # and only use the ephemeral config for fromatting.
                    # However, for the final machine configuration, you have to merge both configurations again
                    # to configure mounting points and the like.
                    #
                    # But we keep the example simple and only use the disko config from the vm
                    # and add some echos around.
                    formatScript = let
                      # get the machine configuration
                      cfg = self.nixosConfigurations.vm2.config;

                      customStartMessage = ''
                        echo "This could be  the result of your preformat command"'';

                      # the disko config from the machine
                      diskoScript = cfg.disko.devices._disko;

                      customEndMessage = ''
                        echo "This could be  the result of your postformat command"'';

                      # Build an executable script and use it for formatting
                    in pkgs.writeScript "formatScript" ''
                      ${customStartMessage}
                      ${diskoScript}
                      ${customEndMessage}
                    '';
                  };

                };

              };
            };

          };

        };
      };

      # DO NOT FORGET!
    in clusterConfig; # use the generated cluster config as the flake content
}
