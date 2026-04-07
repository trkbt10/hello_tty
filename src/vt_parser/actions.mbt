///|
/// Determine the action for a byte in the Ground state.
/// Printable ASCII (0x20-0x7E) → Print
/// C0 controls (0x00-0x1F) → Execute
/// DEL (0x7F) → None (ignored)
/// 0x80-0x8F, 0x91-0x97, 0x99, 0x9A → Execute (C1 controls)
/// 0x90 → DCS, 0x98/0x9E/0x9F → SOS/PM/APC, 0x9B → CSI, 0x9C → ST, 0x9D → OSC
pub fn ground_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x20 && b <= 0x7E {
    // Printable ASCII — emit as a single character for now.
    // Multi-byte UTF-8 handled at a higher level.
    (Print(b.unsafe_to_char()), Ground)
  } else if b <= 0x1F {
    // C0 control codes
    if b == 0x1B {
      (None, Escape) // ESC transitions to Escape state
    } else {
      (Execute(byte), Ground)
    }
  } else if b == 0x7F {
    (None, Ground) // DEL ignored in ground state
  } else if b >= 0xA0 {
    // High bytes (0xA0-0xFF) — treat as printable (part of UTF-8 or Latin-1)
    (Print(b.unsafe_to_char()), Ground)
  } else {
    // C1 control range 0x80-0x9F
    match b {
      0x90 => (None, DcsEntry) // DCS
      0x9B => (None, CsiEntry) // CSI
      0x9D => (OscStart, OscString) // OSC
      0x98 | 0x9E | 0x9F => (None, SosPmApcString)
      0x9C => (None, Ground) // ST (string terminator) — no-op in ground
      _ => (Execute(byte), Ground) // Other C1 controls
    }
  }
}

///|
/// Determine action in the Escape state.
pub fn escape_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x20 && b <= 0x2F {
    // Intermediate bytes → collect and go to EscapeIntermediate
    (Collect(byte), EscapeIntermediate)
  } else if b >= 0x30 && b <= 0x7E {
    // Final byte — dispatch ESC sequence
    match b {
      0x5B => (Clear, CsiEntry) // '[' → CSI
      0x5D => (OscStart, OscString) // ']' → OSC
      0x50 => (Clear, DcsEntry) // 'P' → DCS
      0x58 | 0x5E | 0x5F => // 'X', '^', '_' → SOS/PM/APC
        (None, SosPmApcString)
      _ => (EscDispatch(byte), Ground) // Other final bytes
    }
  } else if b <= 0x1F {
    // C0 controls execute immediately, stay in Escape
    (Execute(byte), Escape)
  } else if b == 0x7F {
    (None, Escape) // DEL ignored
  } else {
    // 0x80+ : treat as ground transition
    (None, Ground)
  }
}

///|
/// Determine action in the EscapeIntermediate state.
pub fn escape_intermediate_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x20 && b <= 0x2F {
    (Collect(byte), EscapeIntermediate)
  } else if b >= 0x30 && b <= 0x7E {
    (EscDispatch(byte), Ground)
  } else if b <= 0x1F {
    (Execute(byte), EscapeIntermediate)
  } else {
    // Invalid: ignore and go to ground
    (None, Ground)
  }
}

///|
/// Determine action in the CsiEntry state.
pub fn csi_entry_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x40 && b <= 0x7E {
    // Final byte immediately — dispatch CSI with no params
    (CsiDispatch(byte), Ground)
  } else if b >= 0x30 && b <= 0x3B {
    // Parameter byte (digit or semicolon)
    (Param(byte), CsiParam)
  } else if b >= 0x3C && b <= 0x3F {
    // Private marker (e.g. '?' in ESC[?25h)
    (Collect(byte), CsiParam)
  } else if b >= 0x20 && b <= 0x2F {
    // Intermediate byte
    (Collect(byte), CsiIntermediate)
  } else if b <= 0x1F {
    (Execute(byte), CsiEntry)
  } else {
    (None, CsiEntry) // 0x7F DEL, ignore
  }
}

///|
/// Determine action in the CsiParam state.
pub fn csi_param_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x30 && b <= 0x3B {
    (Param(byte), CsiParam)
  } else if b >= 0x40 && b <= 0x7E {
    (CsiDispatch(byte), Ground)
  } else if b >= 0x20 && b <= 0x2F {
    (Collect(byte), CsiIntermediate)
  } else if b >= 0x3C && b <= 0x3F {
    // Invalid: parameter byte after parameters started
    (None, CsiIgnore)
  } else if b <= 0x1F {
    (Execute(byte), CsiParam)
  } else {
    (None, CsiParam) // DEL
  }
}

