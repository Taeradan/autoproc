module Autoproc.Classifier where

-- The purpose of this module is to define the abstract and concrete
-- syntax for the condition expression language.

import Control.Monad.Writer hiding (when)

-- Some functions in this module get their meaning and values from
-- Configuration module.  If you want to change a default such as
-- locking, check the Configuration module.
import Autoproc.Configuration

data EmailAddress = Addr String deriving Show

data Mailbox = Mailbox String

data CExp = CExp [Flag] Cond Act deriving Show

data Flag = Copy
     | Wait
     | IgnoreErrors
     | RawWrite
     | NeedLock Bool
     | Chain
     | CaseSensitive deriving (Eq, Show)

data Cond = And Cond Cond
     | Or Cond Cond
     | Not Cond
     | Always
     | Never
     | CheckMatch String
     | CheckHeader String
     | CheckBody String deriving (Eq, Show)

data Act = File String
     | Fwd [EmailAddress]
     | Filter String
     | Nest [CExp]  deriving Show

--type Rule = Cond -> Act -> m CExp
--type Rule = Cond -> Act -> CExp
--data RuleM a = RuleM a

---------------------------------------------------------------------------
-- Basic functions for manipulating conditions and creating Rules

(.&&.) :: Cond -> Cond -> Cond
c1 .&&. c2 = And c1 c2

(.||.) :: Cond -> Cond -> Cond
c1 .||. c2 = Or c1 c2

subject, body, said :: String -> Cond
subject s = CheckHeader ("^Subject.*"++s)
body s    = CheckBody s
said s    = subject s .||. body s

from, to, to_ :: EmailAddress -> Cond
from (Addr s) = CheckHeader ("^From.*"++s)
to   (Addr s) = CheckHeader ("^TO"++s)
to_  (Addr s) = CheckHeader ("^TO_"++s)

when :: Cond -> Act -> Writer [CExp] ()
when c a = whenWithOptions [lock] c a

whenWithOptions :: [Flag] -> Cond -> Act -> Writer [CExp] ()
whenWithOptions fs c a = tell [CExp fs c a]

placeIn :: Mailbox -> Act
placeIn (Mailbox m) = File m

also :: Act -> Act -> Act
also (Nest as) (Nest bs) = Nest (flagAllButLast Copy (as++bs))
also (Nest as) b         = Nest (flagAllButLast Copy
                                (as++(execWriter $
                                        whenWithOptions [] Always b)))
also a         (Nest bs) = Nest (flagAllButLast Copy
                                ((execWriter
                                     (whenWithOptions [] Always a))++bs))
also a         b         = Nest (flagAllButLast Copy
                                ((execWriter $ whenWithOptions [] Always a)++
                                  (execWriter $ whenWithOptions [] Always b)))

flagAllButLast :: Flag -> [CExp] -> [CExp]
flagAllButLast _ [] = []
flagAllButLast f cs = (map (addFlag f) (init cs))++[removeFlag f (last cs)]

addFlag :: Flag -> CExp -> CExp
addFlag f (CExp fs a c) = (CExp (f:fs) a c)

removeFlag :: Flag -> CExp -> CExp
removeFlag f (CExp fs a c) = (CExp (filter (/= f) fs) a c)

forwardTo :: [EmailAddress] -> Act
forwardTo es = Fwd es

isSpam :: Cond
isSpam = CheckHeader ("^x-spam-status: yes") .||.
         CheckHeader ("^x-spam-flag: yes")

spamLevel :: Int -> Cond
spamLevel n = CheckHeader ("^x-spam-Level: "++(concat (replicate n "\\*")))

--------------------------------------------------------------------------
-- Match monad is just the identity monad, this makes it so that the user
-- cannot use match arbitrarily.  Used a monad instead of just a data
-- wrapper because now we can use the monad utilities like liftM

data Match a = Match a

instance Monad Match where
         return = Match
         (>>=) (Match a) f = (f a)

instance Functor Match where
      fmap = liftM

