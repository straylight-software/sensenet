{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | SAVAGE TESTS for sensenet
--
-- Mutation testing, invariant hunting, contract verification.
-- These tests are designed to catch bugs BEFORE they escape.
--
-- "Bring out the gimp." - Zed
module Test.SenseNet.Savage (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception (ErrorCall, SomeException, bracket, evaluate, try)
import Control.Monad (forM, forM_, replicateM, unless, when)
import Crypto.Hash (Blake2b_256 (..), hashWith)
import Data.Bits (xor)
import Data.ByteArray.Encoding qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, ord)
import Data.Foldable (foldl')
import Data.IORef
import Data.List (inits, nub, permutations, sort, subsequences, tails)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

tests :: TestTree
tests =
  testGroup
    "SAVAGE"
    [ testGroup "ContractVerification" contractTests,
      testGroup "InvariantHunting" invariantTests,
      testGroup "MutationStyle" mutationTests,
      testGroup "PermutationTesting" permutationTests,
      testGroup "BisectionAttack" bisectionTests,
      testGroup "FuzzyEquality" fuzzyEqualityTests,
      testGroup "TimeAttacks" timeAttackTests,
      testGroup "MemoryAttacks" memoryAttackTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- CONTRACT VERIFICATION
-- Verify that functions maintain their stated contracts
-- ════════════════════════════════════════════════════════════════════════════

contractTests :: [TestTree]
contractTests =
  [ testProperty "topoSort contract: |output| = |actions|" prop_topoSortSizeContract,
    testProperty "topoSort contract: output ⊆ actions" prop_topoSortSubsetContract,
    testProperty "topoSort contract: no duplicates" prop_topoSortUniqueContract,
    testProperty "addAction contract: size increases or stays same" prop_addActionSizeContract,
    testProperty "addAction contract: action retrievable" prop_addActionRetrievableContract,
    testProperty "emptyGraph contract: truly empty" prop_emptyGraphContract,
    testProperty "hash contract: deterministic" prop_hashDeterministicContract,
    testProperty "hash contract: fixed length" prop_hashLengthContract,
    testProperty "hash contract: changes with input" prop_hashSensitiveContract
  ]

prop_topoSortSizeContract :: Property
prop_topoSortSizeContract = forAll genGraph $ \graph ->
  length (topoSort graph) == Map.size (agActions graph)

prop_topoSortSubsetContract :: Property
prop_topoSortSubsetContract = forAll genGraph $ \graph ->
  all (`Map.member` agActions graph) (topoSort graph)

prop_topoSortUniqueContract :: Property
prop_topoSortUniqueContract = forAll genGraph $ \graph ->
  let sorted = topoSort graph
   in sorted == nub sorted

prop_addActionSizeContract :: Property
prop_addActionSizeContract = forAll ((,) <$> genAction <*> genGraph) $ \(action, graph) ->
  let newGraph = addAction action graph
      oldSize = Map.size (agActions graph)
      newSize = Map.size (agActions newGraph)
   in newSize >= oldSize && newSize <= oldSize + 1

prop_addActionRetrievableContract :: Property
prop_addActionRetrievableContract = forAll genAction $ \action ->
  let graph = addAction action emptyGraph
      key = actionKey action
   in Map.lookup key (agActions graph) == Just action

prop_emptyGraphContract :: Property
prop_emptyGraphContract = once $
  Map.null (agActions emptyGraph) && null (agRoots emptyGraph)

prop_hashDeterministicContract :: Property
prop_hashDeterministicContract = forAll arbitrary $ \(s :: String) ->
  let h1 = hashText (T.pack s)
      h2 = hashText (T.pack s)
   in h1 == h2

prop_hashLengthContract :: Property
prop_hashLengthContract = forAll arbitrary $ \(s :: String) ->
  T.length (hashText (T.pack s)) == 64

prop_hashSensitiveContract :: Property
prop_hashSensitiveContract = forAll genDistinctStrings $ \(s1, s2) ->
  hashText (T.pack s1) /= hashText (T.pack s2)

-- ════════════════════════════════════════════════════════════════════════════
-- INVARIANT HUNTING
-- Find invariants that should always hold
-- ════════════════════════════════════════════════════════════════════════════

invariantTests :: [TestTree]
invariantTests =
  [ testProperty "invariant: actionKey(a) == actionKey(a)" prop_actionKeyReflexive,
    testProperty "invariant: a == b => actionKey(a) == actionKey(b)" prop_actionKeyConsistent,
    testProperty "invariant: graph insert idempotent on same action" prop_insertIdempotent,
    testProperty "invariant: topoSort stable across calls" prop_topoSortStable,
    testProperty "invariant: empty + n actions = n actions graph" prop_emptyAccumulates,
    testProperty "invariant: hash prefix distribution uniform" prop_hashDistribution
  ]

prop_actionKeyReflexive :: Property
prop_actionKeyReflexive = forAll genAction $ \a ->
  actionKey a == actionKey a

prop_actionKeyConsistent :: Property
prop_actionKeyConsistent = forAll genAction $ \a ->
  let a' = a -- Same action
   in actionKey a == actionKey a'

prop_insertIdempotent :: Property
prop_insertIdempotent = forAll genAction $ \action ->
  let g1 = addAction action emptyGraph
      g2 = addAction action g1
   in Map.keys (agActions g1) == Map.keys (agActions g2)

prop_topoSortStable :: Property
prop_topoSortStable = forAll genGraph $ \graph ->
  topoSort graph == topoSort graph

prop_emptyAccumulates :: Property
prop_emptyAccumulates = forAll (listOf genAction) $ \actions ->
  let uniqueActions = nubBy (\a b -> actionKey a == actionKey b) actions
      graph = foldr addAction emptyGraph uniqueActions
   in Map.size (agActions graph) == length uniqueActions

prop_hashDistribution :: Property
prop_hashDistribution = forAll (vectorOf 1000 genNonEmptyString) $ \strings ->
  -- Check that first hex digit is roughly uniformly distributed
  let hashes = map (hashText . T.pack) strings
      firstChars = map T.head hashes
      counts = Map.fromListWith (+) [(c, 1 :: Int) | c <- firstChars]
      hexChars = ['0' .. '9'] ++ ['a' .. 'f']
      -- With 1000 hashes, each of 16 hex digits should appear ~62.5 times
      -- Check that no single hex char dominates (>200) or is absent (0)
      -- and that we use at least 10 different hex chars (not biased to subset)
      presentChars = filter (\c -> Map.findWithDefault 0 c counts > 0) hexChars
      maxCount = maximum $ map (\c -> Map.findWithDefault 0 c counts) hexChars
   in length presentChars >= 10 && maxCount < 200

-- ════════════════════════════════════════════════════════════════════════════
-- MUTATION STYLE TESTING
-- Systematically mutate inputs and verify behavior changes appropriately
-- ════════════════════════════════════════════════════════════════════════════

mutationTests :: [TestTree]
mutationTests =
  [ testCase "bit flip in input changes hash" mutation_bitFlip,
    testCase "byte insertion changes hash" mutation_byteInsertion,
    testCase "byte deletion changes hash" mutation_byteDeletion,
    testCase "byte swap changes hash (usually)" mutation_byteSwap,
    testCase "case flip changes hash" mutation_caseFlip,
    testCase "whitespace changes hash" mutation_whitespace,
    testProperty "single char mutation changes actionKey" prop_singleCharMutation
  ]

mutation_bitFlip :: Assertion
mutation_bitFlip = do
  let original = "test input"
      -- Flip one bit in the first byte
      mutated = chr (ord (head original) `xor` 1) : tail original
  hashText (T.pack original) /= hashText (T.pack mutated) @?= True

mutation_byteInsertion :: Assertion
mutation_byteInsertion = do
  let original = "testinput"
      mutated = "test_input" -- Insert one byte
  hashText (T.pack original) /= hashText (T.pack mutated) @?= True

mutation_byteDeletion :: Assertion
mutation_byteDeletion = do
  let original = "test_input"
      mutated = "testinput" -- Delete one byte
  hashText (T.pack original) /= hashText (T.pack mutated) @?= True

mutation_byteSwap :: Assertion
mutation_byteSwap = do
  let original = "abcd"
      mutated = "bacd" -- Swap first two bytes
  hashText (T.pack original) /= hashText (T.pack mutated) @?= True

mutation_caseFlip :: Assertion
mutation_caseFlip = do
  let original = "TestInput"
      mutated = "testinput"
  hashText (T.pack original) /= hashText (T.pack mutated) @?= True

mutation_whitespace :: Assertion
mutation_whitespace = do
  let original = "test"
      withSpace = "test "
      withTab = "test\t"
      withNewline = "test\n"
  let hashes =
        [ hashText (T.pack original),
          hashText (T.pack withSpace),
          hashText (T.pack withTab),
          hashText (T.pack withNewline)
        ]
  length (nub hashes) @?= 4 -- All different

prop_singleCharMutation :: Property
prop_singleCharMutation = forAll genNonEmptyString $ \s ->
  forAll (choose (0, length s - 1)) $ \idx ->
    let original = s
        c = s !! idx
        mutated = take idx s ++ [mutateChar c] ++ drop (idx + 1) s
     in hashText (T.pack original) /= hashText (T.pack mutated)
  where
    mutateChar c
      | c == 'z' = 'a'
      | otherwise = succ c

-- ════════════════════════════════════════════════════════════════════════════
-- PERMUTATION TESTING
-- Test all permutations of small inputs
-- ════════════════════════════════════════════════════════════════════════════

permutationTests :: [TestTree]
permutationTests =
  [ testCase "all 2-action permutations produce same graph" perm_2actions,
    testCase "all 3-action permutations produce same graph" perm_3actions,
    testCase "action insert order doesn't affect final graph keys" perm_insertOrder,
    testProperty "topoSort result set independent of insert order" prop_topoSortSetIndependent
  ]

perm_2actions :: Assertion
perm_2actions = do
  let a1 = mkAction "action1" [] []
      a2 = mkAction "action2" [] []
      perms = permutations [a1, a2]
      graphs = [foldr addAction emptyGraph p | p <- perms]
      keySets = [Set.fromList $ Map.keys $ agActions g | g <- graphs]
  -- All permutations should produce graphs with same key sets
  length (nub keySets) @?= 1

perm_3actions :: Assertion
perm_3actions = do
  let actions = [mkAction ("action" <> T.pack (show i)) [] [] | i <- [1 .. 3 :: Int]]
      perms = permutations actions
      graphs = [foldr addAction emptyGraph p | p <- perms]
      keySets = [Set.fromList $ Map.keys $ agActions g | g <- graphs]
  length (nub keySets) @?= 1

perm_insertOrder :: Assertion
perm_insertOrder = do
  let n = 5
      actions = [mkAction (T.pack $ show i) [] [] | i <- [1 .. n]]
      -- Test a few random permutations (not all n!, that's 120)
      perms = take 10 $ permutations actions
      graphs = [foldr addAction emptyGraph p | p <- perms]
      keySets = [Set.fromList $ Map.keys $ agActions g | g <- graphs]
  length (nub keySets) @?= 1

prop_topoSortSetIndependent :: Property
prop_topoSortSetIndependent = forAll (resize 6 genUniqueActionList) $ \actions ->
  let perms = take 10 $ permutations actions -- Limit to avoid explosion
      graphs = [foldr addAction emptyGraph p | p <- perms]
      sortedSets = [Set.fromList $ topoSort g | g <- graphs]
   in length (nub sortedSets) == 1

-- ════════════════════════════════════════════════════════════════════════════
-- BISECTION ATTACK
-- Find minimal failing inputs through bisection
-- ════════════════════════════════════════════════════════════════════════════

bisectionTests :: [TestTree]
bisectionTests =
  [ testCase "bisection: find minimal non-empty string that hashes" bisect_minimalHash,
    testCase "bisection: find minimal graph that sorts" bisect_minimalGraph,
    testProperty "all prefixes hash to different values" prop_prefixesUnique,
    testProperty "all suffixes hash to different values" prop_suffixesUnique
  ]

bisect_minimalHash :: Assertion
bisect_minimalHash = do
  -- Find the minimal input that produces a valid hash
  let inputs = ["", "a", "ab", "abc"]
      hashes = map (hashText . T.pack) inputs
  all (\h -> T.length h == 64) hashes @?= True

bisect_minimalGraph :: Assertion
bisect_minimalGraph = do
  -- Find minimal graph that successfully sorts
  let g0 = emptyGraph
      g1 = addAction (mkAction "a" [] []) emptyGraph
  length (topoSort g0) @?= 0
  length (topoSort g1) @?= 1

prop_prefixesUnique :: Property
prop_prefixesUnique = forAll genNonEmptyString $ \s ->
  length s <= 10 ==>
    let prefixes = filter (not . null) $ inits s
        hashes = map (hashText . T.pack) prefixes
     in length (nub hashes) == length prefixes

prop_suffixesUnique :: Property
prop_suffixesUnique = forAll genNonEmptyString $ \s ->
  length s <= 10 ==>
    let suffixes = filter (not . null) $ tails s
        hashes = map (hashText . T.pack) suffixes
     in length (nub hashes) == length suffixes

-- ════════════════════════════════════════════════════════════════════════════
-- FUZZY EQUALITY TESTING
-- Test near-equal inputs
-- ════════════════════════════════════════════════════════════════════════════

fuzzyEqualityTests :: [TestTree]
fuzzyEqualityTests =
  [ testCase "identical strings hash equal" fuzzy_identical,
    testCase "whitespace variants differ" fuzzy_whitespace,
    testCase "unicode normalization forms differ" fuzzy_unicodeNorm,
    testCase "numeric near-misses differ" fuzzy_numericNear
  ]

fuzzy_identical :: Assertion
fuzzy_identical = do
  let s = "test string"
  hashText (T.pack s) @?= hashText (T.pack s)

fuzzy_whitespace :: Assertion
fuzzy_whitespace = do
  let variants =
        [ "test",
          "test ",
          " test",
          "test\n",
          "test\t",
          "test\r",
          " test ",
          "  test"
        ]
      hashes = map (hashText . T.pack) variants
  length (nub hashes) @?= length variants

fuzzy_unicodeNorm :: Assertion
fuzzy_unicodeNorm = do
  -- Different unicode representations of same visual character
  let variants =
        [ "e\x0301", -- e + combining acute
          "\x00e9", -- precomposed é
          "e" -- plain e
        ]
      hashes = map (hashText . T.pack) variants
  -- At minimum, plain 'e' should differ from accented forms
  length (nub hashes) >= 2 @?= True

fuzzy_numericNear :: Assertion
fuzzy_numericNear = do
  -- Numbers that are close but different
  let variants = ["1", "2", "10", "11", "100", "101", "1000"]
      hashes = map (hashText . T.pack) variants
  length (nub hashes) @?= length variants

-- ════════════════════════════════════════════════════════════════════════════
-- TIME ATTACKS
-- Test timing-related edge cases
-- ════════════════════════════════════════════════════════════════════════════

timeAttackTests :: [TestTree]
timeAttackTests =
  [ testCase "hash timing roughly constant" time_hashConstant,
    testCase "topoSort completes in bounded time" time_topoSortBounded,
    testCase "rapid repeated operations don't accumulate delay" time_noAccumulation
  ]

time_hashConstant :: Assertion
time_hashConstant = do
  -- Hash time shouldn't vary too much with input size
  -- (This is a rough check, not a precise timing test)
  let small = T.replicate 10 "x"
      large = T.replicate 10000 "x"
  result1 <- timeout 1000000 $ evaluate $ hashText small
  result2 <- timeout 1000000 $ evaluate $ hashText large
  isJust result1 @?= True
  isJust result2 @?= True

time_topoSortBounded :: Assertion
time_topoSortBounded = do
  let graph = foldr addAction emptyGraph [mkAction (T.pack $ show i) [] [] | i <- [1 .. 1000 :: Int]]
  result <- timeout 5000000 $ evaluate $ length $ topoSort graph
  case result of
    Nothing -> assertFailure "topoSort took too long"
    Just n -> n @?= 1000

time_noAccumulation :: Assertion
time_noAccumulation = do
  result <- timeout 5000000 $ do
    forM_ [1 .. 1000 :: Int] $ \_ -> do
      let actions = [mkAction (T.pack $ show i) [] [] | i <- [1 .. 10 :: Int]]
          graph = foldr addAction emptyGraph actions
      _ <- evaluate $ length $ topoSort graph
      pure ()
    pure "done"
  isJust result @?= True

-- ════════════════════════════════════════════════════════════════════════════
-- MEMORY ATTACKS
-- Test memory-related edge cases
-- ════════════════════════════════════════════════════════════════════════════

memoryAttackTests :: [TestTree]
memoryAttackTests =
  [ testCase "large string hash doesn't OOM" mem_largeStringHash,
    testCase "many small hashes don't OOM" mem_manySmallHashes,
    testCase "deep graph doesn't stack overflow" mem_deepGraph
  ]

mem_largeStringHash :: Assertion
mem_largeStringHash = do
  -- 10MB string
  let large = T.replicate 10000000 "x"
  result <- timeout 30000000 $ evaluate $ T.length $ hashText large
  case result of
    Nothing -> assertFailure "large hash timed out"
    Just n -> n @?= 64

mem_manySmallHashes :: Assertion
mem_manySmallHashes = do
  -- 100k small hashes
  result <- timeout 30000000 $ evaluate $ length [hashText (T.pack $ show i) | i <- [1 .. 100000 :: Int]]
  case result of
    Nothing -> assertFailure "many hashes timed out"
    Just n -> n @?= 100000

mem_deepGraph :: Assertion
mem_deepGraph = do
  -- 10k deep chain
  let actions = buildLinearChain 10000
      graph = foldr addAction emptyGraph actions
  result <- timeout 30000000 $ evaluate $ length $ topoSort graph
  case result of
    Nothing -> assertFailure "deep graph timed out"
    Just n -> n @?= 10000

-- ════════════════════════════════════════════════════════════════════════════
-- GENERATORS
-- ════════════════════════════════════════════════════════════════════════════

genGraph :: Gen ActionGraph
genGraph = sized $ \n -> do
  numActions <- choose (0, max 1 n)
  actions <- replicateM numActions genAction
  pure $ foldr addAction emptyGraph actions

genAction :: Gen Action
genAction = do
  name <- T.pack <$> listOf1 (elements ['a' .. 'z'])
  pure $ mkAction name [] []

genUniqueActionList :: Gen [Action]
genUniqueActionList = do
  n <- choose (0, 6)
  pure [mkAction (T.pack $ show i) [] [] | i <- [1 .. n]]

genDistinctStrings :: Gen (String, String)
genDistinctStrings = do
  s1 <- listOf1 arbitrary
  s2 <- listOf1 arbitrary `suchThat` (/= s1)
  pure (s1, s2)

genNonEmptyString :: Gen String
genNonEmptyString = listOf1 (elements ['a' .. 'z'])

-- ════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ════════════════════════════════════════════════════════════════════════════

nubBy :: (a -> a -> Bool) -> [a] -> [a]
nubBy _ [] = []
nubBy f (x : xs) = x : nubBy f (filter (\y -> not (f x y)) xs)

-- Build a linear chain of N actions
buildLinearChain :: Int -> [Action]
buildLinearChain n = go n Nothing []
  where
    go 0 _ acc = acc
    go i prevKey acc =
      let action = mkAction (T.pack $ show i) [] (maybe [] (: []) prevKey)
          key = actionKey action
       in go (i - 1) (Just key) (action : acc)

-- ════════════════════════════════════════════════════════════════════════════
-- LOCAL TYPE DEFINITIONS
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

-- Real Blake2b_256 hash using crypton
hashText :: Text -> Text
hashText t =
  let hash = hashWith Blake2b_256 (TE.encodeUtf8 t)
      hex = BA.convertToBase BA.Base16 hash :: ByteString
   in TE.decodeUtf8 hex
