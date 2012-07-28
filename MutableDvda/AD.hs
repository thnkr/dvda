{-# OPTIONS_GHC -Wall #-}

module MutableDvda.AD ( backprop
                      , rad
                      ) where

import Data.HashMap.Lazy ( HashMap )
import qualified Data.HashMap.Lazy as HM
import Data.Hashable ( Hashable )

import Dvda.Dual hiding ( fad, fad' )

import MutableDvda.Expr

--fad :: Num a => (Dual a -> [Dual a]) -> a -> [a]
--fad f x = map dualPerturbation $ f (Dual x 1)

bpBinary :: (Eq a, Num a)
            => Expr a -> Expr a -> Expr a
            -> (Dual (Expr a) -> Dual (Expr a) -> Dual (Expr a))
            -> [(Expr a, Expr a)]
bpBinary sens g h binop = gsens ++ hsens
  where
    dfdg = dualPerturbation $ binop (Dual g 1) (Dual h 0)
    dfdh = dualPerturbation $ binop (Dual g 0) (Dual h 1)
    gsens = backpropNode (sens*dfdg) g
    hsens = backpropNode (sens*dfdh) h

bpUnary :: (Eq a, Num a)
           => Expr a -> Expr a
           -> (Dual (Expr a) -> Dual (Expr a))
           -> [(Expr a, Expr a)]
bpUnary sens g unop = backpropNode (sens*dfdg) g
  where
    dfdg = dualPerturbation $ unop (Dual g 1)

backpropNode :: Eq a => Expr a -> Expr a -> [(Expr a, Expr a)]
backpropNode sens e@(ESym _) = [(e,sens)]
backpropNode _ (EConst _) = []
backpropNode _ (ENum (FromInteger _)) = []
backpropNode _ (EFractional (FromRational _)) = []
backpropNode sens (ENum (Mul x y)) = bpBinary sens x y (*)
backpropNode sens (ENum (Add x y)) = bpBinary sens x y (+)
backpropNode sens (ENum (Sub x y)) = bpBinary sens x y (-)
backpropNode sens (ENum (Abs x))    = bpUnary sens x abs
backpropNode sens (ENum (Negate x)) = bpUnary sens x negate
backpropNode sens (ENum (Signum x)) = bpUnary sens x signum
backpropNode sens (EFractional (Div x y)) = bpBinary sens x y (/)
backpropNode sens (EFloating (Pow x y)) = bpBinary sens x y (**)
backpropNode sens (EFloating (LogBase x y)) = bpBinary sens x y logBase
backpropNode sens (EFloating (Exp x))   = bpUnary sens x exp
backpropNode sens (EFloating (Log x))   = bpUnary sens x log
backpropNode sens (EFloating (Sin x))   = bpUnary sens x sin
backpropNode sens (EFloating (Cos x))   = bpUnary sens x cos
backpropNode sens (EFloating (ASin x))  = bpUnary sens x asin
backpropNode sens (EFloating (ATan x))  = bpUnary sens x atan
backpropNode sens (EFloating (ACos x))  = bpUnary sens x acos
backpropNode sens (EFloating (Sinh x))  = bpUnary sens x sinh
backpropNode sens (EFloating (Cosh x))  = bpUnary sens x cosh
backpropNode sens (EFloating (Tanh x))  = bpUnary sens x tanh
backpropNode sens (EFloating (ASinh x)) = bpUnary sens x asinh
backpropNode sens (EFloating (ATanh x)) = bpUnary sens x atanh
backpropNode sens (EFloating (ACosh x)) = bpUnary sens x acosh
backpropNode sens (EGraphRef x _)       = backpropNode sens x

backprop :: (Num a, Eq a, Hashable a) => Expr a -> HashMap (Expr a) (Expr a)
backprop x = HM.fromListWith (+) (backpropNode 1 x)

rad :: (Num a, Eq a, Hashable a) => Expr a -> [Expr a] -> [Expr a]
rad x args = map (\arg -> HM.lookupDefault 0 arg sensitivities) args
  where
    sensitivities = backprop x
