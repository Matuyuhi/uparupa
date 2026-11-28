// Functions exported by the Zig side (core/src/root.zig). Change both files together.
#ifndef UPAA_CORE_H
#define UPAA_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// upaa's own version (form "0.1.0"). The value comes from .version in build.zig.zon.
const char *upaa_version(void);
// true if candidate (form "v0.2.0" or "0.2.0") is newer than the current version. false if it cannot be parsed.
bool upaa_version_is_newer(const char *candidate);

// Config file (key = value lines, Ghostty's keys and color syntax)

typedef struct UpaaConfig UpaaConfig;

// A line that could not be read. The app words it, in the user's language.
typedef struct {
    uint32_t line;
    // Where the line's key is in the text passed to upaa_config_new, in bytes. Empty for UPAA_CONFIG_NOT_KEY_VALUE.
    uint32_t key_start;
    uint32_t key_len;
    uint8_t kind;
} UpaaConfigProblem;
enum { UPAA_CONFIG_NOT_KEY_VALUE = 0, UPAA_CONFIG_UNKNOWN_KEY = 1, UPAA_CONFIG_INVALID_VALUE = 2 };

typedef struct {
    // The font, then its fallbacks, one per line (one font-family line each). NUL-terminated. Valid while the config lives.
    const char *font_family;
    // Points.
    double font_size;
    // How much of the default background color covers what is behind the window (0 to 1).
    double background_opacity;
    // Cells.
    uint16_t window_width;
    uint16_t window_height;
    // The lines that could not be read, as many as fit. Valid while the config lives.
    const UpaaConfigProblem *problems;
    size_t problem_count;
} UpaaConfigValues;

// Reads the text of the config file (UTF-8). Settings it does not name keep their defaults. NULL only when out of memory.
UpaaConfig *upaa_config_new(const uint8_t *text, size_t len);
void upaa_config_free(UpaaConfig *config);
UpaaConfigValues upaa_config_values(const UpaaConfig *config);
// The terminal's default background in light or dark mode, as 0xRRGGBB.
uint32_t upaa_config_background(const UpaaConfig *config, bool dark);

// Terminal session (bundles the PTY, the shell, and the libghostty-vt terminal)

typedef struct UpaaSession UpaaSession;

// All are called from the Zig read thread.
typedef struct {
    void *userdata;
    // The screen changed. The next call does not come until upaa_session_take_dirty is called.
    void (*on_wakeup)(void *userdata);
    // The child process exited.
    void (*on_exit)(void *userdata);
    // The program set the title (OSC 0 or 2). Read it with upaa_session_title.
    void (*on_title)(void *userdata);
} UpaaSessionCallbacks;

// If command is NULL, starts the login shell; otherwise starts /bin/sh -c command. cwd NULL starts in the home
// directory (login shell) or the current one (command). zsh_dir is the directory with upaa's zsh startup files
// (Resources/shell-integration/zsh), used when the login shell is zsh; NULL starts zsh as it is. Returns NULL on failure.
// The colors are libghostty-vt's until upaa_session_set_colors.
UpaaSession *upaa_session_new(uint16_t cols, uint16_t rows, const char *command, const char *cwd, const char *zsh_dir,
                              const UpaaSessionCallbacks *callbacks);
// Sets the default colors for light or dark mode: config's, and design A3's where it names none (config NULL: all A3's).
// config can be freed afterwards.
void upaa_session_set_colors(UpaaSession *session, const UpaaConfig *config, bool dark);
void upaa_session_free(UpaaSession *session);
void upaa_session_write(UpaaSession *session, const uint8_t *data, size_t len);
// A key was pressed once (and released).
typedef struct {
    // macOS virtual key code (NSEvent.keyCode).
    uint16_t key_code;
    // UPAA_KEY_RELEASE / PRESS / REPEAT
    uint8_t action;
    // UPAA_MOD_* values added together.
    uint8_t mods;
    // The character produced by the same key without modifiers. 0 if unknown.
    uint32_t unshifted_codepoint;
    // Characters this key inputs (UTF-8). NULL if none.
    const uint8_t *text;
    size_t text_len;
} UpaaKeyEvent;

enum { UPAA_KEY_RELEASE = 0, UPAA_KEY_PRESS = 1, UPAA_KEY_REPEAT = 2 };
enum { UPAA_MOD_SHIFT = 1 << 0, UPAA_MOD_CTRL = 1 << 1, UPAA_MOD_ALT = 1 << 2, UPAA_MOD_SUPER = 1 << 3 };

