--  | Generic Terminal interface.
--
--  Defines the common interface supported by all terminals.
--
--  See also:
--
--  1. Graphics.Vty.Terminal: This instantiates an abtract interface to the terminal interface based
--  on the TERM and COLORTERM environment variables. 
--  
--  2. Graphics.Vty.Terminal.Generic: Defines the generic interface all terminals need to implement.
--
--  3. Graphics.Vty.Terminal.TerminfoBased: Defines a terminal instance that uses terminfo for all
--  control strings.  No attempt is made to change the character set to UTF-8 for these terminals.
--  I don't know a way to reliably determine if that is required or how to do so.
--
--  4. Graphics.Vty.Terminal.XTermColor: This module contains an interface suitable for xterm-like
--  terminals. These are the terminals where TERM == xterm. This does use terminfo for as many
--  control codes as possible. 
--
-- Copyright 2009-2010 Corey O'Connor
{-# LANGUAGE ScopedTypeVariables #-}
module Graphics.Vty.Terminal ( module Graphics.Vty.Terminal
                             , Terminal(..)
                             , TerminalHandle(..)
                             , DisplayHandle(..)
                             , output_picture
                             , display_context
                             )
    where


import Graphics.Vty.DisplayRegion
import Graphics.Vty.Terminal.Generic
import Graphics.Vty.Terminal.MacOSX as MacOSX
import Graphics.Vty.Terminal.XTermColor as XTermColor
import Graphics.Vty.Terminal.TerminfoBased as TerminfoBased

import Control.Applicative
import Control.Exception ( SomeException, try )
import Control.Monad
import Control.Monad.Trans

import Data.List ( isPrefixOf )

import System.Environment

-- | Returns a TerminalHandle (an abstract Terminal instance) for the current terminal.
--
-- The specific Terminal implementation used is hidden from the API user. All terminal
-- implementations are assumed to perform more, or less, the same. Currently all implementations use
-- terminfo for at least some terminal specific information. This is why platforms without terminfo
-- are not supported. However, as mentioned before, any specifics about it being based on terminfo
-- are hidden from the API user.  If a terminal implementation is developed for a terminal for a
-- platform without terminfo support then Vty should work as expected on that terminal.
--
-- Selection of a terminal is done as follows:
--
--      * If TERM == xterm
--          then the terminal might be one of the Mac OS X .app terminals. Check if that might be
--          the case and use MacOSX if so.
--          otherwise use XTermColor.
--
--      * for any other TERM value TerminfoBased is used.
--
--
-- The terminal has to be determined dynamically at runtime. To satisfy this requirement all
-- terminals instances are lifted into an abstract terminal handle via existential qualification.
-- This implies that the only equations that can used are those in the terminal class.
--
-- To differentiate between Mac OS X terminals this uses the TERM_PROGRAM environment variable.
-- However, an xterm started by Terminal or iTerm *also* has TERM_PROGRAM defined since the
-- environment variable is not reset/cleared by xterm. However a Terminal.app or iTerm.app started
-- from an xterm under X11 on mac os x will likely be done via open. Since this does not propogate
-- environment variables (I think?) this assumes that XTERM_VERSION will never be set for a true
-- Terminal.app or iTerm.app session.
--
--
-- The file descriptor used for output will a duplicate of the current stdout file descriptor.
--
-- todo: add an implementation for windows that does not depend on terminfo. Should be installable
-- with only what is provided in the haskell platform.
--
-- todo: The Terminal interface does not provide any input support.
terminal_handle :: ( Applicative m, MonadIO m ) => m TerminalHandle
terminal_handle = do
    term_type <- liftIO $ getEnv "TERM"
    t <- if "xterm" `isPrefixOf` term_type
        then do
            maybe_terminal_app <- get_env "TERM_PROGRAM"
            case maybe_terminal_app of
                Nothing 
                    -> XTermColor.terminal_instance term_type >>= new_terminal_handle
                Just v | v == "Apple_Terminal" || v == "iTerm.app" 
                    -> do
                        maybe_xterm <- get_env "XTERM_VERSION"
                        case maybe_xterm of
                            Nothing -> MacOSX.terminal_instance v >>= new_terminal_handle
                            Just _  -> XTermColor.terminal_instance term_type >>= new_terminal_handle
                -- Assume any other terminal that sets TERM_PROGRAM to not be an OS X terminal.app
                -- like terminal?
                _   -> XTermColor.terminal_instance term_type >>= new_terminal_handle
        -- Not an xterm-like terminal. try for generic terminfo.
        else TerminfoBased.terminal_instance term_type >>= new_terminal_handle
    return t
    where
        get_env var = do
            mv <- liftIO $ try $ getEnv var
            case mv of
                Left (_e :: SomeException)  -> return $ Nothing
                Right v -> return $ Just v

-- | Sets the cursor position to the given output column and row. 
--
-- This is not necessarially the same as the character position with the same coordinates.
-- Characters can be a variable number of columns in width.
--
-- Currently, the only way to set the cursor position to a given character coordinate is to specify
-- the coordinate in the Picture instance provided to output_picture or refresh.
set_cursor_pos :: MonadIO m => TerminalHandle -> Int -> Int -> m ()
set_cursor_pos t x y = do
    bounds <- display_bounds t
    when (x >= 0 && x < region_width bounds && y >= 0 && y < region_height bounds) $ do
        d <- display_context t bounds
        liftIO $ marshall_to_terminal t (move_cursor_required_bytes d x y) (serialize_move_cursor d x y)

-- | Hides the cursor
hide_cursor :: MonadIO m => TerminalHandle -> m ()
hide_cursor t = do
    bounds <- display_bounds t
    d <- display_context t bounds
    liftIO $ marshall_to_terminal t (hide_cursor_required_bytes d) (serialize_hide_cursor d) 
    
-- | Shows the cursor
show_cursor :: MonadIO m => TerminalHandle -> m ()
show_cursor t = do
    bounds <- display_bounds t
    d <- display_context t bounds
    liftIO $ marshall_to_terminal t (show_cursor_required_bytes d) (serialize_show_cursor d) 

