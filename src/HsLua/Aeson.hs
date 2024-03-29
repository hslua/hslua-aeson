{-|
Module      :  HsLua.Aeson
Copyright   :  © 2017–2021 Albert Krewinkel
License     :  MIT
Maintainer  :  Albert Krewinkel <tarleb@zeitkraut.de>

Glue to HsLua for aeson values.

This provides a @StackValue@ instance for aeson's @Value@ type. The following
conventions are used:

- @Null@ values are encoded as a special value (stored in the registry field
  @HSLUA_AESON_NULL@). Using @nil@ would cause problems with null-containing
  arrays.

- Objects are converted to tables in a straight-forward way.

- Arrays are converted to Lua tables. Array-length is included as the value at
  index 0. This makes it possible to distinguish between empty arrays and empty
  objects.

- JSON numbers are converted to Lua numbers (usually doubles), which can cause
  a loss of precision.
-}
module HsLua.Aeson
  ( peekValue
  , pushValue
  , peekVector
  , pushVector
  , pushNull
  , peekScientific
  , pushScientific
  , peekKeyMap
  , pushKeyMap
  ) where

import Control.Monad ((<$!>), when)
import Data.Scientific (Scientific, toRealFloat, fromFloatDigits)
import Data.String (IsString (fromString))
import Data.Vector (Vector)
import HsLua.Core as Lua
import HsLua.Marshalling as Lua

import qualified Data.Aeson as Aeson
import qualified Data.Vector as Vector
import qualified HsLua.Core.Unsafe as Unsafe

#if MIN_VERSION_aeson(2,0,0)
import Data.Aeson.Key (Key, toText, fromText)
import qualified Data.Aeson.KeyMap as KeyMap
type KeyMap = KeyMap.KeyMap
#else
import Data.Text (Text)
import qualified Data.HashMap.Strict as KeyMap
type Key = Text
type KeyMap = KeyMap.HashMap Key
toText :: Key -> Text
toText = id
fromText :: Text -> Key
fromText = id
#endif

-- Scientific
pushScientific :: Pusher e Scientific
pushScientific = pushRealFloat @Double . toRealFloat

peekScientific :: Peeker e Scientific
peekScientific idx = fromFloatDigits <$!> peekRealFloat @Double idx

-- | Hslua StackValue instance for the Aeson Value data type.
pushValue :: LuaError e => Pusher e Aeson.Value
pushValue = \case
  Aeson.Object o -> pushKeyMap pushValue o
  Aeson.Number n -> checkstack 1 >>= \case
    True -> pushScientific n
    False -> failLua "stack overflow"
  Aeson.String s -> checkstack 1 >>= \case
    True -> pushText s
    False -> failLua "stack overflow"
  Aeson.Array a  -> pushVector pushValue a
  Aeson.Bool b   -> checkstack 1 >>= \case
    True -> pushBool b
    False -> failLua "stack overflow"
  Aeson.Null     -> pushNull

peekValue :: LuaError e => Peeker e Aeson.Value
peekValue idx = liftLua (ltype idx) >>= \case
  TypeBoolean -> Aeson.Bool  <$!> peekBool idx
  TypeNumber -> Aeson.Number <$!> peekScientific idx
  TypeString -> Aeson.String <$!> peekText idx
  TypeTable -> liftLua (checkstack 1) >>= \case
    False -> failPeek "stack overflow"
    True -> do
      isInt <- liftLua $ rawgeti idx 0 *> isinteger top <* pop 1
      if isInt
        then Aeson.Array <$!> peekVector peekValue idx
        else do
          rawlen' <- liftLua $ rawlen idx
          if rawlen' > 0
            then Aeson.Array <$!> peekVector peekValue idx
            else do
              isNull' <- liftLua $ isNull idx
              if isNull'
                then return Aeson.Null
                else Aeson.Object <$!> peekKeyMap peekValue idx
  TypeNil -> return Aeson.Null
  luaType -> fail ("Unexpected type: " ++ show luaType)

-- | Registry key containing the representation for JSON null values.
nullRegistryField :: Name
nullRegistryField = "HSLUA_AESON_NULL"

