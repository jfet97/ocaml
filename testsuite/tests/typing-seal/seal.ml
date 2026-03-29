(* TEST
 expect;
*)

(* basic: already-closed object, no change *)
let t1 = [%seal (object method x = 1 end)];;
[%%expect {|
val t1 : < x : int > = <obj>
|}]

(* no objects: no-op, type stays int *)
let t2 = [%seal 42];;
[%%expect {|
val t2 : int = 42
|}]

(* close an open row from a type annotation *)
let f (x : < foo: int; bar: string; .. >) = [%seal x];;
[%%expect {|
val f : < bar : string; foo : int > -> < bar : string; foo : int > = <fun>
|}]

(* inside a type constructor *)
type ('a, 'b, 'r) t = Dummy;;
let x : (unit, string, < db: int; log: int; .. >) t = Dummy;;
let y = [%seal x];;
[%%expect {|
type ('a, 'b, 'r) t = Dummy
val x : (unit, string, < db : int; log : int; .. >) t = Dummy
val y : (unit, string, < db : int; log : int >) t = Dummy
|}]

(* multiple object types in a tuple *)
let t4 (a : < x: int; .. >) (b : < y: string; .. >) = [%seal (a, b)];;
[%%expect {|
val t4 : < x : int > -> < y : string > -> < x : int > * < y : string > =
  <fun>
|}]

(* object inside arrow type *)
let t5 (f : < m: int; .. > -> < n: string; .. >) = [%seal f];;
[%%expect {|
val t5 : (< m : int > -> < n : string >) -> < m : int > -> < n : string > =
  <fun>
|}]

(* nested objects: object type inside a constructor inside another object *)
let t6 (x : < inner: (< a: int; .. >) list; .. >) = [%seal x];;
[%%expect {|
val t6 : < inner : < a : int > list > -> < inner : < a : int > list > = <fun>
|}]

(* seal with no row variable (already closed annotation) *)
let t7 (x : < foo: int >) = [%seal x];;
[%%expect {|
val t7 : < foo : int > -> < foo : int > = <fun>
|}]
