{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.Chainweb.CutResources
-- Copyright: Copyright © 2019 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Chainweb.CutResources
( CutSyncResources(..)
, CutResources(..)
, cutsCutDb
, withCutResources
, cutNetworks
) where

import Configuration.Utils hiding (Lens', (<.>))

import Control.Lens hiding ((.=), (<.>))
import Control.Monad
import Control.Monad.Catch

import qualified Data.Text as T

import Prelude hiding (log)

import qualified Network.HTTP.Client as HTTP

import System.LogLevel

-- internal modules

import Chainweb.Chainweb.PeerResources
import Chainweb.CutDB
import qualified Chainweb.CutDB.Sync as C
import Chainweb.Logger
import Chainweb.Payload
import Chainweb.Payload.PayloadStore
import Chainweb.RestAPI.NetworkID
import Chainweb.Sync.WebBlockHeaderStore
import Chainweb.Version
import Chainweb.WebBlockHeaderDB

import P2P.Node
import P2P.Peer
import P2P.Session
import P2P.TaskQueue

-- -------------------------------------------------------------------------- --
-- PRELIMINARY TESTING

-- | FAKE pact execution service
--
pact :: PactExectutionService
pact = PactExectutionService $ \_ d -> return
    $ payloadWithOutputs d $ getFakeOutput <$> _payloadDataTransactions d
  where
    getFakeOutput (Transaction txBytes) = TransactionOutput txBytes

-- -------------------------------------------------------------------------- --
-- Cuts Resources

data CutSyncResources logger = CutSyncResources
    { _cutResSyncSession :: !P2pSession
    , _cutResSyncLogger :: !logger
    }

data CutResources logger cas = CutResources
    { _cutResCutConfig :: !CutDbConfig
    , _cutResPeer :: !(PeerResources logger)
    , _cutResCutDb :: !(CutDb cas)
    , _cutResLogger :: !logger
    , _cutResCutSync :: !(CutSyncResources logger)
    , _cutResHeaderSync :: !(CutSyncResources logger)
    , _cutResPayloadSync :: !(CutSyncResources logger)
    }

makeLensesFor
    [ ("_cutResCutDb", "cutsCutDb")
    ] ''CutResources

instance HasChainwebVersion (CutResources logger cas) where
    _chainwebVersion = _chainwebVersion . _cutResCutDb
    {-# INLINE _chainwebVersion #-}

withCutResources
    :: Logger logger
    => PayloadCas cas
    => CutDbConfig
    -> PeerResources logger
    -> logger
    -> WebBlockHeaderDb
    -> PayloadDb cas
    -> HTTP.Manager
    -> (CutResources logger cas -> IO a)
    -> IO a
withCutResources cutDbConfig peer logger webchain payloadDb mgr f = do

    -- initialize blockheader store
    headerStore <- newWebBlockHeaderStore mgr webchain (logFunction logger)

    -- initialize payload store
    payloadStore <- newWebPayloadStore mgr pact payloadDb (logFunction logger)

    withCutDb cutDbConfig (logFunction logger) headerStore payloadStore $ \cutDb ->
        f $ CutResources
            { _cutResCutConfig  = cutDbConfig
            , _cutResPeer = peer
            , _cutResCutDb = cutDb
            , _cutResLogger = logger
            , _cutResCutSync = CutSyncResources
                { _cutResSyncSession = C.syncSession v (_peerInfo $ _peerResPeer peer) cutDb
                , _cutResSyncLogger = setComponent "cut" syncLogger
                }
            , _cutResHeaderSync = CutSyncResources
                { _cutResSyncSession = session 10 (_webBlockHeaderStoreQueue headerStore)
                , _cutResSyncLogger = setComponent "header" syncLogger
                }
            , _cutResPayloadSync = CutSyncResources
                { _cutResSyncSession = session 10 (_webBlockPayloadStoreQueue payloadStore)
                , _cutResSyncLogger = setComponent "payload" syncLogger
                }
            }
  where
    v = _chainwebVersion webchain
    syncLogger = setComponent "sync" logger

-- | The networks that are used by the cut DB.
--
cutNetworks
    :: Logger logger
    => HTTP.Manager
    -> CutResources logger cas
    -> [IO ()]
cutNetworks mgr cuts =
    [ runCutNetworkCutSync mgr cuts
    , runCutNetworkHeaderSync mgr cuts
    , runCutNetworkPayloadSync mgr cuts
    ]

-- | P2P Network for pushing Cuts
--
runCutNetworkCutSync
    :: Logger logger
    => HTTP.Manager
    -> CutResources logger cas
    -> IO ()
runCutNetworkCutSync mgr c
    = mkCutNetworkSync mgr c "cut sync" $ _cutResCutSync c

-- | P2P Network for Block Headers
--
runCutNetworkHeaderSync
    :: Logger logger
    => HTTP.Manager
    -> CutResources logger cas
    -> IO ()
runCutNetworkHeaderSync mgr c
    = mkCutNetworkSync mgr c "block header sync" $ _cutResHeaderSync c

-- | P2P Network for Block Payloads
--
runCutNetworkPayloadSync
    :: Logger logger
    => HTTP.Manager
    -> CutResources logger cas
    -> IO ()
runCutNetworkPayloadSync mgr c
    = mkCutNetworkSync mgr c "block payload sync" $ _cutResPayloadSync c

-- | P2P Network for Block Payloads
--
-- This uses the 'CutNetwork' for syncing peers. The network doesn't restrict
-- the API network endpoints that are used in the client sessions.
--
mkCutNetworkSync
    :: Logger logger
    => HTTP.Manager
    -> CutResources logger cas
    -> T.Text
    -> CutSyncResources logger
    -> IO ()
mkCutNetworkSync mgr cuts label cutSync = bracket create destroy $ \n ->
    p2pStartNode (_peerResConfig $ _cutResPeer cuts) n
  where
    v = _chainwebVersion cuts
    peer = _peerResPeer $ _cutResPeer cuts
    logger = _cutResSyncLogger cutSync
    peerDb = _peerResDb $ _cutResPeer cuts
    s = _cutResSyncSession cutSync

    create = do
        n <- p2pCreateNode v CutNetwork peer (logFunction logger) peerDb mgr s
        logFunctionText logger Info $ label <> ": initialized"
        return n

    destroy n = do
        p2pStopNode n
        logFunctionText logger Info $ label <> ": stopped"
