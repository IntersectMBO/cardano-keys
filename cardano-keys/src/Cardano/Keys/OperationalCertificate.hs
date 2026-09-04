{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeFamilies #-}

-- | Operational certificates
--
-- An operational certificate is a stake pool cold key's signed statement that
-- one particular KES key may forge on its behalf; 'getHotKey' recovers that key.
--
-- Decoding only. Issuing a certificate needs addresses, protocol parameters and
-- transaction signing, none of which this component depends on.
module Cardano.Keys.OperationalCertificate
  ( OperationalCertificate (..)
  , OperationalCertificateIssueCounter (..)
  , Shelley.KESPeriod (..)
  , getHotKey
  , getColdKey
  , getKesPeriod
  , getOpCertCount

    -- * Checking a certificate against its KES key
  , checkKesKeyMatchesOpCert
  , KesKeyMismatch (..)
  , renderKesKeyMismatch

    -- * Data family instances
  , AsType (..)
  )
where

import Cardano.Keys.Class
import Cardano.Keys.HasTypeProxy
import Cardano.Keys.Praos
import Cardano.Keys.Serialise.Cbor
import Cardano.Keys.Serialise.Orphans ()
import Cardano.Keys.Serialise.TextEnvelope
import Cardano.Keys.Shelley

import Cardano.Protocol.Crypto (StandardCrypto)
import Cardano.Protocol.TPraos.OCert qualified as Shelley

import Data.Word
import Prettyprinter (Doc, pretty)

-- ----------------------------------------------------------------------------
-- Operational certificates
--

data OperationalCertificate
  = OperationalCertificate
      !(Shelley.OCert StandardCrypto)
      !(VerificationKey StakePoolKey)
  deriving (Eq, Show)
  deriving anyclass SerialiseAsCBOR

data OperationalCertificateIssueCounter
  = OperationalCertificateIssueCounter
  { opCertIssueCount :: !Word64
  , opCertIssueColdKey :: !(VerificationKey StakePoolKey) -- For consistency checking
  }
  deriving (Eq, Show)
  deriving anyclass SerialiseAsCBOR

instance ToCBOR OperationalCertificate where
  toCBOR (OperationalCertificate ocert vkey) =
    toCBOR (ocert, vkey)

instance FromCBOR OperationalCertificate where
  fromCBOR = do
    (ocert, vkey) <- fromCBOR
    return (OperationalCertificate ocert vkey)

instance ToCBOR OperationalCertificateIssueCounter where
  toCBOR (OperationalCertificateIssueCounter counter vkey) =
    toCBOR (counter, vkey)

instance FromCBOR OperationalCertificateIssueCounter where
  fromCBOR = do
    (counter, vkey) <- fromCBOR
    return (OperationalCertificateIssueCounter counter vkey)

instance HasTypeProxy OperationalCertificate where
  data AsType OperationalCertificate = AsOperationalCertificate
  proxyToAsType _ = AsOperationalCertificate

instance HasTypeProxy OperationalCertificateIssueCounter where
  data AsType OperationalCertificateIssueCounter = AsOperationalCertificateIssueCounter
  proxyToAsType _ = AsOperationalCertificateIssueCounter

instance HasTextEnvelope OperationalCertificate where
  textEnvelopeTypes _ = pure "NodeOperationalCertificate"

instance HasTextEnvelope OperationalCertificateIssueCounter where
  textEnvelopeTypes _ = pure "NodeOperationalCertificateIssueCounter"

-- | The KES verification key the certificate authorises to forge.
getHotKey :: OperationalCertificate -> VerificationKey KesKey
getHotKey (OperationalCertificate cert _) = KesVerificationKey $ Shelley.ocertVkHot cert

-- | The stake pool cold verification key that issued the certificate.
getColdKey :: OperationalCertificate -> VerificationKey StakePoolKey
getColdKey (OperationalCertificate _ vkey) = vkey

-- | The KES period the certificate starts at.
getKesPeriod :: OperationalCertificate -> Shelley.KESPeriod
getKesPeriod (OperationalCertificate cert _) = Shelley.ocertKESPeriod cert

getOpCertCount :: OperationalCertificate -> Word64
getOpCertCount (OperationalCertificate cert _) = Shelley.ocertN cert

-- ----------------------------------------------------------------------------
-- Checking a certificate against its KES key
--

-- | An operational certificate and a KES signing key that do not go together.
--
-- The evidence is the two hashes, not the two files they came from: this is a
-- statement about keys, and a caller that read them from files knows the paths
-- and can name them around 'renderKesKeyMismatch'.
data KesKeyMismatch = KesKeyMismatch
  { expectedKesKeyHash :: !(Hash KesKey)
  -- ^ The hash of the KES verification key the certificate names.
  , actualKesKeyHash :: !(Hash KesKey)
  -- ^ The hash of the KES verification key that was supplied.
  }
  deriving (Eq, Show)

-- | Render a 'KesKeyMismatch' as a human-readable document.
--
-- Use 'Cardano.Keys.Pretty.docToText' to get the text of one.
renderKesKeyMismatch :: KesKeyMismatch -> Doc ann
renderKesKeyMismatch KesKeyMismatch{expectedKesKeyHash, actualKesKeyHash} =
  mconcat
    [ "The KES key provided does not match the KES key specified in the operational "
    , "certificate: the certificate names the KES key with hash "
    , pretty expectedKesKeyHash
    , ", but the key provided hashes to "
    , pretty actualKesKeyHash
    ]

-- | Check that an operational certificate names the KES signing key it was
-- given alongside.
--
-- The certificate is the cold key's signed statement that one particular KES
-- key may forge on its behalf, but nothing ties it to the KES key handed to a
-- node. A stale certificate paired with a rotated KES key forges blocks the
-- certificate does not authorise, and the network rejects every one of them
-- without the node ever seeing a local error.
--
-- The check is a statement about two keys, so it lives here rather than being
-- reimplemented by every consumer.
checkKesKeyMatchesOpCert
  :: OperationalCertificate -> SigningKey KesKey -> Either KesKeyMismatch ()
checkKesKeyMatchesOpCert opCert kesSigningKey
  | expected == actual = Right ()
  | otherwise =
      Left
        KesKeyMismatch
          { expectedKesKeyHash = expected
          , actualKesKeyHash = actual
          }
 where
  expected = verificationKeyHash (getHotKey opCert)
  actual = verificationKeyHash (getVerificationKey kesSigningKey)
