///|
/// Bridge library entry point.
/// Ensures all FFI exports are reachable in the generated C output.
fn main {
  let rows = @utf8.encode("24")
  let cols = @utf8.encode("80")
  let key = @utf8.encode("65")
  let mods = @utf8.encode("0")
  let gained = @utf8.encode("1")
  let data = @utf8.encode("hello")
  // Legacy single-session API
  let _r1 = @bridge.ffi_init(rows, cols)
  let _r2 = @bridge.ffi_process_output(data)
  let _r3 = @bridge.ffi_handle_key(key, mods)
  let _r4 = @bridge.ffi_resize(rows, cols)
  let _r5 = @bridge.ffi_get_title()
  let _r6 = @bridge.ffi_get_grid()
  let _r7 = @bridge.ffi_get_modes()
  let _r8 = @bridge.ffi_focus_event(gained)
  // Session management
  let _s1 : Bytes = @bridge.ffi_create_session(rows, cols)
  let _s2 = @bridge.ffi_destroy_session(@utf8.encode("1"))
  let _s3 = @bridge.ffi_switch_session(@utf8.encode("1"))
  let _s4 = @bridge.ffi_list_sessions()
  let _s5 = @bridge.ffi_get_active_session()
  // GPU rendering exports
  let surface = @utf8.encode("0")
  let width = @utf8.encode("640")
  let height = @utf8.encode("480")
  let _r10 = @bridge.ffi_gpu_init(surface, width, height)
  let _r11 = @bridge.ffi_render_frame()
  let _r12 = @bridge.ffi_gpu_resize(width, height)
  let _r13 = @bridge.ffi_classify_key(key, mods, @utf8.encode("0"))
  // Theme
  let _t1 = @bridge.ffi_get_theme()
  // Shutdown (must be last)
  let _r9 = @bridge.ffi_shutdown()
  println("bridge_lib: all exports referenced")
}
