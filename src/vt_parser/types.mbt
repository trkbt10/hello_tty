///|
/// VT parser states based on the VT100.net state machine diagram.
/// See: https://vt100.net/emu/dec_ansi_parser
pub(all) enum State {
  /// Initial state; processing printable characters and C0 controls.
  Ground
  /// Received ESC (0x1B), waiting for next byte.
  Escape
  /// Inside an ESC intermediate sequence (e.g. ESC ( B).
  EscapeIntermediate
  /// Received CSI (ESC [), collecting parameters.
  CsiEntry
  /// Collecting CSI numeric parameters.
  CsiParam
  /// Collecting CSI intermediate bytes after params.
  CsiIntermediate
  /// CSI sequence with ignored/invalid content.
  CsiIgnore
  /// DCS (Device Control String) entry.
  DcsEntry
  /// Collecting DCS parameters.
  DcsParam
  /// Collecting DCS intermediate bytes.
  DcsIntermediate
  /// DCS passthrough mode — data sent to the application.
  DcsPassthrough
  /// DCS with ignored/invalid content.
  DcsIgnore
  /// OSC (Operating System Command) string.
  OscString
  /// SOS/PM/APC string (consumed and ignored).
  SosPmApcString
} derive(Show, Eq)

///|
/// Actions emitted by the parser state machine.
/// These are dispatched to the terminal state handler.
pub(all) enum Action {
  /// No action needed.
  None
  /// Print a character to the terminal at the cursor position.
  Print(Char)
  /// Execute a C0 or C1 control code (e.g. BEL, BS, HT, LF, CR).
  Execute(Byte)
  /// Clear collected parameters and intermediates.
  Clear
  /// Collect an intermediate byte (0x20-0x2F).
  Collect(Byte)
  /// Collect a parameter byte (0x30-0x3B) — digits and semicolons.
  Param(Byte)
  /// Dispatch an ESC sequence final byte.
  EscDispatch(Byte)
  /// Dispatch a CSI sequence final byte.
  CsiDispatch(Byte)
  /// Hook into a DCS sequence (start passthrough).
  Hook(Byte)
  /// Data byte within a DCS passthrough.
  Put(Byte)
  /// Unhook from a DCS sequence (end passthrough).
  Unhook
  /// Start an OSC string.
  OscStart
  /// A data byte within an OSC string.
  OscPut(Byte)
  /// End an OSC string.
  OscEnd
} derive(Show, Eq)

///|
/// A parsed CSI (Control Sequence Introducer) command.
/// E.g. ESC [ 1 ; 3 1 m => params=[1, 31], intermediates=[], final_byte='m'
pub struct CsiCommand {
  /// Parsed numeric parameters separated by ';'.
  params : Array[Int]
  /// Intermediate bytes (0x20-0x2F), if any.
  intermediates : Array[Byte]
  /// The final byte that identifies the command.
  final_byte : Byte
} derive(Show, Eq)

///|
/// A parsed ESC sequence.
pub struct EscCommand {
  /// Intermediate bytes collected.
  intermediates : Array[Byte]
  /// The final byte.
  final_byte : Byte
} derive(Show, Eq)

///|
/// A parsed OSC (Operating System Command) sequence.
pub struct OscCommand {
  /// The collected OSC string data.
  data : Array[Byte]
} derive(Show, Eq)
