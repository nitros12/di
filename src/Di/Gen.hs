-- | This module exports QuickCheck 'QC.Gen' stuff, mostly useful for testing
-- or generating fake logs.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings#-}

{-# OPTIONS_HADDOCK hide #-}

module Di.Gen
  ( genSegment
  , genKey
  , genValue
  , genMessage
  , genPathNext
  , genPaths
  , genPath
  , genSystemTime
  , genSystemTimeSoonAfter
  , genSystemTimesAscending
  , genLevel
  , genLog
  , genLogAfter
  , genLogs
  , ioPrintLogs
  ) where

import Control.Concurrent.STM (atomically, writeTQueue)
import Data.String (fromString)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Time.Clock.System as Time
import qualified Test.QuickCheck as QC

import qualified Di
import Di.Misc (iterateM)
import qualified Di.Types as Di (diPath, diLogs, diMax)

--------------------------------------------------------------------------------

genSegment :: QC.Gen Di.Segment
genSegment = fromString <$> QC.arbitrary

genKey :: QC.Gen Di.Key
genKey = fromString <$> QC.arbitrary

genValue :: QC.Gen Di.Value
genValue = fromString <$> QC.arbitrary

genMessage :: QC.Gen Di.Message
genMessage = fromString <$> QC.arbitrary

genPathNext :: Di.Path -> QC.Gen Di.Path
genPathNext p0 = case p0 of
  Di.Root _ -> QC.frequency
    [ (3, Di.Push <$> genSegment <*> pure p0)
    , (2, Di.Attr <$> genKey <*> genValue <*> pure p0) ]
  Di.Push _ p -> QC.frequency
    [ (3, Di.Push <$> genSegment <*> pure p0)
    , (2, Di.Attr <$> genKey <*> genValue <*> pure p0)
    , (1, pure p) ]
  Di.Attr _ _ p -> QC.frequency
    [ (3, Di.Push <$> genSegment <*> pure p0)
    , (2, Di.Attr <$> genKey <*> genValue <*> pure p0)
    , (1, pure p) ]

-- | Infinite list.
genPaths :: QC.Gen [Di.Path]
genPaths = iterateM genPathNext =<< fmap Di.Root genSegment

genPath :: QC.Gen Di.Path
genPath = (!!) <$> genPaths <*> QC.choose (0, 30)

genSystemTime :: QC.Gen Time.SystemTime
genSystemTime = do
  a <- fmap abs QC.arbitrary
  b <- QC.choose (0, 1000000000)
  pure (Time.MkSystemTime a b)

genSystemTimeSoonAfter :: Time.SystemTime -> QC.Gen Time.SystemTime
genSystemTimeSoonAfter (Time.MkSystemTime a _) = do
  a' <- (a +) <$> QC.choose (1, 1000)
  b' <- QC.choose (0, 1000000000)
  pure (Time.MkSystemTime a' b')

-- | Infinite list.
genSystemTimesAscending :: QC.Gen [Time.SystemTime]
genSystemTimesAscending = iterateM genSystemTimeSoonAfter =<< genSystemTime

genLevel :: QC.Gen Di.Level
genLevel = QC.frequency
  [ (30, pure Di.Debug)
  , (20, pure Di.Info)
  , (16, pure Di.Notice)
  , (12, pure Di.Warning)
  , (8,  pure Di.Error)
  , (4,  pure Di.Critical)
  , (3,  pure Di.Alert)
  , (1,  pure Di.Emergency) ]

genLog :: QC.Gen Di.Log
genLog = Di.Log <$> genSystemTime <*> genLevel <*> genPath <*> genMessage

genLogAfter :: Di.Log -> QC.Gen Di.Log
genLogAfter l0 = Di.Log
  <$> genSystemTimeSoonAfter (Di.logTime l0)
  <*> genLevel
  <*> genPathNext (Di.logPath l0)
  <*> genMessage

-- | Infinite list.
genLogs :: QC.Gen [Di.Log]
genLogs = iterateM genLogAfter =<< genLog

ioPrintLogs :: [Di.Log] -> IO ()
ioPrintLogs logs = do
  Di.new "unused" $ \di -> do
     mapM_ (atomically . writeTQueue (Di.diLogs di)) logs