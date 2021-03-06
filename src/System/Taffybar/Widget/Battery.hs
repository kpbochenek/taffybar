{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-----------------------------------------------------------------------------
-- |
-- Module      : System.Taffybar.Widget.Battery
-- Copyright   : (c) Ivan A. Malison
-- License     : BSD3-style (see LICENSE)
--
-- Maintainer  : Ivan A. Malison
-- Stability   : unstable
-- Portability : unportable
--
-- This module provides battery widgets using the UPower system
-- service.
--
-- Currently it reports only the first battery it finds.  If it does
-- not find a battery, it just returns an obnoxious widget with
-- warning text in it.  Battery hotplugging is not supported.  These
-- more advanced features could be supported if there is interest.
-----------------------------------------------------------------------------
module System.Taffybar.Widget.Battery
  ( batteryBarNew
  , batteryBarNewWithFormat
  , textBatteryNew
  , defaultBatteryConfig
  ) where

import           Control.Applicative
import qualified Control.Exception.Enclosed as E
import           Control.Monad.Trans
import           Data.IORef
import           Data.Int (Int64)
import           Graphics.UI.Gtk
import           Safe (atMay)
import qualified System.IO as IO
import           Text.Printf (printf)
import           Text.StringTemplate

import           Prelude

import           System.Taffybar.Information.Battery
import           System.Taffybar.Widget.Generic.PollingBar
import           System.Taffybar.Widget.Generic.PollingLabel


-- | Just the battery info that will be used for display (this makes combining
-- several easier).
data BatteryWidgetInfo = BWI
  { seconds :: Maybe Int64
  , percent :: Int
  , status :: String
  } deriving (Eq, Show)

-- | Combination for 'BatteryWidgetInfo'.
-- If one battery lacks time information, combination has no time information
combine :: [BatteryWidgetInfo] -> Maybe BatteryWidgetInfo
combine [] = Nothing
combine bs =
  Just
    BWI
    { seconds = sum <$> sequence (seconds <$> bs)
    , percent = sum (percent <$> bs) `div` length bs
    , status = status $ head bs
    }

-- | Format a duration expressed as seconds to hours and minutes
formatDuration :: Maybe Int64 -> String
formatDuration Nothing = ""
formatDuration (Just secs) = let minutes = secs `div` 60
                                 hours = minutes `div` 60
                                 minutes' = minutes `mod` 60
                             in printf "%02d:%02d" hours minutes'

safeGetBatteryInfo :: IORef BatteryContext -> Int -> IO (Maybe BatteryInfo)
safeGetBatteryInfo mv i = do
  ctxt <- readIORef mv
  E.catchAny (getBatteryInfo ctxt) $ const reconnect
  where
    reconnect = do
      IO.hPutStrLn IO.stderr "reconnecting"
      ctxts <- batteryContextsNew
      let mctxt = ctxts `atMay` i
      case mctxt of
        Nothing -> IO.hPutStrLn IO.stderr "Could not reconnect to UPower"
        Just ctxt ->
          writeIORef mv ctxt
      return Nothing

getBatteryWidgetInfo :: IORef BatteryContext -> Int -> IO (Maybe BatteryWidgetInfo)
getBatteryWidgetInfo r i = do
  minfo <- safeGetBatteryInfo r i
  case minfo of
    Nothing -> return Nothing
    Just info -> do
      let battPctNum :: Int
          battPctNum = floor (batteryPercentage info)
          battTime :: Maybe Int64
          battTime = case batteryState info of
            BatteryStateCharging    -> Just $ batteryTimeToFull info
            BatteryStateDischarging -> Just $ batteryTimeToEmpty info
            _                       -> Nothing
          battStatus :: String
          battStatus = case batteryState info of
            BatteryStateCharging    -> "Charging"
            BatteryStateDischarging -> "Discharging"
            _                       -> "✔"
      return . Just $ BWI { seconds = battTime
                          , percent = battPctNum
                          , status = battStatus
                          }


-- | Given (maybe summarized) battery info and format: provides the string to display
formatBattInfo :: Maybe BatteryWidgetInfo -> String -> String
formatBattInfo Nothing _       =  ""
formatBattInfo (Just info) fmt =
  let tpl = newSTMP fmt
      tpl' = setManyAttrib [ ("percentage", (show . percent) info)
                           , ("time", formatDuration (seconds info))
                           , ("status", status info)
                           ] tpl
  in render tpl'

