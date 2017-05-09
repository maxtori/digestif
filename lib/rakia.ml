let () = Printexc.record_backtrace true

module Bi         = Digestif_bigstring
module By         = Digestif_bytes
module Native     = Rakia_native

module type S =
sig
  type ctx

  val digest_size : int

  module Bigstring :
  sig
    type buffer = Native.ba
    type t = Native.ba

    val init        : unit -> ctx
    val feed        : ctx -> buffer -> unit
    val get         : ctx -> t

    val digest      : buffer -> t
    val digestv     : buffer list -> t
    val hmac        : key:buffer -> buffer -> t
    val hmacv       : key:buffer -> buffer list -> t

    val compare     : t -> t -> int
    val eq          : t -> t -> bool
    val neq         : t -> t -> bool

    val pp          : Format.formatter -> t -> unit
    val of_hex      : buffer -> t
    val to_hex      : t -> buffer
  end

  module Bytes :
  sig
    type buffer = Native.st
    type t = Native.st

    val init        : unit -> ctx
    val feed        : ctx -> buffer -> unit
    val get         : ctx -> t

    val digest      : buffer -> t
    val digestv     : buffer list -> t
    val hmac        : key:buffer -> buffer -> t
    val hmacv       : key:buffer -> buffer list -> t

    val compare : t -> t -> int
    val eq      : t -> t -> bool
    val neq     : t -> t -> bool

    val pp      : Format.formatter -> t -> unit
    val of_hex  : buffer -> t
    val to_hex  : t -> buffer
  end
end

module type Foreign =
sig
  open Native

  module Bigstring :
  sig
    val init     : ctx -> unit
    val update   : ctx -> ba -> int -> int -> unit
    val finalize : ctx -> ba -> int -> unit
  end

  module Bytes :
  sig
    val init     : ctx -> unit
    val update   : ctx -> st -> int -> int -> unit
    val finalize : ctx -> st -> int -> unit
  end

  val ctx_size   : unit -> int
end

module type Desc =
sig
  val block_size  : int
  val digest_size : int
end

module type Convenience =
sig
  type t

  val compare : t -> t -> int
  val eq      : t -> t -> bool
  val neq     : t -> t -> bool
end

module PrettyPrint (S : sig type t val create : int -> t val iter : (char -> unit) -> t -> unit val set : t -> int -> char -> unit val get : t -> int -> char end) (D : Desc) =
struct
  let to_hex hash =
    let res = S.create (D.digest_size * 2) in

    let chr x = match x with
      | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 -> Char.chr (48 + x)
      | _ -> Char.chr (65 + (x - 10))
    in

    for i = 0 to D.digest_size - 1
    do
      let v = Char.code (S.get hash i) in
      S.set res (i * 2) (chr (v lsr 4));
      S.set res (i * 2 + 1) (chr (v land 0x0F));
    done;

    res

  let fold_s f a s =
    let r = ref a in
    S.iter (fun x -> r := f !r x) s; !r

  let of_hex hex =
    let code x = match x with
      | '0' .. '9' -> Char.code x - 48
      | 'A' .. 'F' -> Char.code x - 55
      | 'a' .. 'z' -> Char.code x - 87
      | _ -> raise (Invalid_argument "of_hex")
    in

    let wsp = function ' ' | '\t' | '\r' | '\n' -> true | _ -> false in

    fold_s
      (fun (res, i, acc) -> function
         | chr when wsp chr -> (res, i, acc)
         | chr ->
           match acc, code chr with
           | None, x -> (res, i, Some (x lsl 4))
           | Some y, x -> S.set res i (Char.unsafe_chr (x lor y)); (res, succ i, None))
      (S.create D.digest_size, 0, None)
      hex
    |> function (_, _, Some _)  -> raise (Invalid_argument "of_hex")
              | (res, i, _) ->
                if i = D.digest_size
                then res
                else (for i = i to D.digest_size - 1 do S.set res i '\000' done; res)

  let pp fmt hash =
    for i = 0 to D.digest_size - 1
    do Format.fprintf fmt "%02x" (Char.code (S.get hash i)) done
end

