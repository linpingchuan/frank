
-- A simple parser for the Frank language
{-# LANGUAGE PackageImports #-}
module Parser where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class

import Data.Char
import qualified Data.Map.Strict as M
import qualified Data.HashSet as HashSet

import Text.Trifecta
import Text.Trifecta.Delta
import "indentation-trifecta" Text.Trifecta.Indentation

import Text.Parser.Token as Tok
import Text.Parser.Token.Style
import qualified Text.Parser.Token.Highlight as Hi

import qualified Data.ByteString.Char8 as Char8

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertEqual, assertFailure, Assertion)

import BwdFwd
import Syntax
import ParserCommon
import Debug

-- the eof disallows gibberish at the end of the file!
prog :: (Applicative m, MonadicParsing m) => m (Prog Raw)
prog = MkProg <$ whiteSpace <*> do tts <- many tterm; eof; return tts

tterm :: MonadicParsing m => m (TopTm Raw)
tterm = attachLoc (DataTm <$> parseDataT <|>
                   SigTm <$> try parseMHSig <|>
                   ClsTm <$> parseMHCls <|>
                   ItfTm <$> try parseItf <|>
                   ItfAliasTm <$> parseItfAlias)

parseTyVar :: MonadicParsing m => m (Id, Kind)
parseTyVar = (\x -> (x, ET)) <$> brackets parseEVar <|>
             (\x -> (x, VT)) <$> identifier

parseDataT :: MonadicParsing m => m (DataT Raw)
parseDataT = attachLoc $ do reserved "data"
                            name <- identifier
                            ps <- many parseTyVar
                            symbol "="
                            cs <- localIndentation Gt ctrlist
                            return $ DT name ps cs

parseEVar :: MonadicParsing m => m Id
parseEVar = do mx <- optional identifier
               case mx of
                 Nothing -> return "£"
                 Just x -> return x

ctrlist :: MonadicParsing m => m [Ctr Raw]
ctrlist = sepBy parseCtr (symbol "|")

parseCtr :: MonadicParsing m => m (Ctr Raw)
parseCtr = attachLoc $ do name <- identifier
                          args <- many parseVType'
                          return $ Ctr name args

parseMHSig :: MonadicParsing m => m (MHSig Raw)
parseMHSig = attachLoc $ do name <- identifier
                            symbol ":"
                            ty <- parseSigType
                            return (Sig name ty)

