# cardano-keys

> :warning: **Warning**
>
> This repo is still under construction and packages in it have not been released.

This repository will host `cardano-keys`, the Haskell library of Cardano key types together with the bech32 serialisation layer for them.
That code currently lives in [`cardano-api`](https://github.com/IntersectMBO/cardano-api) and is being extracted into this repository.

## What is in this repository

| Package | What it is |
| --- | --- |
| [`cardano-keys`](cardano-keys/) | The library. Currently incomplete; the key types and their bech32 serialisation are being moved here from `cardano-api`. |

## Requirements

You can build with Nix (easiest: it provides everything) or with your own Haskell toolchain.

**With Nix:**

- [Nix](https://nixos.org/download/) with flakes enabled.
- Answer "yes" when Nix asks to accept the flake settings.
  That enables the IOG binary cache (`cache.iog.io`).
  Without it, you will compile GHC and every dependency from source.
- Works on `x86_64-linux`, `aarch64-linux` and `aarch64-darwin`.

**Without Nix:**

The Developer Portal's [Installing cardano-node](https://developers.cardano.org/docs/operators/node/installing-cardano-node/) guide covers this exact setup step by step.
Follow it up to the point where it starts building the node itself.
In short, you need:

- GHC 9.6, 9.10, 9.12 or 9.14, and Cabal 3.16 (for example via [GHCup](https://www.haskell.org/ghcup/)).
  Development mostly happens on GHC 9.12.
- Cardano's C libraries: `libsodium` (the IOG fork, with VRF support), `libsecp256k1` and `libblst`.
  Prebuilt packages are on the [iohk-nix releases page](https://github.com/input-output-hk/iohk-nix/releases/latest); [this GitHub action](https://github.com/input-output-hk/actions/tree/latest/base) shows how CI installs them.

## Quick start

```bash
git clone https://github.com/IntersectMBO/cardano-keys
cd cardano-keys
nix develop          # skip this line if you are not using Nix
cabal update         # needed at least once, see note below
cabal build all --enable-tests
```

Run the tests:

```bash
cabal test all --enable-tests --test-show-details=direct
```

Build notes:

- `cabal update` downloads the package lists of **two** repositories: Hackage and [CHaP](https://chap.intersectmbo.org/) (Cardano Haskell Packages, where the Cardano-specific dependencies live).
  CHaP is already configured in this repo's `cabal.project`.
- The project builds with `-Werror`, so every warning is an error.
  Stick to the GHC versions listed above.
- The flake provides further development shells: `nix develop .#profiling`, `nix develop .#wasm`,
  and, on x86_64-linux only, `nix develop .#ghc967` and `nix develop .#ghc914` (the haddock
  compiler).

## Using the library in your project

Cardano libraries are released on [CHaP](https://chap.intersectmbo.org/), not on Hackage, so your project needs CHaP configured.

> :warning: **Note**
>
> `cardano-keys` is not published to CHaP yet.
> Until the first release, we don't recommend depending on this package, but if you need to, you can do it directly (for example with a `source-repository-package` stanza in your `cabal.project`).

`cabal.project` points at your package and registers CHaP:

```
packages: .

repository cardano-haskell-packages
  url: https://chap.intersectmbo.org/
  secure: True
  root-keys:
    3e0cce471cf09815f930210f7827266fd09045445d65923e6d0238a6cd15126f
    443abb7fb497a134c343faf52f0b659bd7999bc06b7f63fa76dc99d631f9bea1
    a86a1f6ce86c449c46666bda44268677abf29b5b2d2eb5ec7af903ec2f117a82
    bcec67e8e99cabfa7764d75ad9b158d72bfacf70ca1d0ec8bc6b4406d1bf8413
    c00aae8461a256275598500ea0e187588c35a5d5d7454fb57eac18d9edb86a56
    d4a35cd3121aa00d18544bb0ac01c3e1691d618f462c46129271bccf39f7e8ee
```

(Tip: also pin an `index-state` to make your builds reproducible; see the [CHaP README](https://github.com/IntersectMBO/cardano-haskell-packages).)

Once the package is on CHaP, depending on it will look like this:

```cabal
cabal-version: 3.0
name:          example
version:       0.1.0.0
build-type:    Simple

executable example
  main-is:          Main.hs
  default-language: Haskell2010
  build-depends:
    , base
    , cardano-keys ^>=11.0
    , text
```

Expect the first build to take a while: it compiles a good part of the Cardano stack.
Without Nix, you also need the C libraries from [Requirements](#requirements).

## Documentation

- [Haddock documentation](https://intersectmbo.github.io/cardano-keys/): the full API reference, rebuilt from `master`.
- [Cardano Node Wiki](https://github.com/input-output-hk/cardano-node-wiki/wiki): development documentation.
- [Cardano Developer Portal](https://developers.cardano.org/): if you are new to Cardano itself.

## Contributing

See the [Contributing guide](CONTRIBUTING.md) for how to contribute to this project.

[![x86\_64-linux](https://img.shields.io/endpoint?url=https://ci.iog.io/job/IntersectMBO-cardano-keys/master/x86_64-linux.required/shield&style=flat-square&label=x86_64-linux)](https://ci.iog.io/job/IntersectMBO-cardano-keys/master/x86_64-linux.required)
[![aarch64-darwin](https://img.shields.io/endpoint?url=https://ci.iog.io/job/IntersectMBO-cardano-keys/master/aarch64-darwin.required/shield&style=flat-square&label=aarch64-darwin)](https://ci.iog.io/job/IntersectMBO-cardano-keys/master/aarch64-darwin.required)
[![GHA Build](https://img.shields.io/github/actions/workflow/status/intersectmbo/cardano-keys/haskell.yml?branch=master&label=GHA%20Build&style=flat-square)](https://github.com/IntersectMBO/cardano-keys/actions/workflows/haskell.yml?query=branch%3Amaster)
[![Haddock](https://img.shields.io/github/actions/workflow/status/intersectmbo/cardano-keys/github-page.yml?branch=master&label=Haddocks&style=flat-square)](https://github.com/IntersectMBO/cardano-keys/actions/workflows/github-page.yml?query=branch%3Amaster)
