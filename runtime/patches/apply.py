"""Small, targeted patches applied to the CrossOver Wine source before building.

usage: python3 -I runtime/patches/apply.py <wine source dir>

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
"""
import os
import re
import sys

src = sys.argv[1]


def patch(rel, replacements):
    path = os.path.join(src, rel)
    text = open(path, encoding="utf-8").read()
    for name, old, new, count in replacements:
        n = text.count(old) if isinstance(old, str) else len(re.findall(old, text))
        if n == 0 or (count and n != count):
            raise SystemExit(f"{rel}: patch '{name}' expected {count or 'some'} match(es), found {n}")
        text = text.replace(old, new) if isinstance(old, str) else re.sub(old, new, text)
        print(f"{rel}: applied {name} ({n}x)")
    open(path, "w", encoding="utf-8").write(text)


HELPER = r'''
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
'''

# Insert the helper before the first Objective-C @implementation in cocoa_app.m, then use it
# everywhere the current keyboard layout is read.
cocoa = os.path.join(src, "dlls/winemac.drv/cocoa_app.m")
text = open(cocoa, encoding="utf-8").read()
if "azur_copy_keymap_layout" not in text:
    idx = text.find("@implementation")
    if idx < 0:
        raise SystemExit("cocoa_app.m: no @implementation found")
    text = text[:idx] + HELPER + "\n" + text[idx:]
    open(cocoa, "w", encoding="utf-8").write(text)
    print("dlls/winemac.drv/cocoa_app.m: inserted helper")

patch("dlls/winemac.drv/cocoa_app.m", [
    ("ascii-keymap", "inputSourceLayout = TISCopyCurrentKeyboardLayoutInputSource();",
     "inputSourceLayout = azur_copy_keymap_layout();", 0),
])

patch("dlls/winemac.drv/keyboard.c", [
    ("no-layout-switch",
     "if (macdrv_select_input_source(layout->input_source))",
     "if (getenv(\"WINE_MAC_ALLOW_LAYOUT_SWITCH\") ? macdrv_select_input_source(layout->input_source) : TRUE)",
     1),
])

# keyboard.c must have getenv declared (stdlib.h); add it if missing.
kb = os.path.join(src, "dlls/winemac.drv/keyboard.c")
t = open(kb, encoding="utf-8").read()
if "#include <stdlib.h>" not in t:
    t = t.replace('#include "config.h"', '#include "config.h"\n#include <stdlib.h>', 1)
    open(kb, "w", encoding="utf-8").write(t)
    print("dlls/winemac.drv/keyboard.c: added stdlib.h")
print("all patches applied")
