{-# LANGUAGE FlexibleContexts #-}
module Lamdu.GUI.ExpressionEdit.ExpressionGui.AddNextHoles
  ( addToDef, addToExpr
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Applicative.Utils (when)
import Control.Lens.Operators
import Control.Monad.Trans.State (State, evalState)
import Control.MonadA (MonadA)
import Data.Store.Guid (Guid)
import Lamdu.Sugar.Expression (subExpressions)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Lamdu.GUI.ExpressionEdit.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.Sugar.Types as Sugar

addToDef ::
  MonadA m =>
  Sugar.Definition name m (Sugar.Expression name m ExprGuiM.Payload) ->
  Sugar.Definition name m (Sugar.Expression name m ExprGuiM.Payload)
addToDef =
  (`evalState` Nothing) .
  (Sugar.drBody . Lens.traversed) addToExprH

addToExpr ::
  MonadA m => Sugar.Expression name m ExprGuiM.Payload -> Sugar.Expression name m ExprGuiM.Payload
addToExpr = (`evalState` Nothing) . addToExprH

addToExprH ::
  Sugar.Expression name m ExprGuiM.Payload -> State (Maybe Guid) (Sugar.Expression name m ExprGuiM.Payload)
addToExprH = Lens.backwards subExpressions %%@~ setNextHole

setNextHole ::
  Sugar.ExpressionP name m () ->
  Sugar.Payload name m ExprGuiM.Payload ->
  State (Maybe Guid) (Sugar.Payload name m ExprGuiM.Payload)
setNextHole expr pl =
  setIt <$>
  State.get <*
  when (Lens.has Lens._Just (pl ^. Sugar.plActions) && isHoleToJumpTo expr)
    (State.put (Just (pl ^. Sugar.plGuid)))
  where
    setIt x = pl & Sugar.plData . ExprGuiM.plMNextHoleGuid .~ x

isHoleToJumpTo :: Sugar.ExpressionP name m a -> Bool
isHoleToJumpTo expr =
  Lens.has (Sugar.rBody . Sugar._BodyHole) expr ||
  Lens.anyOf (Sugar.rBody . Sugar._BodyInferred . Sugar.iValue . subExpressions . Lens.asIndex)
    isHoleToJumpTo expr