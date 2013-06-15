module Lamdu.CodeEdit.Sugar.Expression
  ( make, mkGen
  , mkCallWithArg, mkReplaceWithNewHole
  , removeSuccessfulType, removeInferredTypes
  , removeTypes, removeNonHoleTypes, removeHoleResultTypes
  , setNextHoleToFirstSubHole
  , setNextHole
  , subExpressions
  , getStoredName
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens.Operators
import Control.Monad (zipWithM, mplus)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (mapStateT)
import Control.MonadA (MonadA)
import Data.Store.Guid (Guid)
import Data.Store.IRef (Tag)
import Data.Traversable (traverse)
import Data.Typeable (Typeable1)
import Lamdu.CodeEdit.Sugar.Infer (Stored)
import Lamdu.CodeEdit.Sugar.Monad (SugarM)
import Lamdu.CodeEdit.Sugar.Types
import Lamdu.Data.Expression.Infer.Conflicts (iwcInferredTypes)
import qualified Control.Lens as Lens
import qualified Data.Binary.Utils as BinaryUtils
import qualified Data.Store.Guid as Guid
import qualified Data.Store.Property as Property
import qualified Data.Store.Transaction as Transaction
import qualified Lamdu.CodeEdit.Sugar.Infer as SugarInfer
import qualified Lamdu.CodeEdit.Sugar.Monad as SugarM
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Expression.IRef as ExprIRef
import qualified Lamdu.Data.Ops as DataOps
import qualified System.Random as Random
import qualified System.Random.Utils as RandomUtils

removeSuccessfulType :: Expression name m -> Expression name m
removeSuccessfulType = rPayload %~ payloadRemoveSuccessfulType

payloadRemoveSuccessfulType :: Payload name m -> Payload name m
payloadRemoveSuccessfulType =
  plInferredTypes . Lens.filtered (null . drop 1) .~ []

removeInferredTypes :: Expression name m -> Expression name m
removeInferredTypes = rPayload . plInferredTypes .~ []

removeTypes :: Expression name m -> Expression name m
removeTypes = fmap payloadRemoveSuccessfulType

removeNonHoleTypes :: Expression name m -> Expression name m
removeNonHoleTypes =
  removeSuccessfulType . (innerLayer %~ removeNonHoleTypes)
  & (Lens.outside . Lens.filtered . Lens.has) (rBody . _BodyHole) .~
    (innerLayer . innerLayer %~ removeNonHoleTypes)
  where
    innerLayer = rBody . Lens.traversed

removeHoleResultTypes :: Expression name m -> Expression name m
removeHoleResultTypes =
  removeSuccessfulType .
  ( rBody %~
    ( (Lens.traversed %~ removeTypes)
      & Lens.outside _BodyHole .~
        BodyHole . (Lens.traversed . rBody . Lens.traversed %~ removeTypes)
    )
  )

mkGen :: Int -> Int -> Guid -> Random.StdGen
mkGen select count =
  Random.mkStdGen . (+select) . (*count) . BinaryUtils.decodeS . Guid.bs

mkCutter :: MonadA m => Anchors.CodeProps m -> ExprIRef.ExpressionI (Tag m) -> T m Guid -> T m Guid
mkCutter cp expr replaceWithHole = do
  _ <- DataOps.newClipboard cp expr
  replaceWithHole

checkReinferSuccess :: MonadA m => SugarM.Context m -> T m a -> CT m Bool
checkReinferSuccess sugarContext act =
  case sugarContext ^. SugarM.scMReinferRoot of
  Nothing -> pure False
  Just reinferRoot ->
    mapStateT Transaction.forkScratch $ do
      _ <- lift act
      reinferRoot

guardReinferSuccess :: MonadA m => SugarM.Context m -> T m a -> CT m (Maybe (T m a))
guardReinferSuccess sugarContext act = do
  success <- checkReinferSuccess sugarContext act
  pure $
    if success
    then Just act
    else Nothing

mkCallWithArg ::
  MonadA m => SugarM.Context m ->
  ExprIRef.ExpressionM m (SugarInfer.Payload i (Stored m)) ->
  PrefixAction m -> CT m (Maybe (T m Guid))
mkCallWithArg sugarContext exprStored prefixAction =
  guardReinferSuccess sugarContext $ do
    prefixAction
    fmap ExprIRef.exprGuid . DataOps.callWithArg $ exprStored ^. SugarInfer.exprStored

mkReplaceWithNewHole ::
  MonadA m =>
  ExprIRef.ExpressionM m (SugarInfer.Payload i (Stored m)) ->
  T m Guid
mkReplaceWithNewHole =
  fmap ExprIRef.exprGuid . DataOps.replaceWithHole . (^. SugarInfer.exprStored)

mkActions ::
  MonadA m => SugarM.Context m ->
  ExprIRef.ExpressionM m (SugarInfer.Payload i (Stored m)) -> Actions m
mkActions sugarContext exprS =
  Actions
  { _wrap = WrapAction $ ExprIRef.exprGuid <$> DataOps.wrap stored
  , _callWithArg = mkCallWithArg sugarContext exprS
  , _callWithNextArg = pure (pure Nothing)
  , _setToHole = ExprIRef.exprGuid <$> DataOps.setToHole stored
  , _replaceWithNewHole = mkReplaceWithNewHole exprS
  , _cut =
    mkCutter (sugarContext ^. SugarM.scCodeAnchors)
    (Property.value stored) $ mkReplaceWithNewHole exprS
  }
  where
    stored = exprS ^. SugarInfer.exprStored

make ::
  (Typeable1 m, MonadA m) => SugarInfer.ExprMM m ->
  BodyU m -> SugarM m (ExpressionU m)
make exprI body = do
  sugarContext <- SugarM.readContext
  inferredTypes <-
    zipWithM
    ( fmap SugarM.convertSubexpression
    . SugarInfer.mkExprPure
    ) seeds types
  return $ Expression body Payload
    { _plGuid = exprI ^. SugarInfer.exprGuid
    , _plInferredTypes = inferredTypes
    , _plActions =
      mkActions sugarContext <$>
      traverse (Lens.sequenceOf SugarInfer.plStored) exprI
    , _plMNextHoleGuid = Nothing
    , _plPresugaredExpression =
      fmap (StorePoint . Property.value) .
      (^. SugarInfer.plStored) <$> exprI
    , _plHiddenGuids = []
    }
  where
    seeds = RandomUtils.splits . mkGen 0 3 $ exprI ^. SugarInfer.exprGuid
    types = maybe [] iwcInferredTypes $ exprI ^. SugarInfer.exprInferred

subHoles ::
  (Applicative f, Lens.Contravariant f) =>
  (ExpressionU m -> f (ExpressionU m)) ->
  ExpressionU m -> f void
subHoles x =
  Lens.folding subExpressions . Lens.filtered cond $ x
  where
    cond expr =
      Lens.notNullOf (rBody . _BodyHole) expr ||
      Lens.notNullOf (rBody . _BodyInferred . iValue . subHoles) expr

setNextHole :: Guid -> ExpressionU m -> ExpressionU m
setNextHole destGuid =
  -- The mplus ignores holes that are already set:
  Lens.mapped . plMNextHoleGuid %~ (`mplus` Just destGuid)

setNextHoleToFirstSubHole :: MonadA m => ExpressionU m -> ExpressionU m -> ExpressionU m
setNextHoleToFirstSubHole dest =
  maybe id (setNextHole . (^. rPayload . plGuid)) $ dest ^? subHoles

subExpressions :: ExpressionU m -> [ExpressionU m]
subExpressions x = x : x ^.. rBody . Lens.traversed . Lens.folding subExpressions

getStoredName :: MonadA m => Guid -> T m (Maybe String)
getStoredName guid = do
  name <- Transaction.getP $ Anchors.assocNameRef guid
  pure $
    if null name then Nothing else Just name
