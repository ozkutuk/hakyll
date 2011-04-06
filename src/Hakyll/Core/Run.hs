-- | This is the module which binds it all together
--
{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings #-}
module Hakyll.Core.Run
    ( run
    ) where

import Prelude hiding (reverse)
import Control.Monad (filterM)
import Control.Monad.Trans (liftIO)
import Control.Applicative (Applicative, (<$>))
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.State.Strict (StateT, runStateT, get, put)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Monoid (mempty, mappend)
import Data.Maybe (fromMaybe)
import System.FilePath ((</>))
import qualified Data.Set as S

import Hakyll.Core.Routes
import Hakyll.Core.Identifier
import Hakyll.Core.Util.File
import Hakyll.Core.Compiler
import Hakyll.Core.Compiler.Internal
import Hakyll.Core.Resource
import Hakyll.Core.Resource.Provider
import Hakyll.Core.Resource.Provider.File
import Hakyll.Core.Rules.Internal
import Hakyll.Core.DirectedGraph
import Hakyll.Core.DirectedGraph.Dot
import Hakyll.Core.DependencyAnalyzer
import Hakyll.Core.Writable
import Hakyll.Core.Store
import Hakyll.Core.Configuration
import Hakyll.Core.Logger

-- | Run all rules needed, return the rule set used
--
run :: HakyllConfiguration -> Rules -> IO RuleSet
run configuration rules = do
    logger <- makeLogger

    section logger "Initialising"
    store <- timed logger "Creating store" $
        makeStore $ storeDirectory configuration
    provider <- timed logger "Creating provider" $
        fileResourceProvider configuration

    -- Fetch the old graph from the store
    oldGraph <- fromMaybe mempty <$>
        storeGet store "Hakyll.Core.Run.run" "dependencies"

    let ruleSet = runRules rules provider
        compilers = rulesCompilers ruleSet

        -- Extract the reader/state
        reader = unRuntime $ addNewCompilers compilers
        stateT = runReaderT reader $ RuntimeEnvironment
                    { hakyllLogger           = logger
                    , hakyllConfiguration    = configuration
                    , hakyllRoutes           = rulesRoutes ruleSet
                    , hakyllResourceProvider = provider
                    , hakyllStore            = store
                    }

    -- Run the program and fetch the resulting state
    ((), state') <- runStateT stateT $ RuntimeState
        { hakyllAnalyzer  = makeDependencyAnalyzer mempty (const False) oldGraph
        , hakyllCompilers = M.empty
        }

    -- We want to save the final dependency graph for the next run
    storeSet store "Hakyll.Core.Run.run" "dependencies" $
        analyzerGraph $ hakyllAnalyzer state'

    -- Flush and return
    flushLogger logger
    return ruleSet

data RuntimeEnvironment = RuntimeEnvironment
    { hakyllLogger           :: Logger
    , hakyllConfiguration    :: HakyllConfiguration
    , hakyllRoutes           :: Routes
    , hakyllResourceProvider :: ResourceProvider
    , hakyllStore            :: Store
    }

data RuntimeState = RuntimeState
    { hakyllAnalyzer  :: DependencyAnalyzer Identifier
    , hakyllCompilers :: Map Identifier (Compiler () CompileRule)
    }

newtype Runtime a = Runtime
    { unRuntime :: ReaderT RuntimeEnvironment (StateT RuntimeState IO) a
    } deriving (Functor, Applicative, Monad)

-- | Return a set of modified identifiers
--
{-
modified :: ResourceProvider     -- ^ Resource provider
         -> Store                -- ^ Store
         -> [Identifier]         -- ^ Identifiers to check
         -> IO (Set Identifier)  -- ^ Modified resources
modified provider store ids = fmap S.fromList $ flip filterM ids $ \id' ->
    resourceModified provider (Resource id') store
-}

-- | Add a number of compilers and continue using these compilers
--
addNewCompilers :: [(Identifier, Compiler () CompileRule)]
                -- ^ Compilers to add
                -> Runtime ()
addNewCompilers newCompilers = Runtime $ do
    -- Get some information
    logger <- hakyllLogger <$> ask
    section logger "Adding new compilers"
    provider <- hakyllResourceProvider <$> ask
    store <- hakyllStore <$> ask

    -- Old state information
    oldCompilers <- hakyllCompilers <$> get
    oldAnalyzer <- hakyllAnalyzer <$> get

    let -- Create a new partial dependency graph
        dependencies = flip map newCompilers $ \(id', compiler) ->
            let deps = runCompilerDependencies compiler id' provider
            in (id', deps)

        -- Create the dependency graph
        newGraph = fromList dependencies

    -- Check which items have been modified
    modified <- fmap S.fromList $ flip filterM (map fst newCompilers) $
        liftIO . resourceModified provider store . Resource
    -- newModified <- liftIO $ modified provider store $ map fst newCompilers

    -- Create a new analyzer and append it to the currect one
    let newAnalyzer = makeDependencyAnalyzer newGraph (`S.member` modified) $
            analyzerPreviousGraph oldAnalyzer
        analyzer = mappend oldAnalyzer newAnalyzer

    -- Debugging
    liftIO $ putStrLn $ "Remains: " ++ show (analyzerRemains newAnalyzer)
    liftIO $ putStrLn $ "Done: " ++ show (analyzerDone newAnalyzer)
    liftIO $ writeFile "old-prev.dot" $ toDot show (analyzerPreviousGraph oldAnalyzer)
    liftIO $ writeFile "old.dot" $ toDot show (analyzerGraph oldAnalyzer)
    liftIO $ writeFile "old-prev.dot" $ toDot show (analyzerPreviousGraph oldAnalyzer)
    liftIO $ writeFile "new.dot" $ toDot show (analyzerGraph newAnalyzer)
    liftIO $ writeFile "new-prev.dot" $ toDot show (analyzerPreviousGraph newAnalyzer)
    liftIO $ writeFile "result.dot" $ toDot show (analyzerGraph analyzer)
    liftIO $ writeFile "result-prev.dot" $ toDot show (analyzerPreviousGraph analyzer)

    -- Update the state
    put $ RuntimeState
        { hakyllAnalyzer  = analyzer
        , hakyllCompilers = M.union oldCompilers (M.fromList newCompilers)
        }

    -- Continue
    unRuntime stepAnalyzer

stepAnalyzer :: Runtime ()
stepAnalyzer = Runtime $ do
    -- Step the analyzer
    state <- get
    let (signal, analyzer') = step $ hakyllAnalyzer state
    put $ state { hakyllAnalyzer = analyzer' }

    case signal of Done      -> return ()
                   Cycle _   -> return ()
                   Build id' -> unRuntime $ build id'

build :: Identifier -> Runtime ()
build id' = Runtime $ do
    logger <- hakyllLogger <$> ask
    routes <- hakyllRoutes <$> ask
    provider <- hakyllResourceProvider <$> ask
    store <- hakyllStore <$> ask
    compilers <- hakyllCompilers <$> get

    section logger $ "Compiling " ++ show id'

    -- Fetch the right compiler from the map
    let compiler = compilers M.! id'

    -- Check if the resource was modified
    isModified <- liftIO $ resourceModified provider store (Resource id')

    -- Run the compiler
    result <- timed logger "Total compile time" $ liftIO $
        runCompiler compiler id' provider routes store isModified logger

    case result of
        -- Compile rule for one item, easy stuff
        Right (CompileRule compiled) -> do
            case runRoutes routes id' of
                Nothing  -> return ()
                Just url -> timed logger ("Routing to " ++ url) $ do
                    destination <-
                        destinationDirectory . hakyllConfiguration <$> ask
                    let path = destination </> url
                    liftIO $ makeDirectories path
                    liftIO $ write path compiled

            -- Continue for the remaining compilers
            unRuntime stepAnalyzer

        -- Metacompiler, slightly more complicated
        Right (MetaCompileRule newCompilers) ->
            -- Actually I was just kidding, it's not hard at all
            unRuntime $ addNewCompilers newCompilers

        -- Some error happened, log and continue
        Left err -> do
            thrown logger err 
            unRuntime stepAnalyzer
