// X11 (Xlib) windowing backend for Linux.
//
// Extracted from platform_linux.c. All public symbols are prefixed x11_
// so the dispatcher (platform_linux.c) can call them via function pointers.
//
// Compile with: -lX11

#if defined(__linux__) && defined(HELLO_TTY_PLATFORM_LINUX)

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/XKBlib.h>
#include <X11/Xresource.h>

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>

#include "platform_backend.h"

// ---------- Internal state ----------

typedef struct {
    Display *display;
    int screen;
    Atom wm_delete_window;
    Atom clipboard_atom;
    Atom utf8_string;
    Atom targets_atom;
    Atom hello_tty_sel;
    int initialized;
} X11State;

static X11State g_x11 = {0};

typedef struct {
    Window window;
    XIC xic;
    int alive;
    int width, height;
    int event_types[256];
    int event_data[256][4];
    int event_head;
    int event_tail;
} X11Window;

static X11Window g_x11_windows[MAX_WINDOWS] = {0};

static XIM g_x11_xim = NULL;

static char *g_x11_clipboard_text = NULL;
static int g_x11_clipboard_len = 0;

static void x11_push_event(int slot, int type, int d0, int d1, int d2, int d3) {
    int next = (g_x11_windows[slot].event_tail + 1) % 256;
    if (next == g_x11_windows[slot].event_head) return;
    g_x11_windows[slot].event_types[g_x11_windows[slot].event_tail] = type;
    g_x11_windows[slot].event_data[g_x11_windows[slot].event_tail][0] = d0;
    g_x11_windows[slot].event_data[g_x11_windows[slot].event_tail][1] = d1;
    g_x11_windows[slot].event_data[g_x11_windows[slot].event_tail][2] = d2;
    g_x11_windows[slot].event_data[g_x11_windows[slot].event_tail][3] = d3;
    g_x11_windows[slot].event_tail = next;
}

static int x11_pop_event(int slot, int *type, int data[4]) {
    if (g_x11_windows[slot].event_head == g_x11_windows[slot].event_tail) return 0;
    *type = g_x11_windows[slot].event_types[g_x11_windows[slot].event_head];
    memcpy(data, g_x11_windows[slot].event_data[g_x11_windows[slot].event_head], sizeof(int) * 4);
    g_x11_windows[slot].event_head = (g_x11_windows[slot].event_head + 1) % 256;
    return 1;
}

static int x11_find_slot(Window w) {
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_x11_windows[i].alive && g_x11_windows[i].window == w) return i;
    }
    return -1;
}

// ---------- Keyboard translation ----------

int translate_keysym(unsigned long ks) {
    if (ks >= XK_space && ks <= XK_asciitilde) return (int)ks;
    if (ks >= XK_A && ks <= XK_Z) return (int)(ks - XK_A + 'a');
    if (ks >= XK_a && ks <= XK_z) return (int)ks;

    switch (ks) {
        case XK_Up:        return 0xF700;
        case XK_Down:      return 0xF701;
        case XK_Left:      return 0xF702;
        case XK_Right:     return 0xF703;
        case XK_F1:        return 0xF704;
        case XK_F2:        return 0xF705;
        case XK_F3:        return 0xF706;
        case XK_F4:        return 0xF707;
        case XK_F5:        return 0xF708;
        case XK_F6:        return 0xF709;
        case XK_F7:        return 0xF70A;
        case XK_F8:        return 0xF70B;
        case XK_F9:        return 0xF70C;
        case XK_F10:       return 0xF70D;
        case XK_F11:       return 0xF70E;
        case XK_F12:       return 0xF70F;
        case XK_Insert:    return 0xF727;
        case XK_Delete:    return 0xF728;
        case XK_Home:      return 0xF729;
        case XK_End:       return 0xF72B;
        case XK_Page_Up:   return 0xF72C;
        case XK_Page_Down: return 0xF72D;
        case XK_Return:    return 0x0D;
        case XK_KP_Enter:  return 0x0D;
        case XK_Tab:       return 0x09;
        case XK_ISO_Left_Tab: return 0x09;
        case XK_Escape:    return 0x1B;
        case XK_BackSpace: return 0x7F;
        default:           return 0;
    }
}

