{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for reading key files.
--
-- The fixtures under @test\/credentials@ are real key material generated with
-- @cardano-cli@, not hand-rolled: a fixture built by this package's own encoder
-- would round-trip through its own decoder and prove nothing. That directory's
-- README records how they were made.
--
-- @kes.skey@ is the KES key named by @opcert.cert@; @kes-other.skey@ is an
-- unrelated KES key, so 'checkKesKeyMatchesOpCert' can be shown to fail as well
-- as to pass.
module Test.Cardano.Keys.Reading (tests) where

import Cardano.Keys.Byron (VerificationKey (ByronVerificationKey))
import Cardano.Keys.Class (Key (..))
import Cardano.Keys.IO
  ( FileError (..)
  , readBulkCredentialsFile
  , readByronDelegationCertificateFile
  , readByronSigningKeyFile
  , readFileTextEnvelope
  , renderFileError
  )
import Cardano.Keys.OperationalCertificate
  ( KESPeriod (..)
  , KesKeyMismatch (..)
  , OperationalCertificate
  , checkKesKeyMatchesOpCert
  , getColdKey
  , getHotKey
  , getKesPeriod
  , getOpCertCount
  )
import Cardano.Keys.Praos (KesKey, VrfKey)
import Cardano.Keys.Pretty (docToText)
import Cardano.Keys.Serialise.Raw (serialiseToRawBytes, serialiseToRawBytesHex)
import Cardano.Keys.Serialise.TextEnvelope
  ( TextEnvelope (..)
  , TextEnvelopeError (..)
  , TextEnvelopeType (..)
  , decodeTextEnvelopeJSON
  , renderTextEnvelopeError
  )

import Cardano.Chain.Delegation qualified as Byron

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openBinaryTempFile)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase)

import Paths_cardano_keys (getDataFileName)

tests :: IO TestTree
tests = do
  opCertPath <- fixture "opcert.cert"
  kesPath <- fixture "kes.skey"
  kesOtherPath <- fixture "kes-other.skey"
  vrfPath <- fixture "vrf.skey"
  bulkPath <- fixture "bulk.creds"
  bulkMismatchedPath <- fixture "bulk-mismatched.creds"
  byronCertPath <- fixture "byron-delegation.cert"
  byronKeyPath <- fixture "byron-delegate.key"
  pure $
    testGroup
      "reading"
      [ textEnvelopeTests opCertPath kesPath vrfPath
      , kesCheckTests opCertPath kesPath kesOtherPath
      , bulkTests bulkPath bulkMismatchedPath
      , byronTests byronCertPath byronKeyPath opCertPath
      ]

fixture :: FilePath -> IO FilePath
fixture name = getDataFileName ("test/credentials/" <> name)

--
-- Text envelope files
--

-- | The hash of the KES verification key @opcert.cert@ names, which is also the
-- hash of @kes.skey@'s own verification key.
kesKeyHashHex :: ByteString
kesKeyHashHex = "aee9a3c3ea81ce5e3c598e9b2a898d865c2196e22e907c9deef71ea00f745221"

-- | The hash of @kes-other.skey@'s verification key.
kesOtherKeyHashHex :: ByteString
kesOtherKeyHashHex = "336502424cd33d3b7ea5ba66b09921f24432d5804ee6c934e893cdc161c320d6"

-- | The hash of @vrf.skey@'s verification key.
vrfKeyHashHex :: ByteString
vrfKeyHashHex = "e444a59553d536eb4715d386be0ee0b3ec137494e90f33c71344f66b2471520a"

-- | The stake pool cold verification key that issued @opcert.cert@.
coldKeyHex :: ByteString
coldKeyHex = "f7b462b9a8bb623f78a792ea93cdddb240fddecdd88312515950d7f5a874f08b"