// A mouse event, for selecting text or for reporting to the program.
typedef struct {
    // UPAA_POINTER_*
    uint8_t kind;
    // GhosttyMouseButton (1 left, 2 right, 3 middle, 4 wheel up, 5 wheel down). Only used for reporting.
    uint8_t button;
    // UPAA_MOD_* added together. Only used for reporting.
    uint8_t mods;
    // Option held: select a rectangle instead of running text.
    bool rectangle;
    // Position in drawable pixels from the top-left of the view.
    double x;
    double y;
    // Monotonic event time, and the longest gap and distance (pixels) between clicks that still count as a double or triple click.
    uint64_t time_ns;
    uint64_t repeat_interval_ns;
    double repeat_distance;
    uint32_t cols;
    uint32_t rows;
    uint32_t cell_width;
    uint32_t cell_height;
    uint32_t padding_left;
    uint32_t padding_top;
    uint32_t padding_right;
    uint32_t padding_bottom;
    // Size of the whole view in pixels. Dragging past the top or bottom asks for autoscroll.
    uint32_t screen_width;
    uint32_t screen_height;
} UpaaPointer;

enum { UPAA_POINTER_PRESS = 0, UPAA_POINTER_DRAG = 1, UPAA_POINTER_RELEASE = 2, UPAA_POINTER_AUTOSCROLL = 3 };

// Feeds a mouse event to text selection and makes the result the terminal's selection.
// Returns the autoscroll direction a drag asks for (0 none, 1 up, 2 down); send UPAA_POINTER_AUTOSCROLL from a timer while it is not 0.
uint8_t upaa_session_select(UpaaSession *session, const UpaaPointer *pointer);
void upaa_session_select_all(UpaaSession *session);
// Starts the find bar's search through the screen and the scrollback for needle (UTF-8; ASCII letters match either
// case) and selects the newest match. A needle that matches the same way as the last one keeps its results. An empty
// needle ends the search. While it runs, upaa_renderer_frame marks the matches in view.
void upaa_session_find(UpaaSession *session, const uint8_t *needle, size_t len);
// Selects the next older match (the next newer one with back), wrapping around, and scrolls to it if it is out of view.
void upaa_session_find_next(UpaaSession *session, bool back);
// How many matches the search has found so far. selected gets the selected one's place counted from the newest (1),
// or 0 if none is selected.
size_t upaa_session_find_count(UpaaSession *session, size_t *selected);
// The selected text (UTF-8). Returns the full length (0 if nothing is selected); anything beyond cap is truncated. -1 on failure.
ptrdiff_t upaa_session_selection_text(UpaaSession *session, uint8_t *out, size_t cap);
enum { UPAA_PASTE_PASTED = 0, UPAA_PASTE_REJECTED = 1, UPAA_PASTE_FAILED = 2 };
// Whether the program asked for mouse events (vim with mouse=a, htop, ...). If so, send clicks and the wheel to
// upaa_session_report_mouse instead of selecting and scrolling, unless Shift is held.
bool upaa_session_wants_mouse(UpaaSession *session);
// Sends a mouse event to the program in the format it asked for. A wheel step is a press of button 4 (up) or 5 (down).
void upaa_session_report_mouse(UpaaSession *session, const UpaaPointer *pointer);
// Pastes text into the shell, framed for the terminal's current mode (bracketed paste when the program asks for it).
// Returns UPAA_PASTE_REJECTED for text that could run a command by itself (such as a line break outside bracketed
// paste) unless allow_unsafe; ask the user, then call again with allow_unsafe.
uint8_t upaa_session_paste(UpaaSession *session, const uint8_t *text, size_t len, bool allow_unsafe);
// Moves the view through the scrollback by rows (up is negative). Writing input moves it back to the bottom.
void upaa_session_scroll(UpaaSession *session, ptrdiff_t rows);
// Converts key input into a byte sequence matching the terminal's current mode and sends it to the shell.
void upaa_session_key(UpaaSession *session, const UpaaKeyEvent *event);
void upaa_session_resize(UpaaSession *session, uint16_t cols, uint16_t rows, uint32_t cell_width_px, uint32_t cell_height_px);
bool upaa_session_take_dirty(UpaaSession *session);
// The shell's current directory, read from the kernel. Returns its length; 0 if unknown or longer than cap.
size_t upaa_session_cwd(UpaaSession *session, uint8_t *out, size_t cap);
// The program in the terminal's foreground when it is not the shell. Returns its name's length (0 if the name cannot be
// read), -1 while the shell has the terminal.
ptrdiff_t upaa_session_running(UpaaSession *session, uint8_t *out, size_t cap);
// The title the program set (UTF-8). Returns the full length (0 if none); anything beyond cap is truncated.
size_t upaa_session_title(UpaaSession *session, uint8_t *out, size_t cap);
// Plain text of the screen. The return value is the original length; anything beyond cap is truncated. -1 on failure.
ptrdiff_t upaa_session_plain_text(UpaaSession *session, uint8_t *out, size_t cap);

