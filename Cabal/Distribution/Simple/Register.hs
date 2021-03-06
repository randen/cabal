-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.Register
-- Copyright   :  Isaac Jones 2003-2004
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This module deals with registering and unregistering packages. There are a
-- couple ways it can do this, one is to do it directly. Another is to generate
-- a script that can be run later to do it. The idea here being that the user
-- is shielded from the details of what command to use for package registration
-- for a particular compiler. In practice this aspect was not especially
-- popular so we also provide a way to simply generate the package registration
-- file which then must be manually passed to @ghc-pkg@. It is possible to
-- generate registration information for where the package is to be installed,
-- or alternatively to register the package in place in the build tree. The
-- latter is occasionally handy, and will become more important when we try to
-- build multi-package systems.
--
-- This module does not delegate anything to the per-compiler modules but just
-- mixes it all in in this module, which is rather unsatisfactory. The script
-- generation and the unregister feature are not well used or tested.

module Distribution.Simple.Register (
    register,
    unregister,

    initPackageDB,
    doesPackageDBExist,
    createPackageDB,
    deletePackageDB,

    invokeHcPkg,
    registerPackage,
    generateRegistrationInfo,
    inplaceInstalledPackageInfo,
    absoluteInstalledPackageInfo,
    generalInstalledPackageInfo,
  ) where

import Distribution.Simple.LocalBuildInfo
         ( LocalBuildInfo(..), ComponentLocalBuildInfo(..)
         , ComponentName(..), getComponentLocalBuildInfo
         , InstallDirs(..), absoluteInstallDirs )
import Distribution.Simple.BuildPaths (haddockName)

import qualified Distribution.Simple.GHC   as GHC
import qualified Distribution.Simple.GHCJS as GHCJS
import qualified Distribution.Simple.LHC   as LHC
import qualified Distribution.Simple.UHC   as UHC
import qualified Distribution.Simple.HaskellSuite as HaskellSuite

import Distribution.Simple.Compiler
         ( Compiler, CompilerFlavor(..), compilerFlavor, compilerVersion
         , PackageDB, PackageDBStack, absolutePackageDBPaths
         , registrationPackageDB )
import Distribution.Simple.Program
         ( ProgramConfiguration, runProgramInvocation )
import Distribution.Simple.Program.Script
         ( invocationAsSystemScript )
import           Distribution.Simple.Program.HcPkg (HcPkgInfo)
import qualified Distribution.Simple.Program.HcPkg as HcPkg
import Distribution.Simple.Setup
         ( RegisterFlags(..), CopyDest(..)
         , fromFlag, fromFlagOrDefault, flagToMaybe )
import Distribution.PackageDescription
         ( PackageDescription(..), Library(..), BuildInfo(..), libModules )
import Distribution.Package
         ( Package(..), packageName
         , getHSLibraryName )
import Distribution.InstalledPackageInfo
         ( InstalledPackageInfo, InstalledPackageInfo(InstalledPackageInfo)
         , showInstalledPackageInfo, AbiHash(..) )
import qualified Distribution.InstalledPackageInfo as IPI
import Distribution.Simple.Utils
         ( writeUTF8File, writeFileAtomic, setFileExecutable
         , die, notice, setupMessage, shortRelativePath )
import Distribution.System
         ( OS(..), buildOS )
import Distribution.Text
         ( display )
import Distribution.Verbosity as Verbosity
         ( Verbosity, normal )

import System.FilePath ((</>), (<.>), isAbsolute)
import System.Directory
         ( getCurrentDirectory, removeDirectoryRecursive, removeFile
         , doesDirectoryExist, doesFileExist )

import Data.Version
import Control.Monad (when)
import Data.Maybe
         ( isJust, fromMaybe, maybeToList )
import Data.List
         ( partition, nub )
import qualified Data.ByteString.Lazy.Char8 as BS.Char8

-- -----------------------------------------------------------------------------
-- Registration

register :: PackageDescription -> LocalBuildInfo
         -> RegisterFlags -- ^Install in the user's database?; verbose
         -> IO ()