module Core (F : Foreign) (D : Desc) =
struct
  let block_size  = D.block_size
  and digest_size = D.digest_size
  and ctx_size    = F.ctx_size ()

  module Bytes =
  struct
    type buffer = Native.st

    include (By : Convenience with type t = Native.st)
    include PrettyPrint (By) (D)

    let init () =
      let t = Bi.create ctx_size in
      ( F.Bytes.init t; t )

    let feed t buf =
      F.Bytes.update t buf 0 (By.length buf)

    let get t =
      let res = By.create digest_size in
      F.Bytes.finalize t res 0;
      res

    let digest buf =
      let t = init () in ( feed t buf; get t )

    let digestv bufs =
      let t = init () in ( List.iter (feed t) bufs; get t )
  end

  module Bigstring =
  struct
    type buffer = Native.ba

    include (Bi : Convenience with type t = Native.ba)
    include PrettyPrint (Bi) (D)

    let init () =
      let t = Bi.create ctx_size in
      ( F.Bigstring.init t; t )

    let feed t buf =
      F.Bigstring.update t buf 0 (Bi.length buf)

    let get t =
      let res = Bi.create digest_size in
      F.Bigstring.finalize t res 0;
      res

    let digest buf =
      let t = init () in ( feed t buf; get t )

    let digestv bufs =
      let t = init () in ( List.iter (feed t) bufs; get t )
  end
end

module Make (F : Foreign) (D : Desc) =
struct
  type ctx = Native.ctx

  module C = Core (F) (D)

  let block_size  = C.block_size
  and digest_size = C.digest_size
  and ctx_size    = C.ctx_size

  module Bytes =
  struct
    include C.Bytes

    let opad = By.init C.block_size (fun _ -> '\x5c')
    let ipad = By.init C.block_size (fun _ -> '\x36')

    let rec norm key =
      match Pervasives.compare (By.length key) C.block_size with
      | 1  -> norm (C.Bytes.digest key)
      | -1 -> By.rpad key C.block_size '\000'
      | _  -> key

    let hmacv ~key msg =
      let key = norm key in
      let outer = Native.XOR.Bytes.xor key opad in
      let inner = Native.XOR.Bytes.xor key ipad in
      C.Bytes.digestv [ outer; C.Bytes.digestv (inner :: msg) ]

    let hmac ~key msg = hmacv ~key [ msg ]
  end

  module Bigstring =
  struct
    include C.Bigstring

    let opad = Bi.init C.block_size (fun _ -> '\x5c')
    let ipad = Bi.init C.block_size (fun _ -> '\x36')

    let rec norm key =
      match Pervasives.compare (Bi.length key) C.block_size with
      | 1  -> norm (C.Bigstring.digest key)
      | -1 -> Bi.rpad key C.block_size '\000'
      | _  -> key

    let hmacv ~key msg =
      let key = norm key in
      let outer = Native.XOR.Bigstring.xor key opad in
      let inner = Native.XOR.Bigstring.xor key ipad in
      C.Bigstring.digestv [ outer; C.Bigstring.digestv (inner :: msg) ]

    let hmac ~key msg = hmacv ~key [ msg ]
  end
end

module MD5     : S = Make (Native.MD5)    (struct let (digest_size, block_size) = (16, 64) end)
module SHA1    : S = Make (Native.SHA1)   (struct let (digest_size, block_size) = (20, 64) end)
module SHA224  : S = Make (Native.SHA224) (struct let (digest_size, block_size) = (28, 64) end)
module SHA256  : S = Make (Native.SHA256) (struct let (digest_size, block_size) = (32, 64) end)
module SHA384  : S = Make (Native.SHA384) (struct let (digest_size, block_size) = (48, 128) end)
module SHA512  : S = Make (Native.SHA512) (struct let (digest_size, block_size) = (64, 128) end)

