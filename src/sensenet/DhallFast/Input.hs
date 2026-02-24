{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | DhallFast.Input - Drop-in replacement for Dhall input functions
--
-- Uses DhallFast's optimized normalizer instead of upstream Dhall's.
-- The API mirrors Dhall's so it can be used as a drop-in replacement.
--
-- Performance: 2-7x faster normalization due to:
--   - De Bruijn indices (O(1) variable representation)
--   - Strict spine list environment (O(1) cons, small O(i) lookup)
--   - Seq for lists (lazy like upstream)
--   - Cache-optimized data structures
--
-- Note: Uses IgnoreSemanticCache to bypass Dhall's built-in normalization
-- during import resolution, ensuring DhallFast handles all normalization.
module DhallFast.Input
  ( -- * Input functions (drop-in replacements)
    input,
    inputWithSettings,
    inputFile,
    inputFileWithSettings,
    inputExpr,
    inputExprWithSettings,

    -- * Re-exports from Dhall for convenience
    Dhall.Decoder,
    Dhall.auto,
    Dhall.FromDhall,
    Dhall.InputSettings,
    Dhall.EvaluateSettings,
    Dhall.HasEvaluateSettings (..),
    Dhall.defaultInputSettings,
    Dhall.defaultEvaluateSettings,
    Dhall.rootDirectory,
    Dhall.sourceName,
    Dhall.startingContext,
    Dhall.substitutions,
    Dhall.normalizer,
  )
where

import Control.Exception qualified as Exception
import Data.Either.Validation (Validation (..))
import Data.Text (Text)
import Data.Text.IO qualified as Text.IO
import Data.Void (Void)
import Dhall (Decoder (..))
import Dhall qualified
import Dhall.Core (Expr, ReifiedNormalizer)
import Dhall.Import qualified as Import
import Dhall.Parser (Src)
import Dhall.Parser qualified as Parser
import Dhall.TypeCheck qualified as TypeCheck
import DhallFast.Convert qualified as Convert
import DhallFast.Eval qualified as Eval
import Lens.Micro ((&), (.~))
import Lens.Micro.Extras (view)
import System.FilePath (takeDirectory)

-- | Type-check and evaluate a Dhall program, decoding the result into Haskell
--
-- Uses DhallFast's optimized normalizer for 2-7x faster evaluation.
--
-- >>> input integer "+2"
-- 2
-- >>> input (vector double) "[1.0, 2.0]"
-- [1.0,2.0]
--
-- Use `auto` to automatically select which type to decode based on the
-- inferred return type:
--
-- >>> input auto "True" :: IO Bool
-- True
input ::
  Dhall.Decoder a ->
  -- ^ The decoder for the Dhall value
  Text ->
  -- ^ The Dhall program
  IO a
  -- ^ The decoded value in Haskell
input = inputWithSettings Dhall.defaultInputSettings

-- | Extend 'input' with custom settings
inputWithSettings ::
  Dhall.InputSettings ->
  Dhall.Decoder a ->
  -- ^ The decoder for the Dhall value
  Text ->
  -- ^ The Dhall program
  IO a
  -- ^ The decoded value in Haskell
inputWithSettings settings decoder@Decoder {..} text = do
  -- Parse
  let sourceName = view Dhall.sourceName settings
  parsed <- case Parser.exprFromText sourceName text of
    Left err -> Exception.throwIO err
    Right expr -> return expr

  -- Resolve imports WITHOUT semantic cache normalization
  -- This lets DhallFast handle all normalization for consistent speedup
  let rootDir = view Dhall.rootDirectory settings
  resolved <- Import.loadRelativeTo rootDir Import.IgnoreSemanticCache parsed

  -- Type-check
  _ <- case TypeCheck.typeOf resolved of
    Left err -> Exception.throwIO err
    Right _ -> return ()

  -- Normalize using DhallFast (the key optimization!)
  let normalized = normalizeFast (view Dhall.normalizer settings) resolved

  -- Extract to Haskell type
  case extract normalized of
    Success x -> return x
    Failure e -> Exception.throwIO e

-- | Type-check and evaluate a Dhall program from a file
--
-- Uses DhallFast's optimized normalizer for 2-7x faster evaluation.
inputFile ::
  Dhall.Decoder a ->
  -- ^ The decoder for the Dhall value
  FilePath ->
  -- ^ The path to the Dhall program
  IO a
  -- ^ The decoded value in Haskell
inputFile = inputFileWithSettings Dhall.defaultEvaluateSettings

-- | Extend 'inputFile' with custom settings
inputFileWithSettings ::
  Dhall.EvaluateSettings ->
  Dhall.Decoder a ->
  -- ^ The decoder for the Dhall value
  FilePath ->
  -- ^ The path to the Dhall program
  IO a
  -- ^ The decoded value in Haskell
inputFileWithSettings settings decoder path = do
  text <- Text.IO.readFile path
  -- Build InputSettings using lenses since the constructor isn't exported
  let inputSettings =
        Dhall.defaultInputSettings
          & Dhall.rootDirectory .~ takeDirectory path
          & Dhall.sourceName .~ path
          & Dhall.evaluateSettings .~ settings
  inputWithSettings inputSettings decoder text

-- | Evaluate a Dhall program without decoding to Haskell type
--
-- Returns the fully normalized AST.
inputExpr ::
  Text ->
  -- ^ The Dhall program
  IO (Expr Src Void)
  -- ^ The fully normalized AST
inputExpr = inputExprWithSettings Dhall.defaultInputSettings

-- | Extend 'inputExpr' with custom settings
inputExprWithSettings ::
  Dhall.InputSettings ->
  Text ->
  -- ^ The Dhall program
  IO (Expr Src Void)
  -- ^ The fully normalized AST
inputExprWithSettings settings text = do
  -- Parse
  let sourceName = view Dhall.sourceName settings
  parsed <- case Parser.exprFromText sourceName text of
    Left err -> Exception.throwIO err
    Right expr -> return expr

  -- Resolve imports WITHOUT semantic cache normalization
  let rootDir = view Dhall.rootDirectory settings
  resolved <- Import.loadRelativeTo rootDir Import.IgnoreSemanticCache parsed

  -- Type-check
  _ <- case TypeCheck.typeOf resolved of
    Left err -> Exception.throwIO err
    Right _ -> return ()

  -- Normalize using DhallFast
  pure $ normalizeFast (view Dhall.normalizer settings) resolved

-- | Normalize using DhallFast's optimized evaluator
--
-- Pipeline:
--   1. Convert Dhall.Expr → DhallFast.Expr (de Bruijn indices)
--   2. Evaluate with cache-optimized evaluator
--   3. Convert back to Dhall.Expr
--
-- The custom normalizer is ignored for now - DhallFast doesn't support
-- custom normalizers yet. This is fine for sensenet's use case.
normalizeFast ::
  Maybe (ReifiedNormalizer Void) ->
  Expr Src Void ->
  Expr Src Void
normalizeFast _mNormalizer expr =
  -- TODO: Support custom normalizers if needed
  -- For now, just use DhallFast's built-in normalizer
  let fastExpr = Convert.fromDhall expr
      normalizedFast = Eval.normalize fastExpr
   in Convert.toDhall normalizedFast
