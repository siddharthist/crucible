-- |
-- Module           : Lang.Crucible.LLVM.Safety.UndefinedBehavior
-- Description      : All about undefined behavior
-- Copyright        : (c) Galois, Inc 2018
-- License          : BSD3
-- Maintainer       : Langston Barrett <lbarrett@galois.com>
-- Stability        : provisional
--
-- This module is intended to be imported qualified.
--
-- This module serves as an ad-hoc reference for the sort of undefined behaviors
-- that the Crucible LLVM memory model is aware of. The information contained
-- here is used in
--  * providing helpful error messages
--  * configuring which safety checks to perform
--
-- Disabling checks for undefined behavior does not change the behavior of any
-- memory operations. If it is used to enable the simulation of undefined
-- behavior, the result is that any guarantees that Crucible provides about the
-- code essentially have an additional hypothesis: that the LLVM
-- compiler/hardware platform behave identically to Crucible's simulator when
-- encountering such behavior.
--------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}

module Lang.Crucible.LLVM.Extension.Safety.UndefinedBehavior
  (
  -- ** Undefined Behavior
    PtrComparisonOperator(..)
  , UndefinedBehavior(..)
  , cite
  , ppReg
  -- , ppExpr

  -- ** Pointers
  , PointerPair
  , pointerView

  -- ** Config
  , Config
  , getConfig
  , strictConfig
  , laxConfig
  , defaultStrict
  ) where

import           Prelude

import           GHC.Generics (Generic)
import           Data.Data (Data)
import           Data.Kind (Type)
import           Data.Functor.Contravariant (Predicate(..))
import           Data.Maybe (fromMaybe, isJust)
import           Data.Typeable (Typeable)
import           Data.Text (unpack)
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import qualified Data.Parameterized.TraversableF as TF
import           Data.Parameterized.TraversableF (FunctorF(..), FoldableF(..), TraversableF(..))
import qualified Data.Parameterized.TH.GADT as U
import           Data.Parameterized.ClassesC (TestEqualityC(..), OrdC(..))
import           Data.Parameterized.Classes (toOrdering, OrderingF(..))

import qualified What4.Interface as W4I

