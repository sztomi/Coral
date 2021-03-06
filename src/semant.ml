open Ast
open Sast
open Utilities

(* Semant takes an Abstract Syntax Tree and returns a Syntactically Checked AST with partial type inferrence,
syntax checking, and other features. expr objects are converted to sexpr, and stmt objects are converted
to sstmts. *)

(* binop: evaluate types of two binary operations and check if the binary operation is valid.
This currently is quite restrictive and does not permit automatic type casting like in Python.
This may be changed in the future. The commented-out line would allow that feature *)

let binop t1 t2 op = 
  let except = (Failure ("STypeError: unsupported operand type(s) for binary " ^ binop_to_string op ^ ": '" ^ type_to_string t1 ^ "' and '" ^ type_to_string t2 ^ "'")) in
  match (t1, t2) with
  | (Dyn, Dyn) | (Dyn, _) | (_, Dyn) -> Dyn
  | _ -> let same = t1 = t2 in (match op with
    | Add | Sub | Mul | Exp when same && t1 = Int -> Int
    | Add | Sub | Mul | Div | Exp when same && t1 = Float -> Float
    | Add | Sub | Mul | Div | Exp when same && t1 = Bool -> Bool
    | Add when same && t1 = String -> String
    (* | Add | Sub | Mul | Div | Exp when t1 = Int || t1 = FloatArr || t1 = Bool && t2 = Int || t2 = Float || t2 = Bool -> Float *)
    | Less | Leq | Greater | Geq when not same && t1 = String || t2 = String -> raise except
    | Eq | Neq | Less | Leq | Greater | Geq | And | Or when same -> Bool
    | And | Or when same && t1 = Bool -> Bool
    | Mul when is_arr t1 && t2 = Int -> t1
    | Mul when is_arr t2 && t1 = Int -> t2
    | Mul when t1 = String && t2 = Int -> String
    | Mul when t2 = String && t1 = Int -> String
    | Add when same && is_arr t1 -> t1
    | Div when same && t1 = Int -> Int
    | Add | Sub | Mul | Div | Exp when (t1 = Bool && t2 = Int) || (t2 = Bool && t1 = Int) -> Int
    | _ -> raise except
  )

(* unop: evalues the type of a unary operation to check if it is valid. Currently is less restrictive
than binop and this may need to be modified depending on how codegen is implemented. *)

let unop t1 op = match t1 with
  | Dyn -> Dyn
  | _ -> (match op with
    | Neg when t1 = Int || t1 = Float || t1 = Bool -> t1
    | Not -> t1
    | _ -> raise (Failure ("STypeError: unsupported operand type for unary " ^ unop_to_string op ^ ": '" ^ type_to_string t1 ^ "'"))
  )

(* convert: takes the triple tuple returned by exp (type, expression, data) and converts
it to (type, sexpr, data) *)

let convert (t, e, d) = (t, (e, t), d)

(* expr: syntactically check an expression, returning its type, the sexp object, and any relevant data *)
let rec expr map x = convert (exp map x)

(* exp: evaluate expressions, return their types, a partial sast, and any relevant data *)

