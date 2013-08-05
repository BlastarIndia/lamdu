module Lamdu.Data.Infer.Rule.Uncircumsize
  ( make, execute
  ) where

import Control.Applicative ((<$))
import Control.Lens.Operators
import Control.Monad (void)
import Lamdu.Data.Infer.Monad (Infer)
import Lamdu.Data.Infer.RefTags (ExprRef)
import Lamdu.Data.Infer.Rule.Func (RuleResult(..), RuleFunc)
import Lamdu.Data.Infer.Unify (unify)
import qualified Control.Lens as Lens
import qualified Data.UnionFind.WithData as UFData
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Infer.Internal as Infer
import qualified Lamdu.Data.Infer.Monad as InferM
import qualified Lamdu.Data.Infer.Rule.Types as Rule
import qualified Lamdu.Data.Infer.Trigger as Trigger

uncircumsize :: Eq def => Rule.Uncircumsize def -> Infer def ()
uncircumsize rule = do
  scope <- UFData.read (rule ^. Rule.uValRef) <&> (^. Infer.rdScope) & InferM.liftUFExprs
  uncircumsizedRef <- InferM.liftUFExprs . Infer.fresh scope $ rule ^. Rule.uUncircumsizedBody
  void $ unify (rule ^. Rule.uValRef) uncircumsizedRef

execute :: Eq def => Rule.Uncircumsize def -> RuleFunc def
execute rule triggers =
  case triggers ^@.. Lens.itraversed <. Lens.folded of
  [(_, Trigger.FiredGetDef isGetDef)]
    | isGetDef -> RuleDelete <$ uncircumsize rule
    | otherwise -> -- Keep circumsized:
      return RuleDelete
  list -> error $ "Uncircumsize.execute: Unexpected firings: " ++ show list

make ::
  ExprRef def -> ExprRef def ->
  Expr.Body def (ExprRef def) ->
  Infer def ()
make valRef applicantValRef uncircumsizedValBody = do
  ruleRef <-
    InferM.liftRuleMap . Rule.new $
    Rule.RuleUncircumsize Rule.Uncircumsize
    { Rule._uValRef = valRef
    , Rule._uApplicantValRef = applicantValRef
    , Rule._uUncircumsizedBody = uncircumsizedValBody
    }
  Trigger.add Trigger.OnGetDef ruleRef applicantValRef