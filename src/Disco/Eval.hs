{-# OPTIONS_GHC -fno-warn-orphans     #-}
  -- For MonadFail instance; see below.

{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeInType                 #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.Eval
-- Copyright   :  disco team and contributors
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- The top-level Disco monad and associated capabilities.
--
-----------------------------------------------------------------------------

module Disco.Eval
       (

         -- * Memory

         Cell(..), mkCell, Loc, Memory, showMemory, garbageCollect
       , withTopEnv

         -- * Errors

       , IErr(..)

         -- * Lenses for top-level info record

       , topModInfo, topCtx, topDefs, topTyDefs, topEnv, topDocs

         -- * Running things

       , runDisco
       , runTCM, runTCMWith

         -- ** Messages
       , emitMessage, info, warning, err, panic, debug
       , catchAsMessage

         -- ** Memory/environment utilities
       , allocate, delay, delay', mkValue, mkSimple

         -- ** Top level phases
       , parseDiscoModule
       , typecheckDisco
       , loadDiscoModule

       )
       where

import           Disco.Effects
import           Disco.Effects.Counter
import           Polysemy
import           Polysemy.Error
import           Polysemy.Output
import           Polysemy.Reader
import           Polysemy.State

import           Control.Monad                    (forM_, when)
import           Data.Bifunctor
import qualified Data.IntMap                      as IntMap
import           Data.IntSet                      (IntSet)
import qualified Data.IntSet                      as IntSet
import qualified Data.Map                         as M
import qualified Data.Set                         as S
import           GHC.Generics                     (Generic)
import           System.FilePath                  ((-<.>))
import           Text.Printf

import           Control.Lens                     (makeLenses, view)
import           Unbound.Generics.LocallyNameless ()

import           Disco.AST.Core
import           Disco.AST.Surface
import           Disco.AST.Typed
import           Disco.Context
import           Disco.Effects.Fresh
import           Disco.Error
import           Disco.Extensions
import           Disco.Messages
import           Disco.Module
import           Disco.Parser
import           Disco.Typecheck                  (checkModule)
import           Disco.Typecheck.Monad
import           Disco.Types
import           Disco.Util
import           Disco.Value

------------------------------------------------------------
-- Disco monad state
------------------------------------------------------------

-- | A record of information about the current top-level environment.
data TopInfo = TopInfo
  { _topModInfo :: ModuleInfo
    -- ^ Info about the top-level currently loaded module.  Due to
    --   import statements this may actually be a combination of info
    --   about multiple physical modules.

  , _topCtx     :: Ctx Term PolyType
    -- ^ Top-level type environment.

  , _topDefs    :: Ctx ATerm Defn
    -- ^ Environment of top-level surface syntax definitions.  Set by
    --   'loadDefs' and by 'let' command at the REPL.

  , _topTyDefs  :: TyDefCtx
    -- ^ Environment of top-level type definitions.

  , _topEnv     :: Env
    -- ^ Top-level environment mapping names to values (which all
    --   start as indirections to thunks).  Set by 'loadDefs'.
    --   Use it when evaluating with 'withTopEnv'.

  , _topDocs    :: Ctx Term Docs
    -- ^ Top-level documentation.
  }
  deriving (Generic)

-- | The initial (empty) record of top-level info.
initTopInfo :: TopInfo
initTopInfo = TopInfo
  { _topModInfo = emptyModuleInfo
  , _topCtx     = emptyCtx
  , _topDefs    = emptyCtx
  , _topTyDefs  = M.empty
  , _topDocs    = emptyCtx
  , _topEnv     = emptyCtx
  }

type DiscoEffects = DiscoEffects' Env Memory IErr

-- -- | The various pieces of state tracked by the 'Disco' monad.
-- data DiscoState r = DiscoState
--   { topInfo     :: IORef (TopInfo)
--     -- ^ Information about the current top-level environment
--     --   (definitions, types, documentation, etc.).

--   , localEnv    :: Env r
--     -- ^ Local environment used during evaluation of expressions.

--   , memory      :: IORef (Memory)
--     -- ^ A memory is a mapping from "locations" (uniquely generated
--     --   identifiers) to values, along with a flag saying whether the
--     --   value has been evaluated yet.  It also keeps track of the
--     --   next unused location.  We keep track of a memory during
--     --   evaluation, and can create new memory locations to store
--     --   things that should only be evaluated once.

--   , nextLoc     :: IORef Loc
--     -- ^ The next available (unused) memory location.

--   , messageLog  :: IORef (MessageLog IErr)
--     -- ^ A stream of messages generated by the system.

--   , lastFile    :: IORef (Maybe FilePath)
--     -- ^ The most recent file which was :loaded by the user.

--   , enabledExts :: IORef ExtSet
--     -- ^ The set of language extensions currently enabled in the REPL.
--     --   Note this affects only expressions entered at the REPL
--     --   prompt, not modules loaded into the REPL; each module
--     --   specifies its own extensions.
--   }
--   deriving (Generic)

-- -- | The initial state for the @Disco@ monad.
-- initDiscoState :: IO DiscoState
-- initDiscoState = do
--   topInfoRef    <- newIORef initTopInfo
--   memoryRef     <- newIORef IntMap.empty
--   nextLocRef    <- newIORef 0
--   messageLogRef <- newIORef emptyMessageLog
--   lastFileRef   <- newIORef Nothing
--   extsRef       <- newIORef defaultExts
--   return $ DiscoState
--     { topInfo       = topInfoRef
--     , localEnv      = emptyCtx
--     , memory        = memoryRef
--     , nextLoc       = nextLocRef
--     , messageLog    = messageLogRef
--     , lastFile      = lastFileRef
--     , enabledExts   = extsRef
--     }

------------------------------------------------------------
-- Running top-level Disco computations
------------------------------------------------------------

-- | Run a top-level Disco computation, starting in the empty
--   environment.
runDisco :: Sem (Embed IO ': DiscoEffects) a -> IO (Either IErr a)
runDisco d = undefined
  -- s <- initDiscoState
  -- flip CMC.catch (return . Left)
  --   . fmap Right
  --   . runLFreshMT
  --   . flip CMR.runReaderT s
  --   . unDisco
  --   $ d

------------------------------------------------------------
-- Lenses
------------------------------------------------------------

makeLenses ''TopInfo

------------------------------------------------------------
-- Messages
------------------------------------------------------------

emitMessage :: Member (Output (Message IErr)) r => MessageLevel -> MessageBody IErr -> Sem r ()
emitMessage lev body = output $ Message lev body

info, warning, err, panic, debug :: Member (Output (Message IErr)) r => MessageBody IErr -> Sem r ()
info    = emitMessage Info
warning = emitMessage Warning
err     = emitMessage Error
panic   = emitMessage Panic
debug   = emitMessage Debug

-- | Run a computation; if it throws an exception, catch it and turn
--   it into a message.
catchAsMessage :: Member (Output (Message IErr)) r => Sem (Error TCError ': r) () -> Sem r ()
catchAsMessage m = do
  res <- runError m
  case res of
    Left tce -> err (Item (TypeCheckErr tce))
    Right _  -> pure ()

------------------------------------------------------------
-- Memory/environment utilities
------------------------------------------------------------

-- | Run a computation with the top-level environment used as the
--   current local environment.  For example, this is used every time
--   we start evaluating an expression entered at the command line.
withTopEnv :: Member (State TopInfo) r => Sem (Reader Env ': r) a -> Sem r a
withTopEnv m = do
  e <- gets (view topEnv)
  runReader e m

-- | Allocate a new memory cell for the given value, and return its
--   'Loc'.
allocate :: Members '[Counter, State Memory] r => Value -> Sem r Loc
allocate v = do
  loc <- next
  -- io $ putStrLn $ "allocating " ++ show v ++ " at location " ++ show loc
  modify $ IntMap.insert loc (mkCell v)
  return loc

-- | Turn a value into a "simple" value which takes up a constant
--   amount of space: some are OK as they are; for others, we turn
--   them into an indirection and allocate a new memory cell for them.
mkSimple :: Members '[Counter, State Memory] r => Value -> Sem r Value
mkSimple v@VNum{}         = return v
mkSimple v@VUnit{}        = return v
mkSimple v@(VInj _ VUnit) = return v
mkSimple v@VConst{}       = return v
mkSimple v@VClos{}        = return v
mkSimple v@VType{}        = return v
mkSimple v@VIndir{}       = return v
mkSimple v                = VIndir <$> allocate v

-- | Delay a @Disco Value@ computation by packaging it into a
--   @VDelay@ constructor along with the current environment.
delay :: Members DiscoEffects r => (forall r'. Members DiscoEffects r' => Sem r' Value) -> Sem r Value
delay = delay' []

-- | Like 'delay', but also specify a set of values which will be
--   needed during the delayed computation, to prevent any memory
--   referenced by the values from being garbage collected.
delay' :: Members DiscoEffects r => [Value] -> (forall r'. Members DiscoEffects r' => Sem r' Value) -> Sem r Value
delay' vs imv = do
  ls <- getReachable vs
  VDelay imv ls <$> getEnv

-- | Turn a Core expression into a value.  Some kinds of expressions
--   can be turned into corresponding values directly; for others we
--   create a thunk by packaging up the @Core@ expression with the
--   current environment.  The thunk is stored in a new location in
--   memory, and the returned value consists of an indirection
--   referring to its location.
mkValue :: Members '[Reader Env, Counter, State Memory] r => Core -> Sem r Value
mkValue (CConst op)   = return $ VConst op
mkValue CUnit         = return VUnit
mkValue (CInj s v)    = VInj s <$> mkValue v
mkValue (CPair v1 v2) = VPair <$> mkValue v1 <*> mkValue v2
mkValue (CNum d r)    = return $ VNum d r
mkValue (CType ty)    = return $ VType ty
mkValue c             = VIndir <$> (allocate . VThunk c =<< getEnv)

-- | Deallocate any memory cells which are no longer referred to by
--   any top-level binding.
garbageCollect :: Members '[State TopInfo, State Memory] r => Sem r ()
garbageCollect = do
  env  <- gets @TopInfo (view topEnv)
  keep <- getReachable env
  modify @Memory $ \mem ->
    IntMap.withoutKeys mem (IntMap.keysSet mem `IntSet.difference` keep)

-- | Get the set of memory locations reachable from a set of values.
getReachable :: (Reachable v, Members '[State Memory] r) => v -> Sem r IntSet
getReachable = execState IntSet.empty . reachable

class Reachable v where
  -- | @reachable v@ marks the memory locations reachable from the
  --   values stored in @v@.
  reachable :: Members '[State Memory, State IntSet] r => v -> Sem r ()

instance Reachable Value where
  reachable (VInj _ v)      = reachable v
  reachable (VPair v1 v2)   = reachable v1 >> reachable v2
  reachable (VClos _ e)     = reachable e
  reachable (VPAp v vs)     = reachable (v:vs)
  reachable (VThunk _ e)    = reachable e
  reachable (VIndir l)      = reachable l
  reachable (VDelay _ ls e) = (modify @IntSet $ IntSet.union ls) >> reachable e
  reachable (VBag vs)       = reachable (map fst vs)
  reachable (VProp p)       = reachable p
  reachable (VGraph _ adj)  = reachable adj
    -- A graph can only contain SimpleValues, which by def contain no indirection.
    -- However its buffered adjacency map can.
  reachable (VMap m)        = reachable (M.elems m)
  reachable _               = return ()

instance Reachable Env where
  reachable = reachable . M.elems

instance Reachable v => Reachable [v] where
  reachable = mapM_ reachable

instance Reachable ValProp where
  reachable (VPDone (TestResult _ r vs)) = mapM_ reachable r >> reachable vs
  reachable (VPSearch _ _ v vs)          = reachable v >> reachable vs

instance Reachable TestEnv where
  reachable (TestEnv te) = forM_ te $ \(_, _, v) -> reachable v

instance Reachable Loc where
  reachable l = do
    reach <- get @IntSet
    case IntSet.member l reach of
      True -> return ()
      False -> do
        modify $ IntSet.insert l
        mem <- get @Memory
        case IntMap.lookup l mem of
          Nothing         -> return ()
          Just (Cell v _) -> reachable v

showMemory :: Members '[State Memory, Embed IO] r => Sem r ()
showMemory = get >>= (mapM_ showCell . IntMap.assocs)
  where
    showCell :: Member (Embed IO) r => (Int, Cell) -> Sem r ()
    showCell (i, Cell v b) = embed $ printf "%3d%s %s\n" i (if b then "!" else " ") (show v)

------------------------------------------------------------
-- High-level disco phases
------------------------------------------------------------

--------------------------------------------------
-- Parsing

-- | Parse a module from a file, re-throwing a parse error if it
--   fails.
parseDiscoModule :: Members '[Error IErr, Embed IO] r => FilePath -> Sem r Module
parseDiscoModule file = do
  str <- io $ readFile file
  fromEither . first ParseErr $ runParser wholeModule file str

--------------------------------------------------
-- Type checking

-- | Run a typechecking computation, providing it with local
--   (initially empty) contexts for variable types and type
--   definitions.
runTCM
  :: Member (Error IErr) r
  => Sem (Reader TyCtx ': Reader TyDefCtx ': Fresh ': Error TCError ': r) a
  -> Sem r a
runTCM = runTCMWith emptyCtx M.empty

-- | Run a typechecking computation, providing it with local contexts
--   (initialized to the provided arguments) for variable types and
--   type definitions.
runTCMWith
  :: Member (Error IErr) r
  => TyCtx -> TyDefCtx
  -> Sem (Reader TyCtx ': Reader TyDefCtx ': Fresh ': Error TCError ': r) a
  -> Sem r a
runTCMWith tyCtx tyDefCtx
  = mapError TypeCheckErr
  . runFresh
  . runReader @TyDefCtx tyDefCtx
  . runReader @TyCtx tyCtx

-- | Run a typechecking computation, re-throwing a wrapped error if it
--   fails.
typecheckDisco
  :: Members '[State TopInfo, Error IErr] r
  => Sem (Reader TyCtx ': Reader TyDefCtx ': Fresh ': Error TCError ': r) a
  -> Sem r a
typecheckDisco tcm = do
  tyctx  <- gets (view topCtx)
  tydefs <- gets (view topTyDefs)
  runTCMWith tyctx tydefs tcm

-- | Recursively loads a given module by first recursively loading and
--   typechecking its imported modules, adding the obtained
--   'ModuleInfo' records to a map from module names to info records,
--   and then typechecking the parent module in an environment with
--   access to this map. This is really just a depth-first search.
--
--   If the given directory is Just, it will only load a module from
--   the specific given directory.  If it is Nothing, then it will look for
--   the module in the current directory or the standard library.
loadDiscoModule :: Members '[Error IErr, Embed IO] r => Resolver -> ModName -> Sem r ModuleInfo
loadDiscoModule resolver m =
  evalState M.empty $ loadDiscoModule' resolver S.empty m

-- | Recursively load a Disco module while keeping track of an extra
--   Map from module names to 'ModuleInfo' records, to avoid loading
--   any imported module more than once.
loadDiscoModule'
  :: Members '[Error IErr, Embed IO, State (M.Map ModName ModuleInfo)] r
  => Resolver -> S.Set ModName -> ModName
  -> Sem r ModuleInfo
loadDiscoModule' resolver inProcess modName  = do
  when (S.member modName inProcess) (throw $ CyclicImport modName)
  modMap <- get
  case M.lookup modName modMap of
    Just mi -> return mi
    Nothing -> do
      file <- resolveModule resolver modName
             >>= maybe (throw $ ModuleNotFound modName) return
      io . putStrLn $ "Loading " ++ (modName -<.> "disco") ++ "..."
      cm@(Module _ mns _ _) <- parseDiscoModule file

      -- mis only contains the module info from direct imports.
      mis <- mapM (loadDiscoModule' (withStdlib resolver) (S.insert modName inProcess)) mns
      imports@(ModuleInfo _ _ tyctx tydefns _) <- mapError TypeCheckErr $ combineModuleInfo mis
      m  <- runTCMWith tyctx tydefns (checkModule cm)
      m' <- mapError TypeCheckErr $ combineModuleInfo [imports, m]
      modify (M.insert modName m')
      return m'
