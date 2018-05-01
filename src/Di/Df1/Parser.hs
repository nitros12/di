{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Di.Df1.Parser
 ( parseLog
 ) where

import Control.Applicative ((<|>), many, empty)
import Control.Monad (guard)
import Data.Bits (shiftL)
import Data.Char (ord)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Function (fix)
import Data.Functor (($>))
import qualified Data.Attoparsec.ByteString as AB
import qualified Data.Attoparsec.ByteString.Char8 as A8
import Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import qualified Data.Time as Time
import qualified Data.Time.Clock.System as Time
import Data.Word (Word8, Word16, Word32)

import Di.Types as Di
 (Log(Log), Message(Message),
  Level(Debug, Info, Notice, Warning, Error, Critical, Alert, Emergency),
  Path(Attr, Push, Root), Segment(Segment), Key(Key), Value(Value))

--------------------------------------------------------------------------------

parseLog :: AB.Parser Di.Log
parseLog = (AB.<?> "parseLog") $ do
  t <- AB.skipWhile (== 32) *> pIso8601
  p <- AB.skipWhile (== 32) *> pPath
  l <- AB.skipWhile (== 32) *> pLevel
  m <- AB.skipWhile (== 32) *> pMessage
  pure (Log (Time.utcToSystemTime t) l p m)

pIso8601 :: AB.Parser Time.UTCTime
{-# INLINE pIso8601 #-}
pIso8601 = (AB.<?> "pIso8601") $ do
  year <- (pNum4Digits AB.<?> "year") <* (AB.skip (== 45) AB.<?> "-")
  month <- (pNum2Digits AB.<?> "month") <* (AB.skip (== 45) AB.<?> "-")
  day <- (pNum2Digits AB.<?> "day") <* (AB.skip (== 84) AB.<?> "T")
  Just tday <- pure (Time.fromGregorianValid
     (fromIntegral year) (fromIntegral month) (fromIntegral day))
  hour <- (pNum2Digits AB.<?> "hour") <* (AB.skip (== 58) AB.<?> ":")
  min' <- (pNum2Digits AB.<?> "minute") <* (AB.skip (== 58) AB.<?> ":")
  sec <- (pNum2Digits AB.<?> "second") <* (AB.skip (== 46) AB.<?> ".")
  nsec <- (pNum9Digits AB.<?> "nanosecond") <* (AB.skip (== 90) AB.<?> "Z")
  Just ttod <- pure (Time.makeTimeOfDayValid
     (fromIntegral hour) (fromIntegral min')
     (fromIntegral sec + (fromIntegral nsec / 1000000000)))
  pure (Time.UTCTime tday (Time.timeOfDayToTime ttod))

pNum1Digit :: AB.Parser Word8
{-# INLINE pNum1Digit #-}
pNum1Digit = AB.satisfyWith (subtract 48) (< 10) AB.<?> "pNum1Digit"

pNum2Digits :: AB.Parser Word8
{-# INLINE pNum2Digits #-}
pNum2Digits = (AB.<?> "pNum2Digits") $ do
  (+) <$> fmap (* 10) pNum1Digit <*> pNum1Digit

pNum4Digits :: AB.Parser Word16
{-# INLINE pNum4Digits #-}
pNum4Digits = (AB.<?> "pNum4Digits") $ do
  (\a b c d -> a + b + c + d)
     <$> fmap ((* 1000) . fromIntegral) pNum1Digit
     <*> fmap ((* 100) . fromIntegral) pNum1Digit
     <*> fmap ((* 10) . fromIntegral) pNum1Digit
          <*> fmap fromIntegral pNum1Digit

pNum9Digits :: AB.Parser Word32
{-# INLINE pNum9Digits #-}
pNum9Digits = (AB.<?> "pNum9Digits") $ do
  (\a b c d e f g h i -> a + b + c + d + e + f + g + h + i)
     <$> fmap ((* 100000000) . fromIntegral) pNum1Digit
     <*> fmap ((* 10000000) . fromIntegral) pNum1Digit
     <*> fmap ((* 1000000) . fromIntegral) pNum1Digit
     <*> fmap ((* 100000) . fromIntegral) pNum1Digit
     <*> fmap ((* 10000) . fromIntegral) pNum1Digit
     <*> fmap ((* 1000) . fromIntegral) pNum1Digit
     <*> fmap ((* 100) . fromIntegral) pNum1Digit
     <*> fmap ((* 10) . fromIntegral) pNum1Digit
     <*> fmap fromIntegral pNum1Digit

pLevel :: AB.Parser Di.Level
{-# INLINE pLevel #-}
pLevel = (AB.<?> "pLevel") $
  -- In decreasing frequency we expect logs to happen.
  -- We expect 'Debug' to mostly be muted, so 'Info' is prefered.
  (AB.string "INFO"      $> Di.Info)     <|>
  (AB.string "DEBUG"     $> Di.Debug)    <|>
  (AB.string "NOTICE"    $> Di.Notice)   <|>
  (AB.string "WARNING"   $> Di.Warning)  <|>
  (AB.string "ERROR"     $> Di.Error)    <|>
  (AB.string "CRITICAL"  $> Di.Critical) <|>
  (AB.string "ALERT"     $> Di.Alert)    <|>
  (AB.string "EMERGENCY" $> Di.Emergency)

pPath :: AB.Parser Di.Path
{-# INLINE pPath #-}
pPath = (AB.<?> "pLevel") $ do
    pRoot >>= fix (\k path -> ((pPush path <|> pAttr path) >>= k) <|> pure path)
  where
    pRoot :: AB.Parser Di.Path
    pRoot = (AB.<?> "pRoot") $ do
      AB.skip (== 47) AB.<?> "/"
      seg <- pUtf8LtoL =<< pDecodePercents =<< AB.takeWhile (/= 32)
      pure (Di.Root (Di.Segment (TL.toStrict seg)))
    pPush :: Di.Path -> AB.Parser Di.Path
    pPush path = (AB.<?> "pPush") $ do
      AB.skipWhile (== 32)  -- space
      AB.skip (== 47) AB.<?> "/"
      seg <- pUtf8LtoL =<< pDecodePercents =<< AB.takeWhile (/= 32)
      pure (Di.Push (Di.Segment (TL.toStrict seg)) path)
    pAttr :: Di.Path -> AB.Parser Di.Path
    pAttr path = do
      AB.skipWhile (== 32) -- space
      key <- pUtf8LtoL =<< pDecodePercents =<< AB.takeWhile (/= 61)
      AB.skip (== 61) AB.<?> "="
      val <- pUtf8LtoL =<< pDecodePercents =<< AB.takeWhile (/= 32)
      pure (Di.Attr (Key (TL.toStrict key)) (Value val) path)
    {-# INLINE pRoot #-}
    {-# INLINE pPush #-}
    {-# INLINE pAttr #-}

pMessage :: AB.Parser Di.Message
{-# INLINE pMessage #-}
pMessage = (AB.<?> "pMessage") $ do
  -- TODO drop trailing whitespace. Probably do it with Pipes.
  tl <- pUtf8LtoL =<< pDecodePercents =<< AB.takeWhile (/= 10)
  pure (Di.Message tl)

pUtf8LtoL :: BL.ByteString -> AB.Parser TL.Text
{-# INLINE pUtf8LtoL #-}
pUtf8LtoL = \bl -> case TL.decodeUtf8' bl of
   Right x -> pure x
   Left e -> fail (show e) AB.<?> "pUtf8LtoL"

pUtf8StoS :: B.ByteString -> AB.Parser T.Text
{-# INLINE pUtf8StoS #-}
pUtf8StoS = \b -> case T.decodeUtf8' b of
   Right x -> pure x
   Left e -> fail (show e) AB.<?> "pUtf8StoS"

-- | Parse @\"%FF\"@. Always consumes 3 bytes from the input, if successful.
pNumPercent :: AB.Parser Word8
{-# INLINE pNumPercent #-}
pNumPercent = (AB.<?> "pNum2Nibbles") $ do
   AB.skip (== 37) -- percent
   wh <- pHexDigit
   wl <- pHexDigit
   pure (shiftL wh 4 + wl)

pHexDigit :: AB.Parser Word8
{-# INLINE pHexDigit #-}
pHexDigit = AB.satisfyWith
  (\case w | w >= 48 && w <=  57 -> w - 48
           | w >= 65 && w <=  70 -> w - 55
           | w >= 97 && w <= 102 -> w - 87
           | otherwise -> 99)
  (\w -> w /= 99)

-- | Decodes all 'pNumPercent' occurences from the given input.
--
-- TODO: Make faster.
pDecodePercents :: B.ByteString -> AB.Parser BL.ByteString
{-# INLINE pDecodePercents #-}
pDecodePercents = \b -> either fail pure (AB.parseOnly p b) where
  p :: AB.Parser BL.ByteString
  p = AB.atEnd >>= \case
        True -> pure mempty
        False -> fix $ \k -> do
           b <- AB.peekWord8 >>= \case
              Nothing -> empty
              Just 37 -> fmap B.singleton pNumPercent
              Just _  -> AB.takeWhile1 (\w -> w /= 37)
           bls <- many k <* AB.endOfInput
           pure (mconcat (BL.fromStrict b : bls))