textEnvelopeTests :: FilePath -> FilePath -> FilePath -> TestTree
textEnvelopeTests opCertPath kesPath vrfPath =
  testGroup
    "text envelope files"
    [ testCase "an operational certificate decodes, and its accessors agree with the file" $ do
        opCert <- expectRight "the operational certificate" =<< readOpCert opCertPath
        assertEqual "the KES period" (KESPeriod 0) (getKesPeriod opCert)
        assertEqual "the issue counter" 0 (getOpCertCount opCert)
        assertEqual
          "the cold verification key"
          coldKeyHex
          (serialiseToRawBytesHex (getColdKey opCert))
        assertEqual
          "the hot key is the one kes.skey holds"
          kesKeyHashHex
          (serialiseToRawBytesHex (verificationKeyHash (getHotKey opCert)))
        -- Independently of the accessor: the cold key is the last 32 bytes of
        -- the envelope's CBOR payload, which is where cardano-cli puts it.
        envelope <-
          expectRight "the raw envelope" . decodeTextEnvelopeJSON =<< BS.readFile opCertPath
        let payload = teRawCBOR envelope
            coldKeyBytes = serialiseToRawBytes (getColdKey opCert)
        assertEqual
          "the payload ends with the cold key"
          coldKeyBytes
          (BS.drop (BS.length payload - BS.length coldKeyBytes) payload)
    , testCase "a KES signing key decodes" $ do
        kes <- expectRight "the KES signing key" =<< readKes kesPath
        assertEqual
          "the KES verification key hash"
          kesKeyHashHex
          (serialiseToRawBytesHex (verificationKeyHash (getVerificationKey kes)))
    , testCase "a VRF signing key decodes" $ do
        vrf <- expectRight "the VRF signing key" =<< readVrf vrfPath
        assertEqual
          "the VRF verification key hash"
          vrfKeyHashHex
          (serialiseToRawBytesHex (verificationKeyHash (getVerificationKey vrf)))
    , testCase "a key of the wrong type is rejected, naming every type it accepts" $ do
        err <- expectLeft "a KES key read as a VRF key" =<< readVrf kesPath
        assertEqual
          "the envelope type error"
          ( FileError
              kesPath
              ( TextEnvelopeTypeError
                  [TextEnvelopeType "VrfSigningKey_PraosVRF"]
                  (TextEnvelopeType "KesSigningKey_ed25519_kes_2^6")
              )
          )
          err
        assertEqual
          "the rendered error"
          ( Text.pack kesPath
              <> ": TextEnvelope type error: "
              <> " Expected: VrfSigningKey_PraosVRF"
              <> " Actual: KesSigningKey_ed25519_kes_2^6"
          )
          (docToText (renderFileError renderTextEnvelopeError err))
    , testCase "a missing file is reported, not thrown" $ do
        err <- expectLeft "a file that is not there" =<< readKes "/nonexistent/kes.skey"
        expectFileIOError "/nonexistent/kes.skey" err
    ]

readOpCert :: FilePath -> IO (Either (FileError TextEnvelopeError) OperationalCertificate)
readOpCert = readFileTextEnvelope

readKes :: FilePath -> IO (Either (FileError TextEnvelopeError) (SigningKey KesKey))
readKes = readFileTextEnvelope

readVrf :: FilePath -> IO (Either (FileError TextEnvelopeError) (SigningKey VrfKey))
readVrf = readFileTextEnvelope

--
-- The operational certificate KES check
--

kesCheckTests :: FilePath -> FilePath -> FilePath -> TestTree
kesCheckTests opCertPath kesPath kesOtherPath =
  testGroup
    "the operational certificate KES check"
    [ testCase "the KES key the certificate names is accepted" $ do
        opCert <- expectRight "the operational certificate" =<< readOpCert opCertPath
        kes <- expectRight "the KES signing key" =<< readKes kesPath
        assertEqual "the check passes" (Right ()) (checkKesKeyMatchesOpCert opCert kes)
    , testCase "an unrelated KES key is rejected, carrying both hashes" $ do
        opCert <- expectRight "the operational certificate" =<< readOpCert opCertPath
        kesOther <- expectRight "the unrelated KES signing key" =<< readKes kesOtherPath
        mismatch <-
          expectLeft "the unrelated KES key" (checkKesKeyMatchesOpCert opCert kesOther)
        assertEqual
          "the expected hash is the one the certificate names"
          kesKeyHashHex
          (serialiseToRawBytesHex (expectedKesKeyHash mismatch))
        assertEqual
          "the actual hash is the one the supplied key has"
          kesOtherKeyHashHex
          (serialiseToRawBytesHex (actualKesKeyHash mismatch))
        assertBool
          "the two hashes differ"
          (expectedKesKeyHash mismatch /= actualKesKeyHash mismatch)
    ]

--
-- Bulk credentials files
--

bulkTests :: FilePath -> FilePath -> TestTree
bulkTests bulkPath bulkMismatchedPath =
  testGroup
    "bulk credentials files"
    [ testCase "two entries decode, with distinct hot keys" $ do
        entries <- expectRight "the bulk file" =<< readBulkCredentialsFile bulkPath
        assertEqual "the number of entries" 2 (length entries)
        case [getHotKey opCert | (opCert, _, _) <- entries] of
          [hot0, hot1] -> assertBool "the entries have different hot keys" (hot0 /= hot1)
          hots -> assertFailure ("expected two hot keys, got " <> show (length hots))
    , testCase "the file decodes even when an entry's KES key is the wrong one" $ do
        entries <-
          expectRight "the mismatched bulk file" =<< readBulkCredentialsFile bulkMismatchedPath
        assertEqual "the number of entries" 2 (length entries)
        assertEqual
          "entry 0 fails the check and entry 1 passes it"
          [False, True]
          [ either (const False) (const True) (checkKesKeyMatchesOpCert opCert kes)
          | (opCert, _, kes) <- entries
          ]
    , testGroup
        "a bad envelope names the entry it is in"
        [ testCase label $ do
            original <- readBulkEntries bulkPath
            withTempFile "bulk.creds" (encodeBulkEntries (spoil index slot original)) $ \path -> do
              err <- expectLeft "the corrupted bulk file" =<< readBulkCredentialsFile path
              assertEqual "the label of the failing envelope" (path <> suffix) (errorPath err)
        | (label, index, slot, suffix) <-
            [ ("the operational certificate of entry 0", 0, Cert, ".0cert")
            , ("the VRF key of entry 1", 1, Vrf, ".1vrf")
            , ("the KES key of entry 1", 1, Kes, ".1kes")
            ]
        ]
    , testCase "a file that is not an array of envelope triples is reported" $
        withTempFile "bulk.creds" "{}" $ \path -> do
          err <- expectLeft "a bulk file that is an object" =<< readBulkCredentialsFile path
          case err of
            FileError path' (TextEnvelopeAesonDecodeError _) ->
              assertEqual "names the file" path path'
            other -> assertFailure ("expected an aeson decode error, got " <> show other)
    , testCase "a missing file is reported, not thrown" $ do
        err <-
          expectLeft "a file that is not there"
            =<< readBulkCredentialsFile "/nonexistent/bulk.creds"
        expectFileIOError "/nonexistent/bulk.creds" err
    ]

