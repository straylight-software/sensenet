{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Benchmark: DhallFast vs upstream Dhall
module Main where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Void (Void)
import qualified Dhall.Core as D
import qualified Dhall.Parser as Parser
import qualified Dhall.Src as Src
-- DhallFast modules

import DhallFast.Convert
import DhallFast.Core
import DhallFast.Eval
import System.IO (hFlush, stdout)
import Text.Printf (printf)

--------------------------------------------------------------------------------
-- Test expressions
--------------------------------------------------------------------------------

-- Simple arithmetic
simpleNat :: Text
simpleNat = "let x = 1 in let y = 2 in x + y"

-- Natural/fold (loop)
natFold :: Int -> Text
natFold n = T.pack $ "Natural/fold " ++ show n ++ " Natural (\\(x : Natural) -> x + 1) 0"

-- Nested let bindings
nestedLets :: Int -> Text
nestedLets n =
  T.unlines $
    ["let x0 = 1"]
      ++ ["let x" <> T.pack (show i) <> " = x" <> T.pack (show (i - 1)) <> " + 1" | i <- [1 .. n]]
      ++ ["in x" <> T.pack (show n)]

-- Record with many fields
bigRecord :: Int -> Text
bigRecord n =
  "{ " <> T.intercalate ", " [T.pack ("field" ++ show i ++ " = " ++ show i) | i <- [1 .. n]] <> " }"

-- Record field access
recordAccess :: Int -> Text
recordAccess n =
  "let r = " <> bigRecord n <> " in r.field" <> T.pack (show (n `div` 2))

--------------------------------------------------------------------------------
-- Benchmarking infrastructure
--------------------------------------------------------------------------------

time :: String -> IO a -> IO a
time label action = do
  putStr $ label ++ "... "
  hFlush stdout
  start <- getCurrentTime
  !result <- action
  end <- getCurrentTime
  let elapsed = realToFrac (diffUTCTime end start) :: Double
  printf "%.4f sec\n" elapsed
  return result

bench :: String -> Int -> IO () -> IO ()
bench label iterations action = do
  putStr $ label ++ " (" ++ show iterations ++ " iterations)... "
  hFlush stdout
  start <- getCurrentTime
  go iterations
  end <- getCurrentTime
  let elapsed = realToFrac (diffUTCTime end start) :: Double
  let perIter = elapsed / fromIntegral iterations * 1000000 -- microseconds
  printf "%.4f sec total, %.2f µs/iter\n" elapsed perIter
  where
    go 0 = return ()
    go n = action >> go (n - 1)

--------------------------------------------------------------------------------
-- Parse helper
--------------------------------------------------------------------------------

-- Parse Dhall text to resolved expression (no imports)
-- For expressions without imports, we traverse and prove no imports exist
parseDhall :: Text -> Either String (D.Expr Src.Src Void)
parseDhall src = case Parser.exprFromText "(bench)" src of
  Left err -> Left (show err)
  Right expr -> Right (removeImports (D.denote expr))
  where
    -- Our test expressions have no imports, so this is safe
    removeImports :: D.Expr s D.Import -> D.Expr s Void
    removeImports = fmap (\_ -> error "unexpected import")

--------------------------------------------------------------------------------
-- Main benchmark
--------------------------------------------------------------------------------

main :: IO ()
main = do
  putStrLn ""
  putStrLn "╔══════════════════════════════════════════════════════════════════╗"
  putStrLn "║            DhallFast vs Upstream Dhall Benchmarks                ║"
  putStrLn "╚══════════════════════════════════════════════════════════════════╝"
  putStrLn ""

  -- Test 1: Simple expression
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 1. SIMPLE ARITHMETIC                                             │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  let iterations1 = 10000

  putStrLn "Expression: let x = 1 in let y = 2 in x + y"
  putStrLn ""

  -- Parse once
  case parseDhall simpleNat of
    Left err -> putStrLn $ "Parse error: " ++ err
    Right resolved1 -> do
      let fast1 = fromDhall resolved1

      bench "  Upstream Dhall (normalize)" iterations1 $ do
        let !_ = D.normalize resolved1
        return ()

      bench "  DhallFast (eval only)" iterations1 $ do
        let !_ = eval emptyEnv fast1
        return ()

      bench "  DhallFast (eval + quote)" iterations1 $ do
        let !_ = normalize fast1
        return ()

  -- Test 2: Natural/fold
  putStrLn ""
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 2. NATURAL/FOLD (loop performance)                               │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  let foldSizes = [100, 1000]

  forM_ foldSizes $ \size -> do
    putStrLn $ "\nNatural/fold " ++ show size ++ " ..."

    case parseDhall (natFold size) of
      Left err -> putStrLn $ "Parse error: " ++ err
      Right resolved -> do
        let fast = fromDhall resolved
        let iterations = if size > 500 then 10 else 100

        bench "  Upstream Dhall" iterations $ do
          let !_ = D.normalize resolved
          return ()

        bench "  DhallFast" iterations $ do
          let !_ = normalize fast
          return ()

  -- Test 3: Nested lets
  putStrLn ""
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 3. NESTED LET BINDINGS (environment lookup)                      │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  let letSizes = [10, 50, 100, 200]

  forM_ letSizes $ \size -> do
    putStrLn $ "\n" ++ show size ++ " nested lets..."

    case parseDhall (nestedLets size) of
      Left err -> putStrLn $ "Parse error: " ++ err
      Right resolved -> do
        let !fast = fromDhall resolved -- force conversion
        let iterations = 1000

        bench "  Upstream Dhall" iterations $ do
          let !_ = D.normalize resolved
          return ()

        bench "  DhallFast (eval only)" iterations $ do
          let !_ = eval emptyEnv fast
          return ()

        bench "  DhallFast (full)" iterations $ do
          let !_ = normalize fast
          return ()

  -- Test 4: Larger Natural/fold to show scaling
  putStrLn ""
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 4. LARGE NATURAL/FOLD (compute-bound)                            │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  let largeFolds = [5000, 10000]

  forM_ largeFolds $ \size -> do
    putStrLn $ "\nNatural/fold " ++ show size ++ " ..."

    case parseDhall (natFold size) of
      Left err -> putStrLn $ "Parse error: " ++ err
      Right resolved -> do
        let fast = fromDhall resolved

        bench "  Upstream Dhall" 5 $ do
          let !_ = D.normalize resolved
          return ()

        bench "  DhallFast" 5 $ do
          let !_ = normalize fast
          return ()

  -- Test 5: Record operations
  putStrLn ""
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 5. RECORD OPERATIONS (field access, record merge)                │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  -- Record field access
  let recordSizes = [10, 50, 100]

  forM_ recordSizes $ \size -> do
    putStrLn $ "\nRecord with " ++ show size ++ " fields, access middle field..."

    case parseDhall (recordAccess size) of
      Left err -> putStrLn $ "Parse error: " ++ err
      Right resolved -> do
        let !fast = force $ fromDhall resolved
        let iterations = 1000

        bench "  Upstream Dhall" iterations $ do
          let !_ = D.normalize resolved
          return ()

        bench "  DhallFast (eval only)" iterations $ do
          let !_ = eval emptyEnv fast
          return ()

        bench "  DhallFast (full)" iterations $ do
          let !_ = normalize fast
          return ()

  -- Record merge (prefer operator)
  putStrLn "\nRecord merge (10-field records with //)..."

  let recordMerge :: Text
      recordMerge = "let a = " <> bigRecord 10 <> " in let b = " <> bigRecord 10 <> " in a // b"

  case parseDhall recordMerge of
    Left err -> putStrLn $ "Parse error: " ++ err
    Right resolved -> do
      let !fast = force $ fromDhall resolved
      let iterations = 1000

      bench "  Upstream Dhall" iterations $ do
        let !_ = D.normalize resolved
        return ()

      bench "  DhallFast (eval only)" iterations $ do
        let !_ = eval emptyEnv fast
        return ()

      bench "  DhallFast (full)" iterations $ do
        let !_ = normalize fast
        return ()

  -- Pure merge benchmark - just the merge operation, no record creation
  putStrLn "\nPure record merge (pre-built 10-field records)..."

  let pureRecordA :: Text
      pureRecordA = bigRecord 10
      pureRecordB :: Text
      pureRecordB = "{ " <> T.intercalate ", " [T.pack ("field" ++ show i ++ " = " ++ show (i * 100)) | i <- [1 .. 10]] <> " }"
      pureMerge :: Text
      pureMerge = pureRecordA <> " // " <> pureRecordB

  case parseDhall pureMerge of
    Left err -> putStrLn $ "Parse error: " ++ err
    Right resolved -> do
      let !fast = force $ fromDhall resolved
      let iterations = 10000

      bench "  Upstream Dhall" iterations $ do
        let !_ = D.normalize resolved
        return ()

      bench "  DhallFast (eval only)" iterations $ do
        let !_ = eval emptyEnv fast
        return ()

      bench "  DhallFast (full)" iterations $ do
        let !_ = normalize fast
        return ()

  -- Micro-benchmark: just mergeFieldsPrefer on pre-built fields
  putStrLn "\nMicro: mergeFieldsPrefer (10 fields each)..."

  let mkTestFields :: Int -> Int -> Fields Expr
      mkTestFields start n =
        fieldsFromList
          [ (internName (T.pack ("f" ++ show i)), ELit (LitNat (fromIntegral i)))
          | i <- [start .. start + n - 1]
          ]
      !fieldsA = mkTestFields 1 10
      !fieldsB = mkTestFields 6 10 -- overlapping keys
  bench "  mergeFieldsPrefer" 100000 $ do
    let !_ = mergeFieldsPrefer fieldsA fieldsB
    return ()

  -- Test 6: List operations
  putStrLn ""
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 6. LIST OPERATIONS (fold, length, map)                           │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  -- List/length
  let listSizes = [100, 500]

  forM_ listSizes $ \size -> do
    putStrLn $ "\nList/length on " ++ show size ++ " element list..."

    let listExpr :: Text
        listExpr = "List/length Natural [" <> T.intercalate ", " (map (T.pack . show) [1 .. size]) <> "]"

    case parseDhall listExpr of
      Left err -> putStrLn $ "Parse error: " ++ err
      Right resolved -> do
        -- Don't force - let it stay lazy like upstream Dhall
        let fast = fromDhall resolved
        let iterations = if size > 200 then 100 else 500

        bench "  Upstream Dhall" iterations $ do
          let !_ = D.normalize resolved
          return ()

        bench "  DhallFast (eval only)" iterations $ do
          let !_ = eval emptyEnv fast
          return ()

        bench "  DhallFast (full)" iterations $ do
          let !_ = normalize fast
          return ()

  -- List/fold
  forM_ [50, 100] $ \size -> do
    putStrLn $ "\nList/fold on " ++ show size ++ " element list (sum)..."

    let listFoldExpr :: Text
        listFoldExpr = "List/fold Natural [" <> T.intercalate ", " (map (T.pack . show) [1 .. size]) <> "] Natural (\\(x : Natural) -> \\(acc : Natural) -> x + acc) 0"

    case parseDhall listFoldExpr of
      Left err -> putStrLn $ "Parse error: " ++ err
      Right resolved -> do
        let !fast = force $ fromDhall resolved
        let iterations = 100

        bench "  Upstream Dhall" iterations $ do
          let !_ = D.normalize resolved
          return ()

        bench "  DhallFast (eval only)" iterations $ do
          let !_ = eval emptyEnv fast
          return ()

        bench "  DhallFast (full)" iterations $ do
          let !_ = normalize fast
          return ()

  -- Summary
  putStrLn ""
  putStrLn "╔══════════════════════════════════════════════════════════════════╗"
  putStrLn "║                      Benchmark Complete                          ║"
  putStrLn "╚══════════════════════════════════════════════════════════════════╝"
  putStrLn ""
  putStrLn "Key optimizations in DhallFast:"
  putStrLn "  • De Bruijn indices: O(1) variable lookup vs O(n) name search"
  putStrLn "  • Array environment: Cache-friendly vs linked list"
  putStrLn "  • Sorted vector fields: Binary search with better locality"
  putStrLn "  • Unboxed literals: Less indirection, better cache usage"

forM_ :: [a] -> (a -> IO ()) -> IO ()
forM_ [] _ = return ()
forM_ (x : xs) f = f x >> forM_ xs f
