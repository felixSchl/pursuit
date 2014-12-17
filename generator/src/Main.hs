-----------------------------------------------------------------------------
--
-- Module      :  Main
-- Copyright   :  (c) Phil Freeman 2014
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- | Data generator for the pursuit search engine
--
-----------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.List
import Data.List.Split (splitOn)
import Data.Maybe
import Data.Version (showVersion)

import Control.Applicative
import Control.Monad

import System.Console.CmdTheLine
import System.Exit (exitSuccess, exitFailure)
import System.IO (stderr)
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import System.Process (callProcess)
import System.FilePath.Glob (glob)

import qualified Data.Text as T
import qualified Data.Text.IO as T

import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.IO as TL
import qualified Data.Text.Lazy.Builder as TL

import Data.Aeson ((.=), (.:))
import qualified Data.Aeson as A
import qualified Data.Aeson.Encode as A

import qualified Language.PureScript as P
import qualified Paths_pursuit_gen as Paths

import Libraries

data PursuitEntry =
  PursuitEntry { entryName   :: String
               , entryModule :: String
               , entryDetail :: String
               }
               deriving (Show, Eq)

instance A.FromJSON PursuitEntry where
  parseJSON (A.Object o) =
    PursuitEntry <$> o .: "name" <*> o .: "module" <*> o .: "detail"
  parseJSON val = fail $ "couldn't parse " ++ show val ++ " as PursuitEntry"

instance A.ToJSON PursuitEntry where
  toJSON (PursuitEntry name mdl detail) =
    A.object [ "name"   .= name
             , "module" .= mdl
             , "detail" .= detail
             ]

pursuitGenAll :: Maybe FilePath -> IO ()
pursuitGenAll output = do
  entries <- generateAllData
  let json = entriesToJson entries
  case output of
    Just path -> mkdirp path >> TL.writeFile path json
    Nothing -> TL.putStrLn json
  exitSuccess

generateAllData :: IO [PursuitEntry]
generateAllData = do
  currentDir <- getCurrentDirectory
  let baseDir = currentDir </> workingDir

  entries <- forM libraries $ \lib -> do
    let dir = baseDir </> libraryDirFor lib
    gitClone (libraryGitUrl lib) dir
    libraryEntries (libraryBowerName lib) dir

  preludeEntries <- getPreludeEntries

  return $ preludeEntries ++ concat entries

workingDir :: String
workingDir = "./tmp/"

libraryDirFor :: Library -> FilePath
libraryDirFor lib =
  fromMaybe (last $ splitOn "/" $ libraryGitUrl lib) (libraryBowerName lib)

-- Clone the specified repository into the specified directory.
gitClone :: GitUrl -> FilePath -> IO ()
gitClone url dir = do
  callProcess "git" ["clone", url, dir]

libraryEntries :: Maybe String -> FilePath -> IO [PursuitEntry]
libraryEntries _ dir = do
  files <- glob $ dir </> "src/**/*.purs"
  ms <- mapM parseFile files
  return $ modulesToEntries (concat ms)

modulesToEntries :: [P.Module] -> [PursuitEntry]
modulesToEntries = concatMap entriesForModule

entriesToJson :: [PursuitEntry] -> TL.Text
entriesToJson = TL.toLazyText . A.encodeToTextBuilder . A.toJSON

getPreludeEntries :: IO [PursuitEntry]
getPreludeEntries =
  modulesToEntries <$> parseText "<<Prelude>>" (T.pack P.prelude)

pursuitGen :: [FilePath] -> Maybe FilePath -> IO ()
pursuitGen input output = do
  ms <- mapM parseFile (nub input)
  let json = modulesToJson (concat ms)
  case output of
    Just path -> mkdirp path >> TL.writeFile path json
    Nothing -> TL.putStrLn json
  exitSuccess

parseFile :: FilePath -> IO [P.Module]
parseFile input = do
  text <- T.readFile input
  parseText input text

parseText :: FilePath -> T.Text -> IO [P.Module]
parseText input text = do
  case P.runIndentParser input P.parseModules (T.unpack text) of
    Left err -> do
      T.hPutStr stderr $ T.pack $ show err
      exitFailure
    Right ms -> do
      return ms

