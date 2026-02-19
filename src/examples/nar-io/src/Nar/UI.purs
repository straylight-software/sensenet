-- | Nar.io UI Components
-- | Minimal component library for the nar.io aesthetic
module Nar.UI where

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
container className = HH.div [ cls [ "max-w-[1100px] mx-auto px-6", className ] ]

-- | Section wrapper
section :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
section className = HH.section [ cls [ className ] ]

-- ============================================================
-- TYPOGRAPHY
-- ============================================================

-- | Section header
sectionHeader :: forall w i. String -> HH.HTML w i
sectionHeader title =
  HH.h2
    [ cls [ "text-primary text-sm font-medium mb-6 uppercase tracking-wider" ] ]
    [ HH.text title ]

-- | Primary heading
heading :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
heading className = HH.h1 [ cls [ "text-text text-4xl font-bold", className ] ]

-- | Secondary heading
heading2 :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
heading2 className = HH.h2 [ cls [ "text-text text-2xl font-semibold", className ] ]

-- | Body text
text :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
text className = HH.p [ cls [ "text-muted-foreground", className ] ]

-- | Accent text with highlight
accent :: forall w i. String -> HH.HTML w i
accent content =
  HH.span
    [ cls [ "text-primary font-medium" ] ]
    [ HH.text content ]

-- ============================================================
-- BUTTONS
-- ============================================================

-- | Primary button
primaryButton :: forall w i. String -> String -> HH.HTML w i
primaryButton href label =
  HH.a
    [ HP.href href
    , cls [ "inline-flex items-center justify-center px-6 py-3 bg-primary text-background font-medium rounded-md hover:bg-primary/90 transition-colors" ]
    ]
    [ HH.text label ]

-- | Secondary button
secondaryButton :: forall w i. String -> String -> HH.HTML w i
secondaryButton href label =
  HH.a
    [ HP.href href
    , cls [ "inline-flex items-center justify-center px-6 py-3 border border-border text-text font-medium rounded-md hover:bg-card transition-colors" ]
    ]
    [ HH.text label ]

-- ============================================================
-- CODE BLOCKS
-- ============================================================

-- | Terminal-style code block
codeBlock :: forall w i. Array (HH.HTML w i) -> HH.HTML w i
codeBlock children =
  HH.pre
    [ cls [ "bg-card border border-border rounded-lg p-4 overflow-x-auto text-sm font-mono" ] ]
    children

-- | Inline code
inlineCode :: forall w i. String -> HH.HTML w i
inlineCode content =
  HH.code
    [ cls [ "bg-card px-1.5 py-0.5 rounded text-sm font-mono text-text" ] ]
    [ HH.text content ]

-- | Code line with prompt
codeLine :: forall w i. String -> String -> HH.HTML w i
codeLine prompt content =
  HH.div_
    [ HH.span [ cls [ "text-muted-foreground" ] ] [ HH.text prompt ]
    , HH.span [ cls [ "text-text" ] ] [ HH.text content ]
    ]

-- ============================================================
-- CARDS
-- ============================================================

-- | Feature card
featureCard :: forall w i. String -> String -> String -> HH.HTML w i
featureCard icon title description =
  HH.div
    [ cls [ "p-6 bg-card border border-border rounded-lg" ] ]
    [ HH.div
        [ cls [ "text-3xl mb-4" ] ]
        [ HH.text icon ]
    , HH.h3
        [ cls [ "text-text text-lg font-semibold mb-2" ] ]
        [ HH.text title ]
    , HH.p
        [ cls [ "text-muted-foreground text-sm" ] ]
        [ HH.text description ]
    ]

-- | Pricing card
pricingCard :: forall w i. 
  { name :: String
  , price :: String
  , period :: String
  , description :: String
  , features :: Array String
  , cta :: String
  , ctaHref :: String
  , highlighted :: Boolean
  } -> HH.HTML w i
