{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{- |
Description: Contains functions centered around writing pieces to disk

This module contains functionality related to the concurrent
process responsible for periodically writing the pieces contained
in a shared buffer to disk. Utility functions for doing
the writing, as well as starting up the process are provided.
-}
module Haze.PieceWriter
    ( -- Mainly exported for testing
      FileStructure(..)
    , SplitPiece(..)
    , makeFileStructure
    , writePieces
    )
where

import           Relude

import           Data.Array                     ( Array
                                                , (!)
                                                , bounds
                                                , elems
                                                , listArray
                                                )
import qualified Data.ByteString               as BS
-- We import lazy bytestring for implementing efficient file ops
import qualified Data.ByteString.Lazy          as LBS
import           Data.List                      ( zipWith3 )
import           Data.Maybe                     ( fromJust )
import           Path                           ( Path
                                                , Abs
                                                , File
                                                , Dir
                                                , (</>)
                                                , (<.>)
                                                )
import qualified Path
import qualified Path.IO                       as Path
import           System.IO                      ( Handle
                                                , IOMode(..)
                                                , SeekMode(..)
                                                , hSeek
                                                )

import           Haze.Messaging                 ( PeerToWriter(..)
                                                , WriterToPeer(..)
                                                )
import           Haze.PeerInfo                  ( HasPeerInfo(..)
                                                , PeerInfo(..)
                                                , recvToWriter
                                                , sendWriterToPeer
                                                , sendWriterToAll
                                                )
import           Haze.PieceBuffer               ( BlockIndex(..)
                                                , BlockInfo(..)
                                                , HasPieceBuffer(..)
                                                , saveCompletePiecesM
                                                )
import           Haze.Tracker                   ( FileInfo(..)
                                                , FileItem(..)
                                                , SHAPieces(..)
                                                , totalFileLength
                                                )



type AbsFile = Path Abs File

{- | Represents information about the structure of pieces we have.

This should ideally be generated statically before running the piece writer,
as this information never changes.
-}
data FileStructure
    -- | We have a single file, and an array of pieces to save
    = SimplePieces !AbsFile !(Array Int AbsFile)
    {- | We have multiple files to deal with

    The first argument is an array mapping each piece index to how
    we the piece should be split across multiple files. The
    second argument is a list of files and the corresponding
    files they depend on. Whenever all of the corresponding files
    exist, that file is complete.
    -}
    | MultiPieces !(Array Int SplitPiece) ![(AbsFile, [AbsFile])]
    deriving (Eq, Show)

-- | Represents a piece we have to save potentially over 2 files.
data SplitPiece
    -- | A piece we can save to a piece file
    = NormalPiece !AbsFile
    -- | A piece that needs to save N bytes in one file, and the rest in the other
    | LeftOverPiece !Int !AbsFile !AbsFile
    deriving (Eq, Show)


{- | Construct a 'FileStructure' given information about the pieces.

The 'FileInfo' provides information about how the pieces are organised
in a file, and the 'SHAPieces' gives us information about how
each piece is sized. This function also takes a root directory
into which the files should be unpacked.
-}
makeFileStructure :: FileInfo -> SHAPieces -> Path Abs Dir -> FileStructure
makeFileStructure fileInfo pieces root = case fileInfo of
    SingleFile (FileItem path _ _) ->
        let paths      = makePiecePath root <$> [0 .. maxPiece]
            piecePaths = listArray (0, maxPiece) paths
        in  SimplePieces (root </> path) piecePaths
    MultiFile relRoot items ->
        let
            absRoot = root </> relRoot
            go (i, makeLO, splits, files) (FileItem path size _) =
                let
                    absPath    = absRoot </> path
                    startPiece = makeLO $> makeStartPiece absPath
                    midSize    = maybe size ((size -) . snd) makeLO
                    leftOver   = liftA2 (\(f, _) p -> f p) makeLO startPiece
                    (d, m)     = midSize `divMod` pieceSize
                    lastFit    = fromIntegral d + i - 1
                    nextIndex  = lastFit + if m == 0 then 1 else 2
                    finalEnd =
                        guard (m /= 0 && nextIndex > maxPiece)
                            $> makePiecePath absRoot maxPiece
                    bookEnd    = guard (m /= 0) $> makeEndPiece absPath
                    endPiece   = finalEnd <|> bookEnd
                    makeLO'    = makeLeftOverFunc m <$> endPiece
                    midPieces  = makePiecePath absRoot <$> [i .. lastFit]
                    midSplits  = leftOver `tryCons` map NormalPiece midPieces
                    nextSplits = case finalEnd of
                        Just end -> midSplits ++ [NormalPiece end]
                        Nothing  -> midSplits
                    deps   = startPiece `tryCons` (endPiece `tryCons` midPieces)
                    files' = (absRoot </> path, deps) : files
                in
                    (nextIndex, makeLO', splits ++ nextSplits, files')
            (_, _, theSplits, theFiles) = foldl' go (0, Nothing, [], []) items
        in
            MultiPieces (listArray (0, maxPiece) theSplits) theFiles
  where
    pieceSize :: Int64
    pieceSize = let (SHAPieces size _) = pieces in size
    maxPiece :: Int
    maxPiece = fromIntegral $ (totalFileLength fileInfo - 1) `div` pieceSize
    makePiecePath :: Path Abs Dir -> Int -> AbsFile
    makePiecePath theRoot piece =
        let pieceName = "piece-" ++ show piece ++ ".bin"
        in  theRoot </> fromJust (Path.parseRelFile pieceName)
    makeStartPiece :: AbsFile -> AbsFile
    makeStartPiece file = fromJust (file <.> "start")
    makeEndPiece :: AbsFile -> AbsFile
    makeEndPiece file = fromJust (file <.> "end")
    tryCons :: Maybe a -> [a] -> [a]
    tryCons = maybe id (:)
    makeLeftOverFunc :: Int64 -> AbsFile -> (AbsFile -> SplitPiece, Int64)
    makeLeftOverFunc m path =
        (LeftOverPiece (fromIntegral m) path, pieceSize - m)


{- | Write a list of complete indices and pieces to a file.

This function takes information about the pieces, telling
it how they're arranged into files, as well as the size of each normal piece.
The function takes an absolute directory to serve as the root for all files.
-}
writePieces :: MonadIO m => FileStructure -> [(Int, ByteString)] -> m ()
writePieces structure pieces = case structure of
    SimplePieces filePath piecePaths -> do
        forM_ pieces
            $ \(piece, bytes) -> writeAbsFile (piecePaths ! piece) bytes
        appendWhenAllExist filePath (elems piecePaths)
    MultiPieces splitPieces fileDependencies -> do
        forM_ pieces $ \(piece, bytes) -> case splitPieces ! piece of
            NormalPiece filePath ->
                writeFileBS (Path.fromAbsFile filePath) bytes
            LeftOverPiece startSize startPath endPath ->
                let (start, end) = BS.splitAt startSize bytes
                in  writeAbsFile startPath start *> writeAbsFile endPath end
        forM_ fileDependencies (uncurry appendWhenAllExist)
  where
    -- This will also remove the appended files
    appendWhenAllExist :: MonadIO m => AbsFile -> [AbsFile] -> m ()
    appendWhenAllExist filePath paths = do
        allPieces <- allM Path.doesFileExist paths
        when allPieces $ do
            withAbsFile filePath AppendMode (appendAll paths)
            removeAll paths


-- | Write bytes to an absolute path
writeAbsFile :: MonadIO m => AbsFile -> ByteString -> m ()
writeAbsFile path = writeFileBS (Path.fromAbsFile path)

-- | Utility function for `withFile` but with an absolute path
withAbsFile :: MonadIO m => AbsFile -> IOMode -> (Handle -> IO a) -> m a
withAbsFile path mode action =
    liftIO $ withFile (Path.fromAbsFile path) mode action

-- | Append all paths in a file to a handle
appendAll :: [AbsFile] -> Handle -> IO ()
appendAll paths = forM_ paths . appendH
  where
    moveBytes h = LBS.hGetContents >=> LBS.hPut h
    appendH h path = withAbsFile path ReadMode (moveBytes h)

-- | Remove all files in a list
removeAll :: MonadIO m => [AbsFile] -> m ()
removeAll paths = forM_ paths Path.removeFile

{- | PieceMapping allows us to determine where to find a piece on disk.

It contains a list of locations that compose the piece. The locations
come in the same order as they fill the piece in.

This is similar to FileStructure, except instead of telling us how to save
a piece to disk, this tells us how to retrieve the disk later on.
Retrieving is made complicated by the fact that where a piece is located
changes as we download more of the file. In the case of a single file,
the piece will be stored in its own file until the entire file is downloaded,
at which point the piece occupies just a section of a big file.
With multiple files, we have the same situation, but with multiple files
each time. A further complication with multiple files is that the piece
may be a section of one file, but not yet integrated into a part of another file.
-}
newtype PieceMapping = PieceMapping (Array Int [PieceLocation])

-- | Create a PieceMapping given the structure of the files
mappingFromStructure :: FileInfo -> SHAPieces -> Path Abs Dir -> FileStructure -> PieceMapping
mappingFromStructure fileInfo (SHAPieces pieceSize _) root structure =
    case structure of
        SimplePieces bigFile pieceFiles ->
            let
                lengths = map fromIntegral pieceLengths
                embeds =
                    zipWith3 EmbeddedLocation (repeat bigFile) pieceOffsets lengths
                completes = CompleteLocation <$> elems pieceFiles
                locations = pure <$> zipWith PieceLocation completes embeds
            in
                PieceMapping (listArray (bounds pieceFiles) locations)
        MultiPieces splits _ ->
            let (MultiFile relRoot items) = fileInfo
                absRoot = root </> relRoot
                makeEmbedded = findEmbedded absRoot items
                splitPieces = elems splits
                completes = map splitToComplete splitPieces
                embeds = zipWith makeEmbedded pieceOffsets pieceLengths
                bnds = (0, length pieceLengths)
            in  PieceMapping . listArray bnds $
                    zipWith (zipWith PieceLocation) completes embeds
  where
    totalSize :: Int64
    totalSize = totalFileLength fileInfo
    pieceOffsets :: [Int64]
    pieceOffsets = [0,pieceSize..]
    pieceLengths :: [Int64]
    pieceLengths =
        let normalPieceCount = fromIntegral $ totalSize `div` pieceSize
            leftoverLength = totalSize `mod` pieceSize
            leftOver = if leftoverLength == 0 then [] else [leftoverLength]
        in replicate normalPieceCount pieceSize ++ leftOver
    pSize :: Int
    pSize = fromIntegral pieceSize
    leftoverSize :: Int
    leftoverSize = fromIntegral $ totalSize `mod` pieceSize
    findEmbedded :: Path Abs Dir -> [FileItem] -> OffSet -> Int64 -> [EmbeddedLocation]
    findEmbedded root files@(FileItem path size _:rest) offset ln
        | offset < size && offset + ln <= size =
            [EmbeddedLocation (root </> path) offset (fromIntegral ln)]
        | offset < size = 
            let endLength = size - offset
                embed = EmbeddedLocation (root </> path) offset (fromIntegral endLength)
            in embed : findEmbedded root rest size (ln - endLength)
        | otherwise = findEmbedded root rest offset ln
    splitToComplete :: SplitPiece -> [CompleteLocation]
    splitToComplete (NormalPiece file) = [CompleteLocation file]
    splitToComplete (LeftOverPiece _ f1 f2) = CompleteLocation <$> [f1, f2]



-- | An integer offset into a file
type OffSet = Int64

{- | PieceLocation represents a recipe to get part of a piece from disk.

It contains both the initial location, where the piece is alone,
and the final embedded location.
The piece is only in one of them at a time, but where it is needs to be
checked by actually looking if the file for the embedded location is written.
-}
data PieceLocation = PieceLocation !CompleteLocation !EmbeddedLocation

-- | A place where the piece is stored in its own file
newtype CompleteLocation = CompleteLocation AbsFile

-- | The piece is lodged inside a larger file
data EmbeddedLocation = EmbeddedLocation !AbsFile !OffSet !Int

-- | using a pieceMapping, get the nth piece from disk
getPiece :: MonadIO m => PieceMapping -> Int -> m ByteString
getPiece (PieceMapping mappings) piece =
    let mapping = mappings ! piece in foldMapA getLocation mapping
  where
    getLocation :: MonadIO m => PieceLocation -> m ByteString
    getLocation (PieceLocation (CompleteLocation cl) embedded) = do
        isComplete <- Path.doesFileExist cl
        if isComplete then readComplete cl else readEmbedded embedded
    readComplete :: MonadIO m => AbsFile -> m ByteString
    readComplete = readFileBS . Path.fromAbsFile
    readEmbedded :: MonadIO m => EmbeddedLocation -> m ByteString
    readEmbedded (EmbeddedLocation file offset amount) =
        withAbsFile file ReadMode $ \h -> do
            hSeek h AbsoluteSeek (fromIntegral offset)
            BS.hGet h amount



-- | Represents the data a piece writer needs
data PieceWriterInfo = PieceWriterInfo
    { pieceStructure :: !FileStructure
    , pieceMapping :: !PieceMapping
    , peerInfo :: !PeerInfo
    }

-- | A context with access to what a piece writer process needs
newtype PieceWriterM a = PieceWriterM (ReaderT PieceWriterInfo IO a)
    deriving (Functor, Applicative, Monad, MonadReader PieceWriterInfo, MonadIO)

instance HasPeerInfo PieceWriterM where
    getPeerInfo = asks peerInfo

instance HasPieceBuffer PieceWriterM where
    getPieceBuffer = asks (infoBuffer . peerInfo)

-- | Run a piece writer function given the right context
runPieceWriterM :: PieceWriterInfo -> PieceWriterM a -> IO a
runPieceWriterM info (PieceWriterM reader) = runReaderT reader info

-- | Lookup and write the pieces in a pieceBuff
writePiecesM :: PieceWriterM ()
writePiecesM = do
    pieces <- saveCompletePiecesM
    info   <- asks pieceStructure
    writePieces info pieces

pieceWriterLoop :: PieceWriterM ()
pieceWriterLoop = forever $ do
    msg <- recvToWriter
    case msg of
        PieceBufferWritten     -> writePiecesM
        PieceRequest peer info -> do
            let (BlockInfo index@(BlockIndex piece offset) size) = info
            mapping   <- asks pieceMapping
            pieceData <- getPiece mapping piece
            let block = BS.take size $ BS.drop offset pieceData
            sendWriterToPeer (PieceFulfilled index block) peer

