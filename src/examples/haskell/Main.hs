-- | Main module that uses the Greet library
module Main where

import Greet (greet)

main :: IO ()
main = putStrLn (greet "World")