instance Applicative Match where
      pure  = return
      (<*>) = ap

match :: Match String
match = return "$MATCH"

whenMatch :: Match Cond -> Match Act -> Writer [CExp] ()
whenMatch mc ma = whenMatchWithOptions [lock] mc ma

whenMatchWithOptions :: [Flag] -> Match Cond -> Match Act -> Writer [CExp] ()
whenMatchWithOptions fs (Match c) (Match a) = tell [CExp fs c a]

placeInUsingMatch :: Match Mailbox -> Match Act
placeInUsingMatch = liftM placeIn

(%) :: Cond -> String -> Match Cond
(CheckHeader s1) % s2 = return (CheckHeader (s1++"\\/"++s2))
(CheckBody   s1) % s2 = return (CheckBody   (s1++"\\/"++s2))
(CheckMatch  s1) % s2 = return (CheckMatch  (s1++"\\/"++s2))

refineBy :: Match Cond -> Match Cond -> Match Cond
refineBy = liftM2 (.&&.)

alsoUsingMatch :: Match Act -> Match Act -> Match Act
alsoUsingMatch = liftM2 also

---------------------------------------------------------------------------
-- A few functions to create short hand for sorting
sortBy :: (a -> Cond) -> a -> Mailbox -> Writer [CExp] ()
sortBy f s m = when (f s) (placeIn m)

sortByTo_, sortByTo, sortByFrom :: EmailAddress -> Mailbox -> Writer [CExp] ()
sortByTo_     = sortBy to_
sortByTo      = sortBy to
sortByFrom    = sortBy from

sortBySubject :: String -> Mailbox -> Writer [CExp] ()
sortBySubject = sortBy subject

----------------------------------------------------------------------------
-- Everything below here depends on the values in the Configuration module

-- | If the email address (the String argument) contains "foo", then place the email into a folder
-- by the name "foo".  Actually, the name of the mailbox is created by
-- appending boxPrefix which is defined in the Configuration module.
simpleSortByFrom :: String -> Writer [CExp] ()
simpleSortByFrom s = sortByFrom (Addr s) (mailbox s)

simpleSortByTo_, simpleSortByTo:: String -> Writer [CExp] ()
simpleSortByTo   s = sortByTo   (Addr s) (mailbox s)
simpleSortByTo_  s = sortByTo_  (Addr s) (mailbox s)

mailbox :: String -> Mailbox
mailbox s = Mailbox (boxPrefix++s)

mailBoxFromMatch :: Match String -> Match Mailbox
mailBoxFromMatch = liftM mailbox

lock :: Flag
lock = NeedLock lockDefault

---------------------------------------------------------------------------
-- This is the actually "Classifier" implementation.  It's not as powerful.
-- Please consider this "syntax" to be experimental.

type Class = (String, [Cond])

type Trigger = (String, Int, Act)

type Classifier = Writer [CExp] ()

mkTrigger :: Trigger -> Classifier
mkTrigger (s, i, a) = when (CheckHeader
                            ("^"++(mkHeader s)++(replicate i '*')))
                       a

mkClassifiers :: Class -> Writer [CExp] ()
mkClassifiers (s, cs) = more (length cs) s cs
              where
              more _ _ []     = return ()
              more n t (x:xs) = (when x $ Nest $ incrementHeader t n) >>
                                (more n t xs)

incrementHeader :: String -> Int -> [CExp]
incrementHeader s n = concat
                [execWriter (whenMatch ((CheckHeader ("^"++mkHeader s)) %
                                 (replicate n '*'))
                       updateHeader),
                      execWriter (when (Not (CheckHeader ("^"++mkHeader s)))
                      writeHeader)]
  where
  updateHeader = do { m <- match;
                      return (Filter ("formail -I\""++mkHeader s++m++"*\"")) }
  writeHeader  = Filter ("formail -I\""++mkHeader s++"*\"")

mkHeader :: String -> String
mkHeader s = "X-classifier-"++s++": "

