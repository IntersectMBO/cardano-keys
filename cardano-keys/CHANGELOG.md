# Changelog for cardano-keys

## 11.0.0.0 -- 2026-09-15

- Add the key layer ported from `cardano-config` PR #13: the Cardano key types for every key role, with their raw-bytes, hex, CBOR and text-envelope serialisation.
  Bring the bech32 serialisation layer over with the types, so that `SerialiseAsBech32`, `UsingBech32` and the bech32-backed JSON instances are not orphans.
  Let a type accept several text envelope type strings, writing the first of them.
  Add the operational certificate accessors and the `checkKesKeyMatchesOpCert` consistency check, plus the credential file readers asked for in issue #2.
  (feature)
  [PR 4](https://github.com/intersectmbo/cardano-keys/pull/4)

