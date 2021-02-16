{-
Module       : Crux.LLVM.Bugfinding.Setup
Description  : Setting up memory and function args according to preconditions.
Copyright    : (c) Galois, Inc 2021
License      : BSD3
Maintainer   : Langston Barrett <langston@galois.com>
Stability    : provisional
-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

module Crux.LLVM.Bugfinding.Setup
  ( setupExecution
  , logRegMap
  , SetupAssumption(SetupAssumption)
  , SetupResult(SetupResult)
  ) where

import           Control.Lens (to, (^.), (%~))
import           Control.Monad (void)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Data.Function ((&))
import           Data.Functor.Const (Const(Const, getConst))
import qualified Data.Set as Set
import           Data.Text (Text)
import           Data.Type.Equality ((:~:)(Refl))

import           Lumberjack (HasLog, writeLogM)

import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Some (Some(..))

import qualified What4.Interface as What4

import qualified Lang.Crucible.Backend as Crucible
import qualified Lang.Crucible.Simulator as Crucible
import qualified Lang.Crucible.Types as CrucibleTypes

import qualified Lang.Crucible.LLVM.MemModel as LLVMMem
import qualified Lang.Crucible.LLVM.Globals as LLVMGlobals
import qualified Lang.Crucible.LLVM.Translation as LLVMTrans


import           Crux.LLVM.Overrides (ArchOk)

import           Crux.LLVM.Bugfinding.Constraints
import           Crux.LLVM.Bugfinding.Context
import           Crux.LLVM.Bugfinding.Cursor
import           Crux.LLVM.Bugfinding.FullType.CrucibleType (SomeIndex(..), translateIndex, generateM)
import           Crux.LLVM.Bugfinding.FullType.Type (FullType(FTPtr), ToCrucibleType, MapToCrucibleType, FullTypeRepr(FTPtrRepr))
import           Crux.LLVM.Bugfinding.Errors.Unimplemented (unimplemented)
import           Crux.LLVM.Bugfinding.Setup.Monad
import           Crux.LLVM.Bugfinding.Setup.LocalMem (TypedRegEntry(..))

-- TODO unsorted
import Data.Proxy (Proxy(Proxy))
import qualified Data.Text as Text
import Control.Monad.State (gets)
import Data.Parameterized.Classes (IxedF'(ixF'))
import Prettyprinter (Doc)
import Lang.Crucible.LLVM.MemType (MemType(PtrType))
import Data.Maybe (fromMaybe)
import Control.Monad.Error.Class (MonadError(throwError))
import Lang.Crucible.LLVM.TypeContext (asMemType)
import Lang.Crucible.LLVM.Extension (ArchWidth)

ppRegValue ::
  ( Crucible.IsSymInterface sym
  , ArchOk arch
  ) =>
  proxy arch ->
  sym ->
  LLVMMem.MemImpl sym ->
  LLVMMem.StorageType ->
  Crucible.RegEntry sym tp ->
  IO (Doc ann)
ppRegValue _proxy sym mem storageType (Crucible.RegEntry typeRepr regValue) =
  do val <-
       liftIO $
         LLVMMem.packMemValue sym storageType typeRepr regValue
     pure $
       LLVMMem.ppLLVMValWithGlobals
         sym
         (LLVMMem.memImplSymbolMap mem)
         val

logRegMap ::
  forall m arch sym argTypes.
  ( Crucible.IsSymInterface sym
  , ArchOk arch
  , MonadIO m
  , HasLog Text m
  ) =>
  Context arch argTypes ->
  sym ->
  LLVMMem.MemImpl sym ->
  Crucible.RegMap sym (MapToCrucibleType argTypes) ->
  m ()