// Drawing (font, glyph atlas, cell data assembly)

typedef struct UpaaRenderer UpaaRenderer;

typedef struct {
    uint32_t cell_width;
    uint32_t cell_height;
    uint32_t baseline;
    // From the top edge of the cell to the top edge of the underline, and the underline thickness.
    uint32_t underline_offset;
    uint32_t underline_thickness;
} UpaaMetrics;

// Data for one cell passed to Metal. Same layout as Cell in Shaders/terminal.metal (28 bytes).
typedef struct {
    uint16_t col;
    uint16_t row;
    // Position and size of the glyph in the atlas. Size 0 means there is nothing to draw.
    uint16_t glyph_x;
    uint16_t glyph_y;
    uint16_t glyph_width;
    uint16_t glyph_height;
    // From the top-left of the cell to the top-left of the glyph image.
    int16_t glyph_offset_x;
    int16_t glyph_offset_y;
    uint8_t fg[4];
    uint8_t bg[4];
    // UPAA_CELL_* values added together.
    uint32_t flags;
} UpaaCell;

// Draws an underline in the foreground color below the cell.
// UPAA_CELL_WIDE_TAIL marks the right half of a wide character (not used for drawing).
enum { UPAA_CELL_UNDERLINE = 1 << 0, UPAA_CELL_WIDE_TAIL = 1 << 1 };

typedef struct {
    uint32_t cell_count;
    uint16_t cols;
    uint16_t rows;
    uint8_t background[4];
    // Incremented every time the atlas image changes. If it differs from last time, the texture is updated.
    uint64_t atlas_generation;
    // The cell with the cursor. Used as the position for the candidate window. Meaningless when cursor_visible is false.
    uint16_t cursor_col;
    uint16_t cursor_row;
    bool cursor_visible;
    // The find bar's search has more of the scrollback to go through: draw again soon.
    bool searching;
    // Milliseconds until the mascot changes, when the screen should be drawn again. 0 if nothing is waiting.
    uint32_t mascot_next_ms;
} UpaaFrame;

// font_name is the font, then its fallbacks, one per line; fallbacks that are not installed are skipped.
// font_size_px is the pixel count after multiplying by the scale factor (2 on Retina). NULL on failure.
// If mascot is true, the axolotl is drawn faintly behind the text, in cells nothing else uses.
UpaaRenderer *upaa_renderer_new(const char *font_name, double font_size_px, bool mascot);
// Changes the font (names and size as for upaa_renderer_new). Returns false, keeping the old font, if it cannot be found.
bool upaa_renderer_set_font(UpaaRenderer *renderer, const char *font_name, double font_size_px);
void upaa_renderer_free(UpaaRenderer *renderer);
UpaaMetrics upaa_renderer_metrics(UpaaRenderer *renderer);
// Notice drawn above the mascot (e.g. an update is available). ASCII.
void upaa_renderer_set_note(UpaaRenderer *renderer, const char *text);
// Plays the mascot's greeting again if the cell (col, row) is on it. Returns whether it was.
bool upaa_renderer_poke_mascot(UpaaRenderer *renderer, int32_t col, int32_t row);
// Atlas image. 1 byte per pixel; each side is upaa_renderer_atlas_size pixels.
const uint8_t *upaa_renderer_atlas_pixels(UpaaRenderer *renderer);
uint32_t upaa_renderer_atlas_size(void);
// Writes the session's current screen into cells. cells may point directly at the contents of the Metal buffer.
// preedit is the text being composed with IME (UTF-8). NULL if none. Overlaid with an underline starting at the cursor position.
UpaaFrame upaa_renderer_frame(UpaaRenderer *renderer, UpaaSession *session, const uint8_t *preedit, size_t preedit_len, UpaaCell *cells, size_t cap);


#endif
