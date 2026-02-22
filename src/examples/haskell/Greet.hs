-- | A simple greeting library
module Greet (greet) where

greet :: String -> String
greet name = "Hello, " ++ name ++ "!"
