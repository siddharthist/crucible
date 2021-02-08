{-
Module       : Crux.LLVM.Bugfinding.Classify
Description  : Classify errors as true positives or due to missing preconditions
Copyright    : (c) Galois, Inc 2021
License      : BSD3
Maintainer   : Langston Barrett <langston@galois.com>
Stability    : provisional
-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Crux.LLVM.Bugfinding.Classify
  ( Explanation(..)
  , TruePositive(..)
  , ppExplanation
  , classify
  ) where

import           Control.Lens (to, (^.))
import           Control.Monad.IO.Class (liftIO, MonadIO)
import           Data.Text (Text)
import qualified Data.Text as Text

import           Lumberjack (writeLogM, HasLog)

import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.Some (Some(Some))

import qualified What4.Interface as What4

import qualified Lang.Crucible.Backend as Crucible
import qualified Lang.Crucible.Simulator as Crucible

-- import qualified Lang.Crucible.LLVM.MemModel as LLVMMem
import qualified Lang.Crucible.LLVM.MemModel.Pointer as LLVMPointer
import qualified Lang.Crucible.LLVM.Errors as LLVMErrors
import qualified Lang.Crucible.LLVM.Errors.MemoryError as LLVMErrors

import           Crux.LLVM.Bugfinding.Constraints
import           Crux.LLVM.Bugfinding.Context
import           Crux.LLVM.Bugfinding.Cursor (ppCursor)
import           Crux.LLVM.Bugfinding.Setup.Monad (TypedSelector(..))
import Data.Parameterized.Classes (IxedF'(ixF'))
import Data.Functor.Const (Const(getConst))

data TruePositive
  -- TODO which
  = UninitializedStackVariable
  | Generic Text

-- | An error is either a true positive, or a false positives due to some
-- missing preconditions.
data Explanation types
  = ExTruePositive TruePositive
  | ExMissingPreconditions (Constraints types)

ppExplanation :: Explanation types -> Text
ppExplanation =
  \case
    ExTruePositive truePositive ->
      case truePositive of
        UninitializedStackVariable -> "Uninitialized stack variable"
        Generic text -> text
    ExMissingPreconditions constraints -> "Missing constraints"


-- | Take an error that occurred during symbolic execution, classify it as a
-- true or false positive. If it is a false positive, deduce further
-- preconditions.
classify ::
  forall m sym arch argTypes.
  ( Crucible.IsSymInterface sym
  , MonadIO m
  , HasLog Text m
  ) =>
  Context arch argTypes ->
  sym ->
  Crucible.RegMap sym argTypes {-^ Function arguments -} ->
  MapF (What4.SymAnnotation sym) (TypedSelector argTypes)
    {-^ Term annotations (origins) -} ->
  LLVMErrors.BadBehavior sym {-^ Data about the error that occurred -} ->
  m (Explanation argTypes)
classify context sym (Crucible.RegMap args) annotations badBehavior =
  writeLogM ("Explaining error: " <> Text.pack (show (LLVMErrors.explainBB badBehavior))) >>
  case badBehavior of
    LLVMErrors.BBUndefinedBehavior _ -> error "Unimplemented"
    LLVMErrors.BBMemoryError
      (LLVMErrors.MemoryError
        _op
        (LLVMErrors.NoSatisfyingWrite _storageType ptr)) ->
          let annotation =
                What4.getAnnotation sym (LLVMPointer.llvmPointerOffset ptr)
          in case flip MapF.lookup annotations =<< annotation of
               Just (TypedSelector (SelectArgument (Some idx) cursor) _typeRepr) ->
                 do writeLogM $
                      Text.unwords
                        [ "Conclusion: Read from an unmapped pointer in argument"
                        , "#" <> Text.pack (show (Ctx.indexVal idx))
                        , "at"
                        , Text.pack
                            (show
                               (ppCursor
                                  (context ^. argumentNames . ixF' idx . to getConst . to (maybe "<top>" Text.unpack))
                                  cursor))
                        ]
                    return $
                      ExMissingPreconditions $
                        oneArgumentConstraint
                          (Ctx.size args)
                          idx
                          [ValueConstraint Initialized cursor]
               Just (TypedSelector (SelectGlobal _symbol _cursor) _typeRepr) ->
                 error "Unimplemented: Global"
               -- TODO(lb): Something about globals, probably?
               Nothing -> error ("Unimplemented:" ++ show (LLVMPointer.ppPtr ptr) ++
                                 case annotation of
                                   Just _ann -> " Annotated"
                                   Nothing -> " not annotated")
          --if undefined sym ptr args
          -- then pure (ExMissingPreconditions (error "unimplemented"))
          -- else pure (ExTruePositive (Generic "No write"))
    _ -> pure $ ExTruePositive (Generic "Unknown error (assuming true positive)")