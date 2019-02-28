{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Obelisk.Command.Run where

import Control.Exception (bracket)
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (MonadIO)
import Data.Either
import Data.List
import Data.List.NonEmpty as NE
import Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription)
import Distribution.Parsec.ParseResult (runParseResult)
import Distribution.Pretty
import Distribution.Types.BuildInfo
import Distribution.Types.CondTree
import Distribution.Types.GenericPackageDescription
import Distribution.Types.Library
import Distribution.Utils.Generic
import Hpack.Config
import Hpack.Render
import Hpack.Yaml
import Language.Haskell.Extension
import Network.Socket hiding (Debug)
import System.Directory
import System.FilePath
import System.Process (proc)
import System.IO.Temp (withSystemTempDirectory)
import Data.ByteString (ByteString)

import Obelisk.App (MonadObelisk, ObeliskT)
import Obelisk.CliApp
  ( CliT (..), HasCliConfig, Severity (..)
  , callCommand, failWith, getCliConfig, putLog
  , readProcessAndLogStderr, runCli)
import Obelisk.Command.Project (inProjectShell, withProjectRoot)

data CabalPackageInfo = CabalPackageInfo
  { _cabalPackageInfo_packageRoot :: FilePath
  , _cabalPackageInfo_sourceDirs :: NE.NonEmpty FilePath
    -- ^ List of hs src dirs of the library component
  , _cabalPackageInfo_defaultExtensions :: [Extension]
    -- ^ List of globally enable extensions of the library component
  }

-- NOTE: `run` is not polymorphic like the rest because we use StaticPtr to invoke it.
run :: ObeliskT IO ()
run = do
  pkgs <- getLocalPkgs
  withGhciScript pkgs $ \args dotGhciPath -> do
    freePort <- getFreePort
    assets <- withProjectRoot "." $ \root -> do
      let importableRoot = if "/" `isInfixOf` root
            then root
            else "./" <> root
      isDerivation <- readProcessAndLogStderr Debug $
        proc "nix"
          [ "eval"
          , "-f"
          , root
          , "(let a = import " <> importableRoot <> " {}; in toString (a.reflex.nixpkgs.lib.isDerivation a.passthru.staticFilesImpure))"
          , "--raw"
          -- `--raw` is not available with old nix-instantiate. It drops quotation
          -- marks and trailing newline, so is very convenient for shelling out.
          ]
      -- Check whether the impure static files are a derivation (and so must be built)
      if isDerivation == "1"
        then fmap T.strip $ readProcessAndLogStderr Debug $ -- Strip whitespace here because nix-build has no --raw option
          proc "nix-build" ["-E", "(import " <> importableRoot <> "{}).passthru.staticFilesImpure"]
        else readProcessAndLogStderr Debug $
          proc "nix" ["eval", "-f", root, "passthru.staticFilesImpure", "--raw"]
    putLog Debug $ "Assets impurely loaded from: " <> assets
    runGhcid args dotGhciPath $ Just $ unwords
      [ "run"
      , show freePort
      , "(runServeAsset " ++ show assets ++ ")"
      , "Backend.backend"
      , "Frontend.frontend"
      ]

runRepl :: MonadObelisk m => m ()
runRepl = do
  pkgs <- getLocalPkgs
  withGhciScript pkgs $ \args dotGhciPath -> do
    runGhciRepl args dotGhciPath

runWatch :: MonadObelisk m => m ()
runWatch = do
  pkgs <- getLocalPkgs
  withGhciScript pkgs $ \args dotGhciPath -> runGhcid args dotGhciPath Nothing


-- | A target which outputs the flags which would be passed to `ghci` when
-- using `ob run`.
runIdeArgs :: MonadObelisk m => m ()
runIdeArgs = do
  pkgs <- getLocalPkgs
  withGhciScript pkgs $ \args _
    -> liftIO $ T.putStrLn (T.unwords args)

-- | Relative paths to local packages of an obelisk project
-- TODO a way to query this
getLocalPkgs :: Applicative f => f [FilePath]
getLocalPkgs = pure ["backend", "common", "frontend"]

parseCabalPackage
  :: (MonadObelisk m)
  => FilePath -- ^ package directory
  -> m (Maybe CabalPackageInfo)
