-- | Lean 4 Syntax Highlighting
module Straylight.Pages.Lean.Highlight where

import Prelude

import Data.Array as Array
import Data.String as String
import Data.String.Pattern (Pattern(..))
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

-- ============================================================
-- COLORS (ono-sendai theme)
-- ============================================================

-- base05 text
colorText :: String
colorText = "#b6e3ff"

-- base0D blue - keywords
colorKeyword :: String
colorKeyword = "#54aeff"

-- base0B green - strings  
colorString :: String
colorString = "#7ee787"

-- base04 comments
colorComment :: String
colorComment = "#596775"

-- base0E purple - types
colorType :: String
colorType = "#d2a8ff"

-- base09 orange - numbers
colorNumber :: String  
colorNumber = "#f0883e"

-- base0A yellow - theorems/definitions
colorDef :: String
colorDef = "#d29922"

-- ============================================================
-- HIGHLIGHTING
-- ============================================================

cls :: forall r i. Array String -> HP.IProp ( class :: String | r ) i
cls classes = HP.class_ (HH.ClassName (String.joinWith " " classes))

highlightLean :: forall w i. String -> Array (HH.HTML w i)
highlightLean content = 
  Array.intercalate [HH.text "\n"] (map highlightLine (String.split (Pattern "\n") content))

highlightLine :: forall w i. String -> Array (HH.HTML w i)
highlightLine line
  -- Documentation comments (/-! ... -/)
  | isDocComment line = 
      [HH.span [HP.style $ "color:" <> colorComment] [HH.text line]]
  
  -- Regular comments (-- ...)
  | isComment line =
      [HH.span [HP.style $ "color:" <> colorComment] [HH.text line]]
  
  -- Otherwise tokenize
  | otherwise = highlightTokens line

isDocComment :: String -> Boolean
isDocComment s = 
  let trimmed = String.trim s
  in String.take 3 trimmed == "/-!" || 
     String.take 2 trimmed == "-/" ||
     String.take 1 trimmed == "━" ||
     String.take 2 trimmed == "//" ||
     (String.length trimmed > 0 && String.take 1 trimmed == "—")

isComment :: String -> Boolean
isComment s = 
  let trimmed = String.trim s
  in String.take 2 trimmed == "--"

highlightTokens :: forall w i. String -> Array (HH.HTML w i)
highlightTokens line = [highlightedSpan line]

highlightedSpan :: forall w i. String -> HH.HTML w i
highlightedSpan line = HH.span_ (tokenize line)

-- Simple tokenizer - splits on spaces and highlights known tokens
tokenize :: forall w i. String -> Array (HH.HTML w i)
tokenize "" = []
tokenize line = go line []
  where
  go :: String -> Array (HH.HTML w i) -> Array (HH.HTML w i)
  go "" acc = acc
  go s acc = 
    let result = matchToken s
    in go result.rest (acc <> [result.html])

type TokenResult w i = { html :: HH.HTML w i, rest :: String }

matchToken :: forall w i. String -> TokenResult w i
matchToken s
  -- String literal
  | String.take 1 s == "\"" = matchString s
  
  -- Comment to end of line
  | String.take 2 s == "--" = 
      { html: HH.span [HP.style $ "color:" <> colorComment] [HH.text s]
      , rest: "" 
      }
  
  -- Otherwise match word or char
  | otherwise = matchWord s

matchString :: forall w i. String -> TokenResult w i
matchString s =
  let rest = String.drop 1 s
      endIdx = findEndQuote rest 0
      str = String.take (endIdx + 2) s
      remaining = String.drop (endIdx + 2) s
  in { html: HH.span [HP.style $ "color:" <> colorString] [HH.text str]
     , rest: remaining
     }

findEndQuote :: String -> Int -> Int
findEndQuote s idx
  | idx >= String.length s = idx
  | String.take 1 (String.drop idx s) == "\"" = idx
  | String.take 1 (String.drop idx s) == "\\" = findEndQuote s (idx + 2)
  | otherwise = findEndQuote s (idx + 1)

matchWord :: forall w i. String -> TokenResult w i
matchWord s =
  let wordEnd = findWordEnd s 0
      word = String.take wordEnd s
      remaining = String.drop wordEnd s
      html = colorizeWord word
  in { html, rest: remaining }

findWordEnd :: String -> Int -> Int
findWordEnd s idx
  | idx >= String.length s = idx
  | isWordBreak (String.take 1 (String.drop idx s)) = 
      if idx == 0 then 1 else idx
  | otherwise = findWordEnd s (idx + 1)

isWordBreak :: String -> Boolean
isWordBreak c = c == " " || c == "(" || c == ")" || c == "[" || c == "]" || 
                c == "{" || c == "}" || c == ":" || c == "," || c == "\n" ||
                c == "⟨" || c == "⟩" || c == "→" || c == "←" || c == "↔" ||
                c == "∧" || c == "∨" || c == "¬" || c == "∀" || c == "∃" ||
                c == "=" || c == "<" || c == ">" || c == "+" || c == "-" ||
                c == "*" || c == "/" || c == "|" || c == "·"

colorizeWord :: forall w i. String -> HH.HTML w i
colorizeWord word
  -- Keywords
  | isKeyword word = 
      HH.span [HP.style $ "color:" <> colorKeyword <> ";font-weight:600"] [HH.text word]
  
  -- Definition keywords
  | isDefKeyword word =
      HH.span [HP.style $ "color:" <> colorDef <> ";font-weight:600"] [HH.text word]
  
  -- Types (capitalized)
  | isType word =
      HH.span [HP.style $ "color:" <> colorType] [HH.text word]
  
  -- Numbers
  | isNumber word =
      HH.span [HP.style $ "color:" <> colorNumber] [HH.text word]
  
  -- Default
  | otherwise = 
      HH.span [HP.style $ "color:" <> colorText] [HH.text word]

isKeyword :: String -> Boolean
isKeyword w = Array.elem w 
  [ "import", "where", "if", "then", "else", "let", "in", "do", "return"
  , "match", "with", "fun", "by", "have", "show", "from", "calc", "at"
  , "intro", "exact", "apply", "rw", "simp", "omega", "ring", "constructor"
  , "cases", "induction", "rcases", "obtain", "refine", "use", "ext"
  , "push_neg", "by_contra", "by_cases", "subst", "conv"
  ]

isDefKeyword :: String -> Boolean
isDefKeyword w = Array.elem w
  [ "def", "theorem", "lemma", "structure", "inductive", "class", "instance"
  , "namespace", "end", "section", "variable", "open", "export", "deriving"
  , "private", "protected", "partial", "unsafe", "noncomputable"
  ]

isType :: String -> Boolean
isType w = 
  let first = String.take 1 w
  in first >= "A" && first <= "Z" && String.length w > 0

isNumber :: String -> Boolean
isNumber w =
  let first = String.take 1 w
  in first >= "0" && first <= "9"
