open Source
open Ast
open Script
open Values
open Types
open Sexpr


(* Generic formatting *)

let int = string_of_int
let int32 = Int32.to_string
let int64 = Int64.to_string

let add_hex_char buf c = Printf.bprintf buf "\\%02x" (Char.code c)
let add_char buf c =
  if c < '\x20' || c >= '\x7f' then
    add_hex_char buf c
  else begin
    if c = '\"' || c = '\\' then Buffer.add_char buf '\\';
    Buffer.add_char buf c
  end

let string_with add_char s =
  let buf = Buffer.create (3 * String.length s + 2) in
  Buffer.add_char buf '\"';
  String.iter (add_char buf) s;
  Buffer.add_char buf '\"';
  Buffer.contents buf

let bytes = string_with add_hex_char
let string = string_with add_char

let list_of_opt = function None -> [] | Some x -> [x]

let list f xs = List.map f xs
let listi f xs = List.mapi f xs
let opt f xo = list f (list_of_opt xo)

let tab head f xs = if xs = [] then [] else [Node (head, list f xs)]
let atom f x = Atom (f x)

let break_bytes s =
  let ss = Lib.String.breakup s (!Flags.width / 3 - 4) in
  list (atom bytes) ss


(* Types *)

let value_type t = string_of_value_type t

let elem_type t = string_of_elem_type t

let decls kind ts = tab kind (atom value_type) ts

let func_type (FuncType (ins, out)) =
  Node ("func", decls "param" ins @ decls "result" out)

let struct_type = func_type

let limits int {min; max} =
  String.concat " " (int min :: opt int max)

let global_type = function
  | GlobalType (t, Immutable) -> atom string_of_value_type t
  | GlobalType (t, Mutable) -> Node ("mut", [atom string_of_value_type t])


(* Operators *)

module IntOp =
struct
  open Ast.IntOp

  let unop xx = function
    | Clz -> "clz"
    | Ctz -> "ctz"
    | Popcnt -> "popcnt"

  let binop xx = function
    | Add -> "add"
    | Sub -> "sub"
    | Mul -> "mul"
    | DivS -> "div_s"
    | DivU -> "div_u"
    | RemS -> "rem_s"
    | RemU -> "rem_u"
    | And -> "and"
    | Or -> "or"
    | Xor -> "xor"
    | Shl -> "shl"
    | ShrS -> "shr_s"
    | ShrU -> "shr_u"
    | Rotl -> "rotl"
    | Rotr -> "rotr"

  let testop xx = function
    | Eqz -> "eqz"

  let relop xx = function
    | Eq -> "eq"
    | Ne -> "ne"
    | LtS -> "lt_s"
    | LtU -> "lt_u"
    | LeS -> "le_s"
    | LeU -> "le_u"
    | GtS -> "gt_s"
    | GtU -> "gt_u"
    | GeS -> "ge_s"
    | GeU -> "ge_u"

  let cvtop xx = function
    | ExtendSI32 -> "extend_s/i32"
    | ExtendUI32 -> "extend_u/i32"
    | WrapI64 -> "wrap/i64"
    | TruncSF32 -> "trunc_s/f32"
    | TruncUF32 -> "trunc_u/f32"
    | TruncSF64 -> "trunc_s/f64"
    | TruncUF64 -> "trunc_u/f64"
    | ReinterpretFloat -> "reinterpret/f" ^ xx
end

module FloatOp =
struct
  open Ast.FloatOp

  let unop xx = function
    | Neg -> "neg"
    | Abs -> "abs"
    | Ceil -> "ceil"
    | Floor -> "floor"
    | Trunc -> "trunc"
    | Nearest -> "nearest"
    | Sqrt -> "sqrt"

  let binop xx = function
    | Add -> "add"
    | Sub -> "sub"
    | Mul -> "mul"
    | Div -> "div"
    | Min -> "min"
    | Max -> "max"
    | CopySign -> "copysign"

  let testop xx = fun _ -> assert false

  let relop xx = function
    | Eq -> "eq"
    | Ne -> "ne"
    | Lt -> "lt"
    | Le -> "le"
    | Gt -> "gt"
    | Ge -> "ge"

  let cvtop xx = function
    | ConvertSI32 -> "convert_s/i32"
    | ConvertUI32 -> "convert_u/i32"
    | ConvertSI64 -> "convert_s/i64"
    | ConvertUI64 -> "convert_u/i64"
    | PromoteF32 -> "promote/f32"
    | DemoteF64 -> "demote/f64"
    | ReinterpretInt -> "reinterpret/i" ^ xx
