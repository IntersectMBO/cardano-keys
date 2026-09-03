-- | Entry point of the @cardano-keys@ test suite.
module Main (main) where

import Test.Cardano.Keys.Bech32 qualified as Bech32
import Test.Cardano.Keys.Serialisation qualified as Serialisation

import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "cardano-keys"
      [ Serialisation.tests
      , Bech32.tests
      ]
