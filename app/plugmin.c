/* plugmin.exe: 넥슨 플러그 창을 최소화해요. azurctl.sh가 게임이 켜지면 Wine 안에서 불러요.
 *
 * 넥슨 플러그는 Wine에서 소프트웨어 렌더링(SwiftShader)으로 화면을 그려요. 게임이 전체 화면이어도 Wine은
 * 넥슨 플러그 창이 가려졌다고 알려 주지 않아서, 게임 내내 CPU를 50~60% 써요. 최소화하면 그리기를 멈춰요.
 *
 *   plugmin.exe          넥슨 플러그의 보이는 창을 최소화해요 (최소화한 창이 없으면 종료 코드 1)
 *   plugmin.exe /restore 최소화된 넥슨 플러그 창을 다시 띄워요 (게임이 꺼진 뒤)
 *   plugmin.exe /list    대상 창만 보여 주고 아무것도 바꾸지 않아요
 *
 * 빌드: x86_64-w64-mingw32-gcc -O2 -municode -mconsole -o plugmin.exe plugmin.c
 */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static BOOL list_only, restore;
static int count;

static BOOL is_plug(DWORD pid)
{
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    wchar_t path[MAX_PATH];
    DWORD n = MAX_PATH;
    BOOL ok = FALSE;

    if (!p) return FALSE;
    if (QueryFullProcessImageNameW(p, 0, path, &n))
    {
        const wchar_t *base = wcsrchr(path, L'\\');
        ok = _wcsicmp(base ? base + 1 : path, L"NexonPlug.exe") == 0;
    }
    CloseHandle(p);
    return ok;
}

static BOOL CALLBACK each_window(HWND hwnd, LPARAM unused)
{
    DWORD pid = 0;
    LONG_PTR exstyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    wchar_t title[256], cls[256];

    /* 넥슨 플러그의 본 창만: 보이고, (최소화할 때는 아직 최소화 전이고 / 되살릴 때는 최소화된), 다른 창에 딸리지 않았고, 제목이 있는 창 */
    if (!IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER)) return TRUE;
    if (restore ? !IsIconic(hwnd) : IsIconic(hwnd)) return TRUE;
    if (exstyle & WS_EX_TOOLWINDOW) return TRUE;
    if (GetWindowTextW(hwnd, title, 256) <= 0) return TRUE;
    GetWindowThreadProcessId(hwnd, &pid);
    if (!is_plug(pid)) return TRUE;

    GetClassNameW(hwnd, cls, 256);
    if (list_only)
        wprintf(L"%p class=%ls style=%08lx\n", (void *)hwnd, cls, (unsigned long)GetWindowLongPtrW(hwnd, GWL_STYLE));
    else if (restore)
        ShowWindowAsync(hwnd, SW_RESTORE);
    else
        ShowWindowAsync(hwnd, SW_SHOWMINNOACTIVE);  /* 다른 창의 포커스를 빼앗지 않아요 */
    count++;
    return TRUE;
}

int wmain(int argc, wchar_t **argv)
{
    list_only = argc > 1 && _wcsicmp(argv[1], L"/list") == 0;
    restore = argc > 1 && _wcsicmp(argv[1], L"/restore") == 0;
    EnumWindows(each_window, 0);
    return count ? 0 : 1;
}
