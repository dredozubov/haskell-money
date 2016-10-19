{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- | This is an internal module. Import "Data.Money" instead.
module Data.Money.Internal
 ( -- * Dense monetary values
   Dense
 , dense
   -- * Discrete monetary values
 , Discrete
 , fromDiscrete
 , coerceUnit
 , round
 , ceiling
 , floor
 , truncate
   -- * Currency scales
 , Scale
 , Scale'
 , GoodScale
 , ErrScaleNonCanonical
 , scale
 , scaleFromProxy
   -- * Currency exchange
 , ExchangeRate
 , exchangeRate
 , fromExchangeRate
 , flipExchangeRate
 , exchange
   -- * Serializable representations
 , DenseRep
 , denseRep
 , mkDenseRep
 , fromDenseRep
 , withDenseRep
 ) where

import Control.Applicative (empty)
import Data.Proxy (Proxy(..))
import Data.Ratio ((%), numerator, denominator)
import GHC.Real (infinity, notANumber)
import GHC.TypeLits
  (Symbol, SomeSymbol(..), Nat, CmpNat, KnownSymbol, KnownNat,
   natVal, symbolVal, someSymbolVal)
import qualified GHC.TypeLits as GHC
import Prelude hiding (round, ceiling, floor, truncate)
import qualified Prelude
import qualified Text.ParserCombinators.ReadPrec as ReadPrec
import qualified Text.ParserCombinators.ReadP as ReadP
import Text.Read (readPrec)

--------------------------------------------------------------------------------
-- | 'Dense' represents a dense monetary value for @currency@ (usually a
-- ISO-4217 currency code, but not necessarily).
--
-- While monetary values associated with a particular currency are discrete, you
-- can still treat monetary values as dense while operating on them. For
-- example, the half of @USD 3.41@ is @USD 1.705@, which is not an amount that
-- can't be represented as a number of USD cents (the smallest unit that can
-- represent USD amounts). Nevertheless, if you eventually multiply @USD 1.705@
-- by @4@, for example, you end up with @USD 6.82@, which is again a value
-- representable as USD cents. In other words, 'Dense' monetary values
-- allow us to perform precise calculations deferring the conversion to a
-- 'Discrete' monetary values as much as posible. Once you are ready to
-- aproximate a 'Dense' value to a 'Discrete' value you can use one of
-- 'round', 'floor', 'ceiling' or 'truncate'. Otherwise, using 'toRational' you
-- can obtain a precise 'Rational' representation.
--
-- Construct 'Dense' monetary values using 'dense', or
-- 'fromInteger'/'fromIntegral' if that suffices.
newtype Dense (currency :: Symbol) = Dense Rational
  deriving (Eq, Ord, Num, Real, Fractional, Show)

instance Read (Dense currency) where
  readPrec = do
    _ <- ReadPrec.lift (ReadP.string "Dense ")
    maybe empty pure =<< fmap dense readPrec

