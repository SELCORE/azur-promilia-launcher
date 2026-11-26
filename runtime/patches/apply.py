"""Small, targeted patches applied to the CrossOver Wine source before building.

usage: python3 -I runtime/patches/apply.py <wine source dir>

Running it again on an already patched tree is fine: patches that are already in place are skipped.

1. ascii-keymap (dlls/winemac.drv/cocoa_app.m)
   Wine builds its key map (key names, characters for games that read raw keys) from the current
   Mac keyboard layout. With the Korean input method that layout is "2-Set Hangul", so games show
   ㅓ/ㅣ instead of J/L for their shortcuts and raw typing produces loose jamo. When the current
   layout is not ASCII-capable (or is a Hangul layout), use the user's ASCII-capable layout (ABC/US)
   for the key map instead. Text typed through the Mac input method (marked text, Nexon Plug, games
   that enable IME) is not affected. Set WINE_MAC_NATIVE_KEYMAP=1 to get the old behaviour.

2. no-layout-switch (dlls/winemac.drv/keyboard.c)
   When a Windows program calls ActivateKeyboardLayout (Unity games do it whenever they get
   focus), Wine switched the Mac's input source to match, so choosing ABC on the Mac got undone.
   Keep the Mac's input source as the user set it. Set WINE_MAC_ALLOW_LAYOUT_SWITCH=1 to restore.

3. ime-fallback (winemac.drv keyboard.c, cocoa_window.m, event.c, macdrv_main.c; win32u message.c)
   Some games turn the Windows IME off for their window (no input context), so the Mac input
   method never sees their keys and Korean comes out as loose jamo. For programs that opt in
   with the Mac Driver option "ImeFallback" (the launcher sets it for AzurPromilia.exe under
   HKCU\\Software\\Wine\\AppDefaults\\AzurPromilia.exe\\Mac Driver), a key pressed while a Mac
   input method is active and the focused window has no input context goes to the input method
   first. Text it commits is sent as Unicode input (VK_PACKET -> WM_CHAR) before the key itself,
   so it arrives before Enter. Letter keys the input method used are still sent (games use them
   as controls) but marked so TranslateMessage makes no character for them; editing keys it used
   (Backspace inside a syllable and so on) are not sent. The syllable being composed is not shown
   until it is committed, because the game has no way to display it. Windows that have an input
   context (Nexon Plug, password fields that turn the IME off on purpose in other programs) are
   unchanged. WINE_MAC_IME_FALLBACK=0/1 overrides the option.
   Auto-repeats of letters the input method used (holding a movement key) skip the input
   method, and whether an input method is active is remembered until the input source
   changes, so held keys cost no round trips to the Cocoa main thread (p3).
"""
import os
import sys

src = sys.argv[1]


def patch(rel, name, old, new, count=1):
    """Replace old with new in src/rel; skip if new is already there."""
    path = os.path.join(src, rel)
    text = open(path, encoding="utf-8").read()
    if new in text:
        print(f"{rel}: {name} already applied")
        return
    n = text.count(old)
    if n == 0 or (count and n != count):
        raise SystemExit(f"{rel}: patch '{name}' expected {count or 'some'} match(es), found {n}")
    open(path, "w", encoding="utf-8").write(text.replace(old, new))
    print(f"{rel}: applied {name} ({n}x)")


def insert_before(rel, name, anchor, block, marker):
    """Insert block before the first anchor in src/rel unless marker is already present."""
    path = os.path.join(src, rel)
    text = open(path, encoding="utf-8").read()
    if marker in text:
        print(f"{rel}: {name} already applied")
        return
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit(f"{rel}: patch '{name}': anchor not found: {anchor[:60]!r}")
    open(path, "w", encoding="utf-8").write(text[:idx] + block + text[idx:])
    print(f"{rel}: applied {name}")