static int translate_x11_modifiers(unsigned int state) {
    int mods = 0;
    if (state & ShiftMask)   mods |= 1;
    if (state & ControlMask) mods |= 2;
    if (state & Mod1Mask)    mods |= 4;
    if (state & Mod4Mask)    mods |= 8;
    return mods;
}

// ---------- X11 event processing ----------

static void process_x11_event(XEvent *ev) {
    int slot;

    switch (ev->type) {
        case KeyPress: {
            slot = x11_find_slot(ev->xkey.window);
            if (slot < 0) break;

            int mods = translate_x11_modifiers(ev->xkey.state);
            char buf[32];
            KeySym ks;
            int len = 0;

            if (g_x11_windows[slot].xic) {
                Status status;
                len = XmbLookupString(g_x11_windows[slot].xic, &ev->xkey,
                                      buf, sizeof(buf) - 1, &ks, &status);
                if (status == XLookupNone) break;
                if (status == XLookupChars || status == XLookupBoth) {
                    if (len > 0) {
                        buf[len] = '\0';
                        if (len == 1 && buf[0] >= 0x20 && buf[0] < 0x7F) {
                            // Simple printable ASCII — use keysym path below
                        } else if (len > 0 && (status == XLookupChars ||
                                    (ks >= XK_space && ks <= XK_asciitilde))) {
                            for (int i = 0; i < len; i++) {
                                x11_push_event(slot, 1, (int)(unsigned char)buf[i], 0, 0, 0);
                            }
                            break;
                        }
                    }
                }
            } else {
                len = XLookupString(&ev->xkey, buf, sizeof(buf) - 1, &ks, NULL);
            }

            int key = translate_keysym(ks);
            if (key != 0) {
                x11_push_event(slot, 1, key, mods, 0, 0);
            } else if (len > 0) {
                for (int i = 0; i < len; i++) {
                    x11_push_event(slot, 1, (int)(unsigned char)buf[i], 0, 0, 0);
                }
            }
            break;
        }

        case ConfigureNotify: {
            slot = x11_find_slot(ev->xconfigure.window);
            if (slot < 0) break;
            int w = ev->xconfigure.width;
            int h = ev->xconfigure.height;
            if (w != g_x11_windows[slot].width || h != g_x11_windows[slot].height) {
                g_x11_windows[slot].width = w;
                g_x11_windows[slot].height = h;
                x11_push_event(slot, 2, w, h, 0, 0);
            }
            break;
        }

        case ClientMessage: {
            slot = x11_find_slot(ev->xclient.window);
            if (slot < 0) break;
            if ((Atom)ev->xclient.data.l[0] == g_x11.wm_delete_window) {
                x11_push_event(slot, 3, 0, 0, 0, 0);
            }
            break;
        }

        case FocusIn: {
            slot = x11_find_slot(ev->xfocus.window);
            if (slot < 0) break;
            x11_push_event(slot, 4, 0, 0, 0, 0);
            break;
        }

        case FocusOut: {
            slot = x11_find_slot(ev->xfocus.window);
            if (slot < 0) break;
            x11_push_event(slot, 5, 0, 0, 0, 0);
            break;
        }

        case ButtonPress: {
            slot = x11_find_slot(ev->xbutton.window);
            if (slot < 0) break;
            int x = ev->xbutton.x;
            int y = ev->xbutton.y;
            unsigned int btn = ev->xbutton.button;

            if (btn == Button4) {
                x11_push_event(slot, 6, x, y, -2, 3);
            } else if (btn == Button5) {
                x11_push_event(slot, 6, x, y, -2, -3);
            } else {
                int mods = translate_x11_modifiers(ev->xbutton.state);
                x11_push_event(slot, 6, x, y, (int)(btn - 1), mods);
            }
            break;
        }

        case ButtonRelease: {
            slot = x11_find_slot(ev->xbutton.window);
            if (slot < 0) break;
            unsigned int btn = ev->xbutton.button;
            if (btn == Button4 || btn == Button5) break;
            int x = ev->xbutton.x;
            int y = ev->xbutton.y;
            x11_push_event(slot, 6, x, y, (int)(btn - 1) | 0x100, 0);
            break;
        }

        case MotionNotify: {
            slot = x11_find_slot(ev->xmotion.window);
            if (slot < 0) break;
            x11_push_event(slot, 6, ev->xmotion.x, ev->xmotion.y, -1, 0);
            break;
        }

        case SelectionRequest: {
            XSelectionRequestEvent *req = &ev->xselectionrequest;
            XSelectionEvent reply = {0};
            reply.type = SelectionNotify;
            reply.requestor = req->requestor;
            reply.selection = req->selection;
            reply.target = req->target;
            reply.time = req->time;
            reply.property = None;

            if (req->target == g_x11.targets_atom) {
                Atom targets[] = { g_x11.utf8_string, XA_STRING };
                XChangeProperty(g_x11.display, req->requestor, req->property,
                                XA_ATOM, 32, PropModeReplace,
                                (unsigned char *)targets, 2);
                reply.property = req->property;
            } else if ((req->target == g_x11.utf8_string || req->target == XA_STRING)
                       && g_x11_clipboard_text != NULL) {
                XChangeProperty(g_x11.display, req->requestor, req->property,
                                req->target, 8, PropModeReplace,
                                (unsigned char *)g_x11_clipboard_text, g_x11_clipboard_len);
                reply.property = req->property;
            }

            XSendEvent(g_x11.display, req->requestor, False, 0, (XEvent *)&reply);
            XFlush(g_x11.display);
            break;
        }

        case SelectionClear: {
            if (g_x11_clipboard_text) {
                free(g_x11_clipboard_text);
                g_x11_clipboard_text = NULL;
                g_x11_clipboard_len = 0;
            }
            break;
        }

        default:
            break;
    }
}

