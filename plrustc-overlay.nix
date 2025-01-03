final: prev:
{
  plrustc = prev.callPackage
    ./build-plrustc.nix {
       inherit (prev.darwin.apple_sdk.frameworks) Security;
  };
}
