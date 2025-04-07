final: prev: let
  generic = with prev;
    {
      version,
      hash,
      cargoHash,
    }:
      rustPlatform.buildRustPackage rec {
        pname = "cargo-pgrx";

        inherit version;

        src = fetchCrate {
          inherit version pname hash;
        };

        inherit cargoHash;

        nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [
          pkg-config
        ];

        buildInputs =
          lib.optionals stdenv.hostPlatform.isLinux [
            openssl
          ]
          ++ lib.optionals stdenv.hostPlatform.isDarwin [
            darwin.apple_sdk.frameworks.Security
          ];

        preCheck = ''
          export PGRX_HOME=$(mktemp -d)
        '';

        checkFlags = [
          # requires pgrx to be properly initialized with cargo pgrx init
          "--skip=command::schema::tests::test_parse_managed_postmasters"
        ];

        meta = with lib; {
          description = "Build Postgres Extensions with Rust";
          homepage = "https://github.com/pgcentralfoundation/pgrx";
          changelog = "https://github.com/pgcentralfoundation/pgrx/releases/tag/v${version}";
          license = licenses.mit;
          maintainers = with maintainers; [happysalada];
          mainProgram = "cargo-pgrx";
        };
      };
in {
  cargo-pgrx = generic {
    version = "0.11.0";
    hash = "sha256-GiUjsSqnrUNgiT/d3b8uK9BV7cHFvaDoq6cUGRwPigM=";
    cargoHash = "sha256-oXOPpK8VWzbFE1xHBQYyM5+YP/pRdLvTVN/fjxrgD/c=";
  };
}