# ---------------------------------------------------------------- 1. ascii-keymap
insert_before("dlls/winemac.drv/cocoa_app.m", "ascii-keymap helper", "@implementation", r'''
/* azur-promilia-launcher: use an ASCII-capable layout for the key map when the current
 * Mac layout can't type ASCII (e.g. 2-Set Hangul). See runtime/patches/apply.py. */
static TISInputSourceRef azur_copy_keymap_layout(void)
{
    TISInputSourceRef layout = TISCopyCurrentKeyboardLayoutInputSource();
    if (layout && !getenv("WINE_MAC_NATIVE_KEYMAP"))
    {
        CFBooleanRef ascii = TISGetInputSourceProperty(layout, kTISPropertyInputSourceIsASCIICapable);
        CFStringRef sid = TISGetInputSourceProperty(layout, kTISPropertyInputSourceID);
        BOOL hangul = sid && (CFStringFind(sid, CFSTR("Hangul"), kCFCompareCaseInsensitive).location != kCFNotFound ||
                              CFStringFind(sid, CFSTR("Korean"), kCFCompareCaseInsensitive).location != kCFNotFound);
        if (!ascii || !CFBooleanGetValue(ascii) || hangul)
        {
            TISInputSourceRef fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
            if (fallback)
            {
                CFRelease(layout);
                layout = fallback;
            }
        }
    }
    return layout;
}

''', "azur_copy_keymap_layout(void)")

patch("dlls/winemac.drv/cocoa_app.m", "ascii-keymap",
      "inputSourceLayout = TISCopyCurrentKeyboardLayoutInputSource();",
      "inputSourceLayout = azur_copy_keymap_layout();", 0)

# ---------------------------------------------------------------- 2. no-layout-switch
patch("dlls/winemac.drv/keyboard.c", "no-layout-switch",
      "if (macdrv_select_input_source(layout->input_source))",
      "if (getenv(\"WINE_MAC_ALLOW_LAYOUT_SWITCH\") ? macdrv_select_input_source(layout->input_source) : TRUE)")

patch("dlls/winemac.drv/keyboard.c", "stdlib.h",
      '#include "config.h"\n\n', '#include "config.h"\n#include <stdlib.h>\n\n')

# ---------------------------------------------------------------- 3. ime-fallback
# Shared declarations
patch("dlls/winemac.drv/macdrv_cocoa.h", "ime-fallback decl",
      "extern bool macdrv_ime_process_key(int keyc, unsigned int flags, int repeat, void *data);\n",
      "extern bool macdrv_ime_process_key(int keyc, unsigned int flags, int repeat, void *data);\n"
      "/* azur-promilia-launcher ime-fallback, see runtime/patches/apply.py */\n"
      "#define MACDRV_AZUR_FALLBACK_HIMC ((void *)(unsigned long)0x415a5552)\n"
      "extern int macdrv_azur_ime_compose_key(int keyc, unsigned int flags, unsigned short *buf, int buflen,\n"
      "                                       bool *consumed);\n")

patch("dlls/winemac.drv/macdrv.h", "ime-fallback decl",
      "extern void macdrv_key_event(HWND hwnd, const macdrv_event *event);\n",
      "extern void macdrv_key_event(HWND hwnd, const macdrv_event *event);\n"
      "extern bool azur_ime_fallback;  /* azur-promilia-launcher ime-fallback */\n"
      "extern void macdrv_azur_send_text(HWND hwnd, const WCHAR *text, int len, unsigned int time);\n")

# Option: Mac Driver "ImeFallback" (per app through AppDefaults), env WINE_MAC_IME_FALLBACK overrides
patch("dlls/winemac.drv/macdrv_main.c", "ime-fallback option var",
      "bool use_precise_scrolling = true;\n",
      "bool use_precise_scrolling = true;\n"
      "bool azur_ime_fallback = false;  /* azur-promilia-launcher ime-fallback */\n")

