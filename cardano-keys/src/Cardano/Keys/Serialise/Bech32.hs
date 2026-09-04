{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Bech32 Serialisation
module Cardano.Keys.Serialise.Bech32
  ( SerialiseAsBech32 (..)
  , serialiseToBech32
  , Bech32DecodeError (..)
  , renderBech32DecodeError
  , deserialiseFromBech32
  , deserialiseAnyOfFromBech32
  , unsafeHumanReadablePartFromText
  )
where

import Cardano.Keys.HasTypeProxy
import Cardano.Keys.Serialise.Orphans ()
import Cardano.Keys.Serialise.Raw

import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (guard)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Data (Data)
import Data.List qualified as List
import Data.Set (Set)
import Data.Text (Text)
import Data.Text.Encoding.Error (UnicodeException)
import GHC.Exts (IsList (..))
import GHC.Stack
import Prettyprinter (Doc, viaShow)

class (HasTypeProxy a, SerialiseAsRawBytes a) => SerialiseAsBech32 a where
  -- | The human readable prefix to use when encoding this value to Bech32.
  bech32PrefixFor :: a -> Bech32.HumanReadablePart

  -- | The set of human readable prefixes that can be used for this type.
  bech32PrefixesPermitted :: AsType a -> [Bech32.HumanReadablePart]

serialiseToBech32 :: SerialiseAsBech32 a => a -> Text
serialiseToBech32 a =
  Bech32.encodeLenient
    (bech32PrefixFor a)
    (Bech32.dataPartFromBytes (serialiseToRawBytes a))

deserialiseFromBech32
  :: forall a
   . SerialiseAsBech32 a
  => Text -> Either Bech32DecodeError a
deserialiseFromBech32 bech32Str = do
  (prefix, dataPart) <-
    Bech32.decodeLenient bech32Str
      ?!& Bech32DecodingError

  let actualPrefix = Bech32.humanReadablePartToText prefix
      permittedPrefixes = bech32PrefixesPermitted (asType @a)
  guard (prefix `elem` permittedPrefixes)
    ?! Bech32UnexpectedPrefix
      actualPrefix
      (fromList $ Bech32.humanReadablePartToText <$> permittedPrefixes)

  payload <-
    Bech32.dataPartToBytes dataPart
      ?! Bech32DataPartToBytesError (Bech32.dataPartToText dataPart)

  value <- case deserialiseFromRawBytes asType payload of
    Right a -> Right a
    Left _ -> Left $ Bech32DeserialiseFromBytesError payload

  let expectedPrefix = Bech32.humanReadablePartToText $ bech32PrefixFor value
  guard (actualPrefix == expectedPrefix)
    ?! Bech32WrongPrefix actualPrefix expectedPrefix

  return value

deserialiseAnyOfFromBech32
  :: forall b
   . [FromSomeType SerialiseAsBech32 b]
  -> Text
  -> Either Bech32DecodeError b
deserialiseAnyOfFromBech32 types bech32Str = do
  (prefix, dataPart) <-
    Bech32.decodeLenient bech32Str
      ?!& Bech32DecodingError

  let actualPrefix = Bech32.humanReadablePartToText prefix

  FromSomeType actualType fromType <-
    findForPrefix prefix
      ?! Bech32UnexpectedPrefix
        actualPrefix
        (fromList $ Bech32.humanReadablePartToText <$> permittedPrefixes)

  payload <-
    Bech32.dataPartToBytes dataPart
      ?! Bech32DataPartToBytesError (Bech32.dataPartToText dataPart)

  value <- case deserialiseFromRawBytes actualType payload of
    Right a -> Right a
    Left _ -> Left $ Bech32DeserialiseFromBytesError payload

  let expectedPrefix = Bech32.humanReadablePartToText $ bech32PrefixFor value
  guard (actualPrefix == expectedPrefix)
    ?! Bech32WrongPrefix actualPrefix expectedPrefix

  return (fromType value)
 where
  findForPrefix
    :: Bech32.HumanReadablePart
    -> Maybe (FromSomeType SerialiseAsBech32 b)
  findForPrefix prefix =
    List.find
      (\(FromSomeType t _) -> prefix `elem` bech32PrefixesPermitted t)
      types

  permittedPrefixes :: [Bech32.HumanReadablePart]
  permittedPrefixes =
    concat
      [ bech32PrefixesPermitted ttoken
      | FromSomeType ttoken _f <- types
      ]

-- | The human readable part of the Bech32 encoding for the credential. This will
-- error if the prefix is not valid.
unsafeHumanReadablePartFromText :: HasCallStack => Text -> Bech32.HumanReadablePart
unsafeHumanReadablePartFromText =
  either (error . ("unsafeHumanReadablePartFromText: Error while parsing Bech32: " <>) . show) id
    . Bech32.humanReadablePartFromText

-- | Bech32 decoding error.
data Bech32DecodeError
  = -- | There was an error decoding the string as Bech32.
    Bech32DecodingError !Bech32.DecodingError
  | -- | The human-readable prefix in the Bech32-encoded string is not one
    -- of the ones expected.
    Bech32UnexpectedPrefix !Text !(Set Text)
  | -- | There was an error in extracting a 'ByteString' from the data part of
    -- the Bech32-encoded string.
    Bech32DataPartToBytesError !Text
  | -- | There was an error in deserialising the bytes into a value of the
    -- expected type.
    Bech32DeserialiseFromBytesError !ByteString
  | -- | The human-readable prefix in the Bech32-encoded string does not
    -- correspond to the prefix that should be used for the payload value.
    Bech32WrongPrefix !Text !Text
  | Bech32UnexpectedHeader
      !Text
      -- ^ Expected header
      !Text
      -- ^ Unexpected header
  | -- | The input is not valid UTF-8, so it cannot be a Bech32-encoded
    -- string. The field contains the UTF-8 decoding error.
    Bech32InvalidUtf8 !UnicodeException
  deriving (Eq, Show, Data)

-- | Render a 'Bech32DecodeError' as a human-readable document.
--
-- Error types here carry a renderer rather than a class instance, following the
-- convention of the rest of this package. Use 'Cardano.Keys.Pretty.docToText'
-- to get the text of one.
renderBech32DecodeError :: Bech32DecodeError -> Doc ann
renderBech32DecodeError = \case
  Bech32DecodingError decErr ->
    viaShow decErr -- TODO
  Bech32UnexpectedPrefix actual permitted ->
    mconcat
      [ "Unexpected Bech32 prefix: the actual prefix is " <> viaShow actual
      , ", but it was expected to be "
      , mconcat $ List.intersperse " or " (map viaShow (toList permitted))
      ]
  Bech32DataPartToBytesError _dataPart ->
    mconcat
      [ "There was an error in extracting the bytes from the data part of the "
      , "Bech32-encoded string."
      ]
  Bech32DeserialiseFromBytesError _bytes ->
    mconcat
      [ "There was an error in deserialising the data part of the "
      , "Bech32-encoded string into a value of the expected type."
      ]
  Bech32WrongPrefix actual expected ->
    mconcat
      [ "Mismatch in the Bech32 prefix: the actual prefix is " <> viaShow actual
      , ", but the prefix for this payload value should be " <> viaShow expected
      ]
  Bech32UnexpectedHeader expected actual ->
    mconcat
      [ "Unexpected CIP-129 Bech32 header: the actual header is " <> viaShow actual
      , ", but it was expected to be " <> viaShow expected
      ]
  Bech32InvalidUtf8 decodeErr ->
    "The Bech32-encoded string is not valid UTF-8: " <> viaShow decodeErr

-- | Lift a 'Maybe' into 'Either', with the error to use when it is 'Nothing'.
--
-- Stands in for @cardano-api@'s @Cardano.Api.Monad.Error.(?!)@, which is
-- @MonadError@-polymorphic and would cost this package an @mtl@ dependency.
(?!) :: Maybe a -> e -> Either e a
Just x ?! _ = Right x
Nothing ?! e = Left e

infixl 8 ?!

-- | Map over the 'Left' of an 'Either'. Infix 'first' with its arguments flipped.
(?!&) :: Either e a -> (e -> e') -> Either e' a
(?!&) = flip first

infixl 8 ?!&
