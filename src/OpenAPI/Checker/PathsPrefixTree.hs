{-# LANGUAGE QuantifiedConstraints #-}

module OpenAPI.Checker.PathsPrefixTree
  ( PathsPrefixTree
  , empty
  , singleton
  , fromList
  , null
  , foldWith
  , toList
  , filter
  , embed
  )
where

import Data.Aeson
import Data.Foldable hiding (null, toList)
import qualified Data.HashMap.Strict as HM
import Data.Kind
import qualified Data.Map as M
import Data.Monoid
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Type.Equality
import qualified Data.TypeRepMap as TRM
import qualified Data.Vector as V
import qualified GHC.Exts as TRM
import OpenAPI.Checker.Paths
import Type.Reflection
import Prelude hiding (filter, null)

-- | A list of @AnItem r f@, but optimized into a prefix tree.
data PathsPrefixTree (q :: k -> k -> Type) (f :: k -> Type) (r :: k) = PathsPrefixTree
  { rootItems :: !(ASet (f r))
  , snocItems :: !(TRM.TypeRepMap (AStep q f r))
  }

instance (forall a. ToJSON (f a)) => ToJSON (PathsPrefixTree q f r) where
  toJSON =
    Object . getMergableObject
      . foldWith (\t x -> MergableObject . traceObject t $ toJSON x)

deriving instance Eq (PathsPrefixTree q f a)

-- Kind of orphan. Treat the map as an infinite tuple of @Maybe (f a)@'s, where
-- the components are ordered by the @SomeTypeRep@ of the @a@.
compareTRM
  :: (forall a. Typeable a => Ord (f a))
  => TRM.TypeRepMap f
  -> TRM.TypeRepMap f
  -> Ordering
compareTRM s1 s2 =
  foldMap (\k -> compareMaybe compareW (M.lookup k m1) (M.lookup k m2)) mKeys
  where
    (m1, m2) = (toMap s1, toMap s2)
    mKeys = S.toAscList $ M.keysSet m1 `S.union` M.keysSet m2
    compareMaybe _ Nothing Nothing = EQ
    compareMaybe _ Nothing (Just _) = LT
    compareMaybe _ (Just _) Nothing = GT
    compareMaybe cmp (Just x) (Just y) = cmp x y
    compareW
      :: (forall a. Typeable a => Ord (f a))
      => TRM.WrapTypeable f
      -> TRM.WrapTypeable f
      -> Ordering
    compareW (TRM.WrapTypeable (x :: f a)) (TRM.WrapTypeable (y :: f b))
      | Just Refl <- testEquality (typeRep @a) (typeRep @b) = compare x y
      | otherwise = EQ -- unreachable
    toMap s =
      M.fromList
        [(someTypeRep x, w) | w@(TRM.WrapTypeable x) <- TRM.toList s]

instance Ord (PathsPrefixTree q f a) where
  compare (PathsPrefixTree r1 s1) (PathsPrefixTree r2 s2) =
    compare r1 r2 <> compareTRM s1 s2

data ASet (a :: Type) where
  AnEmptySet :: ASet a
  ASet :: Ord a => S.Set a -> ASet a

instance ToJSON a => ToJSON (ASet a) where
  toJSON =
    toJSON . \case
      AnEmptySet -> S.empty
      ASet s -> s

instance Semigroup (ASet a) where
  AnEmptySet <> s = s
  s <> AnEmptySet = s
  ASet s1 <> ASet s2 = ASet $ S.union s1 s2

deriving instance Eq (ASet a)

deriving instance Ord (ASet a)

-- type traceprefixset = traceprefixtree proxy

instance Monoid (ASet a) where
  mempty = AnEmptySet

data AStep (q :: k -> k -> Type) (f :: k -> Type) (r :: k) (a :: k) where
  AStep
    :: NiceQuiver q r a =>
    !(M.Map (q r a) (PathsPrefixTree q f a))
    -> AStep q f r a

deriving instance Eq (AStep q f r a)

deriving instance Ord (AStep q f r a)

singleton :: AnItem q f r -> PathsPrefixTree q f r
singleton (AnItem ys v) = go ys $ PathsPrefixTree (ASet $ S.singleton v) TRM.empty
  where
    go :: Paths q r a -> PathsPrefixTree q f a -> PathsPrefixTree q f r
    go Root !t = t
    go (Snoc xs x) !t =
      go xs $
        PathsPrefixTree AnEmptySet $
          TRM.one $
            AStep $ M.singleton x t

instance Semigroup (PathsPrefixTree q f r) where
  PathsPrefixTree r1 s1 <> PathsPrefixTree r2 s2 =
    PathsPrefixTree (r1 <> r2) (TRM.unionWith joinSteps s1 s2)
    where
      joinSteps (AStep m1) (AStep m2) = AStep $ M.unionWith (<>) m1 m2

instance Monoid (PathsPrefixTree q f r) where
  mempty = PathsPrefixTree mempty TRM.empty

empty :: PathsPrefixTree q f r
empty = mempty

fromList :: [AnItem q f r] -> PathsPrefixTree q f r
fromList = foldMap singleton

null :: PathsPrefixTree q f r -> Bool
null (PathsPrefixTree AnEmptySet s) = TRM.size s == 0
null _ = False

foldWith
  :: forall q f m r.
  Monoid m
  => (forall a. Ord (f a) => Paths q r a -> f a -> m)
  -> PathsPrefixTree q f r
  -> m
foldWith k = goTPT Root
  where
    goTPT :: forall a. Paths q r a -> PathsPrefixTree q f a -> m
    goTPT xs t = goASet xs (rootItems t) <> goTRM xs (snocItems t)
    goASet :: forall a. Paths q r a -> ASet (f a) -> m
    goASet _ AnEmptySet = mempty
    goASet xs (ASet rs) = foldMap (k xs) rs
    goTRM :: forall a. Paths q r a -> TRM.TypeRepMap (AStep q f a) -> m
    goTRM xs s = foldMap (\(TRM.WrapTypeable f) -> goAStep xs f) $ TRM.toList s
    goAStep :: forall a b. Paths q r a -> AStep q f a b -> m
    goAStep xs (AStep m) =
      M.foldrWithKey (\x t -> (goTPT (Snoc xs x) t <>)) mempty m

toList :: PathsPrefixTree q f r -> [AnItem q f r]
toList t = appEndo (foldWith (\xs f -> Endo (AnItem xs f :)) t) []

-- | Select a subtree by prefix
filter :: Paths q r a -> PathsPrefixTree q f r -> PathsPrefixTree q f a
filter Root t = t
filter (Snoc xs x) t =
  foldMap (\(AStep m) -> fold $ M.lookup x m) $
    TRM.lookup $ snocItems $ filter xs t

-- | Embed a subtree in a larger tree with given prefix
embed :: Paths q r a -> PathsPrefixTree q f a -> PathsPrefixTree q f r
embed Root t = t
embed (Snoc xs x) t = embed xs $ PathsPrefixTree AnEmptySet $ TRM.one $ AStep $ M.singleton x t

newtype MergableObject = MergableObject {getMergableObject :: Object}

instance Semigroup MergableObject where
  (MergableObject x) <> (MergableObject y) =
    MergableObject $ HM.unionWith mergeValue x y
    where
      mergeValue :: Value -> Value -> Value
      mergeValue (Object a) (Object b) =
        Object . getMergableObject $ MergableObject a <> MergableObject b
      mergeValue (Array a) (Array b) = Array $ a <> b
      mergeValue (Array a) b = Array $ V.snoc a b
      mergeValue a (Array b) = Array $ V.cons a b
      mergeValue a b = toJSON [a, b]

instance Monoid MergableObject where
  mempty = MergableObject mempty

traceObject :: Paths q r a -> Value -> Object
traceObject Root (Object o) = o
traceObject Root v = HM.singleton "root" v
traceObject (root `Snoc` s) v =
  traceObject root . Object $ HM.singleton (T.pack . show $ s) v