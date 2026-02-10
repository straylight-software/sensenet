--| Minimal vendored Prelude
--|
--| Just the functions we need, no network fetch.

-- Text.concatSep - join texts with separator
let concatSep
    : Text -> List Text -> Text
    = \(sep : Text) ->
      \(xs : List Text) ->
        -- Use Optional to track "first element" without Text comparison
        let result =
              List/fold
                Text
                xs
                { first : Bool, acc : Text }
                ( \(x : Text) ->
                  \(state : { first : Bool, acc : Text }) ->
                    if state.first
                    then { first = False, acc = x }
                    else { first = False, acc = x ++ sep ++ state.acc }
                )
                { first = True, acc = "" }
        in result.acc

-- List.map
let map
    : forall (a : Type) -> forall (b : Type) -> (a -> b) -> List a -> List b
    = \(a : Type) ->
      \(b : Type) ->
      \(f : a -> b) ->
      \(xs : List a) ->
        List/build
          b
          ( \(list : Type) ->
            \(cons : b -> list -> list) ->
            List/fold a xs list (\(x : a) -> cons (f x))
          )

-- List.concatMap
let concatMap
    : forall (a : Type) -> forall (b : Type) -> (a -> List b) -> List a -> List b
    = \(a : Type) ->
      \(b : Type) ->
      \(f : a -> List b) ->
      \(xs : List a) ->
        List/build
          b
          ( \(list : Type) ->
            \(cons : b -> list -> list) ->
            List/fold
              a
              xs
              list
              (\(x : a) -> List/fold b (f x) list cons)
          )

-- List.concat
let concat
    : forall (a : Type) -> List (List a) -> List a
    = \(a : Type) ->
      \(xss : List (List a)) ->
        List/build
          a
          ( \(list : Type) ->
            \(cons : a -> list -> list) ->
            List/fold
              (List a)
              xss
              list
              (\(xs : List a) -> List/fold a xs list cons)
          )

-- List.null (check if empty)
let null
    : forall (a : Type) -> List a -> Bool
    = \(a : Type) ->
      \(xs : List a) ->
        List/fold a xs Bool (\(_ : a) -> \(_ : Bool) -> False) True

in  { Text = { concatSep }
    , List = { map, concatMap, concat, null }
    }
