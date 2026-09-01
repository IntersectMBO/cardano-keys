-- | Bootstrap smoke test for the @cardano-keys@ placeholder module.
--
-- This is deliberately a bare @main@ rather than a @tasty@ suite: the real
-- test suites arrive together with the real key types.
-- Until then, all this has to prove is that the library and its dependencies
-- link and run.
module Main where

import Cardano.Keys (placeholderBech32RoundTrip, placeholderBlake2b_256)

import Data.ByteString qualified as BS
import Data.Text (Text)
import System.Exit (exitFailure)

main :: IO ()
main = do
  bech32Passed <- checkBech32RoundTrip
  blake2bPassed <- checkBlake2b_256
  if bech32Passed && blake2bPassed
    then putStrLn "PASS: cardano-keys bootstrap checks"
    else exitFailure

roundTripInput :: Text
roundTripInput = "cardano-keys"

checkBech32RoundTrip :: IO Bool
checkBech32RoundTrip =
  case placeholderBech32RoundTrip roundTripInput of
    Right recovered
      | recovered == roundTripInput -> do
          putStrLn "PASS: placeholderBech32RoundTrip recovers its input"
          pure True
    actual -> do
      putStrLn $
        "FAIL: placeholderBech32RoundTrip "
          <> show roundTripInput
          <> ": expected "
          <> show (Right roundTripInput :: Either String Text)
          <> " but got "
          <> show actual
      pure False

checkBlake2b_256 :: IO Bool
checkBlake2b_256 = do
  let actualLength = BS.length (placeholderBlake2b_256 "cardano-keys")
  if actualLength == 32
    then do
      putStrLn "PASS: placeholderBlake2b_256 returns a 32 byte digest"
      pure True
    else do
      putStrLn $
        "FAIL: placeholderBlake2b_256: expected a 32 byte digest but got "
          <> show actualLength
          <> " bytes"
      pure False
