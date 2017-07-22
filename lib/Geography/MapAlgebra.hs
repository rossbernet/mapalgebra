{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DataKinds, KindSignatures, ScopedTypeVariables #-}
-- {-# LANGUAGE Strict #-}  -- Does this improve performance?

-- |
-- Module    : Geography.MapAlgebra
-- Copyright : (c) Colin Woodbury, 2017
-- License   : BSD3
-- Maintainer: Colin Woodbury <colingw@gmail.com>
--
-- This library is an implementation of /Map Algebra/ as described in the
-- book /GIS and Cartographic Modeling/ (GaCM) by Dana Tomlin. The fundamental
-- primitive is the `Raster`, a rectangular grid of data that usually describes
-- some area on the earth. A `Raster` need not contain numerical data, however,
-- and need not just represent satellite imagery. It is essentially a matrix,
-- which of course forms a `Functor`, and thus is available for all the
-- operations we would expect to run on any Functor. /GIS and Cartographic Modeling/
-- doesn't lean on this fact, and so describes many seemingly custom
-- operations which to Haskell are just applications of `fmap` or `zipWith`
-- with pure functions.
--
-- Here are the main classes of operations ascribed to /Map Algebra/ and their
-- corresponding approach in Haskell:
--
-- * Single-Raster /Local Operations/ -> `fmap` with pure functions
-- * Multi-Raster /Local Operations/ -> `foldl` with `zipWith` and pure functions
-- * /Focal Operations/ -> Called /convolution/ elsewhere; 'repa' has support for this (described below)
-- * /Zonal Operations/ -> ??? TODO
--
-- Whether it is meaningful to perform operations between two given
-- `Raster`s (i.e. whether the Rasters properly overlap on the earth) is not
-- handled in this library and is left to the application.

{- TODO

Benchmark against numpy as well as GT's collections API
Checkout `repa-io`

-}

module Geography.MapAlgebra
  (
    -- * Types
    Raster(..)
  , constant, fromUnboxed
  , Projection(..)
  , reproject
  , Sphere, LatLng, WebMercator
  , Point(..)
  , Focal(..)
  -- * Map Algebra
  -- ** Local Operations
  -- | Operations between `Raster`s. If the source Rasters aren't the
  -- same size, the size of the result will be their intersection. All operations
  -- are element-wise:
  --
  -- @
  -- 1 1 + 2 2  ==  3 3
  -- 1 1   2 2      3 3
  --
  -- 2 2 * 3 3  ==  6 6
  -- 2 2   3 3      6 6
  -- @
  --
  -- If an operation you need isn't available here, use our `zipWith`:
  --
  -- @
  -- zipWith :: (a -> b -> d) -> Raster p r c a -> Raster p r c b -> Raster p r c d
  --
  -- -- Your operation, which you should INLINE and use bang patterns with.
  -- foo :: Int -> Int -> Int
  --
  -- bar :: Projection p => Raster p r c Int -> Raster p r c Int -> Raster p r c Int
  -- bar a b = zipWith foo a b
  -- @
  , zipWith
  -- *** Unary
  -- | If you want to do simple unary @Raster -> Raster@ operations (called
  -- /LocalCalculation/ in GaCM), `Raster` is a `Functor` so you can use
  -- `fmap` as normal:
  --
  -- @
  -- myRaster :: Raster p r c Int
  -- abs :: Num a => a -> a
  --
  -- -- Absolute value of all values in the Raster.
  -- fmap abs myRaster
  -- @
  , classify
  -- *** Binary
  -- | You can safely use these with the `foldl` family on any `Foldable` of
  -- `Raster`s. You would likely want @foldl1'@ which is provided by both List
  -- and Vector. Keep in mind that `Raster` has a `Num` instance, so you can use
  -- all the normal math operators with them as well.
  , min, max
  -- *** Other
  -- | There is no binary form of these functions that exists without
  -- producing numerical error,  so you can't use the `foldl` family with these.
  -- Consider the average operation, where the following is /not/ true:
  -- \[
  --    \forall abc \in \mathbb{R}. \frac{\frac{a + b}{2} + c}{2} = \frac{a + b + c}{3}
  -- \]
  , mean, variety, majority, minority, variance
  -- ** Focal Operations
  -- | Operations on one `Raster`, given some polygonal neighbourhood.
  , fsum, fmean, fmax, fmin, fvariety
  ) where

import           Data.Array.Repa ((:.)(..), Z(..))
import qualified Data.Array.Repa as R
import qualified Data.Array.Repa.Stencil as R
import qualified Data.Array.Repa.Stencil.Dim2 as R
import           Data.Bits
import           Data.Bits.Floating
import           Data.Foldable
import           Data.Int
import qualified Data.List as L
import           Data.List.NonEmpty (NonEmpty(..), nub)
import qualified Data.Map.Strict as M
import           Data.Proxy (Proxy(..))
import           Data.Semigroup
import qualified Data.Vector.Unboxed as U
import           Data.Word
import           GHC.TypeLits
import qualified Prelude as P
import           Prelude hiding (div, min, max, zipWith)

--

-- | A location on the Earth in some `Projection`.
data Point p a = Point { x :: a, y :: a } deriving (Eq, Show)

-- | The Earth is not a sphere. Various schemes have been invented
-- throughout history that provide `Point` coordinates for locations on the
-- earth, although all are approximations and come with trade-offs. We call
-- these "Projections", since they are a mapping of `Sphere` coordinates to
-- some other approximation. The Projection used most commonly for mapping on
-- the internet is called `WebMercator`.
--
-- A Projection is also known as a Coordinate Reference System (CRS).
--
-- Use `reproject` to convert `Point`s between various Projections.
class Projection p where
  -- | Convert a `Point` in this Projection to one of radians on a perfect `Sphere`.
  toSphere :: Point p Double -> Point Sphere Double

  -- | Convert a `Point` of radians on a perfect sphere to that of a specific Projection.
  fromSphere :: Point Sphere Double -> Point p Double

-- | Reproject a `Point` from one `Projection` to another.
reproject :: (Projection p, Projection r) => Point p Double -> Point r Double
reproject = fromSphere . toSphere

-- | A perfect geometric sphere. The earth isn't actually shaped this way,
-- but it's a convenient middle-ground for converting between various
-- `Projection`s.
data Sphere

instance Projection Sphere where
  toSphere = id
  fromSphere = id

data LatLng

instance Projection LatLng where
  toSphere = undefined
  fromSphere = undefined

-- | The most commonly used `Projection` for mapping in internet applications.
data WebMercator

instance Projection WebMercator where
  toSphere = undefined
  fromSphere = undefined

-- | A rectangular grid of data representing some area on the earth.
--
-- * @p@: What `Projection` is this Raster in?
-- * @r@: How many rows does this Raster have?
-- * @c@: How many columns does this Raster have?
-- * @a@: What data type is held in this Raster?
--
-- By having explicit p, r, and c, we make impossible any operation between
-- two Rasters of differing size or projection. Conceptually, we consider
-- Rasters of different size and projection to be /entirely different types/.
-- Example:
--
-- @
-- -- | A lazy 256x256 Raster with the value 5 at every index. Uses DataKinds
-- -- and "type literals" to achieve the same-size guarantee.
-- myRaster :: Raster WebMercator 256 256 Int
-- myRaster = constant 5
--
-- >>> length myRaster
-- 65536
-- @
newtype Raster p (r :: Nat) (c :: Nat) a = Raster { _array :: R.Array R.D R.DIM2 a }

instance Functor (Raster p r c) where
  fmap f (Raster a) = Raster $ R.map f a
  {-# INLINE fmap #-}

instance (KnownNat r, KnownNat c) => Applicative (Raster p r c) where
  pure = constant
  {-# INLINE pure #-}

  -- TODO: Use strict ($)?
  fs <*> as = zipWith ($) fs as
  {-# INLINE (<*>) #-}

-- | Be careful - this will evaluate your lazy Raster.
instance Eq a => Eq (Raster p r c a) where
  -- TODO: Check size and perform parallel version if big enough.
  (Raster a) == (Raster b) = R.equalsS a b
  {-# INLINE (==) #-}

instance (Monoid a, KnownNat r, KnownNat c) => Monoid (Raster p r c a) where
  mempty = constant mempty
  {-# INLINE mempty #-}

  a `mappend` b = zipWith mappend a b
  {-# INLINE mappend #-}

instance (Num a, KnownNat r, KnownNat c) => Num (Raster p r c a) where
  a + b = zipWith (+) a b
  {-# INLINE (+) #-}

  a - b = zipWith (-) a b
  {-# INLINE (-) #-}

  a * b = zipWith (*) a b
  {-# INLINE (*) #-}

  abs = fmap abs
  signum = fmap signum
  fromInteger = constant . fromInteger

instance (Fractional a, KnownNat r, KnownNat c) => Fractional (Raster p r c a) where
  a / b = zipWith (/) a b
  {-# INLINE (/) #-}

  fromRational = constant . fromRational

-- TODO: Use rules / checks to use `foldAllP` is the Raster has the right type / size.
-- | Be careful - these operations will evaluate your lazy Raster. (Except
-- `length`, which has a specialized O(1) implementation.)
instance Foldable (Raster p r c) where
  foldMap f (Raster a) = R.foldAllS mappend mempty $ R.map f a
  sum (Raster a) = R.sumAllS a
  -- | O(1).
  length (Raster a) = R.size $ R.extent a

-- | O(1). Create a `Raster` of any size which has the same value everywhere.
constant :: forall p r c a. (KnownNat r, KnownNat c) => a -> Raster p r c a
constant a = Raster $ R.fromFunction sh (const a)
  where sh = R.ix2 (fromInteger $ natVal (Proxy :: Proxy r)) (fromInteger $ natVal (Proxy :: Proxy c))

-- | O(1). Create a `Raster` from the values of an unboxed `U.Vector`.
-- Will fail if the size of the Vector does not match the declared size of the `Raster`.
fromUnboxed :: forall p r c a. (KnownNat r, KnownNat c, U.Unbox a) => U.Vector a -> Maybe (Raster p r c a)
fromUnboxed v | (r * c) == U.length v = Just . Raster . R.delay $ R.fromUnboxed (R.ix2 r c) v
              | otherwise = Nothing
  where r = fromInteger $ natVal (Proxy :: Proxy r)
        c = fromInteger $ natVal (Proxy :: Proxy c)

-- | Called /LocalClassification/ in GaCM. The first argument is the value
-- to give to any index whose value is less than the lowest break in the `M.Map`.
--
-- This is a glorified `fmap` operation, but we expose it for convenience.
classify :: Ord a => b -> M.Map a b -> Raster p r c a -> Raster p r c b
classify def m r = fmap f r
  where f a = maybe def snd $ M.lookupLE a m

-- | Finds the minimum value at each index between two `Raster`s.
min :: Ord a => Raster p r c a -> Raster p r c a -> Raster p r c a
min (Raster a) (Raster b) = Raster $ R.zipWith P.min a b

-- | Finds the maximum value at each index between two `Raster`s.
max :: Ord a => Raster p r c a -> Raster p r c a -> Raster p r c a
max (Raster a) (Raster b) = Raster $ R.zipWith P.max a b

-- | Averages the values per-index of all `Raster`s in a collection.
mean :: (Fractional a, KnownNat r, KnownNat c) => NonEmpty (Raster p r c a) -> Raster p r c a
mean (a :| as) = (/ len) <$> foldl' (+) a as
  where len = 1 + fromIntegral (length as)

-- | The count of unique values at each shared index.
variety :: (KnownNat r, KnownNat c, Eq a) => NonEmpty (Raster p r c a) -> Raster p r c Int
variety = fmap (length . nub) . sequenceA

-- | The most frequently appearing value at each shared index.
majority :: (KnownNat r, KnownNat c, Ord a) => NonEmpty (Raster p r c a) -> Raster p r c a
majority = fmap (fst . g . f) . sequenceA
  where f = foldl' (\m a -> M.insertWith (+) a 1 m) M.empty
        g = foldl1 (\(a,c) (k,v) -> if c < v then (k,v) else (a,c)) . M.toList

-- | The least frequently appearing value at each shared index.
minority :: (KnownNat r, KnownNat c, Ord a) => NonEmpty (Raster p r c a) -> Raster p r c a
minority = fmap (fst . g . f) . sequenceA
  where f = foldl' (\m a -> M.insertWith (+) a 1 m) M.empty
        g = foldl1 (\(a,c) (k,v) -> if c > v then (k,v) else (a,c)) . M.toList

-- | A measure of how spread out a dataset is. This calculation will fail
-- with `Nothing` if a length 1 list is given.
variance :: (KnownNat r, KnownNat c, Fractional a) => NonEmpty (Raster p r c a) -> Maybe (Raster p r c a)
variance (_ :| []) = Nothing
variance rs = Just (f <$> sequenceA rs)
  where len = fromIntegral $ length rs
        avg ns = (/ len) $ sum ns
        f os@(n :| ns) = foldl' (\acc m -> acc + ((m - av) ^ 2)) ((n - av) ^ 2) ns / (len - 1)
          where av = avg os


-- Old implementation that was replaced with `sequenceA` usage above. I wonder if this is faster?
-- Leaving it here in case we feel like comparing later.
--listEm :: (Projection p, KnownNat r, KnownNat c) => NonEmpty (Raster p r c a) -> Raster p r c (NonEmpty a)
--listEm = sequenceA
--listEm (r :| rs) = foldl' (\acc s -> zipWith cons s acc) z rs
--  where z = (\a -> a :| []) <$> r
--{-# INLINE [2] listEm #-}

-- | Combine two `Raster`s, element-wise, with a binary operator.
zipWith :: (a -> b -> d) -> Raster p r c a -> Raster p r c b -> Raster p r c d
zipWith f (Raster a) (Raster b) = Raster $ R.zipWith f a b
{-# INLINE zipWith #-}

-- | Focal Addition.
fsum :: Num a => Raster p r c a -> Raster p r c a
fsum (Raster a) = Raster . R.delay $ R.mapStencil2 (R.BoundConst 0) neighbourhood a
  where neighbourhood = R.makeStencil (R.ix2 3 3) (const (Just 1))

-- | Focal Mean.
fmean :: Fractional a => Raster p r c a -> Raster p r c a
fmean (Raster a) = Raster . R.delay $ R.mapStencil2 (R.BoundConst 0) neighbourhood a
  where neighbourhood = R.makeStencil (R.ix2 3 3) (const (Just (1/9)))

-- TODO Not sure about the `Boundary` value to use here.
-- | Focal Maximum
fmax :: (Focal a, Ord a) => Raster p r c a -> Raster p r c a
fmax (Raster a) = Raster . R.map maximum $ focal R.BoundClamp a

-- | Focal Minimum.
fmin :: (Focal a, Ord a) => Raster p r c a -> Raster p r c a
fmin (Raster a) = Raster . R.map minimum $ focal R.BoundClamp a

-- | Focal Variety.
fvariety :: (Focal a, Eq a) => Raster p r c a -> Raster p r c Int
fvariety (Raster a) = Raster . R.map (length . L.nub) $ focal R.BoundClamp a

-- | Yield all the values in a neighbourhood for further scrutiny.
focal :: Focal a => R.Boundary Integer -> R.Array R.D R.DIM2 a -> R.Array R.D R.DIM2 [a]
focal b a = R.map unpack . R.mapStencil2 b focalStencil $ R.map common a
{-# INLINE focal #-}

-- | A stencil used to bit-pack each value of a focal neighbourhood into
-- a single `Integer`. Once packed, you can `fmap` over the resulting `Raster`
-- to unpack the `Integer` and scrutinize the values freely (i.e. determine
-- the maximum value, etc).
focalStencil :: R.Stencil R.DIM2 Integer
focalStencil = R.makeStencil (R.ix2 3 3) f
  where f :: R.DIM2 -> Maybe Integer
        f (Z :. -1 :. -1) = Just 1
        f (Z :. -1 :.  0) = Just (2^64)
        f (Z :. -1 :.  1) = Just (2^128)
        f (Z :. 0  :. -1) = Just (2^196)
        f (Z :. 0  :.  0) = Just (2^256)
        f (Z :. 0  :.  1) = Just (2^320)
        f (Z :. 1  :. -1) = Just (2^384)
        f (Z :. 1  :.  0) = Just (2^448)
        f (Z :. 1  :.  1) = Just (2^512)
        f _               = Nothing

-- | Any type which is meaningful to perform focal operations on.
-- Law:
-- @
-- back (common v) == v
-- @
class Focal a where
  -- | Convert a value into an `Integer` in a way that preserves its bit layout.
  common :: a -> Integer
  -- | Shave the first 64 bits off an `Integer` and recreate the original value.
  back :: Integer -> a

instance Focal Word32 where
  common = toInteger
  back = fromIntegral

instance Focal Word64 where
  common = toInteger
  back = fromIntegral  -- Keeps precisely the first 64 bits of the Integer.

instance Focal Float where
  common = common . coerceToWord
  back = coerceToFloat . back

instance Focal Double where
  common = common . coerceToWord
  back = coerceToFloat . back

instance Focal Int where
  -- Go through `Word` to avoid sign-bit trickery.
  common = toInteger . (\n -> fromIntegral n :: Word64)
  back = fromIntegral . (\n -> back n :: Word64)

instance Focal Int32 where
  common = toInteger . (\n -> fromIntegral n :: Word32)
  back = fromIntegral . (\n -> back n :: Word32)

instance Focal Int64 where
  common = toInteger . (\n -> fromIntegral n :: Word64)
  back = fromIntegral . (\n -> back n :: Word64)

-- | Unpack the 9 original values that were packed into an `Integer` during a Focal op.
unpack :: Focal a => Integer -> [a]
unpack = take 9 . L.unfoldr (\n -> Just (back n, shiftL n 64))

{-
THE STRATEGY (for real this time)

The Inty types can convert to Integer easily.
The Floats can get to Integer via `floating-bits`.

To convert back, you pull out a list of Word64, and convert to your target type
from there.

Is Scientific better to use than `Integer`?
Since many of the digits will be populated by values, Integer is probably correct here.
-}
