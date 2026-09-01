-- | Placeholder module for the @cardano-keys@ package.
--
-- This module is /temporary/ and carries no useful functionality. It exists so
-- that the bootstrap of this repository has something to compile, and it
-- deliberately touches every dependency the real code will need, so that the
-- toolchain is proven end to end: package resolution against Cardano Haskell
-- Packages (CHaP), @bech32@ for the serialisation layer, and
-- @cardano-crypto-class@ for the hashing primitives (which in turn links the
-- @libsodium@, @libsecp256k1@ and @libblst@ C libraries).
--
-- It will be replaced wholesale by the real key types and their bech32
-- serialisation layer in follow-up pull requests.
-- Nothing exported here is stable; do not depend on it.
module Cardano.Keys
  ( placeholderBech32RoundTrip
  , placeholderBlake2b_256
  )
where

import Cardano.Crypto.Hash.Blake2b qualified as Blake2b
import Cardano.Crypto.Hash.Class qualified as Crypto

import Codec.Binary.Bech32 qualified as Bech32
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding qualified as Text

-- | The human readable prefix used by 'placeholderBech32RoundTrip'.
placeholderHumanReadablePrefix :: Text
placeholderHumanReadablePrefix = "placeholder"

-- | Bech32-encode the UTF-8 bytes of the given text under a fixed human
-- readable prefix, decode the result again and return the recovered text.
--
-- A successful call therefore returns its own argument. Any failure is
-- reported as a rendered error message.
placeholderBech32RoundTrip :: Text -> Either String Text
placeholderBech32RoundTrip text = do
  humanReadablePart <-
    first show $ Bech32.humanReadablePartFromText placeholderHumanReadablePrefix
  let encoded =
        Bech32.encodeLenient
          humanReadablePart
          (Bech32.dataPartFromBytes (Text.encodeUtf8 text))
  (_decodedPrefix, dataPart) <- first show $ Bech32.decodeLenient encoded
  bytes <-
    maybe (Left "placeholderBech32RoundTrip: the data part is not a whole number of bytes") Right $
      Bech32.dataPartToBytes dataPart
  first show $ Text.decodeUtf8' bytes

-- | Hash the given bytes with Blake2b-256, returning the 32 raw bytes of the
-- digest.
placeholderBlake2b_256 :: ByteString -> ByteString
placeholderBlake2b_256 bytes =
  Crypto.hashToBytes (Crypto.hashWith id bytes :: Crypto.Hash Blake2b.Blake2b_256 ByteString)
