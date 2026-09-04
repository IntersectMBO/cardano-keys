{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Tests for the bech32 serialisation of the key catalogue.
--
-- Everything here is pure: every key comes from 'deterministicSigningKey' on a
-- fixed seed, so the encodings below are literals that must not drift.
module Test.Cardano.Keys.Bech32 (tests) where

import Cardano.Keys.Class (Key (..))
import Cardano.Keys.HasTypeProxy (HasTypeProxy, asType)
import Cardano.Keys.Leios (AsType (AsBlsKey))
import Cardano.Keys.Praos (AsType (AsKesKey, AsVrfKey))
import Cardano.Keys.Pretty (docToText)
import Cardano.Keys.Serialise.Bech32
import Cardano.Keys.Shelley

import Cardano.Crypto.Seed qualified as Crypto

import Codec.Binary.Bech32 qualified as Bech32
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding.Error (UnicodeException (DecodeError))

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "bech32"
    [ prefixTests
    , roundTripTests
    , encodingTests
    , renderTests
    , jsonTests
    ]

--
-- Deterministic key material
--

-- | The signing key of a role, from a seed of a single repeated byte.
sk :: Key r => AsType r -> SigningKey r
sk t =
  deterministicSigningKey t $
    Crypto.mkSeedFromBytes (BS.replicate (fromIntegral (deterministicSigningKeySeedSize t)) 42)

-- | The verification key of a role, from 'sk'.
vk :: (Key r, HasTypeProxy r) => AsType r -> VerificationKey r
vk = getVerificationKey . sk

-- | The verification key hash of a role, from 'vk'.
kh :: (Key r, HasTypeProxy r) => AsType r -> Hash r
kh = verificationKeyHash . vk

--
-- The prefix catalogue
--

-- | A value of some type in the bech32 catalogue, so that one table can hold
-- verification keys, signing keys and hashes together.
data SomeBech32 = forall a. SerialiseAsBech32 a => SomeBech32 a

-- | Every 'SerialiseAsBech32' instance in the moved catalogue, pinned to the
-- exact human-readable prefix it encodes with.
--
-- These prefixes are the wire format of every bech32 key string @cardano-cli@
-- has ever printed, so changing one is a silent incompatibility.
prefixTable :: [(Text, SomeBech32)]
prefixTable =
  [ -- Payment
    ("addr_vk", SomeBech32 (vk AsPaymentKey))
  , ("addr_sk", SomeBech32 (sk AsPaymentKey))
  , ("addr_xvk", SomeBech32 (vk AsPaymentExtendedKey))
  , ("addr_xsk", SomeBech32 (sk AsPaymentExtendedKey))
  , -- Stake
    ("stake_vk", SomeBech32 (vk AsStakeKey))
  , ("stake_sk", SomeBech32 (sk AsStakeKey))
  , ("stake_xvk", SomeBech32 (vk AsStakeExtendedKey))
  , ("stake_xsk", SomeBech32 (sk AsStakeExtendedKey))
  , -- Constitutional committee
    ("cc_hot", SomeBech32 (kh AsCommitteeHotKey))
  , ("cc_hot_vk", SomeBech32 (vk AsCommitteeHotKey))
  , ("cc_hot_sk", SomeBech32 (sk AsCommitteeHotKey))
  , ("cc_cold", SomeBech32 (kh AsCommitteeColdKey))
  , ("cc_cold_vk", SomeBech32 (vk AsCommitteeColdKey))
  , ("cc_cold_sk", SomeBech32 (sk AsCommitteeColdKey))
  , ("cc_cold_xvk", SomeBech32 (vk AsCommitteeColdExtendedKey))
  , ("cc_cold_xsk", SomeBech32 (sk AsCommitteeColdExtendedKey))
  , ("cc_hot_xvk", SomeBech32 (vk AsCommitteeHotExtendedKey))
  , ("cc_hot_xsk", SomeBech32 (sk AsCommitteeHotExtendedKey))
  , -- Stake pool
    ("pool_vk", SomeBech32 (vk AsStakePoolKey))
  , ("pool_sk", SomeBech32 (sk AsStakePoolKey))
  , ("pool", SomeBech32 (kh AsStakePoolKey))
  , ("pool_xvkh", SomeBech32 (kh AsStakePoolExtendedKey))
  , ("pool_xvk", SomeBech32 (vk AsStakePoolExtendedKey))
  , ("pool_xsk", SomeBech32 (sk AsStakePoolExtendedKey))
  , -- DRep
    ("drep_vk", SomeBech32 (vk AsDRepKey))
  , ("drep_sk", SomeBech32 (sk AsDRepKey))
  , ("drep", SomeBech32 (kh AsDRepKey))
  , ("drep_xvk", SomeBech32 (vk AsDRepExtendedKey))
  , ("drep_xsk", SomeBech32 (sk AsDRepExtendedKey))
  , -- Praos consensus keys
    ("kes_vk", SomeBech32 (vk AsKesKey))
  , ("kes_sk", SomeBech32 (sk AsKesKey))
  , ("vrf_vk", SomeBech32 (vk AsVrfKey))
  , ("vrf_sk", SomeBech32 (sk AsVrfKey))
  , -- Leios
    ("bls_vk", SomeBech32 (vk AsBlsKey))
  , ("bls_sk", SomeBech32 (sk AsBlsKey))
  ]

-- | 'bech32PrefixesPermitted' at the type of a value, so that the table above
-- can check both methods of the class without naming 35 types twice.
prefixesPermittedFor :: forall a. SerialiseAsBech32 a => a -> [Bech32.HumanReadablePart]
prefixesPermittedFor _ = bech32PrefixesPermitted (asType @a)

-- | Both methods of every instance, against the prefix table.
prefixTests :: TestTree
prefixTests =
  testGroup
    "prefixes"
    [ testCase (Text.unpack expected) $ case some of
        SomeBech32 v -> do
          assertEqual
            "bech32PrefixFor"
            expected
            (Bech32.humanReadablePartToText (bech32PrefixFor v))
          assertEqual
            "bech32PrefixesPermitted"
            [expected]
            (map Bech32.humanReadablePartToText (prefixesPermittedFor v))
    | (expected, some) <- prefixTable
    ]

--
-- Round trips
--

-- | Encode, decode at the same type, and re-encode.
reserialise :: forall a. SerialiseAsBech32 a => a -> Either Bech32DecodeError Text
reserialise v =
  serialiseToBech32 <$> (deserialiseFromBech32 (serialiseToBech32 v) :: Either Bech32DecodeError a)

-- | Every catalogue entry survives 'serialiseToBech32' then
-- 'deserialiseFromBech32'.
--
-- The comparison is on the re-encoded string because most signing keys have no
-- 'Eq' instance.
roundTripTests :: TestTree
roundTripTests =
  testGroup
    "round trip"
    [ testCase (Text.unpack expected) $ case some of
        SomeBech32 v ->
          case reserialise v of
            Left err -> assertFailure ("could not decode what we encoded: " <> show err)
            Right actual -> assertEqual "re-encoded" (serialiseToBech32 v) actual
    | (expected, some) <- prefixTable
    ]

--
-- Pinned encodings
--

-- | One representative of each prefix family, encoded in full.
--
-- The prefix tests above would not notice a change in how the payload is laid
-- out; these would.
encodingTests :: TestTree
encodingTests =
  testGroup
    "encodings"
    [ pinned
        "addr_vk"
        (vk AsPaymentKey)
        "addr_vk1r9lkkglpdjzn934tequ04n2757ymurrkk2fqxdqrn0agk0fk34ss7hne6a"
    , pinned
        "stake_vk"
        (vk AsStakeKey)
        "stake_vk1r9lkkglpdjzn934tequ04n2757ymurrkk2fqxdqrn0agk0fk34ssj0t336"
    , pinned "cc_hot" (kh AsCommitteeHotKey) "cc_hot1rhahf2xtek39f3jmth2ajh0cnast9zc3mex69hknhs0ekezvwa2"
    , pinned "pool" (kh AsStakePoolKey) "pool1rhahf2xtek39f3jmth2ajh0cnast9zc3mex69hknhs0ekw36gjg"
    , pinned "drep" (kh AsDRepKey) "drep1rhahf2xtek39f3jmth2ajh0cnast9zc3mex69hknhs0ek43pf4j"
    , pinned "kes_vk" (vk AsKesKey) "kes_vk19l525dpv3zayhznpe722x4rxt589ydl8e6pl6wndsldlkpnnsarse0x3ul"
    , pinned "vrf_vk" (vk AsVrfKey) "vrf_vk1r9lkkglpdjzn934tequ04n2757ymurrkk2fqxdqrn0agk0fk34ssqwpse7"
    , pinned
        "bls_vk"
        (vk AsBlsKey)
        "bls_vk1546k24pw4gq772u3p0cw4wjdnzs7tw9hnnzztkcglpuqwvksa2dush7xza0jw2ergjaj00zh96l3gq3w2f5fmnklen6y5q89h5d2t8d5g5tjzlttpusmxusknmnkryuv9zg5mh9evc772ndj3rnkp28pfu0jrwys"
    ]
 where
  pinned name v expected =
    testCase name $ assertEqual "encoded" expected (serialiseToBech32 v)

--
-- Rendered errors
--

-- | Every constructor of 'Bech32DecodeError' rendered, pinned to the exact
-- messages the origin's golden files record.
renderTests :: TestTree
renderTests =
  testGroup
    "rendered errors"
    [ pinnedRender
        "Bech32DecodingError"
        (Bech32DecodingError Bech32.StringToDecodeTooLong)
        "StringToDecodeTooLong"
    , pinnedRender
        "Bech32UnexpectedPrefix"
        (Bech32UnexpectedPrefix "<text>" (Set.singleton "<text>"))
        ( "Unexpected Bech32 prefix: the actual prefix is \"<text>\", "
            <> "but it was expected to be \"<text>\""
        )
    , pinnedRender
        "Bech32DataPartToBytesError"
        (Bech32DataPartToBytesError "<text>")
        ( "There was an error in extracting the bytes from the data part of the "
            <> "Bech32-encoded string."
        )
    , pinnedRender
        "Bech32DeserialiseFromBytesError"
        (Bech32DeserialiseFromBytesError "<bytes>")
        ( "There was an error in deserialising the data part of the "
            <> "Bech32-encoded string into a value of the expected type."
        )
    , pinnedRender
        "Bech32WrongPrefix"
        (Bech32WrongPrefix "<text>" "<text>")
        ( "Mismatch in the Bech32 prefix: the actual prefix is \"<text>\", "
            <> "but the prefix for this payload value should be \"<text>\""
        )
    , pinnedRender
        "Bech32UnexpectedHeader"
        (Bech32UnexpectedHeader "<text>" "<text>")
        ( "Unexpected CIP-129 Bech32 header: the actual header is \"<text>\", "
            <> "but it was expected to be \"<text>\""
        )
    , pinnedRender
        "Bech32InvalidUtf8"
        (Bech32InvalidUtf8 (DecodeError "<decode error>" (Just 0xc3)))
        "The Bech32-encoded string is not valid UTF-8: Cannot decode byte '\\xc3': <decode error>"
    ]
 where
  pinnedRender name err expected =
    testCase name $ assertEqual "rendered" expected (docToText (renderBech32DecodeError err))

--
-- The bech32-backed JSON instances
--

-- | The three key hashes whose JSON is bech32 rather than hex.
--
-- @cardano-cli@ prints pool ids and DRep ids from these instances, so the
-- literals below are part of its output format.
jsonTests :: TestTree
jsonTests =
  testGroup
    "JSON"
    [ testCase "Hash StakePoolKey encodes as a pool1 string" $
        assertEqual
          "encoded"
          "\"pool1rhahf2xtek39f3jmth2ajh0cnast9zc3mex69hknhs0ekw36gjg\""
          (Aeson.encode (kh AsStakePoolKey))
    , testCase "Hash StakePoolKey is a bech32 JSON key" $
        assertEqual
          "encoded"
          "{\"pool1rhahf2xtek39f3jmth2ajh0cnast9zc3mex69hknhs0ekw36gjg\":1}"
          (Aeson.encode (Map.singleton (kh AsStakePoolKey) (1 :: Int)))
    , testCase "Hash StakePoolKey round-trips through JSON" $
        roundTripJSON (kh AsStakePoolKey)
    , testCase "Hash StakePoolExtendedKey encodes as a pool_xvkh1 string" $
        assertEqual
          "encoded"
          "\"pool_xvkh1l22t9uru4c8uc94t2r04rcvrk29rsxueyysnt5x2eg0fqwn6efp\""
          (Aeson.encode (kh AsStakePoolExtendedKey))
    , testCase "Hash StakePoolExtendedKey round-trips through JSON" $
        roundTripJSON (kh AsStakePoolExtendedKey)
    , testCase "Hash DRepKey encodes as a drep1 string" $
        assertEqual
          "encoded"
          "\"drep1rhahf2xtek39f3jmth2ajh0cnast9zc3mex69hknhs0ek43pf4j\""
          (Aeson.encode (kh AsDRepKey))
    , testCase "Hash DRepKey round-trips through JSON" $
        roundTripJSON (kh AsDRepKey)
    ]
 where
  roundTripJSON
    :: forall a
     . (Aeson.ToJSON a, Aeson.FromJSON a, SerialiseAsBech32 a)
    => a
    -> IO ()
  roundTripJSON v =
    case Aeson.eitherDecode (Aeson.encode v) of
      Left err -> assertFailure ("could not decode what we encoded: " <> err)
      Right v' ->
        assertEqual "re-encoded" (serialiseToBech32 v) (serialiseToBech32 (v' :: a))
