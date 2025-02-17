open OCADml
open OSCADml
open Syntax

module Steps = struct
  type t =
    [ `PerZ of float
    | `Flat of int
    ]

  let to_int t z =
    match t with
    | `PerZ mm -> Int.max 2 (Float.to_int (z /. mm))
    | `Flat n -> n
end

module Drawer = struct
  type loc =
    [ `BL
    | `BR
    | `TL
    | `TR
    | `CN
    | `B of float
    | `T of float
    | `L of float
    | `R of float
    | `XY of float * float
    ]

  type t = loc -> Path3.t

  let map f (t : t) : t = t >> f
  let translate p t loc = Path3.translate p (t loc)
  let xtrans x t loc = Path3.xtrans x (t loc)
  let ytrans y t loc = Path3.ytrans y (t loc)
  let ztrans z t loc = Path3.ztrans z (t loc)
  let scale s t loc = Path3.scale s (t loc)
  let xscale x t loc = Path3.xscale x (t loc)
  let yscale y t loc = Path3.yscale y (t loc)
  let zscale z t loc = Path3.zscale z (t loc)
  let mirror ax t loc = Path3.mirror ax (t loc)
  let rotate ?about r t loc = Path3.rotate ?about r (t loc)
  let xrot ?about r t loc = Path3.xrot ?about r (t loc)
  let yrot ?about r t loc = Path3.yrot ?about r (t loc)
  let zrot ?about r t loc = Path3.zrot ?about r (t loc)
  let axis_rotate ?about ax r t loc = Path3.axis_rotate ?about ax r (t loc)
  let quaternion ?about q t loc = Path3.quaternion ?about q (t loc)
  let affine m t loc = Path3.affine m (t loc)
end

type config =
  { d1 : [ `Abs of float | `Rel of float ] option
  ; d2 : float option
  ; clearance : float option
  ; n_steps : Steps.t option
  ; min_step_dist : float option
  ; scale : V2.t option
  ; scale_ez : (V2.t * V2.t) option
  ; end_z : float option
  }

let default =
  { d1 = None
  ; d2 = None
  ; clearance = None
  ; n_steps = None
  ; min_step_dist = None
  ; scale = None
  ; scale_ez = None
  ; end_z = None
  }

type t =
  { scad : Scad.d3
  ; key : Key.t
  ; side : [ `North | `East | `South | `West ] [@cad.ignore]
  ; start : Points.t
  ; cleared : Points.t
  ; foot : Points.t
  ; drawer : Drawer.t
  ; bounds_drawer : Drawer.t
  }
[@@deriving cad]

(* Compute a rotation around the face's bottom or top edge, depending on which way
   it's orthoganal is pointing in z, that makes the short edge (between the
   bottom and top long edge), as vertical as possible. The pivoted face, and its
   new orthogonal are returned. *)
let swing_face face =
  let dir = Key.Face.direction face in
  let about, z_sign =
    if V3.z face.normal > 0.
    then V3.mid face.points.bot_left face.points.bot_right, 1.
    else V3.mid face.points.top_left face.points.top_right, -1.
  in
  let q =
    let proj = Plane.(project @@ of_normal dir) in
    let up = V3.(normalize (face.points.top_left -@ face.points.bot_left)) in
    Quaternion.make dir @@ (V2.angle (proj up) (proj @@ v3 0. 0. 1.) *. z_sign)
  in
  Key.Face.quaternion ~about q face

