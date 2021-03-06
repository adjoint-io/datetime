{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

module Datetime.Types
  ( Datetime (..),
    Delta (..),
    Period (..),
    Duration (..),
    Interval (..),

    -- ** Constructors
    secs,
    mins,
    hours,

    -- ** Deltas
    days,
    months,
    years,
    weeks,
    addDeltas,
    subDeltas,
    scaleDelta,

    -- ** Ordering
    before,
    after,

    -- ** Ranges
    from,
    between,

    -- ** Validation
    validateDatetime,

    -- ** End-of-month
    eomonth,
    fomonth,

    -- ** Conversion
    dateTimeToDatetime,
    datetimeToDateTime,
    posixToDatetime,

    -- ** Timezones -- XXX Explicit sum type
    TimezoneOffset (..),
    toUTC,
    alterTimezone,

    -- ** Delta operation
    add,
    sub,
    diff,
    within,
    canonicalizeDelta,

    -- ** Fiscal Quarters
    fiscalQuarters,
    q1,
    q2,
    q3,
    q4,

    -- ** Time Parse
    parseDatetime,
    formatDatetime,
    displayDelta,

    -- ** System time
    now,
  )
where

import Control.Monad (fail)
import Data.Aeson
import qualified Data.Binary as B
import Data.Hourglass
  ( Date (..),
    DateTime (..),
    ISO8601_DateAndTime (..),
    LocalTime (..),
    Month (..),
    TimeOfDay (..),
    TimezoneOffset (..),
    localTime,
    localTimeFromGlobal,
    localTimeParse,
    localTimeSetTimezone,
    localTimeToGlobal,
    localTimeUnwrap,
    localTimeUnwrap,
  )
import qualified Data.Hourglass as DH
import Data.Monoid ((<>))
import qualified Data.Serialize as S
import qualified Data.Time.Calendar as DC
import Protolude hiding (diff, from, get, put, second)
import Time.System (dateCurrent, timezoneCurrent)

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

data Datetime
  = Datetime
      { -- | The complete year
        year :: Int,
        -- | A month, between 1 and 12
        month :: Int,
        -- | A day, between 1 and 31
        day :: Int,
        -- | The number of hours since midnight, between 0 and 23
        hour :: Int,
        -- | The number of minutes since the beginning of the hour, between 0 and 59
        minute :: Int,
        -- | The number of seconds since the begining of the minute, between 0 and 59
        second :: Int,
        -- | The local zone offset, in minutes of advance wrt UTC.
        zone :: Int,
        -- | The number of days since sunday, between 0 and 6
        week_day :: Int
      }
  deriving (Show, Eq, Generic, NFData, Hashable)

instance S.Serialize Datetime where

  put Datetime {..} = do
    putInt year
    putInt month
    putInt day
    putInt hour
    putInt minute
    putInt second
    putInt zone
    putInt week_day
    where
      putInt :: Int -> S.PutM ()
      putInt i = S.putInt64be (fromIntegral i :: Int64)

  get = do
    year <- getInt
    month <- getInt
    day <- getInt
    hour <- getInt
    minute <- getInt
    second <- getInt
    zone <- getInt
    week_day <- getInt
    let dt = Datetime {..}
    case validateDatetime dt of
      Left err -> fail err
      Right _ -> pure dt
    where
      getInt :: S.Get Int
      getInt = fmap fromIntegral (S.get :: S.Get Int64)

instance B.Binary Datetime where

  put = B.put . S.encode

  get = do
    edt <- S.decode <$> B.get
    case edt of
      Left err -> fail err
      Right dt -> pure dt

instance ToJSON Datetime where
  toJSON = toJSON . formatDatetime

instance FromJSON Datetime where
  parseJSON = withText "Datetime" $ \t ->
    case parseDatetime (toS t) of
      (Just dt) -> pure dt
      _ -> fail "could not parse ISO-8601 datetime"

-- | Check whether a date is correctly formed
validateDatetime :: Datetime -> Either [Char] ()
validateDatetime (Datetime {..}) =
  sequence_
    [ cond (year > 0) "Year is invalid",
      cond (year < 3000) "Year is not in current millenium",
      cond (month >= 1 && month <= 12) "Month range is invalid",
      cond (day >= 1 && day <= 31) "Day range is invalid",
      cond (hour >= 0 && hour <= 23) "Hour range is invalid",
      cond (minute >= 0 && minute <= 59) "Minute range is invalid",
      cond (second >= 0 && second <= 59) "Second range is invalid",
      cond (week_day >= 0 && week_day <= 6) "Week day range is invalid"
    ]
  where
    cond True msg = Right ()
    cond False msg = Left msg

-- | Convert a Datetime to UTC
toUTC :: Datetime -> Datetime
toUTC = alterTimezone DH.timezone_UTC

-- | Alter the Datetime timezone using logic from Data.Hourglass
alterTimezone :: TimezoneOffset -> Datetime -> Datetime
alterTimezone tz = dateTimeToDatetime tz . datetimeToDateTime

-------------------------------------------------------------------------------
-- Deltas and Intervals
-------------------------------------------------------------------------------

newtype Period = Period {unPeriod :: DH.Period}
  deriving (Show, Eq, Ord, Generic, NFData)

instance Semigroup Period where
  (<>) (Period p1) (Period p2) = Period $ p1 <> p2

instance Monoid Period where

  mempty = Period mempty

  mappend (Period p1) (Period p2) = Period $ mappend p1 p2

instance Hashable Period where
  hashWithSalt salt (Period (DH.Period yrs mns dys)) =
    foldl' hashWithSalt salt [yrs, mns, dys]

instance ToJSON Period where
  toJSON (Period (DH.Period yrs mns dys)) =
    object
      [ "periodYears" .= yrs,
        "periodMonths" .= mns,
        "periodDays" .= dys
      ]

instance FromJSON Period where
  parseJSON = withObject "Period" $ \v ->
    fmap Period $
      DH.Period
        <$> v .: "periodYears"
        <*> v .: "periodMonths"
        <*> v .: "periodDays"

instance S.Serialize Period where

  put (Period (DH.Period yrs mns dys)) = do
    putInt yrs
    putInt mns
    putInt dys
    where
      putInt = S.putInt64be . fromIntegral

  get =
    fmap Period $
      DH.Period
        <$> getInt
        <*> getInt
        <*> getInt
    where
      getInt = fromIntegral <$> S.getInt64be

newtype Duration = Duration {unDuration :: DH.Duration}
  deriving (Show, Eq, Ord, Generic, NFData)

instance Semigroup Duration where
  (<>) (Duration d1) (Duration d2) = Duration $ d1 <> d2

instance Monoid Duration where

  mempty = Duration mempty

  mappend (Duration d1) (Duration d2) = Duration $ mappend d1 d2

instance Hashable Duration where
  hashWithSalt salt (Duration (DH.Duration (DH.Hours h) (DH.Minutes m) (DH.Seconds s) (DH.NanoSeconds ns))) =
    foldl' hashWithSalt salt $ map (fromIntegral :: Int64 -> Int) [h, m, s, ns]

instance ToJSON Duration where
  toJSON (Duration duration) =
    let (DH.Duration (DH.Hours h) (DH.Minutes m) (DH.Seconds s) (DH.NanoSeconds ns)) = duration
     in object
          [ "durationHours" .= h,
            "durationMinutes" .= m,
            "durationSeconds" .= s,
            "durationNs" .= ns
          ]

instance FromJSON Duration where
  parseJSON = withObject "Duration" $ \v ->
    fmap Duration $
      DH.Duration
        <$> (fmap DH.Hours $ v .: "durationHours")
        <*> (fmap DH.Minutes $ v .: "durationMinutes")
        <*> (fmap DH.Seconds $ v .: "durationSeconds")
        <*> (fmap DH.NanoSeconds $ v .: "durationNs")

instance S.Serialize Duration where

  put (Duration duration) = do
    let (DH.Duration (DH.Hours h) (DH.Minutes m) (DH.Seconds s) (DH.NanoSeconds ns)) = duration
    S.putInt64be h
    S.putInt64be m
    S.putInt64be s
    S.putInt64be ns

  get =
    fmap Duration $
      DH.Duration
        <$> (fmap DH.Hours S.getInt64be)
        <*> (fmap DH.Minutes S.getInt64be)
        <*> (fmap DH.Seconds S.getInt64be)
        <*> (fmap DH.NanoSeconds S.getInt64be)

-- | A time difference represented with Period (y/m/d) + Duration (h/m/s/ns)
-- where Duration represents the time diff < 24 hours.
data Delta
  = Delta
      { -- | An amount of conceptual calendar time in terms of years, months and days.
        dPeriod :: Period,
        -- | An amount of time measured in hours/mins/secs/nsecs
        dDuration :: Duration
      }
  deriving (Show, Eq, Ord, Generic, NFData, Hashable, ToJSON, FromJSON)

instance S.Serialize Delta where

  put (Delta p d) = S.put p >> S.put d

  get = Delta <$> S.get <*> S.get

instance B.Binary Delta where

  put = B.put . S.encode

  get = do
    eDelta <- S.decode <$> B.get
    case eDelta of
      Left err -> fail err
      Right d -> pure d

displayDelta :: Delta -> Text
displayDelta (Delta (Period (DH.Period y mo dy)) (Duration d)) =
  year <> month <> day <> hour <> minute <> second
  where
    (DH.Duration (DH.Hours h) (DH.Minutes m) (DH.Seconds s) (DH.NanoSeconds ns)) = d
    year = suffix y "y"
    month = suffix mo "mo"
    day = suffix dy "d"
    hour = suffix h "h"
    minute = suffix m "m"
    second = suffix s "s"
    suffix :: (Eq a, Num a, Show a) => a -> Text -> Text
    suffix n s
      | n == 0 = ""
      | otherwise = show n <> s

-- | This function keeps the Duration sub-24 hours, overflowing all extra time
-- into the Period component. Since the datetime logic is complex, the period
-- fields `years`, `months`, `days` are not overflowed into each other. For
-- instance 20y30mo40d is a valid Period, but 25h61m61s is not a valid Duration
canonicalizeDelta :: Delta -> Delta
canonicalizeDelta (Delta (Period p) (Duration d)) =
  Delta newPeriod newDuration
  where
    (DH.Duration dhrs'' dmins'' dsecs' dns) = d
    (dmins', dsecs) = dsecs' `divMod` 60
    (dhrs', dmins) = (dmins'' + fromIntegral dmins') `divMod` 60
    (days', dhrs) = (dhrs'' + fromIntegral dhrs') `divMod` 24
    extraPeriod = DH.Period {periodYears = 0, periodMonths = 0, periodDays = fromIntegral days'}
    newPeriod = Period $ p <> extraPeriod
    newDuration = Duration $ DH.Duration dhrs dmins dsecs dns

instance Semigroup Delta where
  (<>) (Delta d1 p1) (Delta d2 p2) = Delta (d1 <> d2) (p1 <> p2)

instance Monoid Delta where

  mempty = Delta mempty mempty

  mappend (Delta p1 d1) (Delta p2 d2) =
    canonicalizeDelta $ Delta (p1 `mappend` p2) (d1 `mappend` d2)

-- | A time period between two Datetimes
data Interval
  = Interval
      { iStart :: Datetime,
        iStop :: Datetime
      }
  deriving (Eq, Show, Generic)

-------------------------------------------------------------------------------

-- | Conversion function between Data.Hourglass.DateTime and Datetime defined in
-- this module.
--
-- This should be the only way to construct a Datetime value, given the use of
-- the partial toEnum function in the Datetime -> DateTime conversion functions
dateTimeToDatetime :: TimezoneOffset -> DateTime -> Datetime
dateTimeToDatetime tzo@(TimezoneOffset tzOffset) dt' = datetime
  where
    -- Convert DateTime to local time and then unwrap for conversion
    dt = localTimeUnwrap $ localTimeSetTimezone tzo $ localTimeFromGlobal dt'
    -- Build a Datetime from the localtime adjusted DateTime
    datetime = Datetime
      { year = dateYear (dtDate dt),
        month = 1 + fromEnum (dateMonth (dtDate dt)), -- human convention starts at 1
        day = dateDay (dtDate dt),
        hour = fromIntegral $ todHour (dtTime dt),
        minute = fromIntegral $ todMin (dtTime dt),
        second = fromIntegral $ todSec (dtTime dt),
        zone = tzOffset,
        week_day = fromEnum $ DH.getWeekDay (dtDate dt) -- Sunday is 0
      }

-- | Conversion function between Datetime and Data.Hourglass.DateTime
-- WARNING: Resulting DateTime value is offset UTC by the timezone,
-- but data about the specific timezone offset is lost
datetimeToDateTime :: Datetime -> DateTime
datetimeToDateTime dt =
  localTimeToGlobal
    $ localTime (TimezoneOffset $ zone dt)
    $ DateTime
      { dtDate = dtDate',
        dtTime = dtTime'
      }
  where
    dtDate' = Date
      { dateYear = year dt,
        dateMonth = toEnum (-1 + month dt),
        dateDay = day dt
      }
    dtTime' = TimeOfDay
      { todHour = fromIntegral (hour dt),
        todMin = fromIntegral (minute dt),
        todSec = fromIntegral (second dt),
        todNSec = 0
      }

posixToDatetime :: Int64 -> Datetime
posixToDatetime = dateTimeToDatetime DH.timezone_UTC . DH.timeFromElapsed . DH.Elapsed . DH.Seconds

-------------------------------------------------------------------------------
-- Delta combinators
-------------------------------------------------------------------------------

secs :: Int -> Delta
secs n =
  canonicalizeDelta
    $ Delta mempty
    $ Duration
    $ DH.Duration 0 0 (fromIntegral n) 0

mins :: Int -> Delta
mins n =
  canonicalizeDelta
    $ Delta mempty
    $ Duration
    $ DH.Duration 0 (fromIntegral n) 0 0

hours :: Int -> Delta
hours n =
  canonicalizeDelta
    $ Delta mempty
    $ Duration
    $ DH.Duration (fromIntegral n) 0 0 0

days :: Int -> Delta
days n = flip Delta mempty $ Period $
  DH.Period {DH.periodYears = 0, DH.periodMonths = 0, DH.periodDays = n}

months :: Int -> Delta
months n = flip Delta mempty $ Period DH.Period {DH.periodYears = 0, DH.periodMonths = n, DH.periodDays = 0}

years :: Int -> Delta
years n = flip Delta mempty $ Period DH.Period {DH.periodYears = n, DH.periodMonths = 0, DH.periodDays = 0}

weeks :: Int -> Delta
weeks n = days (7 * n)

-- | Infinite list of days starting from a single date.
from :: Datetime -> [Datetime]
from = iterate (flip add (days 1))

-- | List of days between two points
-- Warning: Converts second Datetime to same timezone as the start
between :: Datetime -> Datetime -> [Datetime]
between start end = takeWhile (before end {zone = zone start}) (from start)

timezoneOffsetDelta :: TimezoneOffset -> Delta
timezoneOffsetDelta (TimezoneOffset minutes') =
  days dys <> hours hrs <> mins minutes
  where
    (hrs', minutes) = minutes' `divMod` 60
    (dys, hrs) = hrs' `divMod` 24

-- | Add two time deltas to get a new time delta
addDeltas :: Delta -> Delta -> Delta
addDeltas d1 = canonicalizeDelta . (<>) d1

-- | Subtract two deltas to get a new time delta
-- Warning: Time deltas cannot have negative values in fields. Any resulting
-- negative values will be trimmed to 0.
subDeltas :: Delta -> Delta -> Delta
subDeltas d1 d2
  | d1 < d2 = Delta mempty mempty
  | otherwise =
    canonicalizeDelta $
      Delta (Period newPeriod) (Duration newDuration)
  where
    (Delta (Period p) (Duration d)) = d1 <> d2
    (DH.Period pyr pmo pdy) = p
    (DH.Duration dhr dmin dsec _) = d
    newPeriod = DH.Period (max 0 pyr) (max 0 pmo) (max 0 pdy)
    newDuration = DH.Duration (max 0 dhr) (max 0 dmin) (max 0 dsec) 0

-- | Scales all fields of a delta by a natural number n
scaleDelta :: Int -> Delta -> Maybe Delta
scaleDelta n (Delta (Period p) (Duration d))
  | n < 1 = Nothing
  | otherwise =
    Just $ canonicalizeDelta $
      Delta (Period newPeriod) (Duration newDuration)
  where
    DH.Period py pm pd = p
    DH.Duration (DH.Hours dh) (DH.Minutes dm) (DH.Seconds ds) _ = d
    newPeriod = DH.Period (n * py) (n * pm) (n * pd)
    newDuration =
      DH.Duration
        (DH.Hours $ (fromIntegral n) * dh)
        (DH.Minutes $ (fromIntegral n) * dm)
        (DH.Seconds $ (fromIntegral n) * ds)
        (DH.NanoSeconds 0)

-------------------------------------------------------------------------------
-- Ordering
-------------------------------------------------------------------------------

instance Ord Datetime where
  d1 `compare` d2 = (datetimeToDateTime $ toUTC d1) `compare` (datetimeToDateTime $ toUTC d2)

-- | Check if first date occurs before a given date
before :: Datetime -> Datetime -> Bool
before = (<)

-- | Check if first date occurs after a given date
after :: Datetime -> Datetime -> Bool
after = (>)

-------------------------------------------------------------------------------
-- Calendar Arithmetic
-------------------------------------------------------------------------------

-- | Add a delta to a date
add :: Datetime -> Delta -> Datetime
add dt (Delta (Period period) (Duration duration)) =
  dateTimeToDatetime tz $ DateTime (dateAddPeriod d period) tod
  where
    -- Data.Hourglass.DateTime with duration added
    (DateTime d tod) = DH.timeAdd (datetimeToDateTime dt) duration
    tz = TimezoneOffset $ zone dt

-- | Subtract a delta from a date (Delta should be positive)
sub :: Datetime -> Delta -> Datetime
sub dt (Delta (Period period) (Duration duration)) =
  dateTimeToDatetime tz $ DateTime (dateSubPeriod d period) tod
  where
    (DateTime d tod) = DH.timeAdd (datetimeToDateTime dt) (negateDuration duration)
    tz = TimezoneOffset $ zone dt

-- | Get the difference between two dates
-- Warning: this function expects both datetimes to be in the same timezone
diff :: Datetime -> Datetime -> Delta
diff d1' d2' = Delta period duration
  where
    (d1, d2) = dateTimeToDatetimeAndOrderDateTime (toUTC d1') (toUTC d2')
    period = buildPeriodDiff d1 mempty
    d1PlusPeriod = dateTimeAddPeriod d1 $ unPeriod period
    duration = buildDurDiff d1PlusPeriod mempty
    -- Build the period part of the Delta
    buildPeriodDiff :: DH.DateTime -> DH.Period -> Period
    buildPeriodDiff dt p
      | dtpYrs <= d2 = buildPeriodDiff dt pYrs
      | dtpMos <= d2 = buildPeriodDiff dt pMos
      | dtpDys <= d2 = buildPeriodDiff dt pDys
      | otherwise = Period p
      where
        (Period pYrs) = Period p <> dPeriod (years 1)
        (Period pMos) = Period p <> dPeriod (months 1)
        (Period pDys) = Period p <> dPeriod (days 1)
        dtpYrs = dateTimeAddPeriod dt pYrs
        dtpMos = dateTimeAddPeriod dt pMos
        dtpDys = dateTimeAddPeriod dt pDys
    -- Build the duration part of the delta
    buildDurDiff :: DH.DateTime -> DH.Duration -> Duration
    buildDurDiff dt d
      | d1dHrs <= d2 = buildDurDiff dt dHrs
      | d1dMns <= d2 = buildDurDiff dt dMns
      | d1dScs <= d2 = buildDurDiff dt dScs
      | otherwise = Duration d
      where
        dHrs = d {DH.durationHours = DH.durationHours d + 1}
        dMns = d {DH.durationMinutes = DH.durationMinutes d + 1}
        dScs = d {DH.durationSeconds = DH.durationSeconds d + 1}
        d1dHrs = DH.timeAdd dt dHrs
        d1dMns = DH.timeAdd dt dMns
        d1dScs = DH.timeAdd dt dScs

-- | Check whether a date lies within an interval
within :: Datetime -> Interval -> Bool
within dt (Interval start stop) =
  startDate <= origDate && origDate <= endDate
  where
    origDate = datetimeToDateTime dt
    startDate = datetimeToDateTime start
    endDate = datetimeToDateTime stop

-- | Get the difference (in days) between two dates
daysBetween :: Datetime -> Datetime -> Delta
daysBetween d1' d2' =
  Delta (Period $ DH.Period 0 0 (abs durDays)) mempty
  where
    (d1, d2) = dateTimeToDatetimeAndOrderDateTime (toUTC d1') (toUTC d2')
    duration = fst $ DH.fromSeconds $ DH.timeDiff d1 d2
    durDays =
      let (DH.Hours hrs) = DH.durationHours duration
       in fromIntegral hrs `div` 24

-- | Get the date of the first day in a month of a given year
fomonth :: Int -> DH.Month -> Datetime
fomonth y m =
  dateTimeToDatetime DH.timezone_UTC $
    DateTime (Date y m 1) (TimeOfDay 0 0 0 0)

-- | Get the date of the last day in a month of a given year
eomonth :: Int -> DH.Month -> Datetime
eomonth y m = sub foNextMonth $ Delta (Period $ DH.Period 0 0 1) mempty
  where
    (year, nextMonth) -- if next month is January, inc year (will be dec in `sub` above)
      | fromEnum m == 11 = (y + 1, January)
      | otherwise = (y, toEnum $ fromEnum m + 1)
    foNextMonth =
      dateTimeToDatetime DH.timezone_UTC $
        DateTime (Date year nextMonth 1) (TimeOfDay 0 0 0 0)

-------------------------------------------------------------------------------
-- Fiscal Quarters
-------------------------------------------------------------------------------

fiscalQuarters :: Int -> (Interval, Interval, Interval, Interval)
fiscalQuarters year = (q1 year, q2 year, q3 year, q4 year)

q1, q2, q3, q4 :: Int -> Interval
q1 year = Interval (fomonth year January) (eomonth year March)
q2 year = Interval (fomonth year April) (eomonth year June)
q3 year = Interval (fomonth year July) (eomonth year September)
q4 year = Interval (fomonth year January) (eomonth year March)

-------------------------------------------------------------------------------
-- Datetime Parsing
-------------------------------------------------------------------------------

-- | Parses either an ISO8601 DateAndTime string: "2014-04-05T17:25:04+05:00"
parseDatetime :: [Char] -> Maybe Datetime
parseDatetime timestr = do
  localTime <- localTimeParse ISO8601_DateAndTime timestr
  let dateTime = localTimeUnwrap localTime
  let tzOffset = localTimeGetTimezone localTime
  pure $ dateTimeToDatetime tzOffset dateTime

formatDatetime :: Datetime -> [Char]
formatDatetime = DH.timePrint ISO8601_DateAndTime . datetimeToDateTime

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

negatePeriod :: Period -> Period
negatePeriod (Period (DH.Period y m d)) = Period (DH.Period (- y) (- m) (- d))

negateDuration :: DH.Duration -> DH.Duration
negateDuration (DH.Duration h m s ns) = DH.Duration (- h) (- m) (- s) (- ns)

dateTimeAddPeriod :: DateTime -> DH.Period -> DateTime
dateTimeAddPeriod (DateTime ddate dtime) p =
  DateTime (dateAddPeriod ddate p) dtime

dateAddPeriod :: Date -> DH.Period -> Date
dateAddPeriod (Date yOrig mOrig dOrig) (DH.Period yDiff mDiff dDiff) =
  loop (yOrig + yDiff + yDiffAcc) mStartPos (dOrig + dDiff)
  where
    mStartPos' = fromEnum mOrig + mDiff
    (yDiffAcc', mStartPos) = mStartPos' `divMod` 12
    yDiffAcc
      | mStartPos < 0 = yDiffAcc' + 1
      | otherwise = yDiffAcc'
    loop y m d
      | d <= 0 =
        let (m', y') =
              if m == 0
                then (11, y - 1)
                else (m - 1, y)
         in loop y' m' (DC.gregorianMonthLength (fromIntegral y') (m' + 1) + d)
      | d <= dMonth = Date y (toEnum m) d
      | dDiff == 0 = Date y (toEnum m) dMonth
      | otherwise =
        let newDiff = d - dMonth
         in if m == 11
              then loop (y + 1) 0 newDiff
              else loop y (m + 1) newDiff
      where
        dMonth = DC.gregorianMonthLength (fromIntegral y) (m + 1)

dateSubPeriod :: Date -> DH.Period -> Date
dateSubPeriod date (DH.Period yDiff mDiff dDiff) =
  let (Date y m d) = subtractMonths mDiff $ subtractDays dDiff date
   in fixDate $ Date (y - yDiff) m d
  where
    subtractDays d date
      | d < 0 = panic "Negative days"
      | d == 0 = date
      | otherwise =
        subtractDays (d -1) $
          date `DH.timeAdd` mempty {DH.durationHours = (-24)}
    subtractMonths m date@(Date year mo day)
      | m < 0 = panic "Negative months"
      | m == 0 = date
      | otherwise =
        if mo == January
          then subtractMonths (m -1) $ Date (year - 1) December day
          else subtractMonths (m -1) $ Date year (toEnum $ fromEnum mo - 1) day
    normalize :: Date -> Date
    normalize (Date y m d) = Date y m (min lastMonthDay d)
      where
        lastMonthDay = DC.gregorianMonthLength (fromIntegral y) (fromEnum m + 1)

-- | Adding/Subtracting Deltas from dates can result in invalid DateTime values.
-- This function makes sure the resulting day of the month is valid and trims
-- accordingly.
fixDate :: Date -> Date
fixDate (Date yr mo dy) = Date yr mo day
  where
    day = min dy $ DC.gregorianMonthLength (fromIntegral yr) (fromEnum mo + 1)

dateTimeToDatetimeAndOrderDateTime :: Datetime -> Datetime -> (DateTime, DateTime)
dateTimeToDatetimeAndOrderDateTime d1' d2'
  | d1 <= d2 = (d1, d2)
  | otherwise = (d2, d1)
  where
    d1 = datetimeToDateTime d1'
    d2 = datetimeToDateTime d2'

minMax :: Ord a => a -> a -> a -> a
minMax mini maxi = max mini . min maxi

-------------------------------------------------------------------------------
-- System Time
-------------------------------------------------------------------------------

-- | Current system time in UTC
now :: IO Datetime
now = dateTimeToDatetime DH.timezone_UTC <$> dateCurrent

-- | Current system time in Local time
localNow :: IO Datetime
localNow = do
  tz <- timezoneCurrent
  alterTimezone tz <$> now
