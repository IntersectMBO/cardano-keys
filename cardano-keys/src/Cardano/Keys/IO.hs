{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Reading key files
--
-- Given a path, give me the key. Every function here takes a 'FilePath' and
-- nothing else: which files to read, which combinations of them are valid, and
-- what to do with the result are the caller's business.
--
-- This is the only module in the package that touches the filesystem, so the
-- boundary between the pure serialisation core and the code that opens files
-- is visible at a glance. Nothing else here does IO.
module Cardano.Keys.IO
  ( -- * Errors
    FileError (..)
  , renderFileError

    -- * Text envelope files
  , readFileTextEnvelope

    -- * Bulk credentials files
  , readBulkCredentialsFile

    -- * Byron files
  , readByronSigningKeyFile
  , readByronDelegationCertificateFile
  )
where

import Cardano.Keys.Byron (AsType (AsByronKey), ByronKey)
import Cardano.Keys.Class (AsType (AsSigningKey), Key (..))
import Cardano.Keys.OperationalCertificate (OperationalCertificate)
import Cardano.Keys.Praos (KesKey, VrfKey)
import Cardano.Keys.Serialise.Raw (SerialiseAsRawBytesError, deserialiseFromRawBytes)
import Cardano.Keys.Serialise.TextEnvelope
  ( HasTextEnvelope
  , TextEnvelope
  , TextEnvelopeError (..)
  , deserialiseFromTextEnvelope
  , deserialiseFromTextEnvelopeJSON
  )

import Cardano.Chain.Delegation qualified as Byron
import Cardano.Prelude (SchemaError)

import Control.Exception (IOException, displayException, try)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Prettyprinter (Doc, pretty)
import Text.JSON.Canonical qualified as Canonical

-- ----------------------------------------------------------------------------
-- Errors
--

-- | Something went wrong with a file, and the path it went wrong on.
data FileError e
  = -- | The file was read, but its contents would not decode.
    FileError !FilePath !e
  | -- | The file could not be read at all.
    FileIOError !FilePath !IOException
  deriving (Eq, Show, Functor)

-- | Render a 'FileError' as a human-readable document, given a renderer for
-- the payload.
--
-- Error types here carry a renderer rather than a class instance, following the
-- convention of the rest of this package. Use 'Cardano.Keys.Pretty.docToText'
-- to get the text of one.
renderFileError :: (e -> Doc ann) -> FileError e -> Doc ann
renderFileError renderPayload = \case
  FileError path e ->
    pretty path <> ": " <> renderPayload e
  FileIOError path ioe ->
    pretty path <> ": " <> pretty (displayException ioe)

-- ----------------------------------------------------------------------------
-- Text envelope files
--

-- | Read a text envelope file and decode it.
--
-- The envelope's @type@ field must be one of the ones the target type accepts;
-- see 'Cardano.Keys.Serialise.TextEnvelope.textEnvelopeTypes'.
readFileTextEnvelope
  :: HasTextEnvelope a
  => FilePath -> IO (Either (FileError TextEnvelopeError) a)
readFileTextEnvelope path = do
  bytes <- readFileBytes path
  pure $ do
    content <- bytes
    first (FileError path) $ deserialiseFromTextEnvelopeJSON content

-- ----------------------------------------------------------------------------
-- Bulk credentials files
--

-- | Read a bulk credentials file: the several sets of forging credentials a
-- node can be given in one file.
--
-- The format is a JSON array of 3-element arrays, each element an inline text
-- envelope: the operational certificate, the VRF signing key and the KES
-- signing key, in that order.
--
-- This decodes and nothing more. In particular it does /not/ check that each
-- entry's operational certificate names its KES key — pass every entry through
-- 'Cardano.Keys.OperationalCertificate.checkKesKeyMatchesOpCert' before
-- forging with it.
--
-- An entry that will not decode is reported against
-- @\<file\>.\<index\>cert@, @\<file\>.\<index\>vrf@ or @\<file\>.\<index\>kes@,
-- because a bulk file with twenty pools and one bad envelope is otherwise very
-- hard to debug.
readBulkCredentialsFile
  :: FilePath
  -> IO
       ( Either
           (FileError TextEnvelopeError)
           [(OperationalCertificate, SigningKey VrfKey, SigningKey KesKey)]
       )
readBulkCredentialsFile path = do
  bytes <- readFileBytes path
  pure $ do
    content <- bytes
    entries <-
      first (FileError path . TextEnvelopeAesonDecodeError) $
        Aeson.eitherDecodeStrict' content
    traverse decodeEntry (zip [0 :: Int ..] entries)
 where
  decodeEntry (index, (teCert, teVrf, teKes)) =
    (,,)
      <$> decodeAt index "cert" teCert
      <*> decodeAt index "vrf" teVrf
      <*> decodeAt index "kes" teKes

  decodeAt
    :: HasTextEnvelope a
    => Int -> String -> TextEnvelope -> Either (FileError TextEnvelopeError) a
  decodeAt index role =
    first (FileError (path <> "." <> show index <> role)) . deserialiseFromTextEnvelope

-- ----------------------------------------------------------------------------
-- Byron files
--

-- | Read a Byron signing key.
--
-- Not a text envelope: the file is the raw CBOR of a legacy Byron @XPrv@, and
-- the node reads it as such rather than looking for a JSON wrapper.
--
-- The error is this package's 'SerialiseAsRawBytesError' rather than a bare
-- 'String', so that a caller can render it the same way as every other
-- deserialisation failure.
readByronSigningKeyFile
  :: FilePath -> IO (Either (FileError SerialiseAsRawBytesError) (SigningKey ByronKey))
readByronSigningKeyFile path = do
  bytes <- readFileBytes path
  pure $ do
    content <- bytes
    first (FileError path) $ deserialiseFromRawBytes (AsSigningKey AsByronKey) content

-- | Read a Byron delegation certificate.
--
-- Neither a text envelope nor CBOR: this file is canonical JSON, the same
-- encoding as the Byron genesis, and this is the only place @canonical-json@ is
-- needed. The payload of a failure is the decoder's own message.
readByronDelegationCertificateFile
  :: FilePath -> IO (Either (FileError Text) Byron.Certificate)
readByronDelegationCertificateFile path = do
  bytes <- readFileBytes path
  pure $ do
    content <- bytes
    first (FileError path) $ decodeCanonicalJSON (LBS.fromStrict content)

-- | Decode a value from canonical JSON, reporting the decoder's message.
--
-- The schema errors of the decoders in @cardano-ledger-byron@ are reported
-- through @cardano-prelude@'s 'SchemaError', which is why that package is named
-- here.
decodeCanonicalJSON
  :: forall a
   . Canonical.FromJSON (Either SchemaError) a
  => LBS.ByteString -> Either Text a
decodeCanonicalJSON bytes = do
  value <- first Text.pack $ Canonical.parseCanonicalJSON bytes
  first (Text.pack . show) (Canonical.fromJSON value :: Either SchemaError a)

-- ----------------------------------------------------------------------------
-- Reading the bytes
--

-- | Read a file's bytes, turning an 'IOException' into a 'FileIOError'.
--
-- Every file here is read through this, so an unreadable one is always a
-- returned error rather than an exception.
readFileBytes :: FilePath -> IO (Either (FileError e) ByteString)
readFileBytes path =
  first (FileIOError path) <$> try (BS.readFile path)
