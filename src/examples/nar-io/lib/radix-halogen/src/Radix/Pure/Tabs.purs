-- | Pure Tabs Implementation
-- |
-- | A tabs component implemented entirely in PureScript/Halogen,
-- | with NO React dependency. Implements the same behavior as Radix Tabs:
-- |
-- | - Controlled and uncontrolled modes
-- | - Keyboard navigation (Arrow keys, Home, End)
-- | - Automatic activation on focus (optional)
-- | - Proper ARIA attributes (role, aria-selected, aria-controls, etc.)
-- | - Horizontal and vertical orientations
module Radix.Pure.Tabs
  ( component
  , Query(..)
  , Input
  , Output(..)
  , Slot
  , Tab
  , Orientation(..)
  , ActivationMode(..)
  , defaultInput
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe)
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.HTML.Properties.ARIA as ARIA
import Web.Event.Event as Event
import Web.HTML as HTML
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.HTMLElement as HTMLElement
import Web.HTML.Window as Window
import Web.UIEvent.KeyboardEvent as KE

-- ═══════════════════════════════════════════════════════════════════════════════
-- TYPES
-- ═══════════════════════════════════════════════════════════════════════════════

-- | A single tab definition
type Tab =
  { value :: String      -- Unique identifier
  , label :: String      -- Display label
  , disabled :: Boolean  -- Whether the tab is disabled
  }

-- | Tabs input props
type Input =
  { tabs :: Array Tab                    -- Tab definitions
  , value :: Maybe String                -- Controlled value
  , defaultValue :: Maybe String         -- Default value (uncontrolled)
  , orientation :: Orientation           -- Horizontal or vertical
  , activationMode :: ActivationMode     -- Automatic or manual
  , loop :: Boolean                      -- Loop keyboard navigation
  }

data Orientation = Horizontal | Vertical

derive instance eqOrientation :: Eq Orientation

data ActivationMode = Automatic | Manual

derive instance eqActivationMode :: Eq ActivationMode

defaultInput :: Input
defaultInput =
  { tabs: []
  , value: Nothing
  , defaultValue: Nothing
  , orientation: Horizontal
  , activationMode: Automatic
  , loop: true
  }

-- | Output events
data Output
  = ValueChanged String

-- | Queries for external control
data Query a
  = SetValue String a
  | GetValue (String -> a)

-- | Internal state
type State =
  { selectedValue :: String
  , input :: Input
  , baseId :: String
  }

-- | Internal actions
data Action
  = Initialize
  | Receive Input
  | SelectTab String
  | HandleKeyDown Int KE.KeyboardEvent  -- Index of focused tab

-- | Slot type for parent components
type Slot id = H.Slot Query Output id

-- ═══════════════════════════════════════════════════════════════════════════════
-- COMPONENT
-- ═══════════════════════════════════════════════════════════════════════════════

component :: forall m. MonadAff m => H.Component Query Input Output m
component = H.mkComponent
  { initialState
  , render
  , eval: H.mkEval $ H.defaultEval
      { handleAction = handleAction
      , handleQuery = handleQuery
      , initialize = Just Initialize
      , receive = Just <<< Receive
      }
  }

initialState :: Input -> State
initialState input =
  { selectedValue: getInitialValue input
  , input
  , baseId: "tabs"  -- Should be unique
  }
  where
  getInitialValue :: Input -> String
  getInitialValue i = 
    case i.value of
      Just v -> v
      Nothing -> case i.defaultValue of
        Just v -> v
        Nothing -> case Array.head (Array.filter (not <<< _.disabled) i.tabs) of
          Just tab -> tab.value
          Nothing -> ""

-- ═══════════════════════════════════════════════════════════════════════════════
-- RENDER
-- ═══════════════════════════════════════════════════════════════════════════════

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div
    [ HP.class_ (HH.ClassName "tabs-root")
    , HP.attr (HH.AttrName "data-orientation") (orientationStr state.input.orientation)
    ]
    [ renderTabList state
    , renderTabPanels state
    ]

renderTabList :: forall m. State -> H.ComponentHTML Action () m
renderTabList state =
  HH.div
    [ HP.class_ (HH.ClassName "tabs-list")
    , HP.attr (HH.AttrName "role") "tablist"
    , HP.attr (HH.AttrName "aria-orientation") (orientationStr state.input.orientation)
    ]
    (Array.mapWithIndex (renderTab state) state.input.tabs)

renderTab :: forall m. State -> Int -> Tab -> H.ComponentHTML Action () m
renderTab state idx tab =
  let 
    isSelected = tab.value == state.selectedValue
    tabId = state.baseId <> "-tab-" <> tab.value
    panelId = state.baseId <> "-panel-" <> tab.value
  in
  HH.button
    [ HP.class_ (HH.ClassName "tabs-trigger")
    , HP.type_ HP.ButtonButton
    , HP.id tabId
    , HP.disabled tab.disabled
    , HP.tabIndex (if isSelected then 0 else (-1))
    , HP.attr (HH.AttrName "role") "tab"
    , ARIA.selected (show isSelected)
    , ARIA.controls panelId
    , HP.attr (HH.AttrName "data-state") (if isSelected then "active" else "inactive")
    , HP.attr (HH.AttrName "data-disabled") (if tab.disabled then "true" else "false")
    , HE.onClick \_ -> SelectTab tab.value
    , HE.onKeyDown (HandleKeyDown idx)
    ]
    [ HH.text tab.label ]

