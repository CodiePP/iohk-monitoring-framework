
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
    , TracingVerbosity (..)
    , Transformable (..)
    , ToLogObject (..)
    , ToObject (..)
    , mkObject, emptyObject
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
import           Cardano.BM.Data.LogItem (LoggerName, LogObject (..),
                     LOContent (..), LOMeta (..), PrivacyAnnotation (..),
                     mkLOMeta)
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
\label{code:toLogObject'}\index{ToLogObject!toLogObject'}
\label{code:toLogObjectVerbose}\index{ToLogObject!toLogObjectVerbose}
\label{code:toLogObjectMinimal}\index{ToLogObject!toLogObjectMinimal}

The transformer |toLogObject| accepts any type for which a |ToObject| instance
is available and returns a |LogObject| which can be forwarded into the |Switchboard|.
It adds a verbosity hint of |NormalVerbosity|.
\\
A verbosity level |TracingVerbosity| can be passed to the transformer |toLogObject'|.

\begin{code}
class Monad m => ToLogObject m where
    toLogObject :: (ToObject a, Transformable a m b)
                => Tracer m (LogObject a) -> Tracer m b
    toLogObject' :: (ToObject a, Transformable a m b)
                 => TracingVerbosity -> Tracer m (LogObject a) -> Tracer m b
    toLogObjectVerbose :: (ToObject a, Transformable a m b)
                       => Tracer m (LogObject a) -> Tracer m b
    default toLogObjectVerbose :: (ToObject a, Transformable a m b)
                       => Tracer m (LogObject a) -> Tracer m b
    toLogObjectVerbose tr = trTransformer MaximalVerbosity tr
    toLogObjectMinimal :: (ToObject a, Transformable a m b)
                       => Tracer m (LogObject a) -> Tracer m b
    default toLogObjectMinimal :: (ToObject a, Transformable a m b)
                       => Tracer m (LogObject a) -> Tracer m b
    toLogObjectMinimal tr = trTransformer MinimalVerbosity tr

instance ToLogObject IO where
    toLogObject :: (MonadIO m, ToObject a, Transformable a m b)
                => Tracer m (LogObject a) -> Tracer m b
    toLogObject tr = trTransformer NormalVerbosity tr
    toLogObject' :: (MonadIO m, ToObject a, Transformable a m b)
                 => TracingVerbosity -> Tracer m (LogObject a) -> Tracer m b
    toLogObject' verb tr = trTransformer verb tr

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

\subsubsection{Verbosity levels}
\label{code:TracingVerbosity}\index{TracingVerbosity}
\label{code:MinimalVerbosity}\index{TracingVerbosity!MinimalVerbosity}
\label{code:NormalVerbosity}\index{TracingVerbosity!NormalVerbosity}
\label{code:MaximalVerbosity}\index{TracingVerbosity!MaximalVerbosity}
The tracing verbosity will be passed to instances of |ToObject| for rendering
the traced item accordingly.
\begin{code}
data TracingVerbosity = MinimalVerbosity | NormalVerbosity | MaximalVerbosity
                        deriving (Eq, Ord)

\end{code}

\subsubsection{ToObject - transforms a logged item to a JSON Object}
\label{code:ToObject}\index{ToObject}
\label{code:toObject}\index{ToObject!toObject}
Katip requires JSON objects to be logged as context. This
typeclass provides a default instance which uses |ToJSON| and
produces an empty object if 'toJSON' results in any type other than
|Object|. If you have a type you want to log that produces an Array
or Number for example, you'll want to write an explicit instance of
|ToObject|. You can trivially add a |ToObject| instance for something with
a |ToJSON| instance like:
\begin{spec}
instance ToObject Foo
\end{spec}
\\
The |toObject| function accepts a |TracingVerbosity| level as argument
and can render the traced item differently depending on the verbosity level.

\begin{code}
class ToObject a where
    toObject :: TracingVerbosity -> a -> Object
    default toObject :: ToJSON a => TracingVerbosity -> a -> Object
    toObject _ v = case toJSON v of
        Object o     -> o
        s@(String _) -> HM.singleton "string" s
        _            -> mempty

\end{code}

A helper function for creating an |Object| given a list of pairs, named items,
or the empty |Object|.
\label{code:mkObject}\index{mkObject}
\label{code:emptyObject}\index{emptyObject}
\begin{code}
mkObject :: ToObject a => [(Text, a)] -> HM.HashMap Text a
mkObject = HM.fromList

emptyObject :: ToObject a => HM.HashMap Text a
emptyObject = HM.empty

\end{code}

default instances:
\begin{code}
instance ToObject () where
    toObject _ _ = mempty

instance ToObject String
instance ToObject Text
instance ToObject Value
instance ToJSON a => ToObject (LogObject a)
instance ToJSON a => ToObject (LOContent a)

\end{code}

\subsubsection{A transformable Tracer}
\label{code:Transformable}\index{Transformable}
\label{code:trTransformer}\index{Transformable!trTransformer}
Parameterised over the source |Tracer| (\emph{b}) and
the target |Tracer| (\emph{a}).\\
The default definition of |trTransformer| is the |nullTracer|. This blocks output
of all items which lack a corresponding instance of |Transformable|.\\
Depending on the input type it can create objects of |LogValue| for numerical values,
|LogMessage| for textual messages, and for all others a |LogStructured| of their
|ToObject| representation.

\begin{code}
class Monad m => Transformable a m b where
    trTransformer :: TracingVerbosity -> Tracer m (LogObject a) -> Tracer m b
    default trTransformer :: TracingVerbosity -> Tracer m (LogObject a) -> Tracer m b
    trTransformer _ _ = nullTracer