-- | Push the value which represents JSON null values to the stack (a specific
-- empty table by default). Internally, this uses the contents of the
-- @HSLUA_AESON_NULL@ registry field; modifying this field is possible, but it
-- must always be non-nil.
pushNull :: LuaError e => LuaE e ()
pushNull = checkstack 3 >>= \case
  False -> failLua "stack overflow while pushing null"
  True -> do
    pushName nullRegistryField
    rawget registryindex
    uninitialized <- isnil top
    when uninitialized $ do
      pop 1 -- remove nil
      newtable
      pushvalue top
      setfield registryindex nullRegistryField

-- | Check if the value under the given index represents a @null@ value.
isNull :: LuaError e => StackIndex -> LuaE e Bool
isNull idx = do
  idx' <- absindex idx
  pushNull
  rawequal idx' top <* pop 1

-- | Push a vector onto the stack.
pushVector :: LuaError e
           => Pusher e a
           -> Pusher e (Vector a)
pushVector pushItem !v = do
  checkstack 3 >>= \case
    False -> failLua "stack overflow"
    True -> do
      pushList pushItem $ Vector.toList v
      pushIntegral (Vector.length v)
      rawseti (nth 2) 0

-- | Try reading the value under the given index as a vector.
peekVector :: LuaError e
           => Peeker e a
           -> Peeker e (Vector a)
peekVector peekItem = fmap (retrieving "list") .
  typeChecked "table" istable $ \idx -> do
  let elementsAt [] = return []
      elementsAt (i : is) = do
        liftLua (checkstack 2) >>= \case
          False -> failPeek "Lua stack overflow"
          True  -> do
            x  <- retrieving ("index " <> showInt i) $ do
              liftLua (rawgeti idx i)
              peekItem top `lastly` pop 1
            xs <- elementsAt is
            return (x:xs)
      showInt (Lua.Integer x) = fromString $ show x
  listLength <- liftLua (rawlen idx)
  list <- elementsAt [1..fromIntegral listLength]
  return $! Vector.fromList list

-- | Pushes a 'KeyMap' onto the stack.
pushKeyMap :: LuaError e
           => Pusher e a
           -> Pusher e (KeyMap a)
pushKeyMap pushVal x =
  checkstack 3 >>= \case
    True -> pushKeyValuePairs pushKey pushVal $ KeyMap.toList x
    False -> failLua "stack overflow"

-- | Retrieves a 'KeyMap' from a Lua table.
peekKeyMap :: Peeker e a
           -> Peeker e (KeyMap a)
peekKeyMap peekVal =
  typeChecked "table" istable $ \idx -> cleanup $ do
  liftLua (checkstack 1) >>= \case
    False -> failPeek "Lua stack overflow"
    True -> do
      idx' <- liftLua $ absindex idx
      let remainingPairs = nextPair peekVal idx' >>= \case
            Nothing -> return []
            Just a  -> (a:) <$!> remainingPairs
      liftLua pushnil
      KeyMap.fromList <$!> remainingPairs

-- | Pushes a JSON key to the stack.
pushKey :: Pusher e Key
pushKey = pushText . toText

-- | Retrieves a JSON key from the stack.
peekKey :: Peeker e Key
peekKey = fmap fromText . peekText

-- | Get the next key-value pair from a table. Assumes the last
-- key to be on the top of the stack and the table at the given
-- index @idx@. The next key, if it exists, is left at the top of
-- the stack.
--
-- The key must be either nil or must exist in the table, or this
-- function will crash with an unrecoverable error.
nextPair :: Peeker e b -> Peeker e (Maybe (Key, b))
nextPair peekVal idx = retrieving "key-value pair" $ do
  liftLua (checkstack 1) >>= \case
    False -> failPeek "Lua stack overflow"
    True -> do
      hasNext <- liftLua $ Unsafe.next idx
      if not hasNext
        then return Nothing
        else do
        key   <- retrieving "key"   $! peekKey (nth 2)
        value <- retrieving "value" $! peekVal (nth 1)
        return (Just (key, value))
          `lastly` pop 1  -- remove value, leave the key
