module Kit.Compiler (
  tryCompile,
  module Kit.Compiler.Binding,
  module Kit.Compiler.Context,
  module Kit.Compiler.Module,
  module Kit.Compiler.Passes,
  module Kit.Compiler.Scope,
  module Kit.Compiler.TypeContext,
  module Kit.Compiler.Unify
) where

import Control.Exception
import Control.Monad
import Data.IORef
import Data.List
import System.Directory
import System.FilePath
import System.Process
import Kit.Ast
import Kit.Ir
import Kit.Compiler.Binding
import Kit.Compiler.Context
import Kit.Compiler.DumpAst
import Kit.Compiler.Module
import Kit.Compiler.Passes
import Kit.Compiler.Scope
import Kit.Compiler.TypeContext
import Kit.Compiler.TypedExpr
import Kit.Compiler.Unify
import Kit.Compiler.Utils
import Kit.Error
import Kit.HashTable
import Kit.Log
import Kit.Parser
import Kit.Str

tryCompile :: CompileContext -> IO (Either KitError ())
tryCompile context = try $ compile context

{-
  Run compilation to completion from the given CompileContext. Throws an
  Error on failure.
-}
compile :: CompileContext -> IO ()
compile ctx = do
  {-
    Load the main module and all of its dependencies recursively. Also builds
    module interfaces, which declare the set of types that exist in a module
    and map them to type variables.
  -}
  printLog "parsing and building module graph"
  declarations <- buildModuleGraph ctx

  {-
    Generate C modules for all includes found during buildModuleGraph.
  -}
  printLog "processing C includes"
  includeCModules ctx

  {-
    This step utilizes the module interfaces from buildModuleGraph to convert
    syntactic types to preliminary typed AST. Type annotations will be looked
    up and will fail if they don't resolve, but program semantics won't be
    checked yet; we'll get typed AST with a lot of spurious type variables,
    which will be unified later.
  -}
  printLog "resolving module types"
  resolved <- resolveModuleTypes ctx declarations

  compilerSanityChecks ctx

  {-
    TODO: expand procedural macros here
  -}

  {-
    Main checking of program semantics happens here. Takes and returns typed
    AST, but the return value should have all necessary type information. This
    step is iterative and repeats until successful convergence, or throws an
    exception on failure.
  -}
  printLog "typing module content"
  typedRaw <- typeContent ctx resolved
  let
    typed =
      [ (fst $ head x, map snd x)
      | x <- groupBy
        (\a b -> (modPath $ fst a) == (modPath $ fst b))
        (sortBy (\a b -> compare (modPath $ fst a) (modPath $ fst b)) typedRaw)
      , not $ null x
      ]

  when (ctxDumpAst ctx) $ do
    printLog "typed AST:"
    forM_ typed (\(mod, decls) -> dumpModuleContent ctx mod decls)

  {-
    Convert typed AST to IR.
  -}
  printLog "generating intermediate representation"
  irRaw <- generateIr ctx typed
  let ir =
        [ (fst $ head x, [foldr mergeBundles (snd $ head x) (map snd $ tail x)])
        | x <- groupBy
          (\a b ->
            ((modPath $ fst a) == (modPath $ fst b))
              && (bundleTp (snd a) == bundleTp (snd b))
          )
          (sortBy
            (\a b -> compare (modPath $ fst a, bundleTp $ snd a)
                             (modPath $ fst b, bundleTp $ snd b)
            )
            [ (mod, decl) | (mod, decls) <- irRaw, decl <- decls ]
          )
        ]

  {-
    Generate header and code files from IR.
  -}
  printLog "generating code"
  generated <- generateCode ctx ir

  {-
    Compile the generated code.
  -}
  binPath   <- if ctxNoCompile ctx
    then do
      printLog "skipping compile"
      return Nothing
    else do
      printLog "compiling"
      compileCode ctx generated

  printLog "finished"

  when (ctxRun ctx) $ case binPath of
    Just x -> do
      callProcess x []
      return ()
    Nothing -> logMsg
      Nothing
      "--run was set, but no binary path was generated; skipping"

compilerSanityChecks :: CompileContext -> IO ()
compilerSanityChecks ctx = do
  let requiredTraits =
        [ typeClassNumericPath
        , typeClassIntegralPath
        , typeClassNumericMixedPath
        , typeClassIteratorPath
        , typeClassIterablePath
        , typeClassNumericPath
        ]
  forMWithErrors_ requiredTraits $ \t -> do
    result <-
      (try $ getTraitDefinition ctx t) :: IO
        (Either KitError (TraitDefinition TypedExpr ConcreteType))
    case result of
      Left _ -> throwk $ InternalError
        ("Sanity check failed: couldn't required trait "
        ++ s_unpack (showTypePath t)
        ++ ", which should be provided by the standard library; check your kitc installation"
        )
        Nothing
      _ -> return ()
    let requiredTypes = [typeOptionPath]
    forMWithErrors_ requiredTypes $ \t -> do
      result <-
        (try $ getTypeDefinition ctx t) :: IO
          (Either KitError (TypeDefinition TypedExpr ConcreteType))
      case result of
        Left _ -> throwk $ InternalError
          ("Sanity check failed: couldn't required type "
          ++ s_unpack (showTypePath t)
          ++ ", which should be provided by the standard library; check your kitc installation"
          )
          Nothing
        _ -> return ()