patch("dlls/winemac.drv/macdrv_main.c", "ime-fallback option read",
      '    if (!get_config_key(hkey, appkey, "UsePreciseScrolling", buffer, sizeof(buffer)))\n',
      '    /* azur-promilia-launcher ime-fallback, see runtime/patches/apply.py */\n'
      '    if (!get_config_key(hkey, appkey, "ImeFallback", buffer, sizeof(buffer)))\n'
      '        azur_ime_fallback = IS_OPTION_TRUE(buffer[0]);\n'
      '    {\n'
      '        const char *env = getenv("WINE_MAC_IME_FALLBACK");\n'
      '        if (env && *env) azur_ime_fallback = IS_OPTION_TRUE(env[0]);\n'
      '    }\n\n'
      '    if (!get_config_key(hkey, appkey, "UsePreciseScrolling", buffer, sizeof(buffer)))\n')

# Cocoa side: capture committed text while our key is being handled
insert_before("dlls/winemac.drv/cocoa_window.m", "ime-fallback capture var", "@implementation", r'''
/* azur-promilia-launcher ime-fallback: text the input method commits while
 * macdrv_azur_ime_compose_key runs (main thread only). */
static NSMutableString* azur_capture_text;

''', "static NSMutableString* azur_capture_text;")

patch("dlls/winemac.drv/cocoa_window.m", "ime-fallback completeText",
      "    - (void) completeText:(NSString*)text\n"
      "    {\n"
      "        macdrv_event* event;\n"
      "        WineWindow* window = (WineWindow*)[self window];\n\n",
      "    - (void) completeText:(NSString*)text\n"
      "    {\n"
      "        macdrv_event* event;\n"
      "        WineWindow* window = (WineWindow*)[self window];\n\n"
      "        if (azur_capture_text && [window himc] == MACDRV_AZUR_FALLBACK_HIMC)\n"
      "        {\n"
      "            if (text) [azur_capture_text appendString:text];\n"
      "            [self clearMarkedText];\n"
      "            return;\n"
      "        }\n\n")

insert_before("dlls/winemac.drv/cocoa_window.m", "ime-fallback compose function",
              "void macdrv_clear_ime_text(void)\n", r'''/***********************************************************************
 *              macdrv_azur_ime_compose_key
 *
 * azur-promilia-launcher ime-fallback: like macdrv_ime_process_key, for windows without a
 * Windows input context. Text the input method commits during the call is returned in buf
 * instead of being posted as IM_SET_TEXT. Returns its length; *consumed tells whether the
 * input method used the key.
 */
int macdrv_azur_ime_compose_key(int keyc, unsigned int flags, unsigned short *buf, int buflen, bool *consumed)
{
    __block int len = 0;
    __block bool ret = false;

    OnMainThread(^{
        WineWindow* window = (WineWindow*)[NSApp keyWindow];
        if (![window isKindOfClass:[WineWindow class]])
        {
            window = (WineWindow*)[NSApp mainWindow];
            if (![window isKindOfClass:[WineWindow class]])
                window = [[WineApplicationController sharedController] frontWineWindow];
        }

        if (window)
        {
            NSUInteger localFlags = flags;
            CGEventRef c;
            NSEvent* event;

            fix_device_modifiers_by_generic(&localFlags);
            c = CGEventCreateKeyboardEvent(NULL, keyc, true);
            CGEventSetFlags(c, localFlags);
            event = [NSEvent eventWithCGEvent:c];
            CFRelease(c);

            window.himc = MACDRV_AZUR_FALLBACK_HIMC;
            window.commandDone = FALSE;
            azur_capture_text = [[NSMutableString alloc] init];
            ret = [[[window contentView] inputContext] handleEvent:event] && !window.commandDone;
            len = MIN((int)[azur_capture_text length], buflen);
            if (len > 0) [azur_capture_text getCharacters:buf range:NSMakeRange(0, len)];
            [azur_capture_text release];
            azur_capture_text = nil;
        }
    });

    *consumed = ret;
    return len;
}

''', "int macdrv_azur_ime_compose_key(")