classify :: [Class] -> [Trigger] -> Writer [CExp] ()
classify cs ts = mapM_ mkClassifiers cs >> mapM_ mkTrigger ts

classifyBy :: (String, Cond) -> Act -> Writer [CExp] ()
classifyBy (s, c) a = classify [(s,[c])] [(s, 1, a)]

classifyByAddress::(EmailAddress -> Cond) -> EmailAddress -> Mailbox -> Writer [CExp] ()
classifyByAddress f e@(Addr s) m = classify [(s, [f e])] [(s, 1, placeIn m)]

classifyByTo_, classifyByTo, classifyByFrom:: EmailAddress -> Mailbox -> Writer [CExp] ()
classifyByTo_  = classifyByAddress to_
classifyByTo   = classifyByAddress to
classifyByFrom = classifyByAddress from

classifyByFromAddr :: String -> String -> Writer [CExp] ()
classifyByFromAddr x y = classifyByFrom (Addr x) (mailbox y)

classifyBySubject :: String -> Mailbox -> Writer [CExp] ()
classifyBySubject s m = classify [(s, [subject s])] [(s, 1, placeIn m)]

simpleClassifyBySubject :: String -> Writer [CExp] ()
simpleClassifyBySubject x = classifyBySubject x (mailbox x)

simpleClassifyByFrom, simpleClassifyByTo_, simpleClassifyByTo::String -> Writer [CExp] ()
simpleClassifyByFrom s = classifyByFrom (Addr s) (mailbox s)
simpleClassifyByTo   s = classifyByTo   (Addr s) (mailbox s)
simpleClassifyByTo_  s = classifyByTo_  (Addr s) (mailbox s)

defaultRule :: String -> Writer [CExp] ()
defaultRule str = when Always $ File str

-- | If the subject line contains a certain string, send it to a certain mailbox.
subjectToMbox :: String -> String -> Writer [CExp] ()
subjectToMbox substr mbox = sortBySubject substr $ mailbox mbox

-- | As with 'subjectToMbox', except by email address.
addressToMbox :: String -> String -> Writer [CExp] ()
addressToMbox addr mbox = sortByFrom (Addr addr) (mailbox mbox)

-- | 'addressToMbox' is fine, but may not work well for mailing lists.
toAddressToMbox :: String -> String -> Writer [CExp] ()
toAddressToMbox addr mbox = sortByTo_ (Addr addr) (mailbox mbox)

{- | 'stuffToMbox' is a very general filtering statement, which is intended for specialization
   by other functions.

   The idea is to take a logical operator and fold it over a list of strings.
   If the result is @True@, then the email gets dropped into a specified mailbox.
   So if you wanted to insist that only an email which has strings @x@, @y@, and @z@ in
   the subject-line could appear in the xyz mailbox, you'd use .&&. as the logical operator,
   "xyz" as the @mbox@ argument, [x, y, z] as the list, and a seed value of True. You also need the
   'subject' operator, which will map over the list and turn it into properly typed
   stuff. -}
stuffToMbox :: Cond -> (a1 -> a) -> (a -> Cond -> Cond) -> String -> [a1] -> Writer [CExp] ()
stuffToMbox seed header operator mbox items = when (foldr (operator) seed $ map header items)
                     (insertMbox mbox)

-- | If all the strings appear in the subject line, deposit the email in the specified mailbox
subjectsToMbox :: [String] -> String -> Writer [CExp] ()
subjectsToMbox x y = stuffToMbox Always subject (.&&.) y x

-- | If any of the strings appear in the subject line, send it to the mbox
-- This is currently a bit of a null-op, and I'm not sure it works.
anySubjectsToMbox :: [String] -> String -> Writer [CExp] ()
anySubjectsToMbox x y = stuffToMbox Never subject (.||.) y x

-- subjectsNotToMbox = stuffToMbox Never subject ((.||.) .) ""

insertMbox :: String -> Act
insertMbox = placeIn . mailbox