and exp map = function 
  | Lit(x) -> 
    let typ = match x with 
      | IntLit(x) -> Int 
      | BoolLit(x) -> Bool 
      | StringLit(x) -> String
      | FloatLit(x) -> Float
    in (typ, SLit(x), None) (* convert lit to type, return (type, SLit(x)), check if defined in map *)
  
  | List(x) -> (* parse Lists to determine if they have uniform type, evaluate each expression separately *)
    let rec aux typ out = function
      | [] -> (Arr, SList(List.rev out, Arr), None) (* replace Dyn with type_to_array typ to allow type inference on lists *)
      | a :: rest -> 
        let (t, e, _) = expr map a in 
        if t = typ then aux typ (e :: out) rest 
        else aux Dyn (e :: out) rest in 
      (match x with
        | a :: rest -> let (t, e, _) = expr map a in aux t [e] rest
        | [] -> (Dyn, SList([], Dyn), None) (* TODO: maybe do something with this special case of empty list *)
      ) 

  | ListAccess(e, x) -> (* parse List access to determine the LHS is a list and the RHS is an int if possible *)
    let (t1, e1, _) = expr map e in
    let (t2, e2, _) = expr map x in
    if t1 <> Dyn && not (is_arr t1) || t2 <> Int && t2 <> Dyn 
      then raise (Failure (Printf.sprintf "STypeError: invalid types (%s, %s) for list access" (type_to_string t1) (type_to_string t2)))
    else (Dyn, SListAccess(e1, e2), None)

  | ListSlice(e, x1, x2) -> raise (Failure "SNotImplementedError: List Slicing has not been implemented")

    (* let (t1, e1, _) = expr map e in
    let (t2, e2, _) = expr map x1 in
    let (t3, e3, _) = expr map x2 in
    if t1 <> Dyn && not (is_arr t1) || t2 <> Int && t2 <> Dyn || t3 <> Int && t3 <> Dyn 
      then raise (Failure ("STypeError: invalid types for list slice"))
    else (Dyn, SListSlice(e1, e2, e3), None) *)

  | Var(Bind(x, t)) -> (* parse Variables, throwing an error if they are not found in the global lookup table *)
    if StringMap.mem x map then 
    let (t', typ, data) = StringMap.find x map in 
    (typ, SVar(x), data)
    else raise (Failure ("SNameError: name '" ^ x ^ "' is not defined"))
  
  | Unop(op, e) -> (* parse Unops, making sure the argument and ops have valid type combinations *)
    let (t1, e', _) = expr map e in
    let t2 = unop t1 op in (t2, SUnop(op, e'), None)

  | Binop(a, op, b) -> (* parse Binops, making sure the two arguments and ops have valid type combinations *)
    let (t1, e1, _) = expr map a in 
    let (t2, e2, _) = expr map b in 
    let t3 = binop t1 t2 op in (t3, SBinop(e1, op, e2), None)

  | Call(exp, args) -> (* parse Call, checking that the LHS is a function, matching arguments and types, evaluating the body *)
    let (t, e, data) = expr map exp in
    if t <> Dyn && t <> FuncType (* if it's known not to be a function, throw an error *)
      then raise (Failure ("STypeError: cannot call objects of type " ^ type_to_string t)) 
    else (match data with 
      | Some(x) -> 
        (match x with 
          | Func(name, formals, body) -> (* if evaluating the expression returns a function *)
            let param_length = List.length args in
            if List.length formals <> param_length 
            then raise (Failure (Printf.sprintf "SSyntaxError: unexpected number of arguments in function call (expected %d but found %d)" (List.length formals) param_length))

            else let rec handle_args (globals, locals, bindout, exprout) bind exp = 
                let data = expr globals exp in 
                let (t', e', _) = data in 
                let (locals, name, inferred_t, explicit_t) = assign locals data bind in 
                (globals, locals, ((Bind(name, explicit_t)) :: bindout), (e' :: exprout))
            
            in 
            
            let clear_explicit_types map = StringMap.map (fun (a, b, c) -> (Dyn, b, c)) map in (* ignore dynamic types when not in same scope *)

            let fn_namespace = clear_explicit_types map in (* we use this map to allow us to overwrite explicit global types *)
            let (_, fn_namespace, bindout, exprout) = (List.fold_left2 handle_args (map, fn_namespace, [], []) formals args) in

            let (_, types) = split_sbind bindout in
            let stack = TypeMap.empty in (* start call stack - used to avoid infinite recursion *)
            let stack' = TypeMap.add (x, types) true stack in

            let (map2, block, data, locals) = (func_stmt map fn_namespace {stack = stack'; cond = false; forloop = false; noeval = false; } body) in

            (match data with (* match return type with *)
              | Some (typ2, e', d) -> (* it did return something *)
                  let Bind(n1, btype) = name in 
                  if btype <> Dyn && btype <> typ2 then if typ2 <> Dyn 
                  then raise (Failure (Printf.sprintf "STypeError: invalid return type (expected %s but found %s)" (string_of_typ btype) (string_of_typ typ2))) 
                  else let func = { styp = btype; sfname = n1; sformals = (List.rev bindout); slocals = locals; sbody = block } in 
                    (btype, (SCall(e, (List.rev exprout), SFunc(func))), d) 
                  else let func = { styp = typ2; sfname = n1; sformals = (List.rev bindout); slocals = locals; sbody = block } in (* case where definite return type and Dynamic inferrence still has  bind*)
                  (typ2, (SCall(e, (List.rev exprout), SFunc(func))), d)
              
              | None -> (* function didn't return anything, null function *)
                  let Bind(n1, btype) = name in if btype <> Dyn then
                  raise (Failure (Printf.sprintf "STypeError: invalid return type (expected %s but found None)" (string_of_typ btype))) else
                  let func = { styp = Null; sfname = n1; sformals = (List.rev bindout); slocals = locals; sbody = block } in
                  (Null, (SCall(e, (List.rev exprout), SFunc(func))), None))
          
          | _ -> raise (Failure ("SCriticalFailure: unexpected type encountered internally in Call evaluation"))) (* can be expanded to allow classes in the future *)
      
      | None -> (* Printf.eprintf "%s\n" "SWarning: called unknown/undefined function"; (* TODO probably not necessary, may be a problem for recursion *) *)
          let eout = List.rev (List.fold_left (fun acc e' -> let (_, e', _) = expr map e' in e' :: acc) [] args) in
          let transforms = make_transforms (globals_to_list map) in (* make_transforms transforms all current globals to dynamics and back for unknown/undefined functions *)
          (Dyn, (SCall(e, eout, transforms)), None)
        )

  | _ as temp -> print_endline ("SNotImplementedError: '" ^ (expr_to_string temp) ^ 
      "' semantic checking not implemented"); (Dyn, SNoexpr, None)

(* func_expr: checks expressions within functions. differs from expr in how it handles function calls *)

and func_expr globals locals the_state x = convert (func_exp globals locals the_state x)

and func_exp globals locals the_state = function (* evaluate expressions, return types and add to map *)
  | Unop(op, e) -> 
    let (t1, e', _) = func_expr globals locals the_state e in 
    let t2 = unop t1 op in (t2, SUnop(op, e'), None)

  | Binop(a, op, b) -> 
    let (t1, e1, _) = func_expr globals locals the_state a in 
    let (t2, e2, _) = func_expr globals locals the_state b in 
    let t3 = binop t1 t2 op in (t3, SBinop(e1, op, e2), None)

  (* if a variable is not found and we are evaluating a Func, 
  add it to the list of possible globals. this causes a dynamic
  version of it to be created so that it can be used even if that
  variable is never defined *)
  | Var(Bind(x, t)) -> (* Printf.printf "[%b %b %s]\n" the_state.noeval the_state.cond x; *)
    if StringMap.mem x locals then
      if (StringMap.mem x globals) && the_state.noeval then (Dyn, SVar(x), None)
      else let (typ, t', data) = StringMap.find x locals in (t', SVar(x), data)
    else if the_state.noeval then 
      let () = possible_globals := (Bind(x, Dyn)) :: !possible_globals in (Dyn, SVar(x), None) 
    else raise (Failure ("SNameError: name '" ^ x ^ "' is not defined"))

  | ListAccess(e, x) ->
    let (t1, e1, _) = func_expr globals locals the_state e in
    let (t2, e2, _) = func_expr globals locals the_state x in
    if t1 <> Dyn && not (is_arr t1) || t2 <> Int && t2 <> Dyn 
      then raise (Failure (Printf.sprintf "STypeError: invalid types (%s, %s) for list access" (type_to_string t1) (type_to_string t2)))
    else (Dyn, SListAccess(e1, e2), None)

  | ListSlice(e, x1, x2) -> raise (Failure "SNotImplementedError: List Slicing has not been implemented")
    (* let (t1, e1, _) = func_expr globals locals the_state e in
    let (t2, e2, _) = func_expr globals locals the_state x1 in
    let (t3, e3, _) = func_expr globals locals the_state x2 in
    if t1 <> Dyn && not (is_arr t1) || t2 <> Int && t2 <> Dyn || t3 <> Int && t3 <> Dyn 
      then raise (Failure ("STypeError: invalid types for list access"))
    else (Dyn, SListSlice(e1, e2, e3), None) *)

  | Call(exp, args) ->
    let (t, e, data) = func_expr globals locals the_state exp in 
    if t <> Dyn && t <> FuncType then raise (Failure ("STypeError: cannot call objects of type " ^ type_to_string t)) else
    let transforms = make_transforms (globals_to_list globals) in

    (match data with (* data is either the Func info *)
      | Some(x) -> 
        (match x with 
          | Func(name, formals, body) -> 
            let param_length = List.length args in
            if List.length formals <> param_length 
            then raise (Failure (Printf.sprintf "SSyntaxError: unexpected number of arguments in function call (expected %d but found %d)" (List.length formals) param_length))

            else let handle_args (globals, locals, bindout, exprout) bind exp = 
              let data = func_expr globals locals the_state exp in 
              let (t', e', _) = data in 
              let (map', name, inferred_t, explicit_t) = assign globals data bind in 
              (map', locals, ((Bind(name, explicit_t)) :: bindout), (e' :: exprout)) in

            let clear_explicit_types map = StringMap.map (fun (a, b, c) -> (Dyn, b, c)) map in (* ignore dynamic types when not in same scope *)

            let fn_namespace = clear_explicit_types locals in
            let (fn_namespace, _, bindout, exprout) = (List.fold_left2 handle_args (globals, fn_namespace, [], []) formals args) in
            let (fn_namespace, _, _, _) = assign fn_namespace (Dyn, (SCall (e, (List.rev exprout), transforms), Dyn), data) name in (* add the function itself to the namespace *)

            let (_, types) = split_sbind bindout in (* avoid recursive calls by checking if the type has already been called. *)
            if TypeMap.mem (x, types) the_state.stack then let () = debug "recursive callstack return" in (Dyn, SCall(e, (List.rev exprout), transforms), None) (* if recursive, return a dynamic function *)
            else let stack' = TypeMap.add (x, types) true the_state.stack in (* otherwise add it to the stack *)

            let (map2, block, data, locals) = (func_stmt globals fn_namespace { the_state with cond = false; forloop = false; stack = stack'; } body) in
            (match data with
              | Some (typ2, e', d) -> let Bind(n1, btype) = name in if btype <> Dyn && btype <> typ2 then 
                  if typ2 <> Dyn then raise (Failure (Printf.sprintf "STypeError: invalid return type (expected %s but found %s)" (string_of_typ btype) (string_of_typ typ2)))
                  else let func = { styp = btype; sfname = n1; sformals = (List.rev bindout); slocals = locals; sbody = block } in
                  (btype, (SCall(e, (List.rev exprout), SFunc(func))), d) else (* case where definite return type and Dynamic inferrence still has  bind*)
                  let func = { styp = typ2; sfname = n1; sformals = (List.rev bindout); slocals = locals; sbody = block } in
                  (typ2, (SCall(e, (List.rev exprout), SFunc(func))), d) (* TODO fix this somehow *)
              
              | None -> let Bind(n1, btype) = name in if btype <> Dyn 
                then raise (Failure (Printf.sprintf "STypeError: invalid return type (expected %s but found None)" (string_of_typ btype))) 
                else let func = { styp = Null; sfname = n1; sformals = (List.rev bindout); slocals = locals; sbody = block } in 
                (Null, (SCall(e, (List.rev exprout), SFunc(func))), None)) (* TODO fix this somehow *)
          
          | _ -> raise (Failure ("SCriticalFailure: unexpected type encountered internally in Call evaluation")))
      
      | None -> (* if not the_state.noeval then Printf.eprintf "%s\n" "SWarning: called unknown/undefined function"; *)
          let eout = List.rev (List.fold_left (fun acc e' -> let (_, e'', _) = func_expr globals locals the_state e' in e'' :: acc) [] args) in
          (Dyn, (SCall(e, eout, transforms)), None)
        )

    | _ as other -> exp locals other


(* assign: function to check if a certain assignment can be performed with inferred/given types, 
does assignment if possible, and returns the name, the infered type, and the explicit type to be checked.

the return type is:

(new map, type needed for locals list, type needed for runtime-checking)

The second bind will generally be dynamic, except when type inferred cannot determine if the
operation is valid and runtime checks must be inserted.

typ is type inferred type of data being assigned. t' is the explicit type previously assigned to the
variable being assigned to. t is the type (optionally) bound to the variable in this assignment.

*)

and assign map data bind =
  let (typ, _, data) = data in  
  let Bind(n, t) = bind in
  if StringMap.mem n map then
  let (t', _, _) = StringMap.find n map in 
    (match typ with
      | Dyn -> (match (t', t) with (* todo deal with the Bind thing *)
        | (Dyn, Dyn) -> let map' = StringMap.add n (Dyn, Dyn, data) map in (map', n, Dyn, Dyn) (*  *)
        | (Dyn, _) -> let map' = StringMap.add n (t, t, data) map in (map', n, t, t) (*  *)
        | (_, Dyn) -> let map' = StringMap.add n (t', t', data) map in (map', n, t', t') (*  *)
        | (_, _) -> let map' = StringMap.add n (t, t, data) map in (map', n, t, t))  (*  *)
      | _ -> (match t' with
        | Dyn -> (match t with 
          | Dyn -> let map' = StringMap.add n (Dyn, typ, data) map in (map', n, typ, Dyn) (*  *)
          | _ when t = typ -> let m' = StringMap.add n (t, t, data) map in (m', n, t, Dyn) (*  *)
          | _ -> raise (Failure (Printf.sprintf "STypeError: expression of type %s cannot be assigned to variable '%s' with explicit type %s" (string_of_typ typ) n (string_of_typ t))))
        | _ -> (match t with
          | Dyn when t' = typ -> let m' = StringMap.add n (t', typ, data) map in (m', n, t', Dyn) (*  *)
          | _ when t = typ -> let m' = StringMap.add n (t, t, data) map in (m', n, t, Dyn) (*  *)
          | _ -> raise (Failure (Printf.sprintf "STypeError: expression of type %s cannot be assigned to variable '%s' with explicit type %s" (string_of_typ typ) n (string_of_typ t'))))))
  else if t = typ 
  then let m' = StringMap.add n (t, t, data) map in (m', n, t, Dyn) (*  *)
  else if t = Dyn then let m' = StringMap.add n (Dyn, typ, data) map in (m', n, typ, Dyn) (*  *)
  else if typ = Dyn then let m' = StringMap.add n (t, t, data) map in (m', n, t, t) (*  *)
  else raise (Failure (Printf.sprintf "STypeError: expression of type %s cannot be assigned to variable '%s' with explicit type %s" (string_of_typ typ) n (string_of_typ t)))


(* makes sure an array type can be assigned to a given variable. used for for loops mostly *)
and check_array map e b = 
  let (typ, e', data) = expr map e in
  (match typ with
  | String -> assign map (typ, e', data) b
  | Arr | Dyn -> assign map (Dyn, e', data) b
  | _ -> raise (Failure (Printf.sprintf "STypeError: cannot iterate over type %s in 'for' loop" (string_of_typ typ))))


(* check_func: checks an entire function. 

globals and locals are the globals and locals maps (locals contains all globals).
out is a sstmt list containing the semanting checked stmts.
data is a (typ, e', sstmt) tuple containing return information for the function.
local_vars is a list of sbinds containing the local variables.
stack is a TypeMap containing the function call stack.

TODO distinguish between outer and inner scope return statements to stop evaluating when definitely
returned. *)

and check_func globals locals out data local_vars the_state = (function  
  | [] -> ((List.rev out), data, locals, List.sort_uniq compare (List.rev local_vars))
  | a :: t -> let (m', value, d, loc) = func_stmt globals locals the_state a in
    (match (data, d) with
      | (None, None) -> check_func globals m' (value :: out) None (loc @ local_vars) the_state t
      | (None, _) -> check_func globals m' (value :: out) d (loc @ local_vars) the_state t
      | (_, None) -> check_func globals m' (value :: out) data (loc @ local_vars) the_state t
      | (_, _) when d = data -> check_func globals m' (value :: out) data (loc @ local_vars) the_state t
      | _ -> check_func globals m' (value :: out) (Some (Dyn, (SNoexpr, Dyn), None)) (loc @ local_vars) the_state t))

(* match_data: when reconciling branches in a conditional branch, this function
  checks what return types can still be inferred. If both return the same type, 
  that will be preserved. If only one returns, a generic dynamic object will be returned.
  If both return the same object, that will be preserved. If both return None, that will 
  be returned. Used in for, if, and while statements.
*)

and match_data d1 d2 = match d1, d2 with
  | (None, None) -> None
  | (None, _) | (_, None) -> (Some (Dyn, (SNoexpr, Dyn), None))
  | (Some x, Some y) -> 
    if x = y then d1
    else let (t1, _, _) = x and (t2, _, _) = y in 
    (Some ((if t1 = t2 then t1 else Dyn), (SNoexpr, Dyn), None))

(* func_stmt: syntactically checkts statements inside functions. Exists mostly to handle 
  function calls which recurse and to redirect calls to expr to func_expr. We may be able
  to simplify the code by merging this with stmt, but it will be challenging to do.
*)

and merge_blocks b1 b2 = 
  let SBlock(body1) = b1 in 
  let SBlock(body2) = b2 in 
  SBlock(body1 @ body2)

and func_stmt globals locals the_state = function 
  | Return(e) -> (* for closures, match t with FuncType, attach local scope *)
    let data = func_expr globals locals the_state e in 
    let (typ, e', d) = data in 
    (locals, SReturn(e'), (Some data), []) 

  | Block(s) -> 
    let (value, data, map', out) = check_func globals locals [] None [] the_state s in 
    (map', SBlock(value), data, out)
  
  | Asn(exprs, e) -> 
    let data = func_expr globals locals the_state e in 
    let (typ, e', d) = data in

    let rec aux (m, lvalues, lcls) = function
      | [] -> (m, List.rev lvalues, List.rev lcls)
      | Var x :: t -> 
        let Bind (x1, t1) = x in 
        if the_state.cond && t1 <> Dyn then 
        raise (Failure ("SSyntaxError: cannot explicitly type variable '" ^ x1 ^ "' while in conditional branches")) 
        else let (m', name, inferred_t, explicit_t) = assign locals data x in 
        (aux (m', SLVar (Bind (name, explicit_t)) :: lvalues, Bind(name, inferred_t) :: lcls) t)

      | ListAccess(e, index) :: t -> 
        let (t1, e1, _) = func_expr globals locals the_state e in
        let (t2, e2, _) = func_expr globals locals the_state index in
        if t1 <> Dyn && not (is_arr t1) || t2 <> Int && t2 <> Dyn || t1 == String 
          then raise (Failure ("STypeError: invalid types (" ^ string_of_typ t1 ^ ", " ^ string_of_typ t2 ^ ") for list assignment"))
        else (aux (m, SLListAccess (e1, e2) :: lvalues, lcls) t)

      | ListSlice(e, low, high) :: t -> raise (Failure "SNotImplementedError: List Slicing has not been implemented")

      | Field(a, b) :: t -> raise (Failure "NotImplementedError: Fields have not been implemented")
      | _ -> raise (Failure ("STypeError: invalid expression as left-hand side of assignment."))
     
    in let (m, lvalues, locals) = aux (locals, [], []) exprs in (m, SAsn(lvalues, e'), None, locals)

  | Expr(e) -> 
      let (t, e', data) = func_expr globals locals the_state e in (locals, SExpr(e'), None, [])
  
  | Func(a, b, c) ->
    let Bind(fn_name, btype) = a in 
    let rec dups = function (* check duplicate argument names *)
      | [] -> ()
      | (Bind(n1, _) :: Bind(n2, _) :: _) when n1 = n2 -> 
        raise (Failure ("SSyntaxError: duplicate argument '" ^ n1 ^ "' in definition of function " ^ fn_name))
      | _ :: t -> dups t
    in let _ = dups (List.sort (fun (Bind(a, _)) (Bind(b, _)) -> compare a b) b) in 

    (* we assign Bind(name, Dyn) because we want to allow reassignment of functions. this weakens the type inference in 
    exchange for reasonable flexibility. i.e. this allows us to do def foo(x) -> int and then def foo(x) -> float later *)

    let (map', _, _, _) = assign locals (FuncType, (SNoexpr, FuncType), Some(Func(a, b, c))) (Bind(fn_name, Dyn)) in
    let (semantmap, _, _, _) = assign StringMap.empty (FuncType, (SNoexpr, FuncType), Some(Func(a, b, c))) (Bind(fn_name, Dyn)) in

    let (map'', binds) = List.fold_left 
        (fun (map, out) (Bind (x, t)) -> 
          let (map', name, inferred_t, explicit_t) = assign map (Dyn, (SNoexpr, Dyn), None) (Bind (x, t)) in 
          (map', Bind(name, explicit_t) :: out)
        ) (semantmap, []) b in

    let bindout = List.rev binds in

    let (map2, block, data, locals) = (func_stmt StringMap.empty map'' { forloop = false; cond = false; noeval = true; stack = TypeMap.empty;} c) in

    (match data with
      | Some (typ2, e', d) ->
        if btype <> Dyn && btype <> typ2 then if typ2 <> Dyn then 
          raise (Failure ("STypeError: invalid return type " ^ string_of_typ typ2 ^ " from function " ^ fn_name)) 
        else let func = { styp = btype; sfname = fn_name; sformals = bindout; slocals = locals; sbody = block } in 
          (map', SFunc(func), None, [Bind(fn_name, FuncType)]) 
        else let func = { styp = typ2; sfname = fn_name; sformals = bindout; slocals = locals; sbody = block } in 
        (map', SFunc(func), None, [Bind(fn_name, FuncType)])

      | None -> 
        if btype <> Dyn then 
          raise (Failure ("STypeError: expected return type " ^ (string_of_typ btype) ^ " from function " ^ fn_name ^ " but found None")) else 
        let func = { styp = Null; sfname = fn_name; sformals = bindout; slocals = locals; sbody = block } in 
        (map', SFunc(func), None, [Bind(fn_name, FuncType)]))

  | If(a, b, c) -> let (typ, e', _) = func_expr globals locals the_state a in 
        if typ <> Bool && typ <> Dyn 
          then raise (Failure (Printf.sprintf "STypeError: invalid boolean type in 'if' statement (found %s but expected bool)" (string_of_typ typ)))
        else let (map', value, data, out) = func_stmt globals locals {the_state with cond = true;} b in 
        let (map'', value', data', out') = func_stmt globals locals {the_state with cond = true;} c in 
        if equals map' map'' then (map', SIf(e', value, value'), match_data data data', out) 
        else let (merged, main, alt, binds) = transform map' map'' in 
        (merged, SIf(e', merge_blocks value main, merge_blocks value' alt), match_data data data', binds @ out @ out')

  | For(a, b, c) -> 
      let (typ, e', _) = func_expr globals locals the_state b in 
      let (m, name, inferred_t, explicit_t) = check_array locals b a in 
      let bind_for_locals = Bind(name, inferred_t) in
      let bind_for_sast = Bind(name, inferred_t) in
      let (m', x', d, out) = func_stmt globals m {the_state with cond = true; forloop = true; } c in 
      if equals locals m' then let () = debug "equal first time" in (m', SFor(bind_for_sast, e', x'), d, bind_for_locals :: out)
      else let (merged_out, _, exit, binds) = transform locals m' in
      let (merged, entry, _, _) = transform m m' in 
      let (m', x', d, out) = func_stmt globals merged {the_state with cond = true; forloop = true; } c in 
      if equals merged m' then let () = debug "equal second time" in (merged_out, SStage(entry, SFor(bind_for_sast, e', x'), exit), match_data d None, bind_for_locals :: out @ binds) 
      else let (merged, _, _, _) = transform merged_out m' in 
      (merged, SStage(entry, SFor(bind_for_sast, e', x'), exit), match_data d None, bind_for_locals :: out @ binds) 

 | Range(a, b, c) -> 
      let (typ, e', data) = func_expr globals locals the_state b in 
      if typ <> Dyn && typ <> Int 
          then raise (Failure (Printf.sprintf "STypeError: invalid type in 'range' statement (found %s but expected int)" (string_of_typ typ)))

      else let (m, name, inferred_t, explicit_t) = assign locals (typ, e', data) a in

      let bind_for_locals = Bind(name, inferred_t) in
      let bind_for_sast = Bind(name, inferred_t) in
      let (m', x', d, out) = func_stmt globals m {the_state with cond = true; forloop = true; } c in 
      if equals locals m' then let () = debug "equal first time" in (m', SRange(bind_for_sast, e', x'), d, bind_for_locals :: out)
      else let (merged_out, _, exit, binds) = transform m m' in
      let (merged, entry, _, _) = transform locals m' in 
      let (m', x', d, out) = func_stmt globals m {the_state with cond = true; forloop = true; } c in 
      if equals merged m' then let () = debug "equal second time" in (merged_out, SStage(entry, SRange(bind_for_sast, e', x'), exit), match_data d None, bind_for_locals :: out @ binds) 
      else let (merged, _, _, _) = transform merged_out m' in
      (merged, SStage(entry, SRange(bind_for_sast, e', x'), exit), match_data d None, bind_for_locals :: out @ binds) 

  | While(a, b) -> 
      let (typ, e, data) = func_expr globals locals the_state a in 
      if typ <> Bool && typ <> Dyn 
        then raise (Failure (Printf.sprintf "STypeError: invalid boolean type in 'while' statement (found %s but expected bool)" (string_of_typ typ)))
      else let (m', x', d, out) = func_stmt globals locals {the_state with cond = true; forloop = true; } b in 
      if equals locals m' then let () = debug "equal first time" in (m', SWhile(e, x'), d, out) else
      let (merged, entry, exit, binds) = transform locals m' in 
      let (m', x', d, out) = func_stmt globals merged {the_state with cond = true; forloop = true; } b in 
      if equals merged m' then let () = debug "equal second time" in (m', SStage(entry, SWhile(e, x'), exit), d, out @ binds)
      else let (merged, _, _, _) = transform merged m' in 
      (merged, SStage(entry, SWhile(e, x'), exit), match_data d None, out @ binds)

  | Nop -> (locals, SNop, None, [])

  | Type(e) ->  let (t, e', _) = func_expr globals locals the_state e in 
    (locals, SType(e'), None, []) 

  | Print(e) -> let (t, e', _) = func_expr globals locals the_state e in 
    (locals, SPrint(e'), None, [])

  | _ as s -> let (map', value, out) = stmt locals the_state s in (map', value, None, [])

(* stmt: the regular statement function used for evaluating statements outside of functions. *)

and stmt map the_state = function (* evaluates statements, can pass it a func *)
  | Asn(exprs, e) -> 
    let data = expr map e in 
    let (typ, e', d) = data in

    let rec aux (m, lvalues, locals) = function
      | [] -> (m, List.rev lvalues, List.rev locals)
      | Var x :: t -> 
        let Bind (x1, t1) = x in 
        if the_state.cond && t1 <> Dyn then 
        raise (Failure ("SSyntaxError: cannot explicitly type variable '" ^ x1 ^ "' while in conditional branches")) 
        else let (m', name, inferred_t, explicit_t) = assign m data x in 
        (aux (m', SLVar (Bind (name, explicit_t)) :: lvalues, Bind(name, inferred_t) :: locals) t)

      | ListAccess(e, index) :: t ->
        let (t1, e1, _) = expr map e in
        let (t2, e2, _) = expr map index in
        if t1 <> Dyn && not (is_arr t1) || t2 <> Int && t2 <> Dyn || t1 == String 
          then raise (Failure ("STypeError: invalid types (" ^ string_of_typ t1 ^ ", " ^ string_of_typ t2 ^ ") for list assignment"))
        else (aux (m, SLListAccess (e1, e2) :: lvalues, locals) t)

      | ListSlice(e, low, high) :: t -> raise (Failure "SNotImplementedError: List Slicing has not been implemented")

      | Field(a, b) :: t -> raise (Failure "SNotImplementedError: Fields have not been implemented")
      | _ -> raise (Failure ("STypeError: invalid expression as left-hand side of assignment."))
      
    in let (m, lvalues, locals) = aux (map, [], []) exprs in (m, SAsn(lvalues, e'), locals)

  | Expr(e) -> let (t, e', _) = expr map e in (map, SExpr(e'), [])
  | Block(s) -> let ((value, globals), map') = check map [] [] the_state s in (map', SBlock(value), globals)
  | Return(e) -> raise (Failure ("SSyntaxError: return statement outside of function"))
  | Func(a, b, c) -> 
    let Bind(fn_name, btype) = a in
    
    let rec dups = function (* check duplicate argument names *)
      | [] -> ()
      | (Bind(n1, _) :: Bind(n2, _) :: _) when n1 = n2 -> 
          raise (Failure ("SSyntaxError: duplicate argument '" ^ n1 ^ "' in definition of function " ^ fn_name))
      | _ :: t -> dups t
    in let _ = dups (List.sort (fun (Bind(a, _)) (Bind(b, _)) -> compare a b) b) in 
    
    let (map', _, _, _) = assign map (FuncType, (SNoexpr, FuncType), Some(Func(a, b, c))) (Bind(fn_name, Dyn)) in
    let (semantmap, _, _, _) = assign StringMap.empty (FuncType, (SNoexpr, FuncType), Some(Func(a, b, c))) (Bind(fn_name, Dyn)) in (* empty map for semantic checking *)

    let (map'', binds) = List.fold_left 
      (fun (map, out) (Bind(x, t)) -> 
        let (map', name, inferred_t, explicit_t) = assign map (Dyn, (SNoexpr, Dyn), None) (Bind(x, t)) in 
        (map', (Bind(name, explicit_t)) :: out)
      ) (semantmap, []) b in

    let bindout = List.rev binds in
    let (map2, block, data, locals) = (func_stmt StringMap.empty map'' {noeval = true; forloop = false; cond = false; stack = TypeMap.empty;} c) in
      (match data with
        | Some (typ2, e', d) ->
            if btype <> Dyn && btype <> typ2 then if typ2 <> Dyn then 
            raise (Failure ("STypeError: invalid return type " ^ string_of_typ typ2 ^ " from function " ^ fn_name)) else 
            let func = { styp = btype; sfname = fn_name; sformals = bindout; slocals = locals; sbody = block } in 
              (map', SFunc(func), [Bind(fn_name, FuncType)]) else
              let func = { styp = typ2; sfname = fn_name; sformals = bindout; slocals = locals; sbody = block } in 
            (map', SFunc(func), [Bind(fn_name, FuncType)])
        
        | None -> 
          if btype <> Dyn then 
          raise (Failure ("STypeError: expected return type " ^ (string_of_typ btype) ^ " from function " ^ fn_name ^ " but found None")) else 
          let func = { styp = Null; sfname = fn_name; sformals = bindout; slocals = locals; sbody = block } in 
          (map', SFunc(func), [Bind(fn_name, FuncType)]))

  | If(a, b, c) -> 
    let (typ, e', _) = expr map a in 
    if typ <> Bool && typ <> Dyn 
      then raise (Failure (Printf.sprintf "STypeError: invalid boolean type in 'if' statement (found %s but expected bool)" (string_of_typ typ)))
    else let (map', value, out) = stmt map {the_state with cond = true;} b in 
    let (map'', value', out') = stmt map {the_state with cond = true;} c in 
    if equals map' map'' then (map', SIf(e', value, value'), out') 
    else let (merged, main, alt, binds) = transform map' map'' in 
    (merged, SIf(e', merge_blocks value main, merge_blocks value' alt), out @ out' @ binds)

  | For(a, b, c) -> 
    let (typ, e', _) = expr map b in 
    let (m, name, inferred_t, explicit_t) = check_array map b a in 

    let bind_for_locals = Bind(name, inferred_t) in
    let bind_for_sast = Bind(name, inferred_t) in
    let (m', x', out) = stmt m {the_state with cond = true; forloop = true; } c in 
    if equals map m' then let () = debug "equal first time" in (m', SFor(bind_for_sast, e', x'), bind_for_locals :: out) 
    else let (merged_out, _, exit, binds) = transform map m' in (* this has the for loop variable as dynamic *)
    let (merged, entry, _, _) = transform m m' in (* this keeps the for loop variable of known type if possible *)
    let (m', x', out) = stmt merged {the_state with cond = true; forloop = true; } c in 
    if equals merged m' then let () = debug "equal second time" in (merged_out, SStage(entry, SFor(bind_for_sast, e', x'), exit), bind_for_locals :: out @ binds) 
    else let (merged, _, _, _) = transform merged_out m' in
    (merged, SStage(entry, SFor(bind_for_sast, e', x'), exit), bind_for_locals :: out @ binds)

  | Range(a, b, c) -> 
    let (typ, e', data) = expr map b in 
    if typ <> Dyn && typ <> Int 
        then raise (Failure (Printf.sprintf "STypeError: invalid type in 'range' statement (found %s but expected int)" (string_of_typ typ)))
    else let (m, name, inferred_t, explicit_t) = assign map (typ, e', data) a in

    let bind_for_locals = Bind(name, inferred_t) in
    let bind_for_sast = Bind(name, inferred_t) in
    let (m', x', out) = stmt m {the_state with cond = true; forloop = true; } c in 
    if equals map m' then let () = debug "equal first time" in (m', SRange(bind_for_sast, e', x'), bind_for_locals :: out) 
    else let (merged_out, _, exit, binds) = transform map m' in
    let (merged, entry, _, _) = transform m m' in 
    let (m', x', out) = stmt merged {the_state with cond = true; forloop = true; } c in 
    if equals merged m' then let () = debug "equal second time" in (merged_out, SStage(entry, SRange(bind_for_sast, e', x'), exit), bind_for_locals :: out @ binds) 
    else let (merged, _, _, _) = transform merged_out m' in
    (merged, SStage(entry, SRange(bind_for_sast, e', x'), exit), bind_for_locals :: out @ binds)


  | While(a, b) -> 
    let (t, e, _) = expr map a in 
    if t <> Bool && t <> Dyn then raise (Failure (Printf.sprintf "STypeError: invalid boolean type in 'while' statement (found %s but expected bool)" (string_of_typ t)))
    else let (m', x, out) = stmt map {the_state with cond = true; forloop = true; } b in 
    if equals map m' then let () = debug "equal first time" in (m', SWhile(e, x), out) 
    else let (merged, entry, exit, binds) = transform map m' in 
    let (m', x', out) = stmt merged {the_state with cond = true; forloop = true; } b in 
    if equals merged m' then let () = debug "equal second time" in (merged, SStage(entry, SWhile(e, x'), exit), out @ binds) 
    else let (merged, _, _, _) = transform merged m' in 
    (merged, SStage(entry, SWhile(e, x'), exit), out @ binds)

  | Nop -> (map, SNop, [])
  | Print(e) -> let (t, e', _) = expr map e in (map, SPrint(e'), [])
  | Type(e) -> let (t, e', _) = expr map e in
    (map, SType(e'), [])

  | _ as temp -> 
    print_endline ("SNotImplementedError: '" ^ (stmt_to_string temp) ^ "' semantic checking not implemented"); (map, SNop, [])

(* check: master function to check the entire program by iterating over the list of
statements and returning a list of sstmts, a list of globals, and the updated map *)

and check map sast_out globals_out the_state = function
  | [] -> ((List.rev sast_out, List.sort_uniq Pervasives.compare (List.rev (globals_out @ !possible_globals))), map)
  | a :: t -> let (m', statement, binds) = stmt map the_state a in check m' (statement :: sast_out) (binds @ globals_out) the_state t
