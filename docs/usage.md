## Usage

### Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+T` | Open a new tab |
| `Cmd+W` | Close current tab / pane |
| `Cmd+D` | Split pane vertically |
| `Cmd+Shift+D` | Split pane horizontally |
| `Cmd+[` / `Cmd+]` | Switch tabs |
| `Cmd+←` / `Cmd+→` | Move focus between panes |
| `Cmd+C` | Copy text |
| `Cmd+V` | Paste text |
| `Cmd+A` | Select all |
| `Cmd+F` | Search |

### Terminal Capabilities

#### Supported Escape Sequences

- **CSI (Control Sequence Introducer)**: Cursor movement, text attributes, color setting, screen/line erase
- **ESC sequences**: RIS (reset), DECSC / DECRC (save/restore cursor)
- **OSC (Operating System Command)**: Window title setting

#### Color Support

- ANSI 16 colors (standard + bright)
- 256-color palette (6×6×6 color cube + 24-step grayscale)
- 24-bit True Color (RGB)
- Theme-based ANSI color customization

#### Terminal Modes

- DECCKM (cursor key application mode)
- DECAWM (auto-wrap)
- DECTCEM (cursor show/hide)
- DECOM (origin mode)
- Bracketed paste
- Focus tracking
- Mouse tracking

### Themes

Built-in themes are available:

- `midnight` (default) — Dark theme
- `solarized` — Solarized color scheme

A theme defines foreground, background, cursor, and selection colors, along with ANSI 16 color overrides and background opacity.

### Default Configuration

| Setting | Value |
|---|---|
| Grid size | 24 rows × 80 columns |
| Shell | `$SHELL` (falls back to `/bin/sh`) |
| Scrollback | Up to 10,000 lines |
| Cell size | 8 × 16 px |
| Font size | 14pt |
| Atlas size | 1024 × 1024 px |
| TERM variable | `xterm-256color` |
