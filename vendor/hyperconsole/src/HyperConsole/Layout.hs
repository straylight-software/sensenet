{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

-- | Flexbox-like layout engine
--
-- Provides constraint-based layout solving similar to CSS Flexbox.
-- Main features:
--   - Direction (horizontal/vertical)
--   - Alignment (main axis and cross axis)
--   - Size constraints (fixed, percentage, fill)
--   - Gap between items
module HyperConsole.Layout
  ( -- * Dimensions
    Dimensions (..),
    Position (..),

    -- * Direction
    Direction (..),

    -- * Alignment
    Alignment (..),

    -- * Constraints
    Constraint (..),

    -- * Layout specification
    Layout (..),
    defaultLayout,
    vstack,
    hstack,

    -- * Layout solving
    solve,
  )
where

-- | Terminal dimensions in cells
data Dimensions = Dimensions
  { width :: !Int,
    height :: !Int
  }
  deriving stock (Eq, Show, Ord)

-- | Position in terminal (0-indexed)
data Position = Position
  { row :: !Int,
    col :: !Int
  }
  deriving stock (Eq, Show, Ord)

-- | Layout direction
data Direction
  = Horizontal
  | Vertical
  deriving stock (Eq, Show)

-- | Alignment within a container
data Alignment
  = -- | Align to start (top/left)
    Start
  | -- | Center
    Center
  | -- | Align to end (bottom/right)
    End
  | -- | Stretch to fill
    Stretch
  | -- | Distribute space between items
    SpaceBetween
  | -- | Distribute space around items
    SpaceAround
  | -- | Equal space between all items
    SpaceEvenly
  deriving stock (Eq, Show)

-- | Size constraint for layout
data Constraint
  = -- | Exact size in cells
    Exact !Int
  | -- | Minimum size
    Min !Int
  | -- | Maximum size
    Max !Int
  | -- | Range (min, max)
    Between !Int !Int
  | -- | Percentage of parent (0-100)
    Percent !Int
  | -- | Fill remaining space with weight
    Fill !Int
  | -- | Fit to content (requires measurement)
    Fit
  deriving stock (Eq, Show)

-- | Layout specification
data Layout = Layout
  { layoutDirection :: !Direction,
    layoutMainAlign :: !Alignment,
    layoutCrossAlign :: !Alignment,
    layoutGap :: !Int,
    layoutPadding :: !(Int, Int, Int, Int) -- top, right, bottom, left
  }
  deriving stock (Eq, Show)

-- | Default layout (horizontal, start-aligned, no gap, no padding)
defaultLayout :: Layout
defaultLayout =
  Layout
    { layoutDirection = Horizontal,
      layoutMainAlign = Start,
      layoutCrossAlign = Stretch,
      layoutGap = 0,
      layoutPadding = (0, 0, 0, 0)
    }

-- | Vertical stack layout
vstack :: Layout
vstack = defaultLayout {layoutDirection = Vertical}

-- | Horizontal stack layout
hstack :: Layout
hstack = defaultLayout {layoutDirection = Horizontal}

-- | Solve layout constraints and return allocated dimensions for each child
--
-- This is a simplified flexbox algorithm:
-- 1. Allocate fixed sizes
-- 2. Calculate remaining space
-- 3. Distribute remaining space to flexible items
solve :: Layout -> Dimensions -> [Constraint] -> [Dimensions]
solve Layout {..} Dimensions {..} constraints
  | null constraints = []
  | otherwise =
      let (pTop, pRight, pBottom, pLeft) = layoutPadding
          availWidth = max 0 (width - pLeft - pRight)
          availHeight = max 0 (height - pTop - pBottom)

          -- Main axis size
          mainSize = case layoutDirection of
            Horizontal -> availWidth
            Vertical -> availHeight

          -- Cross axis size
          crossSize = case layoutDirection of
            Horizontal -> availHeight
            Vertical -> availWidth

          -- Total gap space
          numGaps = max 0 (length constraints - 1)
          totalGap = layoutGap * numGaps
          availMain = max 0 (mainSize - totalGap)

          -- First pass: classify constraints
          classified = [(i, classifyConstraint availMain c) | (i, c) <- zip ([0 ..] :: [Int]) constraints]

          -- Second pass: sum fixed allocations and flex weights
          (fixedSum, flexSum) = foldl' accum (0, 0) classified
            where
              accum (fixed, flex) (_, (mFixed, weight)) =
                (fixed + maybe 0 id mFixed, flex + weight)

          -- Remaining space for flex items
          remaining = max 0 (availMain - fixedSum)

          -- Third pass: allocate sizes
          allocated = allocate classified
            where
              allocate [] = []
              allocate ((_, (mFixed, weight)) : rest) =
                let mainAlloc = case mFixed of
                      Just fixed -> fixed
                      Nothing ->
                        if flexSum > 0
                          then remaining * weight `div` flexSum
                          else 0
                    dims = case layoutDirection of
                      Horizontal -> Dimensions mainAlloc crossSize
                      Vertical -> Dimensions crossSize mainAlloc
                 in dims : allocate rest
       in allocated

-- | Classify a constraint into (maybe fixed size, flex weight)
classifyConstraint :: Int -> Constraint -> (Maybe Int, Int)
classifyConstraint avail c = case c of
  Exact n -> (Just (clamp n), 0)
  Min n -> (Just (clamp n), 0) -- Min acts as fixed minimum
  Max _n -> (Nothing, 1) -- Max is flexible up to n (simplified)
  Between lo _hi -> (Just (clamp lo), 0) -- Use minimum
  Percent p -> (Just (clamp (avail * p `div` 100)), 0)
  Fill w -> (Nothing, max 1 w)
  Fit -> (Nothing, 0) -- Fit needs measurement, treat as 0
  where
    clamp n = max 0 (min avail n)
