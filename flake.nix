{
  description = "Nix flake replicating the Dockerfile for PostgreSQL + PL/Rust setup.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
    util = {
      url = "github:hectic-lab/util.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
    util,
    ...
  }: let
    trace = builtins.trace; # can change to builtins.traceVerbose to make it silent
    overlays = [
      (import rust-overlay)
      util.overlays.default
      (import ./cargo-pgrx-overlay.nix)
    ];
  in
    util.lib.forSpecSystemsWithPkgs ["x86_64-linux" "aarch64-linux"] overlays ({
      system,
      pkgs,
    }: {
      nixosConfigurations.${system} = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ({modulesPath, ...}: {
            imports = [
              (modulesPath + "/profiles/qemu-guest.nix")
            ];
          })
          self.nixosModules.postgresqlPreConfigure
          {
            services.postgresql = {
	      enable = true;
              package = pkgs.postgresql_15;
              lazzyExtensions = {
                pg_cron = true;
                pgjwt = true;
                pg_net = true;
                pg_smtp_client = true;
                http = true;
		plsh = true;
	        hemar = true;
              };

              authentication = self.lib.authPresets.allMixed;

              # Provide an initial script if needed:
              initialScript = pkgs.writeText "init-sql-script" ''
                CREATE EXTENSION IF NOT EXISTS "http";
                       \set gateway_schema `echo $GATEWAY_SCHEMA`
                       SELECT :'gateway_schema' = ''' AS is_gateway_schema;
                       \gset
                       \if :is_gateway_schema
                         \echo 'Error: Environment variable GATEWAY_SCHEMA is not set.'
                         \quit 1
                       \endif

                CREATE SCHEMA :gateway_schema;

                ALTER DATABASE postgres SET "app.gateway" TO :'gateway_schema';
              '';

	      environment = { 
	        TEXT = "aaa";
		TEST = "bbb";
	      };

	    };
          }
          {
            environment.systemPackages = with pkgs; [git curl neovim postgresql_15];

            virtualisation.vmVariant = {
              services.getty.autologinUser = "root";
              virtualisation.forwardPorts = [
                {
                  from = "host";
                  host.port = 40500;
                  guest.port = 22;
                }
                {
                  from = "host";
                  host.port = 54321;
                  guest.port = 5432;
                }
              ];
            };

            users.users.root.openssh.authorizedKeys.keys = [
              ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICrbBG+U07f7OKvOxYIGYCaNvyozzxQF+I9Fb5TYZErK yukkop vm-postgres''
            ];

            services.openssh = {
              enable = true;
              settings = {
                PasswordAuthentication = false;
              };
            };

            networking.firewall = {
              enable = true;
              allowedTCPPorts = [
                53
                22
                5432
              ];
            };

            system.stateVersion = "24.11";
          }
        ];
      };
    })
    // {
      lib = {
        authPresets = {
          localTrusted = builtins.concatStringsSep "\n" [
            "local all       all     trust"
            "host  all      all     127.0.0.1/32   trust"
            "host all       all     ::1/128        trust"
          ];
          allMixed = builtins.concatStringsSep "\n" [
            "local all       all     trust"
            "host  sameuser    all     127.0.0.1/32 scram-sha-256"
            "host  sameuser    all     ::1/128 scram-sha-256"
            "host  all         all     ::1/128 scram-sha-256"
            "host  all        all     0.0.0.0/0 scram-sha-256"
          ];
          localhostOnly = builtins.concatStringsSep "\n" [
            "local all       all     trust"
            "host  sameuser    all     127.0.0.1/32 scram-sha-256"
            "host  sameuser    all     ::1/128 scram-sha-256"
          ];
	};
      };
      nixosModules = let
        extensionFlags = {
           pg_cron = false;
           pgjwt = false;
           pg_net = false;
           pg_smtp_client = false;
           http = false;
           plsh = false;
           hemar = false;
        };
      in {
        postgresqlPreConfigure = { pkgs, config, lib, ... }: let
          system = pkgs.system;
          cfg = config.services.postgresql;
        in {
          options = {
            services.postgresql = {
              lazzyExtensions = lib.mkOption {
                type = lib.types.attrsOf lib.types.bool;
                default = extensionFlags;
              };
	      environment = lib.mkOption {
                type    = lib.types.attrsOf lib.types.str;
                default = {};
              };
	    };
          };
          config = lib.mkIf cfg.enable {
	    systemd.services.postgresql.environment = cfg.environment;
            services.postgresql = {
	      settings.shared_preload_libraries =
                lib.concatStringsSep ", "
                  (lib.attrNames (
          	    lib.filterAttrs (n: v: v && 
          	         n != "http" 
          	      && n != "plsh" 
          	      && n != "pgjwt" 
          	      && n != "pg_smtp_client"
          	  ) cfg.lazzyExtensions));

              extensions = let
                packages = {
                  inherit (cfg.package.pkgs) pg_net pgjwt pg_cron http pg_smtp_client plsh;
                  hemar = util.packages.${system}.pg-15-hemar;
                };
              in
                lib.attrValues (
                  lib.filterAttrs (n: v: v != null)
                  (lib.mapAttrs' (
                      name: enabled:
                        if enabled
                        then lib.nameValuePair name (packages.${name} or (throw "Package ${name} not found in pkgs"))
                        else null
                    )
                    cfg.lazzyExtensions)
                );
            };
          };
        };
        postgresqlServiceLegacy = {
          lib,
          config,
          pkgs,
          ...
        }: let
          system = pkgs.system;
          cfg = config.hectic.postgres;
        in {
          options = {
            hectic.postgres = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
              authPreset = lib.mkOption {
                type = lib.types.enum (lib.attrNames self.lib.authPresets);
                default = "localhostOnly";
                description = "Which authentication preset to use for PostgreSQL (e.g. localTrusted, allMixed, localhostOnly).";
              };
              package = lib.mkOption {
                type = lib.types.package;
                default = pkgs.postgresql_16;
              };
              enableTCPIP = lib.mkOption {
                type = lib.types.bool;
                default = true;
              };
              extensions = lib.mkOption {
                type = lib.types.attrsOf lib.types.bool;
                default = extensionFlags;
              };
              initialScript = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
              };
              settings = lib.mkOption {
                type = lib.types.attrs;
                default = {};
              };
              host = lib.mkOption {
                type = lib.types.string;
                default = "127.0.0.1";
                description = "Address to run PostgreSQL on";
              };
              port = lib.mkOption {
                type = lib.types.int;
                default = 5432;
                description = "Port to run PostgreSQL on";
              };
              # passwordFile = lib.mkOption {
              #   type = lib.types.path;
              #   description = "Password for `postgres` user";
              # };
            };
          };

          config = lib.mkIf cfg.enable {
            # systemd.services = lib.mkMerge [
            #   {
            #     postgresql.serviceConfig.Environment =
            #       builtins.map (name: "${name}=${cfg.environment.${name}}")
            #       (lib.attrNames cfg.environment);
            #   }
            # ];
            services.postgresql = {
              enable = true;
              package = cfg.package;
              enableTCPIP = cfg.enableTCPIP;

              /* postgresql.config */
              settings = lib.mkMerge [
                {
                  port = cfg.port;
                  listen_addresses = lib.mkOverride 80 cfg.host;
                  shared_preload_libraries =
                    lib.concatStringsSep ", "
                    (lib.attrNames (
          	    lib.filterAttrs (n: v: v && 
          	         n != "http" 
          	      && n != "pgjwt" 
          	      && n != "pg_smtp_client"
          	  ) cfg.extensions));
                }
                /* additional custom settings */
                cfg.settings
              ];
              extensions = let
                packages = {
                  inherit (cfg.package.pkgs) pg_net pgjwt pg_cron http pg_smtp_client;
          	hemar = util.packages.${system}.pg-15-hemar;
                };
              in
                lib.attrValues (
                  lib.filterAttrs (n: v: v != null)
                  (lib.mapAttrs' (
                      name: enabled:
                        if enabled
                        then lib.nameValuePair name (packages.${name} or (throw "Package ${name} not found in pkgs"))
                        else null
                    )
                    cfg.extensions)
                );
              authentication = lib.mkOverride 10 self.lib.authPresets.${cfg.authPreset};
              initialScript = cfg.initialScript;
            };
          };
        };
      };
    };
}
