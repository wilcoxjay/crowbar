type src = Random of Random.State.t | Fd of Unix.file_descr
type state =
  {
    chan : src;
    buf : Bytes.t;
    mutable offset : int;
    mutable len : int
  }

type 'a printer = Format.formatter -> 'a -> unit

type 'a strat =
  | Choose of 'a gen list
  | Map : ('f, 'a) gens * 'f -> 'a strat
  | Bind : 'a gen * ('a -> 'b gen) -> 'b strat
  | Option : 'a gen -> 'a option strat
  | List : 'a gen -> 'a list strat
  | List1 : 'a gen -> 'a list strat
  | Unlazy of 'a gen Lazy.t
  | Primitive of (state -> 'a)
  | Print of 'a printer * 'a gen
  | Sized of int * 'a gen

and 'a gen =
  { strategy: 'a strat;
    small_examples: 'a list; }

and ('k, 'res) gens =
  | [] : ('res, 'res) gens
  | (::) : 'a gen * ('k, 'res) gens -> ('a -> 'k, 'res) gens

type nonrec +'a list = 'a list = [] | (::) of 'a * 'a list

exception BadTest of string
exception FailedTest of unit printer

let unlazy f = { strategy = Unlazy f; small_examples = [] }

let fix f =
  let rec lazygen = lazy (f (unlazy lazygen)) in
  unlazy lazygen

let map (type f) (type a) (gens : (f, a) gens) (f : f) =
  let rec smalls: type f a. (f, a) gens -> f -> a list = fun gens f ->
    match gens with
    | [] -> [f]
    | g :: gs ->
       List.concat_map (fun x ->
           match f x with
           | exception (BadTest _) -> []
           | v -> smalls gs v)
         g.small_examples
  in 
  { strategy = Map (gens, f); small_examples = smalls gens f }

let dynamic_bind m f = {strategy = Bind(m, f); small_examples = [] }

let const x = map [] x
let choose gens = { strategy = Choose gens; small_examples = List.concat_map (fun x -> x.small_examples) gens }
let option gen = { strategy = Option gen; small_examples = [None] @ List.map (fun x -> Some x) gen.small_examples }
let list gen = { strategy = List gen; small_examples = [[]] }
let list1 gen = { strategy = List1 gen; small_examples = List.map (fun x -> [x]) gen.small_examples }
let primitive f exs = { strategy = Primitive f; small_examples = exs }
let sized n gen = { strategy = Sized (n, gen); small_examples = gen.small_examples }

let pair gena genb =
  map (gena :: genb :: []) (fun a b -> (a, b))

let concat_gen_list sep l =
  match l with
  | h::t -> List.fold_left (fun acc e ->
      map [acc; sep; e] (fun acc sep e -> acc ^ sep ^ e)
    ) h t
  | [] -> const ""

let with_printer pp gen = {strategy = Print (pp, gen); small_examples = gen.small_examples }

let result gena genb =
  choose [
    map [gena] (fun va -> Ok va);
    map [genb] (fun vb -> Error vb);
  ]


let pp = Format.fprintf
let pp_int ppf n = pp ppf "%d" n
let pp_int32 ppf n = pp ppf "%s" (Int32.to_string n)
let pp_int64 ppf n = pp ppf "%s" (Int64.to_string n)
let pp_float ppf f = pp ppf "%f" f
let pp_bool ppf b = pp ppf "%b" b
let pp_char ppf c = pp ppf "%c" c
let pp_uchar ppf c = pp ppf "U+%04x" (Uchar.to_int c)
let pp_string ppf s = pp ppf "\"%s\"" (String.escaped s)
let pp_list pv ppf l =
  pp ppf "@[<hv 1>[%a]@]"
     (Format.pp_print_list ~pp_sep:(fun ppf () -> pp ppf ";@ ") pv) l
let pp_option pv ppf = function
  | None ->
      Format.fprintf ppf "None"
  | Some x ->
      Format.fprintf ppf "(Some %a)" pv x

let guard = function
  | true -> ()
  | false -> raise (BadTest "guard failed")
let bad_test () = raise (BadTest "bad test")
let nonetheless = function
  | None -> bad_test ()
  | Some a -> a

let get_data chan buf off len =
  match chan with
  | Random rand ->
     for i = off to off + len - 1 do
       Bytes.set buf i (Char.chr (Random.State.bits rand land 0xff))
     done;
     len - off
  | Fd ch ->
     Unix.read ch buf off len

let refill src =
  assert (src.offset <= src.len);
  let remaining = src.len - src.offset in
  (* move remaining data to start of buffer *)
  Bytes.blit src.buf src.offset src.buf 0 remaining;
  src.len <- remaining;
  src.offset <- 0;
  let read = get_data src.chan src.buf remaining (Bytes.length src.buf - remaining) in
  if read = 0 then
    raise (BadTest "premature end of file")
  else
    src.len <- remaining + read

let rec getbytes src n =
  assert (src.offset <= src.len);
  if n > Bytes.length src.buf then failwith "request too big";
  if src.len - src.offset >= n then
    let off = src.offset in
    (src.offset <- src.offset + n; off)
  else
    (refill src; getbytes src n)

let read_char src =
  let off = getbytes src 1 in
  Bytes.get src.buf off

let read_byte src =
  Char.code (read_char src)

let read_bool src =
  let n = read_byte src in
  n land 1 = 1

let bool = with_printer pp_bool (primitive read_bool [false; true])

let uint8 = with_printer pp_int (primitive read_byte [0; 1])
let int8 = with_printer pp_int (map [uint8] (fun n -> n - 128))

let read_uint16 src =
  let off = getbytes src 2 in
  EndianBytes.LittleEndian.get_uint16 src.buf off

let read_int16 src =
  let off = getbytes src 2 in
  EndianBytes.LittleEndian.get_int16 src.buf off

let uint16 = with_printer pp_int (primitive read_uint16 [0; 1])
let int16 = with_printer pp_int (primitive read_int16 [0; 1])

let read_int32 src =
  let off = getbytes src 4 in
  EndianBytes.LittleEndian.get_int32 src.buf off

let read_int64 src = 
  let off = getbytes src 8 in
  EndianBytes.LittleEndian.get_int64 src.buf off

let int32 = with_printer pp_int32 (primitive read_int32 [0l; 1l])
let int64 = with_printer pp_int64 (primitive read_int64 [0L; 1L])

let int =
  with_printer pp_int
    (if Sys.word_size <= 32 then
      map [int32] Int32.to_int
    else
      map [int64] Int64.to_int)

let float = with_printer pp_float (primitive (fun src ->
  let off = getbytes src 8 in
  EndianBytes.LittleEndian.get_double src.buf off) [0.])

let char = with_printer pp_char (primitive read_char ['a'])

(* maybe print as a hexdump? *)
let bytes = with_printer pp_string (primitive (fun src ->
  (* null-terminated, with '\001' as an escape code *)
  let buf = Bytes.make 64 '\255' in
  let rec read_bytes p =
    if p >= Bytes.length buf then p else
    match read_char src with
    | '\000' -> p
    | '\001' ->
       Bytes.set buf p (read_char src);
       read_bytes (p + 1)
    | c ->
       Bytes.set buf p c;
       read_bytes (p + 1) in
  let count = read_bytes 0 in
  Bytes.sub_string buf 0 count) [""])

let bytes_fixed n = with_printer pp_string (primitive (fun src ->
  let off = getbytes src n in
  Bytes.sub_string src.buf off n) [String.make n 'a'])

let choose_int n state =
  assert (n > 0);
  if n = 1 then
    0
  else if (n <= 0x100) then
    read_byte state mod n
  else if (n < 0x1000000) then
    Int32.(to_int (abs (rem (read_int32 state) (of_int n))))
  else
    Int64.(to_int (abs (rem (read_int64 state) (of_int n))))

let list_range ?(min=0) n =
  let rec go acc x n =
    if n <= 0
    then acc
    else go (x :: acc) (x - 1) (n - 1)
  in go [] (min + n - 1) n

let range ?(min=0) n =
  if n <= 0 then
    raise (Invalid_argument "Crowbar.range: argument n must be positive");
  if min < 0 then
    raise (Invalid_argument "Crowbar.range: argument min must be positive or null");
  with_printer pp_int (primitive (fun s -> min + choose_int n s) (list_range ~min (if n < 4 then n else 4)))

let uchar : Uchar.t gen =
  map [range 0x110000] (fun x ->
    guard (Uchar.is_valid x); Uchar.of_int x)
let uchar = with_printer pp_uchar uchar

let rec sequence = function
  g::gs -> map [g; sequence gs] (fun x xs -> x::xs)
| [] -> const []

let shuffle_arr arr =
  let n = Array.length arr in
  let gs = List.init n (fun i -> range ~min:i (n - i)) in
  map [sequence gs] @@ fun js ->
    js |> List.iteri (fun i j ->
      let t = arr.(i) in arr.(i) <- arr.(j); arr.(j) <- t);
    arr

let shuffle l = map [shuffle_arr (Array.of_list l)] Array.to_list

exception GenFailed of exn * Printexc.raw_backtrace * unit printer

let rec stratname : type a. a strat -> string =
  fun strat ->
  match strat with
  | Choose genlist -> Printf.sprintf "choose [%s]" (String.concat "; " (List.map (fun gen -> stratname (gen.strategy)) genlist))
  | Map (gens, _) -> Printf.sprintf "map [%s] ?" (String.concat "; " (gens_names gens))
  | Bind (g, _) -> Printf.sprintf "bind (%s) ?" (stratname g.strategy)
  | Option g -> Printf.sprintf "option (%s)" (stratname g.strategy)
  | List g -> Printf.sprintf "list (%s)" (stratname g.strategy)
  | List1 g -> Printf.sprintf "list1 (%s)" (stratname g.strategy)
  | Primitive _ -> "primitive"
  | Unlazy _ -> "unlazy"
  | Print (_, g) -> Printf.sprintf "print (%s)" (stratname g.strategy)
  | Sized (n, g) -> Printf.sprintf "sized %d (%s)" n (stratname g.strategy)
and gens_names : type k res. (k, res) gens -> string list = fun gens ->
    match gens with
    | [] -> []
    | g :: gs -> stratname g.strategy :: gens_names gs

let rec gens_lengths: type k res. (k, res) gens -> int list = fun gens ->
  match gens with
  | [] -> []
  | g :: gs -> List.length g.small_examples :: gens_lengths gs

let rec generate : type a . int -> state -> a gen -> a * unit printer =
  fun size input gen ->
  (* Printf.printf "generate size = %d strat = %s n_small = %d\n%!" size (stratname gen.strategy) (List.length gen.small_examples);  *)
  if size <= 1 && gen.small_examples <> []
  then begin
      (* print_string "successfully grabbing a small example from ";
      print_endline (stratname gen.strategy); *)
      let n = choose_int (List.length gen.small_examples) input in
      List.nth gen.small_examples n, fun ppf () -> pp ppf "?"
    end
  else begin
    if size < 0 then
      raise (BadTest "ran out of size and no small examples");
  match gen.strategy with
  | Choose gens ->
     (* FIXME: better distribution? *)
     (* FIXME: choices of size > 255? *)
     let n = choose_int (List.length gens) input in
     let v, pv = generate size input (List.nth gens n) in
     v, fun ppf () -> pp ppf "#%d %a" n pv ()
  | Map ([], k) ->
     k, fun ppf () -> pp ppf "?"
  | Map (gens, f) ->
     let v, pvs = gen_apply (size - 1) input gens f in
     begin match v with
       | Ok v -> v, pvs
       | Error (e, bt) -> raise (GenFailed (e, bt, pvs))
     end
  | Bind (m, f) ->
     let index, pv_index = generate (size - 1) input m in
     let a, pv = generate (size - 1) input (f index) in
     a, (fun ppf () -> pp ppf "(%a) => %a" pv_index () pv ())
  | Option gen ->
     if size < 1 then begin
         failwith "option small: impossible"
         (* None, fun ppf () -> pp ppf "None" *)
       end
     else if read_bool input then
       let v, pv = generate size input gen in
       Some v, fun ppf () -> pp ppf "Some (%a)" pv ()
     else
       None, fun ppf () -> pp ppf "None"
  | List gen ->
     let elems = generate_list size input gen in
     List.map fst elems,
       fun ppf () -> pp_list (fun ppf (_, pv) -> pv ppf ()) ppf elems
  | List1 gen ->
     let elems = generate_list1 size input gen in
     List.map fst elems,
       fun ppf () -> pp_list (fun ppf (_, pv) -> pv ppf ()) ppf elems
  | Primitive gen ->
     gen input, fun ppf () -> pp ppf "?"
  | Unlazy gen ->
     generate size input (Lazy.force gen)
  | Print (ppv, gen) ->
     let v, _ = generate size input gen in
     v, fun ppf () -> ppv ppf v
  | Sized (n, gen) ->
     generate n input gen
    end

and generate_list : type a . int -> state -> a gen -> (a * unit printer) list =
  fun size input gen ->
  (* Printf.printf "generate_list size = %d strat = %s n_small = %d\n%!" size (stratname gen.strategy) (List.length gen.small_examples); *)
  if size <= 1 then []
  else if read_bool input then
    generate_list1 size input gen
  else
    []

and generate_list1 : type a . int -> state -> a gen -> (a * unit printer) list =
  fun size input gen ->
  (* Printf.printf "generate_list1 size = %d strat = %s n_small = %d\n%!" size (stratname gen.strategy) (List.length gen.small_examples); *)

  let ans = generate (size/2) input gen in
  ans :: generate_list (size/2) input gen

and gen_apply :
    type k res . int -> state ->
       (k, res) gens -> k ->
       (res, exn * Printexc.raw_backtrace) result * unit printer =
  fun size state gens f ->
  (* 
  Printf.printf "generate_apply size = %d strats = [%s] n_small = [%s]\n%!"
    size
    (String.concat "; " (gens_names gens))
    (String.concat "; " (List.map string_of_int (gens_lengths gens))); *)
  let rec go :
    type k res . int -> state ->
       (k, res) gens -> k ->
       (res, exn * Printexc.raw_backtrace) result * unit printer list =
      fun size input gens -> 
      (* Printf.printf "gen_apply.go size = %d\n%!" size; *)
      match gens with
      | [] -> fun x -> Ok x, []
      | g :: gs -> fun f ->
        let v, pv = generate size input g in
        let res, pvs =
          match f v with
          | exception (BadTest _ as e) -> raise e
          | exception e ->
             Error (e, Printexc.get_raw_backtrace ()) , []
          | fv -> go size input gs fv in
        res, pv :: pvs in
  let v, pvs = go size state gens f in
  let pvs = fun ppf () ->
    match pvs with
    | [pv] ->
       pv ppf ()
    | pvs ->
       pp_list (fun ppf pv -> pv ppf ()) ppf pvs in
  v, pvs


let fail s = raise (FailedTest (fun ppf () -> pp ppf "%s" s))

let failf format =
  Format.kasprintf fail format

let check = function
  | true -> ()
  | false -> raise (FailedTest (fun ppf () -> pp ppf "check false"))

let check_pred ~pp:pv ~pred_name pred x =
  if not (pred x)
  then raise (FailedTest (fun ppf () -> pp ppf "@[<hv>predicate %s failed on@ %a@ @]" pred_name pv x))

let check_eq ?pp:pv ?cmp ?eq a b =
  let pass = match eq, cmp with
    | Some eq, _ -> eq a b
    | None, Some cmp -> cmp a b = 0
    | None, None ->
       Stdlib.compare a b = 0 in
  if pass then
    ()
  else
    raise (FailedTest (fun ppf () ->
      match pv with
      | None -> pp ppf "different"
      | Some pv -> pp ppf "@[<hv>%a@ !=@ %a@]" pv a pv b))

let () = Printexc.record_backtrace true

type test = Test : string * ('f, unit) gens * 'f -> test

type test_status =
  | TestPass of unit printer
  | BadInput of string
  | GenFail of exn * Printexc.raw_backtrace * unit printer
  | TestExn of exn * Printexc.raw_backtrace * unit printer
  | TestFail of unit printer * unit printer

let run_once (gens : (_, unit) gens) f state =
  match gen_apply 20 state gens f with
  | Ok (), pvs -> TestPass pvs
  | Error (FailedTest p, _), pvs -> TestFail (p, pvs)
  | Error (e, bt), pvs -> TestExn (e, bt, pvs)
  | exception (BadTest s) -> BadInput s
  | exception (GenFailed (e, bt, pvs)) -> GenFail (e, bt, pvs)

let classify_status = function
  | TestPass _ -> `Pass
  | BadInput _ -> `Bad
  | GenFail _ -> `Fail (* slightly dubious... *)
  | TestExn _ | TestFail _ -> `Fail

let print_status ppf status =
  let print_ex ppf (e, bt) =
    pp ppf "%s" (Printexc.to_string e);
    bt
    |> Printexc.raw_backtrace_to_string
    |> Str.split (Str.regexp "\n")
    |> List.iter (pp ppf "@,%s") in
  match status with
  | TestPass pvs ->
     pp ppf "When given the input:@.@[<v 4>@,%a@,@]@.the test passed."
        pvs ()
  | BadInput s ->
     pp ppf "The testcase was invalid:@.%s" s
  | GenFail (e, bt, pvs) ->
     pp ppf "When given the input:@.@[<4>%a@]@.the testcase generator threw an exception:@.@[<v 4>@,%a@,@]"
        pvs ()
        print_ex (e, bt)
  | TestExn (e, bt, pvs) ->
     pp ppf "When given the input:@.@[<v 4>@,%a@,@]@.the test threw an exception:@.@[<v 4>@,%a@,@]"
        pvs ()
        print_ex (e, bt)
  | TestFail (err, pvs) ->
     pp ppf "When given the input:@.@[<v 4>@,%a@,@]@.the test failed:@.@[<v 4>@,%a@,@]"
        pvs ()
        err ()

let src_of_seed seed =
  (* try to make this independent of word size *)
  let seed = Int64.( [|
       to_int (logand (of_int 0xffff) seed);
       to_int (logand (of_int 0xffff) (shift_right seed 16));
       to_int (logand (of_int 0xffff) (shift_right seed 32));
       to_int (logand (of_int 0xffff) (shift_right seed 48)) |]) in
  Random (Random.State.make seed)

let run_test ~mode ~silent ?(verbose=false) (Test (name, gens, f)) =
  let show_status_line ?(clear=false) stat =
    Printf.printf "%s: %s\n" name stat;
    if clear then print_newline ();
    flush stdout in
  let ppf = Format.std_formatter in
  if not silent && Unix.isatty Unix.stdout then
    show_status_line ~clear:false "....";
  let status = match mode with
  | `Once state ->
     run_once gens f state
  | `Repeat iters ->
     let worst_status = ref (TestPass (fun _ () -> ())) in
     let npass = ref 0 in
     let nbad = ref 0 in
     while !npass < iters && classify_status !worst_status = `Pass do
       let seed = Random.int64 Int64.max_int in
       let state = { chan = src_of_seed seed;
                     buf = Bytes.make 256 '0';
                     offset = 0; len = 0 } in
       let status = run_once gens f state in
       begin match classify_status status with
       | `Pass -> incr npass
       | `Bad -> incr nbad
       | `Fail ->
          (* if not silent then pp ppf "failed with seed %016LX" seed; *)
          worst_status := status
       end;
     done;
     let status = !worst_status in
     status in
  if silent && verbose && classify_status status = `Fail then begin
         show_status_line
           ~clear:true "FAIL";
         pp ppf "%a@." print_status status;
  end;
  if not silent then begin
      match classify_status status with
      | `Pass ->
         show_status_line
           ~clear:true "PASS";
         if verbose then pp ppf "%a@." print_status status
      | `Fail ->
         show_status_line
           ~clear:true "FAIL";
         pp ppf "%a@." print_status status;
      | `Bad ->
         show_status_line
           ~clear:true "BAD";
         pp ppf "%a@." print_status status;
    end;
  status

exception TestFailure
let run_all_tests file verbosity infinity tests =
  match file, infinity with
  | None, false ->
    (* limited-run QuickCheck mode *)
    let failures = ref 0 in
    let () = tests |> List.iter (fun t ->
        match (run_test ~mode:(`Repeat 5000) ~silent:false t |> classify_status) with
        | `Fail -> failures := !failures + 1
        | _ -> ()
      )
    in
    !failures
  | None, true ->
    (* infinite QuickCheck mode *)
     let rec go ntests alltests tests = match tests with
       | [] ->
          go ntests alltests alltests
       | t :: rest ->
          if ntests mod 10000 = 0 then Printf.eprintf "\r%d%!" ntests;
          match classify_status (run_test ~mode:(`Once { chan = src_of_seed (Random.int64 (Int64.max_int));
                     buf = Bytes.make 256 '0';
                     offset = 0; len = 0 })  ~silent:true ~verbose:true t) with
          | `Fail -> Printf.printf "%d tests passed before first failure\n%!" ntests
          | _ -> go (ntests + 1) alltests rest in
     let () = go 0 tests tests in
     1
  | Some file, _ ->
    (* AFL mode *)
    let verbose = List.length verbosity > 0 in
    let () = AflPersistent.run (fun () ->
         let fd = Unix.openfile file [Unix.O_RDONLY] 0o000 in
         let state = { chan = Fd fd; buf = Bytes.make 256 '0';
                       offset = 0; len = 0 } in
         let status =
           try run_test ~mode:(`Once state) ~silent:false ~verbose @@
             List.nth tests (choose_int (List.length tests) state)
           with
           BadTest s -> BadInput s
         in
         Unix.close fd;
         match classify_status status with
         | `Pass | `Bad -> ()
         | `Fail ->
            Printexc.record_backtrace false;
            raise TestFailure)
    in
    0 (* failures come via the exception mechanism above *)

let last_generated_name = ref 0
let generate_name () =
  incr last_generated_name;
  "test" ^ string_of_int !last_generated_name

let registered_tests = ref []

let add_test ?name gens f =
  let name = match name with
    | None -> generate_name ()
    | Some name -> name in
  registered_tests := Test (name, gens, f) :: !registered_tests

(* cmdliner stuff *)

let randomness_file =
  let doc = "A file containing some bytes, consulted in constructing test cases.  \
    When `afl-fuzz` is calling the test binary, use `@@` to indicate that \
    `afl-fuzz` should put its test case here \
    (e.g. `afl-fuzz -i input -o output ./my_crowbar_test @@`).  Re-run a test by \
    supplying the test file here \
    (e.g. `./my_crowbar_test output/crashes/id:000000`).  If no file is \
    specified, the test will use OCaml's Random module as a source of \
    randomness for a predefined number of rounds." in
  Cmdliner.Arg.(value & pos 0 (some file) None & info [] ~doc ~docv:"FILE")

let verbosity =
  let doc = "Print information on each test as it's conducted." in
  Cmdliner.Arg.(value & flag_all & info ["v"; "verbose"] ~doc ~docv:"VERBOSE")

let infinity =
  let doc = "In non-AFL (quickcheck) mode, continue running until a test failure is \
             discovered.  No attempt is made to track which tests have already been run, \
             so some tests may be repeated, and if there are no failures reachable, the \
             test will never terminate without outside intervention." in
  Cmdliner.Arg.(value & flag & info ["i"] ~doc ~docv:"INFINITE")

let crowbar_info = Cmdliner.Term.info @@ Filename.basename Sys.argv.(0)

let () =
  print_endline "testy test"

let () =
  at_exit (fun () ->
      let t = !registered_tests in
      registered_tests := [];
      match t with
      | [] -> ()
      | t ->
        let cmd = Cmdliner.Term.(const run_all_tests $ randomness_file $ verbosity $
                                 infinity $ const (List.rev t)) in
        match Cmdliner.Term.eval ~catch:false (cmd, crowbar_info) with
        | `Ok 0 -> exit 0
        | `Ok _ -> exit 1
        | n -> Cmdliner.Term.exit n
    )
