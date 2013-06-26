{-# LANGUAGE ConstraintKinds, DeriveFunctor #-}

module Lamdu.CodeEdit.Sugar.Convert.Hole
  ( convert, convertPlain, orderedInnerHoles
  ) where

import Control.Applicative (Applicative(..), (<$>), (<$))
import Control.Lens.Operators
import Control.Monad (MonadPlus(..), guard, join, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (runState, mapStateT)
import Control.Monad.Trans.Writer (execWriter)
import Control.MonadA (MonadA)
import Data.Binary (Binary)
import Data.Hashable (Hashable, hashWithSalt)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Monoid (Monoid(..))
import Data.Store.Guid (Guid)
import Data.Store.IRef (Tag)
import Data.Traversable (sequenceA, traverse)
import Data.Tuple (swap)
import Data.Typeable (Typeable1)
import Lamdu.CodeEdit.Sugar.Infer (InferredWC, Stored)
import Lamdu.CodeEdit.Sugar.Internal
import Lamdu.CodeEdit.Sugar.Monad (SugarM)
import Lamdu.CodeEdit.Sugar.Types
import Lamdu.CodeEdit.Sugar.Types.Internal
import Lamdu.Data.Expression.IRef (DefM)
import Lamdu.Data.Expression.Infer.Conflicts (InferredWithConflicts(..), iwcInferred, iwcInferredValues)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.Cache as Cache
import qualified Data.Foldable as Foldable
import qualified Data.Map as Map
import qualified Data.Store.IRef as IRef
import qualified Data.Store.Property as Property
import qualified Data.Store.Transaction as Transaction
import qualified Lamdu.CodeEdit.Sugar.Expression as SugarExpr
import qualified Lamdu.CodeEdit.Sugar.Infer as SugarInfer
import qualified Lamdu.CodeEdit.Sugar.Monad as SugarM
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Definition as Definition
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Expression.IRef as ExprIRef
import qualified Lamdu.Data.Expression.Infer as Infer
import qualified Lamdu.Data.Expression.Lens as ExprLens
import qualified Lamdu.Data.Expression.Utils as ExprUtil
import qualified Lamdu.Data.Ops as DataOps
import qualified System.Random as Random

convert ::
  (MonadA m, Typeable1 m, Monoid a) =>
  SugarInfer.PayloadMM m a -> SugarM m (ExpressionU m a)
convert =
  convertH convertTypeCheckedHoleH
  <&> Lens.mapped . rPayload . plActions . Lens._Just . mSetToHole .~ Nothing

convertPlain ::
  (MonadA m, Typeable1 m, Monoid a) =>
  SugarInfer.PayloadMM m a -> SugarM m (ExpressionU m a)
convertPlain = convertH convertPlainTyped

convertH ::
  (MonadA m, Typeable1 m) =>
  (SugarInfer.Payload (InferredWC (Tag m)) (Maybe (Stored m)) a ->
   SugarM m (ExpressionU m a)) ->
  SugarInfer.PayloadMM m a ->
  SugarM m (ExpressionU m a)
convertH convertTyped exprPl =
  fixWrap <$>
  maybe convertUntypedHole convertTyped (Lens.sequenceOf SugarInfer.plInferred exprPl)
  where
    fixWrap expr =
      expr
      & rPayload . plActions . Lens.mapped . wrap .~
        AlreadyWrapped (expr ^. rPayload . plGuid)
    convertUntypedHole =
      SugarExpr.make exprPl . BodyHole $ Hole Nothing Nothing

mkPaste :: MonadA m => Stored m -> SugarM m (Maybe (T m Guid))
mkPaste exprP = do
  clipboardsP <- SugarM.codeAnchor Anchors.clipboards
  clipboards <- SugarM.getP clipboardsP
  let
    mClipPop =
      case clipboards of
      [] -> Nothing
      (clip : clips) -> Just (clip, Transaction.setP clipboardsP clips)
  return $ doPaste (Property.set exprP) <$> mClipPop
  where
    doPaste replacer (clipDefI, popClip) = do
      clipDef <- Transaction.readIRef clipDefI
      let
        clip =
          case clipDef of
          Definition.Definition (Definition.BodyExpression defExpr) _ -> defExpr
          _ -> error "Clipboard contained a non-expression definition!"
      Transaction.deleteIRef clipDefI
      ~() <- popClip
      ~() <- replacer clip
      return $ ExprIRef.exprGuid clip

convertTypeCheckedHoleH ::
  (MonadA m, Typeable1 m, Monoid a) =>
  SugarInfer.Payload (InferredWC (Tag m)) (Maybe (Stored m)) a ->
  SugarM m (ExpressionU m a)
convertTypeCheckedHoleH exprPl =
  chooseHoleType (iwcInferredValues (exprPl ^. SugarInfer.plInferred))
  (convertPlainTyped exprPl)
  (convertInferred exprPl)

accept ::
  (MonadA m, Typeable1 m, Binary a, Cache.Key a) =>
  SugarM.Context m ->
  Infer.InferNode (DefM m) ->
  ExprIRef.ExpressionM m a ->
  ExprIRef.ExpressionIM m ->
  T m (Maybe Guid)
accept sugarContext point expr iref = do
  (exprInferred, _) <-
    Cache.unmemoS $
    unjust "The inferred value of a hole must type-check!" <$>
    SugarM.memoLoadInferInHoleContext sugarContext expr point
  fmap fst . pickResult iref $
    flip (,) Nothing <$> cleanUpInferredVal (fst <$> exprInferred)

convertInferred ::
  (MonadA m, Typeable1 m, Monoid a) =>
  SugarInfer.Payload (InferredWC (Tag m)) (Maybe (Stored m)) a ->
  ExprIRef.ExpressionM m () ->
  SugarM m (ExpressionU m a)
convertInferred exprPl wvInferredVal = do
  sugarContext <- SugarM.readContext
  hole <- mkHole exprPl
  val <-
    SugarM.convertSubexpression $
    SugarInfer.mkExprPure wvInferredValGen wvInferredVal
  -- wvInferredVal uses wvInferContext, but for "accept" purposes, we
  -- must use the holeInferContext:
  SugarExpr.make (exprPl & SugarInfer.plInferred %~ Just) $
    BodyInferred Inferred
    { _iHole = hole
    , _iValue = (mempty <$) <$> val
    , _iMAccept =
      fmap (fromMaybe eGuid) .
      accept sugarContext (Infer.iPoint inferred) inferredVal .
      Property.value <$> exprPl ^. SugarInfer.plStored
    }
  where
    wvInferredValGen = genFromHashable (eGuid, show (void wvInferredVal))
    inferredVal =
      ExprUtil.structureForType . void $ Infer.iType inferred
    inferred = iwcInferred $ exprPl ^. SugarInfer.plInferred
    eGuid = exprPl ^. SugarInfer.plGuid

convertPlainTyped ::
  (MonadA m, Typeable1 m, Monoid a) =>
  SugarInfer.Payload (InferredWC (Tag m)) (Maybe (Stored m)) a ->
  SugarM m (ExpressionU m a)
convertPlainTyped exprPl =
  SugarExpr.make (exprPl & SugarInfer.plInferred %~ Just) .
  BodyHole =<< mkHole exprPl

mkHole ::
  (MonadA m, Typeable1 m, Monoid a) =>
  SugarInfer.Payload (InferredWC (Tag m)) (Maybe (Stored m)) a ->
  SugarM m (Hole MStoredName m (ExpressionU m a))
mkHole exprPl = do
  sugarContext <- SugarM.readContext
  mPaste <- fmap join . traverse mkPaste $ exprPl ^. SugarInfer.plStored
  let
    cp = sugarContext ^. SugarM.scCodeAnchors
    mkWritableHoleActions exprPlStored = do
      globals <-
        SugarM.liftTransaction . Transaction.getP $ Anchors.globals cp
      tags <-
        SugarM.liftTransaction . Transaction.getP $ Anchors.tags cp
      pure HoleActions
        { _holePaste = mPaste
        , _holeMUnwrap = Nothing
        , _holeScope =
          mconcat . concat <$> sequence
          [ mapM (getScopeElement sugarContext) . Map.toList $
            Infer.iScope inferred
          , mapM getGlobal globals
          , mapM getTag tags
          ]
        , _holeInferredType = void $ Infer.iType inferred
        , holeLoadInferExprType = inferOnTheSide sugarContext $ Infer.nScope point
        , holeResult = makeHoleResult sugarContext exprPlStored
        }
  mActions <-
    exprPl
    & SugarInfer.plData .~ ()
    & Lens.sequenceOf SugarInfer.plStored
    & traverse mkWritableHoleActions
  pure Hole
    { _holeMActions = mActions
    , _holeMArg = Nothing
    }
  where
    point = Infer.iPoint inferred
    inferred = iwcInferred $ exprPl ^. SugarInfer.plInferred

cleanUpInferredVal ::
  Expr.Expression defa (Infer.Inferred defb) ->
  Expr.Expression defa (Infer.Inferred defb)
cleanUpInferredVal =
  (ExprLens.exprKindedLam Val . Lens._2 . Expr.eBody .~ bodyHole) .
  (ExprLens.exprApply . Lens.filtered isDependentApply .
   Expr.applyArg . Expr.eBody .~ bodyHole) .
  (Expr.eBody . Lens.traversed %~ cleanUpInferredVal)
  where
    isDependentApply =
      ExprUtil.isDependentPi . Infer.iType .
      (^. Expr.applyFunc . Expr.ePayload)
    bodyHole = ExprLens.bodyHole # ()

chooseHoleType ::
  [ExprIRef.ExpressionM m f] -> hole -> (ExprIRef.ExpressionM m f -> hole) -> hole
chooseHoleType inferredVals plain inferred =
  case inferredVals of
  [Expr.Expression { Expr._eBody = Expr.BodyLeaf Expr.Hole }] -> plain
  [inferredVal] -> inferred inferredVal
  _ -> plain

inferOnTheSide ::
  (MonadA m, Typeable1 m, Binary a, Cache.Key a) =>
  SugarM.Context m ->
  Infer.Scope (DefM m) ->
  ExprIRef.ExpressionM m a ->
  CT m
  (Maybe
   ( ExprIRef.ExpressionM m (Infer.Inferred (DefM m), a)
   , Infer.Context (DefM m)
   ))
-- token represents the given holeInferContext
inferOnTheSide sugarContext scope expr =
  -- We can use the same inferStateKey despite making a new node here,
  -- because we haven't altered the context in a meaningful way, we've
  -- added an independent node. This won't collide with inference at
  -- the hole point because the point is an input to the memo.
  SugarInfer.memoLoadInfer Nothing expr inferStateKey . swap $
  runState newNode inferState
  where
    newNode = Infer.newNodeWithScope scope
    inferState = sugarContext ^. SugarM.scHoleInferState
    inferStateKey = sugarContext ^. SugarM.scHoleInferStateKey

getScopeElement ::
  MonadA m => SugarM.Context m ->
  (Guid, Expr.Expression def a) -> T m (Scope MStoredName m)
getScopeElement sugarContext (parGuid, typeExpr) = do
  scopePar <- mkGetPar
  mconcat . (scopePar :) <$>
    mapM onScopeField
    (typeExpr ^..
     -- TODO: Use exprKindedRecordFields Type!
     ExprLens.exprRecord . Expr.recordFields . traverse . Lens._1 . ExprLens.exprTag)
  where
    mkGetPar =
      case Map.lookup parGuid recordParamsMap of
      Just (SugarM.RecordParamsInfo defGuid jumpTo) -> do
        defName <- SugarExpr.getStoredName defGuid
        pure mempty
          { _scopeGetParams = [
            ( GetParams
              { _gpDefGuid = defGuid
              , _gpDefName = defName
              , _gpJumpTo = jumpTo
              }
            , getParam )
          ] }
      Nothing -> do
        parName <- SugarExpr.getStoredName parGuid
        pure mempty
          { _scopeLocals = [
            ( GetVar
              { _gvIdentifier = parGuid
              , _gvName = parName
              , _gvJumpTo = errorJumpTo
              , _gvVarType = GetParameter
              }
            , getParam )
          ] }
    recordParamsMap = sugarContext ^. SugarM.scRecordParamsInfos
    errorJumpTo = error "Jump to on scope item??"
    exprTag = ExprUtil.pureExpression . Expr.BodyLeaf . Expr.Tag
    getParam = ExprLens.pureExpr . ExprLens.bodyParameterRef # parGuid
    onScopeField tGuid = do
      name <- SugarExpr.getStoredName tGuid
      pure mempty
        { _scopeLocals = [
          ( GetVar
            { _gvIdentifier = tGuid
            , _gvName = name
            , _gvJumpTo = errorJumpTo
            , _gvVarType = GetFieldParameter
            }
          , ExprUtil.pureExpression . Expr.BodyGetField $
            Expr.GetField getParam (exprTag tGuid)
          )
        ] }

getGlobal :: MonadA m => DefM m -> T m (Scope MStoredName m)
getGlobal defI = do
  name <- SugarExpr.getStoredName guid
  pure mempty
    { _scopeGlobals = [
      ( GetVar
        { _gvIdentifier = guid
        , _gvName = name
        , _gvJumpTo = errorJumpTo
        , _gvVarType = GetDefinition
        }
      , ExprLens.pureExpr . ExprLens.bodyDefinitionRef # defI
      )
      ] }
  where
    guid = IRef.guid defI
    errorJumpTo = error "Jump to on scope item??"

getTag :: MonadA m => Guid -> T m (Scope MStoredName m)
getTag guid = do
  name <- SugarExpr.getStoredName guid
  pure mempty
    { _scopeTags = [
      ( TagG
        { _tagGuid = guid
        , _tagName = name
        }
      , ExprLens.pureExpr . ExprLens.bodyTag # guid
      )
    ] }

seedExprEnv ::
  MonadA m =>
  a -> Anchors.CodeProps m -> HoleResultSeed m a ->
  T m (ExprIRef.ExpressionM m a, Maybe (T m Guid))
seedExprEnv _ _ (ResultSeedExpression expr) = pure (expr, Nothing)
seedExprEnv emptyPl cp (ResultSeedNewTag name) = do
  tag <- DataOps.makeNewPublicTag cp name
  pure (emptyPl <$ ExprLens.pureExpr . ExprLens.bodyTag # tag, Nothing)
seedExprEnv emptyPl cp (ResultSeedNewDefinition name) = do
  defI <- DataOps.newPublicDefinition cp name
  let jumpToDef =
        IRef.guid defI <$ DataOps.newPane cp defI
  pure
    ( emptyPl <$ ExprLens.pureExpr . ExprLens.bodyDefinitionRef # defI
    , Just jumpToDef
    )

-- TODO: Does this Applicative Transformer already exist?
-- If not, think of a proper name for it.
data Blah f a = Blah { runBlah :: f () }
  deriving Functor
instance Applicative f => Applicative (Blah f) where
  Blah x <*> Blah y = Blah $ x <* y
  pure = const . Blah $ pure ()

idTranslations ::
  Eq def =>
  Expr.Expression def Guid ->
  Expr.Expression def (ExprIRef.ExpressionI t) ->
  [(Guid, Guid)]
idTranslations seedExpr writtenExpr =
  execWriter . runBlah $
  ExprUtil.matchExpression match ((const . const . Blah . return) ())
  seedExpr writtenExpr
  where
    match src dstI = Blah $ Writer.tell [(src, ExprIRef.exprGuid dstI)]

makeHoleResult ::
  (Typeable1 m, MonadA m, Cache.Key a, Binary a, Monoid a) =>
  SugarM.Context m ->
  SugarInfer.Payload (InferredWC (Tag m)) (Stored m) () ->
  HoleResultSeed m (MStorePoint m a) ->
  CT m (Maybe (HoleResult MStoredName m a))
makeHoleResult sugarContext (SugarInfer.Payload guid iwc stored ()) seed =
  mapStateT Transaction.forkScratch $ do
    (fakeSeedExpr, fakeMInferredExprCtx, _fakeMJumpTo) <-
      makeInferredExpr
    traverse (mkHoleResult fakeSeedExpr) fakeMInferredExprCtx
  where
    iref = Property.value stored
    gen = genFromHashable (guid, seedHashable seed)
    cp = sugarContext ^. SugarM.scCodeAnchors
    mkSeedExprEnv = seedExprEnv (Nothing, mempty) cp seed
    makeInferredExpr = do
      (seedExpr, mJumpTo) <- lift mkSeedExprEnv
      mInferredExpr <- SugarM.memoLoadInferInHoleContext sugarContext seedExpr holePoint
      return (seedExpr, mInferredExpr, mJumpTo)
    holePoint = Infer.iPoint $ iwcInferred iwc
    mkHoleResult fakeSeedExpr (fakeInferredResult, fakeCtx) = do
      let
        newContext =
          sugarContext
          & SugarM.scHoleInferState .~ fakeCtx
          & SugarM.scHoleInferStateKey %~ \key -> Cache.bsOfKey (fakeSeedExpr, key)
        expr = prepareExprToSugar gen fakeInferredResult
        mkTranslations = idTranslations ((^. SugarInfer.plGuid) <$> expr)
      fakeConverted <- convertHoleResult newContext expr
      pure HoleResult
        { _holeResultInferred = fst <$> fakeInferredResult
        , _holeResultConverted = fakeConverted
        , _holeResultPick = pick mkTranslations
        , _holeResultPickPrefix = void $ pick mkTranslations
        , _holeResultPickWrapped = do
            (seedExpr, _mJumpTo) <- mkSeedExprEnv
            written <-
              writeExprMStored iref $
              flip (,) () <$> holeWrap (fst <$> seedExpr)
            pure
              PickedResult
              { _prMJumpTo = Just . ExprIRef.exprGuid $ written ^. Expr.ePayload . Lens._1
              , _prIdTranslation = mkTranslations $ fst <$> written
              }
        , _holeResultHasHoles =
          not . null . uninferredHoles $ (,) () . fst <$> fakeInferredResult
        }
    pick mkTranslations = do
      (_seedExpr, mFinalExprCtx, mJumpTo) <- Cache.unmemoS makeInferredExpr
      let
        (finalExpr, _ctx) =
          -- TODO: Makes no sense here anymore, move deeper inside
          -- makeInferredExpr:
          unjust
          ("Arbitrary fake tag successfully inferred as hole result, " ++
           "but real new tag failed!")
          mFinalExprCtx
      (mPickGuid, written) <- pickResult iref $ (Lens._2 %~ fst) <$> finalExpr
      mJumpGuid <- sequenceA mJumpTo
      pure
        PickedResult
        { _prMJumpTo = mJumpGuid `mplus` mPickGuid
        , _prIdTranslation = mkTranslations written
        }

holeWrap :: Expr.Expression def (Maybe a) -> Expr.Expression def (Maybe a)
holeWrap expr
  | Lens.has (ExprLens.exprApply . Expr.applyFunc . ExprLens.exprHole) expr =
    -- Don't rewrap already hole-wrapped results.
    expr
  | otherwise = Expr.Expression (ExprUtil.makeApply hole expr) Nothing
  where
    hole = Expr.Expression (ExprLens.bodyHole # ()) Nothing

convertHoleResult ::
  (MonadA m, Monoid a) =>
  SugarM.Context m -> SugarInfer.ExprMM m a -> CT m (ExpressionU m a)
convertHoleResult sugarContext =
  SugarM.run sugarContext . SugarM.convertSubexpression

prepareExprToSugar ::
  Random.StdGen ->
  Expr.Expression def (Infer.Inferred def, (Maybe (StorePoint t), a)) ->
  Expr.Expression def (SugarInfer.Payload (Maybe (InferredWithConflicts def)) (Maybe stored) a)
prepareExprToSugar gen =
  ExprUtil.randomizeExpr gen . fmap f
  where
    f (inferred, (mStorePoint, x)) guid = SugarInfer.Payload
      { SugarInfer._plGuid =
        case mStorePoint of
        Just storePoint -> ExprIRef.exprGuid $ unStorePoint storePoint
        Nothing -> guid
      , SugarInfer._plInferred =
        Just InferredWithConflicts
        { iwcInferred = inferred
        , iwcTypeConflicts = []
        , iwcValueConflicts = []
        }
      , SugarInfer._plStored = Nothing
      , SugarInfer._plData = x
      }

genFromHashable :: Hashable a => a -> Random.StdGen
genFromHashable = Random.mkStdGen . hashWithSalt 0

seedHashable :: HoleResultSeed m a -> String
seedHashable (ResultSeedExpression expr) = show (void expr)
-- We want the new tag to have the same anim ids even as the name
-- changes, thus we ignore the name:
seedHashable (ResultSeedNewTag _) = "NewTag"
seedHashable (ResultSeedNewDefinition _) = "NewDefinition"

unjust :: String -> Maybe a -> a
unjust = fromMaybe . error

pickResult ::
  MonadA m =>
  ExprIRef.ExpressionIM m ->
  ExprIRef.ExpressionM m (Infer.Inferred (DefM m), Maybe (StorePoint (Tag m))) ->
  T m (Maybe Guid, ExprIRef.ExpressionM m (ExprIRef.ExpressionIM m))
pickResult exprIRef expr = do
  writtenExpr <- writeExprMStored exprIRef $ swap <$> expr
  pure
    ( (ExprIRef.exprGuid . (^. Expr.ePayload . Lens._1)) <$>
      listToMaybe (orderedInnerHoles writtenExpr)
    , fst <$> writtenExpr
    )

randomizeNonStoredParamIds ::
  Random.StdGen -> ExprStorePoint m a -> ExprStorePoint m a
randomizeNonStoredParamIds gen =
  ExprUtil.randomizeParamIdsG id nameGen Map.empty $ \_ _ pl -> pl
  where
    nameGen = ExprUtil.onNgMakeName f $ ExprUtil.randomNameGen gen
    f n prevFunc prevGuid pl@(mStorePoint, _)
      | Lens.has Lens._Just mStorePoint = (prevGuid, n)
      | otherwise = prevFunc prevGuid pl

writeExprMStored ::
  MonadA m =>
  ExprIRef.ExpressionIM m ->
  ExprStorePoint m a ->
  T m (ExprIRef.ExpressionM m (ExprIRef.ExpressionIM m, a))
writeExprMStored exprIRef exprMStorePoint = do
  key <- Transaction.newKey
  randomizeNonStoredParamIds (genFromHashable key) exprMStorePoint
    & Lens.mapped . Lens._1 . Lens._Just %~ unStorePoint
    & ExprIRef.writeExpressionWithStoredSubexpressions exprIRef

orderedInnerHoles ::
  Expr.Expression def (a, Infer.Inferred def) ->
  [Expr.Expression def (a, Infer.Inferred def)]
orderedInnerHoles e =
  case e ^. Expr.eBody of
  Expr.BodyApply (Expr.Apply func arg)
    | Lens.notNullOf (Expr.eBody . ExprLens.bodyHole) func ->
      -- This is a "type-error wrapper".
      -- Skip the conversion hole
      -- and go to inner holes in the expression first.
      uninferredHoles arg ++ [func]
  _ -> uninferredHoles e

-- Also skip param types, those can usually be inferred later, so less
-- useful to fill immediately
uninferredHoles ::
  Expr.Expression def (a, Infer.Inferred def) ->
  [Expr.Expression def (a, Infer.Inferred def)]
uninferredHoles e =
  case e ^. Expr.eBody of
  Expr.BodyLeaf Expr.Hole -> [e]
  Expr.BodyApply (Expr.Apply func _)
    | (ExprUtil.isDependentPi . Infer.iType . (^. Expr.ePayload . Lens._2)) func ->
      uninferredHoles func
  Expr.BodyLam (Expr.Lambda lamKind _ paramType result) ->
    uninferredHoles result ++ do
      guard $ lamKind == Type
      uninferredHoles paramType
  body -> Foldable.concatMap uninferredHoles body