let make
    ?(clearance = 0.)
    ?(n_steps = `Flat 4)
    ?(min_step_dist = 0.02)
    ?(d1 = `Abs 14.)
    ?(d2 = 10.)
    ?scale
    ?scale_ez
    ?(end_z = 0.1)
    side
    (key : Key.t)
  =
  let start_face = Key.Faces.face key.faces side in
  let pivoted_face = swing_face start_face in
  let ortho = pivoted_face.normal in
  let cleared_face = Key.Face.translate (V3.map (( *. ) clearance) ortho) pivoted_face in
  let xy = V3.(normalize (mul ortho (v3 1. 1. 0.)))
  and dir = Points.direction cleared_face.points
  and fn = Steps.to_int n_steps (V3.z cleared_face.points.centre) in
  let d1 =
    match d1 with
    | `Abs d -> d
    | `Rel frac -> V3.z cleared_face.points.centre *. frac
  and step = 1. /. Float.of_int fn in
  let bz end_z =
    let cx = cleared_face.points.centre in
    let p1 = V3.(cx -@ (ortho *$ 0.01)) (* fudge for union *)
    and p2 = V3.((xy *@ v d1 d1 0.) +@ cx)
    and p3 = V3.((xy *@ v d2 d2 0.) +@ v (x cx) (y cx) end_z) in
    Bezier3.make [ p1; p2; p3 ]
  and counter =
    (* counter the rotation created by the z tilt of the face, such that the
       angle of the wall is more in line with the xy angle of the originating face *)
    let a = V3.angle dir (v3 (V3.x dir) (V3.y dir) 0.) *. Math.sign (V3.z dir) *. -1. in
    let s = Quaternion.(slerp (make ortho 0.) (make ortho a))
    and ez = Easing.make (v2 0.42 0.) (v2 1. 1.) in
    let f i = Affine3.of_quaternion @@ s (ez (Float.of_int i *. step)) in
    List.init (fn + 1) f
  and centred =
    Path3.translate (V3.neg @@ cleared_face.points.centre) cleared_face.path
  in
  let scaler =
    match scale with
    | Some s ->
      let p = Path3.to_plane centred in
      let a = V2.angle (V3.project p dir) (v2 1. 0.) in
      let ez =
        match scale_ez with
        | Some (a, b) -> Easing.make a b
        | None -> Fun.id
      in
      let factor i = V2.lerp (v2 1. 1.) s (ez (Float.of_int i *. step)) in
      fun i pt ->
        V3.project p pt
        |> V2.rotate a
        |> V2.scale (factor i)
        |> V2.rotate (-.a)
        |> V2.lift p
    | None -> fun _ pt -> pt
  in
  let transforms =
    let trans =
      Path3.to_transforms ~mode:`NoAlign (Bezier3.curve ~fn (bz 0.))
      |> Util.last
      |> Affine3.compose (Util.last counter)
    in
    let last_shape = Path3.affine trans (List.map (scaler fn) centred) in
    let end_z = Float.max (Box3.minz (Path3.bbox last_shape) *. -1.) 0. +. end_z in
    Path3.to_transforms ~mode:`NoAlign (Bezier3.curve ~fn (bz end_z))
    |> List.map2 (fun c m -> Affine3.(c %> m)) counter
    |> Util.prune_transforms ~min_dist:min_step_dist ~shape:(fun i ->
           List.map (scaler i) centred )
  in
  if List.length transforms < 2
  then
    failwith
      "Insufficient valid wall sweep transformations, consider tweaking d parameters.";
  let scad =
    let rows =
      List.map
        (fun (i, m) -> List.map (fun p -> V3.affine m (scaler i p)) centred)
        transforms
    and clearing =
      Mesh.slice_profiles ~slices:(`Flat 5) [ start_face.path; cleared_face.path ]
    in
    let final =
      let s = Util.last rows in
      let flat = List.map V3.projection s in
      Mesh.slice_profiles ~slices:(`Flat 5) [ s; flat ]
    in
    Mesh.of_rows ~style:`MinEdge (List.concat [ clearing; List.tl rows; List.tl final ])
    |> Scad.of_mesh
  and foot =
    let i, m = Util.last transforms in
    let f p = V3.(projection @@ affine m (scaler i (p -@ cleared_face.points.centre))) in
    Points.map f cleared_face.points
  and drawer ~bounds =
    let start, cleared =
      if bounds
      then start_face.bounds, cleared_face.bounds
      else start_face.points, cleared_face.points
    in
    fun pt ->
      let p0, p1 =
        let f x y =
          let g (p : Points.t) =
            let bot = V3.lerp p.bot_left p.bot_right x
            and top = V3.lerp p.top_left p.top_right x in
            V3.lerp bot top y
          in
          g start, g cleared
        in
        match pt with
        | `TL -> start_face.points.top_left, cleared_face.points.top_left
        | `TR -> start_face.points.top_right, cleared_face.points.top_right
        | `BL -> start_face.points.bot_left, cleared_face.points.bot_left
        | `BR -> start_face.points.bot_right, cleared_face.points.bot_right
        | `CN -> start_face.points.centre, cleared_face.points.centre
        | `T x -> f x 1.
        | `B x -> f x 0.
        | `L y -> f 0. y
        | `R y -> f 1. y
        | `XY (x, y) -> f x y
      in
      let c1 = V3.sub p1 cleared_face.points.centre in
      let trans = List.rev transforms
      and f (i, m) = V3.affine m (scaler i c1) in
      let last = f (List.hd trans) in
      let flat = V3.(last *@ v 1. 1. 0.) in
      p0
      :: List.fold_left
           (fun acc im -> f im :: acc)
           (if V3.approx ~eps:0.1 last flat then [ flat ] else [ last; flat ])
           (List.tl trans)
  in
  { scad
  ; key
  ; side
  ; start = start_face.points
  ; cleared = cleared_face.points
  ; foot
  ; drawer = drawer ~bounds:false
  ; bounds_drawer = drawer ~bounds:true
  }

let of_config { d1; d2; clearance; n_steps; min_step_dist; scale; scale_ez; end_z } =
  make ?d1 ?d2 ?clearance ?n_steps ?min_step_dist ?scale ?scale_ez ?end_z

let start_direction { start = { top_left; top_right; _ }; _ } =
  V3.normalize V3.(top_left -@ top_right)

let foot_direction { foot = { top_left; top_right; _ }; _ } =
  V3.normalize V3.(top_left -@ top_right)

let to_scad t = t.scad
