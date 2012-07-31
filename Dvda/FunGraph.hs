{-# OPTIONS_GHC -Wall #-}
{-# Language TypeOperators #-}
{-# Language TypeFamilies #-}
{-# Language FlexibleInstances #-}

module Dvda.FunGraph ( FunGraph
                     , ToFunGraph
                     , NumT
                     , (:*)(..)
                     , MVS(..)
                     , toFunGraph
                     , countNodes
                     , fgInputs
                     , fgOutputs
                     , fgLookupGExpr
                     , topSort
                     , fgGraph
                     , previewGraph
                     ) where

import Control.Applicative
import Control.Concurrent ( threadDelay )
import Data.Foldable ( Foldable )
import qualified Data.Foldable as F
import qualified Data.Graph as Graph
import Data.Hashable ( Hashable )
import qualified Data.HashSet as HS
import Data.Traversable ( Traversable )
import qualified Data.Traversable as T
import Data.GraphViz ( Labellable, toLabelValue, preview )
import Data.GraphViz.Attributes.Complete ( Label )
import qualified Data.Graph.Inductive as FGL

import Dvda.Expr
import Dvda.Reify ( ReifyGraph(..), reifyGraphs )


data FunGraph a = FunGraph { fgGraph :: Graph.Graph
                           , fgInputs :: [MVS (GExpr a Int)]
                           , fgOutputs :: [MVS Int]
                           , fgReified :: [(Int, GExpr a Int)]
                           , fgLookupGExpr :: (Int -> Maybe (GExpr a Int))
                           , fgVertexFromKey :: Int -> Maybe Int
                           , fgNodeFromVertex :: Int -> (GExpr a Int, Int, [Int])
                           }
instance Show a => Show (FunGraph a) where
  show fg = "FunGraph\ninputs:\n" ++ show (fgInputs fg) ++ "\noutputs:\n" ++ show (fgOutputs fg) ++ "\ngraph:\n" ++ show (fgGraph fg)

---- | matrix or vector or scalar
data MVS a = Mat [[a]] | Vec [a] | Sca a deriving Show

instance Functor MVS where
  fmap f (Sca x)  = Sca (f x)
  fmap f (Vec xs) = Vec (map f xs)
  fmap f (Mat xs) = Mat (map (map f) xs)

instance Foldable MVS where
  foldr f x0 (Sca x)  = foldr f x0 [x]
  foldr f x0 (Vec xs) = foldr f x0 xs
  foldr f x0 (Mat xs) = foldr f x0 (concat xs)

instance Traversable MVS where
  traverse f (Sca x)  = Sca <$> f x
  traverse f (Vec xs) = Vec <$> T.traverse f xs
  traverse f (Mat xs) = Mat <$> T.traverse (T.traverse f) xs

class ToFunGraph a where
  type NumT a
  toMVSList :: a -> [MVS (Expr (NumT a))]
instance ToFunGraph (Expr a) where
  type NumT (Expr a) = a
  toMVSList x = [Sca x]
instance ToFunGraph [Expr a] where
  type NumT [Expr a] = NumT (Expr a)
  toMVSList x = [Vec x]
instance ToFunGraph [[Expr a]] where
  type NumT [[Expr a]] = NumT [Expr a]
  toMVSList x = [Mat x]

data a :* b = a :* b deriving Show
infixr 6 :*
instance (ToFunGraph a, ToFunGraph b, NumT a ~ NumT b) => ToFunGraph (a :* b) where
  type NumT (a :* b) = NumT a
  toMVSList (x :* y) = toMVSList x ++ toMVSList y

-- | find any symbols which are parents of outputs, but are not supplied by the user
detectMissingInputs :: (Eq a, Hashable a, Show a) => [MVS (Expr a)] -> [(Int,GExpr a Int)] -> [GExpr a Int]
detectMissingInputs exprs gr = HS.toList $ HS.difference allGraphInputs allUserInputs
  where
    allUserInputs = let f (ESym name) acc = (GSym name):acc
                        f _ e = error $ "detectMissingInputs given non-ESym input \"" ++ show e ++ "\""
                    in HS.fromList $ foldr f [] (concatMap F.toList exprs)

    allGraphInputs = let f (_,(GSym name)) acc = (GSym name):acc
                         f _ acc = acc
                     in HS.fromList $ foldr f [] gr

-- | if the same input symbol (like ESym "x") is given at two different places throw an exception
findConflictingInputs :: (Eq a, Hashable a, Show a) => [MVS (Expr a)] -> [Expr a]
findConflictingInputs exprs = HS.toList redundant
  where
    redundant = snd $ foldl f (HS.empty, HS.empty) (concatMap F.toList exprs)
      where
        f (knownExprs, redundantExprs) expr@(ESym _)
          | HS.member expr knownExprs = (knownExprs, HS.insert expr redundantExprs)
          | otherwise = (HS.insert expr knownExprs, redundantExprs)
        f _ e = error $ "findConflictingInputs saw non-ESym input \"" ++ show e ++ "\""


-- | Take inputs and outputs which are of classes ToFunGraph (heterogenous lists of @Expr a@)
--   and traverse the outputs reifying all expressions and creating a hashmap of StableNames (stable pointers).
--   Once the hashmap is created, lookup the provided inputs and return a FunGraph which contains an
--   expression graph, input/output indices, and other useful functions. StableNames is non-deterministic
--   so this function may return graphs with more or fewer CSE's eliminated.
--   If CSE is then performed on the graph, the result is deterministic.
toFunGraph :: (Eq a, Hashable a, Show a, ToFunGraph b, ToFunGraph c, NumT b ~ a, NumT c ~ a)
              => b -> c -> IO (FunGraph a)
toFunGraph inputs outputs = mvsToFunGraph (toMVSList inputs) (toMVSList outputs)

mvsToFunGraph :: (Eq a, Hashable a, Show a) => [MVS (Expr a)] -> [MVS (Expr a)] -> IO (FunGraph a)
mvsToFunGraph inputMVSExprs outputMVSExprs = do
  -- reify the outputs
  (ReifyGraph rgr, outputMVSIndices) <- reifyGraphs outputMVSExprs
      -- make sure all the inputs are symbolic, and find their indices in the Expr graph
  let inputMVSIndices = map (fmap f) inputMVSExprs
        where
          f (ESym name) = (GSym name)
          f x = error $ "ERROR: mvsToFunGraph given non-ESym input \"" ++ show x ++ "\""
      
      (gr, lookupVertex, lookupKey) = Graph.graphFromEdges $ map (\(k,gexpr) -> (gexpr, k, getParents gexpr)) rgr
      lookupG k = (\(g,_,_) -> g) <$> lookupVertex <$> lookupKey k

  -- make sure all inputs to graph are provided by user
  return $ case (detectMissingInputs inputMVSExprs rgr, findConflictingInputs inputMVSExprs) of
    ([],[]) -> FunGraph { fgGraph = gr
                        , fgInputs = inputMVSIndices
                        , fgOutputs = outputMVSIndices
                        , fgLookupGExpr = lookupG
                        , fgReified = rgr
                        , fgVertexFromKey = lookupKey
                        , fgNodeFromVertex = lookupVertex
                        }
    (xs,[]) -> error $ "mvsToFunGraph found inputs that were not provided by the user: " ++ show xs
    ( _,xs) -> error $ "mvsToFunGraph found idential inputs set more than once: " ++ show xs


---------------------------------- utilities -----------------------------
countNodes :: FunGraph a -> Int
countNodes = length . Graph.vertices . fgGraph

topSort :: FunGraph a -> [Int]
topSort fg = map ((\(_,k,_) -> k) . (fgNodeFromVertex fg)) $ Graph.topSort (fgGraph fg)

---------------------------------- draw ------------------------------------
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

run :: IO ()
run = do
  let x = sym "x" :: Expr Double
--      y = sym "y"
--      z = sym "z"
--
--      a0 = x + y + z
--      a1 = x*a0/z
--      a2 = a1 + a0/y

      inputs = x -- :* [y] :* [[z]]
      outputs = x*x -- a1 :* a0 :* [[a2]]
  fg <- toFunGraph inputs outputs
  print $ fgReified fg
  print $ topSort fg
  previewGraph fg