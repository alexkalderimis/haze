{- |
Description: Contains message types for communication between different components.

Messaging types are put here, to avoid circular dependency,
and to let us have an abstract specification of the adequate behavior.
-}
module Haze.Messaging 
    ( PeerToWriter(..)
    , WriterToPeer(..)
    )
where

import Relude

import Haze.PieceBuffer (BlockIndex, BlockInfo)


-- | Messages sent from peer clients to the piece writer
data PeerToWriter
    -- | The peer is requesting the data from a piece
    = PieceRequest !BlockInfo

-- | Messages sent from a writer to the peer
data WriterToPeer
    -- | The writer is fulfilling a 'PieceRequest'
    = PieceFulfilled !BlockIndex !ByteString
