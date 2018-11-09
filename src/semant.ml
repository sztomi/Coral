open Ast
open Sast


(* 

2. Check types of assignments (x : str[] = 5)
3. Make sure all variables and functions have been declared (includes getting a list of locals in each scope, somehow handle closures)
4. Duplicate names in function formals
5. Do full type inference
6. Do microC style semantic checking on the sections I can fully infer

sstmt:
  | SFunc of sfunc_decl
  | SBlock of stmt list 
  | SExpr of expr
  | SIf of expr * stmt * stmt
  | SFor of bind * expr * stmt
  | SWhile of expr * stmt
  | SReturn of expr
  | SClass of string * stmt
  | SAsn of bind list * expr

*)

(* 

could have a declared and maybedeclared list, as well as definitely typed and possibly typed. also need to have an explicitly typed list. expressions get translated into SAST versions if
all arguments and 

x = 3

if (condition):
	x : int = x

x = "hello"

have a second map of functions containing function statement/args and a map from args to typed sfunc for that type args.
need a map from list/tuple to sstmt. when called, go into it, check all the types/args with current values. need to attach
closure. 
*)


let stmt_to_string = function
  | Func(_, _, _) -> "func"
  | Block(_) -> "block"
  | Expr(_) -> "expr"
  | If(_, _, _) -> "if"
  | For(_, _, _) -> "for"
  | While(_, _) -> "while"
  | Return(_) -> "return"
  | Class(_, _) -> "class"
  | Asn(_, _) -> "asn"
  | TypeInfo(_) -> "typeinfo"
  | Nop -> "nop"

let expr_to_string = function
  | Binop(_, _, _) -> "binop"
  | Lit(_) -> "lit"
  | Var(_) -> "var"
  | Unop(_, _) -> "unop"
  | Call(_, _) -> "call"
  | Method(_, _, _) -> "method"
  | Field(_, _) -> "field"
  | List(_) -> "list"

let type_to_string = function
  | Dyn -> "dyn"
  | Int -> "int"
  | Float -> "float"
  | Bool -> "bool"
  | String -> "string"
  | IntArr -> "int list"
  | FloatArr -> "float list"
  | BoolArr -> "bool list"
  | StringArr -> "string list"
  | FuncType -> "func"
  | Null -> "null"

let unop_to_string = function
  | Neg -> "-"
  | Not -> "not"

let binop_to_string = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Exp -> "**"
  | Eq -> "=="
  | Neq -> "!="
  | Less -> "<"
  | Leq -> "<="
  | Greater -> ">"
  | Geq -> ">="
  | And -> "and"
  | Or -> "or"

let type_to_array = function
  | Int -> IntArr
  | Bool -> BoolArr
  | String -> StringArr
  | Float -> FloatArr
  | Dyn -> Dyn
  | _ as x -> x

let comp x y =  match List.length x, List.length y with
  | a, b when a < b -> -1
  | a, b when a > b -> 1
  | a, b when a = b -> let rec aux = function
    | [], [] -> 0
    | x :: t, y :: q when x = y -> aux (t, q)
    | x :: t, y :: q when x <> y -> compare x y
    | _ -> raise (Failure "unknown failure in argument matching")
  in aux (x, y)
  | _ -> raise (Failure "unknown failure in argument matching")
;;

module TypeMap = Map.Make(struct type t = typ list let compare = comp end);;

module StringMap = Map.Make(String)

let compare_types a b = if a = b then a else Dyn
let compare_decl a b = if a = b then a else false

let merge m1 m2 = StringMap.merge (fun key v1 v2 -> match v1, v2 with (* merge two lists while keeping type inference intact *)
    | Some (a, b, c, d), Some (e, f, g, h) -> Some (compare_types a e, compare_types b f, compare_decl c g, None)
    | Some (a, b, c, d), None -> Some(a, b, false, d)
    | None, Some(a, b, c, d) -> Some(a, b, false, d)
    | None, None -> None
  ) m1 m2

let equals m1 m2 = (StringMap.equal (fun x y -> (compare x y) = 0) m1 m2) (* check if two maps are equal *)

