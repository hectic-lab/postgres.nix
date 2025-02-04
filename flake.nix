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
	(import ./cargo-pgrx-overlay.nix)
	(import ./plrustc-overlay.nix)
      ];
    in
    util.lib.forSpecSystemsWithPkgs ([ "x86_64-linux" "aarch64-linux" ]) overlays ({ system, pkgs }:
    let 
      lib = pkgs.lib;
      postgresql = pkgs.postgresql_16;

      buildPostgresqlExtension = pkgs.callPackage
        (import (builtins.path {
          name = "extension-builder";
          path = "${nixpkgs.outPath}/pkgs/servers/sql/postgresql/buildPostgresqlExtension.nix";
        })) { inherit postgresql; };

      plrust = pkgs.callPackage
        ./build-plrust.nix {
           inherit (pkgs.darwin.apple_sdk.frameworks) Security;
	} {};

      pg_http = let
        version = "1.6.1";
      in 
      buildPostgresqlExtension { 
        pname = "pg_http";
        inherit version;
        
        src = pkgs.fetchFromGitHub {
          owner = "pramsey";
          repo = "pgsql-http";
          rev = "5e2bd270a9ce2b0e8e1fdf8e46b85396bd4125cd";
          hash = "sha256-C8eqi0q1dnshUAZjIsZFwa5FTYc7vmATF3vv2CReWPM=";
        };

        nativeBuildInputs = [ pkgs.pkg-config pkgs.curl ];
      };
    in
    {
      packages.${system} = {
        plrust = plrust;
	pg_http = pg_http;
      };
      nixosModules.${system}.postgresqlService = { lib, config, pkgs, ... }: let
        cfg = config.hectic.postgres;
      in {
        options = {
          hectic.postgres = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
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
                pg_http  = false;
                plrust   = false;
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
            settings = { port = lib.mkForce cfg.port; } // cfg.settings // {
              shared_preload_libraries = lib.concatStringsSep ", "
                (lib.attrNames (lib.filterAttrs (n: v: v && n != "pg_http" && n != "pgjwt") cfg.extensions));
            };
	    extensions =
	    let 
              packages =  {
                inherit (self.packages.${system}) plrust pg_http;
		inherit (cfg.package.pkgs) pg_net pgjwt pg_cron;
	      };
            in
	    lib.attrValues (lib.filterAttrs (n: v: v != null)
              (lib.mapAttrs' (name: enabled:
                if enabled then
                  lib.nameValuePair name (packages.${name} or (throw "Package ${name} not found in pkgs"))
                else null
              ) cfg.extensions)
            );
	    initialScript = cfg.initialScript;
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
              pg_http  = true;
            };

	    hectic.postgres.environment = {
              GATEWAY_SCHEMA = "zalupa";
	    };

            # Provide an initial script if needed:
            hectic.postgres.initialScript = 
	    pkgs.writeText "init-sql-script" ''
              \set gateway_schema `echo $GATEWAY_SCHEMA`
              SELECT :'gateway_schema' = '''''' AS is_gateway_schema;
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
              ];
            };

	    system.stateVersion = "24.11";
          }
        ];
      };
    });
}
