{-# LANGUAGE LambdaCase #-}


import           Data.Char (isSpace)
import           Data.List (dropWhileEnd, isPrefixOf,intersperse)
import qualified Data.Map as Map
import           Data.Maybe (catMaybes)
import           System.Directory (listDirectory, doesDirectoryExist, doesFileExist, removeFile)
import           System.Exit (ExitCode(..))
import           System.FilePath ((<.>), (</>), takeBaseName, takeExtension)
import qualified System.Process as Proc
import           Text.Parsec (parse, (<|>), (<?>), string, many1, digit)
import           Text.Parsec.String (Parser)

-- import           Mir.SAWInterface (loadMIR, extractMIR)
import qualified Verifier.SAW.FiniteValue as FV
import qualified Verifier.SAW.Prelude as SC
-- import qualified Verifier.SAW.SCTypeCheck as SC
import qualified Verifier.SAW.SharedTerm as SC
import qualified Verifier.SAW.Typechecker as SC
import qualified Verifier.SAW.Simulator.Concrete as Conc

import           Test.Tasty (defaultMain, testGroup, TestTree)
import           Test.Tasty.HUnit (Assertion, testCaseSteps, assertBool, assertFailure)




generateMIR :: FilePath -> String -> IO ExitCode
generateMIR dir name = do
  putStrLn $ "Generating " ++ dir ++ " " ++ name
  (ec, _, _) <- Proc.readProcessWithExitCode "mir-json" [dir </> name <.> "rs", "--crate-type", "lib"] ""
  let rlibFile = ("lib" ++ name) <.> "rlib"
  doesFileExist rlibFile >>= \case
    True -> removeFile rlibFile
    False -> return ()
  return ec

compileAndRun :: FilePath -> String -> IO (Maybe String)
compileAndRun dir name = do
  (ec, _, _) <- Proc.readProcessWithExitCode "rustc" [dir </> name <.> "rs", "--cfg", "with_main"] ""
  case ec of
    ExitFailure _ -> do
      putStrLn $ "rustc compilation failed for " ++ name
      return Nothing
    ExitSuccess -> do
      let execFile = "." </> name
      (ec', out, _) <- Proc.readProcessWithExitCode execFile [] ""
      doesFileExist execFile >>= \case
        True -> removeFile execFile
        False -> return ()
      case ec' of
        ExitFailure _ -> do
          putStrLn $ "non-zero exit code for test executable " ++ name
          return Nothing
        ExitSuccess -> return $ Just out

oracleTest :: FilePath -> String -> (String -> IO ()) -> Assertion
oracleTest dir name step = do
  
  step "Compiling and running oracle program"
  oracleOut <- compileAndRun dir name >>= \case
    Nothing -> assertFailure "failed to compile and run"
    Just out -> return out

  let orOut = dropWhileEnd isSpace oracleOut
  step ("Oracle output: " ++ orOut)

  (_cruxEC, cruxOutFull, _err) <- Proc.readProcessWithExitCode "cabal" ["new-exec", "crux-mir", dir </> name <.> "rs"] ""

  let cruxOut = dropWhileEnd isSpace cruxOutFull
  step ("Crux output: " ++ cruxOut ++ "\n")

  assertBool "crux doesn't match oracle" (orOut == cruxOut)


main :: IO ()
main = defaultMain =<< suite

suite :: IO TestTree
suite = testGroup "mir-verifier tests" <$> sequence
  [ testDir "test/conc_eval" ]

testDir :: FilePath -> IO TestTree
testDir dir = do
  let gen f | "." `isPrefixOf` takeBaseName f = return Nothing
      gen f | takeExtension f == ".rs" = return (Just (testCaseSteps name (oracleTest dir name)))
        where name = (takeBaseName f)
      gen f = doesDirectoryExist (dir </> f) >>= \case
        False -> return Nothing
        True -> Just <$> testDir (dir </> f)
  fs <- listDirectory dir
  tcs <- mapM gen fs
  return (testGroup (takeBaseName dir) (catMaybes tcs))

-- | Parse the Rust program output into a finite value at a given type
parseRustFV :: FV.FiniteType -> Parser (Maybe FV.FiniteValue)
parseRustFV ft = panic <|> (Just <$> p)
  where
    panic = string "<<PANIC>>" *> pure Nothing
    p = case ft of
          FV.FTBit ->
            string "true" *> pure (FV.FVBit True)
            <|> string "false" *> pure (FV.FVBit False)
            <?> "boolean"
          FV.FTVec w FV.FTBit -> do
            i <- read <$> many1 digit
            return (FV.FVWord w i)
          FV.FTVec _n _elt -> error "unimplemented"
          FV.FTTuple _elts -> error "unimplemented"
          FV.FTRec _fields -> error "unimplemented"
