{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE StrictData #-}

-- | DhallFast.Core - Cache-optimized Dhall AST
--
-- Design principles:
--   1. Fit common nodes in single cache line (64 bytes)
--   2. Use de Bruijn indices (Int) instead of Text + Int
--   3. Unbox literals where possible
--   4. Use Vector for records (better cache locality than Map)
--
-- L2 cache optimization:
--   - AMD Zen4: 1MB L2 per core, 64-byte lines
--   - Goal: Keep hot working set under 512KB
--   - Expr node target: 24-32 bytes (vs ~80+ bytes in upstream Dhall)
module DhallFast.Core
  ( -- * Core expression type
    Expr (..),

    -- * Variables (de Bruijn)
    Var (..),
    pattern V,

    -- * Compact literals
    Lit (..),

    -- * Records as vectors
    Fields (..),
    emptyFields,
    singletonFields,
    insertField,
    lookupField,
    fieldsToList,
    fieldsFromList,
    fieldsFromSortedList,
    mergeFieldsPrefer,
    mergeFieldsCombine,

    -- * Interned strings
    Name,
    internName,
    nameText,

    -- * Constants and builtins
    Const (..),
    Builtin (..),
  )
where

import Control.DeepSeq (NFData (..))
import Control.Monad.ST (ST, runST)
import Data.ByteString.Short (ShortByteString)
import qualified Data.ByteString.Short as SBS
import qualified Data.HashMap.Strict as HM
import Data.Hashable (Hashable (..))
import Data.IORef
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import Data.Text.Short (ShortText)
import qualified Data.Text.Short as TS
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import Data.Word (Word64)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)

--------------------------------------------------------------------------------
-- Interned names (for field names, let bindings)
--------------------------------------------------------------------------------

-- | Interned string - small, hashable, cache-friendly
newtype Name = Name {unName :: ShortText}
  deriving stock (Eq, Ord, Show)
  deriving newtype (NFData, Hashable)