// ---------- Public X11 backend API ----------

int x11_platform_init(void) {
    if (g_x11.initialized) return 0;

    g_x11.display = XOpenDisplay(NULL);
    if (!g_x11.display) {
        fprintf(stderr, "hello_tty: failed to open X11 display\n");
        return -1;
    }

    g_x11.screen = DefaultScreen(g_x11.display);
    g_x11.wm_delete_window = XInternAtom(g_x11.display, "WM_DELETE_WINDOW", False);
    g_x11.clipboard_atom = XInternAtom(g_x11.display, "CLIPBOARD", False);
    g_x11.utf8_string = XInternAtom(g_x11.display, "UTF8_STRING", False);
    g_x11.targets_atom = XInternAtom(g_x11.display, "TARGETS", False);
    g_x11.hello_tty_sel = XInternAtom(g_x11.display, "HELLO_TTY_SEL", False);

    g_x11_xim = XOpenIM(g_x11.display, NULL, NULL, NULL);

    g_x11.initialized = 1;
    return 0;
}

int x11_platform_create_window(int width, int height) {
    if (!g_x11.initialized) return -1;

    int slot = -1;
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (!g_x11_windows[i].alive) { slot = i; break; }
    }
    if (slot < 0) return -1;

    Display *dpy = g_x11.display;
    int scr = g_x11.screen;
    Window root = RootWindow(dpy, scr);
    unsigned long black = BlackPixel(dpy, scr);

    g_x11_windows[slot].window = XCreateSimpleWindow(
        dpy, root, 100, 100,
        (unsigned int)width, (unsigned int)height,
        0, black, black
    );

    if (!g_x11_windows[slot].window) return -1;

    long event_mask = KeyPressMask | StructureNotifyMask |
                      FocusChangeMask | ExposureMask |
                      ButtonPressMask | ButtonReleaseMask |
                      PointerMotionMask;
    XSelectInput(dpy, g_x11_windows[slot].window, event_mask);
    XSetWMProtocols(dpy, g_x11_windows[slot].window, &g_x11.wm_delete_window, 1);
    XStoreName(dpy, g_x11_windows[slot].window, "hello_tty");

    XSizeHints hints = {0};
    hints.flags = PMinSize;
    hints.min_width = 200;
    hints.min_height = 100;
    XSetWMNormalHints(dpy, g_x11_windows[slot].window, &hints);

    XClassHint class_hint = { .res_name = "hello_tty", .res_class = "HelloTTY" };
    XSetClassHint(dpy, g_x11_windows[slot].window, &class_hint);

    if (g_x11_xim) {
        g_x11_windows[slot].xic = XCreateIC(g_x11_xim,
            XNInputStyle, XIMPreeditNothing | XIMStatusNothing,
            XNClientWindow, g_x11_windows[slot].window,
            XNFocusWindow, g_x11_windows[slot].window,
            NULL);
    }

    g_x11_windows[slot].alive = 1;
    g_x11_windows[slot].width = width;
    g_x11_windows[slot].height = height;
    g_x11_windows[slot].event_head = 0;
    g_x11_windows[slot].event_tail = 0;

    XMapWindow(dpy, g_x11_windows[slot].window);
    XFlush(dpy);

    return slot + 1;
}

