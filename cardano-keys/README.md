# cardano-keys

The `cardano-keys` package will provides the Cardano key types together with the bech32 serialisation
layer for them. That code currently lives in
[`cardano-api`](https://github.com/IntersectMBO/cardano-api) and is currently being moved here.

Right now this is a stub. It compiles and exercises the dependency toolchain
(CHaP resolution, `bech32`, `cardano-crypto-class` and the Cardano C libraries), but it does not
export any key types yet, and nothing it does export is stable.

See the [repository README](../README.md) for how to build the project and how to depend on it.