end

let oper (intop, floatop) op =
  value_type (type_of op) ^ "." ^
  (match op with
  | I32 o -> intop "32" o
  | I64 o -> intop "64" o
  | F32 o -> floatop "32" o
  | F64 o -> floatop "64" o
  )

let unop = oper (IntOp.unop, FloatOp.unop)
let binop = oper (IntOp.binop, FloatOp.binop)
let testop = oper (IntOp.testop, FloatOp.testop)
let relop = oper (IntOp.relop, FloatOp.relop)
let cvtop = oper (IntOp.cvtop, FloatOp.cvtop)

let mem_size = function
  | Memory.Mem8 -> "8"
  | Memory.Mem16 -> "16"
  | Memory.Mem32 -> "32"

let extension = function
  | Memory.SX -> "_s"
  | Memory.ZX -> "_u"

let memop name {ty; align; offset; _} =
  value_type ty ^ "." ^ name ^
  (if offset = 0l then "" else " offset=" ^ int32 offset) ^
  (if align = size ty then "" else " align=" ^ int align)

let loadop op =
  match op.sz with
  | None -> memop "load" op
  | Some (sz, ext) -> memop ("load" ^ mem_size sz ^ extension ext) op

let storeop op =
  match op.sz with
  | None -> memop "store" op
  | Some sz -> memop ("store" ^ mem_size sz) op


(* Expressions *)

let var x = Int32.to_string x.it
let value v = string_of_value v.it
let constop v = value_type (type_of v.it) ^ ".const"

let rec instr e =
  let head, inner =
    match e.it with
    | Unreachable -> "unreachable", []
    | Nop -> "nop", []
    | Drop -> "drop", []
    | Block es -> "block", list instr es
    | Loop es -> "loop", list instr es
    | Br (n, x) -> "br " ^ int n ^ " " ^ var x, []
    | BrIf (n, x) -> "br_if " ^ int n ^ " " ^ var x, []
    | BrTable (n, xs, x) ->
      "br_table " ^ int n ^ " " ^ String.concat " " (list var (xs @ [x])), []
    | Return -> "return", []
    | If (es1, es2) ->
      "if", [Node ("then", list instr es1); Node ("else", list instr es2)]
    | Select -> "select", []
    | Call x -> "call " ^ var x, []
    | CallIndirect x -> "call_indirect " ^ var x, []
    | GetLocal x -> "get_local " ^ var x, []
    | SetLocal x -> "set_local " ^ var x, []
    | TeeLocal x -> "tee_local " ^ var x, []
    | GetGlobal x -> "get_global " ^ var x, []
    | SetGlobal x -> "set_global " ^ var x, []
    | Load op -> loadop op, []
    | Store op -> storeop op, []
    | Const lit -> constop lit ^ " " ^ value lit, []
    | Unary op -> unop op, []
    | Binary op -> binop op, []
    | Test op -> testop op, []
    | Compare op -> relop op, []
    | Convert op -> cvtop op, []
    | CurrentMemory -> "current_memory", []
    | GrowMemory -> "grow_memory", []
  in Node (head, inner)

let const c =
  list instr c.it


(* Functions *)

let func off i f =
  let {ftype; locals; body} = f.it in
  Node ("func $" ^ string_of_int (off + i),
    [Node ("type " ^ var ftype, [])] @
    decls "local" locals @
    list instr body
  )

let start x = Node ("start " ^ var x, [])

let table xs = tab "table" (atom var) xs


(* Tables & memories *)

let table off i tab =
  let {ttype = TableType (lim, t)} = tab.it in
  Node ("table $" ^ string_of_int (off + i) ^ " " ^ limits int32 lim,
    [atom elem_type t]
  )

let memory off i mem =
  let {mtype = MemoryType lim} = mem.it in
  Node ("memory $" ^ string_of_int (off + i) ^ " " ^ limits int32 lim, [])

let segment head dat seg =
  let {index; offset; init} = seg.it in
  Node (head, atom var index :: Node ("offset", const offset) :: dat init)

let elems seg =
  segment "elem" (list (atom var)) seg

let data seg =
  segment "data" break_bytes seg


(* Modules *)

let typedef i t =
  Node ("type $" ^ string_of_int i, [struct_type t])

let import_kind i k =
  match k.it with
  | FuncImport x ->
    Node ("func $" ^ string_of_int i, [Node ("type", [atom var x])])
  | TableImport t -> table 0 i ({ttype = t} @@ k.at)
  | MemoryImport t -> memory 0 i ({mtype = t} @@ k.at)
  | GlobalImport t -> Node ("global $" ^ string_of_int i, [global_type t])