void x11_platform_set_title(const uint8_t *title, int title_len, int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_x11_windows[slot].alive) return;

    char buf[1024];
    int len = title_len < 1023 ? title_len : 1023;
    memcpy(buf, title, (size_t)len);
    buf[len] = '\0';
    XStoreName(g_x11.display, g_x11_windows[slot].window, buf);
    XFlush(g_x11.display);
}

int x11_platform_poll_event(int window, int32_t *event_buf) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_x11_windows[slot].alive) return 0;

    while (XPending(g_x11.display)) {
        XEvent ev;
        XNextEvent(g_x11.display, &ev);
        if (XFilterEvent(&ev, None)) continue;
        process_x11_event(&ev);
    }

    int type = 0;
    int data[4] = {0};
    if (x11_pop_event(slot, &type, data)) {
        event_buf[0] = data[0];
        event_buf[1] = data[1];
        event_buf[2] = data[2];
        event_buf[3] = data[3];
        return type;
    }

    return 0;
}

void x11_platform_request_redraw(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_x11_windows[slot].alive) return;

    XEvent ev = {0};
    ev.type = Expose;
    ev.xexpose.window = g_x11_windows[slot].window;
    XSendEvent(g_x11.display, g_x11_windows[slot].window, False, ExposureMask, &ev);
    XFlush(g_x11.display);
}

int x11_platform_get_vulkan_surface(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_x11_windows[slot].alive) return 0;
    return (int)(uintptr_t)g_x11_windows[slot].window;
}

int x11_platform_get_dpi_scale(int window) {
    (void)window;
    if (!g_x11.display) return 100;

    char *rms = XResourceManagerString(g_x11.display);
    if (rms) {
        XrmDatabase db = XrmGetStringDatabase(rms);
        if (db) {
            XrmValue value;
            char *type = NULL;
            if (XrmGetResource(db, "Xft.dpi", "Xft.Dpi", &type, &value)) {
                double dpi = atof(value.addr);
                if (dpi > 0) {
                    int scale = (int)(dpi / 96.0 * 100.0);
                    XrmDestroyDatabase(db);
                    return scale > 0 ? scale : 100;
                }
            }
            XrmDestroyDatabase(db);
        }
    }

    int scr = g_x11.screen;
    int width_px = DisplayWidth(g_x11.display, scr);
    int width_mm = DisplayWidthMM(g_x11.display, scr);
    if (width_mm > 0) {
        double dpi = (double)width_px * 25.4 / (double)width_mm;
        int scale = (int)(dpi / 96.0 * 100.0);
        return scale > 0 ? scale : 100;
    }

    return 100;
}