register pkg@PackageDescription { library       = Just lib  } lbi regFlags
  = do
    let clbi = getComponentLocalBuildInfo lbi CLibName

    absPackageDBs    <- absolutePackageDBPaths packageDbs
    installedPkgInfo <- generateRegistrationInfo
                           verbosity pkg lib lbi clbi inplace reloc distPref
                           (registrationPackageDB absPackageDBs)

    when (fromFlag (regPrintId regFlags)) $ do
      putStrLn (display (IPI.installedComponentId installedPkgInfo))

     -- Three different modes:
    case () of
     _ | modeGenerateRegFile   -> writeRegistrationFile installedPkgInfo
       | modeGenerateRegScript -> writeRegisterScript   installedPkgInfo
       | otherwise             -> do
           setupMessage verbosity "Registering" (packageId pkg)
           registerPackage verbosity (compiler lbi) (withPrograms lbi) False
                           packageDbs installedPkgInfo

  where
    modeGenerateRegFile = isJust (flagToMaybe (regGenPkgConf regFlags))
    regFile             = fromMaybe (display (packageId pkg) <.> "conf")
                                    (fromFlag (regGenPkgConf regFlags))

    modeGenerateRegScript = fromFlag (regGenScript regFlags)

    inplace   = fromFlag (regInPlace regFlags)
    reloc     = relocatable lbi
    -- FIXME: there's really no guarantee this will work.
    -- registering into a totally different db stack can
    -- fail if dependencies cannot be satisfied.
    packageDbs = nub $ withPackageDB lbi
                    ++ maybeToList (flagToMaybe  (regPackageDB regFlags))
    distPref  = fromFlag (regDistPref regFlags)
    verbosity = fromFlag (regVerbosity regFlags)

    writeRegistrationFile installedPkgInfo = do
      notice verbosity ("Creating package registration file: " ++ regFile)
      writeUTF8File regFile (showInstalledPackageInfo installedPkgInfo)

    writeRegisterScript installedPkgInfo =
      case compilerFlavor (compiler lbi) of
        JHC -> notice verbosity "Registration scripts not needed for jhc"
        UHC -> notice verbosity "Registration scripts not needed for uhc"
        _   -> withHcPkg
               "Registration scripts are not implemented for this compiler"
               (compiler lbi) (withPrograms lbi)
               (writeHcPkgRegisterScript verbosity installedPkgInfo packageDbs)

register _ _ regFlags = notice verbosity "No package to register"
  where
    verbosity = fromFlag (regVerbosity regFlags)


generateRegistrationInfo :: Verbosity
                         -> PackageDescription
                         -> Library
                         -> LocalBuildInfo
                         -> ComponentLocalBuildInfo
                         -> Bool
                         -> Bool
                         -> FilePath
                         -> PackageDB
                         -> IO InstalledPackageInfo
generateRegistrationInfo verbosity pkg lib lbi clbi inplace reloc distPref packageDb = do
  --TODO: eliminate pwd!
  pwd <- getCurrentDirectory

  --TODO: the method of setting the ComponentId is compiler specific
  --      this aspect should be delegated to a per-compiler helper.
  let comp = compiler lbi
  abi_hash <-
    case compilerFlavor comp of
     GHC | compilerVersion comp >= Version [6,11] [] -> do
            fmap AbiHash $ GHC.libAbiHash verbosity pkg lbi lib clbi
     GHCJS -> do
            fmap AbiHash $ GHCJS.libAbiHash verbosity pkg lbi lib clbi
     _ -> return (AbiHash "")

  installedPkgInfo <-
    if inplace
      then return (inplaceInstalledPackageInfo pwd distPref
                     pkg abi_hash lib lbi clbi)
    else if reloc
      then relocRegistrationInfo verbosity
                     pkg lib lbi clbi abi_hash packageDb
      else return (absoluteInstalledPackageInfo
                     pkg abi_hash lib lbi clbi)


  return installedPkgInfo{ IPI.abiHash = abi_hash }

relocRegistrationInfo :: Verbosity
                      -> PackageDescription
                      -> Library
                      -> LocalBuildInfo
                      -> ComponentLocalBuildInfo
                      -> AbiHash
                      -> PackageDB
                      -> IO InstalledPackageInfo
