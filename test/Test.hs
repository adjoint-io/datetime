{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import qualified Data.Aeson as A
import qualified Data.Binary as B
import qualified Data.Hourglass as DH
import Data.Hourglass.Types as DH
import Data.List (unfoldr)
import Data.Monoid ((<>))
import qualified Data.Serialize as S
import qualified Data.Time.Calendar as DC
import Datetime
import Datetime.Types
import Protolude
import Test.QuickCheck.Monadic
import Test.Tasty
import Test.Tasty.HUnit hiding (assert)
import Test.Tasty.QuickCheck

instance Arbitrary Datetime where
  arbitrary = posixToDatetime <$> choose (1, 32503680000) -- (01/01/1970, 01/01/3000)

instance Arbitrary Period where
  arbitrary = do
    year <- choose (0, 1000)
    month <- choose (0, 12)
    let monthNumDays = DC.gregorianMonthLength (fromIntegral year) (fromIntegral month)
    day <- choose (0, monthNumDays)
    pure $ Period $ DH.Period year month day

instance Arbitrary Duration where
  arbitrary =
    fmap Duration $
      DH.Duration
        <$> (fmap Hours $ choose (0, 23))
        <*> (fmap Minutes $ choose (0, 59))
        <*> (fmap Seconds $ choose (0, 59))
        <*> pure 0

instance Arbitrary Delta where
  arbitrary = Delta <$> arbitrary <*> arbitrary

instance Arbitrary TimezoneOffset where
  arbitrary = TimezoneOffset <$> choose (-660, 840)

nyse2017Holidays =
  map
    (dateTimeToDatetime timezone_UTC)
    [ DateTime (Date 2017 January 2) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 January 16) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 February 20) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 April 14) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 May 29) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 July 4) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 September 4) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 November 23) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 December 25) (TimeOfDay 0 0 0 0)
    ]

uk2017Holidays =
  map
    (dateTimeToDatetime timezone_UTC)
    [ DateTime (Date 2017 January 2) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 April 14) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 April 17) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 May 1) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 May 29) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 August 28) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 December 25) (TimeOfDay 0 0 0 0),
      DateTime (Date 2017 December 26) (TimeOfDay 0 0 0 0)
    ]

suite :: TestTree
suite =
  testGroup
    "Test Suite"
    [ testCase "Correctly identifies Holidays" $ do
        let jan1st2017 =
              dateTimeToDatetime timezone_UTC $
                DateTime (Date 2017 January 1) (TimeOfDay 0 0 0 0)
        let currYear = year jan1st2017
        let yearDts = take 365
              $ flip unfoldr jan1st2017
              $ \dt ->
                Just (dt, add dt (days 1))
        let nyseHolidays' = filter isNYSEHoliday yearDts
        assertEqual
          "Correct NYSE holidays found"
          nyse2017Holidays
          nyseHolidays'
        assertEqual
          "Correct number of NYSE holidays found"
          (length $ nyseHolidays currYear)
          (length nyseHolidays')
        let ukHolidays' = filter isUKHoliday yearDts
        assertEqual
          "Correct UK holidays found"
          uk2017Holidays
          ukHolidays'
        assertEqual
          "Correct number of UK holidays found"
          (length $ ukHolidays currYear)
          (length ukHolidays'),
      testProperty "Manipulating Timezone preserves Datetime Integrity" $ \tzo ->
        monadicIO $ do
          dtNow <- run now
          let dtNowLocal = alterTimezone tzo dtNow
          let tzoMins = timezoneOffsetToMinutes tzo
          let (hrs', mins') = divMod (abs tzoMins) 60
          let alter = if tzoMins < 0 then sub else add
          let dtNowLocal' = (dtNow `alter` (hours hrs' <> mins mins')) {zone = tzoMins}
          assert $ dtNowLocal == dtNowLocal',
      testProperty "ISO 8601: parse . format = id" $ \(dt :: Datetime) ->
        (parseDatetime $ formatDatetime dt) == (Just dt),
      testProperty "dateTimeToDatetime . datetimeToDateTime = id" $ \(dt :: Datetime) ->
        (dateTimeToDatetime timezone_UTC $ datetimeToDateTime dt) == dt,
      testProperty "Deltas are correctly added and canonicalized" $ \(Positive (Small n)) ->
        let d1 = years 1 <> hours (n * 24)
            d2 = months 2 <> mins (n * 60 * 24)
            d3 = days 3 <> secs (n * 60 * 60 * 24)
         in (d1 <> d2 <> d3) == (years 1 <> months 2 <> days 3 <> days (n * 3)),
      testCase "Adding/Subtracting Deltas from Datetimes properly trim invalid month days" $ do
        -- For adding/subtracting 1 month when month length differs
        let mar31_2017 = Datetime 2017 3 31 0 0 0 0 5
        let feb28_2017 = Datetime 2017 2 28 0 0 0 0 2
        let jan31_2017 = Datetime 2017 1 31 0 0 0 0 2
        -- For adding/subtracting 1 year when year length differs
        let feb29_2016 = Datetime 2016 2 29 0 0 0 0 1
        let feb28_2015 = Datetime 2015 2 28 0 0 0 0 6
        let jan31_2015 = Datetime 2015 1 31 0 0 0 0 6
        assertEqual
          "Mar 31 2017 - 1mo == Feb 28 2017"
          (sub mar31_2017 $ months 1)
          feb28_2017
        assertEqual
          "Jan 31 2017 + 1mo == Feb 28 2017"
          (add jan31_2017 $ months 1)
          feb28_2017
        assertEqual
          "Feb 29 2017 - 1yr == Feb 28 2015"
          (sub feb29_2016 $ years 1)
          feb28_2015
        assertEqual
          "Jan 31 2015 + 1yr1mo == Feb 29 2016"
          (add jan31_2015 $ years 1 <> months 1)
          feb29_2016,
      testCase "Function `scaleDelta` behaves correctly" $ do
        let feb23_1999 = Datetime 1999 2 23 23 13 40 5 2
        let testPeriod = Period (DH.Period 1 1 1)
        let testDuration = Duration $ DH.Duration (DH.Hours 1) (DH.Minutes 1) (DH.Seconds 1) (DH.NanoSeconds 0)
        let Just testDelta = scaleDelta 4 $ Delta testPeriod testDuration
        let resPeriod = Period (DH.Period 4 4 4)
        let resDuration = Duration $ DH.Duration (DH.Hours 4) (DH.Minutes 4) (DH.Seconds 4) (DH.NanoSeconds 0)
        let resDelta = Delta resPeriod resDuration
        assertEqual "4 * 1y1mo1d1h1m1s == 4y4mo4d4h4m4s" resDelta testDelta
        let june28_2003 = Datetime 2003 6 28 3 17 44 5 6
        assertEqual
          "Feb 23 1999 at 23:23:13 + 4y4mo4d4h4m4s == June 28 2003 3:17:44"
          (add feb23_1999 testDelta)
          june28_2003,
      testGroup "Binary Serialization" $
        [ testProperty "Serialize: decode (encode <Delta>) == <Delta>" $ \(d :: Delta) ->
            Right d == S.decode (S.encode d),
          testProperty "Binary: decode (encode <Delta>) == <Delta>" $ \(d :: Delta) ->
            d == B.decode (B.encode d)
        ],
      testProperty "JSON: decode (encode <Datetime>) == <Datetime>" $ \(d :: Datetime) ->
        Just d == A.decode (A.encode d)
    ]

main :: IO ()
main = defaultMain suite
