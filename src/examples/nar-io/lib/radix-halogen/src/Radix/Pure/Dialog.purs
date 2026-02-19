-- | Pure Dialog Implementation
-- |
-- | A dialog component implemented entirely in PureScript/Halogen,
-- | with NO React dependency. Implements the same behavior as Radix Dialog:
-- |
-- | - Modal/non-modal modes
-- | - Focus trapping with Tab loop
-- | - Scroll locking
-- | - Escape to close
-- | - Click outside to close
-- | - Focus restoration
-- | - Proper ARIA attributes
module Radix.Pure.Dialog
  ( component
  , Query(..)
  , Input
  , Output(..)
  , Slot
  , defaultInput
  ) where

import Prelude

import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe)
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.HTML.Properties.ARIA as ARIA
import Halogen.Query.Event as HQE
import Radix.Pure.AriaHider as AH
import Radix.Pure.FocusTrap as FT
import Radix.Pure.Id as Id
import Web.Event.Event as Event
import Web.HTML as HTML
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.HTMLElement as HTMLElement
import Web.HTML.Window as Window
import Web.UIEvent.KeyboardEvent as KE
import Web.UIEvent.KeyboardEvent.EventTypes as KET

-- ═══════════════════════════════════════════════════════════════════════════════
-- TYPES
-- ═══════════════════════════════════════════════════════════════════════════════

-- | Dialog input props
type Input =
  { open :: Maybe Boolean           -- Controlled open state
  , defaultOpen :: Boolean          -- Initial state if uncontrolled
  , modal :: Boolean                -- Modal (blocking) vs modeless
  , closeOnEscape :: Boolean        -- Close on Escape key
  , closeOnOutsideClick :: Boolean  -- Close on click outside
  }

defaultInput :: Input
defaultInput =
  { open: Nothing
  , defaultOpen: false
  , modal: true
  , closeOnEscape: true
  , closeOnOutsideClick: true
  }

-- | Output events
data Output
  = Opened
  | Closed
  | OpenChanged Boolean

-- | Queries for external control
data Query a
  = Open a
  | Close a
  | Toggle a
  | IsOpen (Boolean -> a)

-- | Internal state
type State =
  { isOpen :: Boolean
  , input :: Input
  , triggerRef :: Maybe HTMLElement.HTMLElement
  , contentRef :: Maybe HTMLElement.HTMLElement
  , previousActiveElement :: Maybe HTMLElement.HTMLElement
  , focusScope :: Maybe FT.FocusScope
  , ariaHiderState :: Maybe AH.AriaHiderState
  , idGen :: Maybe Id.IdGenerator
  , contentId :: String
  , titleId :: String
  , descriptionId :: String
  }

-- | Internal actions
data Action
  = Initialize
  | Finalize
  | Receive Input
  | HandleTriggerClick
  | HandleCloseClick
  | HandleKeyDown KE.KeyboardEvent
  | HandleOverlayClick
  | ContentClicked
  | SetTriggerRef (Maybe HTMLElement.HTMLElement)
  | SetContentRef (Maybe HTMLElement.HTMLElement)

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
      , finalize = Just Finalize
      , receive = Just <<< Receive
      }
  }

initialState :: Input -> State
initialState input =
  { isOpen: fromMaybe input.defaultOpen input.open
  , input
  , triggerRef: Nothing
  , contentRef: Nothing
  , previousActiveElement: Nothing
  , focusScope: Nothing
  , ariaHiderState: Nothing
  , idGen: Nothing
  , contentId: ""  -- Set in Initialize
  , titleId: ""
  , descriptionId: ""
  }

-- ═══════════════════════════════════════════════════════════════════════════════
-- RENDER
-- ═══════════════════════════════════════════════════════════════════════════════

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div
    [ HP.class_ (HH.ClassName "dialog-root") ]
    [ renderTrigger state
    , if state.isOpen then renderPortal state else HH.text ""
    ]

renderTrigger :: forall m. State -> H.ComponentHTML Action () m
renderTrigger state =
  HH.button
    [ HP.class_ (HH.ClassName "dialog-trigger")
    , HP.type_ HP.ButtonButton
    , HE.onClick \_ -> HandleTriggerClick
    , HP.ref (H.RefLabel "trigger")
    , ARIA.hasPopup "dialog"
    , ARIA.expanded (show state.isOpen)
    , ARIA.controls state.contentId
    , HP.attr (HH.AttrName "data-state") (if state.isOpen then "open" else "closed")
    ]
    [ HH.text "Open Dialog" ]

