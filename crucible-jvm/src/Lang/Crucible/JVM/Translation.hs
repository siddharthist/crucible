{- |
Module           : Lang.Crucible.JVM.Translation
Description      : Translation of JVM AST into Crucible control-flow graph
Copyright        : (c) Galois, Inc 2018
License          : BSD3
Maintainer       : huffman@galois.com, sweirich@galois.com
Stability        : provisional
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE PolyKinds #-}

{-# OPTIONS_GHC -haddock #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Lang.Crucible.JVM.Translation
  (
    module Lang.Crucible.JVM.Types
  , module Lang.Crucible.JVM.Generator
  , module Lang.Crucible.JVM.Class
  , module Lang.Crucible.JVM.Overrides
  , module Lang.Crucible.JVM.Translation
  )
  where

-- base
import Data.Maybe (maybeToList)
import Data.Semigroup(Semigroup(..),(<>))
import Control.Monad.State.Strict 
import Control.Monad.ST  
import Control.Lens hiding (op, (:>))
import Data.Int (Int32)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.String (fromString)
import Data.List (isPrefixOf)

import System.IO

-- jvm-parser
import qualified Language.JVM.Common as J
import qualified Language.JVM.Parser as J
import qualified Language.JVM.CFG as J

-- parameterized-utils
import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Some
import           Data.Parameterized.NatRepr as NR
import qualified Data.Parameterized.Map as MapF


-- crucible
import qualified Lang.Crucible.CFG.Core as C
import           Lang.Crucible.CFG.Expr
import           Lang.Crucible.CFG.Generator
import           Lang.Crucible.CFG.SSAConversion (toSSA)
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.Types
import           Lang.Crucible.Backend
import           Lang.Crucible.Panic

import           Lang.Crucible.Utils.MonadVerbosity

import qualified Lang.Crucible.Simulator               as C
import qualified Lang.Crucible.Simulator.GlobalState   as C
import qualified Lang.Crucible.Analysis.Postdom        as C


-- what4
import           What4.ProgramLoc (Position(InternalPos))
import           What4.FunctionName 
import qualified What4.Interface                       as W4
import qualified What4.InterpretedFloatingPoint        as W4
import qualified What4.Config                          as W4

import           What4.Utils.MonadST (liftST)

-- crucible-jvm
import           Lang.Crucible.JVM.Types
import           Lang.Crucible.JVM.ClassRefs
import           Lang.Crucible.JVM.Generator
import           Lang.Crucible.JVM.Class
import           Lang.Crucible.JVM.Overrides

import qualified Lang.JVM.Codebase as JCB


import Debug.Trace

--------------------------------------------------------------------------------

-- * Special treatment of the Java standard library

{- Overall, the system doesn't take a very principled approach to classes from 
   Java's standard library that are referred to in the test cases.

   The basic idea is that when we similate a Java method call, we first crawl
   over the enclosing class and declare its static vars and dynamic methods
   to the simulator. Because those classes could depend on others, we
   do this step transitively, declaring any class that could be needed.

   However, some of the classes that are implemented via native methods cannot
   be parsed by the jvm-parser code. So, those classes cannot be traversed to
   look for transitive mentions of other classes.

   In that case, we need to define a set of "initClasses", i.e. or
   baseline primitives. These classes we declare only, but we make no
   guarantees that the classes that they refer to will also be
   available. Most of the time, we will implement the functionality
   from these classes via static or dynamic overrides. 

-}


-- | Classes that are always loaded into the initial
-- environment. These classes rely on native code that cannot be
-- parsed by jvm-parser. So instead of transitively loading these
-- classes with the Main class, we always load them but load none of
-- their dependencies. (There has to be a better way to do this,
-- perhaps by declaring classes more lazily, during simulation instead
-- of requiring that everything be available ahead of time.)
initClasses :: [String]
initClasses = [ "java/lang/System",
                "java/lang/Object",
                "java/lang/String",
                "java/lang/Integer",
                "java/lang/Short",
                "java/lang/Byte",
                "java/lang/Long",
                "java/lang/Boolean",
                "java/lang/Character",
                "java/lang/Float",
                "java/lang/Double",
                "java/lang/Math",
                "java/lang/Number",
                "java/lang/Void",
                "sun/misc/FloatingDecimal",
                
                "java/io/PrintStream",
                "java/io/FileOutputStream",
                "java/io/OutputStream",
                "java/io/ObjectStreamField",
                "java/io/FilterOutputStream",
                "java/io/File",
                "java/io/IOException",
                "java/io/DefaultFileSystem",

                "java/lang/StringBuffer",
                "java/lang/AbstractStringBuilder",
                "java/lang/StringBuilder",

                "java/lang/Class",

                "java/lang/Throwable",
                "java/lang/NullPointerException",
                "java/lang/RuntimeException",
                "java/lang/Exception",
                "java/lang/InternalError",
                "java/lang/StringIndexOutOfBoundsException",
                "java/lang/VirtualMachineError",
                "java/lang/Error",
                "java/lang/IndexOutOfBoundsException",

                "java/lang/Thread",
                "java/lang/Runtime"
                
              ]

-- | Class references that we shouldn't include in the transitive closure
--   of class references. 
exclude :: J.ClassName -> Bool
exclude cn = (J.unClassName cn) `elem` initClasses
          || ("["          `isPrefixOf` J.unClassName cn)
          || ("java/nio/" `isPrefixOf` J.unClassName cn)
          || ("java/awt/" `isPrefixOf` J.unClassName cn)
          || ("java/io/" `isPrefixOf` J.unClassName cn)
          || ("java/time/" `isPrefixOf` J.unClassName cn)
          || ("sun/"       `isPrefixOf` J.unClassName cn)
          || ("java/security/" `isPrefixOf` J.unClassName cn)
          || ("java/text/"     `isPrefixOf` J.unClassName cn)
          || ("java/lang/reflect/"     `isPrefixOf` J.unClassName cn)
          || ("java/lang/ref/" `isPrefixOf` J.unClassName cn)
          || ("java/net/"    `isPrefixOf` J.unClassName cn)
          || ("java/lang/System"    `isPrefixOf` J.unClassName cn)
          || ("java/lang/Thread"    `isPrefixOf` J.unClassName cn)
          || ("java/lang/CharSequence"    `isPrefixOf` J.unClassName cn)
          || ("java/lang/ClassLoader"    `isPrefixOf` J.unClassName cn)
          || ("java/lang/Character"    `isPrefixOf` J.unClassName cn)
          || ("java/lang/ConditionalSpecialCasing"  `isPrefixOf` J.unClassName cn)
          || cn `elem`
           [   J.mkClassName "java/lang/Object"
             , J.mkClassName "java/lang/String"
             , J.mkClassName "java/lang/Class"
             , J.mkClassName "java/lang/Package"
             , J.mkClassName "java/lang/SecurityManager"
             , J.mkClassName "java/lang/Shutdown"
             , J.mkClassName "java/lang/Process"
             , J.mkClassName "java/util/Arrays"
             , J.mkClassName "java/lang/RuntimePermission"
             , J.mkClassName "java/lang/StackTraceElement"
             , J.mkClassName "java/lang/ProcessEnvironment"
             , J.mkClassName "java/lang/ProcessBuilder"
             , J.mkClassName "java/lang/Thread"
             , J.mkClassName "java/lang/ThreadLocal"
             , J.mkClassName "java/lang/ApplicationShutdownHooks"
             , J.mkClassName "java/lang/invoke/SerializedLambda"
             , J.mkClassName "java/lang/System$2"
           ]

----------------------------------------------------------------------------------------------
-- * Static Overrides

{- Implementation of native methods from the Java library -}

-- | For static primitives, there is no need to create an override handle
--   we can just dispatch to our code in the interpreter automatically

staticOverrides :: J.ClassName -> J.MethodKey -> Maybe (JVMStmtGen h s ret ())
staticOverrides className methodKey
  | className == "java/lang/System" && J.methodKeyName methodKey == "arraycopy"
  = Just $ do len     <- iPop
              destPos <- iPop
              dest    <- rPop
              srcPos  <- iPop
              src     <- rPop

              rawSrcRef <- throwIfRefNull src
              srcObj  <- lift $ readRef rawSrcRef

              rawDestRef <- throwIfRefNull dest

              -- i = srcPos;
              iReg <- lift $ newReg srcPos

              let end = srcPos + len

              lift $ while (InternalPos, do
                        j <- readReg iReg
                        return $ App $ BVSlt w32 j end)

                    (InternalPos, do
                        j <- readReg iReg

                        --- val = src[i+srcPos]
                        val <- arrayIdx srcObj j

                        -- dest[i+destPos] = val
                        destObj  <- readRef rawDestRef
                        newDestObj <- arrayUpdate destObj (destPos + j) val
                        writeRef rawDestRef newDestObj
                        -- i++;
                        modifyReg iReg (1 +)
                        )
  | className == "java/lang/System" && J.methodKeyName methodKey == "exit"
  = Just $ do _status <- iPop
              -- TODO: figure out how to exit the simulator
              -- let codeStr = "unknown exit code"
              -- _ <- lift $ returnFromFunction (App EmptyApp)
              -- (App $ TextLit (fromString $ "java.lang.System.exit(int status) called with " ++ codeStr))
              return ()
      
  --
  -- Do nothing for registering native state
  --
  | J.methodKeyName methodKey == "registerNatives"
    && className `elem` ["java/lang/System",
                         "java/lang/ClassLoader",
                         "java/lang/Thread",
                         "java/lang/Class"]
  = Just $ return ()

  | className == "java/lang/Arrays" && J.methodKeyName methodKey == "copyOfRange"
  = Nothing

  | className == "java/lang/String" && J.methodKeyName methodKey == "<init>"
  = case (J.methodKeyParameterTypes methodKey) of
         [] -> Just $ return ()
         [J.ArrayType J.CharType, J.IntType, J.IntType] -> Just $ do
           traceM "TODO: 3 arg string constructor unimplemented"
           _count  <- iPop
           _offset <- iPop
           _arrRef <- rPop
           _obj    <- rPop

           -- how do we get access to "this" ??
           return ()
         _ -> Nothing
{-      
  | className == "java/lang/String" && J.methodKeyName methodKey == "<init>"
  = 
     Just $ do return ()
-}

  | className == "java/lang/Object" && J.methodKeyName methodKey == "hashCode"
  =  Just $ do
        -- TODO: hashCode always returns 0, can we make it be an "abstract" int?
        iPush (App $ BVLit knownRepr 0)

  | className == "java/lang/Class" &&
    J.methodKeyName methodKey == "getPrimitiveClass"
  =  Just $
        do _arg <- rPop
           -- TODO: java reflection
           rPush rNull

  -- valueOf methods
  | [ argTy ] <- J.methodKeyParameterTypes methodKey,
    J.methodKeyName methodKey == "valueOf"
    && (className, argTy) `elem`
    [ ("java/lang/Boolean", J.BooleanType)
    , ("java/lang/Byte", J.ByteType)
    , ("java/lang/Short", J.ShortType)
    , ("java/lang/Integer", J.IntType)
    , ("java/lang/Long", J.LongType)
    ]    
  = Just $ do
      val <- popValue
      ref <- lift $ do
        initializeClass className
        clsObj <- getJVMClassByName className
        cls    <- lookupClassGen className
        obj    <- newInstanceInstr clsObj (J.classFields cls)
        obj1   <- setInstanceFieldValue obj
                  (J.FieldId className "value" argTy)
                  val
        rawRef <- newRef obj1
        return $ App (JustValue knownRepr rawRef)
        
      rPush ref

  | otherwise = Nothing
        


  

----------------------------------------------------------------------
-- * JVMRef

rNull :: JVMRef s
rNull = App (NothingValue knownRepr)

rIsNull :: JVMRef s -> JVMGenerator h s ret (JVMBool s)
rIsNull mr =
  caseMaybe mr knownRepr
  MatchMaybe {
    onNothing = return bTrue,
    onJust = \_ -> return bFalse
    }

rEqual :: JVMRef s -> JVMRef s -> JVMGenerator h s ret (JVMBool s)
rEqual mr1 mr2 =
  caseMaybe mr1 knownRepr
  MatchMaybe {
    onNothing = rIsNull mr2,
    onJust = \r1 ->
    caseMaybe mr2 knownRepr
    MatchMaybe {
      onNothing = return bFalse,
      onJust = \r2 -> return (App (ReferenceEq knownRepr r1 r2))
      }
    }

------------------------------------------------------------------------
-- * Registers and stack values

newJVMReg :: JVMValue s -> JVMGenerator h s ret (JVMReg s)
newJVMReg val =
  case val of
    DValue v -> DReg <$> newReg v
    FValue v -> FReg <$> newReg v
    IValue v -> IReg <$> newReg v
    LValue v -> LReg <$> newReg v
    RValue v -> RReg <$> newReg v

readJVMReg :: JVMReg s -> JVMGenerator h s ret (JVMValue s)
readJVMReg reg =
  case reg of
    DReg r -> DValue <$> readReg r
    FReg r -> FValue <$> readReg r
    IReg r -> IValue <$> readReg r
    LReg r -> LValue <$> readReg r
    RReg r -> RValue <$> readReg r

writeJVMReg :: JVMReg s -> JVMValue s -> JVMGenerator h s ret ()
writeJVMReg (DReg r) (DValue v) = assignReg r v
writeJVMReg (FReg r) (FValue v) = assignReg r v
writeJVMReg (IReg r) (IValue v) = assignReg r v
writeJVMReg (LReg r) (LValue v) = assignReg r v
writeJVMReg (RReg r) (RValue v) = assignReg r v
writeJVMReg _ _ = jvmFail "writeJVMReg"

saveStack :: [JVMReg s] -> [JVMValue s] -> JVMGenerator h s ret ()
saveStack [] [] = return ()
saveStack (r : rs) (v : vs) = writeJVMReg r v >> saveStack rs vs
saveStack _ _ = jvmFail "saveStack"


-- TODO: what if we have more values? is it ok to not save them all?
-- See Java/lang/String/compareTo
saveLocals ::
  Map J.LocalVariableIndex (JVMReg s) ->
  Map J.LocalVariableIndex (JVMValue s) ->
  JVMGenerator h s ret ()
saveLocals rs vs
  | Set.fromAscList (Map.keys rs) `Set.isSubsetOf`
    Set.fromAscList (Map.keys vs) = sequence_ (Map.intersectionWith writeJVMReg rs vs)
  | otherwise                  = jvmFail $ "saveLocals:\n\t" ++ show rs ++ "\n\t" ++ show vs

newRegisters :: JVMExprFrame s -> JVMGenerator h s ret (JVMRegisters s)
newRegisters = traverse newJVMReg

readRegisters :: JVMRegisters s -> JVMGenerator h s ret (JVMExprFrame s)
readRegisters = traverse readJVMReg

writeRegisters :: JVMRegisters s -> JVMExprFrame s -> JVMGenerator h s ret ()
writeRegisters rs vs =
  do saveStack (rs^.operandStack) (vs^.operandStack)
     saveLocals (rs^.localVariables) (vs^.localVariables)

forceJVMValue :: JVMValue s -> JVMGenerator h s ret (JVMValue s)
forceJVMValue val =
  case val of
    DValue v -> DValue <$> forceEvaluation v
    FValue v -> FValue <$> forceEvaluation v
    IValue v -> IValue <$> forceEvaluation v
    LValue v -> LValue <$> forceEvaluation v
    RValue v -> RValue <$> forceEvaluation v

-------------------------------------------------------------------------------
-- * Basic blocks

generateBasicBlock ::
  J.BasicBlock ->
  JVMRegisters s ->
  JVMGenerator h s ret a
generateBasicBlock bb rs =
  do -- Record the registers for this block.
     -- This also signals that generation of this block has started.
     jsFrameMap %= Map.insert (J.bbId bb) rs
     -- Read initial values
     vs <- readRegisters rs
     -- Translate all instructions
     (_, eframe) <- runStateT (mapM_ generateInstruction (J.bbInsts bb)) vs
     -- If we didn't already handle a block-terminating instruction,
     -- jump to the successor block, if there's only one.
     cfg <- use jsCFG
     case J.succs cfg (J.bbId bb) of
       [J.BBId succPC] ->
         do lbl <- processBlockAtPC succPC eframe
            _ <- jump lbl
            jvmFail "generateBasicBlock: ran off end of block"
       [] -> jvmFail "generateBasicBlock: no terminal instruction and no successor"
       _  -> jvmFail "generateBasicBlock: no terminal instruction and multiple successors"

-- | Prepare for a branch or jump to the given address, by generating
-- a transition block to copy the values into the appropriate
-- registers. If the target has already been translated (or is
-- currently being translated) then the registers already exist, so we
-- simply write into them. If the target has not been started yet, we
-- copy the values into fresh registers, and also recursively call
-- 'generateBasicBlock' on the target block to start translating it.
processBlockAtPC :: J.PC -> JVMExprFrame s -> JVMGenerator h s ret (Label s)
processBlockAtPC pc vs =
  defineBlockLabel $
  do bb <- getBasicBlockAtPC pc
     lbl <- getLabelAtPC pc
     fm <- use jsFrameMap
     case Map.lookup (J.bbId bb) fm of
       Just rs ->
         do writeRegisters rs vs
       Nothing ->
         do rs <- newRegisters vs
            defineBlock lbl (generateBasicBlock bb rs)
     jump lbl

getBasicBlockAtPC :: J.PC -> JVMGenerator h s ret J.BasicBlock
getBasicBlockAtPC pc =
  do cfg <- use jsCFG
     case J.bbByPC cfg pc of
       Nothing -> jvmFail "getBasicBlockAtPC"
       Just bb -> return bb

getLabelAtPC :: J.PC -> JVMGenerator h s ret (Label s)
getLabelAtPC pc =
  do bb <- getBasicBlockAtPC pc
     lm <- use jsLabelMap
     case Map.lookup (J.bbId bb) lm of
       Nothing -> jvmFail "getLabelAtPC"
       Just lbl -> return lbl



----------------------------------------------------------------------
-- * JVM statement generator monad


-- | This has extra state that is only relevant in the context of a
-- single basic block: It tracks the values of the operand stack and
-- local variable array at each instruction.
type JVMStmtGen h s ret = StateT (JVMExprFrame s) (JVMGenerator h s ret)

-- | Indicate that CFG generation failed due to ill-formed JVM code.
sgFail :: String -> JVMStmtGen h s ret a
sgFail msg = lift $ jvmFail msg

sgUnimplemented :: String -> JVMStmtGen h s ret a
sgUnimplemented msg = sgFail $ "unimplemented: " ++ msg

getStack :: JVMStmtGen h s ret [JVMValue s]
getStack = use operandStack

putStack :: [JVMValue s] -> JVMStmtGen h s ret ()
putStack vs = operandStack .= vs

popValue :: JVMStmtGen h s ret (JVMValue s)
popValue =
  do vs <- getStack
     case vs of
       [] -> sgFail "popValue: empty stack"
       (v : vs') ->
         do putStack vs'
            return v

pushValue :: JVMValue s -> JVMStmtGen h s ret ()
pushValue v =
  do v' <- lift $ forceJVMValue v
     vs <- getStack
     putStack (v' : vs)

pushValues :: [JVMValue s] -> JVMStmtGen h s ret ()
pushValues vs =
  do vs' <- getStack
     putStack (vs ++ vs')

isType1 :: JVMValue s -> Bool
isType1 v =
  case v of
    DValue _ -> False
    LValue _ -> False
    _        -> True

isType2 :: JVMValue s -> Bool
isType2 = not . isType1

popType1 :: JVMStmtGen h s ret (JVMValue s)
popType1 =
  do v <- popValue
     if isType1 v then return v else sgFail "popType1"

popType2 :: JVMStmtGen h s ret [JVMValue s]
popType2 =
  do vs <- getStack
     case vs of
       v : vs' | isType2 v ->
         putStack vs' >> return [v]
       v1 : v2 : vs' | isType1 v1 && isType1 v2 ->
         putStack vs' >> return [v1, v2]
       _ ->
         sgFail "popType2"


iPop :: JVMStmtGen h s ret (JVMInt s)
iPop = popValue >>= lift . fromIValue

lPop :: JVMStmtGen h s ret (JVMLong s)
lPop = popValue >>= lift . fromLValue

rPop :: HasCallStack => JVMStmtGen h s ret (JVMRef s)
rPop = popValue >>= lift . fromRValue

dPop :: JVMStmtGen h s ret (JVMDouble s)
dPop = popValue >>= lift . fromDValue

fPop :: JVMStmtGen h s ret (JVMFloat s)
fPop = popValue >>= lift . fromFValue

iPush :: JVMInt s -> JVMStmtGen h s ret ()
iPush i = pushValue (IValue i)

lPush :: JVMLong s -> JVMStmtGen h s ret ()
lPush l = pushValue (LValue l)

fPush :: JVMFloat s -> JVMStmtGen h s ret ()
fPush f = pushValue (FValue f)

dPush :: JVMDouble s -> JVMStmtGen h s ret ()
dPush d = pushValue (DValue d)

rPush :: JVMRef s -> JVMStmtGen h s ret ()
rPush r = pushValue (RValue r)

uPush :: Expr JVM s UnitType -> JVMStmtGen h s ret ()
uPush _u = return ()


setLocal :: J.LocalVariableIndex -> JVMValue s -> JVMStmtGen h s ret ()
setLocal idx v =
  do v' <- lift $ forceJVMValue v
     localVariables %= Map.insert idx v'

getLocal :: J.LocalVariableIndex -> JVMStmtGen h s ret (JVMValue s)
getLocal idx =
  do vs <- use localVariables
     case Map.lookup idx vs of
       Just v -> return v
       Nothing -> sgFail "getLocal"

throwIfRefNull ::
  JVMRef s -> JVMStmtGen h s ret (Expr JVM s (ReferenceType JVMObjectType))
throwIfRefNull r = lift $ assertedJustExpr r "null dereference"

throw :: JVMRef s -> JVMStmtGen h s ret ()
throw _ = sgUnimplemented "throw"


----------------------------------------------------------------------

processBlockAtPC' :: J.PC -> JVMStmtGen h s ret (Label s)
processBlockAtPC' pc =
  do vs <- get
     lift $ processBlockAtPC pc vs

nextPC :: J.PC -> JVMStmtGen h s ret J.PC
nextPC pc =
  do cfg <- lift $ use jsCFG
     case J.nextPC cfg pc of
       Nothing -> sgFail "nextPC"
       Just pc' -> return pc'


  
----------------------------------------------------------------------

pushRet ::
  forall h s ret tp. TypeRepr tp -> Expr JVM s tp -> JVMStmtGen h s ret ()
pushRet tp expr = 
  tryPush dPush $
  tryPush fPush $
  tryPush iPush $
  tryPush lPush $
  tryPush rPush $
  tryPush uPush $  
  sgFail "pushRet: invalid type"
  where
    tryPush ::
      forall t. KnownRepr TypeRepr t =>
      (Expr JVM s t -> JVMStmtGen h s ret ()) ->
      JVMStmtGen h s ret () -> JVMStmtGen h s ret ()
    tryPush push k =
      case testEquality tp (knownRepr :: TypeRepr t) of
        Just Refl -> push expr
        Nothing -> k
  
popArgument ::
  forall tp h s ret. HasCallStack => TypeRepr tp -> JVMStmtGen h s ret (Expr JVM s tp)
popArgument tp =
  tryPop dPop $
  tryPop fPop $
  tryPop iPop $
  tryPop lPop $
  tryPop rPop $
  sgFail "pushRet: invalid type"
  where
    tryPop ::
      forall t. KnownRepr TypeRepr t =>
      JVMStmtGen h s ret (Expr JVM s t) ->
      JVMStmtGen h s ret (Expr JVM s tp) ->
      JVMStmtGen h s ret (Expr JVM s tp)
    tryPop pop k =
      case testEquality tp (knownRepr :: TypeRepr t) of
        Just Refl -> pop
        Nothing -> k

-- | Pop arguments from the stack; the last argument should be at the
-- top of the stack.
popArguments ::
  forall args h s ret.
  CtxRepr args -> JVMStmtGen h s ret (Ctx.Assignment (Expr JVM s) args)
popArguments args =
  case Ctx.viewAssign args of
    Ctx.AssignEmpty -> return Ctx.empty
    Ctx.AssignExtend tps tp ->
      do x <- popArgument tp
         xs <- popArguments tps
         return (Ctx.extend xs x)

----------------------------------------------------------------------

-- * Instruction generation

iZero :: JVMInt s
iZero = App (BVLit w32 0)

bTrue :: JVMBool s
bTrue = App (BoolLit True)

bFalse :: JVMBool s
bFalse = App (BoolLit False)


-- | Do the heavy lifting of translating JVM instructions to crucible code.
generateInstruction ::
  forall h s ret. HasCallStack =>
  (J.PC, J.Instruction) ->
  JVMStmtGen h s ret ()
generateInstruction (pc, instr) =
  case instr of
    -- Type conversion instructions
    J.D2f -> unary dPop fPush floatFromDouble
    J.D2i -> unary dPop iPush intFromDouble
    J.D2l -> unary dPop lPush longFromDouble
    J.F2d -> unary fPop dPush doubleFromFloat
    J.F2i -> unary fPop iPush intFromFloat
    J.F2l -> unary fPop lPush longFromFloat
    J.I2b -> unary iPop iPush byteFromInt
    J.I2c -> unary iPop iPush charFromInt
    J.I2d -> unary iPop dPush doubleFromInt
    J.I2f -> unary iPop fPush floatFromInt
    J.I2l -> unary iPop lPush longFromInt
    J.I2s -> unary iPop iPush shortFromInt
    J.L2d -> unary lPop dPush doubleFromLong
    J.L2f -> unary lPop fPush floatFromLong
    J.L2i -> unary lPop iPush intFromLong

    -- Arithmetic instructions
    J.Dadd  -> binary dPop dPop dPush dAdd
    J.Dsub  -> binary dPop dPop dPush dSub
    J.Dneg  -> unary dPop dPush dNeg
    J.Dmul  -> binary dPop dPop dPush dMul
    J.Ddiv  -> binary dPop dPop dPush dDiv
    J.Drem  -> binary dPop dPop dPush dRem
    J.Dcmpg -> binaryGen dPop dPop iPush dCmpg
    J.Dcmpl -> binaryGen dPop dPop iPush dCmpl
    J.Fadd  -> binary fPop fPop fPush fAdd
    J.Fsub  -> binary fPop fPop fPush fSub
    J.Fneg  -> unary fPop fPush (error "fNeg")
    J.Fmul  -> binary fPop fPop fPush fMul
    J.Fdiv  -> binary fPop fPop fPush fDiv
    J.Frem  -> binary fPop fPop fPush fRem
    J.Fcmpg -> binaryGen fPop fPop iPush dCmpg
    J.Fcmpl -> binaryGen fPop fPop iPush dCmpl
    J.Iadd  -> binary iPop iPop iPush (\a b -> App (BVAdd w32 a b))
    J.Isub  -> binary iPop iPop iPush (\a b -> App (BVSub w32 a b))
    J.Imul  -> binary iPop iPop iPush (\a b -> App (BVMul w32 a b))
    J.Idiv  -> binary iPop iPop iPush
               (\a b -> App (AddSideCondition (BaseBVRepr w32) (App (BVNonzero w32 b))
                             "java/lang/ArithmeticException"
                             (App (BVSdiv w32 a b))))
    J.Irem -> binary iPop iPop iPush
               (\a b -> App (AddSideCondition (BaseBVRepr w32) (App (BVNonzero w32 b))
                             "java/lang/ArithmeticException"
                             (App (BVSrem w32 a b))))
    J.Ineg  -> unaryGen iPop iPush iNeg
    J.Iand  -> binary iPop iPop iPush (\a b -> App (BVAnd w32 a b))
    J.Ior   -> binary iPop iPop iPush (\a b -> App (BVOr  w32 a b))
    J.Ixor  -> binary iPop iPop iPush (\a b -> App (BVXor w32 a b))
    J.Ishl  -> binary iPop iPop iPush (\a b -> App (BVShl w32 a b))
    J.Ishr  -> binary iPop iPop iPush (\a b -> App (BVAshr w32 a b))
    J.Iushr -> binary iPop iPop iPush (\a b -> App (BVLshr w32 a b))
    J.Ladd  -> binary lPop lPop lPush (\a b -> App (BVAdd w64 a b))
    J.Lsub  -> binary lPop lPop lPush (\a b -> App (BVSub w64 a b))
    J.Lmul  -> binary lPop lPop lPush (\a b -> App (BVMul w64 a b))
    J.Lneg  -> unaryGen lPop lPush lNeg
    J.Ldiv  -> binary lPop lPop lPush -- TODO: why was this lPush an error?
               -- there is also a special case when when dividend is maxlong
               -- and divisor is -1 
               (\a b -> App (AddSideCondition (BaseBVRepr w64) (App (BVNonzero w64 b))
                             "java/lang/ArithmeticException"
                             (App (BVSdiv w64 a b))))
    J.Lrem -> binary lPop lPop lPush
               (\a b -> App (AddSideCondition (BaseBVRepr w64) (App (BVNonzero w64 b))
                             "java/lang/ArithmeticException"
                             (App (BVSrem w64 a b))))
    J.Land  -> binary lPop lPop lPush (\a b -> App (BVAnd w64 a b))
    J.Lor   -> binary lPop lPop lPush (\a b -> App (BVOr  w64 a b))
    J.Lxor  -> binary lPop lPop lPush (\a b -> App (BVXor w64 a b))
    J.Lcmp  -> binaryGen lPop lPop iPush lCmp
    J.Lshl  -> binary lPop (longFromInt <$> iPop) lPush (\a b -> App (BVShl w64 a b))
    J.Lshr  -> binary lPop (longFromInt <$> iPop) lPush (\a b -> App (BVAshr w64 a b))
    J.Lushr -> binary lPop (longFromInt <$> iPop) lPush (\a b -> App (BVLshr w64 a b))

    -- Load and store instructions
    J.Iload idx -> getLocal idx >>= pushValue
    J.Lload idx -> getLocal idx >>= pushValue
    J.Fload idx -> getLocal idx >>= pushValue
    J.Dload idx -> getLocal idx >>= pushValue
    J.Aload idx -> getLocal idx >>= pushValue
    J.Istore idx -> popValue >>= setLocal idx
    J.Lstore idx -> popValue >>= setLocal idx
    J.Fstore idx -> popValue >>= setLocal idx
    J.Dstore idx -> popValue >>= setLocal idx
    J.Astore idx -> popValue >>= setLocal idx
    J.Ldc cpv ->
      case cpv of
        J.Double v   -> dPush (dConst v)
        J.Float v    -> fPush (fConst v)
        J.Integer v  -> iPush (iConst (toInteger v))
        J.Long v     -> lPush (lConst (toInteger v))
        J.String v  -> pushValue . RValue =<< (lift $ refFromString v)
        J.ClassRef _ -> rPush rNull -- TODO: construct reflective class information


    -- Object creation and manipulation
    J.New name -> do
      lift $ debug 2 $ "new " ++ show name
      cls    <- lift $ lookupClassGen name
      clsObj <- lift $ getJVMClass cls
      -- find the fields not just in this class, but also in the super classes
      fields <- lift $ getAllFields cls
      obj    <- lift $ newInstanceInstr clsObj fields
      rawRef <- lift $ newRef obj
      rPush $ App (JustValue knownRepr rawRef)

    J.Getfield fieldId -> do
      lift $ debug 2 $ "getfield " ++ show (J.fieldIdName fieldId)
      objectRef <- rPop
      rawRef <- throwIfRefNull objectRef
      obj <- lift $ readRef rawRef
      val <- lift $ getInstanceFieldValue obj fieldId
      pushValue val

    J.Putfield fieldId -> do
      lift $ debug 2 $ "putfield " ++ show (J.fieldIdName fieldId)
      val <- popValue
      objectRef <- rPop
      rawRef <- throwIfRefNull objectRef
      obj  <- lift $ readRef rawRef
      obj' <- lift $ setInstanceFieldValue obj fieldId val
      lift $ writeRef rawRef obj'

    J.Getstatic fieldId -> do
      val <- lift $ getStaticFieldValue fieldId
      pushValue val

    J.Putstatic fieldId -> do
      val <- popValue
      lift $ setStaticFieldValue fieldId val

    -- Array creation and manipulation
    J.Newarray arrayType ->
      do count <- iPop
         let nonneg = App (BVSle w32 (iConst 0) count)
         lift $ assertExpr nonneg "java/lang/NegativeArraySizeException"
         -- FIXME: why doesn't jvm-parser just store the element type?
         case arrayType of
           J.ArrayType elemType -> do
             -- REVISIT: old version did not allow arrays of arrays
             -- or arrays of objects. Why was that?
             -- We can disable that here if necessary by
             -- matching on the elem type
             let expr = valueToExpr $ defaultValue elemType 
             let obj = newarrayExpr count expr
             rawRef <- lift $ newRef obj
             let ref = App (JustValue knownRepr rawRef)
             rPush ref
{-             case elemType of
               J.ArrayType _ -> sgFail "newarray: invalid element type"
               J.ClassType _ -> sgFail "newarray: invalid element type" -}
           _ -> sgFail "newarray: expected array type"
    J.Multianewarray _elemType dimensions ->
      do counts <- reverse <$> sequence (replicate (fromIntegral dimensions) iPop)
         forM_ counts $ \count -> do
           let nonneg = App (BVSle w32 (iConst 0) count)
           lift $ assertExpr nonneg "java/lang/NegativeArraySizeException"
         sgUnimplemented "multianewarray" --pushValue . RValue =<< newMultiArray arrayType counts

    -- Load an array component onto the operand stack
    J.Baload -> aloadInstr tagI IValue -- byte
    J.Caload -> aloadInstr tagI IValue -- char
    J.Saload -> aloadInstr tagI IValue -- short
    J.Iaload -> aloadInstr tagI IValue
    J.Laload -> aloadInstr tagL LValue
    J.Faload -> aloadInstr tagF FValue
    J.Daload -> aloadInstr tagD DValue
    J.Aaload -> aloadInstr tagR RValue

    -- Store a value from the operand stack as an array component
    J.Bastore -> iPop >>= astoreInstr tagI byteFromInt
    J.Castore -> iPop >>= astoreInstr tagI charFromInt
    J.Sastore -> iPop >>= astoreInstr tagI shortFromInt
    J.Iastore -> iPop >>= astoreInstr tagI id
    J.Lastore -> lPop >>= astoreInstr tagL id
    J.Fastore -> fPop >>= astoreInstr tagF id
    J.Dastore -> dPop >>= astoreInstr tagD id
    J.Aastore -> rPop >>= astoreInstr tagR id

    -- Stack management instructions
    J.Pop ->
      do void popType1
    J.Pop2 ->
      do void popType2
    J.Dup ->
      do value <- popType1
         pushValue value
         pushValue value
    J.Dup_x1 ->
      do value1 <- popType1
         value2 <- popType1
         pushValue value1
         pushValue value2
         pushValue value1
    J.Dup_x2 ->
      do value1 <- popType1
         value2 <- popType2
         pushValue value1
         pushValues value2
         pushValue value1
    J.Dup2 ->
      do value <- popType2
         pushValues value
         pushValues value
    J.Dup2_x1 ->
      do value1 <- popType2
         value2 <- popType1
         pushValues value1
         pushValue value2
         pushValues value1
    J.Dup2_x2 ->
      do value1 <- popType2
         value2 <- popType2
         pushValues value1
         pushValues value2
         pushValues value1
    J.Swap ->
      do value1 <- popType1
         value2 <- popType1
         pushValue value1
         pushValue value2

    -- Conditional branch instructions
    J.If_acmpeq pc' ->
      do r2 <- rPop
         r1 <- rPop
         eq <- lift $ rEqual r1 r2
         pc'' <- nextPC pc
         branchIf eq pc' pc''
    J.If_acmpne pc' ->
      do r2 <- rPop
         r1 <- rPop
         eq <- lift $ rEqual r1 r2
         pc'' <- nextPC pc
         branchIf (App (Not eq)) pc' pc''
    J.Ifnonnull pc' ->
      do r <- rPop
         n <- lift $ rIsNull r
         pc'' <- nextPC pc
         branchIf (App (Not n)) pc' pc''
    J.Ifnull pc' ->
      do r <- rPop
         n <- lift $ rIsNull r
         pc'' <- nextPC pc
         branchIf n pc' pc''

    J.If_icmpeq pc' -> icmpInstr pc pc' $ \a b -> App (BVEq w32 a b)
    J.If_icmpne pc' -> icmpInstr pc pc' $ \a b -> App (Not (App (BVEq w32 a b)))
    J.If_icmplt pc' -> icmpInstr pc pc' $ \a b -> App (BVSlt w32 a b)
    J.If_icmpge pc' -> icmpInstr pc pc' $ \a b -> App (BVSle w32 b a)
    J.If_icmpgt pc' -> icmpInstr pc pc' $ \a b -> App (BVSlt w32 b a)
    J.If_icmple pc' -> icmpInstr pc pc' $ \a b -> App (BVSle w32 a b)

    J.Ifeq pc' -> ifInstr pc pc' $ \a -> App (Not (App (BVNonzero w32 a)))
    J.Ifne pc' -> ifInstr pc pc' $ \a -> App (BVNonzero w32 a)
    J.Iflt pc' -> ifInstr pc pc' $ \a -> App (BVSlt w32 a iZero)
    J.Ifge pc' -> ifInstr pc pc' $ \a -> App (BVSle w32 iZero a)
    J.Ifgt pc' -> ifInstr pc pc' $ \a -> App (BVSlt w32 iZero a)
    J.Ifle pc' -> ifInstr pc pc' $ \a -> App (BVSle w32 a iZero)

    J.Tableswitch pc' lo _hi pcs ->
      do iPop >>= switchInstr pc' (zip [lo ..] pcs)
    J.Lookupswitch pc' table ->
      do iPop >>= switchInstr pc' table
    J.Goto pc' ->
      do vs <- get
         lbl <- lift $ processBlockAtPC pc' vs
         lift $ jump lbl
         
    J.Jsr _pc' -> sgFail "generateInstruction: jsr/ret not supported"
    J.Ret _idx -> sgFail "ret" --warning "jsr/ret not implemented"

    -- Method invocation and return instructions
    -- usual dynamic dispatch
    J.Invokevirtual (J.ClassType className) methodKey ->
      generateInstruction (pc, J.Invokeinterface className methodKey)

    J.Invokevirtual (J.ArrayType _ty) methodKey ->
      sgFail $ "TODO: invoke virtual " ++ show (J.methodKeyName methodKey)
                                       ++ " unsupported for arrays"

    J.Invokevirtual   tp        _methodKey ->
      sgFail $ "Invalid static type for invokevirtual " ++ show tp 

    -- Dynamic dispatch through an interface
    J.Invokeinterface className methodKey -> do
      let mname = J.unClassName className ++ "/" ++ J.methodKeyName methodKey
      lift $ debug 2 $ "invoke: " ++ mname

      -- find the static type of the method
      let argTys = Ctx.fromList (map javaTypeToRepr (J.methodKeyParameterTypes methodKey))
      let retTy  = maybe (Some C.UnitRepr) javaTypeToRepr (J.methodKeyReturnType methodKey)

      case (argTys, retTy) of
        (Some argRepr, Some retRepr) -> do
            
            args <- popArguments argRepr
            objRef <- rPop
            
            rawRef <- throwIfRefNull objRef
            result <- lift $ do
              obj    <- readRef rawRef
              cls    <- getJVMInstanceClass obj
              anym   <- findDynamicMethod cls methodKey
              
              let argRepr' = (Ctx.empty `Ctx.extend` (knownRepr :: TypeRepr JVMRefType)) Ctx.<++> argRepr 
              fn     <- assertedJustExpr (App (UnpackAny (FunctionHandleRepr argRepr' retRepr) anym))
                        (App $ TextLit $ fromString ("invalid method type"
                                      ++ show (FunctionHandleRepr argRepr' retRepr)
                                      ++ " for "
                                      ++ show methodKey))
              call fn (Ctx.empty `Ctx.extend` objRef Ctx.<++> args)

            pushRet retRepr result
            lift $ debug 2 $ "finish invoke:" ++ mname
    
    J.Invokespecial   (J.ClassType methodClass) methodKey ->
      -- treat constructor invocations like static methods
      generateInstruction (pc, J.Invokestatic methodClass methodKey)

    J.Invokespecial   tp _methodKey ->
      -- TODO
      sgUnimplemented $ "Invokespecial for " ++ show tp
      
    J.Invokestatic    className methodKey
      | Just action <- staticOverrides className methodKey
      -- look for a static override for this class and run that
      -- instead
      -> action
      

      | otherwise -> 
        -- make sure that *this* class has already been initialized
        do lift $ initializeClass className
           (JVMHandleInfo _ handle) <- lift $ getStaticMethod className methodKey
           args <- popArguments (handleArgTypes handle)
           result <- lift $ call (App (HandleLit handle)) args
           pushRet (handleReturnType handle) result

    J.Invokedynamic   _word16 ->
      -- TODO
      sgUnimplemented "TODO: Invokedynamic needs more support from jvm-parser"

    J.Ireturn -> returnInstr iPop
    J.Lreturn -> returnInstr lPop
    J.Freturn -> returnInstr fPop
    J.Dreturn -> returnInstr dPop
    J.Areturn -> returnInstr rPop --
    J.Return  -> returnInstr (return (App EmptyApp)) 

    -- Other XXXXX
    J.Aconst_null ->
      do rPush rNull
    J.Arraylength ->
      do arrayRef <- rPop
         rawRef <- throwIfRefNull arrayRef
         obj <- lift $ readRef rawRef
         len <- lift $ arrayLength obj
         iPush len
    J.Athrow ->
      do _objectRef <- rPop
         -- For now, we assert that exceptions won't happen
         lift $ reportError (App (TextLit "athrow"))
         --throwIfRefNull objectRef
         --throw objectRef
         
    J.Checkcast (J.ClassType className) ->
      do objectRef <- rPop
         rawRef <- throwIfRefNull objectRef
         lift $ do obj <- readRef rawRef
                   cls <- getJVMInstanceClass obj
                   b <- isSubType cls className 
                   assertExpr b "java/lang/ClassCastException"
         rPush objectRef

    J.Checkcast tp ->
      -- TODO -- can we cast arrays?
      sgUnimplemented $ "checkcast unimplemented for type: " ++ show tp
    J.Iinc idx constant ->
      do value <- getLocal idx >>= lift . fromIValue
         let constValue = iConst (fromIntegral constant)
         setLocal idx (IValue (App (BVAdd w32 value constValue)))
    J.Instanceof (J.ClassType className) ->
      do objectRef <- rPop
         rawRef <- throwIfRefNull objectRef
         obj <- lift $ readRef rawRef
         cls <- lift $ getJVMInstanceClass obj
         b <- lift $ isSubType cls className
         let ib = App (BaseIte knownRepr b (App $ BVLit w32 1) (App $ BVLit w32 0))
         iPush ib
    J.Instanceof _tp ->
         -- TODO -- ArrayType
         sgUnimplemented "instanceof for array type" -- objectRef `instanceOf` tp
    J.Monitorenter ->
      do void rPop
    J.Monitorexit ->
      do void rPop
    J.Nop ->
      do return ()

unary ::
  JVMStmtGen h s ret a ->
  (b -> JVMStmtGen h s ret ()) ->
  (a -> b) ->
  JVMStmtGen h s ret ()
unary pop push op =
  do value <- pop
     push (op value)


unaryGen ::
  JVMStmtGen h s ret a ->
  (b -> JVMStmtGen h s ret ()) ->
  (a -> JVMGenerator h s ret b) ->
  JVMStmtGen h s ret ()
unaryGen pop push op =
  do value <- pop
     ret <- lift $ op value
     push ret

binary ::
  JVMStmtGen h s ret a ->
  JVMStmtGen h s ret b ->
  (c -> JVMStmtGen h s ret ()) ->
  (a -> b -> c) ->
  JVMStmtGen h s ret ()
binary pop1 pop2 push op =
  do value2 <- pop2
     value1 <- pop1
     push (value1 `op` value2)

binaryGen ::
  JVMStmtGen h s ret a ->
  JVMStmtGen h s ret b ->
  (c -> JVMStmtGen h s ret ()) ->
  (a -> b -> JVMGenerator h s ret c) ->
  JVMStmtGen h s ret ()
binaryGen pop1 pop2 push op =
  do value2 <- pop2
     value1 <- pop1
     ret <- lift $ value1 `op` value2 
     push ret


aloadInstr ::
  KnownRepr TypeRepr t =>
  Ctx.Index JVMValueCtx t ->
  (Expr JVM s t -> JVMValue s) ->
  JVMStmtGen h s ret ()
aloadInstr tag mkVal =
  do idx <- iPop
     arrayRef <- rPop
     rawRef <- throwIfRefNull arrayRef
     obj <- lift $ readRef rawRef
     val <- lift $ arrayIdx obj idx
     let mx = App (ProjectVariant knownRepr tag val)
     x <- lift $ assertedJustExpr mx "aload: invalid element type"
     pushValue (mkVal x)

astoreInstr ::
  KnownRepr TypeRepr t =>
  Ctx.Index JVMValueCtx t ->
  (Expr JVM s t -> Expr JVM s t) ->
  Expr JVM s t ->
  JVMStmtGen h s ret ()
astoreInstr tag f x =
  do idx <- iPop
     arrayRef <- rPop
     rawRef <- throwIfRefNull arrayRef
     obj <- lift $ readRef rawRef
     let val = App (InjectVariant knownRepr tag (f x))
     obj' <- lift $ arrayUpdate obj idx val
     lift $ writeRef rawRef obj'

icmpInstr ::
  J.PC {- ^ previous PC -} ->
  J.PC {- ^ branch target -} ->
  (JVMInt s -> JVMInt s -> JVMBool s) ->
  JVMStmtGen h s ret ()
icmpInstr pc_old pc_t cmp =
  do i2 <- iPop
     i1 <- iPop
     pc_f <- nextPC pc_old
     branchIf (cmp i1 i2) pc_t pc_f

ifInstr ::
  J.PC {- ^ previous PC -} ->
  J.PC {- ^ branch target -} ->
  (JVMInt s -> JVMBool s) ->
  JVMStmtGen h s ret ()
ifInstr pc_old pc_t cmp =
  do i <- iPop
     pc_f <- nextPC pc_old
     branchIf (cmp i) pc_t pc_f

branchIf ::
  JVMBool s ->
  J.PC {- ^ true label -} ->
  J.PC {- ^ false label -} ->
  JVMStmtGen h s ret ()
branchIf cond pc_t pc_f =
  do vs <- get
     lbl_t <- lift $ processBlockAtPC pc_t vs
     lbl_f <- lift $ processBlockAtPC pc_f vs
     lift $ branch cond lbl_t lbl_f

switchInstr ::
  J.PC {- ^ default target -} ->
  [(Int32, J.PC)] {- ^ jump table -} ->
  JVMInt s {- ^ scrutinee -} ->
  JVMStmtGen h s ret ()
switchInstr def [] _ =
  do vs <- get
     lift $ processBlockAtPC def vs >>= jump
switchInstr def ((i, pc) : table) x =
  do vs <- get
     l <- lift $ processBlockAtPC pc vs
     let cond = App (BVEq w32 x (iConst (toInteger i)))
     lift $ whenCond cond (jump l)
     switchInstr def table x

returnInstr ::
  forall h s ret tp.
  KnownRepr TypeRepr tp =>
  JVMStmtGen h s ret (Expr JVM s tp) ->
  JVMStmtGen h s ret ()
returnInstr pop =
  do retType <- lift $ jsRetType <$> get
     case testEquality retType (knownRepr :: TypeRepr tp) of
       Just Refl -> pop >>= (lift . returnFromFunction)
       Nothing -> sgFail "ireturn: type mismatch"

----------------------------------------------------------------------
-- * Basic Value Operations

floatFromDouble :: JVMDouble s -> JVMFloat s
floatFromDouble d = App (FloatCast SingleFloatRepr RNE d)

intFromDouble :: JVMDouble s -> JVMInt s
intFromDouble d = App (FloatToSBV w32 RTZ d)

longFromDouble :: JVMDouble s -> JVMLong s
longFromDouble d = App (FloatToSBV w64 RTZ d)

doubleFromFloat :: JVMFloat s -> JVMDouble s
doubleFromFloat f = App (FloatCast DoubleFloatRepr RNE f)

intFromFloat :: JVMFloat s -> JVMInt s
intFromFloat f = App (FloatToSBV w32 RTZ f)

longFromFloat :: JVMFloat s -> JVMLong s
longFromFloat f = App (FloatToSBV w64 RTZ f)

doubleFromInt :: JVMInt s -> JVMDouble s
doubleFromInt i = App (FloatFromSBV DoubleFloatRepr RNE i)

floatFromInt :: JVMInt s -> JVMFloat s
floatFromInt i = App (FloatFromSBV SingleFloatRepr RNE i)

-- | TODO: double check this
longFromInt :: JVMInt s -> JVMLong s
longFromInt x = App (BVSext w64 w32 x)


doubleFromLong :: JVMLong s -> JVMDouble s
doubleFromLong l = App (FloatFromSBV DoubleFloatRepr RNE l)

floatFromLong :: JVMLong s -> JVMFloat s
floatFromLong l = App (FloatFromSBV SingleFloatRepr RNE l)

intFromLong :: JVMLong s -> JVMInt s
intFromLong l = App (BVTrunc w32 w64 l)

iConst :: Integer -> JVMInt s
iConst i = App (BVLit w32 i)

lConst :: Integer -> JVMLong s
lConst i = App (BVLit w64 i)

dConst :: Double -> JVMDouble s
dConst d = App (DoubleLit d)

fConst :: Float -> JVMFloat s
fConst f = App (FloatLit f)

-- TODO: is there a better way to specify -2^32?
minInt :: JVMInt s
minInt = App $ BVLit w32 (- (2 :: Integer) ^ (32 :: Int))

minLong :: JVMLong s 
minLong = App $ BVLit w64 (- (2 :: Integer) ^ (64 :: Int))

--TODO : doublecheck what Crucible does for BVSub
-- For int values, negation is the same as subtraction from
-- zero. Because the Java Virtual Machine uses two's-complement
-- representation for integers and the range of two's-complement
-- values is not symmetric, the negation of the maximum negative int
-- results in that same maximum negative number. Despite the fact that
-- overflow has occurred, no exception is thrown.
iNeg :: JVMInt s -> JVMGenerator h s ret (JVMInt s)
iNeg e = ifte (App $ BVEq w32 e minInt)
              (return minInt)
              (return $ App (BVSub knownRepr (App (BVLit knownRepr 0)) e))


lNeg :: JVMLong s -> JVMGenerator h s ret (JVMLong s)
lNeg e = ifte (App $ BVEq knownRepr e minLong)
              (return minLong)
              (return $ App (BVSub knownRepr (App (BVLit knownRepr 0)) e))



dAdd, dSub, dMul, dDiv, dRem :: JVMDouble s -> JVMDouble s -> JVMDouble s
dAdd e1 e2 = App (FloatAdd DoubleFloatRepr RNE e1 e2)
dSub e1 e2 = App (FloatSub DoubleFloatRepr RNE e1 e2)
dMul e1 e2 = App (FloatMul DoubleFloatRepr RNE e1 e2)
dDiv e1 e2 = App (FloatDiv DoubleFloatRepr RNE e1 e2)
dRem e1 e2 = App (FloatRem DoubleFloatRepr e1 e2)


--TODO: treatment of NaN
--TODO: difference between dCmpg/dCmpl
-- | If the two numbers are the same, the int 0 is pushed onto the
-- stack. If value2 is greater than value1, the int 1 is pushed onto the
-- stack. If value1 is greater than value2, -1 is pushed onto the
-- stack. If either numbers is NaN, the int 1 is pushed onto the
-- stack. +0.0 and -0.0 are treated as equal.
dCmpg, dCmpl :: forall fi s h ret.
                Expr JVM s (FloatType fi) -> Expr JVM s (FloatType fi) -> JVMGenerator h s ret (JVMInt s)
dCmpg e1 e2 = ifte (App (FloatEq e1 e2)) (return $ App $ BVLit w32 0)
                   (ifte (App (FloatGe e2 e1)) (return $ App $ BVLit w32 1)
                         (return $ App $ BVLit w32 (-1)))
dCmpl = dCmpg

dNeg :: JVMDouble s -> JVMDouble s
dNeg = error "dNeg"

fAdd, fSub, fMul, fDiv, fRem :: JVMFloat s -> JVMFloat s -> JVMFloat s
fAdd e1 e2 = App (FloatAdd SingleFloatRepr RNE e1 e2)
fSub e1 e2 = App (FloatSub SingleFloatRepr RNE e1 e2)
fMul e1 e2 = App (FloatMul SingleFloatRepr RNE e1 e2)
fDiv e1 e2 = App (FloatDiv SingleFloatRepr RNE e1 e2)
fRem e1 e2 = App (FloatRem SingleFloatRepr e1 e2)


-- TODO: are these signed or unsigned integers?
-- | Takes two two-word long integers off the stack and compares them. If
-- the two integers are the same, the int 0 is pushed onto the stack. If
-- value2 is greater than value1, the int 1 is pushed onto the stack. If
-- value1 is greater than value2, the int -1 is pushed onto the stack.
lCmp :: JVMLong s -> JVMLong s -> JVMGenerator h s ret (JVMInt s)
lCmp e1 e2 =  ifte (App (BVEq knownRepr e1 e2)) (return $ App $ BVLit w32 0)
                   (ifte (App (BVSlt knownRepr e1 e2)) (return $ App $ BVLit w32 1)
                         (return $ App $ BVLit w32 (-1)))



----------------------------------------------------------------------

-- | Given a JVM type and a type context and a register assignment,
-- peel off the rightmost register from the assignment, which is
-- expected to match the given LLVM type. Pass the register and the
-- remaining type and register context to the given continuation.
--
-- This procedure is used to set up the initial state of the registers
-- at the entry point of a function.
packTypes ::
  [J.Type] ->
  CtxRepr ctx ->
  Ctx.Assignment (Atom s) ctx ->
  [JVMValue s]
packTypes [] ctx _asgn
  | Ctx.null ctx = []
  | otherwise = error "packTypes: arguments do not match JVM types"
packTypes (t : ts) ctx asgn =
  jvmTypeAsRepr t $ \mkVal ctp ->
  case ctx of
    Ctx.Empty ->
      error "packTypes: arguments do not match JVM types"
    ctx' Ctx.:> ctp' ->
      case testEquality ctp ctp' of
        Nothing -> error $ unwords ["crucible type mismatch", show ctp, show ctp']
        Just Refl ->
          mkVal (AtomExpr (Ctx.last asgn)) : packTypes ts ctx' (Ctx.init asgn)
  where
    jvmTypeAsRepr ::
      J.Type ->
      (forall tp. (Expr JVM s tp -> JVMValue s) -> TypeRepr tp -> [JVMValue s]) ->
      [JVMValue s]
    jvmTypeAsRepr ty k =
      case ty of
        J.ArrayType _ -> k RValue (knownRepr :: TypeRepr JVMRefType)
        J.BooleanType -> k IValue (knownRepr :: TypeRepr JVMIntType)
        J.ByteType    -> k IValue (knownRepr :: TypeRepr JVMIntType)
        J.CharType    -> k IValue (knownRepr :: TypeRepr JVMIntType)
        J.ClassType _ -> k RValue (knownRepr :: TypeRepr JVMRefType)
        J.DoubleType  -> k DValue (knownRepr :: TypeRepr JVMDoubleType)
        J.FloatType   -> k FValue (knownRepr :: TypeRepr JVMFloatType)
        J.IntType     -> k IValue (knownRepr :: TypeRepr JVMIntType)
        J.LongType    -> k LValue (knownRepr :: TypeRepr JVMLongType)
        J.ShortType   -> k IValue (knownRepr :: TypeRepr JVMIntType)
  
initialJVMExprFrame ::
  J.ClassName ->
  J.Method ->
  CtxRepr ctx ->
  Ctx.Assignment (Atom s) ctx ->
  JVMExprFrame s
initialJVMExprFrame cn method ctx asgn = JVMFrame [] locals
  where
    args = J.methodParameterTypes method
    static = J.methodIsStatic method
    args' = if static then args else J.ClassType cn : args
    vals = reverse (packTypes (reverse args') ctx asgn)
    idxs = J.methodParameterIndexes method
    idxs' = if static then idxs else 0 : idxs
    locals = Map.fromList (zip idxs' vals)

----------------------------------------------------------------------


generateMethod ::
  J.ClassName ->
  J.Method ->
  CtxRepr init ->
  Ctx.Assignment (Atom s) init ->
  JVMGenerator h s ret a
generateMethod cn method ctx asgn =
  do let cfg = methodCFG method
     let bbLabel bb = (,) (J.bbId bb) <$> newLabel
     lbls <- traverse bbLabel (J.allBBs cfg)
     jsLabelMap .= Map.fromList lbls
     bb0 <- maybe (jvmFail "no entry block") return (J.bbById cfg J.BBIdEntry)
     let vs0 = initialJVMExprFrame cn method ctx asgn
     rs0 <- newRegisters vs0
     generateBasicBlock bb0 rs0


-- | Define a block with a fresh lambda label, returning the label.
defineLambdaBlockLabel ::
  (IsSyntaxExtension ext, KnownRepr TypeRepr tp) =>
  (forall a. Expr ext s tp -> Generator ext h s t ret a) ->
  Generator ext h s t ret (LambdaLabel s tp)
defineLambdaBlockLabel action =
  do l <- newLambdaLabel
     defineLambdaBlock l action
     return l

-----------------------------------------------------------------------------
-- | translateClass


data MethodTranslation = forall args ret. MethodTranslation
   { methodHandle :: FnHandle args ret
   , methodCCFG   :: C.SomeCFG JVM args ret
   }

-----------------------------------------------------------------------------
-- * Class declarations

-- | allocate a new method handle and add it to the table of method handles
declareMethod :: HandleAllocator s
              -> J.Class
              -> MethodHandleTable
              -> J.Method
              -> ST s MethodHandleTable
declareMethod halloc mcls ctx meth =
  let cname = J.className mcls
      mkey  = J.methodKey meth
  in do
   jvmToFunHandleRepr cname (J.methodIsStatic meth) mkey $
      \ argsRepr retRepr -> do
         -- "declaring " ++ J.unClassName cname ++ "/" ++ J.methodName meth
         --    ++ " : " ++ showJVMArgs argsRepr ++ " ---> " ++ showJVMType retRepr
         h <- mkHandle' halloc (methodHandleName cname mkey) argsRepr retRepr
         return $ Map.insert (cname, mkey) (JVMHandleInfo mkey h) ctx

-- | allocate the static field (a global variable)
-- and add it to the static field table
declareStaticField :: HandleAllocator s
    -> J.Class
    -> StaticFieldTable
    -> J.Field
    -> ST s StaticFieldTable
declareStaticField halloc c m f = do
  let cn = J.className c
  let fn = J.fieldName f
  gvar <- C.freshGlobalVar halloc (globalVarName cn fn) (knownRepr :: TypeRepr JVMValueType)
  return $ (Map.insert (cn,fn) gvar m)



-- | extend the JVM context in preparation for translating class c
-- by declaring handles for all methods
--    declaring global variables for all static fields and
--    adding the class information to the class table
extendJVMContext :: HandleAllocator s -> J.Class -> StateT JVMContext (ST s) ()
extendJVMContext halloc c = do
  sm <- lift $ foldM (declareMethod halloc c) Map.empty (J.classMethods c)
  st <- lift $ foldM (declareStaticField halloc c) Map.empty (J.classFields c)
  modify $ \ctx0 -> JVMContext
    { methodHandles     = sm 
    , staticFields      = st
    , classTable        = Map.singleton (J.className c) c
    , dynamicClassTable = dynamicClassTable ctx0
    } <> ctx0

-- | Create the initial JVMContext
mkInitialJVMContext ::  IsCodebase cb => HandleAllocator RealWorld -> cb -> IO JVMContext
mkInitialJVMContext halloc cb = do
  
  gv <- stToIO $ C.freshGlobalVar halloc (fromString "JVM_CLASS_TABLE")
                                (knownRepr :: TypeRepr JVMClassTableType)
        
  classes <- mapM (findClass cb) initClasses 

  stToIO $ execStateT
             (mapM_ (extendJVMContext halloc) classes)
             (JVMContext
              { methodHandles     = Map.empty
              , staticFields      = Map.empty
              , classTable        = Map.empty
              , dynamicClassTable = gv
              })
  

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
translateMethod' :: JVMContext
                 -> J.ClassName
                 -> J.Method
                 -> FnHandle args ret
                 -> ST h (C.SomeCFG JVM args ret)
translateMethod' ctx cName m h =     
  case (handleArgTypes h, handleReturnType h) of
    ((argTypes :: CtxRepr args), (retType :: TypeRepr ret)) -> do
      let  def :: FunctionDef JVM h (JVMState ret) args ret
           def inputs = (s, f)
             where s = initialState ctx m retType
                   f = generateMethod cName m argTypes inputs
      (SomeCFG g, []) <- defineFunction InternalPos h def
      return $ toSSA g


-- | Translate a single JVM method definition into a crucible CFG
translateMethod :: JVMContext
                -> J.Class
                -> J.Method
                -> ST s ((J.ClassName, J.MethodKey), MethodTranslation)
translateMethod ctx c m = do
  let cName = J.className c
  let mKey  = J.methodKey m
  case Map.lookup (cName,mKey) (methodHandles ctx) of
    Just (JVMHandleInfo _ h)  -> do
          g' <- translateMethod' ctx cName m h
          return ((cName,mKey), MethodTranslation h g')
    Nothing -> fail $ "internal error: Could not find method " ++ show mKey

------------------------------------------------------------------------
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

-- make bindings for all methods in the JVMContext classTable that have
-- associated method handles
mkDelayedBindings :: forall p sym . JVMContext -> C.FunctionBindings p sym JVM
mkDelayedBindings ctx =
  let bindings = [ mkDelayedBinding ctx c m h | (cn,c) <- Map.assocs (classTable ctx)
                                              , m <- J.classMethods c
                                              , h <- maybeToList $ Map.lookup (cn,J.methodKey m)
                                                     (methodHandles ctx)
                                              ]
  in                
    C.fnBindingsFromList bindings

-- Make a binding for a Java method that, when invoked, immediately
-- translates the Java source code and then runs it.
mkDelayedBinding :: forall p sym .
                    JVMContext
                 -> J.Class
                 -> J.Method
                 -> JVMHandleInfo
                 -> C.FnBinding p sym JVM
mkDelayedBinding ctx c m (JVMHandleInfo _mk (handle :: FnHandle args ret)) 
  = let cm           = J.unClassName (J.className c) ++ "/" ++ J.methodName m
        fn           = functionNameFromText (fromString (J.methodName m))
        retRepr      = handleReturnType handle
        
        overrideSim :: C.OverrideSim p sym JVM r args ret (C.RegValue sym ret)
        overrideSim  = do whenVerbosity (const False) $
                            do liftIO $ putStrLn $ "translating (delayed) " ++ cm
                          args <- C.getOverrideArgs
                          C.SomeCFG cfg <- liftST $ translateMethod' ctx (J.className c) m handle
                          C.bindFnHandle handle (C.UseCFG cfg (C.postdomInfo cfg))
                          (C.RegEntry _tp regval) <- C.callFnVal (C.HandleFnVal handle) args
                          return regval
    in
      C.FnBinding handle (C.UseOverride (C.mkOverride' fn retRepr overrideSim))


--------------------------------------------------------------------------------



findAllRefs :: IsCodebase cb => cb -> J.ClassName -> IO [ J.Class ]
findAllRefs cb cls = do
  names <- go (Set.singleton cls) 
  mapM (lookupClass cb) names
  where
    go :: Set.Set J.ClassName -> IO [J.ClassName]
    go curr = do
      (currClasses :: [J.Class]) <- traverse (lookupClass cb) (Set.toList curr)
      let newRefs = fmap classRefs currClasses
      let noExclude = Set.filter (not . exclude) (Set.unions newRefs)
      let allNew  = Set.union curr noExclude
      traceM $ "Curr refs: " ++ show allNew
      if curr == allNew
        then return (Set.toList curr)
        else go allNew 

--------------------------------------------------------------------------------

-- | Read from the provided java code base and simulate a
-- given static method. 
--
-- * Set the verbosity level for simulation
-- * Find the class/method information from the codebase
-- * Set up handles for java.lang.* & primitives
-- * declare the handle for all methods in this class
-- * Find the handle for this method
-- * run the simulator given the handle
executeCrucibleJVM :: forall ret args sym p cb.
  (IsBoolSolver sym, W4.IsSymExprBuilder sym, W4.IsInterpretedFloatSymExprBuilder sym,
   W4.SymInterpretedFloatType sym W4.SingleFloat ~ C.BaseRealType,
   W4.SymInterpretedFloatType sym W4.DoubleFloat ~ C.BaseRealType,
   KnownRepr CtxRepr args, KnownRepr TypeRepr ret, IsCodebase cb)
                   => cb               
                   -> Int               -- ^ Verbosity level
                   -> sym               -- ^ Simulator state
                   -> p                 -- ^ Personality
                   -> String            -- ^ Class name
                   -> String            -- ^ Method name
                   -> C.RegMap sym args -- ^ Arguments
                   -> IO (C.ExecResult p sym JVM (C.RegEntry sym ret))
executeCrucibleJVM cb verbosity sym p cname mname args = do

     setSimulatorVerbosity verbosity sym

     (mcls, meth) <- findMethod cb mname =<< findClass cb cname
     when (not (J.methodIsStatic meth)) $ do
       fail $ unlines [ "Crucible can only extract static methods" ]

  
     allClasses <- findAllRefs cb (J.className mcls)

     halloc <- newHandleAllocator

     -- declare the "primitive" classes
     ctx0 <- mkInitialJVMContext halloc cb

     -- declare this class && all classes that it refers to
     ctx <- stToIO $ execStateT (extendJVMContext halloc mcls >>
                                 mapM (extendJVMContext halloc) allClasses) ctx0


     (JVMHandleInfo _ h) <- findMethodHandle ctx mcls meth

     Refl <- failIfNotEqual (handleArgTypes h)   (knownRepr :: CtxRepr args)
       $ "Checking args for method " ++ mname
     Refl <- failIfNotEqual (handleReturnType h) (knownRepr :: TypeRepr ret)
       $ "Checking return type for method " ++ mname
            
     runMethodHandle sym p halloc ctx (J.className mcls) h args


failIfNotEqual :: forall f m a (b :: k).
                  (Monad m, Show (f a),
                    Show (f b), TestEquality f) => f a -> f b -> String -> m (a :~: b)
failIfNotEqual r1 r2 str
  | Just Refl <- testEquality r1 r2 = return Refl
  | otherwise = fail $ str ++ ": mismatch between " ++ show r1 ++ " and " ++ show r2 


-- 
setSimulatorVerbosity :: (W4.IsSymExprBuilder sym) => Int -> sym -> IO ()
setSimulatorVerbosity verbosity sym = do
  verbSetting <- W4.getOptionSetting W4.verbosity (W4.getConfiguration sym)
  _ <- W4.setOpt verbSetting (toInteger verbosity)
  return ()


findMethodHandle :: JVMContext -> J.Class -> J.Method -> IO JVMHandleInfo
findMethodHandle ctx cls meth =
    case  Map.lookup (J.className cls, J.methodKey meth) (methodHandles ctx) of
        Just handle ->
          return handle
        Nothing ->
          fail $ "BUG: cannot find handle for " ++ J.unClassName (J.className cls)
               ++ "/" ++ J.methodName meth

runClassInit :: HandleAllocator RealWorld -> JVMContext -> J.ClassName
             -> C.OverrideSim p sym JVM rtp a r (C.RegEntry sym C.UnitType)
runClassInit halloc ctx name = do
  (C.SomeCFG g') <- liftIO $ stToIO $ do
      h <- mkHandle halloc "class_init"
      let (meth :: J.Method) = undefined
          def :: FunctionDef JVM s (JVMState UnitType) EmptyCtx UnitType
          def _inputs = (s, f)
              where s = initialState ctx meth knownRepr
                    f = do () <- initializeClass name
                           return (App EmptyApp)
      (SomeCFG g, []) <- defineFunction InternalPos h def
      return (toSSA g)
  C.callCFG g' (C.RegMap Ctx.Empty)
  
-- | Run a Java method in the simulator
runMethodHandle :: (IsSymInterface sym,
                    W4.SymInterpretedFloatType sym W4.SingleFloat ~ C.BaseRealType,
                    W4.SymInterpretedFloatType sym W4.DoubleFloat ~ C.BaseRealType) =>
                     sym
                  -> p
                  -> HandleAllocator RealWorld
                  -> JVMContext
                  -> J.ClassName
                  -> FnHandle args ret
                  -> C.RegMap sym args
                  -> IO (C.ExecResult p sym JVM (C.RegEntry sym ret))
runMethodHandle sym p halloc ctx classname h args = do
  let javaExtImpl :: C.ExtensionImpl p sym JVM
      javaExtImpl = C.ExtensionImpl (\_sym _iTypes _logFn _f x -> case x of) (\x -> case x of)
  let simctx = C.initSimContext sym
                 MapF.empty  -- intrinsics
                 halloc
                 stdout
                 (mkDelayedBindings ctx)
                 javaExtImpl
                 p
  let globals = C.insertGlobal (dynamicClassTable ctx) Map.empty C.emptyGlobals     
  let simSt  = C.initSimState simctx globals C.defaultAbortHandler
  let fnCall = C.regValue <$> C.callFnVal (C.HandleFnVal h) args
  let overrideSim = do _ <- runStateT (mapM_ register_jvm_override stdOverrides) ctx
                       _ <- runClassInit halloc ctx classname
                       fnCall
  C.executeCrucible simSt (C.runOverrideSim (handleReturnType h) overrideSim)


      
      




-- | A type class for what we need from a java code base This is here
-- b/c we have two copies of the Codebase module, the one in this
-- package and the one in the jvm-verifier package. Eventually,
-- saw-script will want to transition to the code base in this package,
-- but it will need to eliminate uses of the old jvm-verifier first.
class IsCodebase cb where
 
   lookupClass :: cb -> J.ClassName -> IO J.Class

   findMethod :: cb -> String -> J.Class -> IO (J.Class,J.Method)

   findClass  :: cb -> String -> IO J.Class
   findClass cb cname = (lookupClass cb . J.mkClassName . J.dotsToSlashes) cname

------------------------------------------------------------------------
-- * utility operations for working with the java code base
-- Some of these are from saw-script util

instance IsCodebase JCB.Codebase where

   lookupClass = cbLookupClass 

   -- | Returns method with given name in this class or one of its subclasses.
   -- Throws an ExecException if method could not be found or is ambiguous.
   -- findMethod :: JCB.Codebase -> String -> J.Class -> IO (J.Class, J.Method)
   findMethod cb nm initClass = impl initClass
    where javaClassName = J.slashesToDots (J.unClassName (J.className initClass))
          methodMatches m = J.methodName m == nm && not (J.methodIsAbstract m)
          impl cl =
            case filter methodMatches (J.classMethods cl) of
              [] -> do
                case J.superClass cl of
                  Nothing ->
                    let msg = ftext $ "Could not find method " ++ nm
                                ++ " in class " ++ javaClassName ++ "."
                        res = "Please check that the class and method are correct."
                     in throwIOExecException msg res
                  Just superName ->
                    impl =<< cbLookupClass cb superName
              [method] -> return (cl,method)
              _ -> let msg = "The method " ++ nm ++ " in class " ++ javaClassName
                               ++ " is ambiguous.  SAWScript currently requires that "
                               ++ "method names are unique."
                       res = "Please rename the Java method so that it is unique."
                    in throwIOExecException (ftext msg) res


-- | Atempt to find class with given name, or throw ExecException if no class
-- with that name exists. Class name should be in slash-separated form.
cbLookupClass :: JCB.Codebase -> J.ClassName -> IO J.Class
cbLookupClass cb nm = do
  maybeCl <- JCB.tryLookupClass cb nm
  case maybeCl of
    Nothing -> do
     let msg = ftext ("The Java class " ++ J.slashesToDots (J.unClassName nm) ++ " could not be found.")
         res = "Please check that the --classpath and --jars options are set correctly."
      in throwIOExecException msg res
    Just cl -> return cl



throwFieldNotFound :: J.Type -> String -> IO a
throwFieldNotFound tp fieldName = throwE msg
  where
    msg = "Values with type \'" ++ show tp ++
          "\' do not contain field named " ++
          fieldName ++ "."

-- | Throw exec exception in a MonadIO.
throwIOExecException :: String -> String -> IO a
throwIOExecException errorMsg resolution = liftIO $ throwE $ errorMsg ++ "\n" ++ resolution
          

findField :: JCB.Codebase -> J.Type -> String -> IO J.FieldId
findField _  tp@(J.ArrayType _) nm = throwFieldNotFound tp nm
findField cb tp@(J.ClassType clName) nm = impl =<< (cbLookupClass cb clName)
  where
    impl cl =
      case filter (\f -> J.fieldName f == nm) $ J.classFields cl of
        [] -> do
          case J.superClass cl of
            Nothing -> throwFieldNotFound tp nm
            Just superName -> impl =<< (cbLookupClass cb  superName)
        [f] -> return $ J.FieldId (J.className cl) nm (J.fieldType f)
        _ -> throwE $
             "internal: Found multiple fields with the same name: " ++ nm
findField  _ _ _ =
  throwE "Primitive types cannot be dereferenced."


getGlobalPair ::
  C.PartialResult sym ext v ->
  IO (C.GlobalPair sym v)
getGlobalPair pr =
  case pr of
    C.TotalRes gp -> return gp
    C.PartialRes _ gp _ -> do
      putStrLn "Symbolic simulation completed with side conditions."
      return gp


ftext :: String -> String
ftext = id

throwE :: String -> IO a
throwE = fail
