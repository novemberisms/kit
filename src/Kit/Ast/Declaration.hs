module Kit.Ast.Declaration where

import Kit.Ast.Definitions
import Kit.Ast.TypePath
import Kit.Ast.UsingType
import Kit.Parser.Span
import Kit.Str

data Declaration a b
  = DeclVar (VarDefinition a b)
  | DeclFunction (FunctionDefinition a b)
  | DeclType (TypeDefinition a b)
  | DeclTrait (TraitDefinition a b)
  | DeclImpl (TraitImplementation a b)
  | DeclRuleSet (RuleSet a b)
  | DeclUsing (UsingType a b)
  | DeclTuple b
  deriving (Eq, Show)

declName :: (Show b) => Declaration a b -> Str
declName (DeclVar      v) = tpName $ varName v
declName (DeclFunction v) = tpName $ functionName v
declName (DeclType     v) = tpName $ typeName v
declName (DeclTrait    v) = tpName $ traitName v
declName (DeclImpl     v) = "()"
declName (DeclRuleSet  v) = tpName $ ruleSetName v
declName (DeclTuple    b) = s_pack $ show b
declName (DeclUsing    v) = "()"