void x11_platform_destroy_window(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_x11_windows[slot].alive) return;

    if (g_x11_windows[slot].xic) {
        XDestroyIC(g_x11_windows[slot].xic);
        g_x11_windows[slot].xic = NULL;
    }

    XDestroyWindow(g_x11.display, g_x11_windows[slot].window);
    g_x11_windows[slot].window = 0;
    g_x11_windows[slot].alive = 0;
    XFlush(g_x11.display);
}

void x11_platform_shutdown(void) {
    if (!g_x11.initialized) return;

    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_x11_windows[i].alive) {
            x11_platform_destroy_window(i + 1);
        }
    }

    if (g_x11_xim) { XCloseIM(g_x11_xim); g_x11_xim = NULL; }

    if (g_x11_clipboard_text) {
        free(g_x11_clipboard_text);
        g_x11_clipboard_text = NULL;
        g_x11_clipboard_len = 0;
    }

    XCloseDisplay(g_x11.display);
    g_x11.display = NULL;
    g_x11.initialized = 0;
}

int x11_platform_clipboard_set(const uint8_t *text, int len) {
    if (!g_x11.initialized || len <= 0) return -1;

    if (g_x11_clipboard_text) free(g_x11_clipboard_text);
    g_x11_clipboard_text = (char *)malloc((size_t)len + 1);
    if (!g_x11_clipboard_text) return -1;
    memcpy(g_x11_clipboard_text, text, (size_t)len);
    g_x11_clipboard_text[len] = '\0';
    g_x11_clipboard_len = len;

    Window owner = None;
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_x11_windows[i].alive) { owner = g_x11_windows[i].window; break; }
    }
    if (owner == None) return -1;

    XSetSelectionOwner(g_x11.display, g_x11.clipboard_atom, owner, CurrentTime);
    XFlush(g_x11.display);
    return 0;
}

int x11_platform_clipboard_get(uint8_t *buf, int max_len) {
    if (!g_x11.initialized) return -1;

    Window owner = XGetSelectionOwner(g_x11.display, g_x11.clipboard_atom);
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_x11_windows[i].alive && g_x11_windows[i].window == owner && g_x11_clipboard_text) {
            int len = g_x11_clipboard_len < max_len ? g_x11_clipboard_len : max_len;
            memcpy(buf, g_x11_clipboard_text, (size_t)len);
            return len;
        }
    }

    Window requestor = None;
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_x11_windows[i].alive) { requestor = g_x11_windows[i].window; break; }
    }
    if (requestor == None) return -1;

    XConvertSelection(g_x11.display, g_x11.clipboard_atom,
                      g_x11.utf8_string, g_x11.hello_tty_sel,
                      requestor, CurrentTime);
    XFlush(g_x11.display);

    XEvent ev;
    for (int attempts = 0; attempts < 100; attempts++) {
        if (XCheckTypedWindowEvent(g_x11.display, requestor, SelectionNotify, &ev)) {
            if (ev.xselection.property == None) return -1;

            Atom actual_type;
            int actual_format;
            unsigned long nitems, bytes_after;
            unsigned char *data = NULL;

            XGetWindowProperty(g_x11.display, requestor,
                               g_x11.hello_tty_sel,
                               0, (long)max_len, True,
                               AnyPropertyType,
                               &actual_type, &actual_format,
                               &nitems, &bytes_after, &data);

            if (data && nitems > 0) {
                int len = (int)nitems < max_len ? (int)nitems : max_len;
                memcpy(buf, data, (size_t)len);
                XFree(data);
                return len;
            }
            if (data) XFree(data);
            return -1;
        }
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 1000000 };
        nanosleep(&ts, NULL);
    }

    return -1;
}

void* x11_platform_get_display(void) {
    return (void *)g_x11.display;
}

#endif // __linux__ && HELLO_TTY_PLATFORM_LINUX
