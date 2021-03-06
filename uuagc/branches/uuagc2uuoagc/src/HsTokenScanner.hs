
module HsTokenScanner where
import HsToken
import UU.Scanner.Position
import Data.List(sort)
import UU.Util.BinaryTrees
import CommonTypes
import Data.Maybe
import Data.Char

isAGesc :: Char -> Bool
isAGesc c = c == '@'

lexTokens :: Options -> Pos -> String -> [HsToken]
lexTokens = scanTokens keywordstxt keywordsops specialchars opchars
  where keywordstxt   =  []
        keywordsops   =  [".","=", ":=", ":","|","@"]
        specialchars  =  ";()[],_{}`"
        opchars       =  "!#$%&*+./<=>?@\\^|-~:"


scanTokens :: [String] -> [String] -> String -> String -> Options -> Pos -> String -> [HsToken]
scanTokens keywordstxt keywordsops specchars opchars opts pos input
  = doScan pos input

 where
   locatein :: Ord a => [a] -> a -> Bool
   locatein es = isJust . btLocateIn compare (tab2tree (sort es))
   iskw     = locatein keywordstxt
   isop     = locatein keywordsops
   isSymb   = locatein specchars
   -- See http://stackoverflow.com/questions/10548170/what-characters-are-permitted-for-haskell-operators
   isOpsym  c = locatein opchars c
                -- For unicode operators
                || (not (isAscii c) && (isSymbol c || isPunctuation c))

   isIdStart c = isLower c || c == '_'

   isIdChar c =  isAlphaNum c
              || c == '\''
              || c == '_'

   scanIdent p s = let (name,rest) = span isIdChar s
                   in (name,advc (length name) p,rest)

   doScan _ []      = []
   doScan p (c:s)   | isSpace c = let (sp,next) = span isSpace s
                                 in  doScan (foldl (flip updPos)  p (c:sp)) next
   doScan p (c:d:s) | isAGesc c && isIdStart d =
                                 let (fld,p2,rest) = scanIdent (advc 2 p) s
                                     field = d:fld
                                 in case rest of
                                      ('.':r:rs)
                                          | isIdStart r -> let (at,p3,rest2) = scanIdent (advc 2 p2) rs
                                                               attr = r : at
                                                           in AGField (Ident field p) (Ident attr p) p Nothing : doScan p3 rest2
                                      _                 -> AGLocal (Ident field p) p Nothing : doScan p2 rest

   doScan p ('/':'/':s) | clean opts  = doScan p (dropWhile (/= '\n') s)
   doScan p ('/':'*':s) | clean opts  = advc' 2 p (lexCleanNest doScan) s   -- }
   doScan p ('-':'-':s)  = doScan p (dropWhile (/= '\n') s)
   doScan p ('{':'-':s)  = advc' 2 p (lexNest doScan) s   -- }
   doScan p ('"':ss)
     = let (s,swidth,rest) = scanString ss
       in if null rest || head rest /= '"'
             then Err "Unterminated string literal" p : advc' swidth p doScan rest
             else StrToken s p : advc' (swidth+2) p doScan (tail rest)

   doScan p ('\'':ss)
     | clean opts = let (str,nswidth,rest) = scanQualName ss
                    in  HsToken ('\'' : str ++ "'") p : advc' (nswidth + 2) p doScan (tail rest)
     | otherwise
     = let (mc,cwidth,rest) = scanChar ss
       in case mc of
            Nothing -> Err "Error in character literal" p : advc' cwidth p doScan rest
            Just c  -> if null rest || head rest /= '\''
                          then Err "Unterminated character literal" p : advc' (cwidth+1) p doScan rest
                          else CharToken  [c] p : advc' (cwidth+2) p doScan (tail rest)
   doScan p cs@(c:s)

     | isIdStart c || isUpper c
         = let (name', p', s')    = scanIdent (advc 1 p) s
               name               = c:name'
               tok                = if iskw name
                                    then HsToken name p               -- keyword
                                    else if null name' && isSymb c
                                    then HsToken [c] p                -- '_'
                                    else HsToken name p               -- varid / conid
           in tok : doScan p' s'
     | isOpsym c = let (name, s') = span isOpsym cs
                       tok | isop name = HsToken name p
                           | otherwise = HsToken name p
                   in tok : doScan (foldl (flip updPos)  p name)  s'
     | isDigit c = let (base,digs,width,s') = getNumber cs
                       number = case base of
                          8  -> "0o"++digs
                          10 -> digs
                          16 -> "0x"++digs
                          _  -> error $ "Base " ++ show base ++ " is not supported."
                   in  HsToken number p : advc' width p doScan s'
     | isSymb c = HsToken [c] p : advc' 1 p doScan s
     | otherwise = Err ("Unexpected character " ++ show c) p : updPos'  c p doScan s

lexNest :: (Pos -> String -> [HsToken]) -> Pos -> String -> [HsToken]
lexNest cont pos inp = lexNest' cont pos inp
 where lexNest' c p ('{':'-':s) = lexNest' (lexNest' c) (advc 2 p) s
       lexNest' c p ('-':'}':s) = c (advc 2 p) s
       lexNest' c p (x:s)       = lexNest' c (updPos  x p) s
       lexNest' _ _ []          = [Err "Unterminated nested comment" pos]

lexCleanNest :: (Pos -> String -> [HsToken]) -> Pos -> String -> [HsToken]
lexCleanNest cont pos inp = lexNest' cont pos inp
 where lexNest' c p ('/':'*':s) = lexNest' (lexNest' c) (advc 2 p) s
       lexNest' c p ('*':'/':s) = c (advc 2 p) s
       lexNest' c p (x:s)       = lexNest' c (updPos  x p) s
       lexNest' _ _ []          = [Err "Unterminated nested comment" pos]

scanString :: String -> (String, Int, String)
scanString []            = ("",0,[])
scanString ('\\':'&':xs) = let (str,w,r) = scanString xs
                           in (str,w+2,r)
scanString ('\'':xs)     = let (str,w,r) = scanString xs
                           in ('\'': str,w+1,r)
scanString xs = let (ch,cw,cr) = getchar xs
                    (str,w,r)  = scanString cr
--                    str' = maybe "" (:str) ch
                in maybe ("",0,xs) (\c -> (c:str,cw+w,r)) ch

scanQualName :: String -> (String, Int, String)
scanQualName []          = ("",0,[])
scanQualName r@('\'':_)  = ("",0,r)
scanQualName xs          = let (ch,cw,cr) = getchar xs
                               (str,w,r)  = scanQualName cr
                           in  maybe ("",0,xs) (\c -> (c:str,cw+w,r)) ch

scanChar :: String -> (Maybe Char, Int, String)
scanChar ('"' :xs) = (Just '"',1,xs)
scanChar xs        = getchar xs

getchar :: String -> (Maybe Char, Int, String)
getchar []          = (Nothing,0,[])
getchar s@('\n':_ ) = (Nothing,0,s )
getchar s@('\t':_ ) = (Nothing,0,s)
getchar s@('\'':_ ) = (Nothing,0,s)
getchar s@('"' :_ ) = (Nothing,0,s)
getchar   ('\\':xs) = let (c,l,r) = getEscChar xs
                      in (c,l+1,r)
getchar (x:xs)      = (Just x,1,xs)

getEscChar :: String -> (Maybe Char, Int, String)
getEscChar [] = (Nothing,0,[])
getEscChar s@(x:xs) | isDigit x = let (base,n,len,rest) = getNumber s
                                      val = readn base  n
                                  in  if val >= 0 && val <= 255
                                         then (Just (chr val),len, rest)
                                         else (Nothing,1,rest)
                    | otherwise = case x `lookup` cntrChars of
                                 Nothing -> (Nothing,0,s)
                                 Just c  -> (Just c,1,xs)
  where cntrChars = [('a','\a'),('b','\b'),('f','\f'),('n','\n'),('r','\r'),('t','\t')
                    ,('v','\v'),('\\','\\'),('"','\"'),('\'','\'')]

readn :: Int -> String -> Int
readn base n = foldl (\r x  -> value x + base * r) 0 n

getNumber :: String -> (Int,String,Int,String)
getNumber [] = error "Empty string"
getNumber cs@(c:s)
  | c /= '0'               = num10
  | null s                 = const0
  | hs == 'x' || hs == 'X' = num16
  | hs == 'o' || hs == 'O' = num8
  | otherwise              = num10
  where (hs:ts) = s
        const0 = (10, "0",1,s)
        num10  = let (n,r) = span isDigit cs
                 in (10,n,length n,r)
        num16   = readNum isHexaDigit  ts 16
        num8    = readNum isOctalDigit ts 8
        readNum p ts' tk
          = let (n,rs) = span p ts'
            in  if null n then const0
                          else (tk, n, 2+length n,rs)

isHexaDigit :: Char -> Bool
isHexaDigit  d = isDigit d || (d >= 'A' && d <= 'F') || (d >= 'a' && d <= 'f')
isOctalDigit :: Char -> Bool
isOctalDigit d = d >= '0' && d <= '7'

value :: Char -> Int
value c | isDigit c = ord c - ord '0'
        | isUpper c = ord c - ord 'A' + 10
        | isLower c = ord c - ord 'a' + 10
value _ = error "Not a valid value"
