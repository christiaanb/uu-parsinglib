{-# LANGUAGE  RankNTypes,
              GADTs,
              MultiParamTypeClasses,
              FunctionalDependencies,
              FlexibleInstances,
              FlexibleContexts,
              UndecidableInstances,
              NoMonomorphismRestriction,
              TypeSynonymInstances,
              ScopedTypeVariables,
              TypeOperators #-}

-- | This module contains basic instances for the class interface described in the "Text.ParserCombinators.UU.Core" module.
--   It demonstates how to construct and maintain a state during parsing. In the state we store error messages,
--   positional information and the actual input that is being parsed.
--   Unless you have very specific wishes the module can be used as such.
--   Since we make use of the "Data.ListLike" interface a wide variety of input structures can be handled.

module Text.ParserCombinators.UU.BasicInstances(
-- * Data Types
   Error      (..),
   Str        (..),
   Insertion  (..),
   LineCol    (..),
   LineColPos (..),
-- * Types
   Parser,
   ParserTrafo,
-- * Classes
   IsLocationUpdatedBy,
-- * Functions
   createStr,
   show_expecting,
   pSatisfy,
   pRangeInsert,
   pRange,
   pSymInsert,
   pSym,
   pToken,
   pTokenCost,
   pMunch,
   pMunchL
) where
import Text.ParserCombinators.UU.Core
import Data.Maybe
import Data.Word
-- import Debug.Trace
import qualified Data.ListLike as LL

-- *  `Error`
-- |The data type `Error` describes the various kinds of errors which can be generated by the instances in this module
data Error  pos =    Inserted String pos        Strings
                     -- ^  @String@ was inserted at @pos@-ition, where we expected  @Strings@
                   | Deleted  String pos        Strings
                     -- ^  @String@ was deleted at @pos@-ition, where we expected  @Strings@
                   | Replaced String String pos Strings
                     -- ^ for future use
                   | DeletedAtEnd String
                     -- ^ the unconsumed part of the input was deleted

instance (Show pos) => Show (Error  pos) where
 show (Inserted s pos expecting)       = "--    Inserted  " ++  s ++  show_expecting  pos expecting
 show (Deleted  t pos expecting)       = "--    Deleted   " ++  t ++  show_expecting  pos expecting
 show (Replaced old new pos expecting) = "--    Replaced  " ++ old ++ " by "++ new ++  show_expecting  pos expecting
 show (DeletedAtEnd t)                 = "--    The token " ++ t ++ " was not consumed by the parsing process."



show_expecting :: Show pos => pos -> [String] -> String
show_expecting pos [a]    = " at position " ++ show pos ++ " expecting " ++ a
show_expecting pos (a:as) = " at position " ++ show pos ++
                            " expecting one of [" ++ a ++ concat (map (", " ++) as) ++ "]"
show_expecting pos []     = " expecting nothing"

-- * The Stream data type
-- | The data type `Str` holds the input data to be parsed, the current location, the error messages generated
--   and whether it is ok to delete elements from the input. Since an insert/delete action is
--   the same as a delete/insert action we try to avoid the first one.
--   So: no deletes after an insert.

data Str a s loc = Str { -- | the unconsumed part of the input
                         input    :: s,
                         -- | the accumulated error messages
                         msgs     :: [Error loc],
                         -- | the current input position
                         pos      :: loc,
                         -- | we want to avoid deletions after insertions
                         deleteOk :: !Bool
                       }

-- | A `Parser` is a parser that is prepared to accept "Data.Listlike" input; hence we can deal with @String@'s, @ByteString@'s, etc.
type Parser      a    = (IsLocationUpdatedBy loc Char, LL.ListLike state Char) => P (Str Char state loc) a

-- | A @`ParserTrafo` a b@ maps a @`Parser` a@ onto a @`Parser` b@.
type ParserTrafo a  b = (IsLocationUpdatedBy loc Char, LL.ListLike state Char) => P (Str Char state loc) a ->  P (Str Char state loc) b

-- |  `createStr` initialises the input stream with the input data and the initial position. There are no error messages yet.
createStr :: LL.ListLike s a => loc -> s -> Str a s loc
createStr beginpos ls = Str ls [] beginpos True


-- The first parameter is the current position, and the second parameter the part which has been removed from the input.
instance IsLocationUpdatedBy Int Char where
   advance pos _ = pos + 1

instance IsLocationUpdatedBy Int Word8 where
   advance pos _ = pos + 1

data LineCol = LineCol !Int !Int deriving Show
instance IsLocationUpdatedBy LineCol Char where
   advance (LineCol line pos) c = case c of
                                 '\n' ->  LineCol (line+1) 0
                                 '\t' ->  LineCol line    ( pos + 8 - (pos-1) `mod` 8)
                                 _    ->  LineCol line    (pos + 1)

data LineColPos = LineColPos !Int !Int !Int  deriving Show
instance IsLocationUpdatedBy LineColPos Char where
   advance (LineColPos line pos abs) c = case c of
                               '\n' ->  LineColPos (line+1) 0                           (abs + 1)
                               '\t' ->  LineColPos line     (pos + 8 - (pos-1) `mod` 8) (abs + 1)
                               _    ->  LineColPos line     (pos + 1)                   (abs + 1)

instance IsLocationUpdatedBy loc a => IsLocationUpdatedBy loc [a] where
   advance  = foldl advance

instance (Show a, LL.ListLike s a) => Eof (Str a s loc) where
       eof (Str  i        _    _    _    )              = LL.null i
       deleteAtEnd (Str s msgs pos ok )     | LL.null s = Nothing
                                            | otherwise = Just (5, Str (LL.tail s) (msgs ++ [DeletedAtEnd (show (LL.head s))]) pos ok)


instance  StoresErrors (Str a s loc) (Error loc) where
       getErrors   (Str  inp      msgs pos ok    )     = (msgs, Str inp [] pos ok)

instance  HasPosition (Str a s loc) loc where
       getPos   (Str  inp      msgs pos ok    )        = pos

-- | the @String@ describes what is being inserted, the @a@ parameter the value which is to be inserted and the @cost@ the prices to be paid.
data Insertion a = Insertion  String a Cost

-- | `pSatisfy`  describes and elementary parsing step. Its first parameter check whether the head element of the input can be recognised,
--    and the second parameter how to proceed in case an element recognised by this parser is absent,
--    and parsing may proceed by pretending such an element was present in the input anayway.
pSatisfy :: forall loc state a .((Show a,  loc `IsLocationUpdatedBy` a, LL.ListLike state a) => (a -> Bool) -> (Insertion a) -> P (Str  a state loc) a)
pSatisfy p  (Insertion msg  a cost) = pSymExt splitState (Succ (Zero)) Nothing
  where  splitState :: forall r. ((a ->  (Str  a state loc)  -> Steps r) ->  (Str  a state loc) -> Steps r)
         splitState  k (Str  tts   msgs pos  del_ok)
          = show_attempt ("Try Predicate: " ++ msg ++ " at position " ++ show pos ++ "\n") (
             let ins exp = (cost, k a (Str tts (msgs ++ [Inserted (show a)  pos  exp]) pos  False))
             in if   LL.null tts
                then Fail [msg] [ins]
                else let t       = LL.head tts
                         ts      = LL.tail tts
                         del exp = (4, splitState k (Str ts (msgs ++ [Deleted  (show t)  pos  exp]) (advance pos t) True ))
                     in if p t
                        then  show_symbol ("Accepting symbol: " ++ show t ++ " at position: " ++ show pos ++"\n")
                              (Step 1 (k t (Str ts msgs (advance pos t) True)))
                        else  Fail [msg] (ins: if del_ok then [del] else [])
            )
-- | `pRangeInsert` recognises an element between a lower and an upper bound. Furthermore it can be specified what element
--   is to be inserted in case such an element is not at the head of the input.
pRangeInsert :: (Ord a, Show a, IsLocationUpdatedBy loc a, LL.ListLike state a) => (a, a) -> Insertion a -> P (Str a state loc) a
pRangeInsert (low, high)  = pSatisfy (\ t -> low <= t && t <= high)

-- | `pRange` uses the information from the bounds to compute the `Insertion` information.
pRange ::  (Ord a, Show a, IsLocationUpdatedBy loc a, LL.ListLike state a) => (a, a) -> P (Str a state loc) a
pRange lh@(low, high) = pRangeInsert lh (Insertion (show low ++ ".." ++ show high) low 5)


-- | `pSymInsert` recognises a specific element. Furthermore it can be specified what element
--   is to be inserted in case such an element is not at the head of the input.
pSymInsert  :: (Eq a,Show a, IsLocationUpdatedBy loc a, LL.ListLike state a) => a -> Insertion a -> P (Str a state loc) a
pSymInsert  t  = pSatisfy (==t)

-- | `pSym` recognises a specific element. Furthermore it can be specified what element. Information about `Insertion` is derived from the parameter.
--   is to be inserted in case such an element is not at the head of the input.
pSym ::   (Eq a,Show a, IsLocationUpdatedBy loc a, LL.ListLike state a) => a ->  P (Str a state loc) a
pSym  t = pSymInsert t (Insertion (show t) t 5)

-- | `pMunchL` recognises the longest prefix of the input for which the passed predicate holds. The message parameter is used when tracing has been switched on.
pMunchL :: forall loc state a .((Show a,  loc `IsLocationUpdatedBy` a, LL.ListLike state a) => (a -> Bool) -> String -> P (Str  a state loc) [a])
pMunchL p msg = pSymExt splitState Zero Nothing
  where  splitState :: forall r. (([a] ->  (Str  a state loc)  -> Steps r) ->  (Str  a state loc) -> Steps r)
         splitState k inp@(Str tts msgs pos del_ok)
          =    show_attempt ("Try Munch: " ++ msg ++ "\n") (
               let (fmunch, rest)  = LL.span p tts
                   munched         = LL.toList fmunch
                   l               = length munched
               in if l > 0 then show_munch ("Accepting munch: " ++ msg ++ " " ++ show munched ++  show pos ++ "\n")
                                (Step l (k munched (Str rest msgs (advance pos munched)  (l>0 || del_ok))))
                           else show_munch ("Accepting munch: " ++ msg ++ " as emtty munch " ++ show pos ++ "\n") (k [] inp)
               )

-- | `pMunch` recognises the longest prefix of the input for which the passed predicate holds.
pMunch :: forall loc state a .((Show a,  loc `IsLocationUpdatedBy` a, LL.ListLike state a) => (a -> Bool)  -> P (Str  a state loc) [a])
pMunch  p   = pMunchL p ""

-- | `pTokenCost` succeeds if its parameter is a prefix of the input.
pTokenCost :: forall loc state a .((Show a, Eq a,  loc `IsLocationUpdatedBy` a, LL.ListLike state a) => [a] -> Int -> P (Str  a state loc) [a])
pTokenCost as cost =
  if null as then error "Module: BasicInstances, function: pTokenCost; call  with empty token"
             else pSymExt splitState (nat_length as) Nothing
  where   tas :: state
          tas = LL.fromList as
          nat_length [] = Zero
          nat_length (_:as) = Succ (nat_length as)
          l = length as
          msg = show as
          splitState :: forall r. (([a] ->  (Str  a state loc)  -> Steps r) ->  (Str  a state loc) -> Steps r)
          splitState k inp@(Str tts msgs pos del_ok)
             = show_attempt ("Try Token: " ++ show as ++ "\n") (
                      if LL.isPrefixOf tas tts
                      then  show_tokens ("Accepting token: " ++ show as ++"\n")
                                      (Step l (k as (Str (LL.drop l tts)  msgs (advance pos as) True)))
                      else  let ins exp =  (cost, k as (Str tts (msgs ++ [Inserted msg pos exp]) pos False))
                            in if LL.null tts
                               then  Fail [msg] [ins]
                               else  let t       = LL.head tts
                                         ts      = LL.tail tts
                                         del exp =  (5, splitState  k
                                                            (Str ts (msgs ++ [Deleted  (show t) pos exp])
                                                            (advance pos t) True))
                                     in  Fail [msg] (ins: if del_ok then [del] else [])

                     )
pToken ::  forall loc state a .((Show a, Eq a,  loc `IsLocationUpdatedBy` a, LL.ListLike state a) => [a] -> P (Str  a state loc) [a])
pToken     as   =   pTokenCost as 10

{-# INLINE show_tokens #-}

show_tokens :: String -> b -> b
show_tokens m v =  {-  trace m -}   v

{-# INLINE show_munch #-}
show_munch :: String -> b -> b
show_munch  m v =   {- trace m -}  v

{-# INLINE show_symbol #-}
show_symbol :: String -> b -> b
show_symbol m v =   {- trace m -}  v
-- show_symbol m v =     trace m   v
{-# INLINE show_attempt #-}
show_attempt m v =  {- trace m -}  v