# Commits that happen outside a key press (focus change, input source switch) arrive as
# IM_SET_TEXT with our marker; send them as Unicode input too.
patch("dlls/winemac.drv/event.c", "ime-fallback async commit",
      "    if (event->im_set_text.complete) post_ime_update(hwnd, -1, NULL, text);\n",
      "    if (event->im_set_text.himc == MACDRV_AZUR_FALLBACK_HIMC)\n"
      "    {\n"
      "        /* azur-promilia-launcher ime-fallback: no IME context, send committed text as input */\n"
      "        if (event->im_set_text.complete && text && text[0])\n"
      "            macdrv_azur_send_text(hwnd, text, lstrlenW(text), 0);\n"
      "        free(text);\n"
      "        return;\n"
      "    }\n\n"
      "    if (event->im_set_text.complete) post_ime_update(hwnd, -1, NULL, text);\n")

# Key path
insert_before("dlls/winemac.drv/keyboard.c", "ime-fallback key handler",
              "/***********************************************************************\n"
              " *              macdrv_key_event\n", r'''/***********************************************************************
 *              azur-promilia-launcher ime-fallback (see runtime/patches/apply.py)
 */
#define AZUR_IME_EXTRA 0x415a5552  /* dwExtraInfo: TranslateMessage makes no character */
enum { AZUR_KEY_UP, AZUR_KEY_DOWN, AZUR_KEY_LETTER, AZUR_KEY_DROPPED };
static BYTE azur_key_state[128];
static int azur_im_cache = -1;  /* is a Mac input method active? -1 = ask Cocoa again */
static unsigned int azur_im_time;

/* Asking Cocoa means a round trip to the main thread, so remember the answer. It is reset
 * when the input source changes (macdrv_keyboard_changed) and re-checked every 2 s. */
static BOOL azur_using_input_method(unsigned int now)
{
    if (azur_im_cache < 0 || now - azur_im_time > 2000)
    {
        azur_im_cache = macdrv_using_input_method();
        azur_im_time = now;
    }
    return azur_im_cache;
}

static void azur_send_key_no_char(HWND hwnd, WORD vkey, WORD scan, DWORD flags, unsigned int time)
{
    INPUT input;

    memset(&input, 0, sizeof(input));
    input.type           = INPUT_KEYBOARD;
    input.ki.wVk         = vkey;
    input.ki.wScan       = scan & 0xff;
    input.ki.dwFlags     = flags;
    input.ki.time        = time;
    input.ki.dwExtraInfo = AZUR_IME_EXTRA;
    NtUserSendHardwareInput(hwnd, 0, &input, 0);
}

void macdrv_azur_send_text(HWND hwnd, const WCHAR *text, int len, unsigned int time)
{
    INPUT input;
    int i;

    for (i = 0; i < len; i++)
    {
        memset(&input, 0, sizeof(input));
        input.type          = INPUT_KEYBOARD;
        input.ki.wScan      = text[i];
        input.ki.dwFlags    = KEYEVENTF_UNICODE;
        input.ki.time       = time;
        NtUserSendHardwareInput(hwnd, 0, &input, 0);
        input.ki.dwFlags    = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        NtUserSendHardwareInput(hwnd, 0, &input, 0);
    }
}

static BOOL azur_ime_fallback_key(HWND hwnd, const macdrv_event *event, WORD vkey, WORD scan, DWORD flags)
{
    unsigned int keyc = event->key.keycode;
    WCHAR text[64];
    bool consumed = false;
    HWND focus;
    int len;

    if (keyc >= ARRAY_SIZE(azur_key_state)) return FALSE;
    if (event->type == KEY_RELEASE)
    {
        BYTE state = azur_key_state[keyc];
        azur_key_state[keyc] = AZUR_KEY_UP;
        return state == AZUR_KEY_DROPPED;  /* the input method used its key press */
    }
    if (!azur_ime_fallback) return FALSE;

    /* Auto-repeat of a letter the input method used (holding W to move): send the key
     * press again without a character and without asking the input method. */
    if (azur_key_state[keyc] == AZUR_KEY_LETTER)
    {
        azur_send_key_no_char(hwnd, vkey, scan, flags, event->key.time_ms);
        return TRUE;
    }
    azur_key_state[keyc] = AZUR_KEY_DOWN;

    switch (vkey)
    {
    case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT:
    case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
    case VK_MENU: case VK_LMENU: case VK_RMENU:
    case VK_LWIN: case VK_RWIN: case VK_CAPITAL: case VK_APPS:
        return FALSE;
    }
    if (event->key.modifiers & (NX_CONTROLMASK | NX_COMMANDMASK | NX_ALTERNATEMASK)) return FALSE;
    if (!(focus = get_focus())) focus = hwnd;
    if (!focus || NtUserGetWindowInputContext(focus)) return FALSE;  /* normal IME path */
    if (!azur_using_input_method(event->key.time_ms)) return FALSE;

    len = macdrv_azur_ime_compose_key(keyc, (unsigned int)event->key.modifiers, text, ARRAY_SIZE(text), &consumed);
    TRACE_(key)("ime-fallback: keyc %u vkey %#x consumed %d text %s\n", keyc, vkey, consumed,
                debugstr_wn(text, len));
    if (len > 0) macdrv_azur_send_text(hwnd, text, len, event->key.time_ms);
    if (!consumed) return FALSE;  /* send the key as usual, after the committed text */

    switch (vkey)
    {
    case VK_BACK: case VK_DELETE: case VK_RETURN: case VK_TAB: case VK_ESCAPE:
    case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN:
    case VK_HOME: case VK_END: case VK_PRIOR: case VK_NEXT:
        /* e.g. Backspace inside a syllable: the game never saw that syllable */
        azur_key_state[keyc] = AZUR_KEY_DROPPED;
        return TRUE;
    }

    /* Letter keys: keep the key press for game controls, but no character for it. */
    azur_key_state[keyc] = AZUR_KEY_LETTER;
    azur_send_key_no_char(hwnd, vkey, scan, flags, event->key.time_ms);
    return TRUE;
}


''', "static BOOL azur_ime_fallback_key(")

