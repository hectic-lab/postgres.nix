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

  outputs = { self, nixpkgs, util, rust-overlay, ... }:
    let
      trace = builtins.trace; # can change to builtins.traceVerbose to make it silent
      overlays = [ 
        (import rust-overlay)
        util.overlays.default
	(import ./cargo-pgrx-overlay.nix)
      ];
    in
    util.lib.forSpecSystemsWithPkgs ([ "x86_64-linux" "aarch64-linux" ]) overlays ({ system, pkgs }:
    {
      nixosModules.${system}.postgresqlService = { lib, config, pkgs, ... }: let
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
        cfg = config.hectic.postgres;
      in {
        options = {
          hectic.postgres = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
	    authPreset = lib.mkOption {
              type = lib.types.enum (lib.attrNames authPresets);
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
              default = {
                pg_cron  = false;
                pgjwt    = false;
                pg_net   = false;
                http  = false;
              };
            };
            initialScript = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
            };
            settings = lib.mkOption {
              type = lib.types.attrs;
              default = {};
            };
	    port = lib.mkOption {
              type = lib.types.int;
              default = 5432;
              description = "Port to run PostgreSQL on";
            };
	    migrationFolders = lib.mkOption {
              type = lib.types.attrsOf lib.types.path;
              default = {};
              description = "Mapping of database names to migration folder paths";
            };
	    postgresPassword = lib.mkOption {
              type = lib.types.str;
              default = "strongpassword";
              description = "Password for postgres user";
            };
	    environment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Environment variables for PostgreSQL initialScript.";
            };
          };
        };
      
        config = lib.mkIf cfg.enable {
	  systemd.services = lib.mkMerge [
            (lib.mapAttrs' (db: folder: {
               "pgMigration-${db}" = {
                 description = "Apply migrations for database ${db}";
                 wants = [ "postgresql.service" ];
                 after = [ "postgresql.service" ];
                 wantedBy = [ "multi-user.target" ];
                 serviceConfig = {
                   Type = "oneshot";
                   ExecStart = [
                     "${util.packages.${system}.pg-migration}/bin/pg-migration -u postgres://localhost:${cfg.port}/${db} -d ${folder}"
                   ];
                 };
               };
            }) cfg.migrationFolders)
            {
	      postgresql.serviceConfig.Environment =
                builtins.map 
		  (name: "${name}=${cfg.environment.${name}}") (lib.attrNames cfg.environment);
	    }
          ];
          services.postgresql = {
	    enable = true;
            package = cfg.package;
            enableTCPIP = cfg.enableTCPIP;
            settings = { port = lib.mkForce cfg.port; listen_addresses = "*"; } // cfg.settings // {
              shared_preload_libraries = lib.concatStringsSep ", "
                (lib.attrNames (lib.filterAttrs (n: v: v && n != "http" && n != "pgjwt") cfg.extensions));
            };
	    extensions =
	    let 
              packages =  {
		inherit (cfg.package.pkgs) pg_net pgjwt pg_cron http;
	      };
            in
	    lib.attrValues (lib.filterAttrs (n: v: v != null)
              (lib.mapAttrs' (name: enabled:
                if enabled then
                  lib.nameValuePair name (packages.${name} or (throw "Package ${name} not found in pkgs"))
                else null
              ) cfg.extensions)
            );
	    authentication = lib.mkOverride 10 authPresets.${cfg.authPreset};
	    initialScript = pkgs.writeText "init-sql-script" (''
	      \echo '${cfg.postgresPassword}'
	      ALTER USER postgres WITH PASSWORD '${cfg.postgresPassword}';
	      '' + (builtins.readFile cfg.initialScript));
          };
        };
      };
      nixosConfigurations.${system} =
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ({ pkgs, modulesPath, ... }: {
            imports = [
              (modulesPath + "/profiles/qemu-guest.nix")
            ];
	  })
	  self.nixosModules.${system}.postgresqlService
	  {
            hectic.postgres.enable = true;
            hectic.postgres.package = pkgs.postgresql_15;
            hectic.postgres.extensions = {
              pg_cron  = true;
              pgjwt    = true;
              pg_net   = true;
              http  = true;
            };

	    hectic.postgres.authPreset = "allMixed";

	    hectic.postgres.environment = {
              GATEWAY_SCHEMA = "zalupa";
	    };

            # Provide an initial script if needed:
            hectic.postgres.initialScript = 
	    pkgs.writeText "init-sql-script" ''
	      CREATE EXTENSION IF NOT EXISTS "http";
              \set gateway_schema `echo $GATEWAY_SCHEMA`
              SELECT :'gateway_schema' = ''' AS is_gateway_schema;
              \gset
              \if :is_gateway_schema
                \echo 'Error: Environment variable GATEWAY_SCHEMA is not set.'
                \quit 1
              \endif

	      ALTER DATABASE postgres SET "app.gateway" TO :'gateway_schema';
            '';


            hectic.postgres.migrationFolders = { };
	  }
          {
            environment.systemPackages = with pkgs; [ git curl neovim postgresql_15 ];

            virtualisation.vmVariant = {
              services.getty.autologinUser = "root";
              virtualisation.forwardPorts = [
                { from = "host"; host.port = 40500; guest.port = 22; }
                { from = "host"; host.port = 54321; guest.port = 5432; }
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
    });
}