pricingCard opts =
  HH.div
    [ cls [ "p-6 rounded-lg flex flex-col"
          , if opts.highlighted 
              then "bg-primary/10 border-2 border-primary" 
              else "bg-card border border-border"
          ]
    ]
    [ HH.h3
        [ cls [ "text-text text-xl font-semibold" ] ]
        [ HH.text opts.name ]
    , HH.div
        [ cls [ "mt-4 mb-2" ] ]
        [ HH.span [ cls [ "text-text text-4xl font-bold" ] ] [ HH.text opts.price ]
        , HH.span [ cls [ "text-muted-foreground text-sm ml-1" ] ] [ HH.text opts.period ]
        ]
    , HH.p
        [ cls [ "text-muted-foreground text-sm mb-6" ] ]
        [ HH.text opts.description ]
    , HH.ul
        [ cls [ "flex-1 space-y-3 mb-6" ] ]
        (map featureItem opts.features)
    , HH.a
        [ HP.href opts.ctaHref
        , cls [ "block text-center py-3 rounded-md font-medium transition-colors"
              , if opts.highlighted
                  then "bg-primary text-background hover:bg-primary/90"
                  else "border border-border text-text hover:bg-card"
              ]
        ]
        [ HH.text opts.cta ]
    ]

featureItem :: forall w i. String -> HH.HTML w i
featureItem feature =
  HH.li
    [ cls [ "flex items-start gap-2 text-sm" ] ]
    [ HH.span [ cls [ "text-primary mt-0.5" ] ] [ HH.text "+" ]
    , HH.span [ cls [ "text-muted-foreground" ] ] [ HH.text feature ]
    ]

-- ============================================================
-- COMPARISON TABLE
-- ============================================================

-- | Comparison row
comparisonRow :: forall w i. String -> String -> String -> HH.HTML w i
comparisonRow feature us them =
  HH.tr
    [ cls [ "border-b border-border" ] ]
    [ HH.td [ cls [ "py-3 text-muted-foreground" ] ] [ HH.text feature ]
    , HH.td [ cls [ "py-3 text-text font-medium text-center" ] ] [ HH.text us ]
    , HH.td [ cls [ "py-3 text-muted-foreground text-center" ] ] [ HH.text them ]
    ]

-- ============================================================
-- LINKS
-- ============================================================

-- | Navigation link
navLink :: forall w i. String -> String -> HH.HTML w i
navLink href label =
  HH.a
    [ HP.href href
    , cls [ "text-muted-foreground text-sm hover:text-text transition-colors" ]
    ]
    [ HH.text label ]

-- | External link
externalLink :: forall w i. String -> String -> HH.HTML w i
externalLink href label =
  HH.a
    [ HP.href href
    , HP.target "_blank"
    , HP.rel "noopener noreferrer"
    , cls [ "text-muted-foreground text-sm hover:text-text transition-colors" ]
    ]
    [ HH.text label ]

-- | Footer link
footerLink :: forall w i. String -> String -> HH.HTML w i
footerLink href label =
  HH.a
    [ HP.href href
    , cls [ "text-muted-foreground hover:text-text transition-colors" ]
    ]
    [ HH.text label ]

-- ============================================================
-- MODAL / DIALOG
-- ============================================================

-- | Modal overlay
modalOverlay :: forall w i. Array (HH.HTML w i) -> HH.HTML w i
modalOverlay children =
  HH.div
    [ cls [ "fixed inset-0 z-50 flex items-center justify-center bg-background/80 backdrop-blur-sm" ]
    , HH.attr (HH.AttrName "role") "dialog"
    , HH.attr (HH.AttrName "aria-modal") "true"
    ]
    children

-- | Modal content box
modalContent :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
modalContent className children =
  HH.div
    [ cls [ "bg-card border border-border rounded-lg shadow-lg p-6 max-w-md w-full mx-4 animate-in fade-in zoom-in-95", className ] ]
    children

-- | Modal header with title and close button
modalHeader :: forall w i. String -> HH.HTML w i
modalHeader title =
  HH.div
    [ cls [ "mb-4" ] ]
    [ HH.h2
        [ cls [ "text-lg font-semibold text-text" ] ]
        [ HH.text title ]
    ]

-- | Modal footer (for action buttons)
modalFooter :: forall w i. Array (HH.HTML w i) -> HH.HTML w i
modalFooter children =
  HH.div
    [ cls [ "flex justify-end gap-3 mt-6 pt-4 border-t border-border" ] ]
    children

-- ============================================================
-- FORM ELEMENTS
-- ============================================================

-- | Label for form fields
inputLabel :: forall w i. String -> HH.HTML w i
inputLabel labelText =
  HH.label
    [ cls [ "block text-sm font-medium text-text mb-1.5" ] ]
    [ HH.text labelText ]

-- | Form field with label
formField :: forall w i. String -> HH.HTML w i -> HH.HTML w i
formField labelText inputEl =
  HH.div
    [ cls [ "space-y-1.5" ] ]
    [ inputLabel labelText
    , inputEl
    ]