patch("dlls/winemac.drv/keyboard.c", "ime-fallback hook",
      "    if (scan & 0x100)               flags |= KEYEVENTF_EXTENDEDKEY;\n\n"
      "    macdrv_send_keyboard_input(hwnd, vkey, scan & 0xff, flags, event->key.time_ms);\n",
      "    if (scan & 0x100)               flags |= KEYEVENTF_EXTENDEDKEY;\n\n"
      "    if (azur_ime_fallback_key(hwnd, event, vkey, scan, flags)) return;\n\n"
      "    macdrv_send_keyboard_input(hwnd, vkey, scan & 0xff, flags, event->key.time_ms);\n")

patch("dlls/winemac.drv/keyboard.c", "ime-fallback input source changed",
      "    struct macdrv_thread_data *thread_data = macdrv_thread_data();\n\n"
      "    TRACE(\"new keyboard layout uchr data %p, type %u, iso %d\\n\", event->keyboard_changed.uchr,\n",
      "    struct macdrv_thread_data *thread_data = macdrv_thread_data();\n\n"
      "    azur_im_cache = -1;  /* azur-promilia-launcher ime-fallback: input source changed */\n"
      "    memset(azur_key_state, 0, sizeof(azur_key_state));\n\n"
      "    TRACE(\"new keyboard layout uchr data %p, type %u, iso %d\\n\", event->keyboard_changed.uchr,\n")

patch("dlls/win32u/message.c", "ime-fallback no char",
      "    if (msg->message != WM_KEYDOWN && msg->message != WM_SYSKEYDOWN) return TRUE;\n\n",
      "    if (msg->message != WM_KEYDOWN && msg->message != WM_SYSKEYDOWN) return TRUE;\n\n"
      "    /* azur-promilia-launcher ime-fallback: winemac.drv already sent this key's text */\n"
      "    if (NtUserGetThreadInfo()->message_extra == 0x415a5552 && msg->wParam != VK_PACKET) return TRUE;\n\n")

print("all patches applied")
