-- | Aria Hider Utilities
-- |
-- | When a modal dialog opens, we need to hide all sibling content from
-- | screen readers by setting aria-hidden="true" on them. This module
-- | provides utilities to do that and restore the original state on close.
module Radix.Pure.AriaHider
  ( AriaHiderState
  , hideOthers
  , restoreOthers
  ) where

import Prelude

import Effect (Effect)
import Web.HTML.HTMLElement (HTMLElement)

-- | State tracking which elements were hidden and their original aria-hidden values
foreign import data AriaHiderState :: Type

-- | Hide all siblings of the given element from screen readers.
-- | Returns state needed to restore the original aria-hidden values.
-- |
-- | This works by:
-- | 1. Walking up to find the body
-- | 2. For each sibling of ancestors (except the path to our element):
-- |    - Store the original aria-hidden value
-- |    - Set aria-hidden="true"
foreign import hideOthers :: HTMLElement -> Effect AriaHiderState

-- | Restore the original aria-hidden values for all elements we modified.
foreign import restoreOthers :: AriaHiderState -> Effect Unit
