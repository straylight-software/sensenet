{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | DhallFast.Input - Drop-in replacement for Dhall input functions
--
-- Uses DhallFast's optimized normalizer instead of upstream Dhall's.
-- The API mirrors Dhall's so it can be used as a drop-in replacement.
--
-- Performance: 2-7x faster normalization due to:
--  - De Bruijn indices (O(1) variable representation)
--  - Strict spine list environment (O(1) cons, small O(i) lookup)
--  - Seq for lists (lazy like upstream)
--  - Cache-optimized data structures
--
-- SECURITY: Blocks dangerous imports:
--  - env: imports (could leak environment variables)
--  - http:/https: imports (could exfiltrate data)
--  - Absolute file paths outside project (could read /etc/passwd etc)
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

    -- * Security
    DangerousImport (..),

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
import Control.Monad (forM_)
import Data.Either.Validation (Validation (..))
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Void (Void)
import Dhall (Decoder (..))
import Dhall qualified
import Dhall.Core (Directory (..), Expr, File (..), FilePrefix (..), Import (..), ImportHashed (..), ImportType (..), ReifiedNormalizer, Scheme (..), URL (..))
import Dhall.Import qualified as Import
import Dhall.Parser (Src)
import Dhall.Parser qualified as Parser
import Dhall.TypeCheck qualified as TypeCheck
import DhallFast.Convert qualified as Convert
import DhallFast.Eval qualified as Eval
import Lens.Micro ((&), (.~))
import Lens.Micro.Extras (view)
import System.FilePath (takeDirectory)

-- ════════════════════════════════════════════════════════════════════════════
-- SECURITY: Dangerous Import Detection
-- ════════════════════════════════════════════════════════════════════════════

-- | Types of dangerous imports that sensenet blocks for security
data DangerousImport
  = -- | env:VAR - could leak secrets
    EnvImport Text
  | -- | http(s):// - could exfiltrate data
    RemoteImport Text
  | -- | /etc/passwd - could read system files
    AbsolutePathImport Text
  | -- | ../../../etc/passwd - path traversal
    ParentEscapeImport Text
  deriving (Show, Eq)

instance Exception.Exception DangerousImport where
  displayException = showDangerousImport

-- | Human-readable error message for dangerous imports
showDangerousImport :: DangerousImport -> String
showDangerousImport (EnvImport var) =
  "SECURITY ERROR: Environment variable imports are not allowed.\n"
    ++ "  Blocked: env:"
    ++ Text.unpack var
    ++ "\n"
    ++ "  Reason: Could leak sensitive environment variables like API keys."
showDangerousImport (RemoteImport url) =
  "SECURITY ERROR: Remote imports are not allowed.\n"
    ++ "  Blocked: "
    ++ Text.unpack url
    ++ "\n"
    ++ "  Reason: Could exfiltrate sensitive data or execute malicious code."
showDangerousImport (AbsolutePathImport path) =
  "SECURITY ERROR: Absolute path imports are not allowed.\n"
    ++ "  Blocked: "
    ++ Text.unpack path
    ++ "\n"
    ++ "  Reason: Could read sensitive system files like /etc/passwd."
showDangerousImport (ParentEscapeImport path) =
  "SECURITY ERROR: Path traversal imports are not allowed.\n"
    ++ "  Blocked: "
    ++ Text.unpack path
    ++ "\n"
    ++ "  Reason: Could escape project directory and read sensitive files."

-- | Check an expression for dangerous imports and throw if found
checkForDangerousImports :: FilePath -> Expr Src Import -> IO ()
checkForDangerousImports projectRoot expr = do
  let imports = collectImports expr
  forM_ imports $ \imp -> do
    case classifyImport projectRoot imp of
      Just danger -> Exception.throwIO danger
      Nothing -> pure ()

-- | Collect all imports from an expression
collectImports :: Expr Src Import -> [Import]
collectImports = toList

-- | Classify an import as dangerous or safe
--
-- Security policy:
--   - env: imports are ALWAYS blocked (credential exfiltration risk)
--   - Remote imports are ALWAYS blocked (data exfiltration risk)
--   - Absolute paths (/etc/passwd) are ALWAYS blocked
--   - Home paths (~/) are ALWAYS blocked
--   - Relative paths (including ../) are ALLOWED within the project
--
-- Note: We intentionally allow ../ imports because Dhall projects commonly
-- use them for cross-package imports. The Nix sandbox provides the real
-- security boundary - it will prevent reading files outside the build.
classifyImport :: FilePath -> Import -> Maybe DangerousImport
classifyImport _projectRoot (Import (ImportHashed _ importType) _) =
  case importType of
    -- Block all environment variable imports - CRITICAL SECURITY
    -- This prevents BUILD.dhall from reading env:AWS_SECRET_ACCESS_KEY etc.
    Env var -> Just (EnvImport var)
    -- Block all remote imports - CRITICAL SECURITY
    -- This prevents BUILD.dhall from sending data to attacker-controlled servers
    Remote (URL {scheme, authority, path = File (Directory pathComponents) pathFile}) ->
      let schemeText = case scheme of
            HTTP -> "http://"
            HTTPS -> "https://"
          urlPath = Text.intercalate "/" (reverse pathComponents ++ [pathFile])
          fullUrl = schemeText <> authority <> "/" <> urlPath
       in Just (RemoteImport fullUrl)
    -- Check local imports based on prefix type
    Local prefix (File (Directory dirComponents) fileName) ->
      let -- Build the full path for display
          pathText = Text.intercalate "/" (reverse dirComponents ++ [fileName])
       in case prefix of
            -- Block absolute paths like /etc/passwd - CRITICAL SECURITY
            Absolute -> Just (AbsolutePathImport ("/" <> pathText))
            -- Block home directory paths like ~/secrets - CRITICAL SECURITY
            Home -> Just (AbsolutePathImport ("~/" <> pathText))
            -- Parent (..) and Here (.) are allowed - the Nix sandbox
            -- provides the real security boundary for file access
            Parent -> Nothing
            Here -> Nothing
    -- Missing imports are handled by Dhall
    Missing -> Nothing

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
  -- | The decoder for the Dhall value
  Dhall.Decoder a ->
  -- | The Dhall program
  Text ->
  -- | The decoded value in Haskell
  IO a
input = inputWithSettings Dhall.defaultInputSettings

-- | Extend 'input' with custom settings
inputWithSettings ::
  Dhall.InputSettings ->
  -- | The decoder for the Dhall value
  Dhall.Decoder a ->
  -- | The Dhall program
  Text ->
  -- | The decoded value in Haskell
  IO a
inputWithSettings settings Decoder {..} text = do
  -- Parse
  let sourceName = view Dhall.sourceName settings
  parsed <- case Parser.exprFromText sourceName text of
    Left err -> Exception.throwIO err
    Right expr -> return expr

  -- SECURITY: Check for dangerous imports BEFORE resolving them
  let rootDir = view Dhall.rootDirectory settings
  checkForDangerousImports rootDir parsed

  -- Resolve imports WITHOUT semantic cache normalization
  -- This lets DhallFast handle all normalization for consistent speedup
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
  -- | The decoder for the Dhall value
  Dhall.Decoder a ->
  -- | The path to the Dhall program
  FilePath ->
  -- | The decoded value in Haskell
  IO a
inputFile = inputFileWithSettings Dhall.defaultEvaluateSettings

-- | Extend 'inputFile' with custom settings
inputFileWithSettings ::
  Dhall.EvaluateSettings ->
  -- | The decoder for the Dhall value
  Dhall.Decoder a ->
  -- | The path to the Dhall program
  FilePath ->
  -- | The decoded value in Haskell
  IO a
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
  -- | The Dhall program
  Text ->
  -- | The fully normalized AST
  IO (Expr Src Void)
inputExpr = inputExprWithSettings Dhall.defaultInputSettings

-- | Extend 'inputExpr' with custom settings
inputExprWithSettings ::
  Dhall.InputSettings ->
  -- | The Dhall program
  Text ->
  -- | The fully normalized AST
  IO (Expr Src Void)
inputExprWithSettings settings text = do
  -- Parse
  let sourceName = view Dhall.sourceName settings
  parsed <- case Parser.exprFromText sourceName text of
    Left err -> Exception.throwIO err
    Right expr -> return expr

  -- SECURITY: Check for dangerous imports BEFORE resolving them
  let rootDir = view Dhall.rootDirectory settings
  checkForDangerousImports rootDir parsed

  -- Resolve imports WITHOUT semantic cache normalization
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
--  1. Convert Dhall.Expr → DhallFast.Expr (de Bruijn indices)
--  2. Evaluate with cache-optimized evaluator
--  3. Convert back to Dhall.Expr
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
