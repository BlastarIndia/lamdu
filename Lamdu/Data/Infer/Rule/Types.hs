{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Data.Infer.Rule.Types
  ( RuleRef
  , GetFieldPhase0(..), gf0GetFieldTag, gf0GetFieldType
  , GetFieldPhase1(..), gf1GetFieldRecordTypeFields, gf1GetFieldType
  , GetFieldPhase2(..), gf2Tag, gf2TagRef, gf2TypeRef, gf2MaybeMatchers
  , Apply(..), aPiGuid, aArgVal, aRigidity, aLinkedExprs, aLinkedNames
  , Uncircumsize(..), uValRef, uApplicantValRef, uUncircumsizedBody
  , Rule(..), ruleTriggersIn, ruleContent
  , RuleContent(..)
  , RuleMap(..), rmMap, rmFresh
    , verifyTagId, initialRuleMap
  , new
  ) where

import Control.Lens.Operators
import Control.Monad.Trans.State (StateT, runState)
import Control.MonadA (MonadA)
import Data.Monoid (Monoid(..))
import Data.Store.Guid (Guid)
import Lamdu.Data.Infer.RefTags (ExprRef, TagExpr, RuleRef, TagRule, ParamRef, TagParam)
import Lamdu.Data.Infer.Rule.Types.Rigidity (Rigidity)
import qualified Control.Lens as Lens
import qualified Data.OpaqueRef as OR
import qualified Lamdu.Data.Expression as Expr

-- We know of a GetField, waiting to know the record type:
data GetFieldPhase0 def = GetFieldPhase0
  { _gf0GetFieldTag :: ExprRef def
  , _gf0GetFieldType :: ExprRef def
  -- trigger on record type, no need for Ref
  }
Lens.makeLenses ''GetFieldPhase0

-- We know of a GetField and the record type, waiting to know the
-- GetField tag:
data GetFieldPhase1 def = GetFieldPhase1
  { _gf1GetFieldRecordTypeFields :: [(ExprRef def, ExprRef def)]
  , _gf1GetFieldType :: ExprRef def
  -- trigger on getfield tag, no need for Ref
  }
Lens.makeLenses ''GetFieldPhase1

-- We know of a GetField and the record type, waiting to know the
-- GetField tag (trigger on getfield tag):
data GetFieldPhase2 def = GetFieldPhase2
  { _gf2Tag :: Guid
  , _gf2TagRef :: ExprRef def
  , _gf2TypeRef :: ExprRef def
  , -- Maps Refs of tags to Refs of their field types
    _gf2MaybeMatchers :: OR.RefMap (TagExpr def) (ExprRef def)
  }
Lens.makeLenses ''GetFieldPhase2

data Apply def = Apply
  { _aPiGuid :: Guid
  , _aArgVal :: ExprRef def
  , _aRigidity :: Rigidity def
  -- unmaintained pi-result to apply type respective/matching subexprs
  , _aLinkedExprs :: OR.RefMap (TagExpr def) (ExprRef def)
  , _aLinkedNames :: OR.RefMap (TagParam def) (ParamRef def)
  }
Lens.makeLenses ''Apply

data Uncircumsize def = Uncircumsize
  { _uValRef :: ExprRef def
  , _uApplicantValRef :: ExprRef def
  , _uUncircumsizedBody :: Expr.Body def (ExprRef def)
  }
Lens.makeLenses ''Uncircumsize

data RuleContent def
  = RuleVerifyTag
  | RuleGetFieldPhase0 (GetFieldPhase0 def)
  | RuleGetFieldPhase1 (GetFieldPhase1 def)
  | RuleGetFieldPhase2 (GetFieldPhase2 def)
  | RuleApply (Apply def)
  | RuleUncircumsize (Uncircumsize def)

data Rule def = Rule
  { _ruleTriggersIn :: OR.RefSet (TagExpr def)
  , _ruleContent :: RuleContent def
  }
Lens.makeLenses ''Rule

data RuleMap def = RuleMap
  { _rmFresh :: OR.Fresh (TagRule def)
  , _rmMap :: OR.RefMap (TagRule def) (Rule def)
  }
Lens.makeLenses ''RuleMap

new :: MonadA m => RuleContent def -> StateT (RuleMap def) m (RuleRef def)
new rule = do
  ruleId <- Lens.zoom rmFresh OR.freshRef
  rmMap . Lens.at ruleId .= Just (Rule mempty rule)
  return ruleId

verifyTagId :: RuleRef def
initialRuleMap :: RuleMap def
(verifyTagId, initialRuleMap) =
  runState (new RuleVerifyTag)
  RuleMap
  { _rmFresh = OR.initialFresh
  , _rmMap = mempty
  }
