{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE UnboxedTuples #-}

-- | DhallFast.Eval - Cache-optimized evaluator
--
-- Key optimizations:
--   1. Array-based environment with O(1) de Bruijn lookup
--   2. Unboxed closures where possible
--   3. Specialized eval for common patterns
--   4. Minimal allocation in hot paths
--
-- L2 cache strategy:
--   - Environment: contiguous array, excellent spatial locality
--   - Values: compact representation, fits in cache lines
--   - Closures: avoid storing full Expr, use indices when possible
module DhallFast.Eval
  ( -- * Evaluation
    eval,
    normalize,
    quote,

    -- * Environment
    Env (..),
    emptyEnv,
    extendEnv,
    lookupEnv,

    -- * Values
    Val (..),
    VClosure (..),

    -- * Conversion checking
    conv,
  )
where

import Data.Int (Int64)
import Data.List (sortOn)
import Data.Sequence (Seq, ViewL (..))
import Data.Sequence qualified as Seq
import Data.Text.Short qualified as TS
import Data.Word (Word64)
import DhallFast.Core

--------------------------------------------------------------------------------
-- Environment: Array-based for O(1) lookup
--------------------------------------------------------------------------------

-- | Environment as strict spine list with unboxed size
-- This matches Dhall's approach but with de Bruijn indices
-- O(1) cons, O(i) lookup - but i is typically small (< 10)
-- The strict spine ensures good cache behavior
data Env
  = EnvNil
  | EnvCons {-# UNPACK #-} !Int !Val !Env -- size, value, rest
  deriving (Show)

emptyEnv :: Env
emptyEnv = EnvNil
{-# INLINE emptyEnv #-}

envSize :: Env -> Int
envSize EnvNil = 0
envSize (EnvCons n _ _) = n
{-# INLINE envSize #-}

-- | O(1) extend
extendEnv :: Val -> Env -> Env
extendEnv !v env = EnvCons (envSize env + 1) v env
{-# INLINE extendEnv #-}

-- | O(i) lookup - de Bruijn index i is distance from head
-- Optimized: indices 0,1,2 are most common
lookupEnv :: Var -> Env -> Maybe Val
lookupEnv (Var 0) (EnvCons _ v _) = Just v
lookupEnv (Var 1) (EnvCons _ _ (EnvCons _ v _)) = Just v
lookupEnv (Var 2) (EnvCons _ _ (EnvCons _ _ (EnvCons _ v _))) = Just v
lookupEnv (Var i) env = go i env
  where
    go !_ EnvNil = Nothing
    go 0 (EnvCons _ v _) = Just v
    go j (EnvCons _ _ rest) = go (j - 1) rest
{-# INLINE lookupEnv #-}

--------------------------------------------------------------------------------
-- Values (evaluation results)
--------------------------------------------------------------------------------

-- | Closure: captures environment + body expression
data VClosure = VClosure
  { closureName :: !Name,
    closureEnv :: !Env,
    closureBody :: !Expr
  }
  deriving (Show)

-- | Value type - WHNF of expressions
data Val
  = VConst !Const
  | VVar {-# UNPACK #-} !Int -- de Bruijn level (not index)
  | VApp !Val !Val -- neutral application
  | VLam !Name !Val !VClosure -- λ(x : A). body
  | VPi !Name !Val !VClosure -- ∀(x : A) → B
  | VBool
  | VBoolLit !Bool
  | VBoolAnd !Val !Val
  | VBoolOr !Val !Val
  | VBoolIf !Val !Val !Val
  | VNatural
  | VNaturalLit {-# UNPACK #-} !Word64
  | VNaturalPlus !Val !Val
  | VNaturalTimes !Val !Val
  | VInteger
  | VIntegerLit {-# UNPACK #-} !Int64
  | VDouble
  | VDoubleLit {-# UNPACK #-} !Double
  | VText
  | VTextLit !TextVal
  | VTextAppend !Val !Val
  | VList !Val
  | VListLit !(Maybe Val) !(Seq Val)
  | VListAppend !Val !Val
  | VOptional !Val
  | VSome !Val
  | VNone !Val
  | VRecord !(Fields Val)
  | VRecordLit !(Fields Val)
  | VUnion !(Fields (Maybe Val))
  | VCombine !Val !Val
  | VCombineTypes !Val !Val
  | VPrefer !Val !Val
  | VMerge !Val !Val !(Maybe Val)
  | VToMap !Val !(Maybe Val)
  | VField !Val !Name -- neutral field access
  | VProject !Val ![Name]
  | VInject !(Fields (Maybe Val)) !Name !(Maybe Val)
  | VAssert !Val
  | VEquivalent !Val !Val
  | VWith !Val ![Name] !Val
  | VBuiltin !Builtin
  | VPrimFun !Name !(Val -> Val) -- primitive function
  deriving (Show)

-- Can't derive Show for function types
instance Show (Val -> Val) where
  show _ = "<function>"

-- | Text value (chunks for interpolation)
data TextVal
  = TextPlain {-# UNPACK #-} !TS.ShortText
  | TextChunks ![(TS.ShortText, Val)] {-# UNPACK #-} !TS.ShortText
  deriving (Show)

--------------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------------

-- | Evaluate expression to WHNF
eval :: Env -> Expr -> Val
eval !env = \case
  EConst c -> VConst c
  EVar v -> case lookupEnv v env of
    Just val -> val
    Nothing -> VVar (envSize env - varIndex v - 1) -- free variable as level
  ELam name ty body ->
    let !vty = eval env ty
        !closure = VClosure name env body
     in VLam name vty closure
  EPi name domain codomain ->
    let !vdom = eval env domain
        !closure = VClosure name env codomain
     in VPi name vdom closure
  EApp f x ->
    let !vf = eval env f
        !vx = eval env x
     in vApp vf vx
  ELet _name _mty val body ->
    let !vval = eval env val
        !env' = extendEnv vval env
     in eval env' body
  ELit lit -> evalLit lit
  EBoolAnd a b -> evalBoolAnd env a b
  EBoolOr a b -> evalBoolOr env a b
  EBoolIf c t f -> evalBoolIf env c t f
  ENatPlus a b -> evalNatPlus env a b
  ENatTimes a b -> evalNatTimes env a b
  ETextAppend a b -> evalTextAppend env a b
  EList mty xs ->
    let !vty = fmap (eval env) mty
        -- Keep elements lazy with Seq - fmap is lazy for Seq
        vxs = fmap (eval env) xs
     in VListLit vty vxs
  EListAppend a b -> evalListAppend env a b
  ERecord fields -> VRecord (fmap (eval env) fields)
  ERecordLit fields -> VRecordLit (fmap (eval env) fields)
  EUnion fields -> VUnion (fmap (fmap (eval env)) fields)
  ECombine a b -> evalCombine env a b
  ECombineTypes a b -> evalCombineTypes env a b
  EPrefer a b -> evalPrefer env a b
  EMerge a b mty ->
    let !va = eval env a
        !vb = eval env b
        !vmty = fmap (eval env) mty
     in evalMerge va vb vmty
  EToMap a mty ->
    let !va = eval env a
        !vmty = fmap (eval env) mty
     in VToMap va vmty
  EField e name ->
    let !ve = eval env e
     in vField ve name
  EProject e names ->
    let !ve = eval env e
     in vProject ve names
  EAssert e -> VAssert (eval env e)
  EEquivalent a b -> VEquivalent (eval env a) (eval env b)
  EWith e path val ->
    let !ve = eval env e
        !vval = eval env val
     in vWith ve path vval
  EBuiltin b -> evalBuiltin b
  EAnnot e _ -> eval env e
{-# INLINE eval #-}

--------------------------------------------------------------------------------
-- Specialized evaluators for common operations
--------------------------------------------------------------------------------

evalLit :: Lit -> Val
evalLit = \case
  LitBool b -> VBoolLit b
  LitNat n -> VNaturalLit n
  LitInt n -> VIntegerLit n
  LitDouble d -> VDoubleLit d
  LitText t -> VTextLit (TextPlain t)
  LitTextLong t -> VTextLit (TextPlain (TS.fromText t))
  LitBytes _ -> error "evalLit: bytes not yet supported"
{-# INLINE evalLit #-}

evalBoolAnd :: Env -> Expr -> Expr -> Val
evalBoolAnd env a b = case eval env a of
  VBoolLit True -> eval env b
  VBoolLit False -> VBoolLit False
  va -> case eval env b of
    VBoolLit True -> va
    VBoolLit False -> VBoolLit False
    vb -> VBoolAnd va vb
{-# INLINE evalBoolAnd #-}

evalBoolOr :: Env -> Expr -> Expr -> Val
evalBoolOr env a b = case eval env a of
  VBoolLit False -> eval env b
  VBoolLit True -> VBoolLit True
  va -> case eval env b of
    VBoolLit False -> va
    VBoolLit True -> VBoolLit True
    vb -> VBoolOr va vb
{-# INLINE evalBoolOr #-}

evalBoolIf :: Env -> Expr -> Expr -> Expr -> Val
evalBoolIf env c t f = case eval env c of
  VBoolLit True -> eval env t
  VBoolLit False -> eval env f
  vc -> VBoolIf vc (eval env t) (eval env f)
{-# INLINE evalBoolIf #-}

evalNatPlus :: Env -> Expr -> Expr -> Val
evalNatPlus env a b = case (eval env a, eval env b) of
  (VNaturalLit 0, vb) -> vb
  (va, VNaturalLit 0) -> va
  (VNaturalLit m, VNaturalLit n) -> VNaturalLit (m + n)
  (va, vb) -> VNaturalPlus va vb
{-# INLINE evalNatPlus #-}

evalNatTimes :: Env -> Expr -> Expr -> Val
evalNatTimes env a b = case (eval env a, eval env b) of
  (VNaturalLit 0, _) -> VNaturalLit 0
  (_, VNaturalLit 0) -> VNaturalLit 0
  (VNaturalLit 1, vb) -> vb
  (va, VNaturalLit 1) -> va
  (VNaturalLit m, VNaturalLit n) -> VNaturalLit (m * n)
  (va, vb) -> VNaturalTimes va vb
{-# INLINE evalNatTimes #-}

evalTextAppend :: Env -> Expr -> Expr -> Val
evalTextAppend env a b = case (eval env a, eval env b) of
  (VTextLit (TextPlain t), vb) | TS.null t -> vb
  (va, VTextLit (TextPlain t)) | TS.null t -> va
  (VTextLit (TextPlain ta), VTextLit (TextPlain tb)) ->
    VTextLit (TextPlain (ta <> tb))
  (va, vb) -> VTextAppend va vb
{-# INLINE evalTextAppend #-}

evalListAppend :: Env -> Expr -> Expr -> Val
evalListAppend env a b = case (eval env a, eval env b) of
  (VListLit _ xs, vb) | Seq.null xs -> vb
  (va, VListLit _ ys) | Seq.null ys -> va
  (VListLit mty xs, VListLit _ ys) -> VListLit mty (xs <> ys)
  (va, vb) -> VListAppend va vb
{-# INLINE evalListAppend #-}

evalCombine :: Env -> Expr -> Expr -> Val
evalCombine env a b = case (eval env a, eval env b) of
  (VRecordLit fs, vb) | null (fieldsToList fs) -> vb
  (va, VRecordLit fs) | null (fieldsToList fs) -> va
  (VRecordLit fa, VRecordLit fb) -> VRecordLit (combineFields fa fb)
  (va, vb) -> VCombine va vb
{-# INLINE evalCombine #-}

evalCombineTypes :: Env -> Expr -> Expr -> Val
evalCombineTypes env a b = case (eval env a, eval env b) of
  (VRecord fs, vb) | null (fieldsToList fs) -> vb
  (va, VRecord fs) | null (fieldsToList fs) -> va
  (VRecord fa, VRecord fb) -> VRecord (combineFields fa fb)
  (va, vb) -> VCombineTypes va vb
{-# INLINE evalCombineTypes #-}

evalPrefer :: Env -> Expr -> Expr -> Val
evalPrefer env a b = case (eval env a, eval env b) of
  (VRecordLit fs, vb) | null (fieldsToList fs) -> vb
  (va, VRecordLit fs) | null (fieldsToList fs) -> va
  (VRecordLit fa, VRecordLit fb) -> VRecordLit (preferFields fa fb)
  (va, vb) -> VPrefer va vb
{-# INLINE evalPrefer #-}

evalMerge :: Val -> Val -> Maybe Val -> Val
evalMerge handlers union mty = case union of
  VInject _ name mval -> case lookupField name (extractHandlers handlers) of
    Just handler -> case mval of
      Just val -> vApp handler val
      Nothing -> handler
    Nothing -> VMerge handlers union mty
  _ -> VMerge handlers union mty
  where
    extractHandlers (VRecordLit fs) = fs
    extractHandlers _ = emptyFields
{-# INLINE evalMerge #-}

--------------------------------------------------------------------------------
-- Value operations
--------------------------------------------------------------------------------

-- | Apply a value to an argument
vApp :: Val -> Val -> Val
vApp !f !x = case f of
  VLam _ _ (VClosure _name env body) ->
    let !env' = extendEnv x env
     in eval env' body
  VPrimFun _ pf -> pf x
  _ -> VApp f x
{-# INLINE vApp #-}

-- | Field access
vField :: Val -> Name -> Val
vField !v !name = case v of
  VRecordLit fields -> case lookupField name fields of
    Just val -> val
    Nothing -> VField v name
  VUnion fields -> case lookupField name fields of
    Just (Just _) -> VPrimFun name $ \x -> VInject fields name (Just x)
    Just Nothing -> VInject fields name Nothing
    Nothing -> VField v name
  _ -> VField v name
{-# INLINE vField #-}

-- | Project fields
vProject :: Val -> [Name] -> Val
vProject !v names
  | null names = VRecordLit emptyFields
  | otherwise = case v of
      VRecordLit fields -> VRecordLit (projectFields names fields)
      _ -> VProject v names
{-# INLINE vProject #-}

-- | With expression
vWith :: Val -> [Name] -> Val -> Val
vWith !_v [] !val = val
vWith !v (name : rest) !val = case v of
  VRecordLit fields ->
    let existing = maybe (VRecordLit emptyFields) id (lookupField name fields)
        updated = vWith existing rest val
     in VRecordLit (insertField name updated fields)
  _ -> VWith v (name : rest) val
{-# INLINE vWith #-}

--------------------------------------------------------------------------------
-- Field operations
--------------------------------------------------------------------------------

combineFields :: Fields Val -> Fields Val -> Fields Val
combineFields = mergeFieldsCombine vCombine
  where
    vCombine (VRecordLit fsa) (VRecordLit fsb) = VRecordLit (combineFields fsa fsb)
    vCombine a b = VCombine a b
{-# INLINE combineFields #-}

preferFields :: Fields Val -> Fields Val -> Fields Val
preferFields = mergeFieldsPrefer
{-# INLINE preferFields #-}

projectFields :: [Name] -> Fields Val -> Fields Val
projectFields names fields =
  fieldsFromSortedList $
    sortOn
      fst
      [(name, val) | name <- names, Just val <- [lookupField name fields]]

--------------------------------------------------------------------------------
-- Builtins
--------------------------------------------------------------------------------

evalBuiltin :: Builtin -> Val
evalBuiltin = \case
  BNatural -> VNatural
  BInteger -> VInteger
  BDouble -> VDouble
  BText -> VText
  BList -> VPrimFun (internName "List") $ \ty -> VList ty
  BOptional -> VPrimFun (internName "Optional") $ \ty -> VOptional ty
  BNone -> VPrimFun (internName "None") $ \ty -> VNone ty
  BSome -> VPrimFun (internName "Some") $ \val -> VSome val
  BBool -> VBool
  BBytes -> error "Bytes type not yet supported"
  BNaturalFold -> VPrimFun (internName "Natural/fold") $ \n ->
    VPrimFun (internName "Natural/fold/1") $ \ty ->
      VPrimFun (internName "Natural/fold/2") $ \succFn ->
        VPrimFun (internName "Natural/fold/3") $ \zero ->
          case n of
            VNaturalLit 0 -> zero
            VNaturalLit m -> go (m - 1) (vApp succFn zero)
              where
                go 0 !acc = acc
                go k !acc = go (k - 1) (vApp succFn acc)
            _ -> VApp (VApp (VApp (VApp (VBuiltin BNaturalFold) n) ty) succFn) zero
  BNaturalBuild -> VPrimFun (internName "Natural/build") $ \f ->
    vApp
      ( vApp
          (vApp f VNatural)
          ( VPrimFun (internName "succ") $ \n -> case n of
              VNaturalLit m -> VNaturalLit (m + 1)
              _ -> VNaturalPlus n (VNaturalLit 1)
          )
      )
      (VNaturalLit 0)
  BNaturalIsZero -> VPrimFun (internName "Natural/isZero") $ \case
    VNaturalLit 0 -> VBoolLit True
    VNaturalLit _ -> VBoolLit False
    n -> VApp (VBuiltin BNaturalIsZero) n
  BNaturalEven -> VPrimFun (internName "Natural/even") $ \case
    VNaturalLit n -> VBoolLit (even n)
    n -> VApp (VBuiltin BNaturalEven) n
  BNaturalOdd -> VPrimFun (internName "Natural/odd") $ \case
    VNaturalLit n -> VBoolLit (odd n)
    n -> VApp (VBuiltin BNaturalOdd) n
  BNaturalToInteger -> VPrimFun (internName "Natural/toInteger") $ \case
    VNaturalLit n -> VIntegerLit (fromIntegral n)
    n -> VApp (VBuiltin BNaturalToInteger) n
  BNaturalShow -> VPrimFun (internName "Natural/show") $ \case
    VNaturalLit n -> VTextLit (TextPlain (TS.fromString (show n)))
    n -> VApp (VBuiltin BNaturalShow) n
  BNaturalSubtract -> VPrimFun (internName "Natural/subtract") $ \x ->
    VPrimFun (internName "Natural/subtract/1") $ \y ->
      case (x, y) of
        (VNaturalLit 0, _) -> y
        (_, VNaturalLit 0) -> VNaturalLit 0
        (VNaturalLit m, VNaturalLit n) ->
          VNaturalLit (if n >= m then n - m else 0)
        _ -> VApp (VApp (VBuiltin BNaturalSubtract) x) y
  BIntegerClamp -> VPrimFun (internName "Integer/clamp") $ \case
    VIntegerLit n | n >= 0 -> VNaturalLit (fromIntegral n)
    VIntegerLit _ -> VNaturalLit 0
    n -> VApp (VBuiltin BIntegerClamp) n
  BIntegerNegate -> VPrimFun (internName "Integer/negate") $ \case
    VIntegerLit n -> VIntegerLit (negate n)
    n -> VApp (VBuiltin BIntegerNegate) n
  BIntegerShow -> VPrimFun (internName "Integer/show") $ \case
    VIntegerLit n | n >= 0 -> VTextLit (TextPlain (TS.fromString ("+" ++ show n)))
    VIntegerLit n -> VTextLit (TextPlain (TS.fromString (show n)))
    n -> VApp (VBuiltin BIntegerShow) n
  BIntegerToDouble -> VPrimFun (internName "Integer/toDouble") $ \case
    VIntegerLit n -> VDoubleLit (fromIntegral n)
    n -> VApp (VBuiltin BIntegerToDouble) n
  BDoubleShow -> VPrimFun (internName "Double/show") $ \case
    VDoubleLit d -> VTextLit (TextPlain (TS.fromString (show d)))
    n -> VApp (VBuiltin BDoubleShow) n
  BTextShow -> VPrimFun (internName "Text/show") $ \case
    VTextLit (TextPlain t) -> VTextLit (TextPlain (TS.fromString (show (TS.toText t))))
    n -> VApp (VBuiltin BTextShow) n
  BTextReplace -> VPrimFun (internName "Text/replace") $ \needle ->
    VPrimFun (internName "Text/replace/1") $ \replacement ->
      VPrimFun (internName "Text/replace/2") $ \haystack ->
        case (needle, replacement, haystack) of
          (VTextLit (TextPlain t), _, h) | TS.null t -> h
          _ -> VApp (VApp (VApp (VBuiltin BTextReplace) needle) replacement) haystack
  BListBuild -> VPrimFun (internName "List/build") $ \ty ->
    VPrimFun (internName "List/build/1") $ \f ->
      vApp
        ( vApp
            (vApp f (VList ty))
            ( VPrimFun (internName "cons") $ \x ->
                VPrimFun (internName "cons/1") $ \xs ->
                  case xs of
                    VListLit mty ys -> VListLit mty (x Seq.<| ys)
                    _ -> VListAppend (VListLit (Just ty) (Seq.singleton x)) xs
            )
        )
        (VListLit (Just ty) Seq.empty)
  BListFold -> VPrimFun (internName "List/fold") $ \ty ->
    VPrimFun (internName "List/fold/1") $ \lst ->
      VPrimFun (internName "List/fold/2") $ \resultTy ->
        VPrimFun (internName "List/fold/3") $ \cons ->
          VPrimFun (internName "List/fold/4") $ \nil ->
            case lst of
              VListLit _ xs -> foldr (\x acc -> vApp (vApp cons x) acc) nil xs
              _ -> VApp (VApp (VApp (VApp (VApp (VBuiltin BListFold) ty) lst) resultTy) cons) nil
  BListLength -> VPrimFun (internName "List/length") $ \_ ->
    VPrimFun (internName "List/length/1") $ \case
      VListLit _ xs -> VNaturalLit (fromIntegral (Seq.length xs))
      lst -> VApp (VApp (VBuiltin BListLength) VNatural) lst
  BListHead -> VPrimFun (internName "List/head") $ \ty ->
    VPrimFun (internName "List/head/1") $ \case
      VListLit _ xs -> case Seq.viewl xs of
        EmptyL -> VNone ty
        (y :< _) -> VSome y
      lst -> VApp (VApp (VBuiltin BListHead) ty) lst
  BListLast -> VPrimFun (internName "List/last") $ \ty ->
    VPrimFun (internName "List/last/1") $ \case
      VListLit _ xs -> case Seq.viewr xs of
        Seq.EmptyR -> VNone ty
        (_ Seq.:> y) -> VSome y
      lst -> VApp (VApp (VBuiltin BListLast) ty) lst
  BListIndexed -> VPrimFun (internName "List/indexed") $ \ty ->
    VPrimFun (internName "List/indexed/1") $ \case
      VListLit _ xs -> VListLit Nothing $ Seq.mapWithIndex mkIndexed xs
        where
          mkIndexed i x =
            VRecordLit $
              fieldsFromList
                [ (internName "index", VNaturalLit (fromIntegral i)),
                  (internName "value", x)
                ]
      lst -> VApp (VApp (VBuiltin BListIndexed) ty) lst
  BListReverse -> VPrimFun (internName "List/reverse") $ \ty ->
    VPrimFun (internName "List/reverse/1") $ \case
      VListLit mty xs -> VListLit mty (Seq.reverse xs)
      lst -> VApp (VApp (VBuiltin BListReverse) ty) lst

--------------------------------------------------------------------------------
-- Normalization (quote back to Expr)
--------------------------------------------------------------------------------

-- | Quote a value back to an expression
quote :: Int -> Val -> Expr
quote !lvl = \case
  VConst c -> EConst c
  VVar k -> EVar (Var (lvl - k - 1)) -- level to index
  VApp f x -> EApp (quote lvl f) (quote lvl x)
  VLam name ty (VClosure _ env body) ->
    let !env' = extendEnv (VVar lvl) env
        !vbody = eval env' body
     in ELam name (quote lvl ty) (quote (lvl + 1) vbody)
  VPi name dom (VClosure _ env body) ->
    let !env' = extendEnv (VVar lvl) env
        !vbody = eval env' body
     in EPi name (quote lvl dom) (quote (lvl + 1) vbody)
  VBool -> EBuiltin BBool
  VBoolLit b -> ELit (LitBool b)
  VBoolAnd a b -> EBoolAnd (quote lvl a) (quote lvl b)
  VBoolOr a b -> EBoolOr (quote lvl a) (quote lvl b)
  VBoolIf c t f -> EBoolIf (quote lvl c) (quote lvl t) (quote lvl f)
  VNatural -> EBuiltin BNatural
  VNaturalLit n -> ELit (LitNat n)
  VNaturalPlus a b -> ENatPlus (quote lvl a) (quote lvl b)
  VNaturalTimes a b -> ENatTimes (quote lvl a) (quote lvl b)
  VInteger -> EBuiltin BInteger
  VIntegerLit n -> ELit (LitInt n)
  VDouble -> EBuiltin BDouble
  VDoubleLit d -> ELit (LitDouble d)
  VText -> EBuiltin BText
  VTextLit (TextPlain t) -> ELit (LitText t)
  VTextLit (TextChunks _ _) -> error "quote: text chunks not yet supported"
  VTextAppend a b -> ETextAppend (quote lvl a) (quote lvl b)
  VList ty -> EApp (EBuiltin BList) (quote lvl ty)
  VListLit mty xs -> EList (fmap (quote lvl) mty) (fmap (quote lvl) xs)
  VListAppend a b -> EListAppend (quote lvl a) (quote lvl b)
  VOptional ty -> EApp (EBuiltin BOptional) (quote lvl ty)
  VSome x -> EApp (EBuiltin BSome) (quote lvl x)
  VNone ty -> EApp (EBuiltin BNone) (quote lvl ty)
  VRecord fields -> ERecord (fmap (quote lvl) fields)
  VRecordLit fields -> ERecordLit (fmap (quote lvl) fields)
  VUnion fields -> EUnion (fmap (fmap (quote lvl)) fields)
  VCombine a b -> ECombine (quote lvl a) (quote lvl b)
  VCombineTypes a b -> ECombineTypes (quote lvl a) (quote lvl b)
  VPrefer a b -> EPrefer (quote lvl a) (quote lvl b)
  VMerge a b mty -> EMerge (quote lvl a) (quote lvl b) (fmap (quote lvl) mty)
  VToMap a mty -> EToMap (quote lvl a) (fmap (quote lvl) mty)
  VField v name -> EField (quote lvl v) name
  VProject v names -> EProject (quote lvl v) names
  VInject fields name mval ->
    let base = EUnion (fmap (fmap (quote lvl)) fields)
     in case mval of
          Just val -> EApp (EField base name) (quote lvl val)
          Nothing -> EField base name
  VAssert e -> EAssert (quote lvl e)
  VEquivalent a b -> EEquivalent (quote lvl a) (quote lvl b)
  VWith v path val -> EWith (quote lvl v) path (quote lvl val)
  VBuiltin b -> EBuiltin b
  VPrimFun _ _ -> error "quote: cannot quote primitive function"

-- | Normalize: eval then quote
normalize :: Expr -> Expr
normalize e = quote 0 (eval emptyEnv e)
{-# INLINE normalize #-}

--------------------------------------------------------------------------------
-- Conversion checking (alpha equivalence of normalized forms)
--------------------------------------------------------------------------------

-- | Check if two values are convertible (alpha-equivalent)
conv :: Int -> Val -> Val -> Bool
conv !lvl v1 v2 = case (v1, v2) of
  (VConst c1, VConst c2) -> c1 == c2
  (VVar k1, VVar k2) -> k1 == k2
  (VApp f1 x1, VApp f2 x2) -> conv lvl f1 f2 && conv lvl x1 x2
  (VLam _ _ cl1, VLam _ _ cl2) ->
    let v = VVar lvl
        b1 = eval (extendEnv v (closureEnv cl1)) (closureBody cl1)
        b2 = eval (extendEnv v (closureEnv cl2)) (closureBody cl2)
     in conv (lvl + 1) b1 b2
  (VPi _ d1 cl1, VPi _ d2 cl2) ->
    conv lvl d1 d2
      && let v = VVar lvl
             b1 = eval (extendEnv v (closureEnv cl1)) (closureBody cl1)
             b2 = eval (extendEnv v (closureEnv cl2)) (closureBody cl2)
          in conv (lvl + 1) b1 b2
  (VBool, VBool) -> True
  (VBoolLit b1, VBoolLit b2) -> b1 == b2
  (VNatural, VNatural) -> True
  (VNaturalLit n1, VNaturalLit n2) -> n1 == n2
  (VInteger, VInteger) -> True
  (VIntegerLit n1, VIntegerLit n2) -> n1 == n2
  (VDouble, VDouble) -> True
  (VDoubleLit d1, VDoubleLit d2) -> d1 == d2
  (VText, VText) -> True
  (VTextLit (TextPlain t1), VTextLit (TextPlain t2)) -> t1 == t2
  (VList t1, VList t2) -> conv lvl t1 t2
  (VListLit _ xs1, VListLit _ xs2) ->
    Seq.length xs1 == Seq.length xs2 && and (Seq.zipWith (conv lvl) xs1 xs2)
  (VOptional t1, VOptional t2) -> conv lvl t1 t2
  (VSome x1, VSome x2) -> conv lvl x1 x2
  (VNone t1, VNone t2) -> conv lvl t1 t2
  (VRecord fs1, VRecord fs2) -> convFields lvl fs1 fs2
  (VRecordLit fs1, VRecordLit fs2) -> convFields lvl fs1 fs2
  (VUnion fs1, VUnion fs2) -> convFieldsMaybe lvl fs1 fs2
  (VBuiltin b1, VBuiltin b2) -> b1 == b2
  _ -> False

convFields :: Int -> Fields Val -> Fields Val -> Bool
convFields lvl fs1 fs2 =
  let ps1 = fieldsToList fs1
      ps2 = fieldsToList fs2
   in length ps1 == length ps2
        && all (\((k1, v1), (k2, v2)) -> k1 == k2 && conv lvl v1 v2) (zip ps1 ps2)

convFieldsMaybe :: Int -> Fields (Maybe Val) -> Fields (Maybe Val) -> Bool
convFieldsMaybe lvl fs1 fs2 =
  let ps1 = fieldsToList fs1
      ps2 = fieldsToList fs2
   in length ps1 == length ps2
        && all (\((k1, v1), (k2, v2)) -> k1 == k2 && convMaybe lvl v1 v2) (zip ps1 ps2)
  where
    convMaybe _ Nothing Nothing = True
    convMaybe l (Just a) (Just b) = conv l a b
    convMaybe _ _ _ = False
