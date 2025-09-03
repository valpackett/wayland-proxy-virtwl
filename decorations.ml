open Wayland

type bbox = {
  x : int32;
  y : int32;
  width : int32;
  height : int32;
}

let bbox_of (x, y, width, height) = { x; y; width; height; }

let rec proxy_decorator_pointer_handler ~cursor_shape_mgr ~surface deco = object (this)
  inherit [_] H.Wl_pointer.v1
  val mutable cursor_shape_dev = None

  method _cursor_shape pointer =
    match cursor_shape_dev with
    | Some dev -> dev
    | None ->
      let new_dev = H.Wp_cursor_shape_manager_v1.get_pointer cursor_shape_mgr ~pointer @@ object
        inherit [_] H.Wp_cursor_shape_device_v1.v1
      end in
      cursor_shape_dev <- Some new_dev;
      new_dev

  val mutable active = false
  val mutable left_click_held = false
  val mutable pos = (Fixed.of_int (-1), Fixed.of_int (-1))
  val mutable last_serial = Int32.of_int (-1)
  val mutable last_click_serial = Int32.of_int (-1)

  method on_axis _ ~time:_ ~axis:_ ~value:_ = ()
  method on_axis_discrete _ ~axis:_ ~discrete:_ = ()
  method on_axis_source _ ~axis_source:_ = ()
  method on_axis_stop _ ~time:_ ~axis:_ = ()
  method on_axis_value120 _ ~axis:_ ~value120:_ = ()
  method on_axis_relative_direction _ ~axis:_ ~direction:_ = ()

  method on_button _ ~serial ~time:_ ~button ~state =
    last_serial <- serial;
    last_click_serial <- serial;
    if button = Int32.of_int 0x110 (* BTN_LEFT *) then (
      left_click_held <- Int32.to_int state = 1;
    ) else ()

  method on_motion _ ~time:_ ~surface_x:x ~surface_y:y =
    if active then pos <- (x, y) else ();

  method on_enter pointer ~serial ~surface:entered_surface ~surface_x:x ~surface_y:y =
    if entered_surface != surface then () else (
      last_serial <- serial;
      pos <- (x, y);
      active <- true;
      this#on_frame pointer;
    )

  method on_leave _ ~serial ~surface:entered_surface =
    if entered_surface != surface then () else (
      active <- false;
      last_serial <- serial;
      pos <- (Fixed.of_int (-1), Fixed.of_int (-1));
    )

  method on_frame pointer = if not active then () else (
    let (x, y) = pos in
    let shape = deco#on_pointer_frame x y (if left_click_held then Some last_click_serial else None) in
    H.Wp_cursor_shape_device_v1.set_shape (this#_cursor_shape pointer) ~serial:last_serial ~shape;
  )
end

and create_proxy_decorator ~(host: Host.t) ~host_surface ~host_toplevel ~internal_data =
  let comp = Registry.bind host.registry @@ new H.Wl_compositor.v1 in
  let subcomp = Registry.bind host.registry @@ new H.Wl_subcompositor.v1 in
  let cursor_shape_mgr = Registry.bind host.registry @@ new H.Wp_cursor_shape_manager_v1.v1 in (* NOTE: hard req *)
  let surface = H.Wl_compositor.create_surface comp @@ object
      inherit [_] H.Wl_surface.v1
      method! user_data = internal_data
      method on_enter _ ~output:_ = ()
      method on_leave _ ~output:_ = ()
      method on_preferred_buffer_scale _ ~factor:_ = ()
      method on_preferred_buffer_transform _ ~transform:_ = ()
    end in
  let subsurface = H.Wl_subcompositor.get_subsurface subcomp ~surface:surface ~parent:host_surface @@ object
      inherit [_] H.Wl_subsurface.v1
    end in
  let shm = Registry.bind host.registry @@ object
      inherit [_] H.Wl_shm.v1
      method on_format _ ~format:_ = ()
    end in
  (* NOTE: no multi seat support rn *)
  let seat = Registry.bind host.registry @@ object
      inherit [_] H.Wl_seat.v1
      method on_name _ ~name:_ = ()
      method on_capabilities _ ~capabilities:_ = ()
    end in

  let with_memfd ~size f =
    let fd = Result.get_ok @@ Memfd.make_memfd ~name:"deco" ~memfd_opts:(Memfd.make_default_memfd_opts ()) in
    Fun.protect ~finally:(fun () -> Unix.close @@ Obj.magic fd) (fun () ->
      Result.get_ok @@ Memfd.memfd_resize ~memfd:fd ~size;
      f @@ Obj.magic fd)
    in
  let top_size = 24l in
  let border_size = 6l in
  object (self)
    val mutable pointer_handler = None
    val mutable bounds = {
      x = Int32.of_int 0;
      y = Int32.of_int 0;
      width = Int32.of_int 1280;
      height = Int32.of_int 720;
    }
    val mutable title = ""

    (* TODO: figure out buffer reuse and dealloc *)
    method redraw () =
      let height = Int32.add bounds.height @@ Int32.add top_size border_size in
      let width = Int32.add bounds.width @@ Int32.add border_size border_size in
      let stride = Int32.mul width 4l in
      let size = Int32.mul height stride in
      let pool, data = with_memfd ~size:(Int32.to_int size) (fun fd ->
          let pool = H.Wl_shm.create_pool shm (new H.Wl_shm_pool.v1) ~fd ~size in
          let ba = Unix.map_file fd Bigarray.Int32 Bigarray.c_layout true [| Int32.to_int height; Int32.to_int width |] in
          pool, Bigarray.array2_of_genarray ba
        ) in
      let buffer =
        H.Wl_shm_pool.create_buffer pool ~offset:0l ~width ~height ~stride ~format:0l @@ object
          inherit [_] H.Wl_buffer.v1
          method on_release = H.Wl_buffer.destroy
        end
      in
      H.Wl_shm_pool.destroy pool;
      let image = Cairo.Image.create_for_data32 data ~w:(Int32.to_int width) ~h:(Int32.to_int height) in
      let cr = Cairo.create image in
      Cairo.set_source_rgb cr 0.9 0.6 0.8;
      Cairo.rectangle cr 0. 0. ~w:(Float.of_int @@ Int32.to_int width) ~h:(Float.of_int @@ Int32.to_int height);
      Cairo.fill cr;
      Cairo.set_source_rgb cr 0.06 0.2 0.1;
      Cairo.select_font_face cr "Adwaita Sans" ~weight:Bold;
      Cairo.set_font_size cr 14.0;
      Cairo.move_to cr 10. 18.;
      Cairo.show_text cr title;
      Cairo.Surface.finish image;
      H.Wl_surface.attach surface ~buffer:(Some buffer) ~x:0l ~y:0l;
      H.Wl_surface.damage surface ~x:0l ~y:0l ~width:Int32.max_int ~height:Int32.max_int;
      H.Wl_subsurface.set_position subsurface ~x:(Int32.sub bounds.x border_size) ~y:(Int32.sub bounds.y top_size);
      H.Wl_surface.commit surface;

    method on_bbox_changed (newbounds: bbox) =
      bounds <- newbounds;
      self#redraw ();
      Client.sync host.display;
      (Int32.sub newbounds.x border_size,
       Int32.sub newbounds.y top_size,
       Int32.add newbounds.width (Int32.add border_size border_size),
       Int32.add newbounds.height (Int32.add top_size border_size));

    method on_title_set newtitle =
      title <- newtitle;
      self#redraw ();
      Client.sync host.display;

    method on_pointer_frame x y left_click =
      match host_toplevel with
      | None -> H.Wp_cursor_shape_device_v1.Shape.Default
      | Some toplevel -> (
        let do_resize edges = match left_click with
            | Some serial -> H.Xdg_toplevel.resize toplevel ~seat ~serial ~edges
            | _ -> () in
        let do_move () = match left_click with
            | Some serial -> H.Xdg_toplevel.move toplevel ~seat ~serial
            | _ -> () in
        let x = Fixed.to_int x in
        let y = Fixed.to_int y in
        let inside_top_border    = y < (Int32.to_int border_size) in
        let inside_left_border   = x < (Int32.to_int border_size) in
        let inside_right_border  = x > (Int32.to_int @@ Int32.add bounds.width border_size) in
        let inside_bottom_border = y > (Int32.to_int @@ Int32.add bounds.height (top_size)) in
             if inside_left_border  && inside_top_border    then (do_resize H.Xdg_toplevel.Resize_edge.Top_left;     H.Wp_cursor_shape_device_v1.Shape.Nw_resize)
        else if inside_left_border  && inside_bottom_border then (do_resize H.Xdg_toplevel.Resize_edge.Bottom_left;  H.Wp_cursor_shape_device_v1.Shape.Sw_resize)
        else if inside_right_border && inside_top_border    then (do_resize H.Xdg_toplevel.Resize_edge.Top_right;    H.Wp_cursor_shape_device_v1.Shape.Ne_resize)
        else if inside_right_border && inside_bottom_border then (do_resize H.Xdg_toplevel.Resize_edge.Bottom_right; H.Wp_cursor_shape_device_v1.Shape.Se_resize)
        else if inside_left_border   then (do_resize H.Xdg_toplevel.Resize_edge.Left;   H.Wp_cursor_shape_device_v1.Shape.W_resize)
        else if inside_top_border    then (do_resize H.Xdg_toplevel.Resize_edge.Top;    H.Wp_cursor_shape_device_v1.Shape.N_resize)
        else if inside_right_border  then (do_resize H.Xdg_toplevel.Resize_edge.Right;  H.Wp_cursor_shape_device_v1.Shape.E_resize)
        else if inside_bottom_border then (do_resize H.Xdg_toplevel.Resize_edge.Bottom; H.Wp_cursor_shape_device_v1.Shape.S_resize)
        else if y < (Int32.to_int @@ Int32.add border_size top_size)
        then (do_move (); H.Wp_cursor_shape_device_v1.Shape.Default)
        else H.Wp_cursor_shape_device_v1.Shape.Crosshair (* typically not visible area *)
      )

    initializer
      H.Wl_subsurface.place_below subsurface ~sibling:host_surface;
      self#redraw ();
      Client.sync host.display;
      (* TODO: pointer can go away and become inert and reappear *)
      pointer_handler <- Some (H.Wl_seat.get_pointer seat @@ proxy_decorator_pointer_handler ~cursor_shape_mgr ~surface self);
  end