{-# NOINLINE nameTable #-}
nameTable :: IORef (HM.HashMap Text Name)
nameTable = unsafePerformIO $ newIORef HM.empty

-- | Intern a Text to a Name (thread-safe, idempotent)
internName :: Text -> Name
internName !t = unsafePerformIO $ do
  atomicModifyIORef' nameTable $ \tbl ->
    case HM.lookup t tbl of
      Just existing -> (tbl, existing)
      Nothing ->
        let !n = Name (TS.fromText t)
         in (HM.insert t n tbl, n)
{-# NOINLINE internName #-}

nameText :: Name -> Text
nameText (Name st) = TS.toText st
{-# INLINE nameText #-}

--------------------------------------------------------------------------------
-- De Bruijn variables
--------------------------------------------------------------------------------

-- | Variable as de Bruijn index
-- Unlike Dhall's (Text, Int), this is just an Int
-- Much better for L2: 8 bytes vs 32+ bytes
newtype Var = Var {varIndex :: Int}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (NFData, Hashable)

-- | Pattern synonym for compatibility
pattern V :: Int -> Var
pattern V i = Var i

{-# COMPLETE V #-}

--------------------------------------------------------------------------------
-- Compact literals
--------------------------------------------------------------------------------

-- | Unboxed literal values
data Lit
  = LitBool !Bool
  | LitNat {-# UNPACK #-} !Word64 -- Natural fits in Word64 for 99% of cases
  | LitInt {-# UNPACK #-} !Int64 -- Integer fits in Int64 for 99% of cases
  | LitDouble {-# UNPACK #-} !Double
  | LitText {-# UNPACK #-} !ShortText -- Short strings inline
  | LitTextLong !Text -- Long strings boxed
  | LitBytes {-# UNPACK #-} !ShortByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

instance Hashable Lit where
  hashWithSalt s (LitBool b) = hashWithSalt s (0 :: Int, b)
  hashWithSalt s (LitNat n) = hashWithSalt s (1 :: Int, n)
  hashWithSalt s (LitInt n) = hashWithSalt s (2 :: Int, n)
  hashWithSalt s (LitDouble d) = hashWithSalt s (3 :: Int, d)
  hashWithSalt s (LitText t) = hashWithSalt s (4 :: Int, TS.toText t)
  hashWithSalt s (LitTextLong t) = hashWithSalt s (5 :: Int, t)
  hashWithSalt s (LitBytes b) = hashWithSalt s (6 :: Int, SBS.unpack b)

--------------------------------------------------------------------------------
-- Fields (sorted vector for records)
--------------------------------------------------------------------------------

-- | Record fields as sorted Vector
-- O(log n) lookup via binary search, excellent cache locality
data Fields a = Fields
  { fieldPairs :: !(Vector (Name, a))
  }
  deriving stock (Eq, Show, Generic, Functor, Foldable, Traversable)
  deriving anyclass (NFData)

emptyFields :: Fields a
emptyFields = Fields V.empty
{-# INLINE emptyFields #-}

singletonFields :: Name -> a -> Fields a
singletonFields k v = Fields (V.singleton (k, v))
{-# INLINE singletonFields #-}

insertField :: Name -> a -> Fields a -> Fields a
insertField k v (Fields pairs) = Fields (V.fromList sorted)
  where
    sorted = sortOn fst ((k, v) : V.toList pairs)
{-# INLINE insertField #-}

-- | Binary search lookup O(log n)
lookupField :: Name -> Fields a -> Maybe a
lookupField !key (Fields pairs) = go 0 (V.length pairs - 1)
  where
    go !lo !hi
      | lo > hi = Nothing
      | otherwise =
          let !mid = lo + (hi - lo) `div` 2
              (!name, !val) = pairs V.! mid
           in case compare key name of
                LT -> go lo (mid - 1)
                GT -> go (mid + 1) hi
                EQ -> Just val
{-# INLINE lookupField #-}

fieldsToList :: Fields a -> [(Name, a)]
fieldsToList (Fields pairs) = V.toList pairs
{-# INLINE fieldsToList #-}

fieldsFromList :: [(Name, a)] -> Fields a
fieldsFromList xs = Fields (V.fromList (sortOn fst xs))
{-# INLINE fieldsFromList #-}

-- | Create Fields from an already-sorted list (O(n) - no sort needed)
fieldsFromSortedList :: [(Name, a)] -> Fields a
fieldsFromSortedList xs = Fields (V.fromList xs)
{-# INLINE fieldsFromSortedList #-}

-- | Merge two sorted field vectors with right-preference (for //)
-- O(n+m) using in-place mutable vector construction
mergeFieldsPrefer :: Fields a -> Fields a -> Fields a
mergeFieldsPrefer (Fields va) (Fields vb)
  | V.null va = Fields vb
  | V.null vb = Fields va
  | otherwise = Fields $ runST $ do
      let !na = V.length va
          !nb = V.length vb
      mv <- MV.new (na + nb)
      let go !i !j !k
            | i >= na = do
                -- Copy remaining from vb
                let !remaining = nb - j
                copySlice mv k vb j remaining
                return (k + remaining)
            | j >= nb = do
                -- Copy remaining from va
                let !remaining = na - i
                copySlice mv k va i remaining
                return (k + remaining)
            | otherwise = do
                let (!ka, !xa) = V.unsafeIndex va i
                    (!kb, !xb) = V.unsafeIndex vb j
                case compare ka kb of
                  LT -> do
                    MV.unsafeWrite mv k (ka, xa)
                    go (i + 1) j (k + 1)
                  GT -> do
                    MV.unsafeWrite mv k (kb, xb)
                    go i (j + 1) (k + 1)
                  EQ -> do
                    MV.unsafeWrite mv k (kb, xb) -- right wins
                    go (i + 1) (j + 1) (k + 1)
      finalLen <- go 0 0 0
      V.freeze (MV.take finalLen mv)
{-# INLINE mergeFieldsPrefer #-}

-- | Copy slice from immutable to mutable vector
copySlice :: MV.MVector s a -> Int -> Vector a -> Int -> Int -> ST s ()
copySlice mv dstOff src srcOff len = go 0
  where
    go !i
      | i >= len = return ()
      | otherwise = do
          MV.unsafeWrite mv (dstOff + i) (V.unsafeIndex src (srcOff + i))
          go (i + 1)
{-# INLINE copySlice #-}

-- | Merge two sorted field vectors with a combining function (for /\)
-- O(n+m) using in-place mutable vector construction
mergeFieldsCombine :: (a -> a -> a) -> Fields a -> Fields a -> Fields a
mergeFieldsCombine combine (Fields va) (Fields vb)
  | V.null va = Fields vb
  | V.null vb = Fields va
  | otherwise = Fields $ runST $ do
      let !na = V.length va
          !nb = V.length vb
      mv <- MV.new (na + nb)
      let go !i !j !k
            | i >= na = do
                let !remaining = nb - j
                copySlice mv k vb j remaining
                return (k + remaining)
            | j >= nb = do
                let !remaining = na - i
                copySlice mv k va i remaining
                return (k + remaining)
            | otherwise = do
                let (!ka, !xa) = V.unsafeIndex va i
                    (!kb, !xb) = V.unsafeIndex vb j
                case compare ka kb of
                  LT -> do
                    MV.unsafeWrite mv k (ka, xa)
                    go (i + 1) j (k + 1)
                  GT -> do
                    MV.unsafeWrite mv k (kb, xb)
                    go i (j + 1) (k + 1)
                  EQ -> do
                    MV.unsafeWrite mv k (ka, combine xa xb)
                    go (i + 1) (j + 1) (k + 1)
      finalLen <- go 0 0 0
      V.freeze (MV.take finalLen mv)
{-# INLINE mergeFieldsCombine #-}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

data Const = Type | Kind | Sort
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (NFData, Hashable)

--------------------------------------------------------------------------------
-- Built-in functions (compact enum)
--------------------------------------------------------------------------------

data Builtin
  = BNatural
  | BNaturalFold
  | BNaturalBuild
  | BNaturalIsZero
  | BNaturalEven
  | BNaturalOdd
  | BNaturalToInteger
  | BNaturalShow
  | BNaturalSubtract
  | BInteger
  | BIntegerClamp
  | BIntegerNegate
  | BIntegerShow
  | BIntegerToDouble
  | BDouble
  | BDoubleShow
  | BText
  | BTextShow
  | BTextReplace
  | BList
  | BListBuild
  | BListFold
  | BListLength
  | BListHead
  | BListLast
  | BListIndexed
  | BListReverse
  | BOptional
  | BNone
  | BSome
  | BBool
  | BBytes
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (NFData, Hashable)

--------------------------------------------------------------------------------
-- Core expression type
--------------------------------------------------------------------------------

-- | Core expression - target 32 bytes per node
data Expr
  = EConst !Const
  | EVar {-# UNPACK #-} !Var
  | ELam !Name !Expr !Expr -- name, type, body
  | EPi !Name !Expr !Expr -- name, domain, codomain
  | EApp !Expr !Expr
  | ELet !Name !(Maybe Expr) !Expr !Expr -- name, annotation, value, body
  | ELit !Lit
  | EBoolAnd !Expr !Expr
  | EBoolOr !Expr !Expr
  | EBoolIf !Expr !Expr !Expr
  | ENatPlus !Expr !Expr
  | ENatTimes !Expr !Expr
  | ETextAppend !Expr !Expr
  | EList !(Maybe Expr) !(Seq Expr) -- element type, elements (Seq for lazy eval)
  | EListAppend !Expr !Expr
  | ERecord !(Fields Expr)
  | ERecordLit !(Fields Expr)
  | EUnion !(Fields (Maybe Expr))
  | ECombine !Expr !Expr
  | ECombineTypes !Expr !Expr
  | EPrefer !Expr !Expr
  | EMerge !Expr !Expr !(Maybe Expr)
  | EToMap !Expr !(Maybe Expr)
  | EField !Expr !Name
  | EProject !Expr ![Name]
  | EAssert !Expr
  | EEquivalent !Expr !Expr
  | EWith !Expr ![Name] !Expr
  | EBuiltin !Builtin
  | EAnnot !Expr !Expr
  deriving stock (Show, Generic)
  deriving anyclass (NFData)
