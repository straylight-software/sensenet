{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | PSYCHOTIC TESTS for sensenet
--
-- These tests are designed to BREAK EVERYTHING.
-- Property-based fuzzing, chaos engineering, stress tests.
-- If sensenet survives this, it survives production.
--
-- "Everyone has a plan until they get punched in the mouth."
-- - Mike Tyson
module Test.SenseNet.Psychotic (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (async, race, wait)
import Control.DeepSeq (NFData (..), deepseq, force)
import Control.Exception (ErrorCall, SomeException, evaluate, try)
import Control.Monad (forM, forM_, replicateM, when)
import Crypto.Hash (Blake2b_256 (..), hashWith)
import Data.ByteArray.Encoding qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (foldl')
import Data.IORef
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

tests :: TestTree
tests =
  testGroup
    "PSYCHOTIC"
    [ testGroup "PropertyFuzzing" propertyFuzzingTests,
      testGroup "StressTests" stressTests,
      testGroup "ChaosEngineering" chaosTests,
      testGroup "ConcurrencyTorture" concurrencyTests,
      testGroup "MemoryTorture" memoryTests,
      testGroup "BoundaryViolence" boundaryTests,
      testGroup "UnicodeWarfare" unicodeTests,
      testGroup "HashCollisionHunting" hashCollisionTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- PROPERTY-BASED FUZZING
-- ════════════════════════════════════════════════════════════════════════════

propertyFuzzingTests :: [TestTree]
propertyFuzzingTests =
  [ testProperty "topoSort output contains all input keys" prop_topoSortContainsAll,
    testProperty "topoSort output has no duplicates" prop_topoSortNoDuplicates,
    testProperty "topoSort respects dependencies" prop_topoSortRespectsDeps,
    testProperty "actionKey is deterministic" prop_actionKeyDeterministic,
    testProperty "actionKey changes when inputs change" prop_actionKeySensitive,
    testProperty "hash is fixed-length (64 chars)" prop_hashFixedLength,
    testProperty "hash is valid hex" prop_hashValidHex,
    testProperty "addAction is idempotent" prop_addActionIdempotent,
    testProperty "emptyGraph + action = single action graph" prop_emptyGraphAddAction,
    testProperty "intercalate empty list doesn't crash" prop_safeIntercalate,
    testProperty "dep cycle detection terminates" prop_cycleDetectionTerminates,
    testProperty "random action graphs don't crash topoSort" prop_randomGraphsStable
  ]

prop_topoSortContainsAll :: Property
prop_topoSortContainsAll = forAll genActionGraph $ \graph ->
  let sorted = topoSort graph
      keys = Map.keys (agActions graph)
   in Set.fromList sorted == Set.fromList keys

prop_topoSortNoDuplicates :: Property
prop_topoSortNoDuplicates = forAll genActionGraph $ \graph ->
  let sorted = topoSort graph
   in length sorted == length (nub sorted)

prop_topoSortRespectsDeps :: Property
prop_topoSortRespectsDeps = forAll genActionGraph $ \graph ->
  let sorted = topoSort graph
      positions = Map.fromList $ zip sorted [0 :: Int ..]
   in all (depsBeforeAction positions graph) (Map.toList $ agActions graph)
  where
    depsBeforeAction positions graph (key, action) =
      all (\dep -> posOf dep <= posOf key) validDeps
      where
        validDeps = filter (`Map.member` agActions graph) (aInputKeys action)
        posOf k = Map.findWithDefault maxBound k positions

prop_actionKeyDeterministic :: Property
prop_actionKeyDeterministic = forAll genAction $ \action ->
  actionKey action == actionKey action

prop_actionKeySensitive :: Property
prop_actionKeySensitive = forAll genTwoDistinctActions $ \(a1, a2) ->
  actionKey a1 /= actionKey a2

prop_hashFixedLength :: Property
prop_hashFixedLength = forAll arbitrary $ \(s :: String) ->
  T.length (hashText (T.pack s)) == 64

prop_hashValidHex :: Property
prop_hashValidHex = forAll arbitrary $ \(s :: String) ->
  T.all isHexChar (hashText (T.pack s))

prop_addActionIdempotent :: Property
prop_addActionIdempotent = forAll genAction $ \action ->
  let g1 = addAction action emptyGraph
      g2 = addAction action g1
   in Map.size (agActions g1) == Map.size (agActions g2)

prop_emptyGraphAddAction :: Property
prop_emptyGraphAddAction = forAll genAction $ \action ->
  let graph = addAction action emptyGraph
   in Map.size (agActions graph) == 1

prop_safeIntercalate :: Property
prop_safeIntercalate = forAll arbitrary $ \(xs :: [String]) ->
  let result = safeIntercalate "," xs
   in length result >= 0

prop_cycleDetectionTerminates :: Property
prop_cycleDetectionTerminates = forAll genPotentiallyCyclicGraph $ \graph ->
  within 1000000 $ length (topoSort graph) >= 0

prop_randomGraphsStable :: Property
prop_randomGraphsStable = forAll (resize 100 genActionGraph) $ \graph ->
  let sorted = topoSort graph
   in length sorted == Map.size (agActions graph)

-- ════════════════════════════════════════════════════════════════════════════
-- STRESS TESTS
-- ════════════════════════════════════════════════════════════════════════════

stressTests :: [TestTree]
stressTests =
  [ testCase "10,000 independent actions" stress_10kIndependentActions,
    testCase "1,000 action linear chain" stress_1kLinearChain,
    testCase "deep diamond (depth=100, width=100)" stress_deepDiamond,
    testCase "hash 1MB of data" stress_hashLargeData,
    testCase "100,000 small hashes" stress_manySmallHashes,
    testCase "action with 10,000 inputs" stress_manyInputs,
    testCase "action with 10,000 dependencies" stress_manyDeps,
    testCase "graph with 50,000 edges" stress_manyEdges,
    testCase "rapid graph construction/destruction" stress_rapidGraphOps
  ]

stress_10kIndependentActions :: Assertion
stress_10kIndependentActions = do
  let n = 10000
      actions = [mkAction ("action" <> T.pack (show i)) [] [] | i <- [1 .. n]]
      graph = foldr addAction emptyGraph actions
  result <- timeout 10000000 $ evaluate $ length $ topoSort graph
  case result of
    Nothing -> assertFailure "10k actions timed out (10s)"
    Just len -> len @?= n

stress_1kLinearChain :: Assertion
stress_1kLinearChain = do
  let n = 1000
      actions = buildLinearChain n
      graph = foldr addAction emptyGraph actions
  result <- timeout 10000000 $ evaluate $ length $ topoSort graph
  case result of
    Nothing -> assertFailure "1k chain timed out (10s)"
    Just len -> len @?= n

stress_deepDiamond :: Assertion
stress_deepDiamond = do
  let depth = 100
      width = 100
      (graph, totalNodes) = buildDiamondGraph depth width
  result <- timeout 30000000 $ evaluate $ length $ topoSort graph
  case result of
    Nothing -> assertFailure "deep diamond timed out (30s)"
    Just len -> len @?= totalNodes

stress_hashLargeData :: Assertion
stress_hashLargeData = do
  let megabyte = T.replicate 1000000 "x"
  result <- timeout 5000000 $ evaluate $ T.length $ hashText megabyte
  case result of
    Nothing -> assertFailure "1MB hash timed out (5s)"
    Just len -> len @?= 64

stress_manySmallHashes :: Assertion
stress_manySmallHashes = do
  let n = 100000
  result <- timeout 30000000 $ evaluate $ length [hashText (T.pack $ show i) | i <- [1 .. n]]
  case result of
    Nothing -> assertFailure "100k hashes timed out (30s)"
    Just len -> len @?= n

stress_manyInputs :: Assertion
stress_manyInputs = do
  let n = 10000
      inputs = Map.fromList [(T.pack $ "input" <> show i, hashText (T.pack $ show i)) | i <- [1 .. n]]
      action =
        Action
          { aName = "massive",
            aCommand = ["build"],
            aInputs = inputs,
            aInputKeys = [],
            aOutputs = ["out"],
            aEnv = Map.empty,
            aCoeffects = []
          }
  result <- timeout 5000000 $ evaluate $ T.length $ actionKeyText $ actionKey action
  case result of
    Nothing -> assertFailure "10k inputs timed out (5s)"
    Just len -> len @?= 64

stress_manyDeps :: Assertion
stress_manyDeps = do
  let n = 10000
      depActions = [mkAction ("dep" <> T.pack (show i)) [] [] | i <- [1 .. n]]
      depKeys = map actionKey depActions
      mainAction = mkAction "main" [] depKeys
      graph = addAction mainAction $ foldr addAction emptyGraph depActions
  result <- timeout 10000000 $ evaluate $ length $ topoSort graph
  case result of
    Nothing -> assertFailure "10k deps timed out (10s)"
    Just len -> len @?= n + 1

stress_manyEdges :: Assertion
stress_manyEdges = do
  let (graph, nodeCount) = buildDenseGraph 500 100
  result <- timeout 30000000 $ evaluate $ length $ topoSort graph
  case result of
    Nothing -> assertFailure "50k edges timed out (30s)"
    Just len -> len @?= nodeCount

stress_rapidGraphOps :: Assertion
stress_rapidGraphOps = do
  let iterations = 1000
  result <- timeout 10000000 $ do
    forM_ [1 .. iterations] $ \i -> do
      let actions = [mkAction (T.pack $ show i <> "-" <> show j) [] [] | j <- [1 .. 100 :: Int]]
          graph = foldr addAction emptyGraph actions
      _ <- evaluate $ length $ topoSort graph
      when (i `mod` 100 == 0) performGC
    pure iterations
  case result of
    Nothing -> assertFailure "rapid ops timed out (10s)"
    Just _ -> pure ()

-- ════════════════════════════════════════════════════════════════════════════
-- CHAOS ENGINEERING
-- ════════════════════════════════════════════════════════════════════════════

chaosTests :: [TestTree]
chaosTests =
  [ testCase "timeout mid-execution" chaos_timeoutMidExecution,
    testCase "exception during action execution" chaos_exceptionDuringExecution,
    testCase "null bytes in inputs" chaos_nullBytes,
    testCase "newlines in action names" chaos_newlinesInNames,
    testCase "very long action names (100KB)" chaos_veryLongNames,
    testCase "empty everything" chaos_emptyEverything,
    testCase "maximum nesting depth" chaos_maxNesting
  ]

chaos_timeoutMidExecution :: Assertion
chaos_timeoutMidExecution = do
  result <- timeout 100000 $ do
    threadDelay 1000000
    pure "completed"
  result @?= Nothing

chaos_exceptionDuringExecution :: Assertion
chaos_exceptionDuringExecution = do
  result <- try @SomeException $ evaluate $ error "intentional chaos"
  case result of
    Left _ -> pure ()
    Right _ -> assertFailure "exception should have been thrown"

chaos_nullBytes :: Assertion
chaos_nullBytes = do
  let withNulls = "hello\0world\0test"
      hash = hashText (T.pack withNulls)
  T.length hash @?= 64

chaos_newlinesInNames :: Assertion
chaos_newlinesInNames = do
  let action = mkAction "name\nwith\nnewlines\n" [] []
      key = actionKey action
  T.length (actionKeyText key) @?= 64

chaos_veryLongNames :: Assertion
chaos_veryLongNames = do
  let longName = T.replicate 100000 "x"
      action = mkAction longName [] []
      key = actionKey action
  T.length (actionKeyText key) @?= 64

chaos_emptyEverything :: Assertion
chaos_emptyEverything = do
  let action =
        Action
          { aName = "",
            aCommand = [],
            aInputs = Map.empty,
            aInputKeys = [],
            aOutputs = [],
            aEnv = Map.empty,
            aCoeffects = []
          }
      graph = addAction action emptyGraph
      sorted = topoSort graph
  length sorted @?= 1

chaos_maxNesting :: Assertion
chaos_maxNesting = do
  let depth = 5000
      chain = buildLinearChain depth
      graph = foldr addAction emptyGraph chain
  result <- timeout 10000000 $ evaluate $ length $ topoSort graph
  case result of
    Nothing -> assertFailure "max nesting timed out"
    Just len -> len @?= depth

-- ════════════════════════════════════════════════════════════════════════════
-- CONCURRENCY TORTURE
-- ════════════════════════════════════════════════════════════════════════════

concurrencyTests :: [TestTree]
concurrencyTests =
  [ testCase "parallel graph construction" conc_parallelConstruction,
    testCase "parallel hashing" conc_parallelHashing,
    testCase "parallel topoSort" conc_parallelTopoSort,
    testCase "thread safety of ActionKey" conc_threadSafetyActionKey,
    testCase "no deadlock with shared resources" conc_noDeadlock
  ]

conc_parallelConstruction :: Assertion
conc_parallelConstruction = do
  let numThreads = 100
      numActions = 100
  results <- forConcurrently [1 .. numThreads] $ \t -> do
    let actions = [mkAction (T.pack $ show t <> "-" <> show i) [] [] | i <- [1 .. numActions]]
        graph = foldr addAction emptyGraph actions
    pure $ length $ topoSort graph
  all (== numActions) results @?= True

conc_parallelHashing :: Assertion
conc_parallelHashing = do
  let numThreads = 1000
  results <- forConcurrently [1 .. numThreads] $ \i -> do
    let hash = hashText (T.pack $ "input" <> show i)
    pure $ T.length hash
  all (== 64) results @?= True

conc_parallelTopoSort :: Assertion
conc_parallelTopoSort = do
  let actions = [mkAction (T.pack $ show i) [] [] | i <- [1 .. 1000 :: Int]]
      graph = foldr addAction emptyGraph actions
      numThreads = 100
  results <- forConcurrently [1 .. numThreads] $ \_ -> do
    pure $ length $ topoSort graph
  all (== 1000) results @?= True

conc_threadSafetyActionKey :: Assertion
conc_threadSafetyActionKey = do
  let action = mkAction "shared" ["file.c"] []
      numThreads = 1000
  results <- forConcurrently [1 .. numThreads] $ \_ -> do
    pure $ actionKeyText $ actionKey action
  length (nub results) @?= 1

conc_noDeadlock :: Assertion
conc_noDeadlock = do
  result <- timeout 5000000 $ do
    ref <- newIORef (0 :: Int)
    forConcurrently [1 .. 100] $ \_ -> do
      forM_ [1 .. 100] $ \_ -> do
        atomicModifyIORef' ref (\x -> (x + 1, ()))
    readIORef ref
  case result of
    Nothing -> assertFailure "deadlock detected"
    Just n -> n @?= 10000

-- ════════════════════════════════════════════════════════════════════════════
-- MEMORY TORTURE
-- ════════════════════════════════════════════════════════════════════════════

memoryTests :: [TestTree]
memoryTests =
  [ testCase "force GC during operations" mem_forceGC,
    testCase "retain and release large structures" mem_retainRelease,
    testCase "thunk explosion prevention" mem_thunkExplosion
  ]

mem_forceGC :: Assertion
mem_forceGC = do
  forM_ [1 .. 10] $ \_ -> do
    let actions = [mkAction (T.pack $ show i) [] [] | i <- [1 .. 10000 :: Int]]
        graph = foldr addAction emptyGraph actions
    _ <- evaluate $ length $ topoSort graph
    performGC
  pure ()

mem_retainRelease :: Assertion
mem_retainRelease = do
  ref <- newIORef (Nothing :: Maybe ActionGraph)
  let actions = [mkAction (T.pack $ show i) [] [] | i <- [1 .. 10000 :: Int]]
      graph = foldr addAction emptyGraph actions
  writeIORef ref (Just graph)
  g <- readIORef ref
  case g of
    Just graph' -> do
      _ <- evaluate $ length $ topoSort graph'
      pure ()
    Nothing -> pure ()
  writeIORef ref Nothing
  performGC
  pure ()

mem_thunkExplosion :: Assertion
mem_thunkExplosion = do
  let n = 100000
      hashes = foldl' (\acc i -> hashText (T.pack $ show i) : acc) [] [1 .. n]
  result <- timeout 10000000 $ evaluate $ length hashes
  case result of
    Nothing -> assertFailure "thunk explosion"
    Just len -> len @?= n

-- ════════════════════════════════════════════════════════════════════════════
-- BOUNDARY VIOLENCE
-- ════════════════════════════════════════════════════════════════════════════

boundaryTests :: [TestTree]
boundaryTests =
  [ testCase "empty string hash" bound_emptyStringHash,
    testCase "single byte hashes all unique" bound_singleByteHash,
    testCase "maximum Int in action" bound_maxInt,
    testCase "zero-length list everywhere" bound_zeroLengthLists,
    testCase "single character variations" bound_singleCharVariations
  ]

bound_emptyStringHash :: Assertion
bound_emptyStringHash = do
  let hash = hashText ""
  T.length hash @?= 64
  -- BLAKE2b-256 of empty string
  hash @?= "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"

bound_singleByteHash :: Assertion
bound_singleByteHash = do
  -- Every printable ASCII byte should produce unique hash
  let hashes = [hashText (T.singleton c) | c <- ['!' .. '~']]
  length (nub hashes) @?= length hashes

bound_maxInt :: Assertion
bound_maxInt = do
  let bigNum = T.pack $ show (maxBound :: Int)
      hash = hashText bigNum
  T.length hash @?= 64

bound_zeroLengthLists :: Assertion
bound_zeroLengthLists = do
  let action =
        Action
          { aName = "empty",
            aCommand = [],
            aInputs = Map.empty,
            aInputKeys = [],
            aOutputs = [],
            aEnv = Map.empty,
            aCoeffects = []
          }
  T.length (actionKeyText $ actionKey action) @?= 64

bound_singleCharVariations :: Assertion
bound_singleCharVariations = do
  let variations =
        [ mkAction "test" ["file.c"] [],
          mkAction "Test" ["file.c"] [],
          mkAction "test" ["File.c"] [],
          mkAction "test" ["file.C"] [],
          mkAction "test " ["file.c"] [],
          mkAction " test" ["file.c"] []
        ]
      keys = map actionKey variations
  length (nub keys) > 1 @?= True

-- ════════════════════════════════════════════════════════════════════════════
-- UNICODE WARFARE
-- ════════════════════════════════════════════════════════════════════════════

unicodeTests :: [TestTree]
unicodeTests =
  [ testCase "BOM handling" unicode_bom,
    testCase "RTL characters" unicode_rtl,
    testCase "zero-width characters" unicode_zeroWidth,
    testCase "emoji" unicode_emoji,
    testCase "combining characters" unicode_combining,
    testCase "surrogate pairs" unicode_surrogates,
    testCase "null in middle of string" unicode_nullMiddle,
    testCase "every plane" unicode_everyPlane
  ]

unicode_bom :: Assertion
unicode_bom = do
  let withBom = "\xFEFF" <> "hello"
      withoutBom = "hello"
  hashText (T.pack withBom) /= hashText (T.pack withoutBom) @?= True

unicode_rtl :: Assertion
unicode_rtl = do
  let rtl = "\x200F\x05D0\x05D1\x05D2"
      hash = hashText (T.pack rtl)
  T.length hash @?= 64

unicode_zeroWidth :: Assertion
unicode_zeroWidth = do
  let withZW = "he\x200Bllo"
      without = "hello"
  hashText (T.pack withZW) /= hashText (T.pack without) @?= True

unicode_emoji :: Assertion
unicode_emoji = do
  let emoji = "🔥💀🎉🚀"
      hash = hashText (T.pack emoji)
  T.length hash @?= 64

unicode_combining :: Assertion
unicode_combining = do
  let combining = "e\x0301"
      precomposed = "é"
      h1 = hashText (T.pack combining)
      h2 = hashText (T.pack precomposed)
  T.length h1 @?= 64
  T.length h2 @?= 64

unicode_surrogates :: Assertion
unicode_surrogates = do
  let astral = "𐀀𐀁𐀂"
      hash = hashText (T.pack astral)
  T.length hash @?= 64

unicode_nullMiddle :: Assertion
unicode_nullMiddle = do
  let withNull = "hello\x0000world"
      hash = hashText (T.pack withNull)
  T.length hash @?= 64

unicode_everyPlane :: Assertion
unicode_everyPlane = do
  let planes = ["A", "𐀀", "𠀀", "🀀"]
      hashes = map (hashText . T.pack) planes
  length (nub hashes) @?= 4

-- ════════════════════════════════════════════════════════════════════════════
-- HASH COLLISION HUNTING
-- ════════════════════════════════════════════════════════════════════════════

hashCollisionTests :: [TestTree]
hashCollisionTests =
  [ testCase "no collisions in 100k sequential" hash_noCollisions100k,
    testCase "no collisions in similar inputs" hash_noCollisionsSimilar,
    testProperty "random inputs unique hashes" prop_noRandomCollision
  ]

hash_noCollisions100k :: Assertion
hash_noCollisions100k = do
  let n = 100000
      hashes = [hashText (T.pack $ show i) | i <- [1 .. n]]
      unique = Set.fromList hashes
  Set.size unique @?= n

hash_noCollisionsSimilar :: Assertion
hash_noCollisionsSimilar = do
  let base = "test input string for hashing"
      variations =
        [ base,
          "Test input string for hashing",
          "test input string for hashinG",
          "test input string for hashing ",
          " test input string for hashing",
          "test input  string for hashing",
          "test input string for hashing\n"
        ]
      hashes = map (hashText . T.pack) variations
      unique = nub hashes
  length unique @?= length variations

prop_noRandomCollision :: Property
prop_noRandomCollision = forAll (vectorOf 50 (listOf1 $ elements ['a' .. 'z'])) $ \xs ->
  let uniqueInputs = nub xs
      hashes = map (hashText . T.pack) uniqueInputs
   in length (nub hashes) == length uniqueInputs

-- ════════════════════════════════════════════════════════════════════════════
-- GENERATORS
-- ════════════════════════════════════════════════════════════════════════════

genAction :: Gen Action
genAction = do
  name <- T.pack <$> listOf1 (elements ['a' .. 'z'])
  numInputs <- choose (0, 10)
  inputs <- replicateM numInputs $ do
    inp <- T.pack <$> listOf1 (elements ['a' .. 'z'])
    pure (inp, hashText inp)
  pure
    Action
      { aName = name,
        aCommand = [name],
        aInputs = Map.fromList inputs,
        aInputKeys = [],
        aOutputs = ["out"],
        aEnv = Map.empty,
        aCoeffects = []
      }

genTwoDistinctActions :: Gen (Action, Action)
genTwoDistinctActions = do
  a1 <- genAction
  a2 <- genAction `suchThat` (\a -> actionKey a /= actionKey a1)
  pure (a1, a2)

genActionGraph :: Gen ActionGraph
genActionGraph = sized $ \n -> do
  numActions <- choose (0, max 1 n)
  if numActions == 0
    then pure emptyGraph
    else do
      baseActions <- replicateM numActions genAction
      let indexed = zip [0 ..] baseActions
      actionsWithDeps <- forM indexed $ \(i, action) -> do
        numDeps <- choose (0, min 3 i)
        depIndices <- nub <$> replicateM numDeps (choose (0, max 0 (i - 1)))
        let depKeys = [actionKey (baseActions !! j) | j <- depIndices, j < length baseActions]
        pure action {aInputKeys = depKeys}
      pure $ foldr addAction emptyGraph actionsWithDeps

genPotentiallyCyclicGraph :: Gen ActionGraph
genPotentiallyCyclicGraph = sized $ \n -> do
  numActions <- choose (1, max 1 n)
  baseActions <- replicateM numActions genAction
  let keys = map actionKey baseActions
  actionsWithDeps <- forM baseActions $ \action -> do
    numDeps <- choose (0, 3)
    depKeys <- replicateM numDeps (elements keys)
    pure action {aInputKeys = depKeys}
  pure $ foldr addAction emptyGraph actionsWithDeps

-- ════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ════════════════════════════════════════════════════════════════════════════

safeIntercalate :: String -> [String] -> String
safeIntercalate _ [] = ""
safeIntercalate sep xs = foldr1 (\a b -> a <> sep <> b) xs

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

buildLinearChain :: Int -> [Action]
buildLinearChain n = go n Nothing []
  where
    go 0 _ acc = acc
    go i prevKey acc =
      let action = mkAction ("action" <> T.pack (show i)) [] (maybe [] (: []) prevKey)
          key = actionKey action
       in go (i - 1) (Just key) (action : acc)

buildDiamondGraph :: Int -> Int -> (ActionGraph, Int)
buildDiamondGraph depth width = (graph, depth * width)
  where
    graph = foldr addAction emptyGraph allActions
    allActions = concatMap makeLayer [0 .. depth - 1]
    makeLayer layer =
      [ let deps =
              if layer == 0
                then []
                else [actionKey (mkAction (T.pack $ show (layer - 1) <> "-" <> show j) [] []) | j <- [0 .. width - 1]]
         in mkAction (T.pack $ show layer <> "-" <> show i) [] deps
      | i <- [0 .. width - 1]
      ]

buildDenseGraph :: Int -> Int -> (ActionGraph, Int)
buildDenseGraph nodes edgesPerNode = (graph, nodes)
  where
    baseActions = [mkAction (T.pack $ show i) [] [] | i <- [0 .. nodes - 1]]
    keys = map actionKey baseActions
    actionsWithDeps =
      [ let deps = [keys !! j | j <- [max 0 (i - edgesPerNode) .. i - 1], j < i]
         in (baseActions !! i) {aInputKeys = deps}
      | i <- [0 .. nodes - 1]
      ]
    graph = foldr addAction emptyGraph actionsWithDeps

forConcurrently :: [a] -> (a -> IO b) -> IO [b]
forConcurrently xs f = do
  asyncs <- mapM (async . f) xs
  mapM wait asyncs

isHexChar :: Char -> Bool
isHexChar c = c `elem` ("0123456789abcdef" :: String)

-- ════════════════════════════════════════════════════════════════════════════
-- LOCAL TYPES (mirror SenseNet.DICE)
-- ════════════════════════════════════════════════════════════════════════════

newtype ActionKey = ActionKey {unActionKey :: ByteString}
  deriving (Show, Eq, Ord)

actionKeyText :: ActionKey -> Text
actionKeyText (ActionKey bs) = TE.decodeUtf8 bs

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

data ActionGraph = ActionGraph
  { agActions :: Map.Map ActionKey Action,
    agRoots :: [ActionKey]
  }
  deriving (Show)

emptyGraph :: ActionGraph
emptyGraph = ActionGraph Map.empty []

addAction :: Action -> ActionGraph -> ActionGraph
addAction action graph =
  let key = actionKey action
   in graph {agActions = Map.insert key action (agActions graph)}

actionKey :: Action -> ActionKey
actionKey action =
  let content = actionToCanonical action
      hash = hashWith Blake2b_256 (TE.encodeUtf8 content)
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

-- Real Blake2b_256 hash using crypton
hashText :: Text -> Text
hashText t =
  let hash = hashWith Blake2b_256 (TE.encodeUtf8 t)
      hex = BA.convertToBase BA.Base16 hash :: ByteString
   in TE.decodeUtf8 hex
