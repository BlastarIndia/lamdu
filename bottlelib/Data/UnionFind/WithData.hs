{-# LANGUAGE TemplateHaskell, DeriveFunctor #-}
module Data.UnionFind.WithData
  ( UFData, empty
  , fresh, find
  , readRep, writeRep
  , popRep
  , read, write, modify
  , union, equiv
  , UnifyRefsResult(..)
  , unifyRefs
  , optimize
  ) where

import Control.Applicative ((<$>), Applicative(..))
import Control.Arrow ((***))
import Control.Lens.Operators
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.State (StateT(..), execStateT, evalState)
import Control.Monad.Trans.Writer (runWriter)
import Control.MonadA (MonadA)
import Data.Binary (Binary(..))
import Data.Foldable (traverse_)
import Data.Maybe.Utils (unsafeUnjust)
import Data.OpaqueRef (Ref, RefMap)
import Prelude hiding (read)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.OpaqueRef as OR
import qualified Data.UnionFind as UF

data UFData p a = UFData
  { _ufdUF :: UF.UnionFind p
  , _ufdData :: RefMap p a
  } deriving (Functor)
Lens.makeLenses ''UFData

instance Binary a => Binary (UFData p a) where
  get = UFData <$> get <*> get
  put (UFData x y) = put x >> put y

empty :: UFData p a
empty = UFData
  { _ufdUF = UF.empty
  , _ufdData = OR.refMapEmpty
  }

fresh :: MonadA m => a -> StateT (UFData p a) m (Ref p)
fresh dat = do
  rep <- Lens.zoom ufdUF UF.freshRef
  writeRep rep dat
  return rep

find :: MonadA m => Ref p -> StateT (UFData p a) m (Ref p)
find = Lens.zoom ufdUF . UF.find

readRep :: Show p => Ref p -> UFData p a -> a
readRep rep ufData =
  unsafeUnjust ("readRep: missing ref: " ++ show rep) $
  ufData ^. ufdData . Lens.at rep

popRep ::
  (MonadA m, Show p) => Ref p -> StateT (UFData p a) m a
popRep rep =
  Lens.zoom (ufdData . Lens.at rep) $
  unsafeUnjust ("popRep: missing ref: " ++ show rep)
  <$> State.get <* State.put Nothing

writeRep ::
  Monad m => Ref p -> a -> StateT (UFData p a) m ()
writeRep rep dat = ufdData . Lens.at rep .= Just dat

read :: (MonadA m, Show p) => Ref p -> StateT (UFData p a) m a
read ref = State.gets . readRep =<< find ref

write ::
  MonadA m => Ref p -> a -> StateT (UFData p a) m ()
write ref dat = (`writeRep` dat) =<< find ref

modify ::
  (MonadA m, Show p) => Ref p -> (a -> a) ->
  StateT (UFData p a) m ()
modify ref f = write ref . f =<< read ref

union :: MonadA m => Ref p -> Ref p -> StateT (UFData p a) m (Ref p)
union x y = Lens.zoom ufdUF $ UF.union x y

equiv :: MonadA m => Ref p -> Ref p -> StateT (UFData p a) m Bool
equiv x y = Lens.zoom ufdUF $ UF.equivalent x y

data UnifyRefsResult a
  = UnifyRefsAlreadyUnified
  | UnifyRefsUnified a a

unifyRefs ::
  (MonadA m, Show p) => Ref p -> Ref p ->
  StateT (UFData p a) m (Ref p, UnifyRefsResult a)
unifyRefs x y = do
  xRep <- find x
  yRep <- find y
  if xRep == yRep
    then return (xRep, UnifyRefsAlreadyUnified)
    else do
      xData <- popRep xRep
      yData <- popRep yRep
      rep <- x `union` y
      writeRep rep $ error "unifyRefs caller read the unified ref data before writing it"
      return (rep, UnifyRefsUnified xData yData)

optimize ::
  ((Ref p -> Ref p) -> a -> b) -> UFData p a -> (Ref p -> Ref p, UFData p b)
optimize onData (UFData oldUf oldRefsData) =
  ( refRename "UFData.optimize:user ref inexistent"
  , UFData newUf newRefsData
  )
  where
    (newUf, refRenames) =
      runWriter . (`execStateT` UF.empty) $
      oldRefsData ^.. OR.unsafeRefMapItems . Lens._1 & traverse_ %%~ freshRef
    refRename msg oldRef =
      let oldRep = (`evalState` oldUf) $ UF.find oldRef
      in refRenames ^? Lens.ix oldRep & unsafeUnjust msg
    newRefsData =
      oldRefsData
      & OR.unsafeRefMapItems %~
        (refRename "optimize:onOldRefItem"
         ***
         onData (refRename "optimize:onRefData"))
    freshRef oldRep = do
      newRep <- UF.freshRef
      lift $ Writer.tell (OR.refMapSingleton oldRep newRep)
