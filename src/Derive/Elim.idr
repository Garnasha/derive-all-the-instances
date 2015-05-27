module Derive.Elim

import Data.Vect
import Data.So
--import Data.Nat

import Derive.Kit
import Language.Reflection.Elab
import Language.Reflection.Utils

||| A representation of a type constructor in which all argument names
||| are made unique and they are separated into params and then
||| indices.
record TyConInfo where
  constructor MkTyConInfo
  ||| Invariant: the names of the args have been made unique
  args : List TyConArg
  ||| The type constructor, applied to its arguments
  result : Raw

getParams : TyConInfo -> List (TTName, Raw)
getParams info = mapMaybe param (args info)
  where param : TyConArg -> Maybe (TTName, Raw)
        param (Parameter n t) = Just (n, t)
        param _ = Nothing

getIndices : TyConInfo -> List (TTName, Raw)
getIndices info = mapMaybe index (args info)
  where index : TyConArg -> Maybe (TTName, Raw)
        index (Index n t) = Just (n, t)
        index _ = Nothing

||| Rename a bound variable across a telescope
renameIn : (from, to : TTName) -> List (TTName, Raw) -> List (TTName, Raw)
renameIn from to [] = []
renameIn from to ((n, ty)::tele) =
    (n, alphaRaw (rename from to) ty) ::
      if from == n
        then tele
        else renameIn from to tele

||| Rename a free variable in type constructor info (used to implement
||| alpha-conversion for unique binder names, hence the odd name)
alphaTyConInfo : (TTName -> Maybe TTName) -> TyConInfo -> TyConInfo
alphaTyConInfo ren (MkTyConInfo [] res) = MkTyConInfo [] (alphaRaw ren res)
alphaTyConInfo ren (MkTyConInfo (tcArg::tcArgs) res) =
  let MkTyConInfo tcArgs' res' = alphaTyConInfo (restrict ren (tyConArgName tcArg)) (MkTyConInfo tcArgs res)
      tcArg' = updateTyConArgTy (alphaRaw ren) tcArg
  in MkTyConInfo (tcArg'::tcArgs') res'

