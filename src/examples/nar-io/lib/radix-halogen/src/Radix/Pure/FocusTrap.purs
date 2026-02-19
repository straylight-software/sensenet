-- | Focus Trapping Utilities
-- |
-- | Pure PureScript implementation of focus management for modal dialogs.
-- | Handles:
-- | - Finding tabbable elements
-- | - Trapping Tab key within container
-- | - Focus guards at document edges
-- | - Focus restoration
module Radix.Pure.FocusTrap
  ( FocusScope
  , createFocusScope
  , destroyFocusScope
  , trapFocus
  , releaseFocus
  , handleTabKey
  , focusFirst
  , focusLast
  , getTabbableElements
  ) where

import Prelude

import Data.Array as Array
import Data.Nullable (Nullable, toMaybe)
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Effect (Effect)
import Web.DOM.Node as Node
import Web.DOM.NodeList as NodeList
import Web.DOM.ParentNode as ParentNode
import Web.HTML as HTML
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.HTMLElement as HTMLElement
import Web.HTML.Window as Window
import Web.UIEvent.KeyboardEvent as KE

-- | A focus scope manages focus trapping for a container element
type FocusScope =
  { container :: HTMLElement.HTMLElement
  , previousActiveElement :: Maybe HTMLElement.HTMLElement
  , startGuard :: Maybe HTMLElement.HTMLElement
  , endGuard :: Maybe HTMLElement.HTMLElement
  }

-- | Create a focus scope for a container
createFocusScope :: HTMLElement.HTMLElement -> Effect FocusScope
createFocusScope container = do
  -- Store currently focused element
  doc <- HTML.window >>= Window.document
  prevActive <- HTMLDocument.activeElement doc
  
  pure
    { container
    , previousActiveElement: prevActive
    , startGuard: Nothing
    , endGuard: Nothing
    }

-- | Destroy a focus scope, restoring focus
destroyFocusScope :: FocusScope -> Effect Unit
destroyFocusScope scope = do
  -- Remove focus guards if they exist
  removeGuard scope.startGuard
  removeGuard scope.endGuard
  
  -- Restore focus to previous element
  case scope.previousActiveElement of
    Just el -> HTMLElement.focus el
    Nothing -> pure unit
  where
  removeGuard :: Maybe HTMLElement.HTMLElement -> Effect Unit
  removeGuard = case _ of
    Just el -> do
      mParent <- Node.parentNode (HTMLElement.toNode el)
      case mParent of
        Just parent -> Node.removeChild (HTMLElement.toNode el) parent *> pure unit
        Nothing -> pure unit
    Nothing -> pure unit

-- | Trap focus within the scope
trapFocus :: FocusScope -> Effect Unit
trapFocus scope = do
  -- Focus the first tabbable element (or container)
  tabbable <- getTabbableElements scope.container
  case Array.head tabbable of
    Just first -> HTMLElement.focus first
    Nothing -> HTMLElement.focus scope.container

-- | Release focus trap
releaseFocus :: FocusScope -> Effect Unit
releaseFocus = destroyFocusScope

-- | Handle Tab key to loop focus within container
-- | Returns true if the event was handled
handleTabKey :: FocusScope -> KE.KeyboardEvent -> Effect Boolean
handleTabKey scope ke = do
  if KE.key ke /= "Tab" then pure false
  else do
    tabbable <- getTabbableElements scope.container
    
    if Array.null tabbable then pure false
    else do
      doc <- HTML.window >>= Window.document
      mActive <- HTMLDocument.activeElement doc
      
      let
        first = Array.head tabbable
        last = Array.last tabbable
        isShift = KE.shiftKey ke
        
      -- Find current index (using referential equality)
      let mIndex = mActive >>= \active -> 
            Array.findIndex (\el -> refEq (HTMLElement.toNode el) (HTMLElement.toNode active)) tabbable
      
      case mIndex, isShift of
        -- At first element, Shift+Tab -> go to last
        Just 0, true -> do
          case last of
            Just el -> HTMLElement.focus el
            Nothing -> pure unit
          pure true
        
        -- At last element, Tab -> go to first
        Just idx, false | idx == Array.length tabbable - 1 -> do
          case first of
            Just el -> HTMLElement.focus el
            Nothing -> pure unit
          pure true
        
        -- Otherwise, let default behavior happen
        _, _ -> pure false

-- | Focus the first tabbable element
focusFirst :: FocusScope -> Effect Unit
focusFirst scope = do
  tabbable <- getTabbableElements scope.container
  case Array.head tabbable of
    Just el -> HTMLElement.focus el
    Nothing -> HTMLElement.focus scope.container

-- | Focus the last tabbable element
focusLast :: FocusScope -> Effect Unit
focusLast scope = do
  tabbable <- getTabbableElements scope.container
  case Array.last tabbable of
    Just el -> HTMLElement.focus el
    Nothing -> HTMLElement.focus scope.container

-- | Get all tabbable elements within a container
-- | Tabbable elements are:
-- | - Have tabindex >= 0
-- | - Not disabled
-- | - Not hidden
-- | - Visible (not display:none)
getTabbableElements :: HTMLElement.HTMLElement -> Effect (Array HTMLElement.HTMLElement)
getTabbableElements container = do
  -- Query for potentially tabbable elements
  let selector = "a[href], button:not([disabled]), input:not([disabled]):not([type=hidden]), " <>
                 "select:not([disabled]), textarea:not([disabled]), " <>
                 "[tabindex]:not([tabindex=\"-1\"]):not([disabled])"
  
  nodeList <- ParentNode.querySelectorAll 
    (ParentNode.QuerySelector selector) 
    (HTMLElement.toParentNode container)
  
  nodes <- NodeList.toArray nodeList
  
  -- Convert to HTMLElements and filter for visibility
  elements <- traverse (pure <<< elementToHTMLElement) nodes
  filterVisible (Array.catMaybes elements)

-- | Filter for visible elements only
filterVisible :: Array HTMLElement.HTMLElement -> Effect (Array HTMLElement.HTMLElement)
filterVisible elements = do
  results <- traverse checkVisible elements
  pure $ Array.catMaybes results
  where
  checkVisible :: HTMLElement.HTMLElement -> Effect (Maybe HTMLElement.HTMLElement)
  checkVisible el = do
    visible <- isVisible el
    pure $ if visible then Just el else Nothing

-- | Check if an element is visible
foreign import isVisible :: HTMLElement.HTMLElement -> Effect Boolean

-- | Convert Element to HTMLElement (unsafe but necessary)
-- Returns null if not an HTMLElement
foreign import elementToHTMLElementImpl :: Node.Node -> Nullable HTMLElement.HTMLElement

elementToHTMLElement :: Node.Node -> Maybe HTMLElement.HTMLElement
elementToHTMLElement = toMaybe <<< elementToHTMLElementImpl

-- | Referential equality for Nodes (no Eq instance available)
foreign import refEq :: forall a. a -> a -> Boolean