-- | Build a 'Dense' monetary value from a 'Rational' value.
--
-- For example, if you want to represent @USD 12.52316@, then you can use:
--
-- @
-- 'dense' (125316 % 10000)
-- @
--
-- This function returns 'Nothing' in case the given 'Rational' is 'infinity' or
-- 'notANumber'.
dense :: Rational -> Maybe (Dense currency)
dense = \r0 ->
  if (infinity == r0 || notANumber == r0)
  then Nothing else Just (Dense r0)
{-# INLINE dense #-}

-- | 'Discrete' represents a discrete monetary value for a @currency@ expresed
-- as an integer amount of a particular @unit@. For example, with @currency ~
-- \"USD\"@ and @unit ~ \"cent\"@ you can represent United States Dollars to
-- their full extent.
--
-- @currency@ is usually a ISO-4217 currency code, but not necessarily.
--
-- Construct 'Discrete' values using 'fromInteger'.
--
-- For example, if you want to represent @GBP 21.05@, where the smallest
-- represetable unit for a GBP (United Kingdom Pound) is the /penny/, and 100
-- /pennies/ equal 1 GBP (i.e., @'Scale'' \"GBP\" ~ '(100, 1)@), then you can
-- use:
--
-- @
-- 'fromInteger' 2105 :: Discrete "GBP" "penny"
-- @
--
-- Because @2015 / 100 == 20.15@.
newtype Discrete (currency :: Symbol) (unit :: Symbol) = Discrete Integer
  deriving (Eq, Ord, Enum, Show, Num, Real, Integral)

instance Read (Discrete currency unit) where
  readPrec = do
    _ <- ReadPrec.lift (ReadP.string "Discrete ")
    Discrete <$> readPrec

instance
  ( GHC.TypeError
      (('GHC.Text "The ") 'GHC.:<>:
       ('GHC.ShowType Discrete) 'GHC.:<>:
       ('GHC.Text " type is deliberately not a ") 'GHC.:<>:
       ('GHC.ShowType Fractional) 'GHC.:$$:
       ('GHC.Text "instance. Convert the ") 'GHC.:<>:
       ('GHC.ShowType Discrete) 'GHC.:<>:
       ('GHC.Text " value to a ") 'GHC.:<>:
       ('GHC.ShowType Dense) 'GHC.:$$:
       ('GHC.Text "value and use the ") 'GHC.:<>:
       ('GHC.ShowType Fractional) 'GHC.:<>:
       ('GHC.Text " features on it instead.")) )
  => Fractional (Discrete currency unit) where
  fromRational = undefined
  recip = undefined

-- | Convert currency 'Discrete' monetary value into a 'Dense' monetary
-- value.
fromDiscrete
  :: GoodScale currency unit
  => Discrete currency unit
  -> Dense currency -- ^
fromDiscrete = \c@(Discrete i) -> Dense (fromInteger i / scale c)
{-# INLINE fromDiscrete #-}

-- | Rename a 'Discrete''s @unit@, provided the new unit shares the same 'Scale'
-- as the original.
--
-- This is useful for converting between cases such as @'Discrete' \"USD\"
-- \"USD\"@ and @'Discrete' \"USD\" \"cent\"@, which have the same meaning yet
-- different types.
coerceUnit
  :: Scale' currency unit1 ~ Scale' currency unit2
  => Discrete currency unit1
  -> Discrete currency unit2
coerceUnit = \(Discrete i) -> Discrete i
{-# INLINE coerceUnit #-}

-- | Internal. Used to implement 'round', 'ceiling', 'floor' and 'truncate'.
roundf
  :: GoodScale currency unit
  => (Rational -> Integer) -- ^ 'Prelude.round', 'Prelude.ceiling' or similar.
  -> Dense currency
  -> (Discrete currency unit, Maybe (Dense currency))
roundf f = \c0 ->
  let r0 = toRational c0 :: Rational
      r1 = r0 * scale d2 :: Rational
      i2 = f r1 :: Integer
      r2 = fromInteger i2 / scale d2 :: Rational
      ycrest | r0 == r2  = Nothing
             | otherwise = Just (Dense (r0 - r2))
      d2 = Discrete i2
  in (d2, ycrest)
{-# INLINE roundf #-}

-- | Round a 'Dense' value @x@ to the nearest value fully representable in
-- its @currency@'s @unit@ 'Scale'', which might be @x@ itself.
--
-- If @x@ is already fully representable in its @currency@'s @unit@ 'Scale'',
-- then the following holds:
--
-- @
-- 'round' x == (x, 'Nothing')
-- @
--
-- Otherwise, if the nearest value to @x@ that is fully representable in its
-- @currency@'s @unit@ 'Scale'' is greater than @x@, then the following holds:
--
-- @
-- 'round' == 'ceiling'
-- @
--
-- Otherwise, the nearest value to @x@ that is fully representable in its
-- @currency@'s @unit@ 'Scale'' is smaller than @x@, and the following holds:
--
-- @
-- 'round' == 'floor'
-- @
--
-- Proof that 'round' doesn't lose money:
--
-- @
-- x == case 'round' x of
--        (y, 'Nothing') -> y
--        (y, 'Just' z)  -> y + z
-- @
round
  :: GoodScale currency unit
  => Dense currency
  -> (Discrete currency unit, Maybe (Dense currency)) -- ^
round = roundf Prelude.round
{-# INLINE round #-}

-- | Round a 'Dense' value @x@ to the nearest value fully representable in
-- its @currency@'s @unit@ 'Scale'' which is greater than @x@ or equal to @x@.
--
--
-- If @x@ is already fully representable in its @currency@'s @unit@ 'Scale'',
-- then the following holds:
--
-- @
-- 'ceiling' x == (x, 'Nothing')
-- @
--
-- Otherwise, if @x@ is not representable in its @currency@'s @unit@ 'Scale'',
-- then the following holds:
--
-- @
-- 'ceiling' x == (y, 'Just' z)
-- @
--
-- @
-- x /= y
-- @
--
-- @
-- z < 'zero'
-- @
--
-- Proof that 'ceiling' doesn't lose money:
--
-- @
-- x == case 'ceiling' x of
--        (y, 'Nothing') -> y
--        (y, 'Just' z)  -> y + z
-- @
ceiling
  :: GoodScale currency unit
  => Dense currency
  -> (Discrete currency unit, Maybe (Dense currency)) -- ^
ceiling = roundf Prelude.ceiling
{-# INLINE ceiling #-}

-- | Round a 'Dense' value @x@ to the nearest value fully representable in
-- its @currency@'s @unit@ 'Scale'' which is smaller than @x@ or equal to @x@.
--
--
-- If @x@ is already fully representable in its @currency@'s @unit@ 'Scale'',
-- then the following holds:
--
-- @
-- 'floor' x == (x, 'Nothing')
-- @
--
-- Otherwise, if @x@ is not representable in its @currency@'s @unit@ 'Scale'',
-- then the following holds:
--
-- @
-- 'floor' x == (y, 'Just' z)
-- @
--
-- @
-- x /= y
-- @
--
-- @
-- z > 'zero'
-- @
--
-- Proof that 'floor' doesn't lose money:
--
-- @
-- x == case 'floor' x of
--        (y, 'Nothing') -> y
--        (y, 'Just' z)  -> y + z
-- @
floor
  :: GoodScale currency unit
  => Dense currency
  -> (Discrete currency unit, Maybe (Dense currency)) -- ^
floor = roundf Prelude.floor
{-# INLINE floor #-}

-- | Round a 'Dense' value @x@ to the nearest value between zero and
-- @x@ (inclusive) which is fully representable in its @currency@'s @unit@
-- 'Scale''.
--
-- If @x@ is already fully representable in its @currency@'s @unit@ 'Scale'',
-- then the following holds:
--
-- @
-- 'truncate' x == (x, 'Nothing')
-- @
--
-- Otherwise, if @x@ is positive, then the following holds:
--
-- @
-- 'truncate' == 'floor'
-- @
--
-- Otherwise, if @x@ is negative, the following holds:
--
-- @
-- 'truncate' == 'ceiling'
-- @
--
-- Proof that 'truncate' doesn't lose money:
--
-- @
-- x == case 'truncate' x of
--        (y, 'Nothing') -> y
--        (y, 'Just' z)  -> y + z
-- @
truncate
  :: GoodScale currency unit
  => Dense currency
  -> (Discrete currency unit, Maybe (Dense currency)) -- ^
truncate = roundf Prelude.truncate
{-# INLINE truncate #-}

--------------------------------------------------------------------------------

-- | Like 'Scale'', but the @currency@'s @unit@ is expected to be the smallest
-- discrete unit that can represent the it in its full extent. For example,
-- cents are the smallest unit that can represent United States Dollars, so:
--
-- @
-- 'Scale' \"USD\"  ~  'Scale'' \"USD\" \"USD\"  ~  'Scale'' \"USD\" \"cent\"
-- @
--
-- If you try to obtain the 'Scale' of a @currency@ without an obvious smallest
-- representable @unit@, like XAU, you will get a compile error.
type Scale (currency :: Symbol) = Scale' currency currency

-- | @'Scale'' currency unit@ is a rational number (expressed as @'(numerator,
-- denominator)@) indicating how many pieces of @unit@ fit in @currency@.
--
-- @currency@ is usually a ISO-4217 currency code, but not necessarily.
--
-- The 'Scale'' will determine how to convert a 'Dense' value into a
-- 'Discrete' value and vice-versa.
--
-- For example, there are 100 USD cents in 1 USD, so the scale for this
-- relationship is:
--
-- @
-- type instance 'Scale'' \"USD\" \"cent\" = '(100, 1)
-- @
--
-- As another example, there is 1 dollar in USD, so the scale for this
-- relationship is:
--
-- @
-- type instance 'Scale'' \"USD\" \"dollar\" = '(1, 1)
-- @
--
-- When using 'Discrete' values to represent money, it will be impossible to
-- represent an amount of @currency@ smaller than @unit@. So, if you decide to
-- use @Scale' \"USD\" \"dollar\"@ as your scale, you will not be able to
-- represent values such as USD 3.50 or USD 21.87, since they are not exact
-- multiples of a dollar.
--
-- If there exists a cannonical smallest @unit@ that can fully represent the
-- currency, then an instance @'Scale'' currency currency@ exists.
--
-- @
-- type instance 'Scale'' \"USD\" \"USD\" = Scale' \"USD\" \"cent\"
-- @
--
-- There is a convenient type synonym 'Scale' for this 'Scale'' case where the
-- @currency@ and @unit@ match:
--
-- @
-- type 'Scale' a = 'Scale'' a a
-- 'Scale' \"USD\" ~ 'Scale'' \"USD\" \"USD\"
-- @
--
-- For some monetary values, such as precious metals, the smallest representable
-- unit is not obvious, since you can continue to split the precious metal many
-- times before it stops being a precious metal. Still, for practical purposes
-- we can make a sane arbitrary choice of smallest unit. For example, the base
-- unit for XAU (Gold) is the /troy ounce/, which is too big to be considered
-- the smallest unit, but we can arbitrarily choose the /milligrain/ as our
-- smallest unit, which is about as heavy as a single grain of table salt and
-- should be sufficiently precise for all monetary practical purposes. A /troy
-- ounce/ equals 480000 /milligrains/.
--
-- @
-- type instance 'Scale'' \"XAG\" \"milligrain\" = '(480000, 1)
-- @
--
-- You can use other units such as /milligrams/ for measuring XAU, for example.
-- However, since the amount of /milligrams/ in a /troy ounce/ (31103.477) is
-- not integral, we need to use rational number to express it.
--
-- @
-- type instance 'Scale'' \"XAU\" \"milligram\" = '(31103477, 1000)
-- @
--
-- If you try to obtain the 'Scale' of a @currency@ without an obvious smallest
-- representable @unit@, like XAU, you will get a compile error.
type family Scale' (currency :: Symbol) (unit :: Symbol) :: (Nat, Nat)

-- | A friendly 'GHC.TypeError' to use for a @currency@ that doesn't have a
-- cannonical small unit.
type family ErrScaleNonCanonical (currency :: Symbol) :: k where
  ErrScaleNonCanonical c = GHC.TypeError
    ( 'GHC.Text c 'GHC.:<>:
      'GHC.Text " is not a currency with a canonical smallest unit," 'GHC.:$$:
      'GHC.Text "be explicit about the currency unit you want to use." )

-- | Constraints to @'Scale'' currency unit@ expected to always be satisfied. In
-- particular, the scale is always guaranteed to be a positive rational number
-- ('infinity' and 'notANumber' are forbidden by 'GoodScale').
type GoodScale (currency :: Symbol) (unit :: Symbol)
  = ( CmpNat 0 (Fst (Scale' currency unit)) ~ 'LT
    , CmpNat 0 (Snd (Scale' currency unit)) ~ 'LT
    , KnownNat (Fst (Scale' currency unit))
    , KnownNat (Snd (Scale' currency unit))
    )

-- | Term-level representation for the @currency@'s @unit@ 'Scale''.
--
-- For example, the 'Scale'' for @\"USD\"@ in @\"cent\"@s is @100/1@.
--
-- The returned 'Rational' is statically guaranteed to be a positive number, and
-- to be different from both 'notANumber' and 'infinity'.
scale
  :: forall currency unit
  .  GoodScale currency unit
  => Discrete currency unit
  -> Rational
scale = \_ -> scaleFromProxy (Proxy :: Proxy currency) (Proxy :: Proxy unit)
{-# INLINE scale #-}

-- | Like 'scale', but takes proxies (e.g., 'Proxy') instead of 'Discrete'.
scaleFromProxy
  :: forall currency unit proxy1 proxy2
  .  GoodScale currency unit
  => proxy1 currency
  -> proxy2 unit
  -> Rational
scaleFromProxy = \_ _ ->
   natVal (Proxy :: Proxy (Fst (Scale' currency unit))) %
   natVal (Proxy :: Proxy (Snd (Scale' currency unit)))
{-# INLINE scaleFromProxy #-}

--------------------------------------------------------------------------------

-- | Exchange rate for converting monetary values of currency @src@ into
-- monetary values of currency @dst@ by multiplying for it.
--
-- For example, if in order to convert USD to GBP we have to multiply by 1.2345,
-- then we can represent this situaion using:
--
-- @
-- 'exchangeRate' (12345 % 10000) :: 'Maybe' ('ExchangeRate' \"USD\" \"GBP\")
-- @
newtype ExchangeRate (src :: Symbol) (dst :: Symbol) = ExchangeRate Rational
  deriving (Eq, Ord, Show)

instance Read (ExchangeRate (src :: Symbol) (dst :: Symbol)) where
  readPrec = maybe empty pure =<< fmap exchangeRate readPrec

-- | Obtain a 'Rational' representation of the 'ExchangeRate'.
--
-- This 'Rational' is statically guaranteed to be greater than 0, different
-- from 'infinity' and different from 'notANumber'.
fromExchangeRate :: ExchangeRate src dst -> Rational
fromExchangeRate = \(ExchangeRate r0) -> r0
{-# INLINE fromExchangeRate #-}

-- | Safely construct an 'ExchangeRate' from a 'Rational' number.
--
-- For construction to succeed, this 'Rational' must be greater than 0,
-- different from 'infinity' and different from 'notANumber'.
exchangeRate :: Rational -> Maybe (ExchangeRate src dst)
exchangeRate = \r0 ->
  if (r0 <= 0 || infinity == r0 || notANumber == r0)
  then Nothing else Just (ExchangeRate r0)
{-# INLINE exchangeRate #-}

-- | Flip the direction of an 'ExchangeRate'.
--
-- Identity law:
--
-- @
-- 'flipExchangeRate' . 'flipExchangeRate'   ==  'id'
-- @
flipExchangeRate :: ExchangeRate a b -> ExchangeRate b a
flipExchangeRate = \(ExchangeRate x) -> ExchangeRate (1 / x)
{-# INLINE flipExchangeRate #-}

-- | Apply the 'ExchangeRate' to the given @'Dense' src@ monetary value.
--
-- Identity law:
--
-- @
-- 'exchange' ('flipExchangeRate' x) . 'exchange' x  ==  'id'
-- @
--
-- Use the /Identity law/ for reasoning about going back and forth between @src@
-- and @dst@ in order to manage any leftovers that might not be representable as
-- a 'Discrete' monetary value of @src@.
exchange :: ExchangeRate src dst -> Dense src -> Dense dst
exchange = \(ExchangeRate r) -> \(Dense s) -> Dense (r * s)
{-# INLINE exchange #-}

--------------------------------------------------------------------------------
-- DenseRep

data DenseRep = DenseRep !String !Integer !Integer
  -- ^ Currency name * Numerator * Denominator (positive, not zero).
  deriving (Eq, Show, Read)

-- | WARNING: This instance does not compare monetary amounts, it just helps you
-- sort 'DenseRep' values in case you need to put them in a 'Data.Set.Set' or
-- similar.
deriving instance Ord DenseRep

-- | Internal. Build a 'DenseRep' from raw values.
mkDenseRep
  :: String -- ^ Currency.
  -> Integer -- ^ Nominator.
  -> Integer -- ^ Denominator (positive, non zero)
  -> Maybe DenseRep
mkDenseRep = \c n d -> if d > 0 then Just (DenseRep c n d) else Nothing
{-# INLINE mkDenseRep #-}

-- | Convert a 'Dense' to a 'DenseRep' for ease of serialization.
denseRep :: KnownSymbol currency => Dense currency -> DenseRep
denseRep = \(Dense r0 :: Dense currency) ->
  let c = symbolVal (Proxy :: Proxy currency)
  in DenseRep c (numerator r0) (denominator r0)
{-# INLINE denseRep #-}

-- | Attempt to convert a 'DenseRep' to a 'Dense', provided you know the target
-- @currency@.
fromDenseRep
  :: forall currency
  .  KnownSymbol currency
  => DenseRep
  -> Maybe (Dense currency)  -- ^
fromDenseRep = \(DenseRep c n d) ->
   if c == symbolVal (Proxy :: Proxy currency)
   then Just (Dense (n % d)) else Nothing
{-# INLINE fromDenseRep #-}

-- | Convert a 'DenseRep' to a 'Dense' without knowing the @target@ currency.
--
-- Notice that @currency@ here can't leave its intended scope unless you can
-- prove equality with some other type at the outer scope, but in that case you
-- would be better off using 'fromDenseRep' directly.
withDenseRep
  :: DenseRep
  -> (forall currency. KnownSymbol currency => Dense currency -> r)
  -> r
withDenseRep (DenseRep c n d) = \f ->
   case someSymbolVal c of
      SomeSymbol (Proxy :: Proxy currency) ->
         f (Dense (n % d) :: Dense currency)
{-# INLINE withDenseRep #-}

--------------------------------------------------------------------------------
-- Miscellaneous

type family Fst (ab :: (ka, kb)) :: ka where Fst '(a,b) = a
type family Snd (ab :: (ka, kb)) :: ka where Snd '(a,b) = b

--------------------------------------------------------------------------------
-- Currency scales

