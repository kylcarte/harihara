{-# LANGUAGE OverloadedStrings #-}

module Harihara.DB
  ( module Harihara.DB
  , module Harihara.DB.Schema
  ) where

import Database.SQLite
import MonadLib
import Text.Show.Pretty hiding (Value (..))

import Control.Applicative
import qualified Data.ByteString as BS
import qualified Data.List as L
import qualified Data.Text as T

import Harihara.DB.Schema
import Harihara.Log

-- DB Monad {{{

newtype DB a = DB { unDB :: ReaderT DBEnv IO a }

instance Functor DB where
  fmap f (DB m) = DB $ fmap f m

instance Monad DB where
  return = DB . return
  (DB m) >>= f = DB $ m >>= unDB . f

instance Applicative DB where
  pure = return
  (<*>) = ap

instance MonadLog DB where
  getLogLevel = fromEnv dbLogLevel
  writeLog ll = io . putStrLn . (renderLevel ll ++)

runDB :: DBEnv -> DB a -> IO a
runDB env m = runReaderT env $ unDB m

io :: IO a -> DB a
io = DB . inBase

-- }}}

-- DBEnv {{{

data DBEnv = DBEnv
  { dbConn   :: SQLiteHandle
  , dbLogLevel :: LogLevel
  }

getEnv :: DB DBEnv
getEnv = DB ask

fromEnv :: (DBEnv -> a) -> DB a
fromEnv = DB . asks

getConn :: DB SQLiteHandle
getConn = fromEnv dbConn

-- }}}

-- DBOpts {{{

data DBOpts = DBOpts
  { dbPath  :: FilePath
  , dbFresh :: Bool
  }

-- }}}

-- Bracketing {{{

setupTable :: DB (Maybe String)
setupTable = dbPrim $ flip defineTable songTable

openDB :: FilePath -> IO SQLiteHandle
openDB = openConnection

closeDB :: DB ()
closeDB = dbPrim closeConnection

addRegexp :: DB ()
addRegexp = dbPrim $ flip addRegexpSupport regex
  where
  regex r s = return (r `BS.isInfixOf` s)

dbPrim :: (SQLiteHandle -> IO a) -> DB a
dbPrim f = do
  conn <- getConn
  io $ f conn

-- }}}

-- DB Wrappers {{{

insertSong :: SongRow -> DB ()
insertSong s = do
  logInfo "Inserting track"
  logDebug $ "Track:\n" ++ ppShow s
  execParams insertCmd (toRow s)
  where
  insertCmd = unwords
    [ "INSERT INTO"
    , "songs (title, artist, album, mbid, file)"
    , "VALUES (:title, :artist, :album, :mbid, :file)"
    ]

getAllSongs :: DB [SongRow]
getAllSongs = query "SELECT * FROM songs"

searchByField :: String -> Value -> DB [SongRow]
searchByField f v = searchByFields [(f,v)]

searchByFields :: [(String,Value)] -> DB [SongRow]
searchByFields fds = queryParams ("SELECT * FROM songs WHERE " ++ fields) params
  where
  fields = L.intercalate " and " $ map (\(f,_) -> unwords [f,"REGEXP",":"++f]) fds
  params = map (\(f,v) -> (":"++f,v)) fds

exec :: String -> DB ()
exec stm = handleExec $ \conn ->
  execStatement_ conn stm

execParams :: String -> [(String,Value)] -> DB ()
execParams stm prm = handleExec $ \conn ->
  execParamStatement_ conn stm prm

query :: String -> DB [SongRow]
query qry = handleQuery $ \conn ->
  execStatement conn qry

queryParams :: String -> [(String,Value)] -> DB [SongRow]
queryParams qry prm = handleQuery $ \conn ->
  execParamStatement conn qry prm

handleExec :: (SQLiteHandle -> IO (Maybe String)) -> DB ()
handleExec f = do
  res <- dbPrim f
  case res of
    Nothing  -> return ()
    Just err -> do
      logError $ "SQLite Error: " ++ err
      return ()

handleQuery :: (SQLiteHandle -> IO (Either String [[Row Value]])) -> DB [SongRow]
handleQuery f = do
  addRegexp
  res <- dbPrim f
  case res of
    Left err -> do
      logError $ "SQLite Error: " ++ err
      return []
    Right rss -> case Prelude.concat <$> mapM (mapM fromRow) rss of
      Nothing -> do
        logError "SQLite Parse Error"
        logDebug $ "SQLite Row: " ++ ppShow rss
        return []
      Just ss -> do
        logDebug $ "SQLite Response: " ++ ppShow ss
        return ss

{-
execStatement :: SQLiteResult a => SQLiteHandle -> String -> IO (Either String [[Row a]])

execStatement_ :: SQLiteHandle -> String -> IO (Maybe String)

execParamStatement :: SQLiteResult a => SQLiteHandle -> String -> [(String, Value)] -> IO (Either String [[Row a]])

execParamStatement_ :: SQLiteHandle -> String -> [(String, Value)] -> IO (Maybe String)

insertRow :: SQLiteHandle -> TableName -> Row String -> IO (Maybe String)
-}

-- }}}