module Make_BLAKE2B (F : Foreign) (D : Desc) : S =
struct
  type ctx = Native.ctx

  let block_size  = D.block_size
  and digest_size = D.digest_size
  and ctx_size    = F.ctx_size ()
  and key_size    = Native.BLAKE2B.key_size ()

  module Bytes =
  struct
    type buffer = Native.st

    include (By : Convenience with type t = Native.st)
    include PrettyPrint (By) (D)

    let init () =
      let t = Bi.create ctx_size in
      ( Native.BLAKE2B.Bytes.init' t digest_size Bytes.empty 0 0; t )

    let feed t buf =
      F.Bytes.update t buf 0 (Bytes.length buf)

    let get t =
      let res = Bytes.create digest_size in
      F.Bytes.finalize t res 0;
      res

    let digest buf =
      let t = init () in ( feed t buf; get t )

    let digestv bufs =
      let t = init () in ( List.iter (feed t) bufs; get t )

    let hmacv ~key msg =
      let ctx = Bi.create ctx_size in
      let res = By.create digest_size in
      Native.BLAKE2B.Bytes.init' ctx digest_size key 0 (By.length key);
      List.iter (fun x -> F.Bytes.update ctx x 0 (By.length x)) msg;
      F.Bytes.finalize ctx res 0;
      res

    let hmac ~key msg =
      hmacv ~key [ msg ]
  end

  module Bigstring =
  struct
    type buffer = Native.ba

    include (Bi : Convenience with type t = Native.ba)
    include PrettyPrint (Bi) (D)

    let init () =
      let t = Bi.create ctx_size in
      ( Native.BLAKE2B.Bigstring.init' t digest_size Bi.empty 0 0; t )

    let feed t buf =
      F.Bigstring.update t buf 0 (Bi.length buf)

    let get t =
      let res = Bi.create digest_size in
      F.Bigstring.finalize t res 0;
      res

    let digest buf =
      let t = init () in ( feed t buf; get t )

    let digestv bufs =
      let t = init () in ( List.iter (feed t) bufs; get t )

    let hmacv ~key msg =
      if Bi.length key > key_size
      then raise (Invalid_argument "BLAKE2B.hmac{v}: invalid key");

      let ctx = Bi.create ctx_size in
      let res = Bi.create digest_size in
      Native.BLAKE2B.Bigstring.init' ctx digest_size key 0 (Bi.length key);
      List.iter (fun x -> F.Bigstring.update ctx x 0 (Bi.length x)) msg;
      F.Bigstring.finalize ctx res 0;
      res

    let hmac ~key msg =
      hmacv ~key [ msg ]
  end
end

module BLAKE2B = Make_BLAKE2B(Native.BLAKE2B) (struct let (digest_size, block_size) = (64, 128) end)

type hash =
  [ `MD5
  | `SHA1
  | `SHA224
  | `SHA256
  | `SHA384
  | `SHA512
  | `BLAKE2B ]

let module_of = function
  | `MD5     -> (module MD5     : S)
  | `SHA1    -> (module SHA1    : S)
  | `SHA224  -> (module SHA224  : S)
  | `SHA256  -> (module SHA256  : S)
  | `SHA384  -> (module SHA384  : S)
  | `SHA512  -> (module SHA512  : S)
  | `BLAKE2B -> (module BLAKE2B : S)

module Bytes =
struct
  let digest hash =
    let module H = (val (module_of hash)) in
    H.Bytes.digest

  let digestv hash =
    let module H = (val (module_of hash)) in
    H.Bytes.digestv

  let mac hash =
    let module H = (val (module_of hash)) in
    H.Bytes.hmac

  let macv hash =
    let module H = (val (module_of hash)) in
    H.Bytes.hmacv

  let of_hex hash =
    let module H = (val (module_of hash)) in
    H.Bytes.of_hex

  let to_hex hash =
    let module H = (val (module_of hash)) in
    H.Bytes.to_hex

  let pp hash =
    let module H = (val (module_of hash)) in
    H.Bytes.pp
end

module Bigstring =
struct
  let digest hash =
    let module H = (val (module_of hash)) in
    H.Bigstring.digest

  let digestv hash =
    let module H = (val (module_of hash)) in
    H.Bigstring.digestv

  let mac hash =
    let module H = (val (module_of hash)) in
    H.Bigstring.hmac

  let macv hash =
    let module H = (val (module_of hash)) in
    H.Bigstring.hmacv

  let of_hex hash =
    let module H = (val (module_of hash)) in
    H.Bigstring.of_hex

  let to_hex hash =
    let module H = (val (module_of hash)) in
    H.Bigstring.to_hex

  let pp hash =
    let module H = (val (module_of hash)) in
    H.Bigstring.pp
end

let digest_size hash =
  let module H = (val (module_of hash)) in
  H.digest_size