let rec expr map = function (* evaluate expressions, return types and add to map *)
  | Lit(x) -> let typ = match x with | IntLit(x) -> Int | BoolLit(x) -> Bool | StringLit(x) -> String | FloatLit(x) -> Float in (typ, SLit(x)) (* convert lit to type, return (type, SLit(x)), check if defined in map *)
  | List(x) -> let rec aux typ out = function
    		| [] -> (type_to_array typ, SList(List.rev out, type_to_array typ))
  			| a :: rest -> let (t, e) = expr map a in if t = typ then aux typ (e :: out) rest else aux Dyn (e :: out) rest
  	      in (match x with
  	        | a :: rest -> let (t, e) = expr map a in aux t [e] rest
  	        | [] -> (Dyn, SList([], Dyn)) (* todo maybe do something with this special case *))
  | Var(Bind(x, t)) -> if StringMap.mem x map then (let (typ, t', decl, _) = StringMap.find x map in if decl then (t', SVar(StrongBind(x, t'))) else (t', SVar(WeakBind(x, t')))) else raise (Failure ("SNameError: name '" ^ x ^ "' is not defined"))
  | Unop(op, e) -> let (typ, e') = expr map e in (match typ with
      | Dyn -> (Dyn, SUnop(op, e'))
      | _ -> (match op with
        | Neg when typ = Int || typ = Float || typ = Bool -> (typ, SUnop(op, e'))
        | Not -> (typ, SUnop(op, e'))
        | _ -> raise (Failure ("STypeError: bad operand type for unary " ^ unop_to_string op ^ ": '" ^ type_to_string typ ^ "'"))
      ))

  | Binop(a, op, b) -> let (t1, e1) = expr map a in let (t2, e2) = expr map b in (match (t1, t2) with
    | (Dyn, Dyn) | (Dyn, _) | (_, Dyn) -> (Dyn, SBinop(e1, op, e2))
    | _ -> let same = t1 = t2 in (match op with
      | Add | Sub | Mul | Exp when same && t1 = Int   -> (Int, SBinop(e1, op, e2))
      | Add | Sub | Mul | Div | Exp when same && t1 = Float -> (Float, SBinop(e1, op, e2))
      | Add | Sub | Mul | Div | Exp when same && t1 = Bool -> (Bool, SBinop(e1, op, e2))
      | Add when same && t1 = String -> (String, SBinop(e1, op, e2))
      | Sub | Mul | Div | Exp when t1 = String || t2 = String -> raise (Failure ("STypeError: unsupported operand type(s)"))

      | Add | Sub | Mul | Div | Exp when t1 = Int || t1 = Float || t1 = Bool && t2 = Int || t2 = Float || t2 = Bool -> (Float, SBinop(e1, op, e2))

      | Eq | Neq | Less | Leq | Greater | Geq -> (Bool, SBinop(e1, op, e2)) (* will have to fix later for strings *)
      | And | Or when same && t1 = Bool -> (Bool, SBinop(e1, op, e2))
  	  | _ -> raise (Failure ("STypeError: unsupported operand type(s)"))
  	)) (* will have to fix this later *)
  | Call(name, exprs) -> if not (StringMap.mem name map) then raise (Failure ("SNameError: function not found.")) else
      let (typ, t', decl, func) = StringMap.find name map in if func = None then raise (Failure ("SNameError: function not found."))
      else let Some(Func(n, args, c)) = func in
      if t' != FuncType && typ != Dyn then (raise (Failure ("STypeError: cannot call variable"))) else
      
      let param_length = List.length exprs in
      if List.length args != param_length then
            raise (Failure ("SyntaxError: unexpected number of arguments in function call"))

      else let rec aux (map, bindout, exprout) v1 v2 = match v1, v2 with
        | b, e -> let (t', e') = expr map e in let (map1, bind2) = check_assign map t' b in (map1, (bind2 :: bindout), (e' :: exprout))

      in let (map1, bindout, exprout) = (List.fold_left2 aux (map, [], []) args exprs) in 
      let (map2, block, typ2) = (func_stmt map1 c) in (* p, q, r is sstmt list, typ, map *)
      let Bind(name, btype) = n in if btype <> Dyn && btype <> typ2 then raise (Failure ("STypeError: invalid return type")) else 
      let func = (SFunc(StrongBind(name, typ2), (List.rev bindout), block)) in (typ2, (SCall(StrongBind(name, typ2), (List.rev exprout), func))) (* TODO fix this somehow *)

  | _ as temp -> print_endline ("NotImplementedError: '" ^ (expr_to_string temp) ^ "' semantic checking not implemented"); (Dyn, SNoexpr)

and check_assign map typ = function (* check if a value can be assigned, and assign if true *)
  | Bind(n, t) when StringMap.mem n map -> let (t', _, decl, _) = StringMap.find n map in 
  			(match typ with
  		  	| Dyn -> (match t with 
  		  		  | IntArr | BoolArr | FloatArr | StringArr -> raise (Failure ("STypeError: invalid array types"))
  		  		  | _ -> let map' = StringMap.add n (t', Dyn, true, None) map in (map', StrongBind(n, Dyn))) (* fix all this *)
  		 	| _ -> (match t' with
  		 	 	  | Dyn -> (match t with 
  			  	      | Dyn -> let map' = StringMap.add n (Dyn, typ, true, None) map in (map', StrongBind(n, Dyn))
  			  	      | _ when t = typ -> let m' = StringMap.add n (t, t, true, None) map in (m', StrongBind(n, t))
  			  	      | _ -> raise (Failure ("STypeError: invalid type assigned to " ^ n)))
  			  	  | _ -> (match t with
  			  	  	  | Dyn when t' = typ -> (map, StrongBind(n, Dyn))
  			  	  	  | _ when t = typ -> let m' = StringMap.add n (t, t, true, None) map in (m', StrongBind(n, t))
  			  	  	  | _ -> raise (Failure ("STypeError: invalid type assigned to " ^ n)))
  			  	  | _ -> raise (Failure ("STypeError: invalid type assigned to " ^ n))))
  | Bind(n, t) when not (StringMap.mem n map) -> if t = typ then let m' = StringMap.add n (t, t, true, None) map in (m', StrongBind(n, t))
	  		else if t = Dyn then let m' = StringMap.add n (Dyn, typ, true, None) map in (m', StrongBind(n, t))
	  		else raise (Failure ("STypeError: invalid type assigned to " ^ n))
  | _ -> raise (Failure ("STypeError: invalid types for assignment."))

and check_array map e b = let (typ, e') = expr map e in match typ with (* make sure an array type can be assigned to a given variable *)
  | IntArr -> check_assign map Int b
  | FloatArr -> check_assign map Float b
  | BoolArr -> check_assign map Bool b
  | StringArr -> check_assign map String b
  | Dyn -> let Bind(n, t) = b in let map' = StringMap.add n (t, t, false, None) map in (map, WeakBind(n, t))
  | _ -> raise (Failure ("STypeError: invalid types for assignment."))

and check_func map out typ = (function  (* check the entire program *)
  | [] -> ((List.rev out), typ, map)
  | a :: t when typ <> Null -> ((List.rev out), typ, map)
  | a :: t -> let (m', value, typ) = func_stmt map a in check_func m' (value :: out) typ t)

and func_stmt map = function (* used to evaluate functions and handle return types. will be used to handle closures too *)
  | Return(e) -> let (t, e') = expr map e in (map, SReturn(e'), t) (* for closures, match t with FuncType, attach local scope *)
  | Block(s) -> let (value, typ, map') = check_func map [] Null s in (map', SBlock(value), typ)
  | Asn(binds, e) -> let (typ, e') = expr map e in let rec aux (m, out) = function
      | [] -> (m, List.rev out)
      | a :: t -> let (m, x) = check_assign map typ a in aux (m, x :: out) t in
    let (m, out) = aux (map, []) binds in (m, SAsn(out, e'), Null)
  | Expr(e) -> let (t, e') = expr map e in (map, SExpr(e'), Null)
  | Func(a, b, c) -> let rec dups = function (* check duplicate argument names *)
      | [] -> ()
      | (Bind(n1, _) :: Bind(n2, _) :: _) when n1 = n2 -> raise (Failure ("SyntaxError: duplicate argument '" ^ n1 ^ "' in function definition"))
      | _ :: t -> dups t
    in let _ = dups (List.sort (fun (Bind(a, _)) (Bind(b, _)) -> compare a b) b) in let Bind(x, t) = a in let map' = StringMap.add x (FuncType, FuncType, true, Some(Func(a, b, c))) map in (map', SFuncDecl(a, b, c), Null)

  | If(a, b, c) -> let (typ, e') = expr map a in let (map', value, t1) = func_stmt map b in let (map'', value', t2) = func_stmt map c in if equals map' map'' then if t1 = t2 then (map', SIf(e', value, value'), t1) else (map', SIf(e', value, value'), Dyn) else 
         let merged = merge map' map'' in if t1 = t2 then (merged, SIf(e', value, value'), t1) else (merged, SIf(e', value, value'), Dyn)

  | For(a, b, c) -> let (m, x) = check_array map b a in let (m', x', t1) = func_stmt m c in let (typ, e') = expr m' b in if equals map m' then (m', SFor(x, e', x'), t1) else 
        let merged = merge m m' in (merged, SFor(x, e', x'), Dyn)

  | While(a, b) -> let (_, e) = expr map a in let (m', x', t1) = func_stmt map b in if equals map m' then (m', SWhile(e, x'), Dyn) else
    let merged = merge map m' in (merged, SWhile(e, x'), Dyn)
  
  | Nop -> (map, SNop, Null)
  | TypeInfo(a) -> let (t, e) = expr map a in print_endline (type_to_string t); (map, SNop, Null)
  | _ as s -> let (map', value) = stmt map s in (map', value, Null)

and stmt map = function (* evaluates statements, can pass it a func *)
  | Asn(binds, e) -> let (typ, e') = expr map e in let rec aux (m, out) = function
      | [] -> (m, List.rev out)
      | a :: t -> let (m, x) = check_assign map typ a in aux (m, x :: out) t in
    let (m, out) = aux (map, []) binds in (m, SAsn(out, e'))
  | Expr(e) -> let (t, e') = expr map e in (map, SExpr(e'))
  | Block(s) -> let (value, map') = check map [] s in (map', SBlock(value))
  | Return(e) -> raise (Failure ("SyntaxError: return statement outside of function"))
  | Func(a, b, c) -> let rec dups = function (* check duplicate argument names *)
      | [] -> ()
      | (Bind(n1, _) :: Bind(n2, _) :: _) when n1 = n2 -> raise (Failure ("SyntaxError: duplicate argument '" ^ n1 ^ "' in function definition"))
      | _ :: t -> dups t
    in let _ = dups (List.sort (fun (Bind(a, _)) (Bind(b, _)) -> compare a b) b) in let Bind(x, t) = a in let map' = StringMap.add x (FuncType, FuncType, true, Some(Func(a, b, c))) map in (map', SFuncDecl(a, b, c))

  | If(a, b, c) -> let (typ, e') = expr map a in let (map', value) = stmt map b in let (map'', value') = stmt map c in if equals map' map'' then (map', SIf(e', value, value')) else 
         let merged = merge map' map'' in (merged, SIf(e', value, value'))

  | For(a, b, c) -> let (m, x) = check_array map b a in let (m', x') = stmt m c in let (typ, e') = expr m' b in if equals map m' then (m', SFor(x, e', x')) else 
        let merged = merge m m' in (merged, SFor(x, e', x'))

  | While(a, b) -> let (_, e) = expr map a in let (m', x') = stmt map b in if equals map m' then (m', SWhile(e, x')) else
    let merged = merge map m' in (merged, SWhile(e, x'))
  
  | Nop -> (map, SNop)
  | TypeInfo(a) -> let (t, e) = expr map a in print_endline (type_to_string t); (map, SNop)
  | _ as temp -> print_endline ("NotImplementedError: '" ^ (stmt_to_string temp) ^ "' semantic checking not implemented"); (map, SNop)

and check map out = function  (* check the entire program *)
  | [] -> (List.rev out, map)
  | a :: t -> let (m', value) = stmt map a in check m' (value :: out) t

;;






