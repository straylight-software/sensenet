{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | sensenet Benchmark Suite
--
-- Performance benchmarks for critical paths.
-- Run with: cabal bench / nix run .#bench
--
-- "Everyone has a plan until they get punched in the face."
-- - Mike Tyson, on performance
module Main (main) where

import Control.DeepSeq (NFData (..), deepseq, force)
import Control.Monad (forM_, replicateM)
import Criterion.Main
import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteArray.Encoding qualified as BA
import Data.ByteString (ByteString)
import Data.Foldable (foldl')
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Random (mkStdGen, randomRs)

main :: IO ()
main =
  defaultMain
    [ bgroup "hash" hashBenchmarks,
      bgroup "actionKey" actionKeyBenchmarks,
      bgroup "topoSort" topoSortBenchmarks,
      bgroup "graphConstruction" graphConstructionBenchmarks,
      bgroup "scaling" scalingBenchmarks
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Hash Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

hashBenchmarks :: [Benchmark]
hashBenchmarks =
  [ bench "empty" $ whnf hashText "",
    bench "10 bytes" $ whnf hashText "0123456789",
    bench "100 bytes" $ whnf hashText (T.replicate 10 "0123456789"),
    bench "1 KB" $ whnf hashText (T.replicate 100 "0123456789"),
    bench "10 KB" $ whnf hashText (T.replicate 1000 "0123456789"),
    bench "100 KB" $ whnf hashText (T.replicate 10000 "0123456789"),
    bench "1 MB" $ whnf hashText (T.replicate 100000 "0123456789"),
    bgroup
      "throughput"
      [ bench "1000 x 100 bytes" $ nf (map hashText) (replicate 1000 $ T.replicate 10 "0123456789"),
        bench "10000 x 10 bytes" $ nf (map hashText) (replicate 10000 "0123456789")
      ]
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- ActionKey Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

actionKeyBenchmarks :: [Benchmark]
actionKeyBenchmarks =
  [ bench "minimal action" $ whnf actionKey minimalAction,
    bench "small action (5 inputs)" $ whnf actionKey (actionWithInputs 5),
    bench "medium action (50 inputs)" $ whnf actionKey (actionWithInputs 50),
    bench "large action (500 inputs)" $ whnf actionKey (actionWithInputs 500),
    bench "action with deps" $ whnf actionKey (actionWithDeps 10),
    bench "action with long command" $ whnf actionKey actionWithLongCommand,
    bgroup
      "throughput"
      [ bench "1000 keys" $ nf (map actionKey) (replicate 1000 minimalAction),
        bench "1000 unique actions" $ nf (map actionKey) uniqueActions1000
      ]
  ]
  where
    minimalAction = mkAction "build" [] []

    actionWithInputs n =
      Action
        { aName = "build",
          aCommand = ["gcc", "-o", "out"],
          aInputs = Map.fromList [(T.pack $ "file" <> show i, T.pack $ "hash" <> show i) | i <- [1 .. n]],
          aInputKeys = [],
          aOutputs = ["out"],
          aEnv = Map.empty,
          aCoeffects = []
        }

    actionWithDeps n =
      let deps = [ActionKey $ TE.encodeUtf8 $ T.pack $ "dep" <> show i | i <- [1 .. n]]
       in mkAction "build" [] deps

    actionWithLongCommand =
      Action
        { aName = "build",
          aCommand = replicate 100 "argument",
          aInputs = Map.empty,
          aInputKeys = [],
          aOutputs = ["out"],
          aEnv = Map.empty,
          aCoeffects = []
        }

    uniqueActions1000 = [mkAction (T.pack $ "action" <> show i) [] [] | i <- [1 .. 1000 :: Int]]

-- ════════════════════════════════════════════════════════════════════════════
-- TopoSort Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

topoSortBenchmarks :: [Benchmark]
topoSortBenchmarks =
  [ bgroup
      "linear chain"
      [ bench "10" $ nf topoSort (linearChainGraph 10),
        bench "100" $ nf topoSort (linearChainGraph 100),
        bench "1000" $ nf topoSort (linearChainGraph 1000),
        bench "10000" $ nf topoSort (linearChainGraph 10000)
      ],
    bgroup
      "wide independent"
      [ bench "10" $ nf topoSort (independentGraph 10),
        bench "100" $ nf topoSort (independentGraph 100),
        bench "1000" $ nf topoSort (independentGraph 1000),
        bench "10000" $ nf topoSort (independentGraph 10000)
      ],
    bgroup
      "diamond"
      [ bench "depth=10, width=10" $ nf topoSort (diamondGraph 10 10),
        bench "depth=50, width=50" $ nf topoSort (diamondGraph 50 50),
        bench "depth=100, width=10" $ nf topoSort (diamondGraph 100 10),
        bench "depth=10, width=100" $ nf topoSort (diamondGraph 10 100)
      ],
    bgroup
      "dense"
      [ bench "100 nodes, 10 edges/node" $ nf topoSort (denseGraph 100 10),
        bench "500 nodes, 10 edges/node" $ nf topoSort (denseGraph 500 10),
        bench "100 nodes, 50 edges/node" $ nf topoSort (denseGraph 100 50)
      ]
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Graph Construction Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

graphConstructionBenchmarks :: [Benchmark]
graphConstructionBenchmarks =
  [ bgroup
      "addAction"
      [ bench "1 action" $ whnf (addAction minimalAction) emptyGraph,
        bench "10 sequential" $ whnf (foldr addAction emptyGraph) (replicate 10 minimalAction),
        bench "100 sequential" $ whnf (foldr addAction emptyGraph) (replicate 100 minimalAction),
        bench "1000 sequential" $ whnf (foldr addAction emptyGraph) (replicate 1000 minimalAction),
        bench "10000 sequential" $ whnf (foldr addAction emptyGraph) (replicate 10000 minimalAction)
      ],
    bgroup
      "addAction unique"
      [ bench "100 unique" $ whnf (foldr addAction emptyGraph) [mkAction (T.pack $ show i) [] [] | i <- [1 .. 100 :: Int]],
        bench "1000 unique" $ whnf (foldr addAction emptyGraph) [mkAction (T.pack $ show i) [] [] | i <- [1 .. 1000 :: Int]],
        bench "10000 unique" $ whnf (foldr addAction emptyGraph) [mkAction (T.pack $ show i) [] [] | i <- [1 .. 10000 :: Int]]
      ]
  ]
  where
    minimalAction = mkAction "build" [] []

-- ════════════════════════════════════════════════════════════════════════════
-- Scaling Benchmarks
-- Compare O(n) vs O(n log n) vs O(n²) behavior
-- ════════════════════════════════════════════════════════════════════════════

scalingBenchmarks :: [Benchmark]
scalingBenchmarks =
  [ bgroup
      "topoSort scaling"
      [ bench "n=100" $ nf measureTopoSort 100,
        bench "n=200" $ nf measureTopoSort 200,
        bench "n=400" $ nf measureTopoSort 400,
        bench "n=800" $ nf measureTopoSort 800,
        bench "n=1600" $ nf measureTopoSort 1600,
        bench "n=3200" $ nf measureTopoSort 3200
      ],
    bgroup
      "hash scaling"
      [ bench "n=1000" $ nf measureHashing 1000,
        bench "n=2000" $ nf measureHashing 2000,
        bench "n=4000" $ nf measureHashing 4000,
        bench "n=8000" $ nf measureHashing 8000,
        bench "n=16000" $ nf measureHashing 16000
      ],
    bgroup
      "graphConstruction scaling"
      [ bench "n=1000" $ nf measureGraphConstruction 1000,
        bench "n=2000" $ nf measureGraphConstruction 2000,
        bench "n=4000" $ nf measureGraphConstruction 4000,
        bench "n=8000" $ nf measureGraphConstruction 8000
      ],
    bgroup
      "end-to-end scaling"
      [ bench "n=500" $ nf measureEndToEnd 500,
        bench "n=1000" $ nf measureEndToEnd 1000,
        bench "n=2000" $ nf measureEndToEnd 2000,
        bench "n=4000" $ nf measureEndToEnd 4000
      ]
  ]
  where
    measureTopoSort n =
      let graph = linearChainGraph n
       in length $ topoSort graph

    measureHashing n =
      let inputs = [T.pack $ "input" <> show i | i <- [1 .. n]]
       in length $ map hashText inputs

    measureGraphConstruction n =
      let actions = [mkAction (T.pack $ show i) [] [] | i <- [1 .. n]]
          graph = foldr addAction emptyGraph actions
       in Map.size $ agActions graph

    measureEndToEnd n =
      let actions = [mkAction (T.pack $ show i) [] [] | i <- [1 .. n]]
          graph = foldr addAction emptyGraph actions
          sorted = topoSort graph
       in length sorted

-- ════════════════════════════════════════════════════════════════════════════
-- Graph Builders
-- ════════════════════════════════════════════════════════════════════════════

-- Linear chain: A -> B -> C -> ...
linearChainGraph :: Int -> ActionGraph
linearChainGraph n = foldr addAction emptyGraph $ buildLinearChain n

buildLinearChain :: Int -> [Action]
buildLinearChain n = go n Nothing []
  where
    go 0 _ acc = acc
    go i prevKey acc =
      let action = mkAction (T.pack $ show i) [] (maybe [] (: []) prevKey)
          key = actionKey action
       in go (i - 1) (Just key) (action : acc)

-- Independent actions (no dependencies)
independentGraph :: Int -> ActionGraph
independentGraph n =
  let actions = [mkAction (T.pack $ show i) [] [] | i <- [1 .. n]]
   in foldr addAction emptyGraph actions

-- Diamond: each layer connects to all nodes in next layer
diamondGraph :: Int -> Int -> ActionGraph
diamondGraph depth width = foldr addAction emptyGraph allActions
  where
    allActions = concatMap makeLayer [0 .. depth - 1]

    makeLayer :: Int -> [Action]
    makeLayer layer =
      [ let deps =
              if layer == 0
                then []
                else [actionKey (mkAction (T.pack $ show (layer - 1) <> "-" <> show j) [] []) | j <- [0 .. width - 1]]
         in mkAction (T.pack $ show layer <> "-" <> show i) [] deps
      | i <- [0 .. width - 1]
      ]

-- Dense graph: each node connects to several previous nodes
denseGraph :: Int -> Int -> ActionGraph
denseGraph nodes edgesPerNode = foldr addAction emptyGraph actionsWithDeps
  where
    baseActions = [mkAction (T.pack $ show i) [] [] | i <- [0 .. nodes - 1]]
    keys = map actionKey baseActions

    actionsWithDeps =
      [ let deps = [keys !! j | j <- [max 0 (i - edgesPerNode) .. i - 1], j < i]
         in (baseActions !! i) {aInputKeys = deps}
      | i <- [0 .. nodes - 1]
      ]

-- ════════════════════════════════════════════════════════════════════════════
-- Local Type Definitions (mirror DICE for standalone benchmarks)
-- ════════════════════════════════════════════════════════════════════════════

newtype ActionKey = ActionKey {unActionKey :: ByteString}
  deriving (Show, Eq, Ord)

actionKeyText :: ActionKey -> Text
actionKeyText (ActionKey bs) = TE.decodeUtf8 bs

instance NFData ActionKey where
  rnf (ActionKey t) = rnf t

data Action = Action
  { aName :: Text,
    aCommand :: [Text],
    aInputs :: Map.Map Text Text,
    aInputKeys :: [ActionKey],
    aOutputs :: [FilePath],
    aEnv :: Map.Map Text Text,
    aCoeffects :: [Text]
  }
  deriving (Show, Eq)

instance NFData Action where
  rnf Action {..} =
    rnf aName `seq`
      rnf aCommand `seq`
        rnf aInputs `seq`
          rnf aInputKeys `seq`
            rnf aOutputs `seq`
              rnf aEnv `seq`
                rnf aCoeffects

data ActionGraph = ActionGraph
  { agActions :: Map.Map ActionKey Action,
    agRoots :: [ActionKey]
  }
  deriving (Show)

instance NFData ActionGraph where
  rnf ActionGraph {..} = rnf agActions `seq` rnf agRoots

emptyGraph :: ActionGraph
emptyGraph = ActionGraph Map.empty []

addAction :: Action -> ActionGraph -> ActionGraph
addAction action graph =
  let key = actionKey action
   in graph {agActions = Map.insert key action (agActions graph)}

actionKey :: Action -> ActionKey
actionKey action =
  let content = actionToCanonical action
      hash = hashWith SHA256 (TE.encodeUtf8 content)
   in ActionKey (BA.convertToBase BA.Base16 hash)

actionToCanonical :: Action -> Text
actionToCanonical Action {..} =
  T.intercalate
    "\n"
    [ "name:" <> aName,
      "cmd:" <> T.intercalate " " aCommand,
      "inputs:" <> T.intercalate "," (map fst $ Map.toAscList aInputs),
      "deps:" <> T.intercalate "," (map (TE.decodeUtf8 . unActionKey) aInputKeys),
      "outputs:" <> T.intercalate "," (map T.pack aOutputs)
    ]

topoSort :: ActionGraph -> [ActionKey]
topoSort ActionGraph {..} = reverse $ go Set.empty [] (Map.keys agActions)
  where
    go :: Set.Set ActionKey -> [ActionKey] -> [ActionKey] -> [ActionKey]
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

mkAction :: Text -> [Text] -> [ActionKey] -> Action
mkAction cmd inputs deps =
  Action
    { aName = cmd,
      aCommand = [cmd],
      aInputs = Map.fromList [(inp, hashText inp) | inp <- inputs],
      aInputKeys = deps,
      aOutputs = ["out"],
      aEnv = Map.empty,
      aCoeffects = []
    }

-- Real SHA256 hash using crypton
hashText :: Text -> Text
hashText t =
  let hash = hashWith SHA256 (TE.encodeUtf8 t)
      hex = BA.convertToBase BA.Base16 hash :: ByteString
   in TE.decodeUtf8 hex
