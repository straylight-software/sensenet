-- | Straylight UI Components for Halogen
-- | Minimal component library for the straylight aesthetic
module Straylight.UI where

import Prelude

import Data.Array (filter, intercalate)
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

-- ============================================================
-- UTILITY
-- ============================================================

-- | Combine class names, filtering empty strings
classes :: Array String -> String
classes = intercalate " " <<< filter (_ /= "")

-- | Create HP.class_ from array of class strings
cls :: forall r i. Array String -> HH.IProp (class :: String | r) i
cls = HP.class_ <<< HH.ClassName <<< classes

-- ============================================================
-- SVG NAMESPACE
-- ============================================================

svgNS :: HH.Namespace
svgNS = HH.Namespace "http://www.w3.org/2000/svg"

-- ============================================================
-- LAYOUT COMPONENTS
-- ============================================================

-- | Flex container
flex :: forall w i. 
  { direction :: String
  , gap :: String
  , align :: String
  , justify :: String
  , className :: String
  } -> 
  Array (HH.HTML w i) -> 
  HH.HTML w i
flex opts children =
  HH.div
    [ cls 
        [ "flex"
        , case opts.direction of
            "column" -> "flex-col"
            _ -> "flex-row"
        , opts.gap
        , case opts.align of
            "center" -> "items-center"
            "end" -> "items-end"
            "stretch" -> "items-stretch"
            _ -> "items-start"
        , case opts.justify of
            "center" -> "justify-center"
            "end" -> "justify-end"
            "between" -> "justify-between"
            _ -> "justify-start"
        , opts.className
        ]
    ]
    children

-- | Simple flex row
row :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
row gap = flex { direction: "row", gap, align: "center", justify: "start", className: "" }

-- | Simple flex column
column :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
column gap = flex { direction: "column", gap, align: "start", justify: "start", className: "" }

-- | Box container
box :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
box className = HH.div [ cls [ className ] ]

-- | Max-width container
container :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
container className = HH.div [ cls [ "max-w-[900px] mx-auto px-8", className ] ]

-- | Section wrapper
section :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
section className = HH.section [ cls [ className ] ]

-- ============================================================
-- TYPOGRAPHY
-- ============================================================

-- | Section header with code formatting
sectionHeader :: forall w i. String -> HH.HTML w i
sectionHeader title =
  HH.h2
    [ cls [ "text-primary text-[0.85rem] font-medium mb-6 lowercase section-header" ] ]
    [ HH.code_ [ HH.text $ "// " <> title ] ]

-- | Primary heading
heading :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
heading className = HH.h1 [ cls [ "text-text text-[2rem] font-medium", className ] ]

-- | Body text
text :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
text className = HH.p [ cls [ "text-muted-foreground", className ] ]

-- | Italic quote text
quote :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
quote className = HH.p [ cls [ "italic text-base02", className ] ]

-- | Keyword span with glow animation
keyword :: forall w i. Int -> String -> HH.HTML w i
keyword n content =
  HH.span
    [ cls [ "text-text keyword keyword-" <> show n ] ]
    [ HH.text content ]

-- ============================================================
-- DECORATIVE ELEMENTS
-- ============================================================

-- | Horizontal rail with shimmer effect
rail :: forall w i. HH.HTML w i
rail = HH.div [ cls [ "h-[3px] rail" ] ] []

-- | Status indicator
statusIndicator :: forall w i. String -> HH.HTML w i
statusIndicator label =
  HH.div
    [ cls [ "flex items-center gap-2 text-xs text-muted-foreground" ] ]
    [ HH.span [ cls [ "w-2 h-2 bg-status inline-block status-pulse" ] ] []
    , HH.text label
    ]

-- | Scanline overlay
scanlineOverlay :: forall w i. HH.HTML w i
scanlineOverlay = HH.div [ cls [ "scanline-overlay" ] ] []

-- ============================================================
-- LINKS
-- ============================================================

-- | Navigation link with trace animation
navLink :: forall w i. String -> String -> HH.HTML w i
navLink href label =
  HH.a
    [ HP.href href
    , cls [ "text-muted-foreground text-[13px] hover:text-text transition-colors link-trace" ]
    ]
    [ HH.text label ]

-- | External link
externalLink :: forall w i. String -> String -> HH.HTML w i
externalLink href label =
  HH.a
    [ HP.href href
    , HP.target "_blank"
    , HP.rel "noopener noreferrer"
    , cls [ "text-muted-foreground text-[13px] hover:text-text transition-colors link-trace" ]
    ]
    [ HH.text label ]

-- | Footer link with float animation
footerLink :: forall w i. String -> String -> HH.HTML w i
footerLink href label =
  HH.a
    [ HP.href href
    , HP.target "_blank"
    , HP.rel "noopener noreferrer"
    , cls [ "text-muted-foreground hover:text-text transition-colors ml-6 link-float inline-block" ]
    ]
    [ HH.text label ]

-- ============================================================
-- CODE BLOCKS
-- ============================================================

-- | Terminal-style code block
codeBlock :: forall w i. Array (HH.HTML w i) -> HH.HTML w i
codeBlock children =
  HH.pre
    [ cls [ "bg-card p-4 overflow-x-auto text-[0.9rem] leading-relaxed" ] ]
    children

-- | Inline code
inlineCode :: forall w i. String -> HH.HTML w i
inlineCode content =
  HH.code
    [ cls [ "text-muted-foreground" ] ]
    [ HH.text content ]

-- | Block cursor (blinking)
blockCursor :: forall w i. HH.HTML w i
blockCursor = HH.span [ cls [ "block-cursor" ] ] []
