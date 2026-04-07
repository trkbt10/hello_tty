///|
/// The VT parser maintains state across byte sequences and emits high-level
/// parsed commands (CSI, ESC, OSC) to a handler.
pub struct Parser {
  /// Current parser state.
  mut state : State
  /// Collected intermediate bytes (0x20-0x2F).
  intermediates : Array[Byte]
  /// Collected parameter bytes, parsed into numeric params.
  params : Array[Int]
  /// Current parameter being accumulated.
  mut current_param : Int
  /// Whether we have started accumulating a parameter.
  mut has_param : Bool
  /// Collected OSC data bytes.
  osc_data : Array[Byte]
  /// Collected DCS data bytes.
  dcs_data : Array[Byte]
  /// Maximum number of parameters allowed (default 16, same as xterm).
  max_params : Int
}

///|
/// Create a new VT parser in the Ground state.
pub fn Parser::new(max_params? : Int = 16) -> Parser {
  {
    state: Ground,
    intermediates: [],
    params: [],
    current_param: 0,
    has_param: false,
    osc_data: [],
    dcs_data: [],
    max_params,
  }
}

///|
/// Reset the parser to its initial state, clearing all buffers.
pub fn Parser::reset(self : Parser) -> Unit {
  self.state = Ground
  self.intermediates.clear()
  self.params.clear()
  self.current_param = 0
  self.has_param = false
  self.osc_data.clear()
  self.dcs_data.clear()
}

///|
/// Process a single byte through the state machine.
/// Returns the high-level parsed event, if any.
pub fn Parser::advance(self : Parser, byte : Byte) -> ParserEvent {
  let (action, next_state) = dispatch(self.state, byte)
  self.state = next_state
  self.handle_action(action)
}

///|
/// Process a sequence of bytes, collecting all emitted events.
pub fn Parser::feed(self : Parser, data : Bytes) -> Array[ParserEvent] {
  let events : Array[ParserEvent] = []
  for i in 0..<data.length() {
    let event = self.advance(data[i])
    match event {
      Nop => ()
      _ => events.push(event)
    }
  }
  events
}

///|
/// Process a string as UTF-8 bytes.
pub fn Parser::feed_str(self : Parser, s : String) -> Array[ParserEvent] {
  let events : Array[ParserEvent] = []
  for c in s {
    let code = c.to_int()
    if code <= 0x7F {
      let event = self.advance(code.to_byte())
      match event {
        Nop => ()
        _ => events.push(event)
      }
    } else if code <= 0x7FF {
      // 2-byte UTF-8
      let b1 = (0xC0 | (code >> 6)).to_byte()
      let b2 = (0x80 | (code & 0x3F)).to_byte()
      // For multi-byte characters, emit them as a single Utf8Char event
      events.push(Utf8Char(c))
      // Still advance the parser state for each byte
      // but discard individual byte actions for multi-byte chars
      self.advance(b1) |> ignore
      self.advance(b2) |> ignore
    } else if code <= 0xFFFF {
      events.push(Utf8Char(c))
      let b1 = (0xE0 | (code >> 12)).to_byte()
      let b2 = (0x80 | ((code >> 6) & 0x3F)).to_byte()
      let b3 = (0x80 | (code & 0x3F)).to_byte()
      self.advance(b1) |> ignore
      self.advance(b2) |> ignore
      self.advance(b3) |> ignore
    } else {
      events.push(Utf8Char(c))
      let b1 = (0xF0 | (code >> 18)).to_byte()
      let b2 = (0x80 | ((code >> 12) & 0x3F)).to_byte()
      let b3 = (0x80 | ((code >> 6) & 0x3F)).to_byte()
      let b4 = (0x80 | (code & 0x3F)).to_byte()
      self.advance(b1) |> ignore
      self.advance(b2) |> ignore
      self.advance(b3) |> ignore
      self.advance(b4) |> ignore
    }
  }
  events
}

///|
/// Handle a single action from the state machine, updating internal buffers
/// and returning a high-level event when a complete sequence is recognized.
fn Parser::handle_action(self : Parser, action : Action) -> ParserEvent {
  match action {
    None => Nop
    Print(c) => PrintChar(c)
    Execute(byte) => Control(byte)
    Clear => {
      self.intermediates.clear()
      self.params.clear()
      self.current_param = 0
      self.has_param = false
      Nop
    }
    Collect(byte) => {
      self.intermediates.push(byte)
      Nop
    }
    Param(byte) => {
      let b = byte.to_int()
      if b == 0x3B {
        // Semicolon — finalize current param and start next
        if self.params.length() < self.max_params {
          if self.has_param {
            self.params.push(self.current_param)
          } else {
            self.params.push(0) // Default param value
          }
        }
        self.current_param = 0
        self.has_param = false
      } else {
        // Digit (0x30-0x39)
        self.current_param = self.current_param * 10 + (b - 0x30)
        self.has_param = true
      }
      Nop
    }
    EscDispatch(byte) => {
      let cmd : EscCommand = {
        intermediates: self.intermediates.copy(),
        final_byte: byte,
      }
      self.intermediates.clear()
      EscSequence(cmd)
    }
    CsiDispatch(byte) => {
      // Finalize the last parameter
      if self.has_param && self.params.length() < self.max_params {
        self.params.push(self.current_param)
      } else if !self.has_param && self.params.length() > 0 {
        // Trailing semicolon with no value
        self.params.push(0)
      }
      let cmd : CsiCommand = {
        params: self.params.copy(),
        intermediates: self.intermediates.copy(),
        final_byte: byte,
      }
      self.params.clear()
      self.intermediates.clear()
      self.current_param = 0
      self.has_param = false
      CsiSequence(cmd)
    }
    Hook(byte) => {
      self.dcs_data.clear()
      self.dcs_data.push(byte)
      Nop
    }
    Put(byte) => {
      self.dcs_data.push(byte)
      Nop
    }
    Unhook => {
      let data = self.dcs_data.copy()
      self.dcs_data.clear()
      DcsSequence(data)
    }
    OscStart => {
      self.osc_data.clear()
      Nop
    }
    OscPut(byte) => {
      self.osc_data.push(byte)
      Nop
    }
    OscEnd => {
      let cmd : OscCommand = { data: self.osc_data.copy() }
      self.osc_data.clear()
      OscSequence(cmd)
    }
  }
}

///|
/// High-level events emitted by the parser.
/// These represent complete, actionable terminal events.
pub(all) enum ParserEvent {
  /// No event (internal bookkeeping).
  Nop
  /// Print a single ASCII character at the cursor.
  PrintChar(Char)
  /// Print a multi-byte UTF-8 character.
  Utf8Char(Char)
  /// Execute a C0/C1 control code.
  Control(Byte)
  /// A complete CSI sequence (e.g. cursor movement, SGR attributes).
  CsiSequence(CsiCommand)
  /// A complete ESC sequence (e.g. charset selection, cursor save/restore).
  EscSequence(EscCommand)
  /// A complete OSC sequence (e.g. window title, clipboard).
  OscSequence(OscCommand)
  /// A complete DCS sequence (e.g. Sixel graphics).
  DcsSequence(Array[Byte])
} derive(Show, Eq)

///|
/// Get the current parser state.
pub fn Parser::current_state(self : Parser) -> State {
  self.state
}