///|
/// Determine action in the CsiIntermediate state.
pub fn csi_intermediate_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x20 && b <= 0x2F {
    (Collect(byte), CsiIntermediate)
  } else if b >= 0x40 && b <= 0x7E {
    (CsiDispatch(byte), Ground)
  } else if b >= 0x30 && b <= 0x3F {
    // Invalid in intermediate state
    (None, CsiIgnore)
  } else if b <= 0x1F {
    (Execute(byte), CsiIntermediate)
  } else {
    (None, CsiIntermediate)
  }
}

///|
/// Determine action in the CsiIgnore state.
pub fn csi_ignore_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x40 && b <= 0x7E {
    // Final byte exits the ignored sequence
    (None, Ground)
  } else if b <= 0x1F {
    (Execute(byte), CsiIgnore)
  } else {
    (None, CsiIgnore)
  }
}

///|
/// Determine action in DcsEntry state.
pub fn dcs_entry_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x40 && b <= 0x7E {
    (Hook(byte), DcsPassthrough)
  } else if b >= 0x30 && b <= 0x3B {
    (Param(byte), DcsParam)
  } else if b >= 0x3C && b <= 0x3F {
    (Collect(byte), DcsParam)
  } else if b >= 0x20 && b <= 0x2F {
    (Collect(byte), DcsIntermediate)
  } else if b <= 0x1F {
    (Execute(byte), DcsEntry)
  } else {
    (None, DcsEntry)
  }
}

///|
/// Determine action in DcsParam state.
pub fn dcs_param_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x30 && b <= 0x3B {
    (Param(byte), DcsParam)
  } else if b >= 0x40 && b <= 0x7E {
    (Hook(byte), DcsPassthrough)
  } else if b >= 0x20 && b <= 0x2F {
    (Collect(byte), DcsIntermediate)
  } else if b >= 0x3C && b <= 0x3F {
    (None, DcsIgnore)
  } else if b <= 0x1F {
    (Execute(byte), DcsParam)
  } else {
    (None, DcsParam)
  }
}

///|
/// Determine action in DcsIntermediate state.
pub fn dcs_intermediate_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x20 && b <= 0x2F {
    (Collect(byte), DcsIntermediate)
  } else if b >= 0x40 && b <= 0x7E {
    (Hook(byte), DcsPassthrough)
  } else if b >= 0x30 && b <= 0x3F {
    (None, DcsIgnore)
  } else if b <= 0x1F {
    (Execute(byte), DcsIntermediate)
  } else {
    (None, DcsIntermediate)
  }
}

///|
/// Determine action in DcsPassthrough state.
pub fn dcs_passthrough_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b >= 0x20 && b <= 0x7E {
    (Put(byte), DcsPassthrough)
  } else if b == 0x9C {
    // ST (String Terminator)
    (Unhook, Ground)
  } else if b == 0x1B {
    // ESC might begin ST (ESC \)
    // We transition to Escape; the Unhook will be emitted there
    (Unhook, Escape)
  } else if b <= 0x1F {
    (Execute(byte), DcsPassthrough)
  } else {
    (Put(byte), DcsPassthrough)
  }
}

///|
/// Determine action in DcsIgnore state.
pub fn dcs_ignore_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b == 0x9C {
    (None, Ground) // ST ends the ignored sequence
  } else if b == 0x1B {
    (None, Escape)
  } else {
    (None, DcsIgnore)
  }
}

///|
/// Determine action in OscString state.
pub fn osc_string_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b == 0x9C {
    // ST ends OSC
    (OscEnd, Ground)
  } else if b == 0x1B {
    // ESC might begin ST (ESC \)
    (OscEnd, Escape)
  } else if b == 0x07 {
    // BEL also terminates OSC (widely used)
    (OscEnd, Ground)
  } else if b >= 0x20 && b <= 0x7F {
    (OscPut(byte), OscString)
  } else if b >= 0x08 && b <= 0x0D {
    // Some C0 controls are passed through in OSC strings
    (OscPut(byte), OscString)
  } else {
    (OscPut(byte), OscString)
  }
}

///|
/// Determine action in SosPmApcString state.
/// SOS, PM, and APC strings are consumed and ignored until ST.
pub fn sos_pm_apc_string_action(byte : Byte) -> (Action, State) {
  let b = byte.to_int()
  if b == 0x9C {
    (None, Ground)
  } else if b == 0x1B {
    (None, Escape)
  } else {
    (None, SosPmApcString)
  }
}