logRegMap context sym mem (Crucible.RegMap regmap) =
  Ctx.traverseWithIndex_
    (\index (Const storageType) ->
       case translateIndex (Ctx.size (context ^. argumentStorageTypes)) index of
         SomeIndex idx Refl ->
           do let regEntry = regmap Ctx.! idx
              arg <-
                liftIO $
                  ppRegValue (Proxy :: Proxy arch) sym mem storageType regEntry
              writeLogM $
                Text.unwords
                  [ "Argument #" <> Text.pack (show (Ctx.indexVal index))
                  , fromMaybe "" (context ^. argumentNames . ixF' index . to getConst) <> ":"
                  , Text.pack (show arg)
                  -- , "(type:"
                  -- , Text.pack (show (Crucible.regType arg)) <> ")"
                  ])
    (context ^. argumentStorageTypes)


annotatedTerm ::
  forall arch sym tp argTypes.
  (Crucible.IsSymInterface sym) =>
  sym ->
  CrucibleTypes.BaseTypeRepr tp ->
  Selector arch argTypes ->
  Setup arch sym argTypes (What4.SymExpr sym tp)
annotatedTerm sym typeRepr selector =
  do symbol <- freshSymbol
      -- TODO(lb): Is freshConstant correct here?
     (annotation, expr) <-
        liftIO $ What4.annotateTerm sym =<< What4.freshConstant sym symbol typeRepr
     addAnnotation annotation selector typeRepr
     pure expr

generateMinimalValue ::
  forall proxy sym arch tp argTypes.
  (Crucible.IsSymInterface sym, ArchOk arch) =>
  proxy arch ->
  sym ->
  CrucibleTypes.TypeRepr tp ->
  Selector arch argTypes {-^ Path to this value -} ->
  Setup arch sym argTypes (Crucible.RegValue sym tp)
generateMinimalValue proxy sym typeRepr selector =
  case CrucibleTypes.asBaseType typeRepr of
    CrucibleTypes.AsBaseType baseTypeRepr ->
      annotatedTerm sym baseTypeRepr selector
    CrucibleTypes.NotBaseType ->
      case typeRepr of
        CrucibleTypes.UnitRepr -> return ()
        CrucibleTypes.AnyRepr ->
          -- TODO(lb): Should be made more complex
          return $ Crucible.AnyValue CrucibleTypes.UnitRepr ()
        LLVMMem.LLVMPointerRepr w ->
          do liftIO . LLVMMem.llvmPointer_bv sym =<<
                annotatedTerm sym (CrucibleTypes.BaseBVRepr w) selector
        CrucibleTypes.VectorRepr _containedTypeRepr ->
          -- TODO(lb): These are fixed size. What size should we generate?
          unin "Generating values of vector types"
        CrucibleTypes.StructRepr types ->
          Ctx.generateM
            (Ctx.size types)
            (\idx ->
               Crucible.RV <$>
                 -- TODO(lb): This selector is wrong
                 generateMinimalValue  proxy sym (types Ctx.! idx) selector)
        _ -> unin ("Generating values of this type: " ++ show typeRepr)
  where unin = unimplemented "generateMinimalValue"

generateMinimalArgs ::
  forall arch sym argTypes.
  ( Crucible.IsSymInterface sym
  , ArchOk arch
  ) =>
  Context arch argTypes ->
  sym ->
  Setup arch sym argTypes (Crucible.RegMap sym (MapToCrucibleType argTypes))
generateMinimalArgs context sym = do
  writeLogM $ "Generating minimal arguments for " <>
                context ^. functionName
  let argTypesRepr = context ^. argumentCrucibleTypes
  args <-
    Crucible.RegMap <$>
      generateM
        (Ctx.size (context ^. argumentFullTypes))
        (\index _index' Refl ->
           case translateIndex (Ctx.size (context ^. argumentFullTypes)) index of
             SomeIndex index' Refl ->
              let typeRepr = argTypesRepr Ctx.! index'
              in Crucible.RegEntry typeRepr <$>
                    generateMinimalValue
                      (Proxy :: Proxy arch)
                      sym
                      typeRepr
                      (SelectArgument (Some index) Here))
                  -- (case translateIndex (Ctx.size (context ^. argumentFullTypes)) index of
                  --    SomeIndex index' Refl -> SelectArgument (Some index) Here))
  mem <- gets setupMemImpl
  logRegMap context sym mem args
  return args

-- | If this pointer already points to initialized memory, then just return the
-- value. Otherwise, allocate some memory and initialize it with a fresh, minimal
-- value.
--
-- TODO: Allow for array initialization
initialize ::
  forall arch sym argTypes full ft.
  ( Crucible.IsSymInterface sym
  , LLVMMem.HasLLVMAnn sym
  , ArchOk arch
  ) =>
  Context arch argTypes ->
  sym ->
  MemType ->
  FullTypeRepr full arch ('FTPtr ft) {-^ Type of pointer -} ->
  Selector arch argTypes {-^ Selector for the pointer -} ->
  LLVMMem.LLVMPtr sym (ArchWidth arch) ->
  Setup arch sym argTypes ( LLVMMem.LLVMPtr sym (ArchWidth arch)
                          , Crucible.RegEntry sym (ToCrucibleType ft)
                          )
initialize context sym pointedToType ftPtr@(FTPtrRepr _ _ ftPointedTo) selector pointer =
  load sym ftPointedTo pointer >>=
    \case
      Just (TypedRegEntry _fullTypeRepr' regEntry) -> pure (pointer, regEntry)
      Nothing ->
        withTypeContext context $
          LLVMTrans.llvmTypeAsRepr
            pointedToType
            (\tp ->  -- the Crucible type being pointed at
              do ptr <- malloc sym ftPointedTo pointedToType pointer
                 pointedToVal <-
                   generateMinimalValue
                     (Proxy :: Proxy arch)
                     sym
                     tp
                     (selector & selectorCursor %~ Dereference)
                 ptr' <-
                   store sym ftPointedTo pointedToType (Crucible.RegEntry tp pointedToVal) ptr
                 pure (ptr', Crucible.RegEntry tp pointedToVal))

constrainHere ::
  forall arch sym argTypes tp.
  ( Crucible.IsSymInterface sym
  , LLVMMem.HasLLVMAnn sym
  , ArchOk arch
  ) =>
  Context arch argTypes ->
  sym ->
  Selector arch argTypes {-^ Top-level selector -} ->
  Constraint ->
  MemType ->
  Crucible.RegEntry sym tp ->
  Setup arch sym argTypes (Crucible.RegEntry sym tp)
constrainHere context sym selector constraint memType regEntry@(Crucible.RegEntry typeRepr regValue) =
  do writeLogM ("Constraining value at: " <> Text.pack (show (ppCursor "<top>" (selector ^. selectorCursor))))
     writeLogM ("Constraint: " <> Text.pack (show (ppConstraint constraint)))
     let showMe :: forall t ann. Crucible.RegEntry sym t -> MemType -> Setup arch sym argTypes (Doc ann)
         showMe regEnt memTy =
           do mem <- gets setupMemImpl
              storableTy <- storableType memTy
              liftIO $ ppRegValue (Proxy :: Proxy arch) sym mem storableTy regEnt
     case constraint of
       Allocated ->
         case typeRepr of
           LLVMMem.PtrRepr ->
             do regEntry' <- Crucible.RegEntry typeRepr <$> malloc sym memType regValue
                pretty <- showMe regEntry' memType
                writeLogM ("Constrained value: " <> Text.pack (show pretty))
                pure regEntry'
           _ -> throwError (SetupBadConstraintSelector selector memType constraint)
       Aligned alignment ->
         case typeRepr of
           LLVMMem.PtrRepr ->
             do assume constraint =<<
                  liftIO (LLVMMem.isAligned sym ?ptrWidth regValue alignment)
                pure regEntry
           _ -> throwError (SetupBadConstraintSelector selector memType constraint)
       Initialized ->
         withTypeContext context $
           case (typeRepr, memType) of
             (LLVMMem.PtrRepr, PtrType (asMemType -> Right pointedToType)) ->
               do (ptr, Some freshVal) <-
                    initialize context sym pointedToType selector regValue
                  let regEntry' = Crucible.RegEntry typeRepr ptr
                  prettyPtr <- showMe regEntry' memType
                  prettyVal <- showMe freshVal pointedToType
                  writeLogM ("Initialized pointer: " <> Text.pack (show prettyPtr))
                  writeLogM ("Pointed-to value: " <> Text.pack (show prettyVal))
                  pure regEntry'
             _ -> throwError (SetupBadConstraintSelector selector memType constraint)
       _ -> unimplemented "constrainHere" ("Constraint:" ++ show (ppConstraint constraint))

constrainValue ::
  forall arch sym argTypes tp.
  ( Crucible.IsSymInterface sym
  , LLVMMem.HasLLVMAnn sym
  , ArchOk arch
  ) =>
  Context arch argTypes ->
  sym ->
  Constraint ->
  Selector arch argTypes {-^ Parent selector for the cursor -} ->
  Cursor ->
  MemType {-^ The \"leaf\" 'MemType', passed directly to 'constrainHere' -} ->
  Crucible.RegEntry sym tp ->
  Setup arch sym argTypes (Crucible.RegEntry sym tp)
constrainValue context sym constraint selector cursor memType regEntry@(Crucible.RegEntry typeRepr regValue) =
  case cursor of
    Here -> constrainHere context sym selector constraint memType regEntry
    Dereference cursor' ->
      case typeRepr of
        LLVMMem.PtrRepr ->
          do -- If there's already a value behind this pointer, constrain that.
             -- Otherwise, allocate new memory, put a fresh value there, and constrain
             -- that.
             (ptr, Some pointedToValue) <-
               initialize context sym memType selector regValue
             void $ constrainValue context sym constraint selector cursor' memType pointedToValue
             pure $ Crucible.RegEntry typeRepr ptr
        _ -> throwError (SetupBadConstraintSelector selector memType constraint)
    _ -> unimplemented "constrainValue" "Non-top-level cursors"

constrainOneArgument ::
  forall arch sym argTypes tp.
  ( Crucible.IsSymInterface sym
  , LLVMMem.HasLLVMAnn sym
  , ArchOk arch
  ) =>
  Context arch argTypes ->
  sym ->
  [ValueConstraint] ->
  Some (Ctx.Index argTypes) ->
  Crucible.RegEntry sym tp ->
  Setup arch sym argTypes (Crucible.RegEntry sym tp)
constrainOneArgument context sym constraints sidx@(Some idx) regEntry =
  -- TODO fold
  case constraints of
    [] -> pure regEntry
    (vc@(ValueConstraint constraint cursor):rest) ->
      do memType <-
           seekType cursor (context ^. argumentMemTypes . ixF' idx . to getConst)
         writeLogM ("Satisfying constraint: " <> Text.pack (show (ppValueConstraint vc)))
         constrainOneArgument context sym rest sidx
           =<< constrainValue
                 context
                 sym
                 constraint
                 (SelectArgument sidx cursor)
                 cursor
                 memType
                 regEntry

constrain ::
  forall arch sym argTypes.
  ( Crucible.IsSymInterface sym
  , LLVMMem.HasLLVMAnn sym
  , ArchOk arch
  ) =>
  Context arch argTypes ->
  sym ->
  Constraints arch argTypes ->
  Crucible.RegMap sym (MapToCrucibleType argTypes) ->
  Setup arch sym argTypes (Crucible.RegMap sym (MapToCrucibleType argTypes))
constrain context sym preconds (Crucible.RegMap args) =
  do writeLogM ("Establishing preconditions..." :: Text)
     args' <-
       generateM
         (Ctx.size (context ^. argumentStorageTypes))
         (\idx idx' Refl ->
            do writeLogM ("Modifying argument #" <> Text.pack (show (Ctx.indexVal idx)))
               constrainOneArgument
                 context
                 sym
                 (Set.toList (getConst (argConstraints preconds Ctx.! idx)))
                 (Some idx)
                 (args Ctx.! idx'))
     return (Crucible.RegMap args')

setupExecution ::
  ( Crucible.IsSymInterface sym
  , LLVMMem.HasLLVMAnn sym
  , ArchOk arch
  , HasLog Text m
  , MonadIO m
  ) =>
  sym ->
  Context arch argTypes ->
  Constraints arch argTypes ->
  m (Either (SetupError arch argTypes)
            ( SetupResult arch sym argTypes
            , Crucible.RegMap sym (MapToCrucibleType argTypes)
            ))
setupExecution sym context preconds = do
  -- TODO(lb): More lazy here?
  let moduleTrans = context ^. moduleTranslation
  let llvmCtxt = moduleTrans ^. LLVMTrans.transContext
  -- TODO: More lazy?
  mem <-
    withTypeContext context $
      liftIO $
        LLVMGlobals.populateAllGlobals sym (LLVMTrans.globalInitMap moduleTrans)
          =<< LLVMGlobals.initializeAllMemory sym llvmCtxt (context ^. llvmModule)
  runSetup context mem (constrain context sym preconds =<<
                          generateMinimalArgs context sym)
