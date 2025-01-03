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
    y-util = {
      url = "github:yukkop/y.util.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs = { self, nixpkgs, y-util, rust-overlay, ... }:
    let
      trace = builtins.trace; # can change to builtins.traceVerbose to make it silent
      overlays = [ 
        (import rust-overlay)
	(import ./cargo-pgrx-overlay.nix)
	(import ./plrustc-overlay.nix)
      ];
    in
    y-util.lib.forSpecSystemsWithPkgs ([ "x86_64-linux" "aarch64-linux" ]) overlays ({ system, pkgs }:
    let 
      lib = pkgs.lib;
      postgresql = pkgs.postgresql_16;

      rustToolchain = pkgs.pkgsBuildHost.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

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
        plrustc = pkgs.plrustc;
	pg_http = pg_http;
	cargo-pgrx = pkgs.cargo-pgrx;
      };
      nixosModules.${system}.postgresqlService = {
            services.postgresql = {
              enable = true;
              package = postgresql;
              enableTCPIP = true;
              #settings = import ./postgresql.conf.nix;
              settings.shared_preload_libraries = "pg_cron, plrust";
	      extensions = (with postgresql.pkgs; [ pg_cron pgjwt ]) ++ [ plrust pg_http];
              # initialScript = ./src/some_init_script.sql;
            };
      };
      nixosConfigurations.${system}.default =
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ({ pkgs, modulesPath, ... }: {
            imports = [
              (modulesPath + "/profiles/qemu-guest.nix")
            ];
	  })
	  self.nixosModules.${system}.postgresqlService
          # Основные настройки
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
	      #virtualisation.qemu.options = [
	      #  "-nographic" 
	      #  "-display" "curses"
	      #  "-append" "console=ttyS0"
	      #  "-serial" "mon:stdio"
	      #  "-vga" "qxl"
	      #];
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


            # Создаем каталог /var/lib/postgresql/plrust как в Dockerfile
            #systemd.tmpfiles.rules = [
            #  "d /var/log/postgresql 0755 postgres postgres -"
            #  "d /var/lib/postgresql/plrust 0755 postgres postgres -"
            #];

	    networking.firewall = {
              enable = true;
              allowedTCPPorts = [
		22
              ];
            };

            # Пример копирования postgresql.conf, если он лежит рядом
            #environment.etc."postgresql/postgresql.conf".source = ./postgresql.conf;

            # Если нужны какие-то другие файлы (например, allowed-dependencies.toml):
            # environment.etc."postgresql/allowed-dependencies.toml".source = ./allowed-dependencies.toml;
            # и т.д.

	    system.stateVersion = "24.11";
          }
        ];
      };
    });
}