renderPortal :: forall m. State -> H.ComponentHTML Action () m
renderPortal state =
  HH.div
    [ HP.class_ (HH.ClassName "dialog-portal") ]
    [ renderOverlay state
    , renderContent state
    ]

renderOverlay :: forall m. State -> H.ComponentHTML Action () m
renderOverlay state =
  HH.div
    [ HP.class_ (HH.ClassName "dialog-overlay")
    , HP.attr (HH.AttrName "data-state") (if state.isOpen then "open" else "closed")
    , HE.onClick \_ -> HandleOverlayClick
    ]
    []

renderContent :: forall m. State -> H.ComponentHTML Action () m
renderContent state =
  HH.div
    [ HP.class_ (HH.ClassName "dialog-content")
    , HP.ref (H.RefLabel "content")
    , HP.id state.contentId
    , HP.attr (HH.AttrName "role") "dialog"
    , HP.attr (HH.AttrName "aria-modal") (if state.input.modal then "true" else "false")
    , ARIA.labelledBy state.titleId
    , ARIA.describedBy state.descriptionId
    , HP.attr (HH.AttrName "data-state") (if state.isOpen then "open" else "closed")
    , HP.tabIndex 0
    , HE.onClick \_ -> ContentClicked
    ]
    [ HH.h2 
        [ HP.id state.titleId
        , HP.class_ (HH.ClassName "dialog-title")
        ]
        [ HH.text "Dialog Title" ]
    , HH.p
        [ HP.id state.descriptionId
        , HP.class_ (HH.ClassName "dialog-description")
        ]
        [ HH.text "Dialog description goes here." ]
    , HH.div [ HP.class_ (HH.ClassName "dialog-body") ]
        [ HH.text "Dialog content" ]
    , HH.button
        [ HP.class_ (HH.ClassName "dialog-close")
        , HP.type_ HP.ButtonButton
        , HE.onClick \_ -> HandleCloseClick
        ]
        [ HH.text "Close" ]
    ]

-- ═══════════════════════════════════════════════════════════════════════════════
-- ACTIONS
-- ═══════════════════════════════════════════════════════════════════════════════

handleAction :: forall m. MonadAff m => Action -> H.HalogenM State Action () Output m Unit
handleAction = case _ of
  Initialize -> do
    -- Generate unique IDs for accessibility
    idGen <- liftEffect $ Id.createIdGenerator "radix-dialog"
    contentId <- liftEffect $ Id.useId idGen "content"
    titleId <- liftEffect $ Id.useId idGen "title"
    descriptionId <- liftEffect $ Id.useId idGen "description"
    H.modify_ _ 
      { idGen = Just idGen
      , contentId = contentId
      , titleId = titleId
      , descriptionId = descriptionId
      }
    
    -- Subscribe to keyboard events
    doc <- liftEffect $ HTML.window >>= Window.document
    void $ H.subscribe $ HQE.eventListener
      KET.keydown
      (HTMLDocument.toEventTarget doc)
      (KE.fromEvent >>> map HandleKeyDown)

  Finalize -> do
    -- Cleanup: restore scroll, focus, etc.
    state <- H.get
    when state.isOpen do
      -- Release focus trap
      for_ state.focusScope \scope ->
        liftEffect $ FT.destroyFocusScope scope
      -- Restore aria-hidden
      for_ state.ariaHiderState \ariaState ->
        liftEffect $ AH.restoreOthers ariaState
      -- Restore scroll
      liftEffect restoreBodyScroll

  Receive newInput -> do
    -- Handle controlled state changes
    case newInput.open of
      Just newOpen -> do
        state <- H.get
        when (newOpen /= state.isOpen) do
          if newOpen
            then openDialog
            else closeDialog
      Nothing -> pure unit
    H.modify_ _ { input = newInput }

  HandleTriggerClick -> do
    state <- H.get
    -- Store trigger ref for focus restoration
    mTrigger <- H.getHTMLElementRef (H.RefLabel "trigger")
    H.modify_ _ { triggerRef = mTrigger }
    
    if state.isOpen
      then closeDialog
      else openDialog

  HandleCloseClick -> closeDialog

  HandleKeyDown ke -> do
    state <- H.get
    when state.isOpen do
      -- Handle Escape key
      when (state.input.closeOnEscape && KE.key ke == "Escape") do
        liftEffect $ Event.preventDefault (KE.toEvent ke)
        closeDialog
      
      -- Handle Tab key for focus trapping
      when (state.input.modal && KE.key ke == "Tab") do
        for_ state.focusScope \scope -> do
          handled <- liftEffect $ FT.handleTabKey scope ke
          when handled do
            liftEffect $ Event.preventDefault (KE.toEvent ke)

  HandleOverlayClick -> do
    state <- H.get
    when (state.isOpen && state.input.closeOnOutsideClick) do
      closeDialog

  ContentClicked -> pure unit  -- Swallow click, don't close

  SetTriggerRef ref -> H.modify_ _ { triggerRef = ref }
  SetContentRef ref -> H.modify_ _ { contentRef = ref }

