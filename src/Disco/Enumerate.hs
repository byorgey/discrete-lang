{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE TupleSections            #-}
{-# LANGUAGE TypeApplications         #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.Enumerate
-- Copyright   :  disco team and contributors
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Enumerate values inhabiting Disco types.
--
-----------------------------------------------------------------------------

module Disco.Enumerate
       (
         ValueEnumeration
         -- * Base types
         , enumVoid
         , enumUnit
         , enumBool
         , enumN
         , enumZ
         , enumF
         , enumQ
         , enumC

         -- * Containers
         , enumSet
        --  , enumBag
         , enumList

         -- * Any type
         , enumType
         , enumTypes

         -- * Lifted functions that return lists
         , enumerateType
         , enumerateTypes
       )
       where

import qualified Data.Enumeration.Invertible as E
import           Disco.AST.Generic           (Side (..))
import           Disco.Types
import           Disco.Value

type ValueEnumeration = E.IEnumeration Value

enumVoid :: ValueEnumeration
enumVoid = E.void

enumUnit :: ValueEnumeration
enumUnit = E.singleton VUnit

enumBool :: ValueEnumeration
enumBool = E.mapE toV fromV $ E.finiteList [L, R]
  where
    toV i = VInj i VUnit
    fromV (VInj i VUnit) = i
    fromV _              = error "enumBool.fromV: value isn't a bool"

-- | Unsafely extract the numeric value of a @Value@
--   (assumed to be a VNum).
valToRat :: Value -> Rational
valToRat (VNum _ r) = r
valToRat _          = error "valToRat: value isn't a number"

ratToVal :: Rational -> Value
ratToVal = VNum mempty

enumN :: ValueEnumeration
enumN = E.mapE (ratToVal . fromInteger) (floor . valToRat) E.nat

enumZ :: ValueEnumeration
enumZ = E.mapE (ratToVal . fromInteger) (floor . valToRat) E.int

enumF :: ValueEnumeration
enumF = E.mapE ratToVal valToRat E.cw

enumQ :: ValueEnumeration
enumQ = E.mapE ratToVal valToRat E.rat

enumC :: ValueEnumeration
enumC = E.mapE toV fromV (E.boundedEnum @Char)
  where
    toV   = ratToVal . fromIntegral . fromEnum
    fromV = toEnum . floor . valToRat

enumSet :: ValueEnumeration -> ValueEnumeration
enumSet e = E.mapE toV fromV (E.finiteSubsetOf e)
  where
    toV = VBag . map (,1)
    fromV (VBag vs) = map fst vs
    fromV _         = error "enumSet.fromV: value isn't a set"

enumList :: ValueEnumeration -> ValueEnumeration
enumList e = E.mapE toV fromV (E.listOf e)
  where
    toV = foldr VCons VNil
    fromV (VCons h t) = h : fromV t
    fromV VNil        = []
    fromV _           = error "enumList.fromV: value isn't a list"

enumFunction :: ValueEnumeration -> ValueEnumeration -> ValueEnumeration
enumFunction xs ys =
  case (E.card xs, E.card ys) of
    (E.Finite 0, _) -> E.singleton (VFun $ \_ -> error "enumFunction: void function called")
    (_, E.Finite 0) -> E.void
    (_, E.Finite 1) -> E.singleton (VFun $ \_ -> E.select ys 0)
    _               -> E.mapE toV fromV (E.functionOf xs ys)
  where
    toV = VFun
    fromV (VFun f) = f
    fromV _        = error "enumFunction.fromV: value isn't a VFun"

enumProd :: ValueEnumeration -> ValueEnumeration -> ValueEnumeration
enumProd xs ys = E.mapE toV fromV $ (E.><) xs ys
  where
    toV (x, y)        = VPair x y
    fromV (VPair x y) = (x, y)
    fromV _           = error "enumProd.fromV: value isn't a pair"

enumSum :: ValueEnumeration -> ValueEnumeration -> ValueEnumeration
enumSum xs ys = E.mapE toV fromV $ (E.<+>) xs ys
  where
    toV (Left x)  = VInj L x
    toV (Right y) = VInj R y
    fromV (VInj L x) = Left x
    fromV (VInj R y) = Right y
    fromV _          = error "enumSum.fromV: value isn't a sum"

enumType :: Type -> ValueEnumeration
enumType TyVoid     = enumVoid
enumType TyUnit     = enumUnit
enumType TyBool     = enumBool
enumType TyN        = enumN
enumType TyZ        = enumZ
enumType TyF        = enumF
enumType TyQ        = enumQ
enumType TyC        = enumC
enumType (TySet  t) = enumSet (enumType t)
enumType (TyList t) = enumList (enumType t)
enumType (a :*: b)  = enumProd (enumType a) (enumType b)
enumType (a :+: b)  = enumSum (enumType a) (enumType b)
enumType (a :->: b) = enumFunction (enumType a) (enumType b)
enumType ty         = error $ "enumType: can't enumerate " ++ show ty

enumTypes :: [Type] -> E.IEnumeration [Value]
enumTypes []     = E.singleton []
enumTypes (t:ts) = E.mapE toL fromL $ (E.><) (enumType t) (enumTypes ts)
  where
    toL (x, xs)  = x:xs
    fromL (x:xs) = (x, xs)
    fromL []     = error "enumTypes.fromL: empty list not in enumeration range"

enumerateType :: Type -> [Value]
enumerateType = E.enumerate . enumType

enumerateTypes :: [Type] -> [[Value]]
enumerateTypes = E.enumerate . enumTypes