-- | One of the three envelopes of a bulk credentials entry.
data Slot = Cert | Vrf | Kes

type BulkEntry = (TextEnvelope, TextEnvelope, TextEnvelope)

readBulkEntries :: FilePath -> IO [BulkEntry]
readBulkEntries path =
  either assertFailure pure . Aeson.eitherDecodeStrict' =<< BS.readFile path

encodeBulkEntries :: [BulkEntry] -> ByteString
encodeBulkEntries = LBS.toStrict . Aeson.encode

-- | Replace the @type@ of one envelope of one entry with an unknown one.
spoil :: Int -> Slot -> [BulkEntry] -> [BulkEntry]
spoil index slot = zipWith atEntry [0 :: Int ..]
 where
  atEntry i entry@(cert, vrf, kes)
    | i /= index = entry
    | otherwise = case slot of
        Cert -> (unknownType cert, vrf, kes)
        Vrf -> (cert, unknownType vrf, kes)
        Kes -> (cert, vrf, unknownType kes)

  unknownType envelope = envelope{teType = TextEnvelopeType "NotAKeyAtAll"}

--
-- Byron files
--

byronTests :: FilePath -> FilePath -> FilePath -> TestTree
byronTests byronCertPath byronKeyPath opCertPath =
  testGroup
    "Byron files"
    [ testCase "a delegation certificate and the signing key it delegates to decode" $ do
        cert <-
          expectRight "the delegation certificate"
            =<< readByronDelegationCertificateFile byronCertPath
        signingKey <- expectRight "the signing key" =<< readByronSigningKeyFile byronKeyPath
        case getVerificationKey signingKey of
          ByronVerificationKey vkey ->
            assertEqual
              "the certificate delegates to the signing key"
              (Byron.delegateVK cert)
              vkey
    , testCase "a signing key that is not a legacy XPrv is reported" $
        withTempFile "byron-delegate.key" "not an xprv at all" $ \path -> do
          err <- expectLeft "junk in place of a signing key" =<< readByronSigningKeyFile path
          assertEqual "names the file" path (errorPath err)
    , testCase "a delegation certificate that is not canonical JSON is reported" $
        withTempFile "byron-delegation.cert" "{not json" $ \path -> do
          err <-
            expectLeft "junk in place of a certificate"
              =<< readByronDelegationCertificateFile path
          assertEqual "names the file" path (errorPath err)
    , testCase "a text envelope is not a delegation certificate" $ do
        -- Valid JSON, so this reaches the schema check rather than the parser.
        err <-
          expectLeft "an operational certificate read as a Byron one"
            =<< readByronDelegationCertificateFile opCertPath
        assertEqual "names the file" opCertPath (errorPath err)
    , testCase "a missing signing key is reported, not thrown" $ do
        err <-
          expectLeft "a file that is not there"
            =<< readByronSigningKeyFile "/nonexistent/byron-delegate.key"
        expectFileIOError "/nonexistent/byron-delegate.key" err
    ]

--
-- Helpers
--

-- | Write a temporary file, run an action on its path, and remove it again.
--
-- @base@ and @directory@ are enough for this, so the test suite does its own
-- temporary files rather than taking a dependency on @temporary@.
withTempFile :: String -> ByteString -> (FilePath -> IO a) -> IO a
withTempFile template contents action =
  bracket create removeFile action
 where
  create = do
    dir <- getTemporaryDirectory
    (path, handle) <- openBinaryTempFile dir template
    BS.hPut handle contents
    hClose handle
    pure path

expectRight :: Show e => String -> Either e a -> IO a
expectRight what = either (\err -> assertFailure (what <> ": " <> show err)) pure

expectLeft :: String -> Either e a -> IO e
expectLeft what =
  either pure (const (assertFailure (what <> ": expected a failure, but it decoded")))

-- | The path a 'FileError' names, whichever constructor it is.
errorPath :: FileError e -> FilePath
errorPath (FileError path _) = path
errorPath (FileIOError path _) = path

expectFileIOError :: Show e => FilePath -> FileError e -> Assertion
expectFileIOError expected err = case err of
  FileIOError path _ -> assertEqual "names the file" expected path
  FileError _ _ -> assertFailure ("expected a FileIOError, got " <> show err)
