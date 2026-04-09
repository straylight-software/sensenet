{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | DhallFast.Convert - Convert from upstream Dhall to DhallFast

This module bridges the gap between the standard Dhall parser
and our optimized evaluator.
-}
module DhallFast.Convert (
    fromDhall,
    toDhall,
)
where

import Data.ByteString.Short qualified as SBS
import Data.Foldable qualified as F
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Short qualified as TS
import Data.Void (Void)
import Dhall.Core qualified as D
import Dhall.Map qualified as DM
import Dhall.Src qualified as Src
import DhallFast.Core

--------------------------------------------------------------------------------
-- Convert from Dhall.Expr to DhallFast.Expr
--------------------------------------------------------------------------------

{- | Convert upstream Dhall expression to DhallFast
Uses de Bruijn indices, requires scope tracking
-}
fromDhall :: D.Expr Src.Src Void -> Expr
fromDhall = go []
  where
    go :: [Text] -> D.Expr Src.Src Void -> Expr
    go !scope expr = case expr of
        D.Const D.Type -> EConst Type
        D.Const D.Kind -> EConst Kind
        D.Const D.Sort -> EConst Sort
        D.Var (D.V name idx) ->
            -- Convert (name, index) to de Bruijn index
            let debruijn = findVar name idx scope 0
             in EVar (Var debruijn)
        D.Lam _ fb body ->
            let name = D.functionBindingVariable fb
                ty = D.functionBindingAnnotation fb
                scope' = name : scope
             in ELam (internName name) (go scope ty) (go scope' body)
        D.Pi _ name domain codomain ->
            let scope' = name : scope
             in EPi (internName name) (go scope domain) (go scope' codomain)
        D.App f x -> EApp (go scope f) (go scope x)
        D.Let binding body ->
            let name = D.variable binding
                mty = D.annotation binding
                val = D.value binding
                scope' = name : scope
             in ELet
                    (internName name)
                    (fmap (go scope . snd) mty)
                    (go scope val)
                    (go scope' body)
        D.Annot e t -> EAnnot (go scope e) (go scope t)
        D.Bool -> EBuiltin BBool
        D.BoolLit b -> ELit (LitBool b)
        D.BoolAnd a b -> EBoolAnd (go scope a) (go scope b)
        D.BoolOr a b -> EBoolOr (go scope a) (go scope b)
        D.BoolEQ a b ->
            -- a == b simplified
            EBoolIf
                (go scope a)
                (go scope b)
                (EBoolIf (go scope b) (ELit (LitBool False)) (ELit (LitBool True)))
        D.BoolNE a b ->
            EBoolIf
                (go scope a)
                (EBoolIf (go scope b) (ELit (LitBool False)) (ELit (LitBool True)))
                (go scope b)
        D.BoolIf c t f -> EBoolIf (go scope c) (go scope t) (go scope f)
        D.Bytes -> EBuiltin BBytes
        D.BytesLit bs -> ELit (LitBytes (SBS.toShort bs))
        D.Natural -> EBuiltin BNatural
        D.NaturalLit n -> ELit (LitNat (fromIntegral n))
        D.NaturalFold -> EBuiltin BNaturalFold
        D.NaturalBuild -> EBuiltin BNaturalBuild
        D.NaturalIsZero -> EBuiltin BNaturalIsZero
        D.NaturalEven -> EBuiltin BNaturalEven
        D.NaturalOdd -> EBuiltin BNaturalOdd
        D.NaturalToInteger -> EBuiltin BNaturalToInteger
        D.NaturalShow -> EBuiltin BNaturalShow
        D.NaturalSubtract -> EBuiltin BNaturalSubtract
        D.NaturalPlus a b -> ENatPlus (go scope a) (go scope b)
        D.NaturalTimes a b -> ENatTimes (go scope a) (go scope b)
        D.Integer -> EBuiltin BInteger
        D.IntegerLit n -> ELit (LitInt (fromIntegral n))
        D.IntegerClamp -> EBuiltin BIntegerClamp
        D.IntegerNegate -> EBuiltin BIntegerNegate
        D.IntegerShow -> EBuiltin BIntegerShow
        D.IntegerToDouble -> EBuiltin BIntegerToDouble
        D.Double -> EBuiltin BDouble
        D.DoubleLit (D.DhallDouble d) -> ELit (LitDouble d)
        D.DoubleShow -> EBuiltin BDoubleShow
        D.Text -> EBuiltin BText
        D.TextLit (D.Chunks [] t) -> ELit (LitText (toShortText t))
        D.TextLit (D.Chunks chunks suffix) ->
            -- Convert text interpolation to series of appends
            foldr
                ( \(prefix, e) acc ->
                    ETextAppend
                        (ELit (LitText (toShortText prefix)))
                        (ETextAppend (go scope e) acc)
                )
                (ELit (LitText (toShortText suffix)))
                chunks
        D.TextAppend a b -> ETextAppend (go scope a) (go scope b)
        D.TextShow -> EBuiltin BTextShow
        D.TextReplace -> EBuiltin BTextReplace
        D.Date -> error "Date not yet supported"
        D.DateLiteral _ -> error "DateLiteral not yet supported"
        D.DateShow -> error "DateShow not yet supported"
        D.Time -> error "Time not yet supported"
        D.TimeLiteral _ _ -> error "TimeLiteral not yet supported"
        D.TimeShow -> error "TimeShow not yet supported"
        D.TimeZone -> error "TimeZone not yet supported"
        D.TimeZoneLiteral _ -> error "TimeZoneLiteral not yet supported"
        D.TimeZoneShow -> error "TimeZoneShow not yet supported"
        D.List -> EBuiltin BList
        D.ListLit mty xs ->
            EList (fmap (go scope) mty) (fmap (go scope) xs)
        D.ListAppend a b -> EListAppend (go scope a) (go scope b)
        D.ListBuild -> EBuiltin BListBuild
        D.ListFold -> EBuiltin BListFold
        D.ListLength -> EBuiltin BListLength
        D.ListHead -> EBuiltin BListHead
        D.ListLast -> EBuiltin BListLast
        D.ListIndexed -> EBuiltin BListIndexed
        D.ListReverse -> EBuiltin BListReverse
        D.Optional -> EBuiltin BOptional
        D.Some e -> EApp (EBuiltin BSome) (go scope e)
        D.None -> EBuiltin BNone
        D.Record fields ->
            ERecord
                ( fieldsFromList
                    [ (internName k, go scope (D.recordFieldValue v))
                    | (k, v) <- DM.toList fields
                    ]
                )
        D.RecordLit fields ->
            ERecordLit
                ( fieldsFromList
                    [ (internName k, go scope (D.recordFieldValue v))
                    | (k, v) <- DM.toList fields
                    ]
                )
        D.Union fields ->
            EUnion
                ( fieldsFromList
                    [ (internName k, fmap (go scope) v)
                    | (k, v) <- DM.toList fields
                    ]
                )
        D.Combine _ _ a b -> ECombine (go scope a) (go scope b)
        D.CombineTypes _ a b -> ECombineTypes (go scope a) (go scope b)
        D.Prefer _ _ a b -> EPrefer (go scope a) (go scope b)
        D.RecordCompletion a b ->
            -- T::r desugars to (T.default // r) : T.Type
            EAnnot
                ( EPrefer
                    (EField (go scope a) (internName "default"))
                    (go scope b)
                )
                (EField (go scope a) (internName "Type"))
        D.Merge a b mty -> EMerge (go scope a) (go scope b) (fmap (go scope) mty)
        D.ToMap a mty -> EToMap (go scope a) (fmap (go scope) mty)
        D.ShowConstructor _ -> error "ShowConstructor not yet supported"
        D.Field e fs -> EField (go scope e) (internName (D.fieldSelectionLabel fs))
        D.Project e (Left names) -> EProject (go scope e) (map internName names)
        D.Project _ (Right _) ->
            error "Project by type not yet supported"
        D.Assert e -> EAssert (go scope e)
        D.Equivalent _ a b -> EEquivalent (go scope a) (go scope b)
        D.With e path val ->
            let names = map componentToName (F.toList path)
             in EWith (go scope e) names (go scope val)
        D.Note _ e -> go scope e -- Drop source annotations
        D.ImportAlt a _ -> go scope a -- Take first alternative
        D.Embed void -> absurd void

    -- Find de Bruijn index for variable
    findVar :: Text -> Int -> [Text] -> Int -> Int
    findVar name !targetIdx [] !_acc =
        error $ "Unbound variable: " ++ T.unpack name ++ "@" ++ show targetIdx
    findVar name !targetIdx (x : xs) !acc
        | x == name = if targetIdx == 0 then acc else findVar name (targetIdx - 1) xs (acc + 1)
        | otherwise = findVar name targetIdx xs (acc + 1)

    componentToName (D.WithLabel t) = internName t
    componentToName D.WithQuestion = internName "?"

    toShortText t
        | T.length t < 256 = TS.fromText t
        | otherwise = TS.fromText t

    absurd :: Void -> a
    absurd v = case v of {}

--------------------------------------------------------------------------------
-- Convert back to Dhall.Expr (for compatibility)
--------------------------------------------------------------------------------

-- | Convert DhallFast expression back to upstream Dhall
toDhall :: Expr -> D.Expr Src.Src Void
toDhall = go []
  where
    go :: [Text] -> Expr -> D.Expr Src.Src Void
    go !scope = \case
        EConst Type -> D.Const D.Type
        EConst Kind -> D.Const D.Kind
        EConst Sort -> D.Const D.Sort
        EVar (Var idx) ->
            -- Convert de Bruijn index back to (name, index) pair
            let (name, count) = indexToVar idx scope
             in D.Var (D.V name count)
        ELam name ty body ->
            let nameT = nameText name
                scope' = nameT : scope
                fb =
                    D.FunctionBinding
                        { D.functionBindingVariable = nameT
                        , D.functionBindingSrc0 = Nothing
                        , D.functionBindingSrc1 = Nothing
                        , D.functionBindingSrc2 = Nothing
                        , D.functionBindingAnnotation = go scope ty
                        }
             in D.Lam Nothing fb (go scope' body)
        EPi name domain codomain ->
            let nameT = nameText name
                scope' = nameT : scope
             in D.Pi Nothing nameT (go scope domain) (go scope' codomain)
        EApp (EBuiltin BSome) x -> D.Some (go scope x)
        EApp f x -> D.App (go scope f) (go scope x)
        ELet name mty val body ->
            let nameT = nameText name
                scope' = nameT : scope
                binding =
                    D.Binding
                        { D.variable = nameT
                        , D.bindingSrc0 = Nothing
                        , D.bindingSrc1 = Nothing
                        , D.annotation = fmap (\t -> (Nothing, go scope t)) mty
                        , D.bindingSrc2 = Nothing
                        , D.value = go scope val
                        }
             in D.Let binding (go scope' body)
        ELit (LitBool b) -> D.BoolLit b
        ELit (LitNat n) -> D.NaturalLit (fromIntegral n)
        ELit (LitInt n) -> D.IntegerLit (fromIntegral n)
        ELit (LitDouble d) -> D.DoubleLit (D.DhallDouble d)
        ELit (LitText t) -> D.TextLit (D.Chunks [] (TS.toText t))
        ELit (LitTextLong t) -> D.TextLit (D.Chunks [] t)
        ELit (LitBytes bs) -> D.BytesLit (SBS.fromShort bs)
        EBoolAnd a b -> D.BoolAnd (go scope a) (go scope b)
        EBoolOr a b -> D.BoolOr (go scope a) (go scope b)
        EBoolIf c t f -> D.BoolIf (go scope c) (go scope t) (go scope f)
        ENatPlus a b -> D.NaturalPlus (go scope a) (go scope b)
        ENatTimes a b -> D.NaturalTimes (go scope a) (go scope b)
        ETextAppend a b -> D.TextAppend (go scope a) (go scope b)
        EList mty xs ->
            D.ListLit (fmap (go scope) mty) (fmap (go scope) xs)
        EListAppend a b -> D.ListAppend (go scope a) (go scope b)
        ERecord fields ->
            D.Record
                ( DM.fromList
                    [ (nameText k, D.makeRecordField (go scope v))
                    | (k, v) <- fieldsToList fields
                    ]
                )
        ERecordLit fields ->
            D.RecordLit
                ( DM.fromList
                    [ (nameText k, D.makeRecordField (go scope v))
                    | (k, v) <- fieldsToList fields
                    ]
                )
        EUnion fields ->
            D.Union
                ( DM.fromList
                    [ (nameText k, fmap (go scope) v)
                    | (k, v) <- fieldsToList fields
                    ]
                )
        ECombine a b -> D.Combine Nothing Nothing (go scope a) (go scope b)
        ECombineTypes a b -> D.CombineTypes Nothing (go scope a) (go scope b)
        EPrefer a b -> D.Prefer Nothing D.PreferFromSource (go scope a) (go scope b)
        EMerge a b mty -> D.Merge (go scope a) (go scope b) (fmap (go scope) mty)
        EToMap a mty -> D.ToMap (go scope a) (fmap (go scope) mty)
        EField e name -> D.Field (go scope e) (D.makeFieldSelection (nameText name))
        EProject e names -> D.Project (go scope e) (Left (map nameText names))
        EAssert e -> D.Assert (go scope e)
        EEquivalent a b -> D.Equivalent Nothing (go scope a) (go scope b)
        EWith e path val ->
            let withPath = map (D.WithLabel . nameText) path
             in case withPath of
                    [] -> go scope val -- empty path = just the value
                    (p : ps) -> D.With (go scope e) (p :| ps) (go scope val)
        EBuiltin b -> builtinToDhall b
        EAnnot e t -> D.Annot (go scope e) (go scope t)

    -- Convert de Bruijn index to (name, shadowing index)
    indexToVar :: Int -> [Text] -> (Text, Int)
    indexToVar idx scope
        | idx < length scope =
            let name = scope !! idx
                -- Count how many times this name appears before this index
                count = length [() | (i, n) <- zip [0 ..] scope, i < idx, n == name]
             in (name, count)
        | otherwise = ("_", idx - length scope)

builtinToDhall :: Builtin -> D.Expr s a
builtinToDhall = \case
    BNatural -> D.Natural
    BNaturalFold -> D.NaturalFold
    BNaturalBuild -> D.NaturalBuild
    BNaturalIsZero -> D.NaturalIsZero
    BNaturalEven -> D.NaturalEven
    BNaturalOdd -> D.NaturalOdd
    BNaturalToInteger -> D.NaturalToInteger
    BNaturalShow -> D.NaturalShow
    BNaturalSubtract -> D.NaturalSubtract
    BInteger -> D.Integer
    BIntegerClamp -> D.IntegerClamp
    BIntegerNegate -> D.IntegerNegate
    BIntegerShow -> D.IntegerShow
    BIntegerToDouble -> D.IntegerToDouble
    BDouble -> D.Double
    BDoubleShow -> D.DoubleShow
    BText -> D.Text
    BTextShow -> D.TextShow
    BTextReplace -> D.TextReplace
    BList -> D.List
    BListBuild -> D.ListBuild
    BListFold -> D.ListFold
    BListLength -> D.ListLength
    BListHead -> D.ListHead
    BListLast -> D.ListLast
    BListIndexed -> D.ListIndexed
    BListReverse -> D.ListReverse
    BOptional -> D.Optional
    BNone -> D.None
    BSome -> error "Some is not a standalone builtin in Dhall"
    BBool -> D.Bool
    BBytes -> D.Bytes
