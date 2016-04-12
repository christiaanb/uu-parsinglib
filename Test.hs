{-# LANGUAGE RankNTypes #-}

data T a b = MkT a b

class C a where
  mkC :: a

type B a = forall b . C b => T a b