relocRegistrationInfo verbosity pkg lib lbi clbi abi_hash packageDb =
  case (compilerFlavor (compiler lbi)) of
    GHC -> do fs <- GHC.pkgRoot verbosity lbi packageDb
              return (relocatableInstalledPackageInfo
                        pkg abi_hash lib lbi clbi fs)
    _   -> die "Distribution.Simple.Register.relocRegistrationInfo: \
               \not implemented for this compiler"

initPackageDB :: Verbosity -> Compiler -> ProgramConfiguration -> FilePath -> IO ()
initPackageDB verbosity comp progdb dbPath =
    createPackageDB verbosity comp progdb True dbPath

-- | Create an empty package DB at the specified location.
createPackageDB :: Verbosity -> Compiler -> ProgramConfiguration -> Bool
                -> FilePath -> IO ()
createPackageDB verbosity comp progdb preferCompat dbPath =
    case compilerFlavor comp of
      GHC   -> HcPkg.init (GHC.hcPkgInfo   progdb) verbosity preferCompat dbPath
      GHCJS -> HcPkg.init (GHCJS.hcPkgInfo progdb) verbosity False dbPath
      LHC   -> HcPkg.init (LHC.hcPkgInfo   progdb) verbosity False dbPath
      UHC   -> return ()
      HaskellSuite _ -> HaskellSuite.initPackageDB verbosity progdb dbPath
      _              -> die $ "Distribution.Simple.Register.createPackageDB: "
                           ++ "not implemented for this compiler"

doesPackageDBExist :: FilePath -> IO Bool
doesPackageDBExist dbPath = do
    -- currently one impl for all compiler flavours, but could change if needed
    dir_exists <- doesDirectoryExist dbPath
    if dir_exists
        then return True
        else doesFileExist dbPath

deletePackageDB :: FilePath -> IO ()
deletePackageDB dbPath = do
    -- currently one impl for all compiler flavours, but could change if needed
    dir_exists <- doesDirectoryExist dbPath
    if dir_exists
        then removeDirectoryRecursive dbPath
        else do file_exists <- doesFileExist dbPath
                when file_exists $ removeFile dbPath

-- | Run @hc-pkg@ using a given package DB stack, directly forwarding the
-- provided command-line arguments to it.
invokeHcPkg :: Verbosity -> Compiler -> ProgramConfiguration -> PackageDBStack
                -> [String] -> IO ()
invokeHcPkg verbosity comp conf dbStack extraArgs =
  withHcPkg "invokeHcPkg" comp conf
    (\hpi -> HcPkg.invoke hpi verbosity dbStack extraArgs)

withHcPkg :: String -> Compiler -> ProgramConfiguration
          -> (HcPkgInfo -> IO a) -> IO a
withHcPkg name comp conf f =
  case compilerFlavor comp of
    GHC   -> f (GHC.hcPkgInfo conf)
    GHCJS -> f (GHCJS.hcPkgInfo conf)
    LHC   -> f (LHC.hcPkgInfo conf)
    _     -> die ("Distribution.Simple.Register." ++ name ++ ":\
                  \not implemented for this compiler")

registerPackage :: Verbosity
                -> Compiler
                -> ProgramConfiguration
                -> Bool
                -> PackageDBStack
                -> InstalledPackageInfo
                -> IO ()
registerPackage verbosity comp progdb multiInstance packageDbs installedPkgInfo =
  case compilerFlavor comp of
    GHC   -> GHC.registerPackage   verbosity progdb multiInstance packageDbs installedPkgInfo
    GHCJS -> GHCJS.registerPackage verbosity progdb multiInstance packageDbs installedPkgInfo
    _ | multiInstance
          -> die "Registering multiple package instances is not yet supported for this compiler"
    LHC   -> LHC.registerPackage   verbosity      progdb packageDbs installedPkgInfo
    UHC   -> UHC.registerPackage   verbosity comp progdb packageDbs installedPkgInfo
    JHC   -> notice verbosity "Registering for jhc (nothing to do)"
    HaskellSuite {} ->
      HaskellSuite.registerPackage verbosity      progdb packageDbs installedPkgInfo
    _    -> die "Registering is not implemented for this compiler"

writeHcPkgRegisterScript :: Verbosity
                         -> InstalledPackageInfo
                         -> PackageDBStack
                         -> HcPkgInfo
                         -> IO ()