trFromIntegral :: (Integral b, MonadIO m) => Text -> Tracer m (LogObject a) -> Tracer m b
trFromIntegral name tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogValue name $ PureI $ fromIntegral arg)

trFromReal :: (Real b, MonadIO m) => Text -> Tracer m (LogObject a) -> Tracer m b
trFromReal name tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogValue name $ PureD $ realToFrac arg)

instance Transformable a IO Int where
    trTransformer MinimalVerbosity = trFromIntegral ""
    trTransformer _ = trFromIntegral "int"
instance Transformable a IO Integer where
    trTransformer MinimalVerbosity = trFromIntegral ""
    trTransformer _ = trFromIntegral "integer"
instance Transformable a IO Word64 where
    trTransformer MinimalVerbosity = trFromIntegral ""
    trTransformer _ = trFromIntegral "word64"
instance Transformable a IO Double where
    trTransformer MinimalVerbosity = trFromReal ""
    trTransformer _ = trFromReal "double"
instance Transformable a IO Float where
    trTransformer MinimalVerbosity = trFromReal ""
    trTransformer _ = trFromReal "float"
instance Transformable Text IO Text where
    trTransformer _ tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogMessage arg)
instance Transformable String IO String where
    trTransformer _ tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogMessage arg)
instance Transformable Text IO String where
    trTransformer _ tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogMessage $ T.pack arg)
instance Transformable String IO Text where
    trTransformer _ tr = Tracer $ \arg ->
        traceWith tr =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogMessage $ T.unpack arg)

\end{code}

The function |trStructured| is a tracer transformer which transforms traced items
to their |ToObject| representation and further traces them as a |LogObject| of type
|LogStructured|. If the |ToObject| representation is empty, then no tracing happens.
\label{code:trStructured}\index{trStructured}
\begin{code}
trStructured :: (ToObject b, MonadIO m) => TracingVerbosity -> Tracer m (LogObject a) -> Tracer m b
trStructured verb tr = Tracer $ \arg ->
        let obj = toObject verb arg
            tracer = if obj == emptyObject then nullTracer else tr
        in
        traceWith tracer =<<
            LogObject <$> pure ""
                      <*> (mkLOMeta Debug Public)
                      <*> pure (LogStructured $ encode $ obj)

\end{code}

\subsubsection{Transformers for setting severity level}
\label{code:setSeverity}
\label{code:severityDebug}
\label{code:severityInfo}
\label{code:severityNotice}
\label{code:severityWarning}
\label{code:severityError}
\label{code:severityCritical}
\label{code:severityAlert}
\label{code:severityEmergency}
\index{setSeverity}\index{severityDebug}\index{severityInfo}
\index{severityNotice}\index{severityWarning}\index{severityError}
\index{severityCritical}\index{severityAlert}\index{severityEmergency}
The log |Severity| level of a |LogObject| can be altered.
\begin{code}
setSeverity :: Severity -> Tracer m (LogObject a) -> Tracer m (LogObject a)
setSeverity sev tr = Tracer $ \lo@(LogObject _nm meta@(LOMeta _ts _tid _sev _pr) _lc) ->
                                traceWith tr $ lo { loMeta = meta { severity = sev } }

severityDebug, severityInfo, severityNotice,
  severityWarning, severityError, severityCritical,
  severityAlert, severityEmergency  :: Tracer m (LogObject a) -> Tracer m (LogObject a)
severityDebug     = setSeverity Debug
severityInfo      = setSeverity Info
severityNotice    = setSeverity Notice
severityWarning   = setSeverity Warning
severityError     = setSeverity Error
severityCritical  = setSeverity Critical
severityAlert     = setSeverity Alert
severityEmergency = setSeverity Emergency

\end{code}

\subsubsection{Transformers for setting privacy annotation}
\label{code:setPrivacy}
\label{code:annotateConfidential}
\label{code:annotatePublic}
\index{setPrivacy}\index{annotateConfidential}\index{annotatePublic}
The privacy annotation (|PrivacyAnnotation|) of the |LogObject| can
be altered with the following functions.
\begin{code}
setPrivacy :: PrivacyAnnotation -> Tracer m (LogObject a) -> Tracer m (LogObject a)
setPrivacy prannot tr = Tracer $ \lo@(LogObject _nm meta@(LOMeta _ts _tid _sev _pr) _lc) ->
                                traceWith tr $ lo { loMeta = meta { privacy = prannot } }

annotateConfidential, annotatePublic :: Tracer m (LogObject a) -> Tracer m (LogObject a)
annotateConfidential = setPrivacy Confidential
annotatePublic = setPrivacy Public

\end{code}

\subsubsection{Transformers for adding a name to the context}
\label{code:setName}
\label{code:addName}\index{setName}\index{addName}
This functions set or add names to the local context naming of |LogObject|.
\begin{code}
setName :: LoggerName -> Tracer m (LogObject a) -> Tracer m (LogObject a)
setName nm tr = Tracer $ \lo@(LogObject _nm _meta _lc) ->
                                traceWith tr $ lo { loName = nm }

addName :: LoggerName -> Tracer m (LogObject a) -> Tracer m (LogObject a)
addName nm tr = Tracer $ \lo@(LogObject nm0 _meta _lc) ->
                                if T.null nm0
                                then
                                    traceWith tr $ lo { loName = nm }
                                else
                                    traceWith tr $ lo { loName = nm0 <> "." <> nm }
 
\end{code}