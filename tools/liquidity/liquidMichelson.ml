(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2017       .                                          *)
(*    Fabrice Le Fessant, OCamlPro SAS <fabrice@lefessant.net>            *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(* Michelson code generation *)

open LiquidTypes

(********************
 * Helper functions *
 ********************)

let loc_of_many (l : loc_michelson list) = match l, List.rev l with
  | [], _ | _, [] -> LiquidLoc.noloc
  | first :: _, last :: _ -> LiquidLoc.merge first.loc last.loc

let ii ~loc ins = { ins; loc; loc_name = None }

let seq exprs = ii ~loc:(loc_of_many exprs) (SEQ exprs)

let dup ~loc n = ii ~loc (DUP n)

(* n = size of preserved head of stack *)
let dip ~loc n exprs = ii ~loc (DIP (n, seq exprs))

let push ~loc ty cst = ii ~loc (PUSH (LiquidEncode.encode_type ty, cst))

let sanitize_name s =
  let to_change = ref [] in
  let sharp_s = "_sharp_" in
  let slash_s = "_slash_" in
  let prim_s = "_prim_" in
  String.iteri (fun i -> function
      | '#' -> to_change := (i, sharp_s) :: !to_change
      | '/' -> to_change := (i, slash_s) :: !to_change
      | '\'' -> to_change := (i, prim_s) :: !to_change
      | _ -> ()
    ) s;
  match !to_change with
  | [] -> s
  | to_change ->
    let new_s = ref "" in
    let last = ref 0 in
    List.iter(fun (i, repl) ->
        new_s := !new_s ^ String.sub s !last (i - !last) ^ repl;
        last := i + 1;
      ) (List.rev to_change);
    let len = String.length s in
    if !last >= len then !new_s
    else !new_s ^ String.sub s !last (len - !last)

let sanitize_opt = function
  | Some s -> Some (sanitize_name s)
  | None -> None

(* n = size of preserved head of stack *)
let drop_stack ~loc n depth =
  if depth = 0 then [] else
    let rec drop_stack depth =
      if depth = 0 then [] else
        ii ~loc DROP :: (drop_stack (depth-1))
    in
    let exps = drop_stack depth in
    if n = 0 then exps else [ii ~loc @@ DIP_DROP (n, List.length exps)]


(*******************
 * Code generation *
 *******************)

let rec translate_code ~parameter_name ~storage_name code =

  (* Compile a Liquidity instruction. The parameter depth maintains
     the current depth of the stack, this is used to recover variables. *)
  let rec compile_desc depth env ~loc desc =
    match desc with
    | Var name ->
      (* A variable whose value is stored at position pos in a stack
         of size depth, can be put on top of the stack with
         instruction DU*(depth-pos)P *)
      let pos = try
          StringMap.find name env
        with Not_found ->
          LiquidLoc.raise_error ~loc
            "Internal Error(Michelson): variable %S not found\n%!"
            name
      in
      [ dup ~loc (depth - pos) ]

    | Const { ty; const } ->
      (* Compiling a constant is just pushing it on the stack *)
      [ push ~loc ty const ]

    | Project { field; record } ->
      (* Projection r.f is translated to access in a nested pair (with
         CD*DR or CD*AR) annotated with the field name *)
      begin match record.ty with
        | Trecord (_, fields) ->
          let n =
            let exception Found of int in
            try
              List.iteri
                (fun i (l, _) -> if l = field then raise (Found i))
                fields;
              LiquidLoc.raise_error ~loc
                "Internal Error: field %s not found\n%!" field
            with Found n -> n
          in
          let last_n = List.length fields - 1 in
          let record = compile depth env record in
          let ins =
            if n = last_n then
              ii ~loc @@ CDDR (n-1, Some field)
            else
              ii ~loc @@ CDAR (n, Some field)
          in
          record @ [ ins ]
        | _ -> assert false
      end

    | SetField { record; field; set_val } ->
      begin match record.ty with
        | Trecord (_, fields) ->
          let record = compile depth env record in
          let fields = List.map fst fields in
          let set_code =
            compile_record_set ~loc (depth+1) env fields field set_val in
          record @ set_code
        | _ -> assert false
      end

    | Seq (e1, e2) ->
      (* Sequences e1; e2 is compiled as a sequence in Michelson and
         the result of e1 is droped (ignored) *)
      let e1 = compile depth env e1 in
      let e2 = compile depth env e2 in
      e1 @ [ ii ~loc:LiquidLoc.noloc DROP ] @ e2

    | Let { bnd_var; bnd_val; body } ->
      (* Compiling a let binding is compiling the bound value and
         remembering the depth at which this value can be found on the
         stack, and compiling the body *)
      let bnd_val = compile depth env bnd_val in
      let env = StringMap.add bnd_var.nname depth env in
      let depth = depth + 1 in
      let body = compile depth env body in
      let cleanup_stack = [ ii ~loc @@ DIP_DROP (1, 1) ] in
      bnd_val @ body @ cleanup_stack

    | Lambda { recursive = Some _ } ->
      assert false (* encoded *)

    | Lambda { arg_name; arg_ty; body; ret_ty; recursive = None } ->
      let env = StringMap.empty in
      let env = StringMap.add arg_name.nname 0 env in
      let depth = 1 in
      let arg_type = LiquidEncode.encode_type arg_ty in
      let res_type = LiquidEncode.encode_type ret_ty in
      let body = compile depth env body in
      let arg_annot = compile_arg_name arg_name.nname in
      [ ii ~loc @@
        LAMBDA (arg_type, res_type,
                seq (arg_annot @ body @ [ii ~loc @@ DIP_DROP (1,1)])) ]

    | Closure { arg_name; arg_ty; call_env; body; ret_ty } ->
      (* A closure is compiled as a pair (call_env, lambda). Function
         application then distinguishes whether the function is a pure
         lambda or a closure *)
      let call_env_code = match call_env with
        | [] -> assert false
        | [_, e] -> compile depth env e
        | _ -> compile_tuple ~loc depth env (List.rev_map snd call_env)
      in
      let arg_ty = LiquidEncode.encode_type arg_ty in
      let ret_ty = LiquidEncode.encode_type ret_ty in
      call_env_code @
      compile_desc depth env ~loc
        (Lambda { arg_name; arg_ty; body; ret_ty; recursive = None }) @
      [ ii ~loc PAIR ]

    | If { cond; ifthen; ifelse } ->
      let cond = compile depth env cond in
      let ifthen = compile depth env ifthen in
      let ifelse = compile depth env ifelse in
      let loc = loc_of_many cond in
      cond @ [ ii ~loc @@ IF (seq ifthen, seq ifelse)]

    | Transfer { entry = Some _ } ->
      assert false (* should have been encoded *)

    | Transfer { contract; amount; entry = None; arg } ->
      (* Contract.call (encoded) compiled to TRANSFER_TOKENS *)
      let contract = compile depth env contract in
      let amount = compile (depth+1) env amount in
      let arg = compile (depth+2) env arg in
      contract @ amount @ arg @ [ ii ~loc TRANSFER_TOKENS ]

    | Failwith arg ->
      let arg = compile depth env arg in
      arg @ [ ii ~loc FAILWITH ]

    | Apply { prim = Prim_unknown } ->
      (* This is removed by typechecking *)
      assert false

    | Apply { prim = Prim_exec; args = [arg; { ty = Tclosure _ } as f] } ->
      (* Compile closure application. Open closure pair, pair argument
         with call environment and pass to lambda. *)
      let f_env = compile depth env f in
      let arg = compile (depth+1) env arg in
      f_env @ arg @
      [ dip ~loc 1 [ dup ~loc 1; ii ~loc @@ CAR None;
                     ii ~loc SWAP; ii ~loc @@ CDR None] ] @
      [ ii ~loc PAIR ; ii ~loc EXEC ]

    | Apply { prim; args = ([_; { ty = Tlambda _ } ] as args) } ->
      compile_prim ~loc depth env prim args

    | Apply { prim; args } ->
      compile_prim ~loc depth env prim args

    (* For the different pattern matching constructs, we need to drop
       values of the constructors arguments on the corresponding
       branches. *)

    | MatchOption { arg; ifnone; some_name; ifsome } ->
      (* Pattern matching on option compiled with IF_NONE. Here, drop
         binding for Some, at the end. *)
      let arg = compile depth env arg in
      let ifnone = compile depth env ifnone in
      let env = StringMap.add some_name.nname depth env in
      let depth = depth + 1 in
      let ifsome = compile depth env ifsome in
      let loc2, loc3 = loc_of_many ifnone, loc_of_many ifsome in
      let ifsome_end = [ii ~loc:loc3 @@ DIP_DROP(1,1)] in
      arg @ [ ii ~loc @@ IF_NONE (seq ifnone, seq (ifsome @ ifsome_end) )]

    | MatchNat { arg; plus_name; ifplus; minus_name; ifminus } ->
      (* match%nat is compiled with ABS *)
      let arg = compile depth env arg in
      let env' = StringMap.add plus_name.nname depth env in
      let ifplus = compile (depth + 1) env' ifplus in
      let env'' = StringMap.add minus_name.nname depth env in
      let ifminus = compile (depth + 1) env'' ifminus in
      let loc2, loc3 = loc_of_many ifplus, loc_of_many ifminus in
      let (ifplus_end, ifminus_end) =
        [ ii ~loc:loc2 @@ DIP_DROP(1,1) ],
        [ ii ~loc:loc3 @@ DIP_DROP(1,1) ] in
      arg @ [
        dup ~loc 1; ii ~loc ABS; ii ~loc SWAP; ii ~loc GE;
        ii ~loc @@ IF (seq (ifplus @ ifplus_end),
                       seq (ifminus @ ifminus_end) )]

    | MatchList { arg; head_name; tail_name; ifcons; ifnil } ->
      (* Pattern matching on lists. Compiled with IF_CONS *)
      let arg = compile depth env arg in
      let ifnil = compile depth env ifnil in
      let env = StringMap.add tail_name.nname depth env in
      let env = StringMap.add head_name.nname (depth+1) env in
      let depth = depth + 2 in
      let ifcons = compile depth env ifcons in
      let loc2, loc3 = loc_of_many ifnil, loc_of_many ifcons in
      let ifcons_end = [ii ~loc:loc3 @@ DIP_DROP(1,2)] in
      arg @ [ ii ~loc @@ IF_CONS (seq (ifcons @ ifcons_end), seq ifnil )]

    | MatchVariant { arg; cases } ->
      (* Pattern matching on sum types are compiled as nested IF_LEFT. *)
      let arg = compile depth env arg in
      let rec iter cases =
        match cases with
        | [] -> [ii ~loc DROP]
        | (CConstr (_, args), e) :: cases ->
          let env, depth, left_start, left_end =
            match args with
            | _ :: _ :: _ -> assert false
            | [] -> env, depth, [ii ~loc DROP], []
            | [arg_name] ->
              let env = StringMap.add arg_name depth env in
              let depth = depth + 1 in
              let left_end = [ii ~loc @@ DIP_DROP(1,1)] in
              let arg_annot = compile_arg_name arg_name in
              env, depth, arg_annot, left_end in
          let left = left_start @ compile depth env e @ left_end in
          begin match cases with
            | [] -> left
            | _ ->
              let right = iter cases in
              [ii ~loc @@ IF_LEFT( seq (left), seq right )]
          end
        | [CAny, e] -> [ii ~loc DROP] @ compile depth env e
        | _ -> assert false
      in
      arg @ iter cases

    | Loop { arg_name; body; arg } ->
      let arg = compile depth env arg in
      let env = StringMap.add arg_name.nname depth env in
      let depth = depth + 1 in
      let arg_annot = compile_arg_name arg_name.nname in
      let body = compile depth env body in
      let body_end = [ ii ~loc @@ DIP_DROP (1,1);
                       ii ~loc @@ DUP 1;
                       ii ~loc @@ CAR None;
                       ii ~loc @@ DIP (1, seq [ ii ~loc @@ CDR None ]) ] in
      arg
      @ [ ii ~loc @@ PUSH (Tbool, CBool true) ]
      @ [ ii ~loc @@ LOOP (seq (arg_annot @ body @ body_end)) ]

    | LoopLeft { arg_name; body; arg; acc = Some acc } ->
      let right_ty = match body.ty with
        | Ttuple [Tor (_, right_ty); _] -> right_ty
        | _ -> assert false in
      let acc = compile depth env acc in
      let depth = depth + 1 in
      let arg = compile depth env arg in
      let env = StringMap.add arg_name.nname depth env in
      let depth = depth + 1 in
      let arg_annot = compile_arg_name arg_name.nname in
      let body = compile depth env body in
      let body_begin = [ dip ~loc 1 [ii ~loc @@ DUP 1]; ii ~loc PAIR ] in
      let body_end = [
        ii ~loc @@ DIP_DROP (1,2);
        dup ~loc 1;
        dip ~loc 1 [ ii ~loc @@ CDR None ];
        ii ~loc @@ CAR None;
      ] in
      acc @ arg @ [ ii ~loc (LEFT (right_ty, None)) ] @
      [ ii ~loc @@ LOOP_LEFT (seq (arg_annot @ body_begin @ body @ body_end));
        ii ~loc PAIR ]

    | LoopLeft { arg_name; body; arg; acc = None } ->
      let right_ty = match body.ty with
        | Tor (_, right_ty) -> right_ty
        | _ -> assert false in
      let arg = compile depth env arg in
      let env = StringMap.add arg_name.nname depth env in
      let depth = depth + 1 in
      let arg_annot = compile_arg_name arg_name.nname in
      let body = compile depth env body in
      let body_end = [ ii ~loc @@ DIP_DROP (1,1) ] in
      arg @ [ ii ~loc (LEFT (right_ty, None)) ] @
      [ ii ~loc @@ LOOP_LEFT (seq (arg_annot @ body @ body_end)) ]

    | Fold { prim; arg_name; body; arg; acc } ->
      let acc = compile depth env acc in
      let depth = depth + 1 in
      let arg = compile depth env arg in
      let env = StringMap.add arg_name.nname depth env in
      let depth = depth + 1 in
      let arg_annot = compile_arg_name arg_name.nname in
      let body = compile depth env body in
      let body_begin = match prim with
        | Prim_map_iter | Prim_set_iter | Prim_list_iter ->
          []
        | _ ->
          [ dip ~loc 1 [ii ~loc @@ DUP 1]; ii ~loc PAIR ]
      in
      let body_end = [ ii ~loc @@ DIP_DROP (1,2) ] in
      acc @ arg @
      [ii ~loc @@ ITER (seq (arg_annot @ body_begin @ body @ body_end))]

    | Map { arg_name; body; arg } ->
      let arg = compile depth env arg in
      let env = StringMap.add arg_name.nname depth env in
      let depth = depth + 1 in
      let arg_annot = compile_arg_name arg_name.nname in
      let body = compile depth env body in
      let body_end = [ ii ~loc @@ DIP_DROP (1,1) ] in
      arg @
      [ii ~loc @@ MAP (seq (arg_annot @ body @ body_end))]

    | MapFold { arg_name; body; arg; acc } ->
      let acc = compile depth env acc in
      let depth = depth + 1 in
      let arg = compile depth env arg in
      let env = StringMap.add arg_name.nname depth env in
      let depth = depth + 1 in
      let arg_annot = compile_arg_name arg_name.nname in
      let body = compile depth env body in
      let body_begin = [ dip ~loc 1 [ii ~loc @@ DUP 1]; ii ~loc PAIR ] in
      let body_end = [
        ii ~loc @@ DIP_DROP (1,2);
        dup ~loc 1;
        dip ~loc 1 [ ii ~loc @@ CDR None ];
        ii ~loc @@ CAR None;
      ] in
      acc @ arg @
      [ii ~loc @@ MAP (seq (arg_annot @ body_begin @ body @ body_end));
       ii ~loc PAIR ]
    (* TODO check this *)

    | CreateContract { args; contract } ->
      let _depth, args_code = compile_args depth env args in
      let mic_contract = translate contract in
      let contract_code = ii ~loc @@ CREATE_CONTRACT mic_contract in
      (* if !LiquidOptions.annotmic then
       *   (\* Hack: using annotation to represent contract name *\)
       *   contract_code.loc_name <- Some (prefix_contract^contract.contract_name); *)
      args_code @
      [contract_code; ii ~loc PAIR]

    | ContractAt { arg; c_sig } ->
      let param_ty = LiquidEncode.encode_contract_sig c_sig in
      compile depth env arg @
      [ ii ~loc (CONTRACT param_ty) ]

    | Unpack { arg; ty } ->
      let ty = LiquidEncode.encode_type ty in
      compile depth env arg @
      [ ii ~loc (UNPACK ty) ]

    | Record fields ->
      compile_record ~loc depth env fields

    | Constructor _ ->
      (* removed during typechecking, replaced by tuple *)
      assert false

  (* Compile a Liquidity application (prim args) *)
  and compile_prim ~loc depth env prim args =
    let ii = ii ~loc in
    match prim, args with
    | Prim_tuple, args ->
      compile_tuple ~loc depth env (List.rev args)

    | Prim_tuple_get,
      [arg; { desc = Const { const = CInt n | CNat n }}] ->
      let size = size_of_type arg.ty in
      let arg = compile depth env arg in
      let n = LiquidPrinter.int_of_integer n in
      let ins =
        if size = n + 1 then
          ii @@ CDDR (n-1, None)
        else
          ii @@ CDAR (n, None)
      in
      arg @ [ ins ]
    | Prim_tuple_get, _ -> assert false

    | Prim_tuple_set,
      [x; { desc = Const { const = CInt n | CNat n }}; y ] ->
      let x_code = compile depth env x in
      let n = LiquidPrinter.int_of_integer n in
      let size = size_of_type x.ty in
      let is_last = size = n + 1 in
      let set_code = compile_tuple_set ~loc is_last (depth+1) env n y in
      x_code @ set_code
    | Prim_tuple_set, _ -> assert false

    | Prim_self, _ -> [ ii SELF ]
    | Prim_balance, _ -> [ ii BALANCE ]
    | Prim_now, _ -> [ ii NOW ]
    | Prim_amount, _ -> [ ii AMOUNT ]
    | Prim_gas, _ -> [ ii STEPS_TO_QUOTA ]
    | Prim_source, _ -> [ ii SOURCE ]
    | Prim_sender, _ -> [ ii SENDER ]

    | Prim_Left, [ arg; { desc = Apply { prim = Prim_unused constr };
                          ty = right_ty }] ->
      let right_ty = LiquidEncode.encode_type right_ty in
      compile depth env arg @
      [ ii (LEFT (right_ty, constr)) ]
    | Prim_Left, _ -> assert false

    | Prim_Right, [ arg; { desc = Apply { prim = Prim_unused constr };
                           ty = left_ty } ] ->
      let left_ty = LiquidEncode.encode_type left_ty in
      compile depth env arg @
      [ ii (RIGHT (left_ty, constr)) ]
    | Prim_Right, _ -> assert false

    (* catch the special case of [a;b;c] where
       the ending NIL is not annotated with a type *)
    | Prim_Cons, [ { ty } as arg; { ty = Tunit } ] ->
      let ty = LiquidEncode.encode_type ty in
      let arg = compile (depth+1) env arg in
      [ push ~loc (Tlist ty) (CList[]) ] @ arg @ [ ii CONS ]

    (* Should be removed in LiquidCheck *)
    | Prim_unknown, _
    | Prim_list_rev, _ -> assert false

    (* Should have disappeared *)
    | Prim_unused _, _ -> assert false
    | (Prim_coll_find|Prim_coll_update|Prim_coll_mem|Prim_coll_size), _ ->
      assert false

    | ( Prim_eq|Prim_neq|Prim_lt|Prim_le|Prim_gt|Prim_ge
      | Prim_compare|Prim_add|Prim_sub|Prim_mul|Prim_ediv|Prim_map_find
      | Prim_map_update|Prim_map_add|Prim_map_remove
      | Prim_map_mem
      | Prim_set_update|Prim_set_add|Prim_set_remove
      | Prim_set_mem|Prim_Some
      | Prim_string_concat|Prim_bytes_concat|Prim_concat|Prim_concat_two
      | Prim_string_size|Prim_bytes_size
      | Prim_string_sub|Prim_bytes_sub|Prim_slice
      | Prim_create_account
      | Prim_blake2b|Prim_sha256|Prim_sha512|Prim_pack
      | Prim_hash_key|Prim_check|Prim_default_account|Prim_list_size
      | Prim_set_size|Prim_map_size|Prim_or|Prim_and|Prim_xor
      | Prim_not|Prim_abs|Prim_int|Prim_neg|Prim_lsr|Prim_lsl|Prim_is_nat
      | Prim_exec|Prim_Cons|Prim_set_delegate|Prim_address),_ ->
      let _depth, args_code = compile_args depth env args in
      let prim_code = match prim, List.length args with
        | Prim_eq, 2 -> [ ii COMPARE; ii EQ ]
        | Prim_neq, 2 -> [ ii COMPARE; ii NEQ ]
        | Prim_lt, 2 -> [ ii COMPARE; ii LT ]
        | Prim_le, 2 -> [ ii COMPARE; ii LE ]
        | Prim_gt, 2 -> [ ii COMPARE; ii GT ]
        | Prim_ge, 2 -> [ ii COMPARE; ii GE ]
        | Prim_compare, 2 -> [ ii COMPARE ]
        | Prim_add, 2 -> [ ii ADD ]
        | Prim_sub, 2 -> [ ii SUB ]
        | Prim_mul, 2 -> [ ii MUL ]
        | Prim_ediv, 2 -> [ ii EDIV ]
        | Prim_map_find, 2 -> [ ii GET ]
        | Prim_map_update, 3 -> [ ii UPDATE ]
        | Prim_map_add, 3 -> [dip ~loc 1 [ii SOME]; ii UPDATE ]
        | Prim_map_remove, 2 ->
          let ty = match args with
            | [_; { ty = (Tmap (_, ty) | Tbigmap (_, ty)) }] -> ty
            | _ -> assert false
          in
          [dip ~loc 1 [push ~loc (Toption ty) CNone]; ii UPDATE ]
        | Prim_map_mem, 2 -> [ ii MEM ]

        | Prim_set_update, 3 -> [ ii UPDATE ]
        | Prim_set_add, 2 -> [dip ~loc 1 [push ~loc Tbool (CBool true)]; ii UPDATE ]
        | Prim_set_remove, 2 -> [dip ~loc 1 [push ~loc Tbool (CBool false)]; ii UPDATE ]
        | Prim_set_mem, 2 -> [ ii MEM ]

        | Prim_Some, 1 -> [ ii SOME ]
        | Prim_string_concat, 1 -> [ ii CONCAT ]
        | Prim_bytes_concat, 1 -> [ ii CONCAT ]

        | Prim_address, 1 -> [ ii ADDRESS ]
        | Prim_create_account, 4 -> [ ii CREATE_ACCOUNT; ii PAIR ]
        | Prim_blake2b, 1 -> [ ii BLAKE2B ]
        | Prim_sha256, 1 -> [ ii SHA256 ]
        | Prim_sha512, 1 -> [ ii SHA512 ]
        | Prim_pack, 1 -> [ ii PACK ]
        | Prim_hash_key, 1 -> [ ii HASH_KEY ]
        | Prim_check, 3 -> [ ii CHECK_SIGNATURE ]
        | Prim_default_account, 1 -> [ ii IMPLICIT_ACCOUNT ]
        | Prim_set_delegate, 1 -> [ ii SET_DELEGATE ]
        | Prim_list_size, 1 -> [ ii SIZE ]
        | Prim_set_size, 1 -> [ ii SIZE ]
        | Prim_map_size, 1 -> [ ii SIZE ]

        | Prim_Cons, 2 -> [ ii CONS ]
        | Prim_or, 2 -> [ ii OR ]
        | Prim_and, 2 -> [ ii AND ]
        | Prim_xor, 2 -> [ ii XOR ]
        | Prim_not, 1 -> [ ii NOT ]
        | Prim_abs, 1 -> [ ii ABS; ii INT ]
        | Prim_is_nat, 1 -> [ ii ISNAT ]
        | Prim_int, 1 -> [ ii INT ]
        | Prim_neg, 1 -> [ ii NEG ]
        | Prim_lsr, 2 -> [ ii LSR ]
        | Prim_lsl, 2 -> [ ii LSL ]

        | Prim_exec, 2 -> [ ii EXEC ]

        | Prim_string_size, 1 -> [ ii SIZE ]
        | Prim_bytes_size, 1 -> [ ii SIZE ]

        | Prim_string_sub, 3 -> [ ii SLICE ]
        | Prim_bytes_sub, 3 -> [ ii SLICE ]

        | (Prim_eq|Prim_neq|Prim_lt|Prim_le|Prim_gt|Prim_ge
          | Prim_compare|Prim_add|Prim_sub|Prim_mul|Prim_ediv|Prim_map_find
          | Prim_map_update|Prim_map_add|Prim_map_remove
          | Prim_map_mem
          | Prim_set_update|Prim_set_add|Prim_set_remove
          | Prim_set_mem|Prim_Some
          | Prim_string_size|Prim_bytes_size
          | Prim_string_sub|Prim_bytes_sub
          | Prim_string_concat|Prim_bytes_concat
          | Prim_create_account
          | Prim_blake2b|Prim_sha256|Prim_sha512|Prim_pack
          | Prim_hash_key|Prim_check|Prim_default_account|Prim_list_size
          | Prim_set_size|Prim_map_size|Prim_or|Prim_and|Prim_xor
          | Prim_not|Prim_abs|Prim_int|Prim_neg|Prim_lsr|Prim_lsl|Prim_is_nat
          | Prim_exec|Prim_Cons|Prim_set_delegate|Prim_address),n ->
          Printf.eprintf "Primitive %S: wrong number of args(%d)\n%!"
            (LiquidTypes.string_of_primitive prim)
            n;
          assert false
        (*                           | prim, args -> *)

        | (Prim_unknown|Prim_tuple_get
          | Prim_tuple_set|Prim_tuple
          | Prim_self|Prim_balance|Prim_now|Prim_amount|Prim_gas
          | Prim_Left|Prim_Right|Prim_source|Prim_sender|Prim_unused _
          | Prim_coll_find|Prim_coll_update|Prim_coll_mem
          | Prim_coll_size|Prim_list_rev|Prim_slice
          | Prim_concat|Prim_concat_two), _ ->
          (* already filtered out *)
          Printf.eprintf "Primitive %S ?\n%!"
            (LiquidTypes.string_of_primitive prim)
          ;
          assert false

      in
      args_code @ prim_code

  (* Compile a tuple update x.(0) <- y *)
  and compile_tuple_set ~loc last depth env n y =
    let ii = ii ~loc in
    if n = 0 then
      if last then
        [ ii DROP ]
        @ compile (depth-1) env y
      else
        [ ii @@ CDR None ] @ compile depth env y @ [ ii PAIR ]
    else
      [ ii (DUP 1); ii @@ CAR None; ii SWAP; ii @@ CDR None ] @
      compile_tuple_set last ~loc (depth+1) env (n-1) y @
      [ ii SWAP; ii PAIR ]

  (* Compile arguments of an apply *)
  and compile_args depth env args =
    match args with
    | [] -> depth,[]
    | arg :: args ->
      let (depth, args) = compile_args depth env args in
      let arg = compile depth env arg in
      depth+1, args @ arg

  (* Compile a record update x.f <- y *)
  and compile_record_set ~loc depth env fields field_name y =
    let ii = ii ~loc in
    match fields with
    | [] | [_] -> assert false
    | [f1; f2] when field_name = f2 ->
      [ ii @@ CAR (Some f1) ] @
      compile depth env y @
      [ ii SWAP; ii @@ RECORD (f1, Some f2) ]
    | [f1; f2] when field_name = f1 ->
      [ ii @@ CDR (Some f2) ] @
      compile depth env y @
      [ ii @@ RECORD (f1, Some f2) ]
    | [_; _] -> assert false
    | f :: fields when field_name = f ->
      [ ii @@ CDR None ] @
      compile depth env y @
      [ ii @@ RECORD (f, None) ]
    | f :: fields ->
      [ ii (DUP 1); ii @@ CAR (Some f); ii SWAP; ii @@ CDR None ] @
      compile_record_set ~loc (depth + 1) env fields field_name y @
      [ ii SWAP; ii @@ RECORD (f, None) ]

  (* Compile a tupe (x, y, z, ...) *)
  and compile_tuple ~loc depth env args =
    match args with
    | []  -> assert false
    | [_] -> assert false
    | arg :: args ->
      let arg = compile depth env arg in
      let args = compile_tuple1 ~loc depth env args in
      arg @ args

  and compile_tuple1 ~loc depth env args =
    match args with
    | [] -> []
    | arg :: args ->
      let arg = compile (depth+1) env arg in
      let args = compile_tuple1 ~loc depth env args in
      arg @ [ ii ~loc PAIR ] @ args

  and compile_record_rev ~loc depth env fields =
    match fields with
    | []  -> assert false
    | [_] -> assert false
    | [label1, exp1; label2, exp2] ->
      let exp2 = compile depth env exp2 in
      let exp1 = compile (depth+1) env exp1 in
      exp2 @ exp1 @ [ ii ~loc (RECORD (label1, Some label2)) ]
    | (label, exp) :: fields ->
      let rest = compile_record_rev ~loc depth env fields in
      let exp = compile (depth+1) env exp in
      rest @ exp @ [ ii ~loc (RECORD (label, None)) ]

  (* Compile a record construct { x = ...; y = ... } *)
  and compile_record ~loc depth env fields =
    compile_record_rev ~loc depth env ((* List.rev *) fields)

  (* Top-level compile an instruction *)
  and compile depth env e =
    let code = compile_desc depth env ~loc:e.loc e.desc in
    match e.desc with
    | If _ | MatchVariant _ | MatchNat _
    | MatchOption _ | MatchList _ | Loop _ | Fold _
    | Map _ | MapFold _ ->
      (* For Michelson instructions that do not accept name
         annotations, we add a RENAME instruction after. *)
      compile_name ~annotafter:true e.name code
    | _ ->
      compile_name ~annotafter:false e.name code

  (* Compile a name *)
  and compile_name ~annotafter name code =
    if annotafter then
      (* Insert a RENAME @name instruction *)
      match name with
      | Some name ->
        code @ [ii ~loc:LiquidLoc.noloc (RENAME (Some (sanitize_name name)))]
      | None -> code
    else
      (* Change in place the name associated with the instruction,
         these are used by the Michelson pretty printer (or
         translator) to produce variable annotations @name. *)
      match List.rev code with
      | c :: _ when name <> None ->
        c.loc_name <- sanitize_opt name;
        code
      | _ -> code

  (* Argument names (for instance in bodies of lambda,
     pattern-matching, iter, etc.) are compiled as just a RENAME
     instruction as this is the only allowed for in Michelson. *)
  and compile_arg_name arg_name =
    [ii ~loc:LiquidLoc.noloc (RENAME (Some (sanitize_name arg_name)))]

  in

  (* This is how we compile a contract: unpair the pair (parameter,
     storage) to have a stack with parameter :: storage (parameter on
     top). *)

  let env = StringMap.empty in
  let env = StringMap.add storage_name 0 env in
  let env = StringMap.add parameter_name 1 env in
  let depth = 2 in

  let exprs = compile depth env code in
  let loc = LiquidLoc.noloc in

  (* replace ( parameter, storage ) with parameter :: storage *)
  let header = [
    dup ~loc 1;
    dip ~loc 1 [ ii ~loc @@ CDR None ];
    ii ~loc @@ CAR None;
  ]
  in
  (* at the end of the code, drop everything excepted for the top-most
     element *)
  let trailer = drop_stack ~loc 1 depth in
  seq (header @ exprs @ trailer)

(* FAILWITH must appear in tail position in Michelson, this function
   removes instructions that appear after FAILWITH in a code block *)
and finalize_fail_pre ({ ins } as e) =
  { e with
    ins =
      match ins with
      | SEQ expr -> SEQ (finalize_fail_seq [] expr)
      | IF (e1, e2) -> IF (finalize_fail_pre e1, finalize_fail_pre e2)
      | IF_NONE (e1, e2) -> IF_NONE (finalize_fail_pre e1, finalize_fail_pre e2)
      | IF_LEFT (e1, e2) -> IF_LEFT (finalize_fail_pre e1, finalize_fail_pre e2)
      | IF_CONS (e1, e2) -> IF_CONS (finalize_fail_pre e1, finalize_fail_pre e2)
      | DIP (n, e) -> DIP (n, finalize_fail_pre e)
      | LOOP e -> LOOP (finalize_fail_pre e)
      | ITER e -> ITER (finalize_fail_pre e)
      | MAP e -> MAP (finalize_fail_pre e)
      | LAMBDA (arg_type, res_type, e) ->
        LAMBDA (arg_type, res_type, finalize_fail_pre e)
      | _ -> ins
  }

and end_fails = function
  | FAILWITH -> true
  | SEQ exprs ->
    (match List.rev exprs with
     | e :: _ -> end_fails e.ins
     | [] -> false)
  | IF (e1, e2) | IF_NONE (e1, e2) | IF_LEFT (e1, e2) | IF_CONS (e1, e2) ->
    end_fails e1.ins && end_fails e2.ins
  | DIP (_, e) -> end_fails e.ins
  | _ -> false

and finalize_fail_seq acc exprs =
  match exprs with
  | [] -> List.rev acc
  | e :: exprs ->
    let e = finalize_fail_pre e in
    if end_fails e.ins then List.rev (e :: acc)
    else finalize_fail_seq (e :: acc) exprs

(*
let translate filename ~peephole contract =
  let pre_code = translate_code contract.code in
  begin
    let pre_optim_code = LiquidEmit.emit pre_code in
    let s =
      LiquidPrinter.Michelson.string_of_contract
        { contract with code = pre_optim_code } in
    FileString.write_file (filename ^ ".mic") s
  end;
  let pre_code =
    if peephole then
      LiquidPeephole.simplify_pre pre_code
    else pre_code in
  let code = LiquidEmit.emit pre_code in
  { contract with code }
 *)
and translate contract =
  let mic_storage = contract.storage in
  match contract.entries with
  | [{ entry_sig = { parameter = mic_parameter; parameter_name; storage_name };
       code }] ->
    { mic_parameter;
      mic_storage;
      mic_code =  translate_code ~parameter_name ~storage_name code
                  |> finalize_fail_pre }
  | _ -> assert false