import           Lang.Crucible.Types
import           Lang.Crucible.Simulator.RegValue (RegValue'(..))
import           Lang.Crucible.LLVM.DataLayout (Alignment)
import           Lang.Crucible.LLVM.MemModel.Pointer (llvmPointerView)
import           Lang.Crucible.LLVM.MemModel.Type (StorageTypeF(..))
import           Lang.Crucible.LLVM.Extension.Safety.Standards
import           Lang.Crucible.LLVM.Types (LLVMPtr)

-- -----------------------------------------------------------------------
-- ** UndefinedBehavior

-- | The various comparison operators you can use on pointers
data PtrComparisonOperator =
    Eq
  | Leq
  deriving (Data, Eq, Generic, Enum, Ord, Read, Show)

ppPtrComparison :: PtrComparisonOperator -> Doc
ppPtrComparison Eq  = text "Equality comparison (==)"
ppPtrComparison Leq = text "Ordering comparison (<=)"

-- | We can't use LLVMPtr, because one of those can't be constructed at
-- translation time, whereas we don't want 'UndefinedBehavior' to be a GADT
-- (beyond some existential quantification of bitvector widths).
type PointerPair e w = (e NatType, e (BVType w))

-- | TODO: duplication with ppPtr
ppPointerPair :: W4I.IsExpr (W4I.SymExpr sym) => PointerPair (RegValue' sym) w -> Doc
ppPointerPair (RV blk, RV bv)
  | Just 0 <- W4I.asNat blk = W4I.printSymExpr bv
  | otherwise =
     let blk_doc = W4I.printSymExpr blk
         off_doc = W4I.printSymExpr bv
      in text "(" <> blk_doc <> text "," <+> off_doc <> text ")"

pointerView :: LLVMPtr sym w -> (RegValue' sym NatType, RegValue' sym (BVType w))
pointerView ptr = let (blk, off) = llvmPointerView ptr in (RV blk, RV off)

-- | This type is parameterized on a higher-kinded term constructor so that it
-- can be instantiated for expressions at translation time (i.e. the 'Expr' in
-- 'LLVMGenerator'), or for expressions at runtime ('SymExpr').
--
-- See 'cite' and 'explain' for what each constructor means at the C/LLVM level.
--
-- The commented-out constructors correspond to behaviors that don't have
-- explicit checks yet (but probably should!).
data UndefinedBehavior (e :: CrucibleType -> Type) where

  -- -------------------------------- Memory management

  FreeBadOffset :: PointerPair e w
                -> UndefinedBehavior e

  FreeUnallocated :: PointerPair e w
                  -> UndefinedBehavior e

  MemsetInvalidRegion :: PointerPair e w   -- ^ Destination
                      -> e (BVType 8) -- ^ Fill byte
                      -> e (BVType v) -- ^ Length
                      -> UndefinedBehavior e

  -- | Is this actually undefined? I (Langston) can't find anything about it
  ReadBadAlignment :: PointerPair e w     -- ^ Read from where?
                   -> Alignment           -- ^ What alignment?
                   -> UndefinedBehavior e

  ReadUnallocated :: PointerPair e w     -- ^ Read from where?
                  -> UndefinedBehavior e

  -- -------------------------------- Pointer arithmetic

  PtrAddOffsetOutOfBounds :: PointerPair e w   -- ^ The pointer
                          -> e (BVType w)      -- ^ Offset added
                          -> UndefinedBehavior e

  CompareInvalidPointer :: PtrComparisonOperator -- ^ Kind of comparison
                        -> PointerPair e w       -- ^ The invalid pointer
                        -> PointerPair e w       -- ^ The pointer it was compared to
                        -> UndefinedBehavior e

  -- | "In all other cases, the behavior is undefined"
  -- TODO: 'PtrComparisonOperator' argument?
  CompareDifferentAllocs :: PointerPair e w
                         -> PointerPair e w
                         -> UndefinedBehavior e

  -- | "When two pointers are subtracted, both shall point to elements of the
  -- same array object"
  PtrSubDifferentAllocs :: PointerPair e w
                        -> PointerPair e w
                        -> UndefinedBehavior e

  PointerCast :: e NatType       -- ^ Pointer's allocation number
              -> e (BVType w)    -- ^ Offset
              -> StorageTypeF () -- ^ Type being cast to
              -> UndefinedBehavior e

  -- | "One of the following shall hold: [...] one operand is a pointer and the
  -- other is a null pointer constant."
  ComparePointerToBV :: e (BVType w) -- ^ Pointer
                     -> e (BVType w) -- ^ Bitvector
                     -> UndefinedBehavior e

  -------------------------------- LLVM: arithmetic

  -- | @SymBV@ or @Expr _ _ (BVType w)@
  UDivByZero   :: e (BVType w) -> UndefinedBehavior e
  SDivByZero   :: e (BVType w) -> UndefinedBehavior e
  URemByZero   :: e (BVType w) -> UndefinedBehavior e
  SRemByZero   :: e (BVType w) -> UndefinedBehavior e
  SDivOverflow :: e (BVType w)
               -> e (BVType w)
               -> UndefinedBehavior e
  SRemOverflow :: e (BVType w)
               -> e (BVType w)
               -> UndefinedBehavior e

  {-
  MemcpyDisjoint          :: UndefinedBehavior e
  DoubleFree              :: UndefinedBehavior e
  DereferenceBadAlignment :: UndefinedBehavior e
  ModifiedStringLiteral   :: UndefinedBehavior e
  -}
  deriving (Typeable)

-- | Which document prohibits this behavior?
standard :: UndefinedBehavior e -> Standard
standard =
  \case

    -- -------------------------------- Memory management

    FreeBadOffset _           -> CStd C99
    FreeUnallocated _         -> CStd C99
    MemsetInvalidRegion _ _ _ -> CXXStd CXX17
    ReadBadAlignment _ _      -> CStd C99
    ReadUnallocated _         -> CStd C99

    -- -------------------------------- Pointer arithmetic

    PtrAddOffsetOutOfBounds _ _ -> CStd C99
    CompareInvalidPointer _ _ _ -> CStd C99
    CompareDifferentAllocs _ _  -> CStd C99
    PtrSubDifferentAllocs _ _   -> CStd C99
    ComparePointerToBV _ _      -> CStd C99
    PointerCast _ _ _           -> CStd C99

    -- -------------------------------- LLVM: arithmetic

    UDivByZero _     -> LLVMRef LLVM8
    SDivByZero _     -> LLVMRef LLVM8
    URemByZero _     -> LLVMRef LLVM8
    SRemByZero _     -> LLVMRef LLVM8
    SDivOverflow _ _ -> LLVMRef LLVM8
    SRemOverflow _ _ -> LLVMRef LLVM8

    {-
    MemcpyDisjoint          -> CStd C99
    DoubleFree              -> CStd C99
    DereferenceBadAlignment -> CStd C99
    ModifiedStringLiteral   -> CStd C99
    -}

-- | Which section(s) of the document prohibit this behavior?
cite :: UndefinedBehavior e -> Doc
cite = text .
  \case

    -------------------------------- Memory management

    FreeBadOffset _           -> "§7.22.3.3 The free function, ¶2"
    FreeUnallocated _         -> "§7.22.3.3 The free function, ¶2"
    MemsetInvalidRegion _ _ _ -> "https://en.cppreference.com/w/cpp/string/byte/memset"
    ReadBadAlignment _ _      -> "§6.2.8 Alignment of objects, ¶?"
    ReadUnallocated _         -> "§6.2.4 Storage durations of objects, ¶2"

    -- -------------------------------- Pointer arithmetic

    PtrAddOffsetOutOfBounds _ _ -> "§6.5.6 Additive operators, ¶8"
    CompareInvalidPointer _ _ _ -> "§6.5.8 Relational operators, ¶5"
    CompareDifferentAllocs _ _  -> "§6.5.8 Relational operators, ¶5"
    PtrSubDifferentAllocs _ _   -> "§6.5.6 Additive operators, ¶9"
    ComparePointerToBV _ _      -> "§6.5.9 Equality operators, ¶2"
    PointerCast _ _ _           -> "TODO"

    -------------------------------- LLVM: arithmetic

    UDivByZero _     -> "‘udiv’ Instruction (Semantics)"
    SDivByZero _     -> "‘sdiv’ Instruction (Semantics)"
    URemByZero _     -> "‘urem’ Instruction (Semantics)"
    SRemByZero _     -> "‘srem’ Instruction (Semantics)"
    SDivOverflow _ _ -> "‘sdiv’ Instruction (Semantics)"
    SRemOverflow _ _ -> "‘srem’ Instruction (Semantics)"

    {-
    MemcpyDisjoint          -> "§7.24.2.1 The memcpy function"
    DoubleFree              -> "§7.22.3.3 The free function"
    DereferenceBadAlignment -> "§6.5.3.2 Address and indirection operators"
    ModifiedStringLiteral   -> "§J.2 Undefined behavior"
    -}

-- | What happened, and why is it a problem?
--
-- This is a generic explanation that doesn't use the included data.
explain :: UndefinedBehavior e -> Doc
explain =
  \case

    -- -------------------------------- Memory management

    FreeBadOffset _ -> cat $
      [ "`free` called on pointer that was not previously returned by `malloc`"
      , "`calloc`, or another memory management function (the pointer did not"
      , "point to the base of an allocation, its offset should be 0)."
      ]
    FreeUnallocated _ ->
      "`free` called on pointer that didn't point to a live region of the heap."
    MemsetInvalidRegion _ _ _ -> cat $
      [ "Pointer passed to `memset` didn't point to a mutable allocation with"
      , "enough space."
      ]
    ReadBadAlignment _ _ ->
      "Read a value from a pointer with incorrect alignment"
    ReadUnallocated _ ->
      "Read a value from a pointer into an unallocated region"

    -- -------------------------------- Pointer arithmetic

    PtrAddOffsetOutOfBounds _ _ -> cat $
      [ "Addition of an offset to a pointer resulted in a pointer to an"
      , "address outside of the allocation."
      ]
    CompareInvalidPointer _ _ _ -> cat $
      [ "Comparison of a pointer which wasn't null or a pointer to a live heap"
      , "object."
      ]
    CompareDifferentAllocs _ _ ->
      "Comparison of pointers from different allocations"
    PtrSubDifferentAllocs _ _ ->
      "Subtraction of pointers from different allocations"
    ComparePointerToBV _ _ ->
      "Comparison of a pointer to a non zero (null) integer value"
    PointerCast _ _ _   ->
      "Cast of a pointer to a non-integer type"

    -------------------------------- LLVM: arithmetic

    UDivByZero _     -> "Unsigned division by zero"
    SDivByZero _     -> "Signed division by zero"
    URemByZero _     -> "Unsigned division by zero via remainder"
    SRemByZero _     -> "Signed division by zero via remainder"
    SDivOverflow _ _ -> "Overflow during signed division"
    SRemOverflow _ _ -> "Overflow during signed division (via signed remainder)"

    {-
    MemcpyDisjoint     -> "Use of `memcpy` with non-disjoint regions of memory"
    DoubleFree         -> "`free` called on already-freed memory"
    DereferenceBadAlignment ->
      "Dereferenced a pointer to a type with the wrong alignment"
    ModifiedStringLiteral -> "Modified the underlying array of a string literal"
    -}

-- | Pretty-print the additional information held by the constructors
-- (for symbolic expressions)
detailsReg :: W4I.IsExpr (W4I.SymExpr sym)
           => proxy sym
           -- ^ Not really used, prevents ambiguous types. Can use "Data.Proxy".
           -> UndefinedBehavior (RegValue' sym)
           -> [Doc]
detailsReg proxySym =
  \case

    -------------------------------- Memory management

    FreeBadOffset ptr   -> [ "Pointer:" <+> ppPointerPair ptr ]
    FreeUnallocated ptr -> [ "Pointer:" <+> ppPointerPair ptr ]
    MemsetInvalidRegion destPtr fillByte len ->
      [ "Destination pointer:" <+> ppPointerPair destPtr
      , "Fill byte:          " <+> (W4I.printSymExpr $ unRV fillByte)
      , "Length:             " <+> (W4I.printSymExpr $ unRV len)
      ]
    ReadBadAlignment ptr alignment ->
      [ "Alignment: " <+> text (show alignment)
      , ppPtr1 ptr
      ]
    ReadUnallocated ptr -> [ ppPtr1 ptr ]

    -------------------------------- Pointer arithmetic

    PtrAddOffsetOutOfBounds ptr offset ->
      [ ppPtr1 ptr
      , ppOffset proxySym (unRV offset)
      ]
    CompareInvalidPointer comparison invalid other ->
      [ "Comparison:                    " <+> ppPtrComparison comparison
      , "Invalid pointer:               " <+> ppPointerPair invalid
      , "Other (possibly valid) pointer:" <+> ppPointerPair other
      ]
    CompareDifferentAllocs ptr1 ptr2 -> [ ppPtr2 ptr1 ptr2 ]
    PtrSubDifferentAllocs ptr1 ptr2  -> [ ppPtr2 ptr1 ptr2 ]
    ComparePointerToBV ptr bv ->
      [ "Pointer:  " <+> (W4I.printSymExpr $ unRV ptr)
      , "Bitvector:" <+> (W4I.printSymExpr $ unRV bv)
      ]
    PointerCast allocNum offset castToType ->
      [ "Allocation number:" <+> (W4I.printSymExpr $ unRV allocNum)
      , "Offset:           " <+> (W4I.printSymExpr $ unRV offset)
      , "Cast to:          " <+> text (show castToType)
      ]

    -------------------------------- LLVM: arithmetic

    -- The cases are manually listed to prevent unintentional fallthrough if a
    -- constructor is added.
    UDivByZero v       -> [ "op1: " <+> (W4I.printSymExpr $ unRV v) ]
    SDivByZero v       -> [ "op1: " <+> (W4I.printSymExpr $ unRV v) ]
    URemByZero v       -> [ "op1: " <+> (W4I.printSymExpr $ unRV v) ]
    SRemByZero v       -> [ "op1: " <+> (W4I.printSymExpr $ unRV v) ]
    SDivOverflow v1 v2 -> [ "op1: " <+> (W4I.printSymExpr $ unRV v1)
                          , "op2: " <+> (W4I.printSymExpr $ unRV v2)
                          ]
    SRemOverflow v1 v2 -> [ "op1: " <+> (W4I.printSymExpr $ unRV v1)
                          , "op2: " <+> (W4I.printSymExpr $ unRV v2)
                          ]

  where ppPtr1 :: W4I.IsExpr (W4I.SymExpr sym) => PointerPair (RegValue' sym) w -> Doc
        ppPtr1 = ("Pointer:" <+>) . ppPointerPair

        ppPtr2 ptr1 ptr2 = vcat [ "Pointer 1:" <+>  ppPointerPair ptr1
                                , "Pointer 2:" <+>  ppPointerPair ptr2
                                ]

        ppOffset :: W4I.IsExpr (W4I.SymExpr sym)
                 => proxy sym -> W4I.SymExpr sym (BaseBVType w) -> Doc
        ppOffset _ = ("Offset:" <+>) . W4I.printSymExpr

pp :: (UndefinedBehavior e -> [Doc]) -- ^ Printer for constructor data
   -> UndefinedBehavior e
   -> Doc
pp extra ub = vcat $
  "Undefined behavior encountered: "
  : explain ub
  : extra ub
  ++ cat [ "Reference: "
         , text (unpack (ppStd (standard ub)))
         , cite ub
         ]
     : case stdURL (standard ub) of
         Just url -> ["Document URL:" <+> text (unpack url)]
         Nothing  -> []

-- | Pretty-printer for symbolic backends
ppReg :: W4I.IsExpr (W4I.SymExpr sym)
      => proxy sym
      -- ^ Not really used, prevents ambiguous types. Can use "Data.Proxy".
      -> UndefinedBehavior (RegValue' sym)
      -> Doc
ppReg proxySym = pp (detailsReg proxySym)

-- -- | General-purpose pretty-printer
-- ppExpr :: W4I.IsExpr e
--        => UndefinedBehavior e
--        -> Doc
-- ppExpr = pp detailsExpr

-- -----------------------------------------------------------------------
-- ** Config

-- | 'Config' has a monoid instance which takes the piecewise logical and of its
-- arguments
type Config e = Predicate (UndefinedBehavior e)

-- | Apply a 'Config' as a predicate
getConfig :: Config e -> UndefinedBehavior e -> Bool
getConfig = getPredicate
{-# INLINE getConfig #-}

-- | Disallow all undefined behavior.
strictConfig :: Config e
strictConfig = Predicate $ const True
{-# INLINE strictConfig #-}

-- | Allow all undefined behavior.
laxConfig :: Config e
laxConfig = Predicate $ const False
{-# INLINE laxConfig #-}

-- | For use in ViewPatterns.
defaultStrict :: Maybe (Config e) -> Config e
defaultStrict = fromMaybe strictConfig

-- -----------------------------------------------------------------------
-- ** Instances

$(return [])

instance TestEqualityC UndefinedBehavior where
  testEqualityC subterms x y = isJust $
    $(U.structuralTypeEquality [t|UndefinedBehavior|]
       [ ( U.DataArg 0 `U.TypeApp` U.AnyType
         , [| subterms |]
         )
       , ( U.ConType [t|PointerPair|] `U.TypeApp` U.AnyType `U.TypeApp` U.AnyType
         , [| \(b1, o1) (b2, o2) -> subterms o1 o2 >> subterms b1 b2 |]
         )
       ]
     ) x y

instance OrdC UndefinedBehavior where
  compareC subterms ub1 ub2 = toOrdering $
    $(U.structuralTypeOrd [t|UndefinedBehavior|]
       [ ( U.DataArg 0 `U.TypeApp` U.AnyType
         , [| subterms |]
         )
       , ( U.ConType [t|PointerPair|] `U.TypeApp` U.AnyType `U.TypeApp` U.AnyType
         , [| \(b1, o1) (b2, o2) ->
               -- This looks pretty strange, but we can't use the EQF from the
               -- second comparison because of the existentially-quantified width
               case subterms b1 b2 of
                 GTF -> GTF
                 LTF -> LTF
                 e@EQF ->
                  case subterms o1 o2 of
                    GTF -> (GTF :: OrderingF NatType NatType)
                    LTF -> (GTF :: OrderingF NatType NatType)
                    EQF -> e
           |]
         )
       ]
     ) ub1 ub2

instance FunctorF UndefinedBehavior where
  fmapF = TF.fmapFDefault

instance FoldableF UndefinedBehavior where
  foldMapF = TF.foldMapFDefault

instance TraversableF UndefinedBehavior where
  traverseF subterms =
    $(U.structuralTraversal [t|UndefinedBehavior|]
       [ ( U.DataArg 0 `U.TypeApp` U.AnyType
         , [| \_ x -> subterms x |]
         )
       , ( U.ConType [t|PointerPair|] `U.TypeApp` U.AnyType `U.TypeApp` U.AnyType
         , [| \_ (b, o) -> (,) <$> subterms b <*> subterms o |]
         )
       ]
     ) subterms
