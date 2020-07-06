{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs     #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.Interactive.Commands
-- Copyright   :  disco team and contributors
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-----------------------------------------------------------------------------

module Disco.Interactive.Commands
  (
    dispatch,
    discoCommands,
    handleLoad,
    loadFile
  ) where

import           Disco.Parser                            (ident, sc, term)


import           System.Console.Haskeline                as H
import           Unbound.Generics.LocallyNameless.Unsafe (unsafeUnbind)

import           Control.Arrow                           ((&&&))
import           Control.Lens                            (use, (%=), (.=))
import           Control.Monad.Except
import           Data.Coerce
import           Data.List                               (sortBy)
import qualified Data.Map                                as M
import           Data.Typeable
import           System.FilePath                         (splitFileName)

import           Disco.AST.Surface
import           Disco.AST.Typed
import           Disco.Compile
import           Disco.Context
import           Disco.Desugar
import           Disco.Eval
import           Disco.Extensions
import           Disco.Interactive.Parser
import           Disco.Interactive.Types
import           Disco.Interpret.Core
import           Disco.Module
import           Disco.Parser                            (parseExtName,
                                                          parseImport, reserved)
import           Disco.Pretty
import           Disco.Property
import           Disco.Typecheck
import           Disco.Typecheck.Erase
import           Disco.Typecheck.Monad
import           Disco.Types
import           Text.Megaparsec                         hiding (runParser)
import           Unbound.Generics.LocallyNameless

dispatch :: [SomeREPLCommand] -> SomeREPLExpr -> Disco IErr ()
dispatch [] _ = return ()
dispatch (SomeCmd c : cs) r@(SomeREPL e) = case gcast e of
  Just e' -> action c e'
  Nothing -> dispatch cs r

discoCommands :: [SomeREPLCommand]
discoCommands =
  [
    SomeCmd annCmd,
    SomeCmd compileCmd,
    SomeCmd desugarCmd,
    SomeCmd docCmd,
    SomeCmd evalCmd,
    SomeCmd helpCmd,
    SomeCmd importCmd,
    SomeCmd letCmd,
    SomeCmd loadCmd,
    SomeCmd namesCmd,
    SomeCmd nopCmd,
    SomeCmd parseCmd,
    SomeCmd prettyCmd,
    SomeCmd reloadCmd,
    SomeCmd showDefnCmd,
    SomeCmd typeCheckCmd,
    SomeCmd usingCmd
  ]

------------------------------------------
-- Commands
------------------------------------------

annCmd :: REPLCommand 'CAnn
annCmd =
    REPLCommand {
      name = "ann",
      helpcmd = ":ann",
      shortHelp = "Show type-annotated typechecked term",
      category = Dev,
      cmdtype = ShellCmd,
      action = handleAnn,
      parser = Ann <$> term
    }

handleAnn :: REPLExpr 'CAnn -> Disco IErr ()
handleAnn (Ann t) = do
    ctx   <- use topCtx
    tymap <- use topTyDefns
    s <- case (evalTCM $ extends ctx $ withTyDefns tymap $ inferTop t) of
        Left  e       -> return . show $ e
        Right (at, _) -> return . show $ at
    iputStrLn s

compileCmd :: REPLCommand 'CCompile
compileCmd =
    REPLCommand {
      name = "compile",
      helpcmd = ":compile",
      shortHelp = "Show a compiled term",
      category = Dev,
      cmdtype = ShellCmd,
      action = handleCompile,
      parser = Compile <$> term
    }

handleCompile :: REPLExpr 'CCompile -> Disco IErr ()
handleCompile (Compile t) = do
  ctx <- use topCtx
  s <- case evalTCM (extends ctx $ inferTop t) of
        Left e       -> return . show $ e
        Right (at,_) -> return . show . compileTerm $ at
  iputStrLn s


desugarCmd :: REPLCommand 'CDesugar
desugarCmd =
    REPLCommand {
      name = "desugar",
      helpcmd = ":desugar",
      shortHelp = "Show a desugared term",
      category = Dev,
      cmdtype = ShellCmd,
      action = handleDesugar,
      parser = Desugar <$> term
    }

handleDesugar :: REPLExpr 'CDesugar -> Disco IErr ()
handleDesugar (Desugar t) = do
  ctx <- use topCtx
  s <- case evalTCM (extends ctx $ inferTop t) of
        Left e       -> return.show $ e
        Right (at,_) -> renderDoc . prettyTerm . eraseDTerm . runDSM . desugarTerm $ at
  iputStrLn s

docCmd :: REPLCommand 'CDoc
docCmd =
    REPLCommand {
      name = "doc",
      helpcmd = ":doc <term>\t",
      shortHelp = "Show documentation",
      category = User,
      cmdtype = ShellCmd,
      action = handleDoc,
      parser = Doc <$> (sc *> ident)
    }

handleDoc :: REPLExpr 'CDoc -> Disco IErr ()
handleDoc (Doc x) = do
  ctx  <- use topCtx
  docs <- use topDocs
  case M.lookup x ctx of
    Nothing -> io . putStrLn $ "No documentation found for " ++ show x ++ "."
    Just ty -> do
      p  <- renderDoc . hsep $ [prettyName x, text ":", prettyPolyTy ty]
      io . putStrLn $ p
      case M.lookup x docs of
        Just (DocString ss : _) -> io . putStrLn $ "\n" ++ unlines ss
        _                       -> return ()

evalCmd :: REPLCommand 'CEval
evalCmd =
    REPLCommand {
      name = "eval",
      helpcmd = "<eval>\t\t",
      shortHelp = "Evaluate a term",
      category = User,
      cmdtype = BuiltIn,
      action = handleEval,
      parser = Eval <$> term
    }

handleEval :: REPLExpr 'CEval -> Disco IErr ()
handleEval (Eval t) = do
  ctx   <- use topCtx
  tymap <- use topTyDefns
  case evalTCM (extends ctx $ withTyDefns tymap $ inferTop t) of
    Left e   -> iprint e    -- XXX pretty-print
    Right (at,_) ->
      let ty = getType at
          c  = compileTerm at
      in do
        v <- withTopEnv $ do
          cv <- mkValue c
          prettyValue ty cv
          return cv
        topCtx %= M.insert (string2Name "it") (toPolyType ty)
        topEnv %= M.insert (string2Name "it") v
        garbageCollect

helpCmd :: REPLCommand 'CHelp
helpCmd =
    REPLCommand {
      name = "help",
      helpcmd = ":help\t\t",
      shortHelp = "Show help",
      category = User,
      cmdtype = ShellCmd,
      action = handleHelp,
      parser = return Help
    }

handleHelp :: REPLExpr 'CHelp -> Disco IErr ()
handleHelp Help = do
  iputStrLn "Commands available from the prompt:\n"
  mapM_ (\(SomeCmd c) -> iputStrLn $ showCmd c) $  sortedList discoCommands
  iputStrLn ""
  where
    sortedList cmds = sortBy (\(SomeCmd x) (SomeCmd y) -> compare (name x) (name y)) $ filteredCommands cmds
    --  don't show dev-only commands by default
    filteredCommands cmds = filter (\(SomeCmd c) -> category c == User) cmds
    showCmd (REPLCommand { helpcmd = h, shortHelp = sh}) = h ++ "\t" ++ sh

importCmd :: REPLCommand 'CImport
importCmd =
    REPLCommand {
      name = "import",
      helpcmd = ":import <module>",
      shortHelp = "Import a library module",
      category = User,
      cmdtype = BuiltIn,
      action = handleImport,
      parser = Import <$> parseImport
    }

handleImport :: REPLExpr 'CImport -> Disco IErr ()
handleImport (Import modName) = catchAndPrintErrors () $ do
  mi <- loadDiscoModule FromCwdOrStdlib modName
  addModule mi


letCmd :: REPLCommand 'CLet
letCmd =
    REPLCommand {
      name = "let",
      helpcmd = "let <expression>",
      shortHelp = "Toplevel let-expression: for the REPL",
      category = User,
      cmdtype = BuiltIn,
      action = handleLet,
      parser = letParser
    }

handleLet :: REPLExpr 'CLet -> Disco IErr ()
handleLet (Let x t) = do
  ctx <- use topCtx
  tymap <- use topTyDefns
  let mat = evalTCM (extends ctx $ withTyDefns tymap $ inferTop t)
  case mat of
    Left e -> io.print $ e   -- XXX pretty print
    Right (at, sig) -> do
      let c = compileTerm at
      thnk <- withTopEnv (mkValue c)
      topCtx   %= M.insert x sig
        -- XXX ability to define more complex things at REPL prompt, with patterns etc.
      topDefns %= M.insert (coerce x) (Defn (coerce x) [] (getType at) [bind [] at])
      topEnv   %= M.insert (coerce x) thnk


loadCmd :: REPLCommand 'CLoad
loadCmd =
    REPLCommand {
      name = "load",
      helpcmd = ":load <filename>",
      shortHelp = "Load a file",
      category = User,
      cmdtype = ShellCmd,
      action = handleLoadWrapper,
      parser = Load <$> fileParser
    }

-- | Parses, typechecks, and loads a module by first recursively loading any imported
--   modules by calling loadDiscoModule. If no errors are thrown, any tests present
--   in the parent module are executed. 
--   Disco.Interactive.CmdLine uses a version of this function that returns a Bool.
handleLoadWrapper :: REPLExpr 'CLoad -> Disco IErr ()
handleLoadWrapper (Load fp) =  handleLoad fp >> return ()

handleLoad :: FilePath -> Disco IErr Bool
handleLoad fp = catchAndPrintErrors False $ do
  let (directory, modName) = splitFileName fp
  m@(ModuleInfo _ props _ _ _) <- loadDiscoModule (FromDir directory) modName
  setLoadedModule m
  t <- withTopEnv $ runAllTests props
  io . putStrLn $ "Loaded."
  garbageCollect
  return t


namesCmd :: REPLCommand 'CNames
namesCmd =
    REPLCommand {
      name = "names",
      helpcmd = ":names\t\t",
      shortHelp = "Show all names in current scope",
      category = User,
      cmdtype = ShellCmd,
      action = handleNames,
      parser = return Names
    }

-- | show names and types for each item in 'topCtx'
handleNames :: REPLExpr 'CNames -> Disco IErr ()
handleNames Names = do
  ctx  <- use topCtx
  mapM_ showFn $ M.toList ctx
  where
      showFn (x, ty) = do
        p  <- renderDoc . hsep $ [prettyName x, text ":", prettyPolyTy ty]
        io . putStrLn $ p


nopCmd :: REPLCommand 'CNop
nopCmd =
    REPLCommand {
      name = "nop",
      helpcmd = "",
      shortHelp = "No-op, e.g. if the user just enters a comment",
      category = Dev,
      cmdtype = BuiltIn,
      action = handleNop,
      parser = Nop <$ (sc <* eof)
    } 

handleNop :: REPLExpr 'CNop -> Disco IErr ()
handleNop Nop = return ()


parseCmd :: REPLCommand 'CParse
parseCmd =
    REPLCommand {
      name = "parse",
      helpcmd = ":parse <expr>",
      shortHelp = "Show the parsed AST",
      category = Dev,
      cmdtype = ShellCmd,
      action = handleParse,
      parser = Parse <$> term
    }

handleParse :: REPLExpr 'CParse -> Disco IErr ()
handleParse (Parse t) = iprint $ t


prettyCmd :: REPLCommand 'CPretty
prettyCmd =
    REPLCommand {
      name = "pretty",
      helpcmd = ":pretty <expr>",
      shortHelp = "Pretty-print a term",
      category = Dev,
      cmdtype = ShellCmd,
      action = handlePretty,
      parser = Pretty <$> term
    }

handlePretty :: REPLExpr 'CPretty -> Disco IErr ()
handlePretty (Pretty t) = renderDoc (prettyTerm t) >>= iputStrLn


reloadCmd :: REPLCommand 'CReload
reloadCmd =
    REPLCommand {
      name = "reload",
      helpcmd = ":reload\t\t",
      shortHelp = "Reloads the most recently loaded file",
      category = User,
      cmdtype = ShellCmd,
      action = handleReload,
      parser = return Reload
    }

handleReload :: REPLExpr 'CReload -> Disco IErr ()
handleReload Reload = do
      file <- use lastFile
      case file of
        Nothing -> iputStrLn "No file to reload."
        Just f  -> handleLoad f >> return()


showDefnCmd :: REPLCommand 'CShowDefn
showDefnCmd =
    REPLCommand {
      name = "defn",
      helpcmd = ":defn <var>\t",
      shortHelp = "Show a variable's definition",
      category = User,
      cmdtype = ShellCmd,
      action = handleShowDefn,
      parser = ShowDefn <$> (sc *> ident)
    }

handleShowDefn :: REPLExpr 'CShowDefn -> Disco IErr ()
handleShowDefn (ShowDefn x) = do
  defns   <- use topDefns
  tyDefns <- use topTyDefns
  s <- case M.lookup (coerce x) defns of
          Just d  -> renderDoc $ prettyDefn d
          Nothing -> case M.lookup name2s tyDefns of
            Just t  -> renderDoc $ prettyTyDef name2s t
            Nothing -> return $ "No definition for " ++ show x
  iputStrLn s
  where
    name2s = name2String x


typeCheckCmd :: REPLCommand 'CTypeCheck
typeCheckCmd =
    REPLCommand {
        name = "type",
        helpcmd = ":type <term>",
        shortHelp = "Typecheck a term",
        category = Dev,
        cmdtype = ShellCmd,
        action = handleTypeCheck,
        parser = TypeCheck <$> (try term <?> "expression")
        }


handleTypeCheck :: REPLExpr 'CTypeCheck -> Disco IErr ()
handleTypeCheck (TypeCheck t) = do
  ctx <- use topCtx
  tymap <- use topTyDefns
  s <- case (evalTCM $ extends ctx $ withTyDefns tymap $ inferTop t) of
        Left e        -> return.show $ e    -- XXX pretty-print
        Right (_,sig) -> renderDoc $ prettyTerm t <+> text ":" <+> prettyPolyTy sig
  iputStrLn s

usingCmd :: REPLCommand 'CUsing
usingCmd =
    REPLCommand {
        name = "using",
        helpcmd = ":using <extension>",
        shortHelp = "Enable an extension",
        category = Dev,
        cmdtype = BuiltIn,
        action = handleUsing,
        parser = Using <$> (reserved "using" *> parseExtName)
        }

handleUsing :: REPLExpr 'CUsing -> Disco IErr ()
handleUsing (Using e) = enabledExts %= addExtension e

------------------------------------------
--- Util functions
------------------------------------------

addModule :: ModuleInfo -> Disco IErr ()
addModule mi = do
  curMI <- use topModInfo
  mi' <- adaptError TypeCheckErr $ combineModuleInfo [curMI, mi]
  topModInfo .= mi'
  populateCurrentModuleInfo

fileNotFound :: FilePath -> IOException -> IO ()
fileNotFound file _ = putStrLn $ "File not found: " ++ file

loadFile :: FilePath -> Disco IErr (Maybe String)
loadFile file = io $ handle (\e -> fileNotFound file e >> return Nothing) (Just <$> readFile file)

populateCurrentModuleInfo :: Disco IErr ()
populateCurrentModuleInfo = do
  ModuleInfo docs _ tys tyds tmds <- use topModInfo
  let cdefns = M.mapKeys coerce $ fmap compileDefn tmds
  topDocs    .= docs
  topCtx     .= tys
  topTyDefns .= tyds
  topDefns   .= tmds
  loadDefs cdefns
  return ()

-- XXX comment, move somewhere else
prettyCounterexample :: Ctx ATerm Type -> Env -> Disco IErr ()
prettyCounterexample ctx env
  | M.null env = return ()
  | otherwise  = do
      iputStrLn "    Counterexample:"
      let maxNameLen = maximum . map (length . name2String) $ M.keys env
      mapM_ (prettyBind maxNameLen) $ M.assocs env
  where
    prettyBind maxNameLen (x,v) = do
      iputStr "      "
      iputStr =<< (renderDoc . prettyName $ x)
      iputStr (replicate (maxNameLen - length (name2String x)) ' ')
      iputStr " = "
      prettyValue (ctx !? coerce x) v
    m !? k = case M.lookup k m of
      Just val -> val
      Nothing  -> error $ "Failed M.! with key " ++ show k ++ " in map " ++ show m

-- XXX redo with message framework, with proper support for indentation etc.
-- XXX also move it to Property or Pretty or somewhere like that
prettyTestFailure :: AProperty -> TestResult -> Disco IErr ()
prettyTestFailure _ (TestOK {}) = return ()
prettyTestFailure prop (TestFalse env) = do
  dp <- renderDoc $ prettyProperty (eraseProperty prop)
  iputStr "  - Test is false: " >> iputStrLn dp
  let qTys = M.fromList . fst . unsafeUnbind $ prop
  prettyCounterexample qTys env
prettyTestFailure prop (TestEqualityFailure ty v1 v2 env) = do
  iputStr     "  - Test result mismatch for: "
  dp <- renderDoc $ prettyProperty (eraseProperty prop)
  iputStrLn dp
  iputStr     "    - Expected: " >> prettyValue ty v2
  iputStr     "    - But got:  " >> prettyValue ty v1
  let qTys = M.fromList . fst . unsafeUnbind $ prop
  prettyCounterexample qTys env
prettyTestFailure prop (TestRuntimeFailure e) = do
  iputStr     "  - Test failed: "
  dp <- renderDoc $ prettyProperty (eraseProperty prop)
  iputStrLn dp
  iputStr     "    " >> iprint e

-- XXX Return a structured summary of the results, not a Bool;
-- separate out results generation and pretty-printing.  Then move it
-- to the Property module.
runAllTests :: Ctx ATerm [AProperty] -> Disco IErr Bool  -- (Ctx ATerm [TestResult])
runAllTests aprops
  | M.null aprops = return True
  | otherwise     = do
      io $ putStrLn "Running tests..."
      and <$> mapM (uncurry runTests) (M.assocs aprops)
      -- XXX eventually this should be moved into Disco.Property and
      -- use a logging framework?

  where
    numSamples :: Int
    numSamples = 50   -- XXX make this configurable somehow

    runTests :: Name ATerm -> [AProperty] -> Disco IErr Bool
    runTests n props = do
      iputStr ("  " ++ name2String n ++ ":")
      results <- sequenceA . fmap sequenceA $ map (id &&& runTest numSamples) props
      let failures = filter (not . testIsOK . snd) results
      case null failures of
        True  -> iputStrLn " OK"
        False -> do
          iputStrLn ""
          forM_ failures (uncurry prettyTestFailure)
      return (null failures)

-- | Add information from ModuleInfo to the Disco monad. This includes updating the
--   Disco monad with new term definitions, documentation, types, and type definitions.
--   Replaces any previously loaded module.
setLoadedModule :: ModuleInfo -> Disco IErr ()
setLoadedModule mi = do
  topModInfo .= mi
  populateCurrentModuleInfo