-- ═══════════════════════════════════════════════════════════════════════════════
-- STATE TRANSITIONS
-- ═══════════════════════════════════════════════════════════════════════════════

openDialog :: forall m. MonadAff m => H.HalogenM State Action () Output m Unit
openDialog = do
  state <- H.get
  
  -- Store current active element for restoration
  doc <- liftEffect $ HTML.window >>= Window.document
  mActive <- liftEffect $ HTMLDocument.activeElement doc
  H.modify_ _ { previousActiveElement = mActive }
  
  -- Lock body scroll if modal
  when state.input.modal do
    liftEffect lockBodyScroll
  
  -- Update state to trigger render
  H.modify_ _ { isOpen = true }
  
  -- Create focus scope after render (need content element)
  mContent <- H.getHTMLElementRef (H.RefLabel "content")
  for_ mContent \el -> do
    -- Hide siblings from screen readers (for modal dialogs)
    when state.input.modal do
      ariaState <- liftEffect $ AH.hideOthers el
      H.modify_ _ { ariaHiderState = Just ariaState }
    
    -- Create and activate focus scope
    scope <- liftEffect $ FT.createFocusScope el
    H.modify_ _ { focusScope = Just scope }
    
    -- Trap focus (focuses first tabbable element)
    liftEffect $ FT.trapFocus scope
  
  -- Emit events
  H.raise Opened
  H.raise (OpenChanged true)

closeDialog :: forall m. MonadAff m => H.HalogenM State Action () Output m Unit
closeDialog = do
  state <- H.get
  
  -- Release focus trap and restore focus
  for_ state.focusScope \scope ->
    liftEffect $ FT.destroyFocusScope scope
  H.modify_ _ { focusScope = Nothing }
  
  -- Restore aria-hidden on siblings
  for_ state.ariaHiderState \ariaState ->
    liftEffect $ AH.restoreOthers ariaState
  H.modify_ _ { ariaHiderState = Nothing }
  
  -- Restore body scroll
  when state.input.modal do
    liftEffect restoreBodyScroll
  
  -- Update state
  H.modify_ _ { isOpen = false }
  
  -- Restore focus to trigger (fallback if focus scope didn't restore)
  for_ state.triggerRef \el ->
    liftEffect $ HTMLElement.focus el
  
  -- Emit events
  H.raise Closed
  H.raise (OpenChanged false)

-- ═══════════════════════════════════════════════════════════════════════════════
-- QUERIES
-- ═══════════════════════════════════════════════════════════════════════════════

handleQuery :: forall m a. MonadAff m => Query a -> H.HalogenM State Action () Output m (Maybe a)
handleQuery = case _ of
  Open a -> do
    openDialog
    pure (Just a)
  
  Close a -> do
    closeDialog
    pure (Just a)
  
  Toggle a -> do
    state <- H.get
    if state.isOpen then closeDialog else openDialog
    pure (Just a)
  
  IsOpen reply -> do
    state <- H.get
    pure (Just (reply state.isOpen))

-- ═══════════════════════════════════════════════════════════════════════════════
-- SIDE EFFECTS (FFI)
-- ═══════════════════════════════════════════════════════════════════════════════

foreign import lockBodyScroll :: Effect Unit
foreign import restoreBodyScroll :: Effect Unit


