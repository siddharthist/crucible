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
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Crux.LLVM.Bugfinding.Setup
  ( setupExecution
  , logRegMap
  ) where

import           Control.Lens (to, view, (^.))
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Data.Text (Text)

import           Lumberjack (HasLog, writeLogM)

import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Some (Some(..))
import           Data.Parameterized.Map (MapF)

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
import           Crux.LLVM.Bugfinding.Setup.Monad

-- TODO unsorted
import Data.Proxy (Proxy(Proxy))
import qualified Data.Text as Text
import Data.Functor.Const (Const(getConst))
import Control.Monad.State (gets)
import Data.Parameterized.Classes (IxedF'(ixF'))
import Prettyprinter (Doc)
import Lang.Crucible.LLVM.MemType (MemType)
import Data.Maybe (fromMaybe)

data ExecutionSetupError = ExecutionSetupError

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
  Crucible.RegMap sym argTypes ->
  m ()
logRegMap context sym mem (Crucible.RegMap regmap) =
  Ctx.traverseWithIndex_
    (\index regEntry ->
      do let storageType =
               context ^. argumentStorageTypes . ixF' index . to getConst
         arg <-
           liftIO $
             ppRegValue (Proxy :: Proxy arch) sym mem storageType regEntry
         writeLogM $
           Text.unwords
             [ "Argument"
             , fromMaybe
                 (Text.pack (show (Ctx.indexVal index)) <> ":")
                 (context ^. argumentNames . ixF' index . to getConst)
             , Text.pack (show arg)
             -- , "(type:"
             -- , Text.pack (show (Crucible.regType arg)) <> ")"
             ])
    regmap


annotatedTerm ::
  forall arch sym tp argTypes.
  (Crucible.IsSymInterface sym) =>
  sym ->
  CrucibleTypes.BaseTypeRepr tp ->
  Selector argTypes ->
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
  Context arch argTypes ->
  sym ->
  CrucibleTypes.TypeRepr tp ->
  Selector argTypes ->
  Setup arch sym argTypes (Crucible.RegValue sym tp)
generateMinimalValue _proxy sym typeRepr selector =
  let unimplemented = error ("Unimplemented: " ++ show typeRepr) -- TODO(lb)
  in
    case CrucibleTypes.asBaseType typeRepr of
      CrucibleTypes.AsBaseType baseTypeRepr ->
        annotatedTerm sym baseTypeRepr selector
      CrucibleTypes.NotBaseType ->
        case typeRepr of
          CrucibleTypes.UnitRepr -> return ()
          CrucibleTypes.AnyRepr ->
            -- TODO(lb): Should be made more complex
            return $ Crucible.AnyValue CrucibleTypes.UnitRepr ()

          LLVMMem.PtrRepr ->
            do liftIO . LLVMMem.llvmPointer_bv sym =<<
                 annotatedTerm sym (CrucibleTypes.BaseBVRepr ?ptrWidth) selector
          CrucibleTypes.VectorRepr _containedTypeRepr -> unimplemented
          CrucibleTypes.StructRepr _containedTypes -> unimplemented
          _ -> unimplemented -- TODO(lb)

-- TODO(lb): Replace with "generate"

generateMinimalArgs ::
  forall arch sym argTypes.
  ( Crucible.IsSymInterface sym
  , ArchOk arch
  ) =>
  Context arch argTypes ->
  sym ->
  Setup arch sym argTypes (Crucible.RegMap sym argTypes)
generateMinimalArgs context sym = do
  writeLogM $ "Generating minimal arguments for " <>
                context ^. functionName
  let argTypesRepr = context ^. argumentTypes
  args <-
    Crucible.RegMap <$>
      Ctx.generateM
        (Ctx.size argTypesRepr)
        (\index ->
          let typeRepr = argTypesRepr Ctx.! index
          in Crucible.RegEntry typeRepr <$>
                generateMinimalValue
                  context
                  sym
                  typeRepr
                  (SelectArgument (Some index) Here))
  mem <- gets (view setupMem)
  logRegMap context sym mem args
  return args


-- -- | Allocate a memory region.
-- doMalloc
-- :: (IsSymInterface sym, HasPtrWidth wptr)
-- => sym
-- -> G.AllocType {- ^ stack, heap, or global -}
-- -> G.Mutability {- ^ whether region is read-only -}
-- -> String {- ^ source location for use in error messages -}
-- -> MemImpl sym
-- -> SymBV sym wptr {- ^ allocation size -}
-- -> Alignment
-- -> IO (LLVMPtr sym wptr, MemImpl sym)
constrainHere ::
  forall proxy arch sym argTypes tp.
  ( Crucible.IsSymInterface sym
  , ArchOk arch
  ) =>
  proxy arch ->
  sym ->
  Constraint ->
  Crucible.RegEntry sym tp ->
  Setup arch sym argTypes (Crucible.RegEntry sym tp)
constrainHere proxy sym constraint (Crucible.RegEntry typeRepr regValue) =
  case constraint of
    Initialized ->
      case typeRepr of
        LLVMMem.PtrRepr -> error "Unimplemented: constrainHere"
        _ -> error "Bad cursor"

constrainValue ::
  forall proxy arch sym argTypes tp.
  ( Crucible.IsSymInterface sym
  , ArchOk arch
  ) =>
  proxy arch ->
  sym ->
  Constraint ->
  Cursor ->
  Crucible.RegEntry sym tp ->
  Setup arch sym argTypes (Crucible.RegEntry sym tp)
constrainValue proxy sym constraint cursor regEntry =
  case cursor of
    Here -> constrainHere proxy sym constraint regEntry

constrainOneArgument ::
  forall proxy arch sym argTypes tp.
  ( Crucible.IsSymInterface sym
  , ArchOk arch
  ) =>
  proxy arch ->
  sym ->
  [ValueConstraint] ->
  Crucible.RegEntry sym tp ->
  Setup arch sym argTypes (Crucible.RegEntry sym tp)
constrainOneArgument proxy sym constraints regEntry =
  -- TODO fold
  case constraints of
    [] -> pure regEntry
    (ValueConstraint constraint cursor:rest) ->
      constrainOneArgument proxy sym rest
        =<< constrainValue proxy sym constraint cursor regEntry

constrain ::
  forall proxy arch sym argTypes.
  ( Crucible.IsSymInterface sym
  , ArchOk arch
  ) =>
  proxy arch ->
  sym ->
  Constraints argTypes ->
  Crucible.RegMap sym argTypes ->
  Setup arch sym argTypes (Crucible.RegMap sym argTypes)
constrain proxy sym preconds (Crucible.RegMap args) =
  do writeLogM ("Establishing preconditions..." :: Text)
     writeLogM ("Modifying arguments..." :: Text)
     args' <-
       Ctx.traverseWithIndex
         (\idx -> constrainOneArgument
                    proxy
                    sym
                    (getConst (argConstraints preconds Ctx.! idx)))
         args
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
  Constraints argTypes ->
  m (Either ExecutionSetupError (LLVMMem.MemImpl sym, MapF (What4.SymAnnotation sym) (TypedSelector argTypes), Crucible.RegMap sym argTypes))
setupExecution sym context preconds = do
  -- TODO(lb): More lazy here?
  let moduleTrans = context ^. moduleTranslation
  let llvmCtxt = moduleTrans ^. LLVMTrans.transContext
  -- TODO: More lazy?
  mem <-
    let ?lc = llvmCtxt ^. LLVMTrans.llvmTypeCtx
    in liftIO $
         LLVMGlobals.populateAllGlobals sym (LLVMTrans.globalInitMap moduleTrans)
           =<< LLVMGlobals.initializeAllMemory sym llvmCtxt (context ^. llvmModule)
  Right <$>
    runSetup context mem (constrain moduleTrans sym preconds =<<
                            generateMinimalArgs context sym)