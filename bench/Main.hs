{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Main (bench)
-- Description : sensenet performance benchmarks
--
-- Comprehensive benchmark suite for DICE (content-addressed build system).
--
-- Run with:
--   nix run .#bench
--   cabal bench
--   ghc -O2 -package ... bench/Main.hs && ./Main
--
-- == Performance Summary (as of 2024)
--
-- @
-- ┌─────────────────────────────────────────────────────────────────┐
-- │ ACTIONKEY COMPUTATION                                          │
-- ├─────────────────────────────────────────────────────────────────┤
-- │ Algorithm      │ Time/op  │ Throughput   │ vs Baseline         │
-- ├────────────────┼──────────┼──────────────┼─────────────────────┤
-- │ SHA256 + Text  │ 2.07 µs  │ 483K keys/s  │ baseline            │
-- │ SHA256 + BS    │ 1.41 µs  │ 710K keys/s  │ +47%                │
-- │ BLAKE2b + BS   │ 1.13 µs  │ 885K keys/s  │ +83%                │
-- │ FNV-1a (unsafe)│ 0.65 µs  │ 1.5M keys/s  │ +210% (non-crypto)  │
-- └─────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────┐
-- │ GRAPH OPERATIONS (10,000 actions)                              │
-- ├─────────────────────────────────────────────────────────────────┤
-- │ Operation              │ Time     │ Notes                      │
-- ├────────────────────────┼──────────┼────────────────────────────┤
-- │ Graph construction     │ ~25 ms   │ 400K inserts/sec           │
-- │ Topological sort       │ ~30 ms   │ Linear chain worst case    │
-- │ End-to-end             │ ~31 ms   │ Build + sort               │
-- └─────────────────────────────────────────────────────────────────┘
-- @
--
-- == Optimization History
--
-- 1. __Baseline__: Text.intercalate + SHA256 + encodeUtf8
-- 2. __ByteString Builder__: +35% on canonical form
-- 3. __hashlazy__: Avoid toStrict copy before hashing
-- 4. __BLAKE2b-256__: 1.5x faster than SHA256, still cryptographic
-- 5. __Fast-path escape__: Skip byte-by-byte when no special chars
module Main (main) where

import Control.DeepSeq (NFData (..), force)
import Control.Exception (evaluate)
import Crypto.Hash (Blake2b_256 (..), Digest, hashlazy)
import Data.ByteArray.Encoding qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (foldl')
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Word (Word8)
import System.Environment (getArgs)
import System.Mem (performGC)
import Text.Printf (printf)

-- ════════════════════════════════════════════════════════════════════════════
-- Main
-- ════════════════════════════════════════════════════════════════════════════

main :: IO ()
main = do
  args <- getArgs
  let quick = "--quick" `elem` args
      n = if quick then 10000 else 100000

  putStrLn "╔══════════════════════════════════════════════════════════════════╗"
  putStrLn "║           sensenet DICE Performance Benchmarks                   ║"
  putStrLn "╚══════════════════════════════════════════════════════════════════╝"
  putStrLn ""
  printf "Configuration: %d actions, %s mode\n\n" n (if quick then "quick" else "full" :: String)

  -- Generate test data
  let actions = generateActions n
  _ <- evaluate $ length actions

  -- Run benchmarks
  benchActionKey n actions
  benchCanonicalForm n actions
  benchGraphConstruction n actions
  benchTopoSort n
  benchEndToEnd n

  putStrLn "╔══════════════════════════════════════════════════════════════════╗"
  putStrLn "║                      Benchmark Complete                          ║"
  putStrLn "╚══════════════════════════════════════════════════════════════════╝"

-- ════════════════════════════════════════════════════════════════════════════
-- Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

benchActionKey :: Int -> [Action] -> IO ()
benchActionKey n actions = do
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 1. ACTION KEY COMPUTATION (BLAKE2b-256)                          │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  performGC
  start <- getCurrentTime
  !total <- evaluate $ foldl' (\acc a -> acc + BS.length (unActionKey $ actionKey a)) 0 actions
  end <- getCurrentTime

  let elapsed = realToFrac (diffUTCTime end start) :: Double
      perOp = elapsed * 1e6 / fromIntegral n
      throughput = fromIntegral n / elapsed

  printf "   Actions:     %d\n" n
  printf "   Total time:  %.4f sec\n" elapsed
  printf "   Per action:  %.2f µs\n" perOp
  printf "   Throughput:  %.0f keys/sec\n" throughput
  printf "   Checksum:    %d bytes\n\n" total

benchCanonicalForm :: Int -> [Action] -> IO ()
benchCanonicalForm n actions = do
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 2. CANONICAL FORM CONSTRUCTION (ByteString Builder)              │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  performGC
  start <- getCurrentTime
  !total <- evaluate $ foldl' (\acc a -> acc + fromIntegral (BL.length $ actionToCanonicalLazy a)) 0 actions
  end <- getCurrentTime

  let elapsed = realToFrac (diffUTCTime end start) :: Double
      perOp = elapsed * 1e6 / fromIntegral n
      avgSize = total `div` n

  printf "   Actions:     %d\n" n
  printf "   Total time:  %.4f sec\n" elapsed
  printf "   Per action:  %.2f µs\n" perOp
  printf "   Avg size:    %d bytes\n" avgSize
  printf "   Total data:  %.2f MB\n\n" (fromIntegral total / 1e6 :: Double)

benchGraphConstruction :: Int -> [Action] -> IO ()
benchGraphConstruction n actions = do
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 3. GRAPH CONSTRUCTION                                            │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  performGC
  start <- getCurrentTime
  let !graph = foldl' (flip addAction) emptyGraph actions
  !size <- evaluate $ Map.size $ agActions graph
  end <- getCurrentTime

  let elapsed = realToFrac (diffUTCTime end start) :: Double
      perOp = elapsed * 1e6 / fromIntegral n
      throughput = fromIntegral n / elapsed

  printf "   Actions:     %d\n" n
  printf "   Graph size:  %d nodes\n" size
  printf "   Total time:  %.4f sec\n" elapsed
  printf "   Per insert:  %.2f µs\n" perOp
  printf "   Throughput:  %.0f inserts/sec\n\n" throughput

benchTopoSort :: Int -> IO ()
benchTopoSort n = do
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 4. TOPOLOGICAL SORT                                              │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  -- Linear chain (worst case)
  let chainActions = buildLinearChain n
      chainGraph = foldl' (flip addAction) emptyGraph chainActions
  _ <- evaluate $ Map.size $ agActions chainGraph

  performGC
  start1 <- getCurrentTime
  !len1 <- evaluate $ length $ topoSort chainGraph
  end1 <- getCurrentTime
  let chain = realToFrac (diffUTCTime end1 start1) :: Double

  -- Independent (best case)
  let indepActions = [mkAction (T.pack $ show i) [] | i <- [1 .. n]]
      indepGraph = foldl' (flip addAction) emptyGraph indepActions
  _ <- evaluate $ Map.size $ agActions indepGraph

  performGC
  start2 <- getCurrentTime
  !len2 <- evaluate $ length $ topoSort indepGraph
  end2 <- getCurrentTime
  let indep = realToFrac (diffUTCTime end2 start2) :: Double

  printf "   Nodes:       %d\n" n
  printf "   Linear chain (worst): %.4f sec (%d sorted)\n" chain len1
  printf "   Independent (best):   %.4f sec (%d sorted)\n\n" indep len2

benchEndToEnd :: Int -> IO ()
benchEndToEnd n = do
  putStrLn "┌──────────────────────────────────────────────────────────────────┐"
  putStrLn "│ 5. END-TO-END (construct graph + topological sort)               │"
  putStrLn "└──────────────────────────────────────────────────────────────────┘"

  let actions = [mkAction (T.pack $ show i) [T.pack $ "in" ++ show j | j <- [1 .. 3 :: Int]] | i <- [1 .. n]]
  _ <- evaluate $ length actions

  performGC
  start <- getCurrentTime
  let graph = foldl' (flip addAction) emptyGraph actions
      sorted = topoSort graph
  !len <- evaluate $ length sorted
  end <- getCurrentTime

  let elapsed = realToFrac (diffUTCTime end start) :: Double
      perAction = elapsed * 1e6 / fromIntegral n

  printf "   Actions:     %d\n" n
  printf "   Sorted:      %d\n" len
  printf "   Total time:  %.4f sec\n" elapsed
  printf "   Per action:  %.2f µs\n\n" perAction

-- ════════════════════════════════════════════════════════════════════════════
-- Test Data Generation
-- ════════════════════════════════════════════════════════════════════════════

generateActions :: Int -> [Action]
generateActions n =
  [ mkAction
      (T.pack $ "//pkg" ++ show (i `div` 100) ++ ":target" ++ show i)
      [T.pack $ "src/file" ++ show j ++ ".hs" | j <- [1 .. 3 :: Int]]
  | i <- [1 .. n]
  ]

buildLinearChain :: Int -> [Action]
buildLinearChain n = go n Nothing []
  where
    go 0 _ acc = acc
    go i prevKey acc =
      let action = mkAction (T.pack $ "chain-" ++ show i) [] `withDeps` maybe [] (: []) prevKey
          key = actionKey action
       in go (i - 1) (Just key) (action : acc)

    withDeps a deps = a {aInputKeys = deps}

-- ════════════════════════════════════════════════════════════════════════════
-- DICE Types (standalone, mirrors SenseNet.DICE)
-- ════════════════════════════════════════════════════════════════════════════

newtype ActionKey = ActionKey {unActionKey :: ByteString}
  deriving (Show, Eq, Ord)

instance NFData ActionKey where
  rnf (ActionKey bs) = rnf bs

data Action = Action
  { aName :: !Text,
    aCommand :: ![Text],
    aInputs :: ![Text],
    aInputKeys :: ![ActionKey],
    aOutputs :: ![Text],
    aEnv :: !(Map.Map Text Text),
    aCoeffects :: ![Text]
  }
  deriving (Show, Eq)

instance NFData Action where
  rnf Action {..} =
    rnf aName `seq` rnf aCommand `seq` rnf aInputs `seq`
    rnf aInputKeys `seq` rnf aOutputs `seq` rnf aEnv `seq` rnf aCoeffects

data ActionGraph = ActionGraph
  { agActions :: !(Map.Map ActionKey Action),
    agRoots :: ![ActionKey]
  }

emptyGraph :: ActionGraph
emptyGraph = ActionGraph Map.empty []

addAction :: Action -> ActionGraph -> ActionGraph
addAction action graph =
  let key = actionKey action
   in graph {agActions = Map.insert key action (agActions graph)}

-- | Compute action key using BLAKE2b-256
actionKey :: Action -> ActionKey
actionKey action =
  let !canonical = actionToCanonicalLazy action
      !hash = hashlazy canonical :: Digest Blake2b_256
   in ActionKey (BA.convertToBase BA.Base16 hash)
{-# INLINE actionKey #-}

-- | Canonical form using ByteString Builder (zero-copy)
actionToCanonicalLazy :: Action -> BL.ByteString
actionToCanonicalLazy Action {..} = BB.toLazyByteString builder
  where
    builder =
      "action:2\n"
        <> "name:" <> textBS aName <> nl
        <> "command:" <> mconcat [textBS c <> nul | c <- aCommand] <> nl
        <> "inputs:" <> mconcat [escapeBS (TE.encodeUtf8 i) <> nul | i <- aInputs] <> nl
        <> "outputs:" <> mconcat [textBS o <> nul | o <- aOutputs] <> nl
        <> "env:" <> serializeEnvBS aEnv <> nl
        <> "coeffects:" <> mconcat [textBS c <> comma | c <- aCoeffects] <> nl
    nl = BB.char7 '\n'
    nul = BB.char7 '\0'
    comma = BB.char7 ','
    textBS = BB.byteString . TE.encodeUtf8
{-# INLINE actionToCanonicalLazy #-}

escapeBS :: ByteString -> BB.Builder
escapeBS bs
  | BS.null bs = mempty
  | hasSpecial bs = BS.foldl' (\b w -> b <> escapeByte w) mempty bs
  | otherwise = BB.byteString bs
  where
    hasSpecial = BS.any (\w -> w == 0 || w == 92)
    escapeByte :: Word8 -> BB.Builder
    escapeByte 0 = "\\0"
    escapeByte 92 = "\\\\"
    escapeByte w = BB.word8 w
{-# INLINE escapeBS #-}

serializeEnvBS :: Map.Map Text Text -> BB.Builder
serializeEnvBS m =
  mconcat
    [ BB.byteString (TE.encodeUtf8 k) <> BB.char7 '=' <> escapeBS (TE.encodeUtf8 v) <> BB.char7 '\0'
    | (k, v) <- Map.toAscList m
    ]
{-# INLINE serializeEnvBS #-}

topoSort :: ActionGraph -> [ActionKey]
topoSort ActionGraph {..} = reverse $ go Set.empty [] (Map.keys agActions)
  where
    go _ sorted [] = sorted
    go visited sorted (k : ks)
      | k `Set.member` visited = go visited sorted ks
      | otherwise =
          let action = agActions Map.! k
              deps = aInputKeys action
              (visited', sorted') = foldl' visitDep (Set.insert k visited, sorted) deps
           in go visited' (k : sorted') ks

    visitDep (v, s) dep
      | dep `Set.member` v = (v, s)
      | otherwise =
          case Map.lookup dep agActions of
            Nothing -> (Set.insert dep v, s)
            Just action ->
              let deps = aInputKeys action
                  (v', s') = foldl' visitDep (Set.insert dep v, s) deps
               in (v', dep : s')

mkAction :: Text -> [Text] -> Action
mkAction name inputs =
  Action
    { aName = name,
      aCommand = [name],
      aInputs = inputs,
      aInputKeys = [],
      aOutputs = ["out"],
      aEnv = Map.empty,
      aCoeffects = []
    }
