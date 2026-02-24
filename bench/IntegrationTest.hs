{-# LANGUAGE OverloadedStrings #-}

{- | Integration test for DhallFast with real BUILD.dhall files

Tests DhallFast normalization against upstream Dhall to verify
they produce equivalent results.
-}
module Main where

import Control.DeepSeq (deepseq)
import Control.Exception (evaluate)
import qualified Data.Text.IO as T.IO
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Void (Void)
import qualified Dhall.Core as Core
import qualified Dhall.Import
import Dhall.Parser (Src)
import qualified Dhall.Parser
import qualified DhallFast.Convert as Convert
import qualified DhallFast.Eval as Eval
import System.Environment (getArgs)
import System.FilePath (takeDirectory)

-- | Normalize using upstream Dhall
normalizeUpstream :: Core.Expr Src Void -> Core.Expr Src Void
normalizeUpstream = Core.normalize

-- | Normalize using DhallFast
normalizeFast :: Core.Expr Src Void -> Core.Expr Src Void
normalizeFast expr =
    let fastExpr = Convert.fromDhall expr
        normalizedFast = Eval.normalize fastExpr
     in Convert.toDhall normalizedFast

-- | Compare normalization results for a file
compareNormalization :: FilePath -> IO ()
compareNormalization path = do
    putStrLn $ "\n=== Testing: " ++ path ++ " ==="

    -- Parse
    putStrLn "Parsing..."
    text <- T.IO.readFile path
    parsed <- case Dhall.Parser.exprFromText path text of
        Left err -> error $ "Parse error: " ++ show err
        Right e -> return e

    -- Resolve imports (WITHOUT semantic cache to get un-normalized expression)
    -- This ensures both normalizers get the same input
    putStrLn "Resolving imports (no cache, for fair comparison)..."
    let dir = takeDirectory path
    resolved <- Dhall.Import.loadRelativeTo dir Dhall.Import.IgnoreSemanticCache parsed

    -- Normalize with upstream
    putStr "Upstream Dhall normalize: "
    t0 <- getCurrentTime
    let upstreamResult = normalizeUpstream resolved
    _ <- evaluate (upstreamResult `deepseq` ())
    t1 <- getCurrentTime
    putStrLn $ show (diffUTCTime t1 t0)

    -- Normalize with DhallFast
    putStr "DhallFast normalize:      "
    t2 <- getCurrentTime
    let fastResult = normalizeFast resolved
    _ <- evaluate (fastResult `deepseq` ())
    t3 <- getCurrentTime
    putStrLn $ show (diffUTCTime t3 t2)

    -- Compare results (alpha-normalize both for comparison)
    let upstreamAlpha = Core.alphaNormalize upstreamResult
        fastAlpha = Core.alphaNormalize fastResult

    if upstreamAlpha == fastAlpha
        then putStrLn "Results match!"
        else do
            putStrLn "Results DIFFER!"
            putStrLn "\nUpstream result:"
            print upstreamResult
            putStrLn "\nDhallFast result:"
            print fastResult

-- | Run multiple iterations for timing
benchmark :: FilePath -> Int -> IO ()
benchmark path iterations = do
    putStrLn $ "\n=== Benchmarking: " ++ path ++ " (" ++ show iterations ++ " iterations) ==="

    -- Parse and resolve once
    text <- T.IO.readFile path
    parsed <- case Dhall.Parser.exprFromText path text of
        Left err -> error $ "Parse error: " ++ show err
        Right e -> return e
    let dir = takeDirectory path
    resolved <- Dhall.Import.loadRelativeTo dir Dhall.Import.IgnoreSemanticCache parsed

    -- Benchmark upstream
    putStr $ "Upstream Dhall (" ++ show iterations ++ "x): "
    t0 <- getCurrentTime
    let goUpstream 0 = return ()
        goUpstream n = do
            let !_ = normalizeUpstream resolved
            goUpstream (n - 1)
    goUpstream iterations
    t1 <- getCurrentTime
    let upstreamTime = diffUTCTime t1 t0
    putStrLn $
        show upstreamTime
            ++ " total, "
            ++ show (realToFrac upstreamTime / fromIntegral iterations :: Double)
            ++ "s/iter"

    -- Benchmark DhallFast
    putStr $ "DhallFast      (" ++ show iterations ++ "x): "
    t2 <- getCurrentTime
    let goFast 0 = return ()
        goFast n = do
            let !_ = normalizeFast resolved
            goFast (n - 1)
    goFast iterations
    t3 <- getCurrentTime
    let fastTime = diffUTCTime t3 t2
    putStrLn $
        show fastTime
            ++ " total, "
            ++ show (realToFrac fastTime / fromIntegral iterations :: Double)
            ++ "s/iter"

    -- Speedup
    let speedup = realToFrac upstreamTime / realToFrac fastTime :: Double
    putStrLn $ "Speedup: " ++ show speedup ++ "x"

main :: IO ()
main = do
    args <- getArgs
    case args of
        [] -> do
            putStrLn "DhallFast Integration Test"
            putStrLn "=========================="
            putStrLn ""
            putStrLn "Usage: IntegrationTest <path-to-BUILD.dhall> [iterations]"
            putStrLn ""
            putStrLn "Testing with default files..."
            compareNormalization "src/examples/cxx/BUILD.dhall"
        [path] -> compareNormalization path
        [path, nStr] -> benchmark path (read nStr)
        _ -> putStrLn "Too many arguments"