renderTabPanels :: forall m. State -> H.ComponentHTML Action () m
renderTabPanels state =
  HH.div
    [ HP.class_ (HH.ClassName "tabs-panels") ]
    (map (renderTabPanel state) state.input.tabs)

renderTabPanel :: forall m. State -> Tab -> H.ComponentHTML Action () m
renderTabPanel state tab =
  let
    isSelected = tab.value == state.selectedValue
    tabId = state.baseId <> "-tab-" <> tab.value
    panelId = state.baseId <> "-panel-" <> tab.value
  in
  if isSelected then
    HH.div
      [ HP.class_ (HH.ClassName "tabs-content")
      , HP.id panelId
      , HP.attr (HH.AttrName "role") "tabpanel"
      , HP.tabIndex 0
      , ARIA.labelledBy tabId
      , HP.attr (HH.AttrName "data-state") "active"
      ]
      [ HH.text $ "Content for " <> tab.label ]
  else
    HH.div
      [ HP.class_ (HH.ClassName "tabs-content")
      , HP.id panelId
      , HP.attr (HH.AttrName "role") "tabpanel"
      , HP.tabIndex (-1)
      , ARIA.labelledBy tabId
      , HP.attr (HH.AttrName "data-state") "inactive"
      , HP.attr (HH.AttrName "hidden") "true"
      ]
      []

orientationStr :: Orientation -> String
orientationStr Horizontal = "horizontal"
orientationStr Vertical = "vertical"

-- ═══════════════════════════════════════════════════════════════════════════════
-- ACTIONS
-- ═══════════════════════════════════════════════════════════════════════════════

handleAction :: forall m. MonadAff m => Action -> H.HalogenM State Action () Output m Unit
handleAction = case _ of
  Initialize -> pure unit

  Receive newInput -> do
    -- Handle controlled value changes
    case newInput.value of
      Just newValue -> do
        state <- H.get
        when (newValue /= state.selectedValue) do
          H.modify_ _ { selectedValue = newValue }
      Nothing -> pure unit
    H.modify_ _ { input = newInput }

  SelectTab value -> do
    state <- H.get
    -- Find the tab to check if disabled
    let mTab = Array.find (\t -> t.value == value) state.input.tabs
    case mTab of
      Just tab | not tab.disabled -> do
        H.modify_ _ { selectedValue = value }
        H.raise (ValueChanged value)
      _ -> pure unit

  HandleKeyDown currentIdx ke -> do
    state <- H.get
    let
      key = KE.key ke
      tabs = state.input.tabs
      enabledIndices = Array.mapWithIndex (\i t -> if t.disabled then Nothing else Just i) tabs
                       # Array.catMaybes
      currentEnabledIdx = Array.findIndex (_ == currentIdx) enabledIndices
      
      -- Navigate based on orientation and key
      nextIdx = case state.input.orientation, key of
        Horizontal, "ArrowRight" -> nextEnabledTab enabledIndices currentEnabledIdx state.input.loop
        Horizontal, "ArrowLeft" -> prevEnabledTab enabledIndices currentEnabledIdx state.input.loop
        Vertical, "ArrowDown" -> nextEnabledTab enabledIndices currentEnabledIdx state.input.loop
        Vertical, "ArrowUp" -> prevEnabledTab enabledIndices currentEnabledIdx state.input.loop
        _, "Home" -> Array.head enabledIndices
        _, "End" -> Array.last enabledIndices
        _, _ -> Nothing

    for_ nextIdx \idx -> do
      liftEffect $ Event.preventDefault (KE.toEvent ke)
      case Array.index tabs idx of
        Just tab -> do
          -- Focus the tab
          doc <- liftEffect $ HTML.window >>= Window.document
          let tabId = state.baseId <> "-tab-" <> tab.value
          mEl <- liftEffect $ getElementById tabId doc
          for_ mEl \el -> liftEffect $ HTMLElement.focus el
          
          -- If automatic activation, select it too
          when (state.input.activationMode == Automatic) do
            handleAction (SelectTab tab.value)
        Nothing -> pure unit

-- Helper to find next enabled tab
nextEnabledTab :: Array Int -> Maybe Int -> Boolean -> Maybe Int
nextEnabledTab indices mCurrent loop =
  case mCurrent of
    Nothing -> Array.head indices
    Just current ->
      let next = current + 1
      in if next >= Array.length indices
         then if loop then Array.head indices else Nothing
         else Array.index indices next

-- Helper to find previous enabled tab
prevEnabledTab :: Array Int -> Maybe Int -> Boolean -> Maybe Int
prevEnabledTab indices mCurrent loop =
  case mCurrent of
    Nothing -> Array.last indices
    Just current ->
      let prev = current - 1
      in if prev < 0
         then if loop then Array.last indices else Nothing
         else Array.index indices prev

-- FFI for getElementById
foreign import getElementByIdImpl :: String -> HTMLDocument.HTMLDocument -> Effect (Nullable HTMLElement.HTMLElement)

getElementById :: String -> HTMLDocument.HTMLDocument -> Effect (Maybe HTMLElement.HTMLElement)
getElementById id doc = toMaybe <$> getElementByIdImpl id doc

-- ═══════════════════════════════════════════════════════════════════════════════
-- QUERIES
-- ═══════════════════════════════════════════════════════════════════════════════

handleQuery :: forall m a. MonadAff m => Query a -> H.HalogenM State Action () Output m (Maybe a)
handleQuery = case _ of
  SetValue value a -> do
    handleAction (SelectTab value)
    pure (Just a)
  
  GetValue reply -> do
    state <- H.get
    pure (Just (reply state.selectedValue))