let import i im =
  let {module_name; item_name; ikind} = im.it in
  Node ("import",
    [atom string module_name; atom string item_name; import_kind i ikind]
  )

let export_kind k =
  match k.it with
  | FuncExport -> "func"
  | TableExport -> "table"
  | MemoryExport -> "memory"
  | GlobalExport -> "global"

let export ex =
  let {name; ekind; item} = ex.it in
  Node ("export",
    [atom string name; Node (export_kind ekind, [atom var item])]
  )

let global off i g =
  let {gtype; value} = g.it in
  Node ("global $" ^ string_of_int (off + i), global_type gtype :: const value)


(* Modules *)

let var_opt = function
  | None -> ""
  | Some x -> " " ^ x.it

let is_func_import im =
  match im.it.ikind.it with FuncImport _ -> true | _ -> false
let is_table_import im =
  match im.it.ikind.it with TableImport _ -> true | _ -> false
let is_memory_import im =
  match im.it.ikind.it with MemoryImport _ -> true | _ -> false
let is_global_import im =
  match im.it.ikind.it with GlobalImport _ -> true | _ -> false

let module_with_var_opt x_opt m =
  let func_imports = List.filter is_func_import m.it.imports in
  let table_imports = List.filter is_table_import m.it.imports in
  let memory_imports = List.filter is_memory_import m.it.imports in
  let global_imports = List.filter is_global_import m.it.imports in
  Node ("module" ^ var_opt x_opt,
    listi typedef m.it.types @
    listi import table_imports @
    listi import memory_imports @
    listi import global_imports @
    listi import func_imports @
    listi (table (List.length table_imports)) m.it.tables @
    listi (memory (List.length memory_imports)) m.it.memories @
    listi (global (List.length global_imports)) m.it.globals @
    listi (func (List.length func_imports)) m.it.funcs @
    list export m.it.exports @
    opt start m.it.start @
    list elems m.it.elems @
    list data m.it.data
  )

let binary_module_with_var_opt x_opt bs =
  Node ("module" ^ var_opt x_opt, break_bytes bs)

let module_ = module_with_var_opt None
let binary_module = binary_module_with_var_opt None


(* Scripts *)

let literal lit =
  match lit.it with
  | Values.I32 i -> Node ("i32.const " ^ I32.to_string i, [])
  | Values.I64 i -> Node ("i64.const " ^ I64.to_string i, [])
  | Values.F32 z -> Node ("f32.const " ^ F32.to_string z, [])
  | Values.F64 z -> Node ("f64.const " ^ F64.to_string z, [])

let definition mode x_opt def =
  match mode, def.it with
  | `Textual, _ | `Original, Textual _ ->
    let m =
      match def.it with
      | Textual m -> m
      | Binary (_, bs) -> Decode.decode "" bs
    in module_with_var_opt x_opt m
  | `Binary, _ | `Original, Binary _ ->
    let bs =
      match def.it with
      | Textual m -> Encode.encode m
      | Binary (_, bs) -> bs
    in binary_module_with_var_opt x_opt bs

let access x_opt name =
  String.concat " " [var_opt x_opt; string name]

let action act =
  match act.it with
  | Invoke (x_opt, name, lits) ->
    Node ("invoke" ^ access x_opt name, List.map literal lits)
  | Get (x_opt, name) ->
    Node ("get" ^ access x_opt name, [])

let assertion mode ass =
  match ass.it with
  | AssertMalformed (def, re) ->
    Node ("assert_malformed", [definition `Original None def; Atom (string re)])
  | AssertInvalid (def, re) ->
    Node ("assert_invalid", [definition mode None def; Atom (string re)])
  | AssertUnlinkable (def, re) ->
    Node ("assert_unlinkable", [definition mode None def; Atom (string re)])
  | AssertReturn (act, lits) ->
    Node ("assert_return", action act :: List.map literal lits)
  | AssertReturnNaN act ->
    Node ("assert_return_nan", [action act])
  | AssertTrap (act, re) ->
    Node ("assert_trap", [action act; Atom (string re)])

let command mode cmd =
  match cmd.it with
  | Module (x_opt, def) -> definition mode x_opt def
  | Register (name, x_opt) ->
    Node ("register " ^ string name ^ var_opt x_opt, [])
  | Action act -> action act
  | Assertion ass -> assertion mode ass
  | Meta _ -> assert false

let script mode scr = List.map (command mode) scr
