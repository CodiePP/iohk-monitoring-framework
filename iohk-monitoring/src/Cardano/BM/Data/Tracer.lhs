
\subsection{Cardano.BM.Data.Tracer}
\label{code:Cardano.BM.Data.Tracer}

%if style == newcode
\begin{code}
{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE InstanceSigs          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances  #-}

module Cardano.BM.Data.Tracer
    ( Tracer (..)
    , Transformable (..)
    , ToLogObject (..)
    , ToObject (..)
    , traceWith
    -- * tracer transformers
    , natTracer
    , nullTracer
    , stdoutTracer
    , debugTracer
    , showTracing
    , trStructured
    -- * conditional tracing
    , condTracing
    , condTracingM
    -- * severity transformers
    , severityDebug
    , severityInfo
    , severityNotice
    , severityWarning
    , severityError
    , severityCritical
    , severityAlert
    , severityEmergency
    -- * privacy annotation transformers
    , annotateConfidential
    , annotatePublic
    -- * annotate context name
    , addName
    , setName
    ) where


import           Control.Monad.IO.Class (MonadIO (..))

import           Data.Aeson (Object, ToJSON (..), Value (..), encode)
import qualified Data.HashMap.Strict as HM
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Word (Word64)

import           Cardano.BM.Data.Aggregated
import           Cardano.BM.Data.LogItem (LogObject (..), LOContent (..),
                     LOMeta (..), PrivacyAnnotation (..), mkLOMeta)
import           Cardano.BM.Data.Severity (Severity (..))
import           Control.Tracer

\end{code}
%endif

This module extends the basic |Tracer| with one that keeps a list of context names to
create the basis for |Trace| which accepts messages from a Tracer and ends in the |Switchboard|
for further processing of the messages.

\begin{scriptsize}
\begin{verbatim}
   +-----------------------+
   |                       |
   |    external code      |
   |                       |
   +----------+------------+
              |
              |
        +-----v-----+
        |           |
        |  Tracer   |
        |           |
        +-----+-----+
              |
              |
  +-----------v------------+
  |                        |
  |        Trace           |
  |                        |
  +-----------+------------+
              |
  +-----------v------------+
  |      Switchboard       |
  +------------------------+

  +----------+ +-----------+
  |Monitoring| |Aggregation|
  +----------+ +-----------+

          +-------+
          |Logging|
          +-------+

+-------------+ +------------+
|Visualisation| |Benchmarking|
+-------------+ +------------+

\end{verbatim}
\end{scriptsize}

\subsubsection{ToLogObject - transforms a logged item to LogObject}
\label{code:ToLogObject}\index{ToLogObject}
\label{code:toLogObject}\index{ToLogObject!toLogObject}
The function |toLogObject| can be specialized for various environments
\begin{code}
class Monad m => ToLogObject m where
    toLogObject :: (ToObject a, Transformable a m b) => Tracer m (LogObject a) -> Tracer m b

instance ToLogObject IO where
    toLogObject :: (MonadIO m, ToObject a, Transformable a m b) => Tracer m (LogObject a) -> Tracer m b
    toLogObject tr =
        trTransformer tr

\end{code}

\begin{spec}
To be placed in ouroboros-network.

instance (MonadFork m, MonadTimer m) => ToLogObject m where
    toLogObject tr = Tracer $ \a -> do
        lo <- LogObject <$> pure ""
                        <*> (LOMeta <$> getMonotonicTime  -- must be evaluated at the calling site
                                    <*> (pack . show <$> myThreadId)
                                    <*> pure Debug
                                    <*> pure Public)
                        <*> pure (LogMessage a)
        traceWith tr lo

\end{spec}

\subsubsection{ToObject - transforms a logged item to JSON}\label{code:ToObject}\index{ToObject}\label{code:toObject}\index{ToObject!toObject}
Katip requires JSON objects to be logged as context. This
typeclass provides a default instance which uses |ToJSON| and
produces an empty object if 'toJSON' results in any type other than
|Object|. If you have a type you want to log that produces an Array
or Number for example, you'll want to write an explicit instance
here. You can trivially add a |ToObject| instance for something with
a ToJSON instance like:
\begin{spec}
instance ToObject Foo
\end{spec}

\begin{code}
class ToJSON a => ToObject a where
    toObject :: a -> Object
    default toObject :: a -> Object
    toObject v = case toJSON v of
        Object o     -> o
        s@(String _) -> HM.singleton "string" s
        _            -> mempty

instance ToObject () where
    toObject _ = mempty

instance ToObject String
instance ToObject Text
instance ToJSON a => ToObject (LogObject a)
instance ToJSON a => ToObject (LOContent a)

\end{code}

\subsubsection{A transformable Tracer}

Parameterised over the source Tracer (\emph{b}) and
the target Tracer (\emph{a}).

\begin{code}
class Monad m => Transformable a m b where
    trTransformer :: Tracer m (LogObject a) -> Tracer m b
    default trTransformer :: Tracer m (LogObject a) -> Tracer m b
    trTransformer _ = nullTracer

trFromIntegral :: (Integral b, MonadIO m) => Tracer m (LogObject a) -> Text -> Tracer m b
trFromIntegral tr name = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogValue name $ PureI $ fromIntegral arg)

