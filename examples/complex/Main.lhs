\subsubsection{Module header and import directives}
\begin{code}
{-# LANGUAGE CPP                     #-}
{-# LANGUAGE FlexibleContexts        #-}
{-# LANGUAGE MultiParamTypeClasses   #-}
{-# LANGUAGE ScopedTypeVariables     #-}

#if defined(linux_HOST_OS)
#define LINUX
#endif

{- define the parallel procedures that create messages -}
#define RUN_ProcMessageOutput
#define RUN_ProcObserveIO
#undef RUN_ProcObseverSTM
#undef RUN_ProcObseveDownload
#define RUN_ProcRandom
#define RUN_ProcMonitoring
#define RUN_ProcBufferDump
#define RUN_ProcCounterOutput

module Main
  ( main )
  where

import           Control.Concurrent (threadDelay)
import qualified Control.Concurrent.Async as Async
import           Control.Monad (forM_, when)
import           Data.Aeson (ToJSON (..), Key, Value (..))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.HashMap.Strict as HM
import           Data.Maybe (isJust)
import           Data.Text (Text, pack)
#ifdef ENABLE_OBSERVABLES
#ifdef RUN_ProcObseverSTM
import           Control.Monad (forM)
import           GHC.Conc.Sync (atomically, STM, TVar, newTVar, readTVar, writeTVar)
#endif
#endif
#ifdef LINUX
#ifdef RUN_ProcObseveDownload
import qualified Data.ByteString.Char8 as BS8
import           Network.Download (openURI)
#endif
#endif
import           System.Random

import           Cardano.BM.Backend.Aggregation
import           Cardano.BM.Backend.Monitoring
import           Cardano.BM.Backend.Switchboard (Switchboard, readLogBuffer)
import           Cardano.BM.Backend.TraceForwarder
#ifdef LINUX
import           Cardano.BM.Scribe.Systemd
#endif

import qualified Cardano.BM.Configuration.Model as CM
import           Cardano.BM.Counters (readCounters)
import           Cardano.BM.Data.Aggregated (Measurable (..))
import           Cardano.BM.Data.AggregatedKind
import           Cardano.BM.Data.BackendKind
import           Cardano.BM.Data.Configuration (RemoteAddr(..))
import           Cardano.BM.Data.Counter
import           Cardano.BM.Data.LogItem
import           Cardano.BM.Data.MonitoringEval
import           Cardano.BM.Data.Output
import           Cardano.BM.Data.Rotation
import           Cardano.BM.Data.Severity
import           Cardano.BM.Data.SubTrace
import           Cardano.BM.Data.Trace
import           Cardano.BM.Data.Tracer hiding(mkObject)
#ifdef ENABLE_OBSERVABLES
import           Cardano.BM.Configuration
import           Cardano.BM.Data.Observable
import           Cardano.BM.Observer.Monadic (bracketObserveIO)
#ifdef RUN_ProcObseverSTM
import qualified Cardano.BM.Observer.STM as STM
#endif
#endif
import           Cardano.BM.Plugin
import           Cardano.BM.Setup
import           Cardano.BM.Trace

\end{code}

\subsubsection{Define configuration}
\begin{code}
prepare_configuration :: IO CM.Configuration
prepare_configuration = do
    c <- CM.empty
    CM.setMinSeverity c Info
    CM.setSetupBackends c [ KatipBK
                          , AggregationBK
                          , MonitoringBK
                          -- , TraceForwarderBK -- testing for pipe
                          ]
    CM.setDefaultBackends c [KatipBK]
    CM.setSetupScribes c [ ScribeDefinition {
                              scName = "stdout"
                            , scKind = StdoutSK
                            , scFormat = ScText
                            , scPrivacy = ScPublic
                            , scMinSev = Notice
                            , scMaxSev = maxBound
                            , scRotation = Nothing
                            }
                         , ScribeDefinition {
                              scName = "logs/out.odd.json"
                            , scKind = FileSK
                            , scFormat = ScJson
                            , scPrivacy = ScPublic
                            , scMinSev = minBound
                            , scMaxSev = maxBound
                            , scRotation = Just $ RotationParameters
                                              { rpLogLimitBytes = 5000 -- 5kB
                                              , rpMaxAgeHours   = 24
                                              , rpKeepFilesNum  = 3
                                              }
                            }
                         , ScribeDefinition {
                              scName = "logs/out.even.json"
                            , scKind = FileSK
                            , scFormat = ScJson
                            , scPrivacy = ScPublic
                            , scMinSev = minBound
                            , scMaxSev = maxBound
                            , scRotation = Just $ RotationParameters
                                              { rpLogLimitBytes = 5000 -- 5kB
                                              , rpMaxAgeHours   = 24
                                              , rpKeepFilesNum  = 3
                                              }
                            }
                         , ScribeDefinition {
                              scName = "logs/downloading.json"
                            , scKind = FileSK
                            , scFormat = ScJson
                            , scPrivacy = ScPublic
                            , scMinSev = minBound
                            , scMaxSev = maxBound
                            , scRotation = Just $ RotationParameters
                                              { rpLogLimitBytes = 5000 -- 5kB
                                              , rpMaxAgeHours   = 24
                                              , rpKeepFilesNum  = 3
                                              }
                            }
                         , ScribeDefinition {
                              scName = "logs/out.txt"
                            , scKind = FileSK
                            , scFormat = ScText
                            , scPrivacy = ScPublic
                            , scMinSev = Info
                            , scMaxSev = maxBound
                            , scRotation = Just $ RotationParameters
                                              { rpLogLimitBytes = 5000 -- 5kB
                                              , rpMaxAgeHours   = 24
                                              , rpKeepFilesNum  = 3
                                              }
                            }
                         , ScribeDefinition {
                              scName = "logs/info.txt"
                            , scKind = FileSK
                            , scFormat = ScText
                            , scPrivacy = ScPublic
                            , scMinSev = Debug
                            , scMaxSev = Info
                            , scRotation = Just $ RotationParameters
                                              { rpLogLimitBytes = 5000 -- 5kB
                                              , rpMaxAgeHours   = 24
                                              , rpKeepFilesNum  = 3
                                              }
                            }
                         , ScribeDefinition {
                              scName = "logs/out.json"
                            , scKind = FileSK
                            , scFormat = ScJson
                            , scPrivacy = ScPublic
                            , scMinSev = minBound
                            , scMaxSev = maxBound
                            , scRotation = Just $ RotationParameters
                                              { rpLogLimitBytes = 50000000 -- 50 MB
                                              , rpMaxAgeHours   = 24
                                              , rpKeepFilesNum  = 13
                                              }
                            }
                         ]
#ifdef LINUX
    CM.setDefaultScribes c ["StdoutSK::stdout", "FileSK::logs/out.txt", "FileSK::logs/info.txt", "JournalSK::example-complex"]
#else
    CM.setDefaultScribes c ["StdoutSK::stdout"]
#endif
    CM.setScribes c "complex.random" (Just ["StdoutSK::stdout", "FileSK::logs/out.txt"])
    forM_ [(1::Int)..10] $ \x ->
      if odd x
      then
        CM.setScribes c ("complex.#aggregation.complex.observeSTM." <> pack (show x)) $ Just [ "FileSK::logs/out.odd.json" ]
      else
        CM.setScribes c ("complex.#aggregation.complex.observeSTM." <> pack (show x)) $ Just [ "FileSK::logs/out.even.json" ]

#ifdef LINUX
#ifdef ENABLE_OBSERVABLES
    CM.setSubTrace c "complex.observeDownload" (Just $ ObservableTraceSelf [IOStats,NetStats])
#endif
    CM.setBackends c "complex.observeDownload" (Just [KatipBK])
    CM.setScribes c "complex.observeDownload" (Just ["FileSK::logs/downloading.json"])
#endif
    CM.setSubTrace c "#messagecounters.switchboard" $ Just NoTrace
    CM.setSubTrace c "#messagecounters.katip"       $ Just NoTrace
    CM.setSubTrace c "#messagecounters.aggregation" $ Just NoTrace
    CM.setBackends c "#messagecounters.switchboard" $ Just [KatipBK]
    CM.setSubTrace c "#messagecounters.monitoring"  $ Just NoTrace

    CM.setSubTrace c "complex.random" (Just $ TeeTrace "ewma")
#ifdef ENABLE_OBSERVABLES
    CM.setSubTrace c "complex.observeIO" (Just $ ObservableTraceSelf [GhcRtsStats,MemoryStats])
    forM_ [(1::Int)..10] $ \x ->
      CM.setSubTrace
        c
        ("complex.observeSTM." <> (pack $ show x))
        (Just $ ObservableTraceSelf [GhcRtsStats,MemoryStats])
#endif

    CM.setBackends c "complex.message" (Just [AggregationBK, KatipBK, TraceForwarderBK])
    CM.setBackends c "complex.random" (Just [KatipBK])
    CM.setBackends c "complex.random.ewma" (Just [AggregationBK])
    CM.setBackends c "complex.observeIO" (Just [AggregationBK, MonitoringBK])

    forM_ [(1::Int)..10] $ \x -> do
      CM.setBackends c
        ("complex.observeSTM." <> pack (show x))
        (Just [AggregationBK])
      CM.setBackends c
        ("complex.#aggregation.complex.observeSTM." <> pack (show x))
        (Just [KatipBK])

    CM.setAggregatedKind c "complex.random.rr" (Just StatsAK)
    CM.setAggregatedKind c "complex.random.ewma.rr" (Just (EwmaAK 0.22))

    CM.setBackends c "complex.#aggregation.complex.message" (Just [MonitoringBK])
    CM.setBackends c "complex.#aggregation.complex.monitoring" (Just [MonitoringBK])

    CM.setScribes c "complex.counters" (Just ["StdoutSK::stdout","FileSK::logs/out.json"])

    CM.setGUIport c 13790
\end{code}

output could also be forwarded using a pipe:
\begin{spec}
    CM.setForwardTo c (Just $ RemotePipe "logs/pipe")
    CM.setForwardTo c (Just $ RemotePipe "\\\\.\\pipe\\acceptor") -- on Windows
\end{spec}

\begin{code}
    CM.setForwardTo c (Just $ RemoteSocket "127.0.0.1" "42999")
    CM.setTextOption c "forwarderMinSeverity" "Warning"  -- sets min severity filter in forwarder

    CM.setForwardDelay c (Just 1000)

    CM.setMonitors c $ HM.fromList
        [ ( "complex.monitoring"
          , ( Just (Compare "monitMe" (GE, OpMeasurable 10))
            , Compare "monitMe" (GE, OpMeasurable 42)
            , [CreateMessage Warning "MonitMe is greater than 42!"]
            )
          )
        , ( "complex.#aggregation.complex.monitoring"
          , ( Just (Compare "monitMe.fcount" (GE, OpMeasurable 8))
            , Compare "monitMe.mean" (GE, OpMeasurable 41)
            , [CreateMessage Warning "MonitMe.mean is greater than 41!"]
            )
          )
        , ( "complex.observeIO.close"
          , ( Nothing
            , Compare "complex.observeIO.close.Mem.size" (GE, OpMeasurable 25)
            , [CreateMessage Warning "closing mem size is greater than 25!"]
            )
          )
        ]
    CM.setBackends c "complex.monitoring" (Just [AggregationBK, KatipBK, MonitoringBK])
    return c

\end{code}

\subsubsection{Dump the log buffer periodically}
\begin{code}
dumpBuffer :: Switchboard Text -> Trace IO Text -> IO (Async.Async ())
dumpBuffer sb trace = do
  logInfo trace "starting buffer dump"
  Async.async (loop trace)
 where
    loop tr = do
        threadDelay 25000000  -- 25 seconds
        buf <- readLogBuffer sb
        forM_ buf $ \(logname, LogObject _ lometa locontent) -> do
            let tr' = modifyName (\n -> "#buffer" <> "." <> n <> "." <> logname) tr
            traceNamedObject tr' (lometa, locontent)
        loop tr
\end{code}

\subsubsection{Thread that outputs a random number to a |Trace|}
\begin{code}
randomThr :: Trace IO Text -> IO (Async.Async ())
randomThr trace = do
  logInfo trace "starting random generator"
  let trace' = appendName "random" trace
  Async.async (loop trace')
 where
    loop tr = do
        threadDelay 500000  -- 0.5 second
        num <- randomRIO (42-42, 42+42) :: IO Double
        lo <- (,) <$> mkLOMeta Info Public <*> pure (LogValue "rr" (PureD num))
        traceNamedObject tr lo
        loop tr

\end{code}

\subsubsection{Thread that outputs a random number to monitoring |Trace|}
\begin{code}
#ifdef RUN_ProcMonitoring
monitoringThr :: Trace IO Text -> IO (Async.Async ())
monitoringThr trace = do
  logInfo trace "starting numbers for monitoring..."
  let trace' = appendName "monitoring" trace
  Async.async (loop trace')
 where
    loop tr = do
        threadDelay 500000  -- 0.5 second
        num <- randomRIO (42-42, 42+42) :: IO Double
        lo <- (,) <$> mkLOMeta Warning Public <*> pure (LogValue "monitMe" (PureD num))
        traceNamedObject tr lo
        loop tr
#endif
\end{code}

\subsubsection{Thread that observes an |IO| action}
\begin{code}
#ifdef ENABLE_OBSERVABLES
observeIO :: Configuration -> Trace IO Text -> IO (Async.Async ())
observeIO config trace = do
  logInfo trace "starting observer"
  proc <- Async.async (loop trace)
  return proc
  where
    loop tr = do
        threadDelay 5000000  -- 5 seconds
        let tr' = appendName "observeIO" tr
        _ <- bracketObserveIO config tr' Warning "complex.observeIO" $ do
            num <- randomRIO (100000, 200000) :: IO Int
            ls <- return $ reverse $ init $ reverse $ 42 : [1 .. num]
            pure $ const ls ()
        loop tr
#endif
\end{code}

\subsubsection{Threads that observe |STM| actions on the same TVar}
\begin{code}
#ifdef RUN_ProcObseverSTM
#ifdef ENABLE_OBSERVABLES
observeSTM :: Configuration -> Trace IO Text -> IO [Async.Async ()]
observeSTM config trace = do
  logInfo trace "starting STM observer"
  tvar <- atomically $ newTVar ([1..1000]::[Int])
  -- spawn 10 threads
  proc <- forM [(1::Int)..10] $ \x -> Async.async (loop trace tvar (pack $ show x))
  return proc
  where
    loop tr tvarlist trname = do
        threadDelay 10000000  -- 10 seconds
        STM.bracketObserveIO config tr Warning ("observeSTM." <> trname) (stmAction tvarlist)
        loop tr tvarlist trname

stmAction :: TVar [Int] -> STM ()
stmAction tvarlist = do
  list <- readTVar tvarlist
  writeTVar tvarlist $! (++) [42] $ reverse $ init $ reverse $ list
  pure ()
#endif
#endif
\end{code}

\subsubsection{Thread that observes an |IO| action which downloads a text in
order to observe the I/O statistics}
\begin{code}
#ifdef LINUX
#ifdef RUN_ProcObseveDownload
#ifdef ENABLE_OBSERVABLES
observeDownload :: Configuration -> Trace IO Text -> IO (Async.Async ())
observeDownload config trace = do
  proc <- Async.async (loop trace)
  return proc
  where
    loop tr = do
        threadDelay 1000000  -- 1 second
        let tr' = appendName "observeDownload" tr
        bracketObserveIO config tr' Warning "complex.observeDownload" $ do
            license <- openURI "http://www.gnu.org/licenses/gpl.txt"
            case license of
              Right bs -> logNotice tr' $ pack $ BS8.unpack bs
              Left _ ->  return ()
            threadDelay 50000  -- .05 second
            pure ()
        loop tr
#endif
#endif
#endif
\end{code}

\subsubsection{Thread that periodically outputs a message}
\begin{code}
data Pet = Pet { name :: Text, age :: Int}
           deriving (Show)

mkObject :: [(Key, v)] -> KeyMap.KeyMap v
mkObject = KeyMap.fromList

instance ToObject Pet where
    toObject MinimalVerbosity _ = KeyMap.empty -- do not log
    toObject NormalVerbosity (Pet _ _) =
        mkObject [ ("kind", String "Pet") ]
    toObject MaximalVerbosity (Pet n a) =
        mkObject [ ("kind", String "Pet")
                 , ("name", toJSON n)
                 , ("age", toJSON a) ]
instance HasTextFormatter Pet where
    formatText pet _o = "Pet " <> name pet <> " is " <> pack (show (age pet)) <> " years old."
instance Transformable Text IO Pet where
    -- transform to JSON Object
    trTransformer MaximalVerbosity tr = trStructuredText MaximalVerbosity tr
    trTransformer MinimalVerbosity _tr = nullTracer
    -- transform to textual representation using |show|
    trTransformer _v tr = Tracer $ \pet -> do
        meta <- mkLOMeta Info Public
        traceWith tr $ ("pet", LogObject "pet" meta $ (LogMessage . pack . show) pet)

-- default privacy annotation: Public
instance HasPrivacyAnnotation Pet
instance HasSeverityAnnotation Pet where
    getSeverityAnnotation _ = Critical

#ifdef RUN_ProcMessageOutput
msgThr :: Trace IO Text -> IO (Async.Async ())
msgThr trace = do
  logInfo trace "start messaging .."
  let trace' = appendName "message" trace
  Async.async (loop trace')
  where
    loop tr = do
        threadDelay 3000000  -- 3 seconds
        logNotice tr "N O T I F I C A T I O N ! ! !"
        logDebug tr "a detailed debug message."
        logError tr "Boooommm .."
        traceWith (toLogObject' MaximalVerbosity tr) (Pet "bella" 8)
        loop tr
#endif

\end{code}

\subsubsection{Thread that periodically outputs operating system counters}
\begin{code}
#ifdef RUN_ProcCounterOutput
countersThr :: Trace IO Text -> IO (Async.Async ())
countersThr trace = do
  let trace' = appendName "counters" trace
  Async.async (loop trace')
  where
    loop tr = do
        threadDelay 3000000  -- 3 seconds
        let counters = [MemoryStats, ProcessStats, NetStats, IOStats, SysStats]
        cts <- readCounters (ObservableTraceSelf counters)
        mle <- mkLOMeta Info Confidential
        forM_ cts $ \c@(Counter _ct cn cv) ->
            traceNamedObject tr (mle, LogValue (nameCounter c <> "." <> cn) cv)
        loop tr
#endif

\end{code}

\subsubsection{Main entry point}
\begin{code}
main :: IO ()
main = do
    -- create configuration
    c <- prepare_configuration

    -- create initial top-level Trace
    (tr :: Trace IO Text, sb) <- setupTrace_ c "complex"

    -- load plugins
{-    Cardano.BM.Backend.Editor.plugin c tr sb
      >>= loadPlugin sb -}
    forwardTo <- CM.getForwardTo c
    when (isJust forwardTo) $
      Cardano.BM.Backend.TraceForwarder.plugin c tr sb "forwarderMinSeverity" (return [])
        >>= loadPlugin sb
    Cardano.BM.Backend.Aggregation.plugin c tr sb
      >>= loadPlugin sb
    Cardano.BM.Backend.Monitoring.plugin c tr sb
      >>= loadPlugin sb
#ifdef LINUX
    -- inspect logs with 'journalctl -t example-complex'
    Cardano.BM.Scribe.Systemd.plugin c tr sb "example-complex"
      >>= loadPlugin sb
#endif
    logNotice tr "starting program; hit CTRL-C to terminate"

#ifdef RUN_ProcBufferDump
    procDump <- dumpBuffer sb tr
#endif

#ifdef RUN_ProcRandom
    {- start thread sending unbounded sequence of random numbers
       to a trace which aggregates them into a statistics -}
    procRandom <- randomThr tr
#endif
#ifdef RUN_ProcMonitoring
    procMonitoring <- monitoringThr tr
#endif
#ifdef RUN_ProcObserveIO
    -- start thread endlessly reversing lists of random length
#ifdef ENABLE_OBSERVABLES
    procObsvIO <- observeIO c tr
#endif
#endif
#ifdef RUN_ProcObseverSTM
    -- start threads endlessly observing STM actions operating on the same TVar
#ifdef ENABLE_OBSERVABLES
    procObsvSTMs <- observeSTM c tr
#endif
#endif
#ifdef LINUX
#ifdef RUN_ProcObseveDownload
    -- start thread endlessly which downloads sth in order to check the I/O usage
#ifdef ENABLE_OBSERVABLES
    procObsvDownload <- observeDownload c tr
#endif
#endif
#endif

#ifdef RUN_ProcMessageOutput
    -- start a thread to output a text messages every n seconds
    procMsg <- msgThr tr
#endif

#ifdef RUN_ProcCounterOutput
    procCounters <- countersThr tr
#endif

#ifdef RUN_ProcCounterOutput
    _ <- Async.waitCatch procCounters
#endif

#ifdef RUN_ProcMessageOutput
    -- wait for message thread to finish, ignoring any exception
    _ <- Async.waitCatch procMsg
#endif

#ifdef LINUX
#ifdef RUN_ProcObseveDownload
    -- wait for download thread to finish, ignoring any exception
#ifdef ENABLE_OBSERVABLES
    _ <- Async.waitCatch procObsvDownload
#endif
#endif
#endif
#ifdef RUN_ProcObseverSTM
    -- wait for observer thread to finish, ignoring any exception
#ifdef ENABLE_OBSERVABLES
    _ <- forM procObsvSTMs Async.waitCatch
#endif
#endif
#ifdef RUN_ProcObserveIO
    -- wait for observer thread to finish, ignoring any exception
#ifdef ENABLE_OBSERVABLES
    _ <- Async.waitCatch procObsvIO
#endif
#endif
#ifdef RUN_ProcRandom
    -- wait for random thread to finish, ignoring any exception
    _ <- Async.waitCatch procRandom
#endif
#ifdef RUN_ProcMonitoring
    _ <- Async.waitCatch procMonitoring
#endif
#ifdef RUN_ProcBufferDump
    _ <- Async.waitCatch procDump
#endif

    return ()

\end{code}