writeHcPkgRegisterScript verbosity installedPkgInfo packageDbs hpi = do
  let invocation  = HcPkg.reregisterInvocation hpi Verbosity.normal
                      packageDbs (Right installedPkgInfo)
      regScript   = invocationAsSystemScript buildOS invocation

  notice verbosity ("Creating package registration script: " ++ regScriptFileName)
  writeUTF8File regScriptFileName regScript
  setFileExecutable regScriptFileName

regScriptFileName :: FilePath
regScriptFileName = case buildOS of
                        Windows -> "register.bat"
                        _       -> "register.sh"


-- -----------------------------------------------------------------------------
-- Making the InstalledPackageInfo

-- | Construct 'InstalledPackageInfo' for a library in a package, given a set
-- of installation directories.
--
generalInstalledPackageInfo
  :: ([FilePath] -> [FilePath]) -- ^ Translate relative include dir paths to
                                -- absolute paths.
  -> PackageDescription
  -> AbiHash
  -> Library
  -> LocalBuildInfo
  -> ComponentLocalBuildInfo
  -> InstallDirs FilePath
  -> InstalledPackageInfo
generalInstalledPackageInfo adjustRelIncDirs pkg abi_hash lib lbi clbi installDirs =
  InstalledPackageInfo {
    IPI.sourcePackageId    = packageId   pkg,
    IPI.installedComponentId= componentId clbi,
    IPI.compatPackageKey   = componentCompatPackageKey clbi,
    IPI.license            = license     pkg,
    IPI.copyright          = copyright   pkg,
    IPI.maintainer         = maintainer  pkg,
    IPI.author             = author      pkg,
    IPI.stability          = stability   pkg,
    IPI.homepage           = homepage    pkg,
    IPI.pkgUrl             = pkgUrl      pkg,
    IPI.synopsis           = synopsis    pkg,
    IPI.description        = description pkg,
    IPI.category           = category    pkg,
    IPI.abiHash            = abi_hash,
    IPI.exposed            = libExposed  lib,
    IPI.exposedModules     = componentExposedModules clbi,
    IPI.hiddenModules      = otherModules bi,
    IPI.instantiatedWith   = map (\(k,(p,n)) ->
                                   (k,IPI.OriginalModule (IPI.installedComponentId p) n))
                                 (instantiatedWith lbi),
    IPI.trusted            = IPI.trusted IPI.emptyInstalledPackageInfo,
    IPI.importDirs         = [ libdir installDirs | hasModules ],
    -- Note. the libsubdir and datasubdir templates have already been expanded
    -- into libdir and datadir.
    IPI.libraryDirs        = if hasLibrary
                               then libdir installDirs : extraLibDirs bi
                               else                      extraLibDirs bi,
    IPI.dataDir            = datadir installDirs,
    IPI.hsLibraries        = if hasLibrary
                               then [getHSLibraryName (componentId clbi)]
                               else [],
    IPI.extraLibraries     = extraLibs bi,
    IPI.extraGHCiLibraries = extraGHCiLibs bi,
    IPI.includeDirs        = absinc ++ adjustRelIncDirs relinc,
    IPI.includes           = includes bi,
    IPI.depends            = map fst (componentPackageDeps clbi),
    IPI.ccOptions          = [], -- Note. NOT ccOptions bi!
                                 -- We don't want cc-options to be propagated
                                 -- to C compilations in other packages.
    IPI.ldOptions          = ldOptions bi,
    IPI.frameworkDirs      = [],
    IPI.frameworks         = frameworks bi,
    IPI.haddockInterfaces  = [haddockdir installDirs </> haddockName pkg],
    IPI.haddockHTMLs       = [htmldir installDirs],
    IPI.pkgRoot            = Nothing
  }
  where
    bi = libBuildInfo lib
    (absinc, relinc) = partition isAbsolute (includeDirs bi)
    hasModules = not $ null (libModules lib)
    hasLibrary = hasModules || not (null (cSources bi))
                            || (not (null (jsSources bi)) &&
                                compilerFlavor (compiler lbi) == GHCJS)

