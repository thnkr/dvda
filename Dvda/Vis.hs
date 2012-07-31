{-# OPTIONS_GHC -Wall #-}
{-# Language TypeOperators #-}
{-# Language TypeFamilies #-}
{-# Language FlexibleInstances #-}

module Dvda.Vis ( previewGraph
                ) where

import Control.Concurrent ( threadDelay )
import Data.GraphViz ( Labellable, toLabelValue, preview )
import Data.GraphViz.Attributes.Complete ( Label )
import qualified Data.Graph.Inductive as FGL

import Dvda.Expr
import Dvda.FunGraph

previewGraph :: Show a => FunGraph a -> IO ()
previewGraph fg = do
  preview $ toFGLGraph fg
  threadDelay 10000

toFGLGraph :: FunGraph a -> FGL.Gr (FGLNode a) (FGLEdge a)
toFGLGraph fg = FGL.mkGraph fglNodes fglEdges
  where
    fglNodes = map (\(k,gexpr) -> (k, FGLNode (k, gexpr))) $ fgReified fg
    fglEdges = concatMap nodeToEdges $ fgReified fg
      where
        nodeToEdges (k,gexpr) = map (\p -> (p,k,FGLEdge (p,k,gexpr))) (getParents gexpr)

data FGLNode a = FGLNode (Int, GExpr a Int)
data FGLEdge a = FGLEdge (Int, Int, GExpr a Int)
instance Eq (FGLEdge a) where
  (==) (FGLEdge (p0,k0,_)) (FGLEdge (p1,k1,_)) = (==) (p0,k0) (p1,k1)
instance Ord (FGLEdge a) where
  compare (FGLEdge (p0,k0,_)) (FGLEdge (p1,k1,_)) = compare (p0,k0) (p1,k1)

instance Labellable (FGLEdge a) where
  toLabelValue (FGLEdge (p,k,_)) = toLabelValue $ show p ++ " --> " ++ show k

tlv :: Int -> String -> Label
tlv k s = toLabelValue $ show k ++ ": " ++ s

instance Show a => Labellable (FGLNode a) where
  toLabelValue (FGLNode (k, (GSym s)))                       = tlv k (show s)
  toLabelValue (FGLNode (k, (GConst c)))                     = tlv k (show c)
  toLabelValue (FGLNode (k, (GNum (Mul _ _))))               = tlv k "*"
  toLabelValue (FGLNode (k, (GNum (Add _ _))))               = tlv k "+"
  toLabelValue (FGLNode (k, (GNum (Sub _ _))))               = tlv k "-"
  toLabelValue (FGLNode (k, (GNum (Negate _))))              = tlv k "-"
  toLabelValue (FGLNode (k, (GNum (Abs _))))                 = tlv k "abs"
  toLabelValue (FGLNode (k, (GNum (Signum _))))              = tlv k "signum"
  toLabelValue (FGLNode (k, (GNum (FromInteger x))))         = tlv k (show x)
  toLabelValue (FGLNode (k, (GFractional (Div _ _))))        = tlv k "/"
  toLabelValue (FGLNode (k, (GFractional (FromRational x)))) = tlv k (show (fromRational x :: Double))
  toLabelValue (FGLNode (k, (GFloating (Pow _ _))))          = tlv k "**"
  toLabelValue (FGLNode (k, (GFloating (LogBase _ _))))      = tlv k "logBase"
  toLabelValue (FGLNode (k, (GFloating (Exp _))))            = tlv k "exp"
  toLabelValue (FGLNode (k, (GFloating (Log _))))            = tlv k "log"
  toLabelValue (FGLNode (k, (GFloating (Sin _))))            = tlv k "sin"
  toLabelValue (FGLNode (k, (GFloating (Cos _))))            = tlv k "cos"
  toLabelValue (FGLNode (k, (GFloating (ASin _))))           = tlv k "asin"
  toLabelValue (FGLNode (k, (GFloating (ATan _))))           = tlv k "atan"
  toLabelValue (FGLNode (k, (GFloating (ACos _))))           = tlv k "acos"
  toLabelValue (FGLNode (k, (GFloating (Sinh _))))           = tlv k "sinh"
  toLabelValue (FGLNode (k, (GFloating (Cosh _))))           = tlv k "cosh"
  toLabelValue (FGLNode (k, (GFloating (Tanh _))))           = tlv k "tanh"
  toLabelValue (FGLNode (k, (GFloating (ASinh _))))          = tlv k "asinh"
  toLabelValue (FGLNode (k, (GFloating (ATanh _))))          = tlv k "atanh"
  toLabelValue (FGLNode (k, (GFloating (ACosh _))))          = tlv k "acosh"
