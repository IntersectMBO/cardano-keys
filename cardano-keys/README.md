# cardano-keys

`cardano-keys` holds the Cardano key types — one type per key role, from payment and stake keys to
the KES, VRF and BLS keys a block-forging node needs — together with the serialisations those keys
have: raw bytes, hex, CBOR, bech32, and the text-envelope JSON format that `cardano-cli` writes.
On top of that it provides operational certificates (decoding, accessors, and the check that a
certificate really names a given KES key) and one small file-reading module, so that a consumer
holding the path of a credential file can get the key out of it without depending on
[`cardano-api`](https://github.com/IntersectMBO/cardano-api). Nothing here is era-dependent and
nothing here builds transactions.

See the [repository README](../README.md) for how to build the project, how to depend on it, and
[what lives here and what stays in `cardano-api`](../README.md#what-lives-here-and-what-stays-in-cardano-api).

## Modules

Every module listed here is exposed. `Cardano.Keys` re-exports the whole public API, so a consumer
can import that module alone; `Cardano.Keys.Serialise.Orphans` has no names of its own to export,
but importing `Cardano.Keys` still brings its instances into scope.

| Module | What it is |
| --- | --- |
| `Cardano.Keys` | The whole public API in a single import. |
| `Cardano.Keys.Byron` | Byron keys, including the legacy signing-key format. |
| `Cardano.Keys.Class` | The `Key` class: the `VerificationKey` and `SigningKey` families, key generation, and the role casts. |
| `Cardano.Keys.HasTypeProxy` | `HasTypeProxy` and the `AsType` index that names a key type at the value level. |
| `Cardano.Keys.Hash` | Key hashes and the casts between hash roles. |
| `Cardano.Keys.IO` | The only module that touches the filesystem: `FileError` and the credential file readers. |
| `Cardano.Keys.Leios` | Leios BLS keys and their possession proofs. |
| `Cardano.Keys.OperationalCertificate` | Operational certificates, their accessors, and `checkKesKeyMatchesOpCert`. |
| `Cardano.Keys.Praos` | The Praos consensus keys: KES and VRF. |
| `Cardano.Keys.Pretty` | Rendering this package's error documents as `Text` or `String`. |
| `Cardano.Keys.Serialise.Bech32` | `SerialiseAsBech32`, its encoders and decoders, and its error type. |
| `Cardano.Keys.Serialise.Cbor` | `SerialiseAsCBOR`. |
| `Cardano.Keys.Serialise.Orphans` | Orphan instances the key layer needs and that no upstream package provides. |
| `Cardano.Keys.Serialise.Raw` | `SerialiseAsRawBytes` and the hex encoders and decoders built on it. |
| `Cardano.Keys.Serialise.TextEnvelope` | The text-envelope type, its JSON codec, and the decoders that accept one of several types. |
| `Cardano.Keys.Serialise.Using` | The `deriving via` newtypes: `UsingRawBytes`, `UsingRawBytesHex`, `UsingBech32`. |
| `Cardano.Keys.Shelley` | The Shelley-onwards key roles — payment, stake, stake pool, DRep, committee, genesis — and their extended variants. |

## Reading a credential

`Cardano.Keys.IO` takes a path and gives back a key. Deciding which files to read, and whether the
combination of them makes sense, stays with the caller; the one cross-file consistency check that is
a statement about two keys rather than about a configuration lives here, in
`checkKesKeyMatchesOpCert`:

```haskell
import Cardano.Keys.IO (FileError, readFileTextEnvelope, renderFileError)
import Cardano.Keys.OperationalCertificate
  ( OperationalCertificate
  , checkKesKeyMatchesOpCert
  , renderKesKeyMismatch
  )
import Cardano.Keys.Praos (KesKey, SigningKey)
import Cardano.Keys.Pretty (docToString)
import Cardano.Keys.Serialise.TextEnvelope (TextEnvelopeError, renderTextEnvelopeError)

import Data.Bifunctor (first)

-- | Read a block-forging node's operational certificate and KES signing key,
-- rejecting the pair unless the certificate names that very KES key.
readForgingCredentials
  :: FilePath
  -> FilePath
  -> IO (Either String (OperationalCertificate, SigningKey KesKey))
readForgingCredentials opCertPath kesKeyPath = do
  opCertFile <- readFileTextEnvelope opCertPath
  kesKeyFile <- readFileTextEnvelope kesKeyPath
  pure $ do
    opCert <- envelope opCertFile
    kesKey <- envelope kesKeyFile
    first (docToString . renderKesKeyMismatch) $
      checkKesKeyMatchesOpCert opCert kesKey
    pure (opCert, kesKey)
 where
  envelope :: Either (FileError TextEnvelopeError) a -> Either String a
  envelope = first (docToString . renderFileError renderTextEnvelopeError)
```

`readFileTextEnvelope` is return-type polymorphic: the type you ask for decides which envelope
`type` strings are accepted, and a file of the wrong type is reported as a `TextEnvelopeTypeError`
naming all of them. The same module also reads bulk credentials files
(`readBulkCredentialsFile`, whose errors name the entry and slot they came from) and the two
Byron files (`readByronSigningKeyFile`, `readByronDelegationCertificateFile`).

## The unsound pure KES key

A `SigningKey KesKey` wraps an `UnsoundPureSignKeyKES`, and the accessor for it is called
`unsoundPureKesSigningKey`. The name is deliberate and is meant to stay visible at the call site:
this is the KES key variant that can be loaded from a file at all, and the mlocked variant exists
precisely so that KES secrets need never touch disk. A node that takes its KES key from a KES agent
never goes through this path.

## Test fixtures

The credential fixtures in [`test/credentials`](test/credentials/README.md) are real
`cardano-cli 11.0.0.0` output, not files this package produced: a fixture built by our own encoder
would round-trip through our own decoder and prove nothing. That provenance is the only evidence
that the operational-certificate payload and the legacy Byron `XPrv` reading path here are
byte-compatible with what `cardano-cli` writes, so they must not be regenerated with anything else.
Their README records the exact commands that made them.

## Status

The package's content is complete, but it has not been released yet: it is not published to CHaP,
and the version stays at `11.0.0.0` until the first release is cut.
