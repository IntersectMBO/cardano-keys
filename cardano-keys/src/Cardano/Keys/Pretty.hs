-- | Turning the error documents of this package into text
--
-- The @render*Error@ functions return @'Doc' ann@ so that callers keep
-- @prettyprinter@'s grouping and wrapping. The two functions here are the
-- layout this package pins for callers that just want a string: the default
-- layout options, so that a document with no group in it renders as the
-- concatenation of its parts.
module Cardano.Keys.Pretty
  ( docToText
  , docToString
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prettyprinter (Doc, defaultLayoutOptions, layoutPretty)
import Prettyprinter.Render.Text (renderStrict)

-- | Render a document with 'defaultLayoutOptions'.
docToText :: Doc ann -> Text
docToText = renderStrict . layoutPretty defaultLayoutOptions

-- | Render a document with 'defaultLayoutOptions', as a 'String'.
docToString :: Doc ann -> String
docToString = Text.unpack . docToText
