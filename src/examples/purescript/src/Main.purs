-- | Halogen TODO App Entry Point
module Main where

import Prelude

import Effect (Effect)
import Effect.Aff (launchAff_)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.Aff as HA
import Halogen.VDom.Driver (runUI)

import Component.Todo as Todo

main :: Effect Unit
main = launchAff_ do
  HA.awaitLoad
  body <- HA.awaitBody
  void $ runUI Todo.component unit body
