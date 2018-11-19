{-# LANGUAGE RecordWildCards #-}
{- |
Description: Contains functions related to trackers

This file provides a more abstract description of
the communication protocol with trackers. First it
specificies the data in a .torrent file with MetaInfo,
then data sent to and returned from a tracker.
-}
module Haze.Tracker 
    ( Tracker(..)
    , TieredList(..)
    , MD5Sum(..)
    , SHA1
    , getSHA1
    , SHAPieces(..)
    , FileInfo(..)
    , FileItem(..)
    , MetaInfo(..)
    , decodeMeta
    , metaFromBytes
    , Announce(..)
    , AnnounceInfo(..)
    , Peer(..)
    , decodeAnnounce
    , announceFromHTTP
    , ReqEvent(..)
    , TrackerRequest(..)
    , newTrackerRequest
    , trackerQuery
    )
where

import Relude

import Crypto.Hash.SHA1 as SHA1
import Data.Bits ((.|.), shift)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.HashMap.Strict as HM
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Network.Socket (HostName, PortNumber)
import Text.Show (Show(..))

import Haze.Bencoding (Bencoding(..), Decoder(..), DecodeError(..),
                       decode, encode, encodeBen)


-- | Represents the URL for a torrent Tracker
newtype Tracker = Tracker Text deriving (Show)

{- | Represents a tiered list of objects.

Every element in the tier is tried before moving on
to the next tier. In MetaInfo files, multiple
tiers of trackers are provided, with each tier needing
to be tried before the subsequent one is used.
-}
newtype TieredList a = TieredList [[a]] deriving (Show)

-- | Represents the MD5 sum of a file
newtype MD5Sum = MD5Sum ByteString deriving (Show)

-- | Represents a 20 byte SHA1 hash
newtype SHA1 = SHA1 { getSHA1 :: ByteString } deriving (Show)

-- | Represents the concatenation of multiple SHA pieces.
data SHAPieces = SHAPieces Int64 ByteString

instance Show SHAPieces where
    show (SHAPieces i _) = 
        "SHAPieces " ++ Relude.show i ++ " (..bytes)"

{- | Represents the information in the `info` of a metainfo file

A torrent can contain either a single file, or multiple files,
and what each file contains in the multi file mode is different than
the single file.
-}
data FileInfo 
    -- | A single file, with name, length, and md5 sum
    = SingleFile FilePath Int64 (Maybe MD5Sum)
    -- | Multiple files, with directory name
    |  MultiFile FilePath [FileItem]
    deriving (Show)

{- | A single file in a multi file torrent

Note that the information in this datatype is slightly different
from the 'SingleFile' branch of 'FileInfo'. Notably, instead of
having a name, it instead has a list of strings representing
the full file path, which must be respected.
-}
data FileItem = FileItem [FilePath] Int64 (Maybe MD5Sum) deriving (Show)

{- | Represents the information in a .torrent file
stem.Directory
Contains information about the files contained in the
torrent, and the trackers to use to connect to peers
seeding those files.
-}
data MetaInfo = MetaInfo
    { metaPieces :: SHAPieces
    , metaPrivate :: Bool
    , metaFile :: FileInfo
    , metaInfoHash :: SHA1
    , metaAnnounce :: Text
    , metaAnnounceList :: Maybe (TieredList Tracker)
    , metaCreation :: Maybe UTCTime
    , metaComment :: Maybe Text
    , metaCreatedBy :: Maybe Text 
    , metaEncoding :: Maybe Text
    }
    deriving (Show)


-- | Try and decode a meta file from a bytestring
metaFromBytes :: ByteString -> Either DecodeError MetaInfo
metaFromBytes bs = decode decodeMeta bs 
    >>= maybe (Left (DecodeError "Bad MetaInfo file")) Right

-- | Get the total size (bytes) of all the files in a torrent
totalFileSize :: MetaInfo -> Int64
totalFileSize meta = case metaFile meta of
    SingleFile _ len _ -> len
    MultiFile _ items  -> sum (map itemLen items)
  where
    itemLen (FileItem _ len _) = len


type BenMap = HM.HashMap ByteString Bencoding

decodeMeta :: Decoder (Maybe MetaInfo)
decodeMeta = Decoder doDecode
  where
    doDecode (BMap mp) = do
        info <- HM.lookup "info" mp
        (metaPieces, metaPrivate, metaFile) <- getInfo info
        let metaInfoHash = SHA1 $ SHA1.hash (encode encodeBen info)
        metaAnnounce     <- withKey "announce" mp tryText
        let metaAnnounceList = getAnnounces "announce-list" mp
        let metaCreation  = withKey "creation date" mp tryDate
        let metaComment   = withKey "comment" mp tryText
        let metaCreatedBy = withKey "created by" mp tryText
        let metaEncoding  = withKey "encoding" mp tryText
        return (MetaInfo {..})
    doDecode _          = Nothing
    getBool :: ByteString -> BenMap -> Bool
    getBool k mp = case HM.lookup k mp of
        Just (BInt 1) -> True
        _             -> False
    getAnnounces :: ByteString -> BenMap -> Maybe (TieredList Tracker)
    getAnnounces k mp = 
        withKey k mp 
        (fmap TieredList . traverse getTrackers <=< tryList)
      where
        getTrackers :: Bencoding -> Maybe [Tracker]
        getTrackers = 
            traverse (fmap Tracker . tryText) <=< tryList
    tryDate :: Bencoding -> Maybe UTCTime
    tryDate (BInt i) = Just . posixSecondsToUTCTime $
            fromInteger (toInteger i)
    tryDate _        = Nothing
    getInfo :: Bencoding -> Maybe (SHAPieces, Bool, FileInfo)
    getInfo (BMap mp) = do
        let private = getBool "private" mp
        pieceLen <- withKey "piece length" mp tryInt
        pieces   <- withKey "pieces" mp tryBS
        let sha = SHAPieces pieceLen pieces
        file <- case HM.lookup "files" mp of
            Nothing    -> getSingle mp
            Just files -> getMulti mp files
        return (sha, private, file)
    getInfo _         = Nothing
    getFilePart :: BenMap -> Maybe (Int64, Maybe MD5Sum)
    getFilePart mp = do
        len <- withKey "length" mp tryInt
        let md5 = MD5Sum <$> withKey "md5sum" mp tryBS
        return (len, md5)
    getSingle :: BenMap -> Maybe FileInfo
    getSingle mp = do
        name       <- withKey "name" mp tryPath
        (len, md5) <- getFilePart mp
        return (SingleFile name len md5)
    getMulti :: BenMap -> Bencoding -> Maybe FileInfo
    getMulti mp (BList l) = do
        name  <- withKey "name" mp tryPath
        files <- traverse getFileItem l
        return (MultiFile name files)
    getMulti _ _         = Nothing
    getFileItem :: Bencoding -> Maybe FileItem
    getFileItem (BMap mp) = do
        (len, md5) <- getFilePart mp
        path <- withKey "path" mp
                (tryList >=> traverse tryPath)
        return (FileItem path len md5)
    getFileItem _         = Nothing


-- | Information sent to the tracker about the state of the request
data ReqEvent
    -- | The request has just started
    = ReqStarted
    -- | The request has stopped
    | ReqStopped
    -- | The request has successfully downloaded everything
    | ReqCompleted
    -- | No new information about the request
    | ReqEmpty
    deriving (Show)

-- | Represents the information in a request to a tracker
data TrackerRequest = TrackerRequest
    { treqInfoHash :: SHA1
    -- | Represents the peer id for this client
    , treqPeerID :: ByteString
    , treqPort :: PortNumber
    -- | The total number of bytes uploaded
    , treqUploaded :: Int64
    -- | The total number of bytes downloaded
    , treqDownloaded :: Int64
    -- | The number of bytes in the file left to download
    , treqLeft :: Int64
    -- | Whether or not the client expects a compact response
    , treqCompact :: Bool
    -- | The current state of this ongoing request
    , treqEvent :: ReqEvent
    , treqNumWant :: Maybe Int
    -- | This is to be included if the tracker sent it
    , treqTransactionID :: Maybe ByteString
    }
    deriving (Show)

-- | Constructs the tracker request to be used at the start of a session
newTrackerRequest :: MetaInfo -> ByteString -> TrackerRequest
newTrackerRequest meta@MetaInfo{..} peerID = TrackerRequest 
    metaInfoHash peerID 6881 0 0 (totalFileSize meta) 
    True ReqStarted Nothing Nothing


-- | Encodes a 'TrackerRequest' as query parameters
trackerQuery :: TrackerRequest -> [(ByteString, Maybe ByteString)]
trackerQuery TrackerRequest{..} = map (\(a, b) -> (a, Just b)) $
    [ ("info_hash", getSHA1 treqInfoHash)
    , ("peer_id", treqPeerID)
    , ("port", Relude.show treqPort)
    , ("uploaded", Relude.show treqUploaded)
    , ("downloaded", Relude.show treqDownloaded)
    , ("left", Relude.show treqLeft)
    , ("compact", if treqCompact then "1" else "0")
    ] ++
    eventQuery ++
    maybe [] (\i -> [("numwant", Relude.show i)]) treqNumWant ++
    maybe [] (\s -> [("trackerid", s)]) treqTransactionID
  where
    eventQuery = case treqEvent of
        ReqStarted -> [("event", "started")]
        ReqStopped -> [("event", "stopped")]
        ReqCompleted -> [("event", "completed")]
        ReqEmpty -> []


-- | Represents the announce response from a tracker
data Announce
    -- | The request to the tracker was bad
    = FailedAnnounce Text
    | GoodAnnounce AnnounceInfo
    deriving (Show)

-- | The information of a successful announce response
data AnnounceInfo = AnnounceInfo
    { annWarning :: Maybe Text -- ^ A warning message
    , annInterval :: Int -- ^ Seconds between requests
    -- | If present, the client must not act more frequently
    , annMinInterval :: Maybe Int
    , annTransactionID :: Maybe ByteString
    -- | The number of peers with the complete file
    , annSeeders :: Maybe Int
    -- | The number of peers without the complete file
    , annLeechers :: Maybe Int
    , annPeers :: [Peer] 
    }
    deriving (Show)


-- | Represents a peer in the swarm
data Peer = Peer
    { peerID :: Maybe Text
    , peerHost :: HostName
    , peerPort :: PortNumber
    }
    deriving (Show)

{- | This reads a bytestring announce from HTTP

HTTP and UDP trackers differ in that HTTP trackers
will send back a bencoded bytestring to read the
announce information from, but UDP trackers will
send a bytestring without bencoding.
This parses the bencoded bytestring from HTTP.
-}
announceFromHTTP :: ByteString -> Either DecodeError Announce
announceFromHTTP bs = decode decodeAnnounce bs
    >>= maybe (Left (DecodeError "Bad Announce Data")) Right

-- | A Bencoding decoder for the Announce data
decodeAnnounce :: Decoder (Maybe Announce)
decodeAnnounce = Decoder doDecode
  where
    doDecode :: Bencoding -> Maybe Announce
    doDecode (BMap mp) = 
        case HM.lookup "failure reason" mp of
            Just (BString s) ->
                Just (FailedAnnounce (decodeUtf8 s))
            Nothing          -> do
                info <- decodeAnnounceInfo mp
                return (GoodAnnounce info)
            Just _           ->
                Nothing
    doDecode _         = Nothing
    decodeAnnounceInfo :: BenMap -> Maybe AnnounceInfo
    decodeAnnounceInfo mp = do
        let annWarning       = withKey "warning message" mp tryText
        annInterval         <- withKey "interval" mp tryNum
        let annMinInterval   = withKey "min interval" mp tryNum
        let annTransactionID = withKey "tracker id" mp tryBS
        let annSeeders       = withKey "complete" mp tryNum
        let annLeechers      = withKey "incomplete" mp tryNum
        pInfo               <- HM.lookup "peers" mp
        annPeers            <- dictPeers pInfo 
                           <|> binPeers pInfo
        return (AnnounceInfo {..})
    dictPeers :: Bencoding -> Maybe [Peer]
    dictPeers = tryList >=> traverse getPeer
      where
        getPeer :: Bencoding -> Maybe Peer
        getPeer (BMap mp) = do
            let peerID = withKey "peer id" mp tryText
            peerHost <- BSC.unpack <$> withKey "ip" mp tryBS
            peerPort <- withKey "port" mp tryNum
            return (Peer {..})
        getPeer _          = Nothing
    binPeers :: Bencoding -> Maybe [Peer]
    binPeers (BString bs)
        -- The bytestring isn't a multiple of 6
        | BS.length bs `mod` 6 /= 0 = Nothing
        | otherwise                 =
            let chunks = makeChunks 6 bs
                makePeerHost :: ByteString -> String
                makePeerHost chunk = intercalate "." . map Relude.show $
                    BS.unpack (BS.take 4 chunk)
                makePeerPort chunk = 
                    -- this is safe because of when we call this
                    let [a, b] = BS.unpack (BS.drop 4 chunk)
                    in fromInteger (toInteger (makeWord16 a b))
            in Just $ map (\chunk -> 
                Peer Nothing 
                (makePeerHost chunk) 
                (makePeerPort chunk))
                chunks
    binPeers _ = Nothing
    makeWord16 :: Word8 -> Word8 -> Word16
    makeWord16 a b = 
        shift (fromIntegral a) 8 .|. fromIntegral b
    makeChunks :: Int -> ByteString -> [ByteString]
    makeChunks size bs
        | BS.null bs = []
        | otherwise  = BS.take size bs 
                     : makeChunks size (BS.drop size bs)


{- Decoding utilities -}

withKey :: ByteString -> BenMap 
        -> (Bencoding -> Maybe a) -> Maybe a
withKey k mp next = HM.lookup k mp >>= next

tryInt :: Bencoding -> Maybe Int64
tryInt (BInt i) = Just i
tryInt _        = Nothing

tryNum :: Num n => Bencoding -> Maybe n
tryNum (BInt i) = 
    Just (fromInteger (toInteger i))
tryNum _        = Nothing

tryBS :: Bencoding -> Maybe ByteString
tryBS (BString bs) = Just bs
tryBS _            = Nothing

tryPath :: Bencoding -> Maybe FilePath
tryPath = fmap BSC.unpack  . tryBS

tryText :: Bencoding -> Maybe Text
tryText = fmap decodeUtf8 . tryBS

tryList :: Bencoding -> Maybe [Bencoding]
tryList (BList l) = Just l
tryList _         = Nothing