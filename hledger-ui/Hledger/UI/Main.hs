{-|
hledger-ui - a hledger add-on providing a curses-style interface.
Copyright (c) 2007-2015 Simon Michael <simon@joyful.com>
Released under GPL version 3 or later.
-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

module Hledger.UI.Main where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Monad (forM_, void, when)
import Data.List (find)
import Data.List.Extra (nubSort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Graphics.Vty (mkVty)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory)
import System.FSNotify (Event(Modified), isPollingManager, watchDir, withManager)
import Brick

import qualified Brick.BChan as BC

import Hledger
import Hledger.Cli hiding (progname,prognameandversion)
import Hledger.UI.UIOptions
import Hledger.UI.UITypes
import Hledger.UI.UIState (toggleHistorical)
import Hledger.UI.Theme
import Hledger.UI.AccountsScreen
import Hledger.UI.RegisterScreen

----------------------------------------------------------------------

newChan :: IO (BC.BChan a)
newChan = BC.newBChan 10

writeChan :: BC.BChan a -> a -> IO ()
writeChan = BC.writeBChan


main :: IO ()
main = do
  opts@UIOpts{cliopts_=copts@CliOpts{inputopts_=iopts,rawopts_=rawopts}} <- getHledgerUIOpts
  -- when (debug_ $ cliopts_ opts) $ printf "%s\n" prognameandversion >> printf "opts: %s\n" (show opts)

  -- always generate forecasted periodic transactions; their visibility will be toggled by the UI.
  let copts' = copts{inputopts_=iopts{forecast_=forecast_ iopts <|> Just nulldatespan}}

  case True of
    _ | "help"            `inRawOpts` rawopts -> putStr (showModeUsage uimode)
    _ | "info"            `inRawOpts` rawopts -> runInfoForTopic "hledger-ui" Nothing
    _ | "man"             `inRawOpts` rawopts -> runManForTopic  "hledger-ui" Nothing
    _ | "version"         `inRawOpts` rawopts -> putStrLn prognameandversion
    -- _ | "binary-filename" `inRawOpts` rawopts -> putStrLn (binaryfilename progname)
    _                                         -> withJournalDo copts' (runBrickUi opts)

runBrickUi :: UIOpts -> Journal -> IO ()
runBrickUi uopts@UIOpts{cliopts_=copts@CliOpts{inputopts_=_iopts,reportspec_=rspec@ReportSpec{_rsReportOpts=ropts}}} j = do
  d <- getCurrentDay

  let

    -- hledger-ui's query handling is currently in flux, mixing old and new approaches.
    -- Related: #1340, #1383, #1387. Some notes and terminology:

    -- The *startup query* is the Query generated at program startup, from
    -- command line options, arguments, and the current date. hledger CLI
    -- uses this.

    -- hledger-ui/hledger-web allow the query to be changed at will, creating
    -- a new *runtime query* each time.

    -- The startup query or part of it can be used as a *constraint query*,
    -- limiting all runtime queries. hledger-web does this with the startup
    -- report period, never showing transactions outside those dates.
    -- hledger-ui does not do this.

    -- A query is a combination of multiple subqueries/terms, which are
    -- generated from command line options and arguments, ui/web app runtime
    -- state, and/or the current date.

    -- Some subqueries are generated by parsing freeform user input, which
    -- can fail. We don't want hledger users to see such failures except:

    -- 1. at program startup, in which case the program exits
    -- 2. after entering a new freeform query in hledger-ui/web, in which case
    --    the change is rejected and the program keeps running

    -- So we should parse those kinds of subquery only at those times. Any
    -- subqueries which do not require parsing can be kept separate. And
    -- these can be combined to make the full query when needed, eg when
    -- hledger-ui screens are generating their data. (TODO)

    -- Some parts of the query are also kept separate for UI reasons.
    -- hledger-ui provides special UI for controlling depth (number keys), 
    -- the report period (shift arrow keys), realness/status filters (RUPC keys) etc.
    -- There is also a freeform text area for extra query terms (/ key).
    -- It's cleaner and less conflicting to keep the former out of the latter.

    uopts' = uopts{
      cliopts_=copts{
         reportspec_=rspec{
            _rsQuery=filteredQuery $ _rsQuery rspec,  -- query with depth/date parts removed
            _rsReportOpts=ropts{
               depth_ =queryDepth $ _rsQuery rspec,  -- query's depth part
               period_=periodfromoptsandargs,       -- query's date part
               no_elide_=True,  -- avoid squashing boring account names, for a more regular tree (unlike hledger)
               empty_=not $ empty_ ropts,  -- show zero items by default, hide them with -E (unlike hledger)
               balanceaccum_=Historical  -- show historical balances by default (unlike hledger)
               }
            }
         }
      }
      where
        datespanfromargs = queryDateSpan (date2_ ropts) $ _rsQuery rspec
        periodfromoptsandargs =
          dateSpanAsPeriod $ spansIntersect [periodAsDateSpan $ period_ ropts, datespanfromargs]
        filteredQuery q = simplifyQuery $ And [queryFromFlags ropts, filtered q]
          where filtered = filterQuery (\x -> not $ queryIsDepth x || queryIsDate x)

    -- XXX move this stuff into Options, UIOpts
    theme = maybe defaultTheme (fromMaybe defaultTheme . getTheme) $
            maybestringopt "theme" $ rawopts_ copts
    mregister = maybestringopt "register" $ rawopts_ copts

    (scr, prevscrs) = case mregister of
      Nothing   -> (accountsScreen, [])
      -- with --register, start on the register screen, and also put
      -- the accounts screen on the prev screens stack so you can exit
      -- to that as usual.
      Just apat -> (rsSetAccount acct False registerScreen, [ascr'])
        where
          acct = fromMaybe (error' $ "--register "++apat++" did not match any account")  -- PARTIAL:
                 . firstMatch $ journalAccountNamesDeclaredOrImplied j
          firstMatch = case toRegexCI $ T.pack apat of
              Right re -> find (regexMatchText re)
              Left  _  -> const Nothing
          -- Initialising the accounts screen is awkward, requiring
          -- another temporary UIState value..
          ascr' = aScreen $
                  asInit d True
                    UIState{
                     astartupopts=uopts'
                    ,aopts=uopts'
                    ,ajournal=j
                    ,aScreen=asSetSelectedAccount acct accountsScreen
                    ,aPrevScreens=[]
                    ,aMode=Normal
                    }

    ui =
      (sInit scr) d True $
        (if change_ uopts' then toggleHistorical else id) -- XXX
          UIState{
           astartupopts=uopts'
          ,aopts=uopts'
          ,ajournal=j
          ,aScreen=scr
          ,aPrevScreens=prevscrs
          ,aMode=Normal
          }

    brickapp :: App UIState AppEvent Name
    brickapp = App {
        appStartEvent   = return
      , appAttrMap      = const theme
      , appChooseCursor = showFirstCursor
      , appHandleEvent  = \ui ev -> sHandle (aScreen ui) ui ev
      , appDraw         = \ui    -> sDraw   (aScreen ui) ui
      }

  -- print (length (show ui)) >> exitSuccess  -- show any debug output to this point & quit

  if not (watch_ uopts')
  then
    void $ Brick.defaultMain brickapp ui

  else do
    -- a channel for sending misc. events to the app
    eventChan <- newChan

    -- start a background thread reporting changes in the current date
    -- use async for proper child termination in GHCI
    let
      watchDate old = do
        threadDelay 1000000 -- 1 s
        new <- getCurrentDay
        when (new /= old) $ do
          let dc = DateChange old new
          -- dbg1IO "datechange" dc -- XXX don't uncomment until dbg*IO fixed to use traceIO, GHC may block/end thread
          -- traceIO $ show dc
          writeChan eventChan dc
        watchDate new

    withAsync 
      -- run this small task asynchronously:
      (getCurrentDay >>= watchDate) 
      -- until this main task terminates:
      $ \_async ->
      -- start one or more background threads reporting changes in the directories of our files
      -- XXX many quick successive saves causes the problems listed in BUGS
      -- with Debounce increased to 1s it easily gets stuck on an error or blank screen
      -- until you press g, but it becomes responsive again quickly.
      -- withManagerConf defaultConfig{confDebounce=Debounce 1} $ \mgr -> do
      -- with Debounce at the default 1ms it clears transient errors itself
      -- but gets tied up for ages
      withManager $ \mgr -> do
        dbg1IO "fsnotify using polling ?" $ isPollingManager mgr
        files <- mapM (canonicalizePath . fst) $ jfiles j
        let directories = nubSort $ map takeDirectory files
        dbg1IO "files" files
        dbg1IO "directories to watch" directories

        forM_ directories $ \d -> watchDir
          mgr
          d
          -- predicate: ignore changes not involving our files
          (\fev -> case fev of
            Modified f _ False -> f `elem` files
            -- Added    f _ -> f `elem` files
            -- Removed  f _ -> f `elem` files
            -- we don't handle adding/removing journal files right now
            -- and there might be some of those events from tmp files
            -- clogging things up so let's ignore them
            _ -> False
            )
          -- action: send event to app
          (\fev -> do
            -- return $ dbglog "fsnotify" $ showFSNEvent fev -- not working
            dbg1IO "fsnotify" $ show fev
            writeChan eventChan FileChange
            )

        -- and start the app. Must be inside the withManager block
        let mkvty = mkVty mempty
        vty0 <- mkvty
        void $ customMain vty0 mkvty (Just eventChan) brickapp ui
