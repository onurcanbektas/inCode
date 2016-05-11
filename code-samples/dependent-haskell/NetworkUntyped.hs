#!/usr/bin/env stack
-- stack --resolver lts-5.15 --install-ghc runghc --package hmatrix --package MonadRandom

{-# LANGUAGE BangPatterns     #-}
{-# LANGUAGE FlexibleContexts #-}

import Control.Monad
import Control.Monad.Random
import Data.List
import Data.Maybe
import Numeric.LinearAlgebra
import System.Environment
import Text.Read

data Weights = W { wBiases :: !(Vector Double)
                 , wNodes  :: !(Matrix Double)
                 }
  deriving (Show, Eq)

data Network = O !Weights
             | !Weights :&~ !Network
  deriving (Show, Eq)
infixr 5 :&~

logistic :: Floating a => a -> a
logistic x = 1 / (1 + exp (-x))

logistic' :: Floating a => a -> a
logistic' x = logix * (1 - logix)
  where
    logix = logistic x

runLayer :: Weights -> Vector Double -> Vector Double
runLayer (W wB wN) v = wB + wN #> v

runNet :: Network -> Vector Double -> Vector Double
runNet (O w)      !v = logistic (runLayer w v)
runNet (w :&~ n') !v = let v' = logistic (runLayer w v)
                       in  runNet n' v'

randomWeights :: MonadRandom m => Int -> Int -> m Weights
randomWeights i o = do
    s1 <- getRandom
    s2 <- getRandom
    let wB = randomVector s1 Uniform o * 2 - 1
        wN = uniformSample s2 o (replicate i (-1, 1))
    return $ W wB wN

randomNet :: MonadRandom m => Int -> [Int] -> Int -> m Network
randomNet i [] o     =     O <$> randomWeights i o
randomNet i (h:hs) o = (:&~) <$> randomWeights i h <*> randomNet h hs o

train
    :: Double           -- ^ learning rate
    -> Vector Double    -- ^ input vector
    -> Vector Double    -- ^ target vector
    -> Network          -- ^ network to train
    -> Network
train rate x0 target = fst . go x0
  where
    -- | Recursively trains the network, starting from the outer layer and
    -- building up to the input layer.  Returns the updated network as well
    -- as the list of derivatives to use for calculating the gradient at
    -- the next layer up.
    go  :: Vector Double    -- ^ input vector
        -> Network          -- ^ network to train
        -> (Network, Vector Double)
    go !x (O w@(W wB wN))
        = let y    = runLayer w x
              o    = logistic y
              dEdy = logistic' y * (o - target)
              wB'  = wB - scale rate dEdy
              wN'  = wN - scale rate (dEdy `outer` x)
              w'   = W wB' wN'
              dWs  = tr wN #> dEdy
          in  (O w', dWs)
    go !x (w@(W wB wN) :&~ n)
        = let y          = runLayer w x
              o          = logistic y
              (n', dWs') = go o n
              dEdy       = logistic' y * dWs'
              wB'        = wB - scale rate dEdy
              wN'        = wN - scale rate (dEdy `outer` x)
              w'         = W wB' wN'
              dWs        = tr wN #> dEdy
          in  (w' :&~ n', dWs)

netTest :: MonadRandom m => Double -> Int -> m String
netTest rate n = do
    inps <- replicateM n $ do
      s <- getRandom
      return $ randomVector s Uniform 2 * 2 - 1
    let outs = flip map inps $ \v ->
                 if v `inCircle` (fromRational 0.33, 0.33)
                      || v `inCircle` (fromRational (-0.33), 0.33)
                   then fromRational 1
                   else fromRational 0
    net0 <- randomNet 2 [16,8] 1
    let trained = foldl' trainEach net0 (zip inps outs)
          where
            trainEach :: Network -> (Vector Double, Vector Double) -> Network
            trainEach nt (i, o) = train rate i o nt

        outMat = [ [ render (norm_2 (runNet trained (vector [x / 25 - 1,y / 10 - 1])))
                   | x <- [0..50] ]
                 | y <- [0..20] ]
        render n | n <= 0.2  = ' '
                 | n <= 0.4  = '.'
                 | n <= 0.6  = '-'
                 | n <= 0.8  = '='
                 | otherwise = '#'

    return $ unlines outMat
  where
    inCircle :: Vector Double -> (Vector Double, Double) -> Bool
    v `inCircle` (o, r) = norm_2 (v - o) <= r

main :: IO ()
main = do
    args <- getArgs
    let n    = readMaybe =<< (args !!? 0)
        rate = readMaybe =<< (args !!? 1)
    putStrLn "Training network..."
    putStrLn =<< evalRandIO (netTest (fromMaybe 0.25   rate)
                                     (fromMaybe 500000 n   )
                            )

(!!?) :: [a] -> Int -> Maybe a
[]     !!? _ = Nothing
(x:_ ) !!? 0 = Just x
(x:xs) !!? n = xs !!? (n - 1)