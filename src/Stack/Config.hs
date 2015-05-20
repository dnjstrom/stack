{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ViewPatterns #-}

-- | The general Stack configuration that starts everything off. This should
-- be smart to falback if there is no stack.yaml, instead relying on
-- whatever files are available.
--
-- If there is no stack.yaml, and there is a cabal.config, we
-- read in those constraints, and if there's a cabal.sandbox.config,
-- we read any constraints from there and also find the package
-- database from there, etc. And if there's nothing, we should
-- probably default to behaving like cabal, possibly with spitting out
-- a warning that "you should run `stk init` to make things better".
module Stack.Config
  ( loadConfig
  , LoadOptions (..)
  , defaultLoadOptions
  ) where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger hiding (Loc)
import           Control.Monad.Reader (MonadReader, ask, runReaderT)
import           Data.Aeson
import           Data.Either (partitionEithers)
import           Data.Map (Map)
import           Data.Maybe
import           Data.Monoid
import           Data.Set (Set)
import qualified Data.Set as S
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Encoding (encodeUtf8)
import qualified Data.Yaml as Yaml
import           Network.HTTP.Client.Conduit (HasHttpManager, getHttpManager, Manager)
import           Path
import           Stack.BuildPlan
import           Stack.Package
import           Stack.Types
import           System.Directory
import           System.Environment
import qualified System.FilePath as FP

-- An uninterpreted representation of configuration options.
-- Configurations may be "cascaded" using mappend (left-biased).
data ConfigMonoid =
  ConfigMonoid
    { configMonoidDockerOpts     :: !DockerOpts
    , configMonoidUrls           :: !(Map Text Text)
    -- ^ Various URLs for downloading things. Yes, this is stringly typed,
    -- making it easy to extend. Please make sure to only access it using
    -- helper functions.
    , configMonoidGpgVerifyIndex :: !(Maybe Bool)
    -- ^ Controls how package index updating occurs
    , configMonoidResolver       :: !(Maybe Resolver)
    -- ^ How we resolve which dependencies to use
    , configMonoidInstallDeps    :: !(Maybe Bool)
    -- ^ Whether or not we should install dependencies. When using Docker,
    -- default is False, otherwise default is True
    }
  deriving Show

-- | Get the default resolver value
getDefaultResolver :: (MonadIO m, MonadCatch m, MonadReader env m, HasStackRoot env, HasUrls env, HasHttpManager env, MonadLogger m)
                   => Path Abs Dir
                   -> m Resolver
getDefaultResolver dir = do
    ecabalfp <- try $ getCabalFileName dir
    msnap <- case ecabalfp of
        Left e -> do
            $logWarn $ T.pack $ show (e :: PackageException)
            return Nothing
        Right cabalfp -> do
            gpd <- readPackageUnresolved cabalfp
            mpair <- findBuildPlan cabalfp gpd
            return mpair
    case msnap of
        Just (snap, _FIXMEflagsIgnored) -> return $ ResolverSnapshot snap
        Nothing -> return $ ResolverSnapshot $ LTS 2 9 -- FIXME

-- | Dummy type to support this monoid business.
newtype DockerOpts = DockerOpts (Maybe Docker)
  deriving (Show)

-- | Left-biased instance.
instance Monoid DockerOpts where
  mappend (DockerOpts Nothing) x = x
  mappend x (DockerOpts Nothing) = x
  mappend x _ = x
  mempty = DockerOpts Nothing

instance Monoid ConfigMonoid where
  mempty = ConfigMonoid
    { configMonoidDockerOpts = mempty
    , configMonoidUrls = mempty
    , configMonoidGpgVerifyIndex = Nothing
    , configMonoidResolver = Nothing
    , configMonoidInstallDeps = Nothing
    }
  mappend l r = ConfigMonoid
    { configMonoidDockerOpts = configMonoidDockerOpts l <> configMonoidDockerOpts r
    , configMonoidUrls = configMonoidUrls l <> configMonoidUrls r
    , configMonoidGpgVerifyIndex = configMonoidGpgVerifyIndex l <|> configMonoidGpgVerifyIndex r
    , configMonoidResolver = configMonoidResolver l <|> configMonoidResolver r
    , configMonoidInstallDeps = configMonoidInstallDeps l <|> configMonoidInstallDeps r
    }

instance FromJSON ConfigMonoid where
  parseJSON =
    withObject "ConfigMonoid" $
    \obj ->
      do getTheDocker <- obj .:? "docker"
         configMonoidUrls <- obj .:? "urls" .!= mempty
         configMonoidGpgVerifyIndex <- obj .:? "gpg-verify-index"
         configMonoidResolver <- obj .:? "resolver" -- FIXME move to Project?
         configMonoidInstallDeps <- obj .:? "install-dependencies" -- FIXME move to Project?
         let configMonoidDockerOpts = DockerOpts getTheDocker
         return ConfigMonoid {..}

-- | A project is a collection of packages. We can have multiple stack.yaml
-- files, but only one of them may contain project information.
data Project = Project
    { projectRoot :: !(Path Abs Dir)
    -- ^ The directory containing the project's stack.yaml
    , projectPackagesPath :: ![FilePath]
    -- ^ Components of the package list which refer to local directories
    --
    -- Note that we use @FilePath@ and not @Path@s. The goal is: first parse
    -- the value raw, and then use @canonicalizePath@ and @parseAbsDir@.
    , projectPackagesIdent :: !(Set PackageIdentifier)
    -- ^ Components of the package list referring to package/version combos,
    -- see: https://github.com/fpco/stack/issues/41
    , projectGlobalFlags :: !(Map FlagName Bool)
    -- ^ Applied to all packages
    , projectPackageFlags :: !(Map PackageName (Map FlagName Bool))
    -- ^ Applied to an individual package, overriding global flags
    , projectConfigExists :: !Bool
    -- ^ If 'True', then we actually loaded this from a real config file. If
    -- 'False', then we just made up a default.
    , projectConfigMonoid :: !ConfigMonoid
    -- ^ Extra config values found
    }
  deriving Show

instance FromJSON (Path Abs Dir -> Project) where -- FIXME get rid of Path Abs Dir
    parseJSON = withObject "Project" $ \o -> do
        ps <- o .:? "packages" .!= ["."]
        let eps = map (\p ->
                case parsePackageIdentifier $ encodeUtf8 p of
                    Left _ -> Left $ T.unpack p
                    Right pi' -> Right pi') ps
        let (dirs, idents) = partitionEithers eps
        gf <- o .:? "flags" .!= mempty
        pf <- o .:? "package-flags" .!= mempty
        config <- parseJSON $ Object o
        return $ \root -> Project
            { projectRoot = root
            , projectPackagesPath = dirs
            , projectPackagesIdent = S.fromList idents
            , projectGlobalFlags = gf
            , projectPackageFlags = pf
            , projectConfigExists = True
            , projectConfigMonoid = config
            }

-- TODO: What about Windows?
-- FIXME: This will not build on Windows. (Good!)
defaultStackGlobalConfig :: Path Abs File
defaultStackGlobalConfig = $(mkAbsFile "/etc/stack/config")

defaultLoadOptions :: LoadOptions
defaultLoadOptions = LoadOptions
    { loWriteMissing = True
    , loSmartResolver = True
    }

data LoadOptions = LoadOptions
    { loWriteMissing :: !Bool
    -- ^ Write out a stack.yaml if none was found
    , loSmartResolver :: !Bool
    -- ^ Use the intelligent resolver locator, otherwise just provides no
    -- resolver
    }

-- Interprets ConfigMonoid options.
configFromConfigMonoid :: (MonadLogger m, MonadIO m, MonadCatch m, MonadReader env m, HasHttpManager env)
  => LoadOptions
  -> Path Abs Dir -- ^ stack root, e.g. ~/.stack
  -> Project
  -> ConfigMonoid
  -> m Config
configFromConfigMonoid lo configStackRoot Project{..} ConfigMonoid{..} = do
     let configDocker = case configMonoidDockerOpts of
                 DockerOpts x -> x
         configFlags = projectGlobalFlags
         configPackageFlags = projectPackageFlags
         configPackagesIdent = projectPackagesIdent
         configDir = projectRoot
         configUrls = configMonoidUrls
         configGpgVerifyIndex = fromMaybe False configMonoidGpgVerifyIndex
         configInstallDeps =
            case configMonoidInstallDeps of
                Just b -> b
                Nothing ->
                    case configMonoidDockerOpts of
                        DockerOpts Nothing -> True
                        DockerOpts (Just _) -> False

     configPackagesPath' <- forM projectPackagesPath $ \p -> do
        dir <- liftIO $ canonicalizePath $ toFilePath projectRoot FP.</> p
        parseAbsDir dir
     let configPackagesPath = S.fromList configPackagesPath'

     env <- ask
     let miniConfig = MiniConfig (getHttpManager env) configStackRoot configUrls
     configResolver <- case configMonoidResolver of
        Nothing | loSmartResolver lo -> do
            r <- runReaderT (getDefaultResolver configDir) miniConfig
            $logWarn $ T.concat
                [ "No resolver value found in your config files. "
                , "Without a value stated, your build will be slower and unstable. "
                , "Please consider adding the following line to your config file:"
                ]
            $logWarn $ "    resolver: " <> renderResolver r
            return r
        Nothing -> return ResolverNone
        Just r -> return r
     configGhcVersion <-
        case configResolver of
            ResolverSnapshot snapName -> do
                bp <- runReaderT (loadBuildPlan snapName) miniConfig
                return $ Just $ siGhcVersion $ bpSystemInfo bp
            ResolverNone -> return Nothing

     when (loWriteMissing lo && not projectConfigExists) $ do
        let dest = toFilePath $ projectRoot </> stackDotYaml
        $logInfo $ "Writing default config file to: " <> T.pack dest
        liftIO $ Yaml.encodeFile dest $ object
            [ "packages" .= ["." :: Text]
            , "resolver" .= renderResolver configResolver
            ]
     return Config {..}

data MiniConfig = MiniConfig Manager (Path Abs Dir) (Map Text Text)
instance HasStackRoot MiniConfig where
    getStackRoot (MiniConfig _ root _) = root
instance HasHttpManager MiniConfig where
    getHttpManager (MiniConfig man _ _) = man
instance HasUrls MiniConfig where
    getUrls (MiniConfig _ _ urls) = urls

-- | Load the configuration, using current directory, environment variables,
-- and defaults as necessary.
loadConfig :: (MonadLogger m,MonadIO m,MonadCatch m,MonadReader env m,HasHttpManager env)
           => LoadOptions
           -> m Config
loadConfig lo = do
    env <- liftIO getEnvironment
    stackRoot <- (>>= parseAbsDir) $
        case lookup "STACK_ROOT" env of
            Nothing -> liftIO $ getAppUserDataDirectory "stack"
            Just x -> return x

    extraConfigs <- getExtraConfigs stackRoot >>= mapM loadConfigMonoid
    project <- loadProjectConfig
    let config = mconcat (projectConfigMonoid project:extraConfigs)
    configFromConfigMonoid lo stackRoot project config

-- | Determine the extra config file locations which exist.
--
-- Returns most local first
getExtraConfigs :: MonadIO m
                => Path Abs Dir -- ^ stack root
                -> m [Path Abs File]
getExtraConfigs stackRoot = liftIO $ do
    env <- getEnvironment
    mstackConfig <-
        maybe (return Nothing) (fmap Just . parseAbsFile)
      $ lookup "STACK_CONFIG" env
    mstackGlobalConfig <-
        maybe (return Nothing) (fmap Just . parseAbsFile)
      $ lookup "STACK_GLOBAL_CONFIG" env
    filterM (liftIO . doesFileExist . toFilePath)
        [ fromMaybe (stackRoot </> stackDotYaml) mstackConfig
        , fromMaybe defaultStackGlobalConfig mstackGlobalConfig
        ]

-- | Load the value of a 'ConfigMonoid' from the given file.
loadConfigMonoid :: MonadIO m => Path Abs File -> m ConfigMonoid
loadConfigMonoid path =
    liftIO $ Yaml.decodeFileEither (toFilePath path)
         >>= either throwM return

-- | Find the project config file location, respecting environment variables
-- and otherwise traversing parents. If no config is found, we supply a default
-- based on current directory.
loadProjectConfig :: (MonadIO m, MonadThrow m, MonadLogger m) => m Project
loadProjectConfig = do
    env <- liftIO getEnvironment
    case lookup "STACK_YAML" env of
        Just fp -> do
            $logInfo "Getting project config file from STACK_YAML environment"
            parseAbsFile fp >>= load
        Nothing -> do
            currDir <- liftIO (canonicalizePath ".") >>= parseAbsDir
            mfp <- search currDir
            case mfp of
                Just fp -> do
                    $logInfo $ "Loading project config file at " <> T.pack (toFilePath fp)
                    load fp
                Nothing -> do
                    $logInfo $ "No project config file found, using defaults"
                    return Project
                        { projectRoot = currDir
                        , projectPackagesPath = ["."]
                        , projectPackagesIdent = mempty
                        , projectGlobalFlags = mempty
                        , projectPackageFlags = mempty
                        , projectConfigExists = False
                        , projectConfigMonoid = mempty
                        }
  where
    load fp = do
        mkProject <-
            liftIO (Yaml.decodeFileEither (toFilePath fp))
               >>= either throwM return
        return $ mkProject $ parent fp

    search dir = do
        let fp = dir </> stackDotYaml
            fp' = toFilePath fp
        $logDebug $ "Checking for project config at: " <> T.pack fp'
        exists <- liftIO $ doesFileExist fp'
        if exists
            then return $ Just fp
            else do
                let dir' = parent dir
                if dir == dir'
                    -- fully traversed, give up
                    then return Nothing
                    else search dir'

-- | The filename used for the stack config file.
stackDotYaml :: Path Rel File
stackDotYaml = $(mkRelFile "stack.yaml")