-- As the outer braces are optional in top-level signatures we require
-- that plain pegs must have explicit ability brackets.
--
-- The following collections of signatures are equivalent:
--
--   f : {A -> B -> C}  and  f : A -> B -> C
--   x : {Int}  and  x : {[]Int}  and x : []Int
--
-- A signature of the form
--
--   x : Int
--
-- is not currently valid. Once we add support for top level values it
-- will become valid, but will not mean the same thing as:
--
--   x : []Int
parseSigType :: MonadicParsing m => m (CType Raw)
parseSigType = (do a <- getLoc
                   symbol "{"
                   ct <- parseCType
                   symbol "}"
                   rest <- optional (symbol "->" *> parseCType)
                   return $
                     case rest of
                       Nothing -> modifyAnn a ct
                       Just (CType ports peg a') ->
                         CType (Port idAdjRaw (SCTy ct a') a' : ports) peg a) <|>
               attachLoc (do ports <- some (try (parsePort <* symbol "->"))
                             peg <- parsePeg
                             return $ CType ports peg) <|>
               attachLoc (do peg <- parsePegExplicit
                             return $ CType [] peg)

parseMHCls :: MonadicParsing m => m (MHCls Raw)
parseMHCls = provideLoc $ \a -> do
               name <- identifier
               ps <- choice [some parsePattern, symbol "!" >> return []]
               symbol "="
               seq <- localIndentation Gt parseRawTmSeq
               return $ MHCls name (Cls ps seq a) a

parseItf :: MonadicParsing m => m (Itf Raw)
parseItf = attachLoc $ do
             reserved "interface"
             name <- identifier
             ps <- many parseTyVar
             symbol "="
             xs <- localIndentation Gt $ sepBy1 parseCmd (symbol "|")
             return (Itf name ps xs)

parseCmd :: MonadicParsing m => m (Cmd Raw)
parseCmd = attachLoc $ do cmd <- identifier
                          ps <- many parseTyVar  -- polymorphic commands
                          symbol ":"
                          (xs,y) <- parseCmdType
                          return (Cmd cmd ps xs y)

-- type vars, input types, output type
parseCmdType :: MonadicParsing m => m ([VType Raw], VType Raw)
parseCmdType = do vs <- sepBy1 parseVType (symbol "->")
                  if length vs == 1 then return ([],head vs)
                  else return (init vs, last vs)

parseItfAlias :: MonadicParsing m => m (ItfAlias Raw)
parseItfAlias = attachLoc $ do reserved "interface"
                               name <- identifier
                               ps <- many parseTyVar
                               symbol "="
                               a <- getLoc
                               symbol "["
                               m <- parseItfInstances
                               symbol "]"
                               return $ ItfAlias name ps m

parseCType :: MonadicParsing m => m (CType Raw)
parseCType = attachLoc $ do ports <- many (try (parsePort <* symbol "->"))
                            peg <- parsePeg
                            return $ CType ports peg

parsePort :: MonadicParsing m => m (Port Raw)
parsePort = attachLoc $ do adj <- parseAdj
                           ty <- parseVType
                           return $ Port adj ty

parsePeg :: MonadicParsing m => m (Peg Raw)
parsePeg = attachLoc $ do ab <- parseAb
                          ty <- parseVType
                          return $ Peg ab ty

parsePegExplicit :: MonadicParsing m => m (Peg Raw)
parsePegExplicit = attachLoc $ do ab <- brackets parseAbBody
                                  ty <- parseVType
                                  return $ Peg ab ty

parseAdj :: MonadicParsing m => m (Adj Raw)
parseAdj = provideLoc $ \a -> do
              mItfMap <- optional $ angles parseItfInstances
              case mItfMap of
                Nothing -> return $ Adj (ItfMap M.empty a) a
                Just itfMap -> return $ Adj itfMap a

parseDTAb :: MonadicParsing m => m (Ab Raw)
parseDTAb = brackets parseAbBody

parseItfInstances :: MonadicParsing m => m (ItfMap Raw)
parseItfInstances = do
  a <- getLoc
  insts <- sepBy parseItfInstance (symbol ",")
  return $ foldl addInstanceToItfMap (ItfMap M.empty a) insts

-- 0 | 0|Interfaces | E|Interfaces | Interfaces
parseAbBody :: MonadicParsing m => m (Ab Raw)
parseAbBody = provideLoc $ \a ->
                -- closed ability: [0] or [0 | i_1, ... i_n]
                (do symbol "0"
                    m <- option (ItfMap M.empty a) (symbol "|" *> parseItfInstances)
                    return $ Ab (EmpAb a) m a) <|>
                -- open ability:   [i_1, ..., i_n] (implicitly e := £) or [e | i_1, ..., i_n]
                (do e <- option (AbVar "£" a) (try $ AbVar <$> identifier <* symbol "|" <*> pure a)
                    m <- parseItfInstances
                    return $ Ab e m a)

parseAb :: MonadicParsing m => m (Ab Raw)
parseAb = do mxs <- optional $ brackets parseAbBody
             case mxs of
               Nothing -> provideLoc $ \a ->
                 return $ Ab (AbVar "£" a) (ItfMap M.empty a) a
               Just ab -> return ab

parseItfInstance :: MonadicParsing m => m (Id, [TyArg Raw])
parseItfInstance = do x <- identifier
                      ts <- many parseTyArg
                      return (x, ts)

-- This parser gives higher precedence to MkDTTy when coming across "X"
-- E.g., the type "X" becomes   MkDTTy "X" []   (instead of MkTVar "X")
parseVType :: MonadicParsing m => m (VType Raw)
parseVType = try parseDTType <|> -- could possibly also be a MKTvar (determined
                                 -- during refinement)
             parseVType'

-- This parser gives higher precedence to MkTVar when coming across "X"
-- E.g., the type "X" becomes   MkTVar "X"   (instead of MkDTTy "X" [])
-- By writing "(X)" one can escape back to parseVType
parseVType' :: MonadicParsing m => m (VType Raw)
parseVType' = parens parseVType <|>
              (attachLoc $ SCTy <$> try (braces parseCType)) <|>
              (attachLoc $ StringTy <$ reserved "String") <|>
              (attachLoc $ IntTy <$ reserved "Int") <|>
              (attachLoc $ CharTy <$ reserved "Char") <|>
              -- could possibly also be a MkDTTy (determined during refinement)
              (attachLoc $ TVar <$> identifier)

parseTyArg :: MonadicParsing m => m (TyArg Raw)
parseTyArg = attachLoc $ VArg <$> parseVType' <|>
                         EArg <$> parseDTAb

-- Parse a potential datatype. Note it may actually be a type variable.
parseDTType :: MonadicParsing m => m (VType Raw)
parseDTType = attachLoc $ do x <- identifier
                             args <- localIndentation Gt $ many parseTyArg
                             return $ DTTy x args

parseRawTmSeq :: MonadicParsing m => m (Tm Raw)
parseRawTmSeq = do loc <- getLoc
                   tm1 <- parseRawTm
                   m <- optional $ symbol ";"
                   case m of
                     Just _ -> do tm2 <- parseRawTmSeq
                                  return $ TmSeq tm1 tm2 loc
                     Nothing -> return tm1

-- parse term of 1st syntactic category
parseRawTm :: MonadicParsing m => m (Tm Raw)
parseRawTm = parseLet <|>
             try parseRawOpTm <|>
             parseRawTm'

-- parse term of 2nd syntactic category
-- parse binary operation or term comb t_1 ... t_n
parseRawOpTm :: (MonadicParsing m) => m (Tm Raw)
parseRawOpTm = do loc <- getLoc
                  uminus <- optional $ symbol "-"
                  t1 <- parseRawOperandTm
                  let t1' = case uminus of
                              Just _ -> Use (RawComb (RawId "-" loc) [IntTm 0 loc, t1] loc) loc
                              Nothing -> t1
                  (do binOp <- parseBinOp
                      t2 <- parseRawOperandTm
                      return $ Use (RawComb binOp [t1',t2] loc) loc
                    <|> (return t1'))

parseRawOperandTm :: MonadicParsing m => m (Tm Raw)
parseRawOperandTm = (attachLoc $ Use <$> try parseComb) <|>
                    parens parseRawOpTm <|>
                    (attachLoc $ Use <$> parseId) <|>
                    (attachLoc $ IntTm <$> natural)

parseBinOp :: MonadicParsing m => m (Use Raw)
parseBinOp = attachLoc $ do op <- choice $ map symbol ["+","-","*","/","::"]
                            let op' = if op == "::" then "cons" else op
                            return $ RawId op'

parseId :: MonadicParsing m => m (Use Raw)
parseId = attachLoc $ do x <- identifier
                         return $ RawId x

parseNullaryComb :: MonadicParsing m => m (Use Raw)
parseNullaryComb = attachLoc $ do x <- choice [parseId, parens parseComb]
                                  symbol "!"
                                  return $ RawComb x []

parseLet :: MonadicParsing m => m (Tm Raw)
parseLet = attachLoc $ do reserved "let"
                          x <- identifier
                          symbol "="
                          tm1 <- parseRawTm
                          reserved "in"
                          tm2 <- parseRawTmSeq
                          return $ Let x tm1 tm2

-- parse any term except let-expression or binary operation
parseRawTm' :: MonadicParsing m => m (Tm Raw)
parseRawTm' = (attachLoc $ Use <$> try parseNullaryComb) <|>  -- x!
              parens parseRawTmSeq <|>                        -- t_1 ; ... ; t_n
              (attachLoc $ Use <$> parseId) <|>               -- x
              (attachLoc $ SC <$> parseRawSComp) <|>          -- { p_1 -> t_1 | ...
              (attachLoc $ StrTm <$> stringLiteral) <|>       -- "string"
              (attachLoc $ IntTm <$> natural) <|>             -- 42
              (attachLoc $ CharTm <$> charLiteral) <|>        -- 'c'
              (attachLoc $ ListTm <$> listTm)                 -- [t_1, ..., t_n]

listTm :: MonadicParsing m => m [Tm Raw]                      -- [t_1, ..., t_n]
listTm = brackets (sepBy parseRawTm (symbol ","))

parseComb :: MonadicParsing m => m (Use Raw)
parseComb = attachLoc $ do x <- choice [parseId, parens parseComb]
                           args <- choice [some parseRawTm', symbol "!" >> pure []]
                           return $ RawComb x args

parseRawClause :: MonadicParsing m => m (Clause Raw)
parseRawClause = attachLoc $ do ps <- choice [try parsePatterns, pure []]
                                seq <- parseRawTmSeq
                                return $ Cls ps seq
  where parsePatterns = do
          ps <- choice [some parsePattern, symbol "!" >> return []]
          symbol "->"
          return ps

parsePattern :: MonadicParsing m => m (Pattern Raw)
parsePattern = try parseCPat <|> (attachLoc $ VPat <$> parseVPat)

parseCPat :: MonadicParsing m => m (Pattern Raw)
parseCPat = between (symbol "<") (symbol ">") $
            try parseCmdPat <|> parseThunkPat

parseThunkPat :: MonadicParsing m => m (Pattern Raw)
parseThunkPat = attachLoc $ do x <- identifier
                               return (ThkPat x)

parseCmdPat :: MonadicParsing m => m (Pattern Raw)
parseCmdPat = attachLoc $ do cmd <- identifier
                             ps <- many parseVPat
                             symbol "->"
                             g <- identifier
                             return (CmdPat cmd ps g)

parseVPat :: MonadicParsing m => m (ValuePat Raw)
parseVPat = parseDataTPat <|>
            (attachLoc $ do x <- identifier
                            return $ VarPat x) <|>
            (attachLoc $ IntPat <$> try integer) <|> -- try block for unary minus
            (attachLoc $ CharPat <$> charLiteral) <|>
            (attachLoc $ StrPat <$> stringLiteral) <|>
            (attachLoc $ ListPat <$> brackets (sepBy parseVPat (symbol ",")))

parseDataTPat :: MonadicParsing m => m (ValuePat Raw)
parseDataTPat = attachLoc $ parens $ ((try (do p <- parseVPat
                                               symbol "::"
                                               q <- parseVPat
                                               return $ ConsPat p q)) <|>
                                     (do k <- identifier
                                         ps <- many parseVPat
                                         return $ DataPat k ps))

parseRawSComp :: MonadicParsing m => m (SComp Raw)
parseRawSComp = attachLoc $ localIndentation Gt $ absoluteIndentation $
                do cs <- braces $ sepBy parseRawClause (symbol "|")
                   return $ SComp cs

evalCharIndentationParserT :: Monad m => FrankParser Char m a ->
                              IndentationState -> m a
evalCharIndentationParserT = evalIndentationParserT . runFrankParser

evalTokenIndentationParserT :: Monad m => FrankParser Token m a ->
                               IndentationState -> m a
evalTokenIndentationParserT = evalIndentationParserT . runFrankParser

--TODO: LC: Give types, make parsing-interface clearer
runParse ev p input =
   let indA = ev p $ mkIndentationState 0 infIndentation True Ge
   in case parseString indA (Directed Char8.empty 0 0 0 0) input of
    Failure err -> Left (show err)
    Success t -> Right t

runProgParse ev input = runParse ev prog input

-- runParseFromFileEx ev p fname =
--   let indA = ev p $ mkIndentationState 0 infIndentation True Ge in
--   do res <- parseFromFileEx indA fname
--      case res of
--        Failure err -> return $ Left (show err)
--        Success t -> return $ Right t

-- runProgParseFromFileEx ev fname = runParseFromFileEx ev prog fname

-- runTokenParseFromFile :: (MonadIO m, Applicative m, MonadicParsing m) =>
--                          String -> m (Either String (Prog Raw))
-- runTokenParseFromFile = runProgParseFromFileEx evalTokenIndentationParserT

runTokenParse p = runParse evalTokenIndentationParserT p
runTokenProgParse = runProgParse evalTokenIndentationParserT

getLoc :: (MonadicParsing m) => m Raw
getLoc = do r <- rend
            line <- line
            pos <- position
            case delta r of
              (Directed _ l c _ _) -> return $ Raw $ InCode (fromIntegral l + 1, fromIntegral c + 1)
              _ -> error "precondition not fulfilled"

attachLoc :: (MonadicParsing m) => m (Raw -> AnnotTFix Raw f) -> m (AnnotTFix Raw f)
attachLoc parser = do a <- getLoc
                      parser <*> pure a

provideLoc :: (MonadicParsing m) => (Raw -> m (AnnotTFix Raw f)) -> m (AnnotTFix Raw f)
provideLoc parser = do a <- getLoc
                       parser a


-- Tests
input = [ "tests/evalState.fk"
        , "tests/listMap.fk"
        , "tests/suspended_computations.fk"
        , "tests/fib.fk"
        , "tests/paper.fk"]

--outputc = map runCharParseFromFile input
--outputt = map runTokenParseFromFile input

assertParsedOk :: (Show err, Show a, Eq a) => IO (Either err a) -> IO a
                  -> Assertion
assertParsedOk actual expected =
  do x <- actual
     case x of
       Right ok -> do y <- expected
                      assertEqual "parsing succeeded, but " y ok
       Left err -> do y <- expected
                      assertFailure ("parse failed with " ++ show err
                                     ++ ", expected " ++ show y)