parseCabalPackage dir = do
  let cabalFp = dir </> (takeBaseName dir <> ".cabal")
      hpackFp = dir </> "package.yaml"
  hasCabal <- liftIO $ doesFileExist cabalFp
  hasHpack <- liftIO $ doesFileExist hpackFp

  mCabalContents <- if hasCabal
    then Just <$> liftIO (readUTF8File cabalFp)
    else if hasHpack
      then do
        let decodeOptions = DecodeOptions hpackFp Nothing decodeYaml
        liftIO (readPackageConfig decodeOptions) >>= \case
          Left err -> do
            putLog Error $ T.pack $ "Failed to parse " <> hpackFp <> ": " <> err
            return Nothing
          Right (DecodeResult hpackPackage _ _) -> do
            return $ Just $ renderPackage [] hpackPackage
      else return Nothing

  fmap join $ forM mCabalContents $ \cabalContents -> do
    let (warnings, result) = runParseResult $ parseGenericPackageDescription $
          toUTF8BS $ cabalContents
    mapM_ (putLog Warning) $ fmap (T.pack . show) warnings
    case result of
      Right gpkg -> do
        return $ do
          (_, lib) <- simplifyCondTree (const $ pure True) <$> condLibrary gpkg
          pure $ CabalPackageInfo
            { _cabalPackageInfo_packageRoot = takeDirectory cabalFp
            , _cabalPackageInfo_sourceDirs =
                fromMaybe (pure ".") $ NE.nonEmpty $ hsSourceDirs $ libBuildInfo lib
            , _cabalPackageInfo_defaultExtensions =
                defaultExtensions $ libBuildInfo lib
            }
      Left (_, errors) -> do
        putLog Error $ T.pack $ "Failed to parse " <> cabalFp <> ":"
        mapM_ (putLog Error) $ fmap (T.pack . show) errors
        return Nothing

withUTF8FileContentsM :: (MonadIO m, HasCliConfig e m) => FilePath -> (ByteString -> CliT e IO a) -> m a
withUTF8FileContentsM fp f = do
  c <- getCliConfig
  liftIO $ withUTF8FileContents fp $ runCli c . f . toUTF8BS

-- | Create ghci configuration to load the given packages
withGhciScript
  :: MonadObelisk m
  => [FilePath] -- ^ List of packages to load into ghci
  -> ([T.Text] -> FilePath -> m ()) -- ^ Action to run with
                                  --    1. Arguments to pass to ghc
                                  --    2. The path to generated temporary .ghci
  -> m ()
withGhciScript pkgs f = do
  (pkgDirErrs, packageInfos) <- fmap partitionEithers $ forM pkgs $ \pkg -> do
    flip fmap (parseCabalPackage pkg) $ \case
      Nothing -> Left pkg
      Just packageInfo -> Right packageInfo

  when (null packageInfos) $
    failWith $ T.pack $ "No valid pkgs found in " <> intercalate ", " pkgs
  unless (null pkgDirErrs) $
    putLog Warning $ T.pack $ "Failed to find pkgs in " <> intercalate ", " pkgDirErrs

  let extensions = packageInfos >>= _cabalPackageInfo_defaultExtensions
      extensionArgs = if extensions == mempty
        then []
        else (T.pack . ("-X" <>) . prettyShow <$> extensions)

      includeArg = T.pack $ "-i" <> intercalate ":" (packageInfos >>= rootedSourceDirs)

      args = "-no-user-package-db" : includeArg : extensionArgs

      dotGhci = unlines $
        [ ":load Backend Frontend"
        , "import Obelisk.Run"
        , "import qualified Frontend"
        , "import qualified Backend"
        ]
  withSystemTempDirectory "ob-ghci" $ \fp -> do
    let dotGhciPath = fp </> ".ghci"
    liftIO $ writeFile dotGhciPath dotGhci
    f args dotGhciPath

  where
    rootedSourceDirs pkg = NE.toList $
      (_cabalPackageInfo_packageRoot pkg </>) <$> _cabalPackageInfo_sourceDirs pkg

-- | Run ghci repl
runGhciRepl
  :: MonadObelisk m
  => [T.Text] -- ^ Arguments to pass to GHC
  -> FilePath -- ^ Path to .ghci
  -> m ()
runGhciRepl args dotGhci =
  inProjectShell "ghc"
    $ T.unpack . T.unwords $ "ghci" : ["-ghci-script", T.pack dotGhci] ++ args

-- | Run ghcid
runGhcid
  :: MonadObelisk m
  => [T.Text] -- ^ GHC arguments
  -> FilePath -- ^ Path to .ghci
  -> Maybe String -- ^ Optional command to run at every reload
  -> m ()
runGhcid args dotGhci mcmd = callCommand $ unwords $ "ghcid" : opts
  where
    ghci_args = T.unpack (T.unwords args)
    opts =
      [ "-W"
      --TODO: The decision of whether to use -fwarn-redundant-constraints should probably be made by the user
      , "--command='ghci -Wall -ignore-dot-ghci -fwarn-redundant-constraints -no-user-package-db -ghci-script " <> dotGhci <> " " <> ghci_args <> "' "
      , "--reload=config"
      , "--outputfile=ghcid-output.txt"
      ] <> testCmd
    testCmd = maybeToList (flip fmap mcmd $ \cmd -> "--test='" <> cmd <> "'")

getFreePort :: MonadIO m => m PortNumber
getFreePort = liftIO $ withSocketsDo $ do
  addr:_ <- getAddrInfo (Just defaultHints) (Just "127.0.0.1") (Just "0")
  bracket (open addr) close socketPort
  where
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      bind sock (addrAddress addr)
      return sock
