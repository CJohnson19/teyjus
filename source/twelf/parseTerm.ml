(* This is taken from the Twelf implementation *)

module type PARSE_TERM =
sig

  (*! structure Parsing : PARSING !*)

  val parseQualId' : (string list * Parsing.Parsing.lexResult) Parsing.Parsing.parser
  val parseTerm' : ExtSyn.term Parsing.Parsing.parser
  val parseDec' : (string option * ExtSyn.term option) Parsing.Parsing.parser

end  (* signature PARSE_TERM *)


module ParseTerm : PARSE_TERM =
struct

  (* Operators and atoms for operator precedence parsing *)
  type 'a operator =
        Atom of 'a
      | Infix of (int * Lfabsyn.assoc) * ('a * 'a -> 'a)
      | Prefix of int * ('a -> 'a)
      | Postfix of int * ('a -> 'a)

    (* Predeclared infix operators *)
  let juxOp = Infix ((Lfabsyn.maxPrec+1, Lfabsyn.Left), ExtSyn.app) (* juxtaposition *)
  let arrowOp = Infix ((Lfabsyn.minPrec-1, Lfabsyn.Right), ExtSyn.arrow)
  let backArrowOp = Infix ((Lfabsyn.minPrec-1, Lfabsyn.Left), ExtSyn.backarrow)
  let colonOp = Infix ((Lfabsyn.minPrec-2, Lfabsyn.Left), ExtSyn.hastype)

  let infixOp (infixity, tm) =
          Infix (infixity, (fun (tm1, tm2) -> ExtSyn.app (ExtSyn.app (tm, tm1), tm2)))
  let prefixOp (prec, tm) =
          Prefix (prec, (fun tm1 -> ExtSyn.app (tm, tm1)))
  let postfixOp (prec, tm) =
          Postfix (prec, (fun tm1 -> ExtSyn.app (tm, tm1)))

  let idToTerm args =
    match args with
        (Lexer.Lexer.Lower, ids, name, r) -> ExtSyn.lcid (ids, name, r)
      | (Lexer.Lexer.Upper, ids, name, r) -> ExtSyn.ucid (ids, name, r)
      | (Lexer.Lexer.Quoted, ids, name, r) -> ExtSyn.quid (ids, name, r)

  let isQuoted arg =
    match arg with
        (Lexer.Lexer.Quoted) -> true
      | _ -> false

  type stack = (ExtSyn.term operator) list
  type opr = ExtSyn.term operator

    (* The next section deals generically with fixity parsing          *)
    (* Because of juxtaposition, it is not clear how to turn this      *)
    (* into a separate module without passing a juxtaposition operator *)
    (* into the shift and resolve functions                            *)

    module P :
      (sig
	val reduce : stack -> stack
        val reduceAll : Paths.Paths.region * stack -> ExtSyn.term
        val shiftAtom : ExtSyn.term * stack -> stack
        val shift : Paths.Paths.region * opr * stack -> stack
        val resolve : Paths.Paths.region * opr * stack -> stack
      end) =
    struct
      (* Stack invariants, refinements of operator list *)
      (*
	 <p>       ::= <pStable> | <pRed>
	 <pStable> ::= <pAtom> | <pOp?>
	 <pAtom>   ::= Atom _ :: <pOp?>
	 <pOp?>    ::= nil | <pOp>
	 <pOp>     ::= Infix _ :: <pAtom> :: <pOp?>
		     | Prefix _ :: <pOp?>
	 <pRed>    ::= Postfix _ :: Atom _ :: <pOp?>
		     | Atom _ :: <pOp>
      *)
      (* val reduce : <pRed> -> <p> *)
      let reduce arg =
        match arg with
            (Atom(tm2)::Infix(_,con)::Atom(tm1)::p') -> Atom(con(tm1,tm2))::p'
	  | (Atom(tm)::Prefix(_,con)::p') -> Atom(con(tm))::p'
	  | (Postfix(_,con)::Atom(tm)::p') -> Atom(con(tm))::p'
	(* no other cases should be possible by stack invariant *)

      (* val reduceRec : <pStable> -> ExtSyn.term *)
      let rec reduceRec arg = 
        match arg with
            [Atom(e)] -> e
	  | (p) -> reduceRec (reduce p)

      (* val reduceAll : <p> -> ExtSyn.term *)
      let reduceAll args =
        match args with
            (r, [Atom(e)]) -> e
          | (r, Infix _::p') -> Parsing.Parsing.error (r, "Incomplete infix expression")
  	  | (r, Prefix _::p') -> Parsing.Parsing.error (r, "Incomplete prefix expression")
  	  | (r, []) -> Parsing.Parsing.error (r, "Empty expression")
	  | (r, p) -> reduceRec (reduce p)

      (* val shiftAtom : term * <pStable> -> <p> *)
      (* does not raise Error exception *)
      let shiftAtom (tm,p) =
        match (tm,p) with
            (tm, (Atom _::p')) ->
	      (* insert juxOp operator and reduce *)
	      (* juxtaposition binds most strongly *)
	      reduce (Atom(tm)::juxOp::p)
	  | (tm, p) -> Atom(tm)::p

      (* val shift : Paths.Paths.region * opr * <pStable> -> <p> *)
      let shift args =
        match args with
            (r, ((Atom _) as opr), ((Atom _::p') as p)) ->
	      (* insert juxOp operator and reduce *)
	      (* juxtaposition binds most strongly *)
	      reduce (opr::juxOp::p)
	(* Atom/Infix: shift *)
	(* Atom/Prefix: shift *)
	(* Atom/Postfix cannot arise *)
	(* Atom/Empty: shift *)
	(* Infix/Atom: shift *)
	  | (r, Infix _, Infix _::p') ->
	    Parsing.Parsing.error (r, "Consective infix operators")
	  | (r, Infix _, Prefix _::p') ->
	    Parsing.Parsing.error (r, "Infix operator following prefix operator")
	(* Infix/Postfix cannot arise *)
	  | (r, Infix _, []) ->
	    Parsing.Parsing.error (r, "Leading infix operator")
	  | (r, ((Prefix _) as opr), ((Atom _::p') as p)) ->
	    (* insert juxtaposition operator *)
	    (* will be reduced later *)
	    opr::juxOp::p
	(* Prefix/{Infix,Prefix,Empty}: shift *)
	(* Prefix/Postfix cannot arise *)
	(* Postfix/Atom: shift, reduced immediately *)
	  | (r, Postfix _, Infix _::p') ->
	    Parsing.Parsing.error (r, "Postfix operator following infix operator")
	  | (r, Postfix _, Prefix _::p') ->
	    Parsing.Parsing.error (r, "Postfix operator following prefix operator")
	(* Postfix/Postfix cannot arise *)
	  | (r, Postfix _, []) ->
	    Parsing.Parsing.error (r, "Leading postfix operator")
	  | (r, opr, p) -> opr::p

      (* val resolve : Paths.Paths.region * opr * <pStable> -> <p> *)
      (* Decides, based on precedence of opr compared to the top of the
         stack whether to shift the new operator or reduce the stack
      *)
      let rec resolve (r, opr, p) =
        match (r, opr, p) with
            (r, Infix((prec, assoc), _), (Atom(_)::Infix((prec', assoc'), _)::p')) ->
	      (match (prec-prec', assoc, assoc') with
	           (n,_,_) when n > 0 -> shift(r, opr, p)
	         | (n,_,_) when n < 0 -> resolve (r, opr, reduce(p))
	         | (0, Lfabsyn.Left, Lfabsyn.Left) -> resolve (r, opr, reduce(p))
	         | (0, Lfabsyn.Right, Lfabsyn.Right) -> shift(r, opr, p)
	         | _ -> Parsing.Parsing.error (r, "Ambiguous: infix following infix of identical precedence"))
	  | (r, Infix ((prec, assoc), _), (Atom(_)::Prefix(prec', _)::p')) ->
	      (match prec-prec' with
	           n when n > 0 -> shift(r, opr, p)
	         | n when n < 0 -> resolve (r, opr, reduce(p))
	         | 0 -> Parsing.Parsing.error (r, "Ambiguous: infix following prefix of identical precedence"))
	(* infix/atom/atom cannot arise *)
	(* infix/atom/postfix cannot arise *)
	(* infix/atom/<empty>: shift *)

	(* always shift prefix *)
	  | (r, Prefix _, p) ->
	    shift(r, opr, p)

	(* always reduce postfix, possibly after prior reduction *)
	  | (r, Postfix(prec, _), (Atom _::Prefix(prec', _)::p')) ->
	      (match prec-prec' with
	           n when n > 0 -> reduce (shift (r, opr, p))
	  	 | n when n < 0 -> resolve (r, opr, reduce (p))
		 | 0 -> Parsing.Parsing.error (r, "Ambiguous: postfix following prefix of identical precedence"))
	(* always reduce postfix *)
	  | (r, Postfix(prec, _), (Atom _::Infix((prec', _), _)::p')) ->
	      (match prec - prec' with
	           n when n > 0 -> reduce (shift (r, opr, p))
	         | n when n < 0 -> resolve (r, opr, reduce (p))
                 | 0 -> Parsing.Parsing.error (r, "Ambiguous: postfix following infix of identical precedence"))
	  | (r, Postfix _, [Atom _]) ->
	    reduce (shift (r, opr, p))

	(* default is shift *)
	  | (r, opr, p) ->
	    shift(r, opr, p)

    end  (* structure P *)

  (* parseQualifier' f = (ids, f')
     pre: f begins with Lexer.Lexer.ID
     Note: precondition for recursive call is enforced by the lexer. *)
  let rec parseQualId' (Stream.Stream.Cons ((Lexer.Lexer.ID (_, id) as t, r), s')) =
      (match Stream.Stream.expose s' with
           Stream.Stream.Cons ((Lexer.Lexer.PATHSEP, _), s'') ->
             let ((ids, (t, r)), f') = parseQualId' (Stream.Stream.expose s'') in
             ((id::ids, (t, r)), f')
         | f' -> (([], (t, r)), f'))


  (* val parseExp : (Lexer.Lexer.token * Lexer.Lexer.region) Stream.Stream.stream * <p>
                      -> ExtSyn.term * (Lexer.Lexer.token * Lexer.Lexer.region) Stream.Stream.front *)
  let rec parseExp (s, p) = parseExp' (Stream.Stream.expose s, p)
  and parseExp' (f,p) =
    match (f,p) with
        (Stream.Stream.Cons((Lexer.Lexer.ID _, r0), _), p) ->
          let ((ids, (Lexer.Lexer.ID (idCase, name), r1)), f') = parseQualId' f in
          let r = Paths.Paths.join (r0, r1) in
          let tm = idToTerm (idCase, ids, name, r) in
          (* Currently, we cannot override fixity status of identifiers *)
          (* Thus isQuoted always returns false *)
          if isQuoted (idCase)
          then parseExp' (f', P.shiftAtom (tm, p))
          else parseExp' (f', P.shiftAtom (tm, p))
      | (Stream.Stream.Cons((Lexer.Lexer.UNDERSCORE,r), s), p) ->
          parseExp (s, P.shiftAtom (ExtSyn.omitted r, p))
      | (Stream.Stream.Cons((Lexer.Lexer.TYPE,r), s), p) ->
	  parseExp (s, P.shiftAtom (ExtSyn.typ r, p))
      | (Stream.Stream.Cons((Lexer.Lexer.COLON,r), s), p) ->
	  parseExp (s, P.resolve (r, colonOp, p))
      | (Stream.Stream.Cons((Lexer.Lexer.BACKARROW,r), s), p) ->
	  parseExp (s, P.resolve (r, backArrowOp, p))
      | (Stream.Stream.Cons((Lexer.Lexer.ARROW,r), s), p) ->
          parseExp (s, P.resolve (r, arrowOp, p))
      | (Stream.Stream.Cons((Lexer.Lexer.LPAREN,r), s), p) ->
	  decideRParen (r, parseExp (s, []), p)
      | (Stream.Stream.Cons((Lexer.Lexer.RPAREN,r), s), p) ->
	  (P.reduceAll (r, p), f)
      | (Stream.Stream.Cons((Lexer.Lexer.LBRACE,r), s), p) ->
	  decideRBrace (r, parseDec (s), p)
      | (Stream.Stream.Cons((Lexer.Lexer.RBRACE,r), s), p) ->
          (P.reduceAll (r, p), f)
      | (Stream.Stream.Cons((Lexer.Lexer.LBRACKET,r), s), p) ->
          decideRBracket (r, parseDec (s), p)
      | (Stream.Stream.Cons((Lexer.Lexer.RBRACKET,r), s), p) ->
	  (P.reduceAll (r, p), f)
      | (Stream.Stream.Cons((Lexer.Lexer.DOT,r), s), p) ->
	  (P.reduceAll (r, p), f)
      | (Stream.Stream.Cons((Lexer.Lexer.EOF,r), s), p) ->
	  (P.reduceAll (r, p), f)
      | (Stream.Stream.Cons((t,r), s), p) ->
	  (* possible error recovery: insert DOT *)
	  Parsing.Parsing.error (r, "Unexpected token " ^ Lexer.Lexer.toString t
			    ^ " found in expression")

  and parseDec (s) = parseDec' (Stream.Stream.expose s)
  and parseDec' args =
    match args with
        (Stream.Stream.Cons ((Lexer.Lexer.ID (Lexer.Lexer.Quoted,name), r), s')) ->
          (* cannot happen at present *)
	  Parsing.Parsing.error (r, "Illegal bound quoted identifier " ^ name)
      | (Stream.Stream.Cons ((Lexer.Lexer.ID (idCase,name), r), s')) ->
        (* MKS: we have single file, so nothing would ever be in the table to lookup *)
        parseDec1 (Some(name), Stream.Stream.expose s')
      | (Stream.Stream.Cons ((Lexer.Lexer.UNDERSCORE, r), s')) ->
          parseDec1 (None, Stream.Stream.expose s')
      | (Stream.Stream.Cons ((Lexer.Lexer.EOF, r), s')) ->
	  Parsing.Parsing.error (r, "Unexpected end of stream in declaration")
      | (Stream.Stream.Cons ((t, r), s')) ->
	  Parsing.Parsing.error (r, "Expected variable name, found token " ^ Lexer.Lexer.toString t)

  and parseDec1 args =
    match args with
        (x, Stream.Stream.Cons((Lexer.Lexer.COLON, r), s')) ->
          let (tm, f'') = parseExp (s', []) in
          ((x, Some tm), f'') 
      | (x, (Stream.Stream.Cons((Lexer.Lexer.RBRACE, _), _) as f)) ->
          ((x, None), f)
      | (x, (Stream.Stream.Cons ((Lexer.Lexer.RBRACKET, _), _) as f)) ->
          ((x, None), f)
      | (x, Stream.Stream.Cons ((t,r), s')) ->
	  Parsing.Parsing.error (r, "Expected optional type declaration, found token "
			    ^ Lexer.Lexer.toString t)

  and decideRParen args =
    match args with
        (r0, (tm, Stream.Stream.Cons((Lexer.Lexer.RPAREN,r), s)), p) ->
          parseExp (s, P.shiftAtom(tm,p))
      | (r0, (tm, Stream.Stream.Cons((_, r), s)), p) ->
	  Parsing.Parsing.error (Paths.Paths.join(r0, r), "Unmatched open parenthesis")

  and decideRBrace args =
    match args with
        (r0, ((x, yOpt), Stream.Stream.Cons ((Lexer.Lexer.RBRACE,r), s)), p) ->
          let dec = (match yOpt with
                         None -> ExtSyn.dec0 (x, Paths.Paths.join (r0, r))
                       | Some y -> ExtSyn.dec (x, y, Paths.Paths.join (r0, r))) in
	  let (tm, f') = parseExp (s, []) in
	  parseExp' (f', P.shiftAtom (ExtSyn.pi (dec, tm), p))
      | (r0, (_, Stream.Stream.Cons ((_, r), s)), p) ->
	  Parsing.Parsing.error (Paths.Paths.join(r0, r), "Unmatched open brace")

  and decideRBracket args =
    match args with
        (r0, ((x, yOpt), Stream.Stream.Cons ((Lexer.Lexer.RBRACKET,r), s)), p) ->
          let dec = (match yOpt with
                         None -> ExtSyn.dec0 (x, Paths.Paths.join (r0, r))
                       | Some y -> ExtSyn.dec (x, y, Paths.Paths.join (r0, r))) in
	  let(tm, f') = parseExp (s, []) in
	  parseExp' (f', P.shiftAtom (ExtSyn.lam (dec, tm), p))
      | (r0, (dec, Stream.Stream.Cons ((_, r), s)), p) ->
	  Parsing.Parsing.error (Paths.Paths.join(r0, r), "Unmatched open bracket")



  let parseTerm' = (fun f -> parseExp' (f, []))

end  (* functor ParseTerm *)
