-- | TODO List Component
module Component.Todo where

import Prelude

import Data.Array (filter, snoc, mapWithIndex, length)
import Data.Maybe (Maybe(..))
import Web.UIEvent.KeyboardEvent (KeyboardEvent, key)
import Control.Monad (when)
import Data.String (trim, null)
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

-- ============================================================
-- TYPES
-- ============================================================

type TodoItem =
  { id :: Int
  , text :: String
  , completed :: Boolean
  }

type State =
  { todos :: Array TodoItem
  , input :: String
  , nextId :: Int
  }

data Action
  = UpdateInput String
  | AddTodo
  | HandleKeyDown KeyboardEvent
  | ToggleTodo Int
  | RemoveTodo Int
  | ClearCompleted

-- ============================================================
-- COMPONENT
-- ============================================================

component :: forall q i o m. MonadAff m => H.Component q i o m
component = H.mkComponent
  { initialState: const initialState
  , render
  , eval: H.mkEval H.defaultEval { handleAction = handleAction }
  }

initialState :: State
initialState =
  { todos: []
  , input: ""
  , nextId: 0
  }

-- ============================================================
-- HANDLER
-- ============================================================

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  UpdateInput str ->
    H.modify_ _ { input = str }
  
  AddTodo -> do
    { input, nextId } <- H.get
    let trimmed = trim input
    unless (null trimmed) do
      let newTodo = { id: nextId, text: trimmed, completed: false }
      H.modify_ \s -> s
        { todos = snoc s.todos newTodo
        , input = ""
        , nextId = nextId + 1
        }
  
  HandleKeyDown e ->
    when (key e == "Enter") do
      handleAction AddTodo
  
  ToggleTodo targetId ->
    H.modify_ \s -> s
      { todos = map toggleIfMatch s.todos }
    where
      toggleIfMatch todo
        | todo.id == targetId = todo { completed = not todo.completed }
        | otherwise = todo
  
  RemoveTodo targetId ->
    H.modify_ \s -> s
      { todos = filter (\t -> t.id /= targetId) s.todos }
  
  ClearCompleted ->
    H.modify_ \s -> s
      { todos = filter (not <<< _.completed) s.todos }

-- ============================================================
-- RENDER
-- ============================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div
    [ HP.class_ $ HH.ClassName "todo-app" ]
    [ renderHeader
    , renderInput state.input
    , renderTodoList state.todos
    , renderFooter state.todos
    ]

renderHeader :: forall w i. HH.HTML w i
renderHeader =
  HH.header_
    [ HH.h1
        [ HP.class_ $ HH.ClassName "todo-title" ]
        [ HH.text "// todos //" ]
    ]

renderInput :: forall m. String -> H.ComponentHTML Action () m
renderInput inputValue =
  HH.div
    [ HP.class_ $ HH.ClassName "todo-input-container" ]
    [ HH.input
        [ HP.type_ HP.InputText
        , HP.value inputValue
        , HP.placeholder "what needs to be done?"
        , HP.class_ $ HH.ClassName "todo-input"
        , HE.onValueInput UpdateInput
        , HE.onKeyDown HandleKeyDown
        ]
    , HH.button
        [ HP.class_ $ HH.ClassName "todo-add-btn"
        , HE.onClick \_ -> AddTodo
        ]
        [ HH.text "+" ]
    ]

renderTodoList :: forall m. Array TodoItem -> H.ComponentHTML Action () m
renderTodoList todos =
  HH.ul
    [ HP.class_ $ HH.ClassName "todo-list" ]
    (mapWithIndex (\_ todo -> renderTodoItem todo) todos)

renderTodoItem :: forall m. TodoItem -> H.ComponentHTML Action () m
renderTodoItem todo =
  HH.li
    [ HP.class_ $ HH.ClassName $ "todo-item" <> if todo.completed then " completed" else "" ]
    [ HH.input
        [ HP.type_ HP.InputCheckbox
        , HP.checked todo.completed
        , HP.class_ $ HH.ClassName "todo-checkbox"
        , HE.onChecked \_ -> ToggleTodo todo.id
        ]
    , HH.span
        [ HP.class_ $ HH.ClassName "todo-text" ]
        [ HH.text todo.text ]
    , HH.button
        [ HP.class_ $ HH.ClassName "todo-remove-btn"
        , HE.onClick \_ -> RemoveTodo todo.id
        ]
        [ HH.text "x" ]
    ]

renderFooter :: forall m. Array TodoItem -> H.ComponentHTML Action () m
renderFooter todos =
  let
    total = length todos
    completed = length $ filter _.completed todos
    remaining = total - completed
  in
    HH.footer
      [ HP.class_ $ HH.ClassName "todo-footer" ]
      [ HH.span_
          [ HH.text $ show remaining <> " items remaining" ]
      , HH.button
          [ HP.class_ $ HH.ClassName "clear-completed-btn"
          , HE.onClick \_ -> ClearCompleted
          ]
          [ HH.text "clear completed" ]
      ]



