open Ast

(*

What semant does:

  1. undeclared identifiers (get a list of globals and locals for each function, check to make sure they are all declared at some poiont
  2. correct number of arguments in function call
  3. correct types of explicitly declared variables
  4. return types in the right place
  5. duplicate formal arguments
*)

type sprogram = sstmt list * sbind list

and sfunc_decl = {
  styp : typ;
  sfname : string;
  sformals : sbind list;
  slocals : sbind list;
  sbody : sstmt
}

and sbind = 
  | WeakBind of string * typ (* bind when not known to be declared, typ can be dynamic. (name, inferred type) *)
  | StrongBind of string * typ (* known to be declared, typ can be dynamic. (name, inferred type) *)

and sexpr =
  | SBinop of sexpr * operator * sexpr (* (left sexpr, op, right sexpr) *)
  | SLit of literal (* literal *)
  | SVar of sbind (* see above *)
  | SUnop of uop * sexpr (* (uop, sexpr ) *)
  | SCall of sbind * sexpr list * sstmt (* ((name, return type), list of args, SFunc) *)
  | SMethod of sexpr * string * sexpr list (* not implemented *)
  | SField of sexpr * string (* not implemented *)
  | SList of sexpr list * typ (* (list of expressions, inferred type) *)
  | SNoexpr (* no expression *)
  (* | SListAccess of sexpr * sexpr (* not implemented *) *)

and sstmt = (* this can be refactored using Blocks, but I haven't quite figured it out yet *)
  | SFunc of sfunc_decl (* (name, return type), list of formals, list of locals, body) *)
  | SBlock of sstmt list (* block found in function body or for/else/if/while loop *)
  | SExpr of sexpr (* see above *)
  | SIf of sexpr * sstmt * sstmt (* condition, if, else *)
  | SFor of sbind * sexpr * sstmt (* (variable, list, body (block)) *)
  | SWhile of sexpr * sstmt (* (condition, body (block)) *)
  | SReturn of sexpr (* return statement *)
  | SClass of sbind * sstmt (* not implemented *)
  | SAsn of sbind list * sexpr (* x : int = sexpr, (Bind(x, int), sexpr) *)
  | SPrint of sexpr
  | SNop

let rec string_of_sbind = function
  | WeakBind(s, t) -> s ^ ": " ^ string_of_typ t ^ " [weak]"
  | StrongBind(s, t) -> s ^ ": " ^ string_of_typ t ^ " [strong]"

and string_of_sexpr = function
  | SBinop(e1, o, e2) -> string_of_sexpr e1 ^ " " ^ string_of_op o ^ " " ^ string_of_sexpr e2
  | SLit(l) -> string_of_lit l
  | SVar(b) -> string_of_sbind b
  | SUnop(o, e) -> string_of_uop o ^ string_of_sexpr e
  | SCall(f, el, s) -> string_of_sbind f ^ "(" ^ String.concat ", " (List.map string_of_sexpr el) ^ "):\n" ^ string_of_sstmt s
  | SMethod(obj, m, el) -> string_of_sexpr obj ^ "." ^ m ^ "(" ^ String.concat ", " (List.map string_of_sexpr el) ^ ")"
  | SField(obj, s) -> string_of_sexpr obj ^ "." ^ s
  | SList(el, t) -> string_of_typ t ^ " list : " ^ String.concat ", " (List.map string_of_sexpr el)
  | SNoexpr -> ""

and string_of_sstmt = function
  | SFunc({ styp; sfname; sformals; slocals; sbody }) -> "def " ^ sfname ^ "(" ^ String.concat ", " (List.map string_of_sbind sformals) ^ ") -> " ^ (string_of_typ styp) ^ ": [" ^ String.concat ", " (List.map string_of_sbind slocals) ^ "]\n" ^ string_of_sstmt sbody
  | SBlock(sl) -> String.concat "\n" (List.map string_of_sstmt sl) ^ "\n"
  | SExpr(e) -> string_of_sexpr e
  | SIf(e, s1, s2) ->  "if " ^ string_of_sexpr e ^ ":\n" ^ string_of_sstmt s1 ^ "else:\n" ^ string_of_sstmt s2
  | SFor(b, e, s) -> "for " ^ string_of_sbind b ^ " in " ^ string_of_sexpr e ^ ":\n" ^ string_of_sstmt s
  | SWhile(e, s) -> "while " ^ string_of_sexpr e ^ ":\n" ^ string_of_sstmt s
  | SReturn(e) -> "return " ^ string_of_sexpr e ^ "\n"
  | SClass(b, s) -> "class " ^ ((function | StrongBind(s, t) -> s | WeakBind(s, t) -> s) b ^ ":\n" ^ string_of_sstmt s)
  | SAsn(bl, e) -> String.concat ", " (List.map string_of_sbind bl) ^ " = "  ^ string_of_sexpr e
  (* | SFuncDecl(b, bl, s) -> "def " ^ string_of_bind b ^ "(" ^ String.concat ", " (List.map string_of_bind bl) ^ ")\n" ^ string_of_stmt s *)
  | SNop -> ""

and string_of_sprogram (sl, bl) = String.concat "" (List.map string_of_sstmt sl) ^ "\n\n" ^ String.concat " " (List.map string_of_sbind bl)