-- | Construct 'InstalledPackageInfo' for a library that is in place in the
-- build tree.
--
-- This function knows about the layout of in place packages.
--
inplaceInstalledPackageInfo :: FilePath -- ^ top of the build tree
                            -> FilePath -- ^ location of the dist tree
                            -> PackageDescription
                            -> AbiHash
                            -> Library
                            -> LocalBuildInfo
                            -> ComponentLocalBuildInfo
                            -> InstalledPackageInfo
inplaceInstalledPackageInfo inplaceDir distPref pkg abi_hash lib lbi clbi =
    generalInstalledPackageInfo adjustRelativeIncludeDirs
                                pkg abi_hash lib lbi clbi installDirs
  where
    adjustRelativeIncludeDirs = map (inplaceDir </>)
    installDirs =
      (absoluteInstallDirs pkg lbi NoCopyDest) {
        libdir     = inplaceDir </> buildDir lbi,
        datadir    = inplaceDir </> dataDir pkg,
        docdir     = inplaceDocdir,
        htmldir    = inplaceHtmldir,
        haddockdir = inplaceHtmldir
      }
    inplaceDocdir  = inplaceDir </> distPref </> "doc"
    inplaceHtmldir = inplaceDocdir </> "html" </> display (packageName pkg)


-- | Construct 'InstalledPackageInfo' for the final install location of a
-- library package.
--
-- This function knows about the layout of installed packages.
--
absoluteInstalledPackageInfo :: PackageDescription
                             -> AbiHash
                             -> Library
                             -> LocalBuildInfo
                             -> ComponentLocalBuildInfo
                             -> InstalledPackageInfo
absoluteInstalledPackageInfo pkg abi_hash lib lbi clbi =
    generalInstalledPackageInfo adjustReativeIncludeDirs
                                pkg abi_hash lib lbi clbi installDirs
  where
    -- For installed packages we install all include files into one dir,
    -- whereas in the build tree they may live in multiple local dirs.
    adjustReativeIncludeDirs _
      | null (installIncludes bi) = []
      | otherwise                 = [includedir installDirs]
    bi = libBuildInfo lib
    installDirs = absoluteInstallDirs pkg lbi NoCopyDest


relocatableInstalledPackageInfo :: PackageDescription
                                -> AbiHash
                                -> Library
                                -> LocalBuildInfo
                                -> ComponentLocalBuildInfo
                                -> FilePath
                                -> InstalledPackageInfo
relocatableInstalledPackageInfo pkg abi_hash lib lbi clbi pkgroot =
    generalInstalledPackageInfo adjustReativeIncludeDirs
                                pkg abi_hash lib lbi clbi installDirs
  where
    -- For installed packages we install all include files into one dir,
    -- whereas in the build tree they may live in multiple local dirs.
    adjustReativeIncludeDirs _
      | null (installIncludes bi) = []
      | otherwise                 = [includedir installDirs]
    bi = libBuildInfo lib

    installDirs = fmap (("${pkgroot}" </>) . shortRelativePath pkgroot)
                $ absoluteInstallDirs pkg lbi NoCopyDest

-- -----------------------------------------------------------------------------
-- Unregistration

unregister :: PackageDescription -> LocalBuildInfo -> RegisterFlags -> IO ()
unregister pkg lbi regFlags = do
  let pkgid     = packageId pkg
      genScript = fromFlag (regGenScript regFlags)
      verbosity = fromFlag (regVerbosity regFlags)
      packageDb = fromFlagOrDefault (registrationPackageDB (withPackageDB lbi))
                                    (regPackageDB regFlags)
      unreg hpi =
        let invocation = HcPkg.unregisterInvocation
                           hpi Verbosity.normal packageDb pkgid
        in if genScript
             then writeFileAtomic unregScriptFileName
                    (BS.Char8.pack $ invocationAsSystemScript buildOS invocation)
             else runProgramInvocation verbosity invocation
  setupMessage verbosity "Unregistering" pkgid
  withHcPkg "unregistering is only implemented for GHC and GHCJS"
    (compiler lbi) (withPrograms lbi) unreg

unregScriptFileName :: FilePath
unregScriptFileName = case buildOS of
                          Windows -> "unregister.bat"
                          _       -> "unregister.sh"
