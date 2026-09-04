{
  stdenvNoCC,
  fetchFromGitHub,
  autoreconfHook,
  wasi-sdk,
  runCommandLocal,
}:
let
  # Upstream libsodium provides the shared object. GHC's wasm dynamic loader
  # instantiates it for Template Haskell; it has no crypto_vrf_* symbols, so
  # the VRF entry points stay unresolved imports there, which is fine because
  # nothing calls VRF at splice time.
  upstream = stdenvNoCC.mkDerivation {
    name = "libsodium-upstream";

    src = fetchFromGitHub {
      owner = "jedisct1";
      repo = "libsodium";
      rev = "9511c982fb1d046470a8b42aa36556cdb7da15de";
      hash = "sha256-ZPVzKJZRglZT2EJKqdBu94I4TRrF5sujSglUR64ApWA=";
    };

    nativeBuildInputs = [
      wasi-sdk
      autoreconfHook
    ];

    configureFlags = [
      "--host=wasm32-wasi"
    ];

    postInstall = ''
      wasm32-wasi-clang -shared -Wl,--whole-archive $out/lib/libsodium.a -o $out/lib/libsodium.so
    '';
  };

  # IOG's VRF fork, the same revision iohkNix pins for the native build
  # (flake.lock input "sodium"), provides the static archive: executables are
  # linked statically on wasm, and cardano-crypto-praos needs the fork's
  # crypto_vrf_ietfdraft03_* API at that link. The fork's 1.0.18 base predates
  # libsodium's own wasm support, hence the WASI emulation layers.
  vrf = stdenvNoCC.mkDerivation {
    name = "libsodium-vrf-static";

    src = fetchFromGitHub {
      owner = "input-output-hk";
      repo = "libsodium";
      rev = "dbb48cce5429cb6585c9034f002568964f1ce567";
      hash = "sha256-0uRcN5gvMwO7MCXVYnoqG/OmeBFi8qRVnDWJLnBb9+Y=";
    };

    nativeBuildInputs = [
      wasi-sdk
      autoreconfHook
    ];

    configureFlags = [
      "--host=wasm32-wasi"
      "--disable-shared"
    ];

    CFLAGS = "-D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN";
    LDFLAGS = "-lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-mman";
  };
in
# One installation directory with the upstream shared object and the fork's
# static archive, so dynamic (Template Haskell) links see no mismatched VRF
# definitions while executable links get the VRF implementation.
runCommandLocal "libsodium" {} ''
  mkdir -p $out
  cp -r ${upstream}/* $out/
  chmod -R +w $out
  cp ${vrf}/lib/libsodium.a $out/lib/libsodium.a
  for pc in $out/lib/pkgconfig/*.pc; do
    substituteInPlace "$pc" --replace-fail "${upstream}" "$out"
  done
''
