{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}

module Main where

import           Codec.Picture
import qualified Data.Array.Repa as R
import qualified Data.ByteString as BS
import           Data.Int
import qualified Data.Vector.Unboxed as U
import           Data.Word
import           Geography.MapAlgebra
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck
import qualified Data.List.NonEmpty as NE

---

main :: IO ()
main = do
  -- tif <- BS.readFile "/home/colin/code/haskell/mapalgebra/LC81750172014163LGN00_LOW5.TIF"
  -- defaultMain $ suite tif
  defaultMain suite

suite :: TestTree
suite = testGroup "Unit Tests"
  [ testGroup "Raster Creation"
    [ testCase "constant (256x256)" $ length small @?= 65536
    , testCase "constant (2^16 x 2^16)" $ length big @?= 4294967296
    , testCase "fromImage (256x256)" $ fmap length (NE.head <$> fromImage img :: Maybe (Raster p 256 256 Word8)) @?= Just 65536
    ]
  , testGroup "Typeclass Ops"
    [ testCase "(==)" $ assert (small == small)
    , testCase "(+)" $ assert (one + one == two)
    ]
  , testGroup "Folds"
    [ testCase "sum (small)" $ sum small @?= 327680
    -- takes ~4 seconds
--    , testCase "sum (large)" $ runIdentity (R.sumAllP $ _array big) @?= 21474836480
    ]
  , testGroup "Local Ops"
    [ testCase "(+)" $ sum (small + small) @?= (327680 * 2)
    -- takes ~68 seconds
--    , testCase "(+) big" $ runIdentity (R.sumAllP . _array $ big + big) @?= 21474836480 * 2
    ]
  , testGroup "Focal Ops"
    [ testCase "fvariety" $ fvariety one @?= one
    , testCase "fmax" $ fmax one @?= one
    , testCase "fmin" $ fmin one @?= one
    ]
  , testGroup "Focal Typeclass"
    [ testProperty "Word8"  (\(v :: Word8)  -> back (common v) == v)
    , testProperty "Word32" (\(v :: Word32) -> back (common v) == v)
    , testProperty "Word64" (\(v :: Word64) -> back (common v) == v)
    , testProperty "Float"  (\(v :: Float)  -> back (common v) == v)
    , testProperty "Double" (\(v :: Double) -> back (common v) == v)
    , testProperty "Int"    (\(v :: Int)    -> back (common v) == v)
    , testProperty "Int32"  (\(v :: Int32)  -> back (common v) == v)
    , testProperty "Int64"  (\(v :: Int64)  -> back (common v) == v)
    ]
  , testGroup "Repa Behaviour"
    [ testCase "Row-Major Indexing" $ R.index arr (R.ix2 1 0) @?= 3
    ]
  -- , testGroup "JuicyPixels Behaviour"
    -- [ testCase "Initial Image Height" $ (imageHeight <$> i) @?= Just 1753
    -- , testCase "Initial Image Width"  $ (imageWidth  <$> i) @?= Just 1760
    -- , testCase "Repa'd Array Size"    $ (R.extent . fromRGBA <$> i) @?= Just (Z :. 1753 :. 1760 :. 4)
    -- ]
  ]

one :: Raster p 7 7 Int
one = constant 1

two :: Raster p 7 7 Int
two = constant 2

small :: Raster WebMercator 256 256 Int
small = constant 5

big :: Raster WebMercator 65536 65536 Int
big = constant 5

-- | Should have two rows and 3 columns.
arr :: R.Array R.U R.DIM2 Int
arr = R.fromUnboxed (R.ix2 2 3) $ U.fromList [0..5]

img :: Image Pixel8
img = generateImage (\_ _ -> 5) 256 256

getImage :: BS.ByteString -> Maybe (Image PixelRGBA8)
getImage bs = either (const Nothing) Just (decodeTiff bs) >>= f
  where f (ImageRGBA8 i) = Just i
        f _ = Nothing
