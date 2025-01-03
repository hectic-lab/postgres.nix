{ lib
, rustPlatform
, fetchFromGitHub
, pkg-config
, cargo-pgrx
, postgresql
, Security
, bash
, pkgsBuildHost
}:
let
  rustToolchain = pkgsBuildHost.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
  pgrxPostgresMajor = lib.versions.major postgresql.version;
in
rustPlatform.buildRustPackage {
  pname = "plrustc";
  version = "1.2.8"; # Update this to the appropriate version

  src = (fetchFromGitHub {
    owner = "tcdi";
    repo  = "plrust";
    rev   = "v1.2.8"; # Ensure this is the correct commit for plrustc
    sha256 = "sha256-AW1ZcVNTROXueGoLeByfsC5YeSJ8+Z7GiRi2EGMlhqU=";
  }) + "/plrustc";

  cargoHash = "sha256-x9Uh5AyJCX90Spie1D35I/cSkbWVrK9knGIdUPfO22o=";

  # Specify any additional build inputs specific to plrustc
  nativeBuildInputs = [
    cargo-pgrx
    pkg-config
    postgresql
    Security
    rustToolchain
  ];

  buildInputs = [
  ];

  buildPhase = ''
    runHook preBuild

    echo "Building plrustc"
    ${bash}/bin/bash ./build.sh

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp ../build/bin/plrustc $out/bin/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Separate compiler for plrust PostgreSQL extension";
    homepage = "https://github.com/tcdi/plrust";
    license = licenses.mit;
    maintainers = with maintainers; [ yourName ]; # Replace with actual maintainer
  };
}
