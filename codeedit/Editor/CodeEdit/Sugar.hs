{-# LANGUAGE TemplateHaskell, GeneralizedNewtypeDeriving, DeriveFunctor, OverloadedStrings #-}

module Editor.CodeEdit.Sugar
  ( Definition(..), DefinitionBody(..), ListItemActions(..)
  , FuncParamActions(..)
  , DefinitionExpression(..), DefinitionContent(..), DefinitionNewType(..)
  , DefinitionBuiltin(..)
  , Actions(..)
  , ExpressionBody(..)
  , Payload(..)
  , ExpressionP(..)
  , Expression
  , WhereItem(..)
  , Func(..), FuncParam(..)
  , Pi(..)
  , Section(..)
  , Hole(..), HoleActions(..), HoleResult, holeResultHasHoles
  , LiteralInteger(..)
  , Inferred(..)
  , Polymorphic(..)
  , HasParens(..)
  , convertExpressionPure
  , loadConvertDefinition, loadConvertExpression
  , removeTypes
  ) where

import Control.Applicative ((<$>), Applicative(..))
import Control.Arrow (first)
import Control.Monad ((<=<), liftM, mplus, void)
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import Control.Monad.Trans.Writer (Writer, runWriter)
import Data.Derive.Foldable (makeFoldable)
import Data.Derive.Traversable (makeTraversable)
import Data.DeriveTH (derive)
import Data.Foldable (Foldable(..))
import Data.Function (on)
import Data.List.Utils (sortOn)
import Data.Map (Map)
import Data.Maybe (listToMaybe, maybeToList)
import Data.Monoid (Monoid(..), Any(..))
import Data.Set (Set)
import Data.Store.Guid (Guid)
import Data.Store.Transaction (Transaction)
import Data.Traversable (Traversable(traverse))
import Editor.Anchors (ViewTag)
import Editor.CodeEdit.Sugar.Config (SugarConfig)
import qualified Control.Monad.Trans.Reader as Reader
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.AtFieldTH as AtFieldTH
import qualified Data.Binary.Utils as BinaryUtils
import qualified Data.Foldable as Foldable
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Store.Guid as Guid
import qualified Data.Store.IRef as IRef
import qualified Data.Store.Property as Property
import qualified Data.Store.Transaction as Transaction
import qualified Data.Traversable as Traversable
import qualified Editor.Anchors as Anchors
import qualified Editor.CodeEdit.Infix as Infix
import qualified Editor.Config as Config
import qualified Editor.Data as Data
import qualified Editor.Data.IRef as DataIRef
import qualified Editor.Data.Infer as Infer
import qualified Editor.Data.Load as Load
import qualified Editor.Data.Ops as DataOps
import qualified System.Random as Random
import qualified System.Random.Utils as RandomUtils

type T = Transaction ViewTag

data Actions m = Actions
  { giveAsArg    :: T m Guid
  , replace      :: T m Guid
  , cut          :: T m Guid
  -- Turn "x" to "x ? _" where "?" is an operator-hole.
  -- Given string is initial hole search term.
  , giveAsArgToOperator :: String -> T m Guid
  }

data HasParens = HaveParens | DontHaveParens

data Payload m = Payload
  { plInferredTypes :: [Expression m]
  , plActions :: Maybe (Actions m)
  , plNextHole :: Maybe (Expression m)
  }

data ExpressionP m pl = Expression
  { rGuid :: Guid
  , rExpressionBody :: ExpressionBody m (ExpressionP m pl)
  , rPayload :: pl
  } deriving (Functor)

type Expression m = ExpressionP m (Payload m)

data ListItemActions m = ListItemActions
  { itemAddNext :: T m Guid
  , itemDelete :: T m Guid
  }

data FuncParamActions m = FuncParamActions
  { fpListItemActions :: ListItemActions m
  , fpGetExample :: T m (Expression m)
  }

data FuncParam m expr = FuncParam
  { fpGuid :: Guid
  , fpHiddenLambdaGuid :: Maybe Guid
  , fpType :: expr
  , fpMActions :: Maybe (FuncParamActions m)
  } deriving (Functor)

instance Show expr => Show (FuncParam m expr) where
  show fp =
    concat ["(", show (fpHiddenLambdaGuid fp), ":", show (fpType fp), ")"]

-- Multi-param Lambda
data Func m expr = Func
  { fParams :: [FuncParam m expr]
  , fBody :: expr
  } deriving (Functor)

data Pi m expr = Pi
  { pParam :: FuncParam m expr
  , pResultType :: expr
  } deriving (Functor)

-- Infix Sections include: (+), (1+), (+1), (1+2). Last is really just
-- infix application, but considered an infix section too.
data Section expr = Section
  { sectionLArg :: Maybe expr
  , sectionOp :: expr -- TODO: Always a Data.GetVariable, use a more specific type
  , sectionRArg :: Maybe expr
  } deriving (Functor)

type HoleResult = Infer.Expression ()

data HoleActions m = HoleActions
  { holePickResult :: HoleResult -> T m (Guid, Actions m)
  , holeConvertResult :: HoleResult -> T m (Expression m)
  , holePaste :: Maybe (T m Guid)
  }

data Hole m = Hole
  { holeScope :: [Guid]
  , holeInferResults :: Data.PureExpression -> T m [HoleResult]
  , holeMActions :: Maybe (HoleActions m)
  }

data LiteralInteger m = LiteralInteger
  { liValue :: Integer
  , liSetValue :: Maybe (Integer -> T m ())
  }

data Inferred m expr = Inferred
  { iValue :: expr
  , iHole :: Hole m
  } deriving (Functor)

data Polymorphic expr = Polymorphic
  { pFuncGuid :: Guid
  , pCompact :: Data.VariableRef
  , pFullExpression :: expr
  } deriving (Functor)

data ExpressionBody m expr
  = ExpressionApply   { eHasParens :: HasParens, eApply :: Data.Apply expr }
  | ExpressionSection { eHasParens :: HasParens, eSection :: Section expr }
  | ExpressionFunc    { eHasParens :: HasParens, _eFunc :: Func m expr }
  | ExpressionPi      { eHasParens :: HasParens, _ePi :: Pi m expr }
  | ExpressionGetVariable { _getVariable :: Data.VariableRef }
  | ExpressionHole { _eHole :: Hole m }
  | ExpressionInferred { _eInferred :: Inferred m expr }
  | ExpressionPolymorphic { _ePolymorphic :: Polymorphic expr }
  | ExpressionLiteralInteger { _eLit :: LiteralInteger m }
  | ExpressionAtom { _eAtom :: String }
  deriving (Functor)

wrapParens :: HasParens -> String -> String
wrapParens HaveParens x = concat ["(", x, ")"]
wrapParens DontHaveParens x = x

instance Show expr => Show (ExpressionBody m expr) where
  show ExpressionApply   { eHasParens = hasParens, eApply = Data.Apply func arg } =
    wrapParens hasParens $ show func ++ " " ++ show arg
  show ExpressionSection { eHasParens = hasParens, eSection = Section mleft op mright } =
    wrapParens hasParens $ maybe "" show mleft ++ " " ++ show op ++ maybe "" show mright
  show ExpressionFunc    { eHasParens = hasParens, _eFunc = Func params body } =
    wrapParens hasParens $ "\\" ++ unwords (map show params) ++ " -> " ++ show body
  show ExpressionPi      { eHasParens = hasParens, _ePi = Pi param resultType } =
    wrapParens hasParens $ "_:" ++ show param ++ " -> " ++ show resultType
  show ExpressionGetVariable { _getVariable = Data.ParameterRef guid } = 'P' : show guid
  show ExpressionGetVariable { _getVariable = Data.DefinitionRef defI } = 'D' : show (IRef.guid defI)
  show ExpressionHole {} = "Hole"
  show ExpressionInferred {} = "Inferred"
  show ExpressionPolymorphic {} = "Poly"
  show ExpressionLiteralInteger { _eLit = LiteralInteger i _ } = show i
  show ExpressionAtom { _eAtom = atom } = atom

data DefinitionNewType m = DefinitionNewType
  { dntNewType :: Expression m
  , dntAcceptNewType :: T m ()
  }

data WhereItem m = WhereItem
  { wiValue :: DefinitionContent m
  , wiGuid :: Guid
  , wiHiddenGuids :: [Guid]
  , wiActions :: ListItemActions m
  }

-- Common data for definitions and where-items
data DefinitionContent m = DefinitionContent
  { dBody :: Expression m
  , dParameters :: [FuncParam m (Expression m)]
  , dWhereItems :: [WhereItem m]
  , dAddFirstParam :: T m Guid
  , dAddInnermostWhereItem :: T m Guid
  }

data DefinitionExpression m = DefinitionExpression
  { deContent :: DefinitionContent m
  , deIsTypeRedundant :: Bool
  , deMNewType :: Maybe (DefinitionNewType m)
  }

data DefinitionBuiltin m = DefinitionBuiltin
  { biName :: Data.FFIName
  -- Consider removing Maybe'ness here
  , biMSetName :: Maybe (Data.FFIName -> T m ())
  }

data DefinitionBody m
  = DefinitionBodyExpression (DefinitionExpression m)
  | DefinitionBodyBuiltin (DefinitionBuiltin m)

data Definition m = Definition
  { drGuid :: Guid
  , drType :: Expression m
  , drBody :: DefinitionBody m
  }

AtFieldTH.make ''Hole
AtFieldTH.make ''WhereItem
AtFieldTH.make ''FuncParam
AtFieldTH.make ''Func
AtFieldTH.make ''Pi
AtFieldTH.make ''Section
AtFieldTH.make ''ExpressionBody
AtFieldTH.make ''Inferred
AtFieldTH.make ''Actions
AtFieldTH.make ''ListItemActions
AtFieldTH.make ''FuncParamActions
AtFieldTH.make ''Payload
AtFieldTH.make ''ExpressionP

data ExprEntityInferred a = ExprEntityInferred
  { eesInferred :: Infer.Inferred a
  , eesTypeConflicts :: [Data.PureExpression]
  , eesValueConflicts :: [Data.PureExpression]
  } deriving (Functor)
derive makeFoldable ''ExprEntityInferred
derive makeTraversable ''ExprEntityInferred

type ExprEntityStored m =
  ExprEntityInferred (DataIRef.ExpressionProperty (T m))

type ExprEntityMStored m =
  ExprEntityInferred (Maybe (DataIRef.ExpressionProperty (T m)))

type ExprEntity m = Data.Expression (Maybe (ExprEntityMStored m))

eeStored :: ExprEntity m -> Maybe (ExprEntityStored m)
eeStored = Traversable.sequenceA <=< Data.ePayload

eeProp :: ExprEntity m -> Maybe (DataIRef.ExpressionProperty (T m))
eeProp = Infer.iStored . eesInferred <=< Data.ePayload

eeFromPure :: Data.PureExpression -> ExprEntity m
eeFromPure = fmap $ const Nothing

newtype ConflictMap =
  ConflictMap { unConflictMap :: Map Infer.Ref (Set Data.PureExpression) }

instance Monoid ConflictMap where
  mempty = ConflictMap mempty
  mappend (ConflictMap x) (ConflictMap y) =
    ConflictMap $ Map.unionWith mappend x y

getConflicts :: Infer.Ref -> ConflictMap -> [Data.PureExpression]
getConflicts ref = maybe [] Set.toList . Map.lookup ref . unConflictMap

argument :: (a -> b) -> (b -> c) -> a -> c
argument = flip (.)

writeIRef
  :: Monad m => DataIRef.ExpressionProperty (T m)
  -> Data.ExpressionBody Data.ExpressionIRef
  -> Transaction t m ()
writeIRef = DataIRef.writeExprBody . Property.value

writeIRefVia
  :: Monad m
  => (a -> DataIRef.ExpressionBody)
  -> DataIRef.ExpressionProperty (T m)
  -> a -> Transaction t m ()
writeIRefVia f = (fmap . argument) f writeIRef

data SugarContext = SugarContext
  { scInferState :: Infer.RefMap
  , scConfig :: SugarConfig
  }
AtFieldTH.make ''SugarContext

newtype Sugar m a = Sugar {
  unSugar :: ReaderT SugarContext (T m) a
  } deriving (Monad)
AtFieldTH.make ''Sugar

runSugar :: Monad m => SugarContext -> Sugar m a -> T m a
runSugar ctx (Sugar action) = runReaderT action ctx

readContext :: Monad m => Sugar m SugarContext
readContext = Sugar Reader.ask

liftTransaction :: Monad m => T m a -> Sugar m a
liftTransaction = Sugar . lift

type Convertor m = ExprEntity m -> Sugar m (Expression m)

mkCutter :: Monad m => Data.ExpressionIRef -> T m Guid -> T m Guid
mkCutter iref replaceWithHole = do
  Anchors.modP Anchors.clipboards (iref:)
  replaceWithHole

mkActions :: Monad m => DataIRef.ExpressionProperty (T m) -> Actions m
mkActions stored =
  Actions
  { giveAsArg = guidify $ DataOps.giveAsArg stored
  , replace = doReplace
  , cut = mkCutter (Property.value stored) doReplace
  , giveAsArgToOperator = guidify . DataOps.giveAsArgToOperator stored
  }
  where
    guidify = liftM DataIRef.exprGuid
    doReplace = guidify $ DataOps.replaceWithHole stored

mkGen :: Int -> Int -> Guid -> Random.StdGen
mkGen select count =
  Random.mkStdGen . (+select) . (*count) . BinaryUtils.decodeS . Guid.bs

mkExpression ::
  Monad m =>
  ExprEntity m ->
  ExpressionBody m (Expression m) -> Sugar m (Expression m)
mkExpression ee expr = do
  inferredTypesRefs <- mapM (convertExpressionI . eeFromPure) types
  return
    Expression
    { rGuid = Data.eGuid ee
    , rExpressionBody = expr
    , rPayload = Payload
      { plInferredTypes = inferredTypesRefs
      , plActions = fmap mkActions $ eeProp ee
      , plNextHole = Nothing
      }
    }
  where
    types =
      zipWith Data.randomizeGuids
      (RandomUtils.splits (mkGen 0 2 (Data.eGuid ee))) .
      maybe [] eesInferredTypes $ Data.ePayload ee

mkDelete
  :: Monad m
  => DataIRef.ExpressionProperty (T m)
  -> DataIRef.ExpressionProperty (T m)
  -> T m Guid
mkDelete parentP replacerP = do
  Property.set parentP replacerI
  return $ DataIRef.exprGuid replacerI
  where
    replacerI = Property.value replacerP

mkAddParam ::
  Monad m => DataIRef.ExpressionProperty (T m) -> T m Guid
mkAddParam = liftM fst . DataOps.lambdaWrap

storedIRefP :: Data.Expression (ExprEntityInferred a) -> a
storedIRefP = Infer.iStored . eesInferred . Data.ePayload

mkFuncParamActions ::
  Monad m => SugarContext ->
  ExprEntityStored m ->
  Data.Lambda (ExprEntityStored m) ->
  DataIRef.ExpressionProperty (T m) ->
  FuncParamActions m
mkFuncParamActions
  ctx lambdaStored (Data.Lambda param paramType _) replacerP =
  FuncParamActions
  { fpListItemActions =
    ListItemActions
    { itemDelete =
         mkDelete ((Infer.iStored . eesInferred) lambdaStored) replacerP
    , itemAddNext = mkAddParam replacerP
    }
  , fpGetExample = do
      exampleP <-
        Anchors.nonEmptyAssocDataRef "example" param .
        DataIRef.newExprBody $ Data.ExpressionLeaf Data.Hole
      exampleS <- Load.loadExpression exampleP
      loaded <- uncurry (Infer.load loader) newNode Nothing exampleS
      let (_, inferState, exampleStored) = inferWithConflicts loaded
      convertStoredExpression exampleStored $
        SugarContext inferState (scConfig ctx)
  }
  where
    scope = Infer.nScope . Infer.iPoint $ eesInferred lambdaStored
    paramTypeRef =
      Infer.tvVal . Infer.nRefs . Infer.iPoint $ eesInferred paramType
    newNode =
      Infer.newTypedNodeWithScope scope paramTypeRef $ scInferState ctx

convertLambda
  :: Monad m
  => Data.Lambda (ExprEntity m)
  -> ExprEntity m -> Sugar m (FuncParam m (Expression m), Expression m)
convertLambda lam@(Data.Lambda param paramTypeI bodyI) expr = do
  sBody <- convertExpressionI bodyI
  typeExpr <- convertExpressionI paramTypeI
  ctx <- readContext
  let
    fp = FuncParam
      { fpGuid = param
      , fpHiddenLambdaGuid = Nothing
      , fpType = removeRedundantTypes typeExpr
      , fpMActions =
        mkFuncParamActions ctx
        <$> eeStored expr
        <*> Traversable.mapM eeStored lam
        <*> eeProp bodyI
      }
  return (fp, sBody)

convertFunc
  :: Monad m
  => Data.Lambda (ExprEntity m)
  -> Convertor m
convertFunc lambda exprI = do
  (param, sBody) <- convertLambda lambda exprI
  mkExpression exprI .
    ExpressionFunc DontHaveParens $
    case rExpressionBody sBody of
      ExpressionFunc _ (Func nextParams body) ->
        case nextParams of
        [] -> error "Func must have at least 1 param!"
        (nextParam : _) ->
          Func (deleteToNextParam nextParam param : nextParams) body
      _ -> Func [param] sBody
  where
    deleteToNextParam nextParam =
      atFpMActions . fmap . atFpListItemActions . atItemDelete . liftM . const $ fpGuid nextParam

convertPi
  :: Monad m
  => Data.Lambda (ExprEntity m)
  -> Convertor m
convertPi lambda exprI = do
  (param, sBody) <- convertLambda lambda exprI
  mkExpression exprI $ ExpressionPi DontHaveParens
    Pi
    { pParam = atFpType addApplyChildParens param
    , pResultType = removeRedundantTypes sBody
    }

addParens :: ExpressionBody m (Expression m) -> ExpressionBody m (Expression m)
addParens (ExpressionInferred (Inferred val hole)) =
  ExpressionInferred $ Inferred (atRExpressionBody addParens val) hole
addParens (ExpressionPolymorphic (Polymorphic g compact full)) =
  ExpressionPolymorphic . Polymorphic g compact $
  atRExpressionBody addParens full
addParens x = (atEHasParens . const) HaveParens x

addApplyChildParens :: Expression m -> Expression m
addApplyChildParens =
  atRExpressionBody f
  where
    f x@ExpressionApply{} = x
    f x@ExpressionPolymorphic{} = x
    f x = addParens x

isPolymorphicFunc :: ExprEntity m -> Bool
isPolymorphicFunc funcI =
  maybe False
  (Data.isDependentPi . Infer.iType . eesInferred)
  (Data.ePayload funcI)

convertApply :: Monad m => Data.Apply (ExprEntity m) -> Convertor m
convertApply (Data.Apply funcI argI) exprI = do
  funcS <- convertExpressionI funcI
  argS <- convertExpressionI argI
  let apply = Data.Apply (funcS, funcI) (argS, argI)
  case rExpressionBody funcS of
    ExpressionSection _ section ->
      applyOnSection section apply exprI
    _ ->
      convertApplyPrefix apply exprI

removeInferredTypes :: Expression m -> Expression m
removeInferredTypes = (atRPayload . atPlInferredTypes . const) []

removeRedundantTypes :: Expression m -> Expression m
removeRedundantTypes =
  (atRPayload . atPlInferredTypes) removeIfNoErrors
  where
    removeIfNoErrors [_] = []
    removeIfNoErrors xs = xs

isSameOp :: ExpressionBody m expr -> ExpressionBody m expr -> Bool
isSameOp (ExpressionPolymorphic p0) (ExpressionPolymorphic p1) =
  on (==) pCompact p0 p1
isSameOp (ExpressionGetVariable v0) (ExpressionGetVariable v1) =
  v0 == v1
isSameOp _ _ = False

setNextHole :: Expression m -> Expression m -> Expression m
setNextHole possibleHole =
  case rExpressionBody possibleHole of
  ExpressionHole{} ->
    (fmap . atPlNextHole . flip mplus . Just) possibleHole
  _ -> id

applyOnSection ::
  Monad m =>
  Section (Expression m) -> Data.Apply (Expression m, ExprEntity m) -> Convertor m
applyOnSection (Section Nothing op Nothing) (Data.Apply (_, funcI) arg@(argRef, _)) exprI
  | isPolymorphicFunc funcI = do
    newOpRef <-
      convertApplyPrefix (Data.Apply (op, funcI) arg) exprI
    mkExpression exprI . ExpressionSection DontHaveParens $
      Section Nothing (removeRedundantTypes newOpRef) Nothing
  | otherwise =
    mkExpression exprI . ExpressionSection DontHaveParens $
    Section (Just (addApplyChildParens argRef)) op Nothing
applyOnSection (Section (Just left) op Nothing) (Data.Apply _ (argRef, _)) exprI =
  mkExpression exprI . ExpressionSection DontHaveParens $
  on (Section . Just) (setNextHole right) left op (Just right)
  where
    right =
      case rExpressionBody argRef of
      ExpressionSection _ (Section (Just _) rightOp (Just _))
        | on isSameOp rExpressionBody op rightOp -> argRef
      _ -> addApplyChildParens argRef
applyOnSection _ apply exprI = convertApplyPrefix apply exprI

convertApplyPrefix ::
  Monad m =>
  Data.Apply (Expression m, ExprEntity m) -> Convertor m
convertApplyPrefix (Data.Apply (funcRef, funcI) (argRef, _)) exprI
  | isPolymorphicFunc funcI =
    case rExpressionBody funcRef of
    ExpressionPolymorphic (Polymorphic g compact full) ->
      makePolymorphic g compact =<< makeApply full
    ExpressionGetVariable getVar ->
      makePolymorphic (Data.eGuid funcI) getVar =<< makeFullApply
    _ -> makeFullApply
  | otherwise = makeFullApply
  where
    newArgRef = atRExpressionBody addParens argRef
    newFuncRef =
      setNextHole newArgRef .
      addApplyChildParens .
      removeRedundantTypes $
      funcRef
    expandedGuid = Guid.combine (Data.eGuid exprI) $ Guid.fromString "polyExpanded"
    makeFullApply = makeApply newFuncRef
    makeApply f =
      mkExpression exprI . ExpressionApply DontHaveParens $
      Data.Apply f newArgRef
    makePolymorphic g compact fullExpression =
      mkExpression exprI $ ExpressionPolymorphic Polymorphic
        { pFuncGuid = g
        , pCompact = compact
        , pFullExpression =
          (atRGuid . const) expandedGuid $ removeInferredTypes fullExpression
        }


isHole :: Data.ExpressionBody a -> Bool
isHole (Data.ExpressionLeaf Data.Hole) = True
isHole _ = False

convertGetVariable :: Monad m => Data.VariableRef -> Convertor m
convertGetVariable varRef exprI = do
  isInfix <- liftTransaction $ Infix.isInfixVar varRef
  getVarExpr <-
    mkExpression exprI $ ExpressionGetVariable varRef
  if isInfix
    then
      mkExpression exprI .
      ExpressionSection HaveParens $
      Section Nothing (removeInferredTypes getVarExpr) Nothing
    else return getVarExpr

mkPaste :: Monad m => DataIRef.ExpressionProperty (T m) -> Sugar m (Maybe (T m Guid))
mkPaste exprP = do
  clipboardsP <- liftTransaction Anchors.clipboards
  let
    mClipPop =
      case Property.value clipboardsP of
      [] -> Nothing
      (clip : clips) -> Just (clip, Property.set clipboardsP clips)
  return $ fmap (doPaste (Property.set exprP)) mClipPop
  where
    doPaste replacer (clip, popClip) = do
      ~() <- popClip
      ~() <- replacer clip
      return $ DataIRef.exprGuid clip

zeroGuid :: Guid
zeroGuid = Guid.fromString "applyZero"

pureHole :: Data.PureExpression
pureHole = Data.pureExpression zeroGuid $ Data.ExpressionLeaf Data.Hole

countArrows :: Data.PureExpression -> Int
countArrows Data.Expression
  { Data.eValue =
    Data.ExpressionPi (Data.Lambda _ _ resultType)
  } = 1 + countArrows resultType
countArrows _ = 0

-- TODO: Return a record, not a tuple
countPis :: Data.PureExpression -> (Int, Int)
countPis e@Data.Expression
  { Data.eValue =
    Data.ExpressionPi (Data.Lambda _ _ resultType)
  }
  | Data.isDependentPi e = first (1+) $ countPis resultType
  | otherwise = (0, 1 + countArrows resultType)
countPis _ = (0, 0)

applyForms
  :: Data.PureExpression
  -> Data.PureExpression -> [Data.PureExpression]
applyForms _ e@Data.Expression{ Data.eValue = Data.ExpressionLambda {} } =
  [e]
applyForms exprType expr =
  map Data.canonizeGuids . reverse . take (1 + arrows) $ iterate addApply withDepPisApplied
  where
    withDepPisApplied = iterate addApply expr !! depPis
    (depPis, arrows) = countPis exprType
    addApply =
      Data.pureExpression zeroGuid .
      (`Data.makeApply` pureHole)

convertReadOnlyHole :: Monad m => Convertor m
convertReadOnlyHole exprI =
  mkExpression exprI $ ExpressionHole Hole
  { holeScope = []
  , holeInferResults = const $ return []
  , holeMActions = Nothing
  }

loader :: Monad m => Infer.Loader (T m)
loader = Infer.Loader Load.loadPureDefinitionType

-- Fill partial holes in an expression. Parital holes are those whose
-- inferred (filler) value itself is not complete, so will not be a
-- useful auto-inferred value. By auto-filling those, we allow the
-- user a chance to access all the partiality that needs filling more
-- easily.
fillPartialHolesInExpression ::
  Monad m =>
  (Data.PureExpression -> m (Maybe (Infer.Expression a))) ->
  Infer.Expression a -> m [Infer.Expression a]
fillPartialHolesInExpression check oldExpr =
  liftM ((++ [oldExpr]) . maybeToList) .
  recheck . runWriter $ fillHoleExpr oldExpr
  where
    recheck (newExpr, Any True) = check newExpr
    recheck (_, Any False) = return Nothing
    fillHoleExpr expr@(Data.Expression _ (Data.ExpressionLeaf Data.Hole) hInferred) =
      let inferredVal = Infer.iValue hInferred
      in
        case Data.eValue inferredVal of
        Data.ExpressionLeaf Data.Hole -> return $ void expr
        _ | isCompleteType inferredVal -> return $ void expr
          | otherwise -> do
            -- Hole inferred value has holes to fill, no use leaving it as
            -- auto-inferred, just fill it:
            Writer.tell $ Any True
            return inferredVal
    fillHoleExpr (Data.Expression g body _) =
      liftM (Data.pureExpression g) $ Traversable.mapM fillHoleExpr body

resultComplexityScore :: HoleResult -> Int
resultComplexityScore =
  sum . map ((+ negate 2) . length . Foldable.toList . Infer.iType) .
  Foldable.toList

convertWritableHole ::
  Monad m =>
  ExprEntityInferred (DataIRef.ExpressionProperty (T m)) -> Convertor m
convertWritableHole eeInferred exprI = do
  ctx <- readContext
  mPaste <- mkPaste . Infer.iStored $ eesInferred eeInferred
  let
    inferState = scInferState ctx
    check expr =
      inferExpr expr inferState . Infer.iPoint $ eesInferred eeInferred

    makeApplyForms _ _ Nothing = return []
    makeApplyForms processRes expr (Just i) =
      liftM concat . mapM processRes $
      applyForms (Infer.iType (Data.ePayload i)) expr

    inferResults processRes expr =
      liftM (sortOn resultComplexityScore) .
      makeApplyForms processRes expr =<<
      ( uncurry (inferExpr expr)
      . Infer.newNodeWithScope
        ((Infer.nScope . Infer.iPoint . eesInferred) eeInferred)
      ) inferState
    onScopeElement (param, _typeExpr) = param
    hole processRes = Hole
      { holeScope =
        map onScopeElement . Map.toList . Infer.iScope $
        eesInferred eeInferred
      , holeInferResults = inferResults processRes
      , holeMActions = Just HoleActions
          { holePickResult = pickResult . Infer.iStored $ eesInferred eeInferred
          , holePaste = mPaste
          , holeConvertResult = convertHoleResult $ scConfig ctx
          }
      }
    plainHole = do
      holeExpr <- mkExpression exprI . ExpressionHole $ hole (liftM maybeToList . check)
      searchTermRef <- liftTransaction $ Anchors.assocSearchTermRef eGuid
      let searchTerm = Property.value searchTermRef
      if not (null searchTerm) && all (`elem` Config.operatorChars) searchTerm
        then
          mkExpression exprI .
            ExpressionSection DontHaveParens $
            Section Nothing (removeInferredTypes holeExpr) Nothing
        else return holeExpr

  case eesInferredValues eeInferred of
    [Data.Expression { Data.eValue = Data.ExpressionLeaf Data.Hole }] ->
      plainHole
    [x] ->
      mkExpression exprI =<<
      ( liftM
        ( ExpressionInferred
        . (`Inferred` hole
           (maybe (return []) (fillPartialHolesInExpression check) <=< check))
        )
      . convertExpressionI . eeFromPure
      ) (Data.randomizeGuids (mkGen 1 2 eGuid) x)
    _ -> plainHole
  where
    inferExpr expr inferContext inferPoint =
      liftM (fmap fst . Infer.infer (Infer.InferActions (const Nothing))) $
      Infer.load loader inferContext inferPoint Nothing expr
    pickResult irefP =
      liftM
      ( flip (,) (mkActions irefP)
      . maybe eGuid Data.eGuid . listToMaybe . uninferredHoles
      ) . DataIRef.writeExpression (Property.value irefP)
    eGuid = Data.eGuid exprI

-- TODO: This is a DRY violation, implementing isPolymorphic logic
-- here again

-- Also skip param types, those can usually be inferred later, so less
-- useful to fill immediately
uninferredHoles :: HoleResult -> [HoleResult]
uninferredHoles Data.Expression { Data.eValue = Data.ExpressionApply (Data.Apply func arg) } =
  if (Data.isDependentPi . Infer.iType . Data.ePayload) func
  then uninferredHoles func
  else uninferredHoles func ++ uninferredHoles arg
uninferredHoles e@Data.Expression { Data.eValue = Data.ExpressionLeaf Data.Hole } = [e]
uninferredHoles Data.Expression
  { Data.eValue = Data.ExpressionPi (Data.Lambda _ paramType resultType) } =
    uninferredHoles resultType ++ uninferredHoles paramType
uninferredHoles Data.Expression
  { Data.eValue = Data.ExpressionLambda (Data.Lambda _ paramType result) } =
    uninferredHoles result ++ uninferredHoles paramType
uninferredHoles Data.Expression { Data.eValue = body } =
  Foldable.concatMap uninferredHoles body

holeResultHasHoles :: HoleResult -> Bool
holeResultHasHoles = not . null . uninferredHoles

convertHole :: Monad m => Convertor m
convertHole exprI =
  maybe convertReadOnlyHole convertWritableHole mStored exprI
  where
    mStored = f =<< Data.ePayload exprI
    f entity = fmap (g entity) $ (Infer.iStored . eesInferred) entity
    g entity stored =
      (atEesInferred . fmap . const) stored entity
    atEesInferred j x = x { eesInferred = j $ eesInferred x }

convertLiteralInteger :: Monad m => Integer -> Convertor m
convertLiteralInteger i exprI =
  mkExpression exprI . ExpressionLiteralInteger $
  LiteralInteger
  { liValue = i
  , liSetValue =
      fmap (writeIRefVia (Data.ExpressionLeaf . Data.LiteralInteger)) $
      eeProp exprI
  }

convertAtom :: Monad m => String -> Convertor m
convertAtom name exprI =
  mkExpression exprI $ ExpressionAtom name

convertExpressionI :: Monad m => ExprEntity m -> Sugar m (Expression m)
convertExpressionI ee =
  ($ ee) $
  case Data.eValue ee of
  Data.ExpressionLambda x -> convertFunc x
  Data.ExpressionPi x -> convertPi x
  Data.ExpressionApply x -> convertApply x
  Data.ExpressionLeaf (Data.GetVariable x) -> convertGetVariable x
  Data.ExpressionLeaf (Data.LiteralInteger x) -> convertLiteralInteger x
  Data.ExpressionLeaf Data.Hole -> convertHole
  Data.ExpressionLeaf Data.Set -> convertAtom "Set"
  Data.ExpressionLeaf Data.IntegerType -> convertAtom "Int"

-- Check no holes
isCompleteType :: Data.PureExpression -> Bool
isCompleteType = not . any (isHole . Data.eValue) . Data.subExpressions

convertHoleResult ::
  Monad m => SugarConfig -> HoleResult -> T m (Expression m)
convertHoleResult config =
  runSugar ctx . convertExpressionI . fmap toExprEntity
  where
    toExprEntity inferred =
      Just ExprEntityInferred
      { eesInferred = (fmap . const) Nothing inferred
      , eesTypeConflicts = []
      , eesValueConflicts = []
      }
    ctx =
      SugarContext
      { scInferState = error "pure expression doesnt have infer state"
      , scConfig = config
      }

convertExpressionPure ::
  Monad m => SugarConfig -> Data.PureExpression -> T m (Expression m)
convertExpressionPure config =
  runSugar ctx . convertExpressionI . eeFromPure
  where
    ctx =
      SugarContext
      { scInferState = error "pure expression doesnt have infer state"
      , scConfig = config
      }

reportError :: Infer.Error -> Writer ConflictMap ()
reportError err =
  Writer.tell . ConflictMap .
  Map.singleton (Infer.errRef err) .
  Set.singleton .
  snd $ Infer.errMismatch err

loadConvertExpression ::
  Monad m =>
  SugarConfig ->
  DataIRef.ExpressionProperty (T m) -> T m (Expression m)
loadConvertExpression config exprP =
  convertLoadedExpression config Nothing =<< Load.loadExpression exprP

convertDefinitionParams ::
  Monad m =>
  SugarContext -> Data.Expression (ExprEntityStored m) ->
  T m ([FuncParam m (Expression m)], Data.Expression (ExprEntityStored m))
convertDefinitionParams ctx expr =
  case Data.eValue expr of
  Data.ExpressionLambda lam@(Data.Lambda param paramType body) -> do
    paramTypeS <- convertStoredExpression paramType ctx
    let
      fp = FuncParam
        { fpGuid = param
        , fpHiddenLambdaGuid = Just $ Data.eGuid expr
        , fpType = removeRedundantTypes paramTypeS
        , fpMActions =
          Just $
          mkFuncParamActions ctx
          (Data.ePayload expr) (fmap Data.ePayload lam)
          (storedIRefP body)
        }
    (nextFPs, funcBody) <- convertDefinitionParams ctx body
    return (fp : nextFPs, funcBody)
  _ -> return ([], expr)

convertWhereItems ::
  Monad m =>
  SugarContext -> Data.Expression (ExprEntityStored m) ->
  T m ([WhereItem m], Data.Expression (ExprEntityStored m))
convertWhereItems ctx
  topLevel@Data.Expression
  { Data.eValue = Data.ExpressionApply apply@Data.Apply
  { Data.applyFunc = Data.Expression
  { Data.eValue = Data.ExpressionLambda lambda@Data.Lambda
  { Data.lambdaParamId = param
  , Data.lambdaParamType = Data.Expression
  { Data.eValue = Data.ExpressionLeaf Data.Hole
  }}}}} = do
    value <- convertDefinitionContent ctx $ Data.applyArg apply
    let
      body = Data.lambdaBody lambda
      item = WhereItem
        { wiValue = value
        , wiGuid = param
        , wiHiddenGuids =
            map Data.eGuid
            [ topLevel
            , Data.lambdaParamType lambda
            ]
        , wiActions =
            ListItemActions
            { itemDelete = mkDelete (prop topLevel) (prop body)
            , itemAddNext = liftM fst . DataOps.redexWrap $ prop topLevel
            }
        }
    (nextItems, whereBody) <- convertWhereItems ctx body
    return (item : nextItems, whereBody)
  where
    prop = Infer.iStored . eesInferred . Data.ePayload
convertWhereItems _ expr = return ([], expr)

convertDefinitionContent ::
  Monad m =>
  SugarContext -> Data.Expression (ExprEntityStored m) ->
  T m (DefinitionContent m)
convertDefinitionContent sugarContext expr = do
  (params, funcBody) <- convertDefinitionParams sugarContext expr
  (whereItems, whereBody) <- convertWhereItems sugarContext funcBody
  bodyS <- convertStoredExpression whereBody sugarContext
  return DefinitionContent
    { dBody = bodyS
    , dParameters = params
    , dWhereItems = whereItems
    , dAddFirstParam = mkAddParam $ stored expr
    , dAddInnermostWhereItem =
        liftM fst . DataOps.redexWrap $ stored whereBody
    }
  where
    stored = Infer.iStored . eesInferred . Data.ePayload

loadConvertDefinition ::
  Monad m => SugarConfig -> Data.DefinitionIRef -> T m (Definition m)
loadConvertDefinition config defI =
  -- TODO: defI given twice probably means the result of
  -- loadDefinition is missing some defI-dependent values
  convertDefinition config defI =<< Load.loadDefinition defI

convertDefinition ::
  Monad m => SugarConfig ->
  Data.DefinitionIRef ->
  Load.DefinitionEntity (T m) ->
  T m (Definition m)
convertDefinition config defI (Data.Definition defBody typeL) = do
  let typeP = void typeL
  body <-
    case defBody of
    Data.DefinitionBuiltin (Data.Builtin name) -> do
      let
        typeI = Property.value $ Data.ePayload typeL
        setName =
          Transaction.writeIRef defI . (`Data.Definition` typeI) .
          Data.DefinitionBuiltin . Data.Builtin
      -- TODO: If we want editable builtin types:
      -- typeS <- convertLoadedExpression Nothing typeL
      return $ DefinitionBodyBuiltin DefinitionBuiltin
        { biName = name
        , biMSetName = Just setName
        }
    Data.DefinitionExpression exprL -> do
      (isSuccess, inferState, exprStored) <-
        inferLoadedExpression (Just defI) exprL
      let
        inferredTypeP =
          Infer.iType . eesInferred $ Data.ePayload exprStored
        typesMatch = on (==) Data.canonizeGuids typeP inferredTypeP
        mkNewType = do
          inferredTypeS <-
            convertExpressionPure config $
            Data.randomizeGuids (mkGen 0 1 (IRef.guid defI)) inferredTypeP
          return DefinitionNewType
            { dntNewType = inferredTypeS
            , dntAcceptNewType =
              Property.set (Data.ePayload typeL) =<<
              DataIRef.newExpression inferredTypeP
            }
        sugarContext =
          SugarContext
          { scInferState = inferState
          , scConfig = config
          }
      content <- convertDefinitionContent sugarContext exprStored
      mNewType <-
        if isSuccess && not typesMatch && isCompleteType inferredTypeP
        then liftM Just mkNewType
        else return Nothing
      return $ DefinitionBodyExpression DefinitionExpression
        { deContent = content
        , deMNewType = mNewType
        , deIsTypeRedundant = isSuccess && typesMatch
        }
  typeS <- convertExpressionPure config typeP
  return Definition
    { drGuid = IRef.guid defI
    , drBody = body
    , drType = typeS
    }

inferLoadedExpression ::
  Monad f =>
  Maybe Data.DefinitionIRef ->
  Load.ExpressionEntity (T m) ->
  T f
  (Bool,
   Infer.RefMap,
   Data.Expression (ExprEntityStored m))
inferLoadedExpression mDefI exprL = do
  loaded <- uncurry (Infer.load loader) Infer.initial mDefI exprL
  return $ inferWithConflicts loaded

inferWithConflicts ::
  Infer.Loaded (DataIRef.ExpressionProperty (T m)) ->
  ( Bool
  , Infer.RefMap
  , Data.Expression (ExprEntityStored m)
  )
inferWithConflicts loaded =
  ( Map.null $ unConflictMap conflictsMap
  , inferContext
  , fmap toExprEntity exprInferred
  )
  where
    ((exprInferred, inferContext), conflictsMap) =
      runWriter $ Infer.infer (Infer.InferActions reportError) loaded
    toExprEntity x =
      ExprEntityInferred
      { eesInferred = x
      , eesValueConflicts = conflicts Infer.tvVal x
      , eesTypeConflicts = conflicts Infer.tvType x
      }
    conflicts getRef x =
      getConflicts ((getRef . Infer.nRefs . Infer.iPoint) x)
      conflictsMap

convertLoadedExpression ::
  Monad m =>
  SugarConfig ->
  Maybe Data.DefinitionIRef ->
  Data.Expression (DataIRef.ExpressionProperty (T m)) ->
  T m (Expression m)
convertLoadedExpression config mDefI exprL = do
  (_, inferState, exprStored) <- inferLoadedExpression mDefI exprL
  convertStoredExpression exprStored $ SugarContext inferState config

convertStoredExpression ::
  Monad m =>
  Data.Expression (ExprEntityStored m) -> SugarContext ->
  T m (Expression m)
convertStoredExpression expr sugarContext =
  runSugar sugarContext . convertExpressionI $
  fmap (Just . fmap Just) expr

removeTypes :: Expression m -> Expression m
removeTypes = removeInferredTypes . (atRExpressionBody . fmap) removeTypes

eesInferredExprs ::
  (Infer.Inferred a -> b) ->
  (ExprEntityInferred a -> [b]) ->
  ExprEntityInferred a -> [b]
eesInferredExprs getVal eeConflicts ee =
  getVal (eesInferred ee) : eeConflicts ee

eesInferredTypes :: ExprEntityInferred a -> [Data.PureExpression]
eesInferredTypes = eesInferredExprs Infer.iType eesTypeConflicts

eesInferredValues :: ExprEntityInferred a -> [Data.PureExpression]
eesInferredValues = eesInferredExprs Infer.iValue eesValueConflicts
