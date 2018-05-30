-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.Simulator.SimError
-- Description      : Data structure the execution state of the simulator
-- Copyright        : (c) Galois, Inc 2014
-- License          : BSD3
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
------------------------------------------------------------------------
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
module Lang.Crucible.Simulator.SimError (
    SimErrorReason(..)
  , SimError(..)
  , simErrorReasonMsg
  , ppSimError
  ) where

import Control.Exception
import Data.String
import Data.Typeable
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import What4.ProgramLoc

------------------------------------------------------------------------
-- SimError

-- | Class for exceptions generated by simulator.
data SimErrorReason
   = GenericSimError !String
   | Unsupported !String -- ^ We can't do that (yet?)
   | ReadBeforeWriteSimError !String -- FIXME? include relevant data instead of a string?
   | AssertFailureSimError !String
 deriving (Typeable,Eq)

data SimError
   = SimError
   { simErrorLoc :: !ProgramLoc
   , simErrorReason :: !SimErrorReason
   }
 deriving (Typeable,Eq)

simErrorReasonMsg :: SimErrorReason -> String
simErrorReasonMsg (GenericSimError msg) = msg
simErrorReasonMsg (Unsupported msg) = "Unsupported feature: " ++ msg
simErrorReasonMsg (ReadBeforeWriteSimError msg) = msg
simErrorReasonMsg (AssertFailureSimError msg) = msg

instance IsString SimErrorReason where
  fromString = GenericSimError

instance Show SimErrorReason where
  show = simErrorReasonMsg

instance Show SimError where
  show = show . ppSimError

ppSimError :: SimError -> Doc
ppSimError er =
  vcat [ vcat (text <$> lines (show (simErrorReason er)))
       , text "in" <+> text (show (plFunction loc)) <+> text "at" <+> text (show (plSourceLoc loc))
       ]
 where loc = simErrorLoc er

instance Exception SimError