mkdirp :: FilePath -> IO ()
mkdirp = createDirectoryIfMissing True . takeDirectory

modulesToJson :: [P.Module] -> TL.Text
modulesToJson = entriesToJson . modulesToEntries

entriesForModule :: P.Module -> [PursuitEntry]
entriesForModule (P.Module mn ds _) = concatMap (entriesForDeclaration mn) ds

entry :: P.ModuleName -> String -> String -> PursuitEntry
entry mn name detail = PursuitEntry name (show mn) detail

entriesForDeclaration :: P.ModuleName -> P.Declaration -> [PursuitEntry]
entriesForDeclaration mn (P.TypeDeclaration ident ty) =
  [entry mn (show ident) $ show ident ++ " :: " ++ prettyPrintType' ty]
entriesForDeclaration mn (P.ExternDeclaration _ ident _ ty) =
  [entry mn (show ident) $ show ident ++ " :: " ++ prettyPrintType' ty]
entriesForDeclaration mn (P.DataDeclaration dtype name args ctors) =
  let typeName = P.runProperName name ++ (if null args then "" else " " ++ unwords (map fst args))
      detail = show dtype ++ " " ++ typeName ++ (if null ctors then "" else " = ") ++
        intercalate " | " (map (\(ctor, tys) ->
          intercalate " " (P.runProperName ctor : map P.prettyPrintTypeAtom tys)) ctors)
  in entry mn (show name) detail : map (\(ctor, _) -> entry mn (show ctor) detail) ctors
entriesForDeclaration mn (P.ExternDataDeclaration name kind) =
  [entry mn (show name) $ "data " ++ P.runProperName name ++ " :: " ++ P.prettyPrintKind kind]
entriesForDeclaration mn (P.TypeSynonymDeclaration name args ty) =
  let typeName = P.runProperName name ++ " " ++ unwords (map fst args)
  in [entry mn (show name) $ "type " ++ typeName ++ " = " ++ prettyPrintType' ty]
entriesForDeclaration mn (P.TypeClassDeclaration name args implies ds) =
  let impliesText = case implies of
                      [] -> ""
                      is -> "(" ++ intercalate ", " (map (\(pn, tys') -> show pn ++ " " ++ unwords (map P.prettyPrintTypeAtom tys')) is) ++ ") <= "
      detail = "class " ++ impliesText ++ P.runProperName name ++ " " ++ unwords (map fst args) ++ " where"
  in entry mn (show name) detail : concatMap (entriesForDeclaration mn) ds
entriesForDeclaration mn (P.TypeInstanceDeclaration name constraints className tys _) = do
  let constraintsText = case constraints of
                          [] -> ""
                          cs -> "(" ++ intercalate ", " (map (\(pn, tys') -> show pn ++ " " ++ unwords (map P.prettyPrintTypeAtom tys')) cs) ++ ") => "
  [entry mn (show name) $ "instance " ++ show name ++ " :: " ++ constraintsText ++ show className ++ " " ++ unwords (map P.prettyPrintTypeAtom tys)]
entriesForDeclaration mn (P.PositionedDeclaration _ d) =
  entriesForDeclaration mn d
entriesForDeclaration _ _ = []

prettyPrintType' :: P.Type -> String
prettyPrintType' = P.prettyPrintType . P.everywhereOnTypes dePrim
  where
  dePrim ty@(P.TypeConstructor (P.Qualified _ name))
    | ty == P.tyBoolean || ty == P.tyNumber || ty == P.tyString =
      P.TypeConstructor $ P.Qualified Nothing name
  dePrim other = other

inputFiles :: Term [FilePath]
inputFiles = value $ posAny [] $ posInfo { posName = "file(s)", posDoc = "The input .purs file(s)" }

outputFile :: Term (Maybe FilePath)
outputFile = value $ opt Nothing $ (optInfo [ "o", "output" ]) { optDoc = "The output .json file" }

term :: Term (IO ())
term = pursuitGenAll <$> outputFile
--term = pursuitGen <$> inputFiles <*> outputFile

termInfo :: TermInfo
termInfo = defTI
  { termName = "pursuit-gen"
  , version  = showVersion Paths.version
  , termDoc  = "Generate data for use with the pursuit search engine"
  }

main :: IO ()
main = run (term, termInfo)