trFromReal :: (Real b, MonadIO m) => Tracer m (LogObject a) -> Text -> Tracer m b
trFromReal tr name = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogValue name $ PureD $ realToFrac arg)

instance Transformable a IO Int where
    trTransformer tr = trFromIntegral tr "int"
instance Transformable a IO Integer where
    trTransformer tr = trFromIntegral tr "integer"
instance Transformable a IO Word64 where
    trTransformer tr = trFromIntegral tr "word64"
instance Transformable a IO Double where
    trTransformer tr = trFromReal tr "double"
instance Transformable a IO Float where
    trTransformer tr = trFromReal tr "float"
instance Transformable Text IO Text where
    trTransformer tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogMessage arg)
instance Transformable String IO String where
    trTransformer tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogMessage arg)
instance Transformable Text IO String where
    trTransformer tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogMessage $ T.pack arg)
instance Transformable String IO Text where
    trTransformer tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogMessage $ T.unpack arg)

trStructured :: (MonadIO m, ToJSON b) => Tracer m (LogObject a) -> Tracer m b
trStructured tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogStructured $ encode arg)

\end{code}

\subsubsection{Transformers for setting severity level}
The log |Severity| level of a LogObject can be altered.
\begin{code}
setSeverity :: Tracer m (LogObject a) -> Severity -> Tracer m (LogObject a)
setSeverity tr sev = Tracer $ \lo@(LogObject _nm meta@(LOMeta _ts _tid _sev _pr) _lc) ->
                                traceWith tr $ lo { loMeta = meta { severity = sev } }

severityDebug, severityInfo, severityNotice,
  severityWarning, severityError, severityCritical,
  severityAlert, severityEmergency  :: Tracer m (LogObject a) -> Tracer m (LogObject a)
severityDebug tr = setSeverity tr Debug
severityInfo tr = setSeverity tr Info
severityNotice tr = setSeverity tr Notice
severityWarning tr = setSeverity tr Warning
severityError tr = setSeverity tr Error
severityCritical tr = setSeverity tr Critical
severityAlert tr = setSeverity tr Alert
severityEmergency tr = setSeverity tr Emergency

\end{code}

\subsubsection{Transformers for setting privacy annotation}
The privacy annotation (|PrivacyAnnotation|) of the LogObject can
be altered with the following functions.
\begin{code}
setPrivacy :: Tracer m (LogObject a) -> PrivacyAnnotation -> Tracer m (LogObject a)
setPrivacy tr prannot = Tracer $ \lo@(LogObject _nm meta@(LOMeta _ts _tid _sev _pr) _lc) ->
                                traceWith tr $ lo { loMeta = meta { privacy = prannot } }

annotateConfidential, annotatePublic :: Tracer m (LogObject a) -> Tracer m (LogObject a)
annotateConfidential tr = setPrivacy tr Confidential
annotatePublic tr = setPrivacy tr Public

\end{code}

\subsubsection{Transformers for adding a name to the context}
This functions set or add names to the local context naming of |LogObject|.
\begin{code}
setName :: Tracer m (LogObject a) -> Text -> Tracer m (LogObject a)
setName tr nm = Tracer $ \lo@(LogObject _nm _meta _lc) ->
                                traceWith tr $ lo { loName = nm }

addName :: Tracer m (LogObject a) -> Text -> Tracer m (LogObject a)
addName tr nm = Tracer $ \lo@(LogObject nm0 _meta _lc) ->
                                if (T.length nm0) > 0
                                then
                                    traceWith tr $ lo { loName = nm0 <> "." <> nm }
                                else
                                    traceWith tr $ lo { loName = nm }
 
\end{code}