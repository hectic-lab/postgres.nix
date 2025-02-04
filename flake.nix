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
                pg_cron  = true;
                pgjwt    = true;
                pg_net   = true;
                pg_http  = true;
                plrust   = true;
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
                builtins.map (name: "${name}=${cfg.env.${name}}") (lib.attrNames cfg.env);
	    }
          ];
          services.postgresql = {
            package    = cfg.package;
            enableTCPIP = cfg.enableTCPIP;
            settings = { port = lib.mkForce cfg.port; } // cfg.settings // {
              shared_preload_libraries = lib.concatStringsSep ", "
                (lib.attrNames (lib.filterAttrs (n: v: v) cfg.extensions));
            };
            extensions   = lib.attrValues (lib.filterAttrs (n: v: v) cfg.extensions);
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
            environment.systemPackages = with pkgs; [
              gcc
              clang
              llvm
              makeWrapper
              pkg-config
              git
              gnupg
              wget
	      curl
	      cacert
	      neovim
            ];

            virtualisation.vmVariant = {
              services.getty.autologinUser = "root";
              virtualisation.forwardPorts = [
                { from = "host"; host.port = 40500; guest.port = 22; }
              ];
            };

	    users.users.root.openssh.authorizedKeys.keys = [
              ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICrbBG+U07f7OKvOxYIGYCaNvyozzxQF+I9Fb5TYZErK yukkop vm-postgres''
            ];

            services.openssh = {
              enable = true;
              settings = {
                PasswordAuthentication = true;
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
