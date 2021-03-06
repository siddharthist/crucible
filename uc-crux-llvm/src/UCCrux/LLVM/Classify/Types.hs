{-
Module       : UCCrux.LLVM.Classify.Types
Description  : Types and utility functions on them used in classification
Copyright    : (c) Galois, Inc 2021
License      : BSD3
Maintainer   : Langston Barrett <langston@galois.com>
Stability    : provisional
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}

module UCCrux.LLVM.Classify.Types
  ( Explanation (..),
    partitionExplanations,
    TruePositive (..),
    LocatedTruePositive (..),
    TruePositiveTag (..),
    truePositiveTag,
    Diagnosis (..),
    DiagnosisTag (..),
    diagnose,
    diagnoseTag,
    prescribe,
    ppTruePositive,
    ppLocatedTruePositive,
    ppTruePositiveTag,
    Unclassified (..),
    doc,
    Uncertainty (..),
    partitionUncertainty,
    ppUncertainty,
    Unfixable (..),
    ppUnfixable,
    Unfixed (..),
    ppUnfixed,
  )
where

{- ORMOLU_DISABLE -}
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Void (Void)

import           Prettyprinter (Doc)
import qualified Prettyprinter as PP
import qualified Prettyprinter.Render.Text as PP

import           Data.Parameterized.Ctx (Ctx)

import qualified What4.ProgramLoc as What4

import qualified Lang.Crucible.LLVM.Errors.UndefinedBehavior as UB

import           Prelude hiding (log)