-- | Provides textual information regarding multiple batteries
battSumm :: [IORef BatteryContext] -> String -> IO String
battSumm rs fmt = do
  winfos <- traverse (uncurry getBatteryWidgetInfo) (rs `zip` [0..])
  let ws :: [BatteryWidgetInfo]
      ws = flatten winfos
      flatten []            = []
      flatten (Just a:as) = a:flatten as
      flatten (Nothing:as)  = flatten as
      combined = combine ws
  return $ formatBattInfo combined fmt


-- | A simple textual battery widget that auto-updates once every polling period
-- (specified in seconds). The displayed format is specified format string where
-- $percentage$ is replaced with the percentage of battery remaining and $time$
-- is replaced with the time until the battery is fully charged/discharged.
--
-- Multiple battery values are combined as follows:
-- - for time remaining, the largest value is used.
-- - for percentage, the mean is taken.
textBatteryNew :: [IORef BatteryContext]
                    -> String -- ^ Display format
                    -> Double -- ^ Poll period in seconds
                    -> IO Widget
textBatteryNew [] _ _ =
  let lbl :: Maybe String
      lbl = Just "No battery"
  in toWidget <$> labelNew lbl
textBatteryNew rs fmt pollSeconds = do
    l <- pollingLabelNew "" pollSeconds (battSumm rs fmt)
    widgetShowAll l
    return l


-- | Returns the current battery percent as a double in the range [0,
-- 1]
battPct :: IORef BatteryContext -> Int -> IO Double
battPct i r = do
  minfo <- safeGetBatteryInfo i r
  case minfo of
    Nothing   -> return 0
    Just info -> return (batteryPercentage info / 100)

-- | A default configuration for the graphical battery display.  The
-- bar will be red when power is critical (< 10%), green if it is full
-- (> 90%), and grey otherwise.
--
-- You can customize this with any of the options in 'BarConfig'
defaultBatteryConfig :: BarConfig
defaultBatteryConfig =
  defaultBarConfig colorFunc
  where
    colorFunc pct
      | pct < 0.1 = (1, 0, 0)
      | pct < 0.9 = (0.5, 0.5, 0.5)
      | otherwise = (0, 1, 0)


-- | A fancy graphical battery widget that represents batteries as colored
-- vertical bars (one per battery). There is also a textual percentage reppadout
-- next to the bars, containing a summary of battery information.
batteryBarNew :: MonadIO m => BarConfig -> Double -> m Widget
batteryBarNew battCfg = liftIO .
  batteryBarNewWithFormat battCfg "$percentage$%"

-- | A battery bar constructor which allows using a custom format string in
-- order to display more information, such as charging/discharging time and
-- status. An example: "$percentage$% ($time$) - $status$".
batteryBarNewWithFormat :: MonadIO m => BarConfig -> String -> Double -> m Widget
batteryBarNewWithFormat battCfg formatString pollSeconds =
  liftIO $ do
    battCtxt <- batteryContextsNew
    case battCtxt of
      [] -> do
        let lbl :: Maybe String
            lbl = Just "No battery"
        toWidget <$> labelNew lbl
      cs -> do
        b <- hBoxNew False 1
        rs <- traverse newIORef cs
        txt <- textBatteryNew rs formatString pollSeconds
        let ris :: [(IORef BatteryContext, Int)]
            ris = rs `zip` [0 ..]
        bars <-
          traverse
            (\(i, r) -> pollingBarNew battCfg pollSeconds (battPct i r))
            ris
        mapM_ (\bar -> boxPackStart b bar PackNatural 0) bars
        boxPackStart b txt PackNatural 0
        widgetShowAll b
        return (toWidget b)