getTyConInfo' : List TyConArg -> Raw -> (TTName -> Maybe TTName) -> Elab TyConInfo
getTyConInfo' [] res _ = return (MkTyConInfo [] res)
getTyConInfo' (tcArg::tcArgs) res ren =
  do let n = tyConArgName tcArg
     n' <- nameFrom n
     -- n' is globally unique so we don't worry about scope
     next <- getTyConInfo' tcArgs (RApp res (Var n')) (extend ren n n')
     return $ record {args = setTyConArgName tcArg n' :: args next} next

getTyConInfo : List TyConArg -> Raw -> Elab TyConInfo
getTyConInfo args res = getTyConInfo' args res (const Nothing)


bindParams : TyConInfo -> Elab ()
bindParams info = traverse_ (uncurry forall) (getParams info)

||| Bind indices at new names and return a renamer that's used to
||| rewrite an application of something to their designated global
||| names
bindIndices : TyConInfo -> Elab (TTName -> Maybe TTName)
bindIndices info = do ns <- traverse bindI (getIndices info)
                      return $ foldr (\(n,n'), ren => extend ren n n') (const Nothing) ns
  where bindI : (TTName, Raw) -> Elab (TTName, TTName)
        bindI (n, t) = do n' <- nameFrom n
                          forall n' t
                          return (n, n')

||| Return the renaming required to use the result type for this binding of the indices
bindTarget : TyConInfo -> Elab (TTName, (TTName -> Maybe TTName))
bindTarget info = do ren <- bindIndices info
                     tn <- gensym "target"
                     forall tn (alphaRaw ren $ result info)
                     return (tn, ren)

elabMotive : TyConInfo -> Elab ()
elabMotive info = do attack
                     ren <- bindIndices info
                     x <- gensym "scrutinee"
                     forall x (alphaRaw ren $ result info)
                     apply `(Type)
                     solve -- the attack
                     solve -- the motive type hole

||| Point ctor arguments that are parameters at the global param
||| quantification.
|||
||| We keep the other arguments, such as indices, but assign them
||| unique names so we don't have to worry about shadowing later.
removeParams : TyConInfo -> Raw -> Elab (List (Either TTName (TTName, Raw)), Raw)
removeParams info ctorTy =
  do (args, res) <- stealBindings ctorTy (const Nothing)
     return $ killParams (map (\(n, b) => (n, getBinderTy b)) args)
                         res
  where isParamName : TTName -> Maybe TTName
        isParamName name = if elem name (map fst $ getParams info)
                             then Just name
                             else Nothing

        isParamIn : (argn : TTName) -> (resty : Raw) -> (infoTy : Raw) -> Maybe TTName
        isParamIn argn (RApp f (Var x)) (RApp g (Var y)) =
          if argn == x
            then isParamName y
            else isParamIn argn f g
        isParamIn argn (RApp f _) (RApp g _) = isParamIn argn f g
        isParamIn _ (Var _) (Var _) = Nothing
        isParamIn argn resty infoTy = Nothing -- shouldn't happen - TODO fail ["error checking param name"]

        killParams : List (TTName, Raw) -> Raw -> (List (Either TTName (TTName, Raw)), Raw)
        killParams [] res = ([], res)
        killParams ((n,t)::args) res =
          let (args', res') = killParams args res
          in case isParamIn n res' (result info) of
               Just glob => (Left glob :: map (renIndex n glob) args',
                             alphaRaw (rename n glob) res')
               Nothing => (Right (n, t) :: args', res')
          where renIndex : TTName -> TTName -> Either TTName (TTName, Raw) -> Either TTName (TTName, Raw)
                renIndex n glob (Right (n', t)) = Right (n', alphaRaw (rename n glob) t)
                renIndex _ _ (Left p) = Left p

||| Apply the motive for elimination to some subject, inferring the
||| values of the indices from the type of the subject.
applyMotive : TyConInfo -> (motive : Raw) -> (arg, argTy : Raw) -> Raw
applyMotive info motive arg argTy =
  mkApp motive $
        map snd (filter (isIndex . fst) (zip' (args info) (snd (unApply argTy)))) ++
        [arg]
  where zip' : List a -> List b -> List (a, b)
        zip' [] _ = []
        zip' _ [] = []
        zip' (x::xs) (y::ys) = (x, y) :: zip' xs ys
        isIndex : TyConArg -> Bool
        isIndex (Index _ _) = True
        isIndex _ = False

headVar : Raw -> Maybe TTName
headVar (RApp f _) = headVar f
headVar (Var n) = Just n
headVar x = Nothing

headsMatch : Raw -> Raw -> Bool
headsMatch x y =
  case (headVar x, headVar y) of
    (Just n1, Just n2) => n1 == n2
    _ => False

elabMethodTy : TyConInfo -> TTName -> List (Either TTName (TTName, Raw)) -> Raw -> Raw -> Elab ()
elabMethodTy info motiveName [] res ctorApp =
  do apply $ applyMotive info (Var motiveName) ctorApp res
     solve
elabMethodTy info motiveName (Left paramN  :: args) res ctorApp =
  elabMethodTy info motiveName args  res (RApp ctorApp (Var paramN))
elabMethodTy info motiveName (Right (n, t) :: args) res ctorApp =
  do attack; forall n t
     if headsMatch t (result info)
       then do arg <- newHole "arg" t
               ih <- gensym "ih"
               ihT <- newHole "ihT" `(Type)
               forall ih (Var ihT)
               focus ihT
               apply $ applyMotive info (Var motiveName) (Var arg) t
               solve
               focus arg
               apply (Var n); solve
       else return ()
     elabMethodTy info motiveName args res (RApp ctorApp (Var n))
     solve




elabMethod : TyConInfo -> (motiveName, ctorN : TTName) -> Raw -> Elab ()
elabMethod info motiveName ctorN cty =
  do (args', resTy) <- removeParams info cty
     elabMethodTy info motiveName args' resTy (Var ctorN)


||| Bind a method for a constructor
bindMethod : TyConInfo -> (motiveName, cn : TTName) -> Raw -> Elab ()
bindMethod info motiveName cn cty =
  do n <- nameFrom cn
     h <- newHole "methTy" `(Type)
     forall n (Var h)
     focus h; elabMethod info motiveName cn cty

getElimTy : TyConInfo -> List (TTName, Raw) -> Elab Raw
getElimTy info ctors =
  do ty <- runElab `(Type) $
             do bindParams info
                (scrut, iren) <- bindTarget info
                motiveN <- gensym "P"
                motiveH <- newHole "motive" `(Type)
                forall motiveN (Var motiveH)
                focus motiveH
                elabMotive info
                traverse_ (uncurry (bindMethod info motiveN)) ctors
                let ret = mkApp (Var motiveN)
                                (map (Var . fst)
                                     (getIndices info) ++
                                 [Var scrut])
                apply (alphaRaw iren ret)
                solve
     forgetTypes (fst ty)

getSigmaArgs : Raw -> Elab (Raw, Raw)
getSigmaArgs `(MkSigma {a=~_} {P=~_} ~rhsTy ~lhs) = return (rhsTy, lhs)
getSigmaArgs arg = fail [TextPart "Not a sigma constructor"]

getElimClause : TyConInfo -> (elimn : TTName) -> (methCount : Nat) ->
                (TTName, Raw) -> Nat -> Elab FunClause
getElimClause info elimn methCount (cn, cty) whichCon =
  do (args, resTy) <- removeParams info cty
     pat <- runElab `(Sigma Type id) $
              do -- First set up the machinery to infer the type of the LHS
                 th <- newHole "finalTy" `(Type)
                 patH <- newHole "pattern" (Var th)
                 fill `(MkSigma {a=Type} {P=id} ~(Var th) ~(Var patH))
                 solve
                 focus patH

                 -- Establish a hole for each parameter
                 traverse {b=()} (\(n, ty) => do claim n ty
                                                 unfocus n)
                          (getParams info)

                 -- Establish a hole for each argument to the constructor
                 traverse {b=()} (\arg => case arg of
                                            Left _ => return ()
                                            Right (n, ty) => do claim n ty
                                                                unfocus n)
                   args

                 -- Establish a hole for the scrutinee (infer type)
                 scrutinee <- newHole "scrutinee" resTy

                 -- Apply the eliminator to the proper holes
                 let paramApp : Raw = mkApp (Var elimn) $
                                      map (Var . fst) (getParams info)
                 let indexApp : Raw =
                       applyMotive info paramApp (Var scrutinee) resTy

                 -- We leave the RHS with a function type: motive -> method* -> res
                 -- to make it easier to map methods to constructors
                 apply indexApp
                 solve

                 -- Turn all remaining holes into pattern variables
                 -- traverse {b=()} (\(h, t) => do focus h ; patvar h)
                 --          (getParams info)
                 traverse {b=()} (\h => do focus h ; patvar h) !getHoles
                 return ()

     (pvars, sigma) <- stealBindings !(forgetTypes (fst pat)) (const Nothing)
     (rhsTy, lhs) <- getSigmaArgs sigma
     rhs <- runElab (bindPatTys pvars rhsTy) $
              do repeatUntilFail bindPat
                 motiveN <- gensym "motive"
                 intro (Just motiveN)
                 prevMethods <- doTimes whichCon intro1
                 methN <- gensym "useThisMethod"
                 intro (Just methN)
                 nextMethods <- intros
                 apply (Var methN) ; solve
     realRhs <- forgetTypes (fst rhs)
     return $ MkFunClause (bindPats pvars lhs) realRhs
--     debugMessage (show lhs)

getElimClauses : TyConInfo -> (elimn : TTName) ->
                 List (TTName, Raw) -> Elab (List FunClause)
getElimClauses info elimn ctors =
  let methodCount = length ctors
  in traverse (\(i, con) => getElimClause info elimn methodCount con i) (reverse $ enumerate ctors)

instance Show FunClause where
  show (MkFunClause x y) = "(MkFunClause " ++ show x ++ " " ++ show y ++ ")"
  show (MkImpossibleClause x) = "(MkImpossibleClause " ++ show x ++ ")"

deriveElim : (tyn, elimn : TTName) -> Elab ()
deriveElim tyn elimn =
  do -- Begin with some basic sanity checking
     -- 1. The type name uniquely determines a datatype
     (MkDatatype tyn tyconArgs tyconRes ctors) <- lookupDatatypeExact tyn
     info <- getTyConInfo tyconArgs (Var tyn)
     declareType $ Declare elimn [] !(getElimTy info ctors)
     clauses <- getElimClauses info elimn ctors
--     debugMessage {a=()} (show (take 1 clauses))
     defineFunction $ DefineFun elimn clauses
     return ()

||| A strict less-than relation on `Nat`.
|||
||| @ n the smaller number
||| @ m the larger number
data LT' : (n,m : Nat) -> Type where
  ||| n < 1 + n
  LTSucc : LT' n (S n)
  ||| n < m implies that n < m + 1
  LTStep : LT' n m -> LT' n (S m)


forEffect : ()
forEffect = %runElab (deriveElim `{Vect} (NS (UN "vectElim") ["Elim", "Derive"]) *> trivial)

-- vectElim a Z Nil P nil cons = nil
-- vectElim a (S n) ((::) {a=a} {n=n} x xs) P nil cons = cons n x xs (vectElim a n xs P nil cons)