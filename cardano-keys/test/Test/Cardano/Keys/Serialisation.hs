{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Tests for the serialisation of the key catalogue.
--
-- Everything here is pure: the envelope @type@ strings every 'HasTextEnvelope'
-- instance writes, the several type strings one instance can accept, the text
-- the document of 'renderTextEnvelopeError' lays out, and a CBOR round-trip of
-- a Byron signing key made from a fixed seed.
module Test.Cardano.Keys.Serialisation (tests) where

import Cardano.Keys.Byron (AsType (AsByronKey), ByronKey, ByronKeyLegacy)
import Cardano.Keys.Class (Key (..))
import Cardano.Keys.HasTypeProxy (HasTypeProxy (..), asType)
import Cardano.Keys.Leios (BlsKey, BlsPossessionProof)
import Cardano.Keys.OperationalCertificate
  ( OperationalCertificate
  , OperationalCertificateIssueCounter
  )
import Cardano.Keys.Praos (KesKey, VrfKey)
import Cardano.Keys.Pretty (docToText)
import Cardano.Keys.Serialise.Cbor
  ( FromCBOR
  , SerialiseAsCBOR
  , ToCBOR
  , deserialiseFromCBOR
  , serialiseToCBOR
  )
import Cardano.Keys.Serialise.TextEnvelope
  ( HasTextEnvelope (..)
  , TextEnvelope (..)
  , TextEnvelopeDescr (..)
  , TextEnvelopeError (..)
  , TextEnvelopeType (..)
  , deserialiseFromTextEnvelope
  , renderTextEnvelopeError
  , serialiseToTextEnvelope
  , textEnvelopeType
  )
import Cardano.Keys.Shelley

import Cardano.Binary (DecoderError (..))
import Cardano.Crypto.Seed (mkSeedFromBytes)

import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "keys"
    [ envelopeTypeTests
    , envelopeAcceptanceTests
    , renderTextEnvelopeErrorTests
    , byronKeyCborTests
    ]

--
-- The role catalogue
--

-- | Every 'HasTextEnvelope' instance in the moved catalogue, pinned to the exact
-- @type@ string it writes into a text envelope.
--
-- These strings are the on-disk format, shared with every key file
-- @cardano-cli@ has written, so changing one is a silent incompatibility.
envelopeTypeTests :: TestTree
envelopeTypeTests =
  testGroup
    "text envelope types"
    [ testCase (Text.unpack expected) $
        assertEqual "envelope type" (TextEnvelopeType (Text.unpack expected)) actual
    | (expected, actual) <- envelopeTypeTable
    ]

envelopeTypeTable :: [(Text, TextEnvelopeType)]
envelopeTypeTable =
  [ -- Payment
    ("PaymentVerificationKeyShelley_ed25519", ty @(VerificationKey PaymentKey))
  , ("PaymentSigningKeyShelley_ed25519", ty @(SigningKey PaymentKey))
  , ("PaymentExtendedVerificationKeyShelley_ed25519_bip32", ty @(VerificationKey PaymentExtendedKey))
  , ("PaymentExtendedSigningKeyShelley_ed25519_bip32", ty @(SigningKey PaymentExtendedKey))
  , -- Stake
    ("StakeVerificationKeyShelley_ed25519", ty @(VerificationKey StakeKey))
  , ("StakeSigningKeyShelley_ed25519", ty @(SigningKey StakeKey))
  , ("StakeExtendedVerificationKeyShelley_ed25519_bip32", ty @(VerificationKey StakeExtendedKey))
  , ("StakeExtendedSigningKeyShelley_ed25519_bip32", ty @(SigningKey StakeExtendedKey))
  , -- Genesis
    ("GenesisVerificationKey_ed25519", ty @(VerificationKey GenesisKey))
  , ("GenesisSigningKey_ed25519", ty @(SigningKey GenesisKey))
  , ("GenesisExtendedVerificationKey_ed25519_bip32", ty @(VerificationKey GenesisExtendedKey))
  , ("GenesisExtendedSigningKey_ed25519_bip32", ty @(SigningKey GenesisExtendedKey))
  , ("GenesisDelegateVerificationKey_ed25519", ty @(VerificationKey GenesisDelegateKey))
  , ("GenesisDelegateSigningKey_ed25519", ty @(SigningKey GenesisDelegateKey))
  ,
    ( "GenesisDelegateExtendedVerificationKey_ed25519_bip32"
    , ty @(VerificationKey GenesisDelegateExtendedKey)
    )
  , ("GenesisDelegateExtendedSigningKey_ed25519_bip32", ty @(SigningKey GenesisDelegateExtendedKey))
  , ("GenesisUTxOVerificationKey_ed25519", ty @(VerificationKey GenesisUTxOKey))
  , ("GenesisUTxOSigningKey_ed25519", ty @(SigningKey GenesisUTxOKey))
  , -- Stake pool
    ("StakePoolVerificationKey_ed25519", ty @(VerificationKey StakePoolKey))
  , ("StakePoolSigningKey_ed25519", ty @(SigningKey StakePoolKey))
  , ("StakePoolExtendedVerificationKey_ed25519_bip32", ty @(VerificationKey StakePoolExtendedKey))
  , ("StakePoolExtendedSigningKey_ed25519_bip32", ty @(SigningKey StakePoolExtendedKey))
  , -- DRep
    ("DRepVerificationKey_ed25519", ty @(VerificationKey DRepKey))
  , ("DRepSigningKey_ed25519", ty @(SigningKey DRepKey))
  , ("DRepExtendedVerificationKey_ed25519_bip32", ty @(VerificationKey DRepExtendedKey))
  , ("DRepExtendedSigningKey_ed25519_bip32", ty @(SigningKey DRepExtendedKey))
  , -- Constitutional committee
    ("ConstitutionalCommitteeColdVerificationKey_ed25519", ty @(VerificationKey CommitteeColdKey))
  , ("ConstitutionalCommitteeColdSigningKey_ed25519", ty @(SigningKey CommitteeColdKey))
  ,
    ( "ConstitutionalCommitteeColdExtendedVerificationKey_ed25519_bip32"
    , ty @(VerificationKey CommitteeColdExtendedKey)
    )
  ,
    ( "ConstitutionalCommitteeColdExtendedSigningKey_ed25519_bip32"
    , ty @(SigningKey CommitteeColdExtendedKey)
    )
  , ("ConstitutionalCommitteeHotVerificationKey_ed25519", ty @(VerificationKey CommitteeHotKey))
  , ("ConstitutionalCommitteeHotSigningKey_ed25519", ty @(SigningKey CommitteeHotKey))
  ,
    ( "ConstitutionalCommitteeHotExtendedVerificationKey_ed25519_bip32"
    , ty @(VerificationKey CommitteeHotExtendedKey)
    )
  ,
    ( "ConstitutionalCommitteeHotExtendedSigningKey_ed25519_bip32"
    , ty @(SigningKey CommitteeHotExtendedKey)
    )
  , -- Praos consensus keys
    ("KesVerificationKey_ed25519_kes_2^6", ty @(VerificationKey KesKey))
  , ("KesSigningKey_ed25519_kes_2^6", ty @(SigningKey KesKey))
  , ("VrfVerificationKey_PraosVRF", ty @(VerificationKey VrfKey))
  , ("VrfSigningKey_PraosVRF", ty @(SigningKey VrfKey))
  , -- Leios

    ( "BlsVerificationKey_bls12-381-BLS-Signature-Mininimal-Signature-Size"
    , ty @(VerificationKey BlsKey)
    )
  , ("BlsSigningKey_bls12-381-BLS-Signature-Mininimal-Signature-Size", ty @(SigningKey BlsKey))
  , ("BlsPossessionProof_bls12-381-BLS-Signature-Mininimal-Signature-Size", ty @BlsPossessionProof)
  , -- Byron
    ("PaymentVerificationKeyByron_ed25519_bip32", ty @(VerificationKey ByronKey))
  , ("PaymentSigningKeyByron_ed25519_bip32", ty @(SigningKey ByronKey))
  , ("PaymentVerificationKeyByronLegacy_ed25519_bip32", ty @(VerificationKey ByronKeyLegacy))
  , ("PaymentSigningKeyByronLegacy_ed25519_bip32", ty @(SigningKey ByronKeyLegacy))
  , -- Operational certificates
    ("NodeOperationalCertificate", ty @OperationalCertificate)
  , ("NodeOperationalCertificateIssueCounter", ty @OperationalCertificateIssueCounter)
  ]

ty :: forall a. HasTextEnvelope a => TextEnvelopeType
ty = textEnvelopeType (asType @a)

--
-- Several accepted envelope types
--

-- | A type that accepts two envelope @type@ strings, to exercise the mechanism
-- that no shipped instance needs yet: every instance of the catalogue above
-- still accepts exactly the one string it writes.
newtype Legacy = Legacy Word8
  deriving stock (Eq, Show)
  deriving newtype (ToCBOR, FromCBOR)

instance HasTypeProxy Legacy where
  data AsType Legacy = AsLegacy
  proxyToAsType _ = AsLegacy

instance SerialiseAsCBOR Legacy

instance HasTextEnvelope Legacy where
  textEnvelopeTypes _ =
    TextEnvelopeType "LegacyCurrentSpelling" :| [TextEnvelopeType "LegacyOldSpelling"]

-- | The head of 'textEnvelopeTypes' is written; the whole list is accepted.
envelopeAcceptanceTests :: TestTree
envelopeAcceptanceTests =
  testGroup
    "several accepted envelope types"
    [ testCase "serialising writes the head of the list" $
        assertEqual "written type" (TextEnvelopeType "LegacyCurrentSpelling") (teType envelope)
    , testCase "deserialising accepts the head" $
        assertEqual "decoded" (Right (Legacy 7)) (decode envelope)
    , testCase "deserialising accepts a legacy spelling" $
        assertEqual
          "decoded"
          (Right (Legacy 7))
          (decode envelope{teType = TextEnvelopeType "LegacyOldSpelling"})
    , testCase "deserialising reports the whole accepted list" $
        assertEqual
          "error"
          ( Left
              ( TextEnvelopeTypeError
                  [TextEnvelopeType "LegacyCurrentSpelling", TextEnvelopeType "LegacyOldSpelling"]
                  (TextEnvelopeType "LegacyUnknownSpelling")
              )
          )
          (decode envelope{teType = TextEnvelopeType "LegacyUnknownSpelling"})
    ]
 where
  envelope = serialiseToTextEnvelope Nothing (Legacy 7)

  decode :: TextEnvelope -> Either TextEnvelopeError Legacy
  decode = deserialiseFromTextEnvelope

--
-- Error rendering
--

-- | The exact text the document of 'renderTextEnvelopeError' lays out for each
-- constructor, under the layout 'docToText' pins.
--
-- These messages reach whoever is starting a node, so they are pinned rather
-- than left to drift.
renderTextEnvelopeErrorTests :: TestTree
renderTextEnvelopeErrorTests =
  testGroup
    "renderTextEnvelopeError"
    [ golden
        "TextEnvelopeAesonDecodeError"
        (TextEnvelopeAesonDecodeError "<string>")
        "TextEnvelope aeson decode error: <string>"
    , golden
        "TextEnvelopeDecodeError"
        (TextEnvelopeDecodeError DecoderErrorVoid)
        "TextEnvelope decode error: DecoderErrorVoid"
    , golden
        "TextEnvelopeTypeError"
        ( TextEnvelopeTypeError
            [TextEnvelopeType "<string>", TextEnvelopeType "<string>"]
            (TextEnvelopeType "<string>")
        )
        "TextEnvelope type error:  Expected one of: <string>, <string> Actual: <string>"
    , golden
        "TextEnvelopeUnknownKeyWitness"
        (TextEnvelopeUnknownKeyWitness (TextEnvelopeDescr "<string>"))
        "Unknown key witness specified: TextEnvelopeDescr \"<string>\""
    , golden
        "TextEnvelopeUnknownType"
        (TextEnvelopeUnknownType "<string>")
        "Unknown TextEnvelope type: <string>"
    ]
 where
  golden name err expected =
    testCase name $ assertEqual "rendered error" expected (docToText (renderTextEnvelopeError err))

--
-- Byron keys
--

-- | Round-trip a Byron signing key through CBOR.
--
-- The seed is fixed rather than generated, and the comparison is on the
-- serialised bytes because @SigningKey ByronKey@ has no 'Eq' instance.
byronKeyCborTests :: TestTree
byronKeyCborTests =
  testGroup
    "Byron keys"
    [ testCase "roundtrip byron signing key CBOR" $ do
        let seedSize = fromIntegral (deterministicSigningKeySeedSize AsByronKey)
            sk = deterministicSigningKey AsByronKey (mkSeedFromBytes (BS.replicate seedSize 42))
            bytes = serialiseToCBOR sk
        case deserialiseFromCBOR (AsSigningKey AsByronKey) bytes of
          Left err -> assertFailure ("could not decode a Byron signing key: " <> show err)
          Right sk' -> assertEqual "reserialised bytes" bytes (serialiseToCBOR (sk' :: SigningKey ByronKey))
    ]
