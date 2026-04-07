///|
/// Dispatch the state machine for a given state and input byte.
/// Returns the action to perform and the next state.
pub fn dispatch(state : State, byte : Byte) -> (Action, State) {
  // Global transitions that apply regardless of current state:
  // ESC (0x1B) from any state except certain string states
  // CAN (0x18) and SUB (0x1A) abort sequences and return to Ground
  let b = byte.to_int()
  // CAN and SUB abort any sequence in progress
  if b == 0x18 || b == 0x1A {
    match state {
      Ground => (Execute(byte), Ground)
      DcsPassthrough => (Unhook, Ground)
      OscString => (OscEnd, Ground)
      _ => (None, Ground)
    }
  } else {
    // State-specific dispatch
    match state {
      Ground => ground_action(byte)
      Escape => escape_action(byte)
      EscapeIntermediate => escape_intermediate_action(byte)
      CsiEntry => csi_entry_action(byte)
      CsiParam => csi_param_action(byte)
      CsiIntermediate => csi_intermediate_action(byte)
      CsiIgnore => csi_ignore_action(byte)
      DcsEntry => dcs_entry_action(byte)
      DcsParam => dcs_param_action(byte)
      DcsIntermediate => dcs_intermediate_action(byte)
      DcsPassthrough => dcs_passthrough_action(byte)
      DcsIgnore => dcs_ignore_action(byte)
      OscString => osc_string_action(byte)
      SosPmApcString => sos_pm_apc_string_action(byte)
    }
  }
}