import           Control.Exception (displayException)
import           Control.Lens (Lens', lens, to, (^.))
import           Panic (Panic)

import           Data.Parameterized.Some (Some)

import qualified Lang.Crucible.Simulator as Crucible

import           UCCrux.LLVM.Constraints (NewConstraint)
import           UCCrux.LLVM.Cursor (Where(..))
import           UCCrux.LLVM.Errors.Unimplemented (Unimplemented)
import           UCCrux.LLVM.FullType.Type (FullType)
{- ORMOLU_ENABLE -}

data TruePositiveTag
  = TagConcretelyFailingAssert
  | TagDoubleFree
  | TagUDivByConcreteZero
  | TagSDivByConcreteZero
  | TagURemByConcreteZero
  | TagSRemByConcreteZero
  | TagReadNonPointer
  | TagWriteNonPointer
  | TagFreeNonPointer
  | TagReadUninitializedStack
  | TagReadUninitializedHeap
  | TagCallNonFunctionPointer
  | TagFloatToPointer
  deriving (Eq, Ord)

data TruePositive
  = ConcretelyFailingAssert
  | DoubleFree
  | UDivByConcreteZero
  | SDivByConcreteZero
  | URemByConcreteZero
  | SRemByConcreteZero
  | ReadNonPointer
  | WriteNonPointer
  | FreeNonPointer
  | ReadUninitializedStack !String -- program location of allocation
  | ReadUninitializedHeap !String -- program location of allocation
  | CallNonFunctionPointer !String -- program location of allocation
  | FloatToPointer
  deriving (Eq, Ord)

data LocatedTruePositive = LocatedTruePositive
  { truePositive :: !TruePositive,
    truePositiveLoc :: !What4.ProgramLoc
  }
  deriving (Eq, Ord)

ppLocatedTruePositive :: LocatedTruePositive -> Text
ppLocatedTruePositive (LocatedTruePositive pos loc) =
  Text.unwords
    [ ppTruePositive pos,
      Text.pack "at",
      Text.pack (show (What4.plSourceLoc loc))
    ]

truePositiveTag :: TruePositive -> TruePositiveTag
truePositiveTag =
  \case
    ConcretelyFailingAssert {} -> TagConcretelyFailingAssert
    DoubleFree {} -> TagDoubleFree
    UDivByConcreteZero {} -> TagUDivByConcreteZero
    SDivByConcreteZero {} -> TagSDivByConcreteZero
    URemByConcreteZero {} -> TagURemByConcreteZero
    SRemByConcreteZero {} -> TagSRemByConcreteZero
    ReadNonPointer {} -> TagReadNonPointer
    WriteNonPointer {} -> TagWriteNonPointer
    FreeNonPointer {} -> TagFreeNonPointer
    ReadUninitializedStack {} -> TagReadUninitializedStack
    ReadUninitializedHeap {} -> TagReadUninitializedHeap
    CallNonFunctionPointer {} -> TagCallNonFunctionPointer
    FloatToPointer {} -> TagFloatToPointer

ppTruePositiveTag :: TruePositiveTag -> Text
ppTruePositiveTag =
  \case
    TagConcretelyFailingAssert -> "Concretely failing user assertion"
    TagDoubleFree -> "Double free"
    TagUDivByConcreteZero -> "Unsigned division with a concretely zero divisor"
    TagSDivByConcreteZero -> "Signed division with a concretely zero divisor"
    TagURemByConcreteZero -> "Unsigned remainder with a concretely zero divisor"
    TagSRemByConcreteZero -> "Signed remainder with a concretely zero divisor"
    TagReadNonPointer -> "Read from data that concretely wasn't a pointer"
    TagWriteNonPointer -> "Write to data that concretely wasn't a pointer"
    TagFreeNonPointer -> "`free` called on data that concretely wasn't a pointer"
    TagReadUninitializedStack -> "Read from uninitialized stack allocation"
    TagReadUninitializedHeap -> "Read from uninitialized heap allocation"
    TagCallNonFunctionPointer -> "Called a pointer that wasn't a function pointer"
    TagFloatToPointer -> "Treated float as pointer"

ppTruePositive :: TruePositive -> Text
ppTruePositive =
  \case
    pos@(ReadUninitializedStack loc) -> withLoc pos loc
    pos@(ReadUninitializedHeap loc) -> withLoc pos loc
    pos@(CallNonFunctionPointer loc) -> withLoc pos loc
    tp -> ppTruePositiveTag (truePositiveTag tp)
  where
    withLoc pos loc =
      ppTruePositiveTag (truePositiveTag pos) <> " allocated at " <> Text.pack loc

-- | All of the preconditions that we can deduce. We know how to detect and fix
-- these issues.
data DiagnosisTag
  = DiagnoseWriteBadAlignment
  | DiagnoseReadBadAlignment
  | DiagnoseFreeUnallocated
  | DiagnoseFreeBadOffset
  | DiagnoseWriteUnmapped
  | DiagnoseReadUninitialized
  | DiagnoseReadUninitializedOffset
  | DiagnosePointerConstOffset
  | DiagnoseMemsetTooSmall
  | DiagnoseAddSignedWrap
  | DiagnoseSubSignedWrap
  | DiagnoseNonZero
  deriving (Eq, Ord)

data Diagnosis = Diagnosis
  { diagnosisTag :: DiagnosisTag,
    diagnosisWhere :: Where
  }

diagnoseTag :: DiagnosisTag -> Text
diagnoseTag =
  \case
    DiagnoseWriteBadAlignment -> "Write to a pointer with insufficient alignment"
    DiagnoseReadBadAlignment -> "Read from a pointer with insufficient alignment"
    DiagnoseFreeUnallocated -> "`free` called on an unallocated pointer"
    DiagnoseFreeBadOffset -> "`free` called on pointer with nonzero offset"
    DiagnoseWriteUnmapped -> "Write to an unmapped pointer"
    DiagnoseReadUninitialized -> "Read from an uninitialized pointer"
    DiagnoseReadUninitializedOffset -> "Read from an uninitialized pointer calculated from a pointer"
    DiagnosePointerConstOffset -> "Addition of a constant offset to a pointer"
    DiagnoseMemsetTooSmall -> "`memset` called on pointer to too-small allocation"
    DiagnoseAddSignedWrap -> "Addition of a constant caused signed wrap of an int"
    DiagnoseSubSignedWrap -> "Subtraction of a constant caused signed wrap of an int"
    DiagnoseNonZero -> "Division or remainder by zero"

diagnose :: Diagnosis -> Text
diagnose (Diagnosis tag which) =
  diagnoseTag tag
    <> case which of
      Arg n -> "in argument #" <> Text.pack (show n)
      Global g -> "in global " <> Text.pack g
      ReturnValue f -> "in return value of skipped function " <> Text.pack f

prescribe :: DiagnosisTag -> Text
prescribe =
  ("Prescription: Add a precondition that " <>)
    . \case
      DiagnoseWriteBadAlignment -> "the pointer is sufficiently aligned."
      DiagnoseReadBadAlignment -> "the pointer is sufficiently aligned."
      DiagnoseFreeUnallocated -> "the pointer points to initialized memory."
      DiagnoseFreeBadOffset -> "the pointer points to initialized memory."
      DiagnoseWriteUnmapped -> "the pointer points to allocated memory."
      DiagnoseReadUninitialized -> "the pointer points to initialized memory."
      DiagnoseReadUninitializedOffset -> "the pointer points to initialized memory."
      DiagnosePointerConstOffset -> "the allocation is at least that size."
      DiagnoseMemsetTooSmall -> "the allocation is at least that size."
      DiagnoseAddSignedWrap -> "the integer is small enough"
      DiagnoseSubSignedWrap -> "the integer is large enough"
      DiagnoseNonZero -> "the integer is not zero"

-- | There was an error and we know roughly what sort it was, but we still can't
-- do anything about it, i.e., it\'s not clear what kind of precondition could
-- avoid the error.
data Unfixable
  = -- | The addition of an offset of a pointer such that the result points
    -- beyond (one past) the end of the allocation is undefined behavior -
    -- see the @PtrAddOffsetOutOfBounds@ constructor of @UndefinedBehavior@.
    -- If the offset that was added is symbolic and not part of an argument or
    -- global variable, it\'s not clear what kind of precondition could
    -- mitigate/avoid the error.
    AddSymbolicOffsetToInputPointer
  deriving (Eq, Ord, Show)

ppUnfixable :: Unfixable -> Text
ppUnfixable =
  \case
    AddSymbolicOffsetToInputPointer ->
      "Addition of a symbolic offset to pointer in argument, global variable, or return value of skipped function"

-- | We know how we *could* fix this in theory, but haven't implemented it yet.
data Unfixed
  = UnfixedArgPtrOffsetArg
  | UnfixedFunctionPtrInInput
  deriving (Eq, Ord, Show)

ppUnfixed :: Unfixed -> Text
ppUnfixed =
  \case
    UnfixedArgPtrOffsetArg -> "Addition of an offset from argument to a pointer in argument"
    UnfixedFunctionPtrInInput ->
      "Called function pointer in argument, global, or return value of skipped function"

-- | We don't (yet) know what to do about this error, so we can't continue
-- executing this function.
data Unclassified
  = UnclassifiedUndefinedBehavior (Doc Void) (Some UB.UndefinedBehavior)
  | UnclassifiedMemoryError (Doc Void)

doc :: Lens' Unclassified (Doc Void)
doc =
  lens
    ( \case
        UnclassifiedUndefinedBehavior doc' _ -> doc'
        UnclassifiedMemoryError doc' -> doc'
    )
    ( \s doc' ->
        case s of
          UnclassifiedUndefinedBehavior _ val ->
            UnclassifiedUndefinedBehavior doc' val
          UnclassifiedMemoryError _ ->
            UnclassifiedMemoryError doc'
    )

-- | Only used in tests, not a valid 'Show' instance.
instance Show Unclassified where
  show =
    \case
      UnclassifiedUndefinedBehavior {} -> "Undefined behavior"
      UnclassifiedMemoryError {} -> "Memory error"

-- | Possible sources of uncertainty, these might be true or false positives
data Uncertainty
  = UUnclassified Unclassified
  | UUnfixable Unfixable
  | UUnfixed Unfixed
  | -- | Simulation, input generation, or classification encountered
    -- unimplemented functionality
    UUnimplemented (Panic Unimplemented)
  | -- | This @Pred@ was not annotated
    UMissingAnnotation Crucible.SimError
  | -- | A user assertion failed, but symbolically
    UFailedAssert !What4.ProgramLoc
  | -- | Simulation timed out
    UTimeout !Text
  deriving (Show)

partitionUncertainty ::
  [Uncertainty] -> ([Crucible.SimError], [What4.ProgramLoc], [Panic Unimplemented], [Unclassified], [Unfixed], [Unfixable], [Text])
partitionUncertainty = go [] [] [] [] [] [] []
  where
    go ms fs ns us ufd ufa ts =
      \case
        [] -> (ms, fs, ns, us, ufd, ufa, ts)
        (UMissingAnnotation err : rest) ->
          let (ms', fs', ns', us', ufd', ufa', ts') = go ms fs ns us ufd ufa ts rest
           in (err : ms', fs', ns', us', ufd', ufa', ts')
        (UFailedAssert loc : rest) ->
          let (ms', fs', ns', us', ufd', ufa', ts') = go ms fs ns us ufd ufa ts rest
           in (ms', loc : fs', ns', us', ufd', ufa', ts')
        (UUnimplemented unin : rest) ->
          let (ms', fs', ns', us', ufd', ufa', ts') = go ms fs ns us ufd ufa ts rest
           in (ms', fs', unin : ns', us', ufd', ufa', ts')
        (UUnclassified unclass : rest) ->
          let (ms', fs', ns', us', ufd', ufa', ts') = go ms fs ns us ufd ufa ts rest
           in (ms', fs', ns', unclass : us', ufd', ufa', ts')
        (UUnfixed uf : rest) ->
          let (ms', fs', ns', us', ufd', ufa', ts') = go ms fs ns us ufd ufa ts rest
           in (ms', fs', ns', us', uf : ufd', ufa', ts')
        (UUnfixable uf : rest) ->
          let (ms', fs', ns', us', ufd', ufa', ts') = go ms fs ns us ufd ufa ts rest
           in (ms', fs', ns', us', ufd', uf : ufa', ts')
        (UTimeout fun : rest) ->
          let (ms', fs', ns', us', ufd', ufa', ts') = go ms fs ns us ufd ufa ts rest
           in (ms', fs', ns', us', ufd', ufa', fun : ts')

-- | An error is either a true positive, a false positive due to some missing
-- preconditions, or unknown.
--
-- NOTE(lb): The explicit kind signature here is necessary for GHC 8.8/8.6
-- compatibility.
data Explanation m arch (argTypes :: Ctx (FullType m))
  = ExTruePositive LocatedTruePositive
  | ExDiagnosis (Diagnosis, [NewConstraint m argTypes])
  | ExUncertain Uncertainty
  | -- | Hit recursion/loop bounds
    ExExhaustedBounds !String

partitionExplanations ::
  [Explanation m arch types] ->
  ([LocatedTruePositive], [(Diagnosis, [NewConstraint m types])], [Uncertainty], [String])
partitionExplanations = go [] [] [] []
  where
    go ts cs ds es =
      \case
        [] -> (ts, cs, ds, es)
        (ExTruePositive t : xs) ->
          let (ts', cs', ds', es') = go ts cs ds es xs
           in (t : ts', cs', ds', es')
        (ExDiagnosis c : xs) ->
          let (ts', cs', ds', es') = go ts cs ds es xs
           in (ts', c : cs', ds', es')
        (ExUncertain d : xs) ->
          let (ts', cs', ds', es') = go ts cs ds es xs
           in (ts', cs', d : ds', es')
        (ExExhaustedBounds e : xs) ->
          let (ts', cs', ds', es') = go ts cs ds es xs
           in (ts', cs', ds', e : es')

ppUncertainty :: Uncertainty -> Text
ppUncertainty =
  \case
    UUnclassified unclass ->
      "Unclassified error:\n"
        <> (unclass ^. doc . to (PP.layoutPretty PP.defaultLayoutOptions) . to PP.renderStrict)
    UUnfixable unfix -> "Unfixable/inactionable error:\n" <> ppUnfixable unfix
    UUnfixed unfix ->
      "Fixable, but fix not yet implemented for this error:\n" <> ppUnfixed unfix
    UMissingAnnotation err ->
      "(Internal issue) Missing annotation for error:\n" <> Text.pack (show err)
    UFailedAssert loc ->
      "Symbolically failing user assertion at " <> Text.pack (show loc)
    UUnimplemented pan -> Text.pack (displayException pan)
    UTimeout fun -> Text.pack "Simulation timed out while executing " <> fun
