{-# LANGUAGE CPP #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Xmobar
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
--
-- Maintainer  :  Jose A. Ortega Ruiz <jao@gnu.org>
-- Stability   :  unstable
-- Portability :  unportable
--
-- A status bar for the Xmonad Window Manager
--
-----------------------------------------------------------------------------

module Xmobar
    ( -- * Main Stuff
      -- $main
      X , XConf (..), runX
    , startLoop
    -- * Program Execution
    -- $command
    , startCommand
    -- * Window Management
    -- $window
    , createWin
    -- * Printing
    -- $print
    , drawInWin, printStrings
    ) where

import Prelude hiding (lookup)
import Graphics.X11.Xlib hiding (textExtents, textWidth)
import Graphics.X11.Xlib.Extras
import Graphics.X11.Xinerama
import Graphics.X11.Xrandr

import Control.Arrow ((&&&))
import Control.Applicative ((<$>))
import Control.Monad.Reader
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (handle, SomeException(..))
import Data.Bits
import Data.Map hiding (foldr, map, filter)
import Data.Maybe (fromJust, isJust)
import Foreign.Marshal.Alloc
import Foreign.Storable
import Foreign.Ptr

import Bitmap
import Config
import Parsers
import Commands
import Actions
import Runnable
import Signal
import Window
import XUtil
import ColorCache

#ifdef XFT
import Graphics.X11.Xft
#endif

#ifdef DBUS
import IPC.DBus
#endif

-- $main
--
-- The Xmobar data type and basic loops and functions.

-- | The X type is a ReaderT
type X = ReaderT XConf IO

-- | The ReaderT inner component
data XConf =
    XConf { display :: Display
          , rect    :: Rectangle
          , window  :: Window
          , fontS   :: XFont
          , iconS   :: Map FilePath Bitmap
          , config  :: Config
          }

-- | Runs the ReaderT
runX :: XConf -> X () -> IO ()
runX xc f = runReaderT f xc

-- | Starts the main event loop and threads
startLoop :: XConf -> TMVar SignalType -> [[(Maybe ThreadId, TVar String)]] -> IO ()
startLoop xcfg@(XConf _ _ w _ _ _) sig vs = do
#ifdef XFT
    xftInitFtLibrary
#endif
    tv <- atomically $ newTVar []
    _ <- forkIO (handle (handler "checker") (checker tv [] vs sig))
#ifdef THREADED_RUNTIME
    _ <- forkOS (handle (handler "eventer") (eventer sig))
#else
    _ <- forkIO (handle (handler "eventer") (eventer sig))
#endif
#ifdef DBUS
    runIPC sig
#endif
    eventLoop tv xcfg [] sig
  where
    handler thing (SomeException _) =
      void $ putStrLn ("Thread " ++ thing ++ " failed")
    -- Reacts on events from X
    eventer signal =
      allocaXEvent $ \e -> do
        dpy <- openDisplay ""
        xrrSelectInput    dpy (defaultRootWindow dpy) rrScreenChangeNotifyMask
        selectInput       dpy w (exposureMask .|. structureNotifyMask .|. buttonPressMask)

        forever $ do
#ifdef THREADED_RUNTIME
          nextEvent dpy e
#else
          nextEvent' dpy e
#endif
          ev <- getEvent e
          case ev of
            ConfigureEvent {} -> atomically $ putTMVar signal Reposition
            ExposeEvent {} -> atomically $ putTMVar signal Wakeup
            RRScreenChangeNotifyEvent {} -> atomically $ putTMVar signal Reposition
            ButtonEvent {} -> atomically $ putTMVar signal (Action (ev_button ev) (fi $ ev_x ev))
            _ -> return ()

-- | Send signal to eventLoop every time a var is updated
checker :: TVar [String]
           -> [String]
           -> [[(Maybe ThreadId, TVar String)]]
           -> TMVar SignalType
           -> IO ()
checker tvar ov vs signal = do
      nval <- atomically $ do
              nv <- mapM concatV vs
              guard (nv /= ov)
              writeTVar tvar nv
              return nv
      atomically $ putTMVar signal Wakeup
      checker tvar nval vs signal
    where
      concatV = fmap concat . mapM (readTVar . snd)


-- | Continuously wait for a signal from a thread or a interrupt handler
eventLoop :: TVar [String] -> XConf -> [([Action], Position, Position)] -> TMVar SignalType -> IO ()
eventLoop tv xc@(XConf d r w fs is cfg) as signal = do
      typ <- atomically $ takeTMVar signal
      case typ of
         Wakeup -> do
            str <- updateString cfg tv
            xc' <- updateCache d w is (iconRoot cfg) str >>= \c -> return xc { iconS = c }
            as' <- updateActions xc r str
            runX xc' $ drawInWin r str
            eventLoop tv xc' as' signal

         Reposition ->
            reposWindow cfg

         ChangeScreen -> do
            ncfg <- updateConfigPosition cfg
            reposWindow ncfg

         Hide   t -> hide   (t*100*1000)
         Reveal t -> reveal (t*100*1000)
         Toggle t -> toggle t

         TogglePersistent -> eventLoop
            tv xc { config = cfg { persistent = not $ persistent cfg } } as signal

         Action but x -> action but x

    where
        isPersistent = not $ persistent cfg

        hide t
            | t == 0 =
                when isPersistent (hideWindow d w) >> eventLoop tv xc as signal
            | otherwise = do
                void $ forkIO
                     $ threadDelay t >> atomically (putTMVar signal $ Hide 0)
                eventLoop tv xc as signal

        reveal t
            | t == 0 = do
                when isPersistent (showWindow r cfg d w)
                eventLoop tv xc as signal
            | otherwise = do
                void $ forkIO
                     $ threadDelay t >> atomically (putTMVar signal $ Reveal 0)
                eventLoop tv xc as signal

        toggle t = do
            ismapped <- isMapped d w
            atomically (putTMVar signal $ if ismapped then Hide t else Reveal t)
            eventLoop tv xc as signal

        reposWindow rcfg = do
          r' <- repositionWin d w fs rcfg
          eventLoop tv (XConf d r' w fs is rcfg) as signal

        updateConfigPosition ocfg =
          case position ocfg of
            OnScreen n o -> do
              srs <- getScreenInfo d
              return (if n == length srs
                       then
                        (ocfg {position = OnScreen 1 o})
                       else
                        (ocfg {position = OnScreen (n+1) o}))
            o ->
              return (ocfg {position = OnScreen 1 o})

        action button x = do
          mapM_ runAction $
            filter (\(Spawn b _) -> button `elem` b) $
            concatMap (\(a,_,_) -> a) $
            filter (\(_, from, to) -> x >= from && x <= to) as
          eventLoop tv xc as signal

-- $command

-- | Runs a command as an independent thread and returns its thread id
-- and the TVar the command will be writing to.
startCommand :: TMVar SignalType
             -> (Runnable,String,String)
             -> IO (Maybe ThreadId, TVar String)
startCommand sig (com,s,ss)
    | alias com == "" = do var <- atomically $ newTVar is
                           atomically $ writeTVar var (s ++ ss)
                           return (Nothing,var)
    | otherwise       = do var <- atomically $ newTVar is
                           let cb str = atomically $ writeTVar var (s ++ str ++ ss)
                           h <- forkIO $ start com cb
                           _ <- forkIO $ trigger com
                                       $ maybe (return ()) (atomically . putTMVar sig)
                           return (Just h,var)
    where is = s ++ "Updating..." ++ ss

updateString :: Config -> TVar [String] ->
                IO [[(Widget, String, Maybe [Action])]]
updateString conf v = do
  s <- atomically $ readTVar v
  let l:c:r:_ = s ++ repeat ""
  io $ mapM (parseString conf) [l, c, r]

updateActions :: XConf -> Rectangle -> [[(Widget, String, Maybe [Action])]] ->
                 IO [([Action], Position, Position)]
updateActions conf (Rectangle _ _ wid _) ~[left,center,right] = do
  let (d,fs) = (display &&& fontS) conf
      strLn :: [(Widget, String, Maybe [Action])] -> IO [(Maybe [Action], Position, Position)]
      strLn  = io . mapM getCoords
      iconW i = maybe 0 Bitmap.width (lookup i $ iconS conf)
      getCoords (Text s,_,a) = textWidth d fs s >>= \tw -> return (a, 0, fi tw)
      getCoords (Icon s,_,a) = return (a, 0, fi $ iconW s)
      partCoord off xs = map (\(a, x, x') -> (fromJust a, x, x')) $
                         filter (\(a, _,_) -> isJust a) $
                         scanl (\(_,_,x') (a,_,w') -> (a, x', x' + w')) (Nothing, 0, off) xs

      totSLen              = foldr (\(_,_,len) -> (+) len) 0
      remWidth xs          = fi wid - totSLen xs
      offs                 = 1
      offset a xs          = case a of
                               C -> (remWidth xs + offs) `div` 2
                               R -> remWidth xs
                               L -> offs

  fmap concat $ mapM (\(a,xs) -> (\xs' -> partCoord (offset a xs') xs') <$> strLn xs) $
                zip [L,C,R] [left,center,right]

-- $print

-- | Draws in and updates the window
drawInWin :: Rectangle -> [[(Widget, String, Maybe [Action])]] -> X ()
drawInWin (Rectangle bgx bgy wid ht) ~[left,center,right] = do
  r <- ask
  let (c,d ) = (config &&& display) r
      (w,fs) = (window &&& fontS  ) r
      strLn  = io . mapM getWidth
      iconW i = maybe 0 Bitmap.width (lookup i $ iconS r)
      getWidth (Text s,cl,_) = textWidth d fs s >>= \tw -> return (Text s,cl,fi tw)
      getWidth (Icon s,cl,_) = return (Icon s,cl,fi $ iconW s)

  withColors d [borderColor c] $ \[bdcolor] -> do
    gc <- io $ createGC  d w
    -- create a pixmap to write to and fill it with a rectangle
    p <- io $ createPixmap d w wid ht
         (defaultDepthOfScreen (defaultScreenOfDisplay d))
    io $ withRenderPicture d p $ \pic -> do
        -- Handle background color
        bgcolor <- parseRenderColor d (bgColor c)
        withRenderFill d bgcolor $ \bgfill ->
            -- I apparently don't know how to do this properly with
            -- just bgcolor' (putting in the mask alpha directly has strange
            -- results.  I wish someone had better docs on how
            -- XRenderComposite worked...)
            withRenderFill d (XRenderColor 0 0 0 (257 * alpha c)) $ \m ->
                xRenderComposite d pictOpSrc bgfill m pic 0 0 0 0 0 0 (fromIntegral wid) (fromIntegral ht)
        -- Handle transparency
        internAtom d "_XROOTPMAP_ID" False >>= \xid ->
            let xroot = defaultRootWindow d in
            alloca $ \x1 ->
            alloca $ \x2 ->
            alloca $ \x3 ->
            alloca $ \x4 ->
            alloca $ \pprop -> do
                xGetWindowProperty d xroot xid 0 1 False 20 x1 x2 x3 x4 pprop
                prop <- peek pprop
                when (prop /= nullPtr) $ do
                    rootbg <- peek (castPtr prop) :: IO Pixmap
                    xFree prop
                    withRenderPicture d rootbg $ \bgpic ->
                        withRenderFill d (XRenderColor 0 0 0 (0xFFFF - 257 * alpha c)) $ \m ->
                            xRenderComposite d pictOpAdd bgpic m pic (fromIntegral bgx) (fromIntegral bgy) 0 0 0 0 (fromIntegral wid) (fromIntegral ht)
    -- write to the pixmap the new string
    printStrings p gc fs 1 L =<< strLn left
    printStrings p gc fs 1 R =<< strLn right
    printStrings p gc fs 1 C =<< strLn center
    -- draw 1 pixel border if requested
    io $ drawBorder (border c) (borderWidth c) d p gc bdcolor wid ht
    -- copy the pixmap with the new string to the window
    io $ copyArea   d p w gc 0 0 wid ht 0 0
    -- free up everything (we do not want to leak memory!)
    io $ freeGC     d gc
    io $ freePixmap d p
    -- resync
    io $ sync       d True

verticalOffset ::  (Integral b, Integral a, MonadIO m) =>
                   a -> Widget -> XFont -> Config -> m b
verticalOffset ht (Text t) fontst conf
  | textOffset conf > -1 = return $ fi (textOffset conf)
  | otherwise = do
     (as,ds) <- io $ textExtents fontst t
     let bwidth = borderOffset (border conf) (borderWidth conf)
         verticalMargin = (fi ht) - fi (as + ds) - 2 * fi (abs bwidth)
     return $ (fi ht) - (fi ds) - (verticalMargin `div` 2) + bwidth + 1
verticalOffset _ (Icon _) _ conf
  | iconOffset conf > -1 = return $ fi (iconOffset conf)
  | otherwise = do
     let bwidth = borderOffset (border conf) (borderWidth conf)
     return $ bwidth + 1

-- | An easy way to print the stuff we need to print
printStrings :: Drawable -> GC -> XFont -> Position
             -> Align -> [(Widget, String, Position)] -> X ()
printStrings _ _ _ _ _ [] = return ()
printStrings dr gc fontst offs a sl@((s,c,l):xs) = do
  r <- ask
  let (conf,d) = (config &&& display) r
      Rectangle _ _ wid ht = rect r
      totSLen = foldr (\(_,_,len) -> (+) len) 0 sl
      remWidth = fi wid - fi totSLen
      offset = case a of
                 C -> (remWidth + offs) `div` 2
                 R -> remWidth
                 L -> offs
      (fc,bc) = case break (==',') c of
                 (f,',':b) -> (f, b           )
                 (f,    _) -> (f, bgColor conf)
  valign <- verticalOffset ht s fontst conf
  case s of
    (Text t) -> io $ printString d dr fontst gc fc bc offset valign t
    (Icon p) -> io $ maybe (return ()) (drawBitmap d dr gc fc bc offset valign) (lookup p (iconS r))
  printStrings dr gc fontst (offs + l) a xs
