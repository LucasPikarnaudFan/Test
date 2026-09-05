# ============================================================
#  RBX Executor - Installateur complet
#  Usage : iex (irm "URL_RAW_GITHUB")
#  Installe le DLL + executeur dans C:\Users\<toi>\Desktop\Roblox Game\
# ============================================================
Set-StrictMode -Off
$ErrorActionPreference = "Stop"

$dest = "C:\Users\$env:USERNAME\Desktop\Roblox Game"
$gpp  = "C:\msys64\mingw64\bin\g++.exe"
$src  = "$dest\src"
$hook = "$dest\rbx_hook"

Write-Host ""
Write-Host "  ██████╗ ██████╗ ██╗  ██╗" -ForegroundColor Cyan
Write-Host "  ██╔══██╗██╔══██╗╚██╗██╔╝" -ForegroundColor Cyan
Write-Host "  ██████╔╝██████╔╝ ╚███╔╝ " -ForegroundColor Cyan
Write-Host "  ██╔══██╗██╔══██╗ ██╔██╗ " -ForegroundColor Cyan
Write-Host "  ██║  ██║██████╔╝██╔╝ ██╗" -ForegroundColor Cyan
Write-Host "  ╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝  EXECUTOR INSTALLER" -ForegroundColor Cyan
Write-Host ""

# ── Pre-checks ──────────────────────────────────────────────
if (!(Test-Path $gpp)) {
    Write-Host "[!] g++ introuvable. Installe MSYS2 + MinGW64 d'abord." -ForegroundColor Red
    Write-Host "    https://www.msys2.org/ puis: pacman -S mingw-w64-x86_64-gcc" -ForegroundColor Yellow
    exit 1
}
try { $null = dotnet --version } catch {
    Write-Host "[!] .NET SDK introuvable. Installe .NET 10 SDK." -ForegroundColor Red
    exit 1
}

# ── Dossiers ────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $dest | Out-Null
New-Item -ItemType Directory -Force -Path $src  | Out-Null
New-Item -ItemType Directory -Force -Path $hook | Out-Null
Write-Host "[+] Dossiers crees : $dest" -ForegroundColor Green

# ────────────────────────────────────────────────────────────
#  1) rbx_hook.cpp  (CRT-free, -nostartfiles, extern C DllMain)
# ────────────────────────────────────────────────────────────
Set-Content -Encoding UTF8 -Path "$hook\rbx_hook.cpp" -Value @'
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <psapi.h>

static volatile LONG g_ready = 0;   // 0=scan, 1=pret, 2=echec

typedef int(*loadbuf_t)(void*, const char*, size_t, const char*);
typedef int(*pcall_t)(void*, int, int, int);

static void**    g_stateRef = nullptr;
static loadbuf_t g_load     = nullptr;
static pcall_t   g_pcall    = nullptr;

static void dbg(const char* msg) {
    // C:\Windows\Temp\ toujours accessible, meme depuis un process sandboxe
    HANDLE f = CreateFileA("C:\\Windows\\Temp\\rbx_debug.txt", FILE_APPEND_DATA,
        FILE_SHARE_READ|FILE_SHARE_WRITE,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD w = 0;
    WriteFile(f, msg, (DWORD)lstrlenA(msg), &w, nullptr);
    WriteFile(f, "\r\n", 2, &w, nullptr);
    FlushFileBuffers(f);
    CloseHandle(f);
}

static bool parsePat(const char* pat, BYTE* pb, BOOL* pw, int* plen) {
    int n = 0;
    const char* p = pat;
    while (*p && n < 128) {
        while (*p == ' ') p++;
        if (!*p) break;
        if (*p == '?') {
            pw[n] = TRUE; pb[n] = 0; n++;
            p++; if (*p == '?') p++;
        } else {
            pw[n] = FALSE;
            BYTE b = 0;
            for (int i = 0; i < 2 && *p && *p != ' '; i++, p++) {
                b = (BYTE)(b << 4);
                char c = *p;
                if (c>='0'&&c<='9') b|=(BYTE)(c-'0');
                else if (c>='a'&&c<='f') b|=(BYTE)(c-'a'+10);
                else if (c>='A'&&c<='F') b|=(BYTE)(c-'A'+10);
            }
            pb[n] = b; n++;
        }
    }
    *plen = n;
    return n > 0;
}

static uintptr_t scanMem(uintptr_t base, size_t sz, const char* pat) {
    BYTE pb[128]; BOOL pw[128]; int plen = 0;
    if (!parsePat(pat, pb, pw, &plen) || plen == 0) return 0;
    MEMORY_BASIC_INFORMATION mbi;
    uintptr_t addr = base, end = base + sz;
    while (addr < end) {
        if (!VirtualQuery((LPCVOID)addr, &mbi, sizeof(mbi))) break;
        uintptr_t rEnd = (uintptr_t)mbi.BaseAddress + mbi.RegionSize;
        if (rEnd > end) rEnd = end;
        if (mbi.State == MEM_COMMIT &&
            (mbi.Protect & (PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|
                            PAGE_READONLY|PAGE_READWRITE)) &&
           !(mbi.Protect & PAGE_GUARD)) {
            BYTE* rb = (BYTE*)mbi.BaseAddress;
            SIZE_T rsz = rEnd - (uintptr_t)mbi.BaseAddress;
            for (SIZE_T i = 0; i + (SIZE_T)plen <= rsz; i++) {
                bool ok = true;
                for (int j = 0; j < plen; j++)
                    if (!pw[j] && rb[i+j] != pb[j]) { ok=false; break; }
                if (ok) return (uintptr_t)(rb+i);
            }
        }
        addr = rEnd;
    }
    return 0;
}

static const char* S_PATS[] = {
    "48 8B 05 ?? ?? ?? ?? 48 85 C0 74 ??",
    "48 8B 0D ?? ?? ?? ?? 48 85 C9 74 ??",
    "48 8B 1D ?? ?? ?? ?? 48 85 DB 74 ??",
    nullptr
};
static const char* L_PATS[] = {
    "48 89 5C 24 ?? 48 89 74 24 ?? 57 48 83 EC 30",
    "40 53 55 56 57 41 56 48 83 EC 30",
    "48 89 5C 24 ?? 55 56 57 48 83 EC 20",
    nullptr
};
static const char* C_PATS[] = {
    "40 53 48 83 EC 20 49 8B D8 E8 ?? ?? ?? ??",
    "48 89 5C 24 ?? 57 48 83 EC 20 48 8B FA",
    nullptr
};

static bool findLua() {
    HMODULE mods[256]; DWORD needed = 0;
    HANDLE hP = GetCurrentProcess();
    if (!EnumProcessModules(hP, mods, sizeof(mods), &needed)) return false;
    DWORD cnt = needed / sizeof(HMODULE);
    for (DWORD m = 0; m < cnt; m++) {
        char name[MAX_PATH] = {};
        GetModuleFileNameExA(hP, mods[m], name, MAX_PATH);
        bool isRbx = false;
        for (int i = 0; name[i]; i++) {
            char c0=name[i]|0x20, c1=name[i+1]|0x20, c2=name[i+2]|0x20;
            if (c0=='r'&&c1=='o'&&c2=='b') { isRbx=true; break; }
        }
        if (!isRbx) continue;
        MODULEINFO mi = {};
        GetModuleInformation(hP, mods[m], &mi, sizeof(mi));
        uintptr_t base = (uintptr_t)mi.lpBaseOfDll;
        size_t sz = mi.SizeOfImage;
        for (int sp = 0; S_PATS[sp]; sp++) {
            uintptr_t hit = scanMem(base, sz, S_PATS[sp]);
            if (!hit) continue;
            int rel = *(int*)(hit+3);
            void** sv = (void**)(hit+7+rel);
            if (!sv || !*sv) continue;
            for (int lp = 0; L_PATS[lp]; lp++) {
                uintptr_t lh = scanMem(base, sz, L_PATS[lp]);
                if (!lh) continue;
                for (int cp = 0; C_PATS[cp]; cp++) {
                    uintptr_t ch = scanMem(base, sz, C_PATS[cp]);
                    if (!ch) continue;
                    g_stateRef = sv;
                    g_load = (loadbuf_t)lh;
                    g_pcall = (pcall_t)ch;
                    return true;
                }
            }
        }
    }
    return false;
}

static DWORD WINAPI FinderThread(LPVOID) {
    dbg("[FinderThread] demarre");
    for (int i = 0; i < 180; i++) {
        if (InterlockedCompareExchange(&g_ready, 0, 0) == 1) return 0;
        if (findLua()) {
            InterlockedExchange(&g_ready, 1);
            dbg("[FinderThread] Lua TROUVE !");
            return 0;
        }
        Sleep(1000);
    }
    InterlockedCompareExchange(&g_ready, 2, 0);
    dbg("[FinderThread] echec 180s - mets a jour les patterns");
    return 0;
}

static DWORD WINAPI PipeThread(LPVOID) {
    dbg("[PipeThread] demarre");
    const char* pname = "\\\\.\\pipe\\RbxExec";
    static char buf[65536];

    while (true) {
        HANDLE h = CreateNamedPipeA(pname,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE|PIPE_READMODE_MESSAGE|PIPE_WAIT,
            1, 65536, 65536, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) { Sleep(500); continue; }
        dbg("[PipeThread] pipe ouvert, attente client...");

        BOOL ok = ConnectNamedPipe(h, nullptr);
        if (!ok && GetLastError() != ERROR_PIPE_CONNECTED) {
            CloseHandle(h); continue;
        }
        dbg("[PipeThread] client connecte");

        DWORD rd = 0;
        if (!ReadFile(h, buf, sizeof(buf)-1, &rd, nullptr) || rd == 0) {
            DisconnectNamedPipe(h); CloseHandle(h); continue;
        }
        buf[rd] = '\0';
        dbg("[PipeThread] script recu");

        const char* resp = "ERR:SCAN";
        LONG rdy = InterlockedCompareExchange(&g_ready, 0, 0);

        if (rdy == 1) {
            void* L = g_stateRef ? *g_stateRef : nullptr;
            if (!L) {
                resp = "ERR:NULL";
                dbg("[PipeThread] ERR:NULL - lua_State null");
            } else {
                int r = g_load(L, buf, (size_t)rd, "=rbx");
                if (r == 0) g_pcall(L, 0, -1, 0);
                resp = (r == 0) ? "OK" : "ERR:LOAD";
                dbg(resp);
            }
        } else if (rdy == 2) {
            dbg("[PipeThread] ERR:SCAN - patterns non trouves");
        } else {
            dbg("[PipeThread] ERR:SCAN - scan en cours, attends 5-10s");
        }

        DWORD wr = 0;
        WriteFile(h, resp, (DWORD)lstrlenA(resp), &wr, nullptr);
        DisconnectNamedPipe(h);
        CloseHandle(h);
    }
    return 0;
}

extern "C" __declspec(dllexport) DWORD WINAPI RbxExecute(const char* script, int len) {
    if (!g_stateRef || !*g_stateRef || !g_load || !g_pcall) {
        dbg("[RbxExecute] ERR lua not ready");
        return 1;
    }
    void* L = *g_stateRef;
    int r = g_load(L, script, (size_t)len, "=rbx");
    if (r == 0) g_pcall(L, 0, -1, 0);
    dbg(r == 0 ? "[RbxExecute] OK" : "[RbxExecute] LOAD_ERR");
    return (DWORD)r;
}

extern "C" __declspec(dllexport) DWORD WINAPI ExecFromParam(LPVOID param) {
    dbg("[ExecFromParam] APPELE");
    const char* s = (const char*)param;
    if (!s) { dbg("[ExecFromParam] param NULL"); return 2; }
    bool ok = tryExecScript(s, lstrlenA(s));
    dbg(ok ? "[ExecFromParam] OK" : "[ExecFromParam] ECHEC");
    return ok ? 0 : 1;
}

extern "C" BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        // Retour IMMEDIAT - le thread hijacke tient des locks Roblox (render/physics).
        // Tout blocage ici = deadlock = crash. Zero scan, zero Sleep, zero threads.
        // L'execution Lua se fera via TCtxHijack externe (M10 DirectLua depuis C#).
        auto NtSIT = reinterpret_cast<BOOL(__stdcall*)(HANDLE,ULONG,PVOID,ULONG)>(
            GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtSetInformationThread"));
        if (NtSIT) NtSIT(GetCurrentThread(), 0x11, nullptr, 0);
        dbg("[DllMain] OK - EXECUTE pour executer");
    }
    return TRUE;
}

// Appele depuis ExecFromParam (via TCtxHijack au moment EXECUTE).
// Fait un scan Lua en un seul passage (pas de Sleep/loop = safe en thread game).
static bool tryExecScript(const char* script, int len) {
    dbg("[tryExec] enter");
    if (InterlockedCompareExchange(&g_ready, 0, 0) != 1) {
        dbg("[tryExec] scan lua...");
        if (findLua()) {
            InterlockedExchange(&g_ready, 1);
            dbg("[tryExec] lua TROUVE !");
        } else {
            dbg("[tryExec] lua NON TROUVE - patterns invalides ou trop tot");
            return false;
        }
    } else {
        dbg("[tryExec] lua deja pret");
    }
    void* L = g_stateRef ? *g_stateRef : nullptr;
    if (!L) { dbg("[tryExec] lua_State NULL"); return false; }
    if (!g_load || !g_pcall) { dbg("[tryExec] load/pcall NULL"); return false; }
    int r = g_load(L, script, (size_t)len, "=rbx");
    if (r == 0) g_pcall(L, 0, -1, 0);
    dbg(r == 0 ? "[tryExec] OK - script execute !" : "[tryExec] LOAD_ERR");
    return r == 0;
}
'@
Write-Host "[+] rbx_hook.cpp ecrit" -ForegroundColor Green

# ────────────────────────────────────────────────────────────
#  2) MainForm.cs  — ACG bypass via NtMapViewOfSection
#     MEM_PRIVATE (VirtualAllocEx)  => STATUS_DYNAMIC_CODE_BLOCKED
#     MEM_MAPPED  (NtMapViewOfSection) => execution autorisee par le kernel
# ────────────────────────────────────────────────────────────
Set-Content -Encoding UTF8 -Path "$src\MainForm.cs" -Value @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Windows.Forms;
using System.Drawing;

namespace RBLXExecutor
{
    public class MainForm : Form
    {
        // ── Win32 P/Invoke ──────────────────────────────────────────────────────
        const uint PROCESS_ALL_ACCESS = 0x1F0FFF;

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr GetProcAddress(IntPtr hMod, string name);

        [DllImport("kernel32.dll", EntryPoint="GetProcAddress")]
        static extern IntPtr GetProcAddressOrd(IntPtr hMod, IntPtr ordinal);

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Ansi)]
        static extern IntPtr LoadLibraryA(string name);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr CreateRemoteThread(IntPtr hP, IntPtr attr, uint stkSz,
            IntPtr fn, IntPtr param, uint flags, out uint tid);

        [DllImport("kernel32.dll")]
        static extern uint WaitForSingleObject(IntPtr h, uint ms);

        [DllImport("kernel32.dll")]
        static extern bool GetExitCodeThread(IntPtr h, out uint code);

        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr VirtualAllocEx(IntPtr hP, IntPtr addr, uint sz, uint type, uint prot);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool WriteProcessMemory(IntPtr hP, IntPtr addr, byte[] buf, int sz, out int written);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool VirtualFreeEx(IntPtr hP, IntPtr addr, uint sz, uint type);

        [DllImport("ntdll.dll")]
        static extern int NtCreateSection(
            out IntPtr SectionHandle,
            uint        DesiredAccess,
            IntPtr      ObjectAttributes,
            ref long    MaximumSize,
            uint        SectionPageProtection,
            uint        AllocationAttributes,
            IntPtr      FileHandle);

        [DllImport("ntdll.dll")]
        static extern int NtMapViewOfSection(
            IntPtr   SectionHandle,
            IntPtr   ProcessHandle,
            ref IntPtr BaseAddress,
            UIntPtr  ZeroBits,
            UIntPtr  CommitSize,
            ref long SectionOffset,
            ref UIntPtr ViewSize,
            uint     InheritDisposition,
            uint     AllocationType,
            uint     Win32Protect);

        [DllImport("ntdll.dll")]
        static extern int NtUnmapViewOfSection(IntPtr ProcessHandle, IntPtr BaseAddress);

        [DllImport("ntdll.dll")]
        static extern int NtClose(IntPtr Handle);

        [DllImport("ntdll.dll")]
        static extern int NtQueueApcThread(
            IntPtr ThreadHandle, IntPtr ApcRoutine,
            IntPtr SystemArgument1, IntPtr SystemArgument2, IntPtr SystemArgument3);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

        [DllImport("kernel32.dll")]
        static extern bool Thread32First(IntPtr hSnap, ref THREADENTRY32 lpte);

        [DllImport("kernel32.dll")]
        static extern bool Thread32Next(IntPtr hSnap, ref THREADENTRY32 lpte);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenThread(uint dwDesiredAccess, bool bInheritHandle, uint dwThreadId);

        [DllImport("kernel32.dll")]
        static extern uint SuspendThread(IntPtr hThread);

        [DllImport("kernel32.dll")]
        static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetThreadContext(IntPtr hThread, IntPtr lpContext);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool SetThreadContext(IntPtr hThread, IntPtr lpContext);

        [DllImport("kernel32.dll")]
        static extern bool GetThreadTimes(IntPtr hThread,
            out long creation, out long exit, out long kernel, out long user);

        [DllImport("ntdll.dll")]
        static extern int NtCreateThreadEx(
            out IntPtr ThreadHandle, uint DesiredAccess, IntPtr ObjectAttributes,
            IntPtr ProcessHandle, IntPtr StartRoutine, IntPtr Argument,
            uint CreateFlags, UIntPtr ZeroBits, UIntPtr StackSize,
            UIntPtr MaximumStackSize, IntPtr AttributeList);

        [DllImport("ntdll.dll")]
        static extern int RtlCreateUserThread(
            IntPtr ProcessHandle, IntPtr SecurityDescriptor, bool CreateSuspended,
            uint StackZeroBits, UIntPtr StackReserved, UIntPtr StackCommit,
            IntPtr StartAddress, IntPtr Parameter,
            out IntPtr ThreadHandle, IntPtr ClientId);

        [DllImport("ntdll.dll")]
        static extern int NtResumeThread(IntPtr ThreadHandle, out uint SuspendCount);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool ReadProcessMemory(IntPtr hP, IntPtr addr, byte[] buf, int sz, out int read);

        [StructLayout(LayoutKind.Sequential)]
        struct THREADENTRY32 {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ThreadID;
            public uint th32OwnerProcessID;
            public int  tpBasePri;
            public int  tpDeltaPri;
            public uint dwFlags;
        }

        const string DASH_SCRIPT =
@"-- INFINITE DASHES (Appuie Q pour dash sans cooldown)
local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local UIS = game:GetService('UserInputService')

local player = Players.LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local hrp = char:WaitForChild('HumanoidRootPart', 5)
local dashing = false

local function doDash()
    if dashing or not hrp then return end
    dashing = true
    local dir = hrp.CFrame.LookVector
    hrp.AssemblyLinearVelocity = dir * 130
    task.wait(0.04)
    dashing = false
end

UIS.InputBegan:Connect(function(inp, gp)
    if gp then return end
    if inp.KeyCode == Enum.KeyCode.Q then doDash() end
end)

task.spawn(function()
    while task.wait(0.01) do
        dashing = false
    end
end)

print('[RBX] Infinite Dashes actif - touche Q pour dasher')";

        const string CRASH_SCRIPT =
@"-- CRASH PLAYER (stack overflow Lua VM)
print('[RBX] Envoi du crash...')
local function bomb() return bomb() + bomb() end
local ok, err = pcall(bomb)
print('[RBX] Crash: ' .. tostring(err))
task.spawn(function()
    while true do
        local t = {}
        for i = 1, 10000 do t[i] = Instance.new('Part') end
        task.wait()
    end
end)";

        RichTextBox scriptBox;
        ListBox     logBox;
        Button      injectBtn, execBtn, dashBtn, crashBtn, clearBtn;
        Label       statusLbl;
        bool        injected = false;
        int         _rbxPid      = 0;
        ulong       _remoteDll   = 0;
        byte[]      _dllBytes    = null;

        public MainForm()
        {
            this.Text            = "RBX Executor v2.8 - Sync Scan + 10x Exec";
            this.Size            = new Size(800, 580);
            this.BackColor       = Color.FromArgb(12, 12, 28);
            this.ForeColor       = Color.White;
            this.FormBorderStyle = FormBorderStyle.FixedSingle;
            this.MaximizeBox     = false;
            this.StartPosition   = FormStartPosition.CenterScreen;

            var title = new Label {
                Text      = "◈  R B X   E X E C U T O R",
                Font      = new Font("Consolas", 13, FontStyle.Bold),
                ForeColor = Color.FromArgb(80, 200, 255),
                Location  = new Point(20, 12),
                AutoSize  = true
            };

            statusLbl = new Label {
                Text      = "● Non injecte",
                Font      = new Font("Consolas", 9),
                ForeColor = Color.FromArgb(200, 80, 80),
                Location  = new Point(590, 18),
                AutoSize  = true
            };

            scriptBox = new RichTextBox {
                Location    = new Point(20, 50),
                Size        = new Size(750, 300),
                BackColor   = Color.FromArgb(8, 8, 22),
                ForeColor   = Color.FromArgb(160, 230, 160),
                Font        = new Font("Consolas", 10),
                BorderStyle = BorderStyle.FixedSingle,
                AcceptsTab  = true,
                Text        = "-- Tape ton script ici\nprint('RBX Executor pret')"
            };

            injectBtn = MkBtn("INJECT",    20, 365, Color.FromArgb(30,  90, 200));
            execBtn   = MkBtn("EXECUTE",  140, 365, Color.FromArgb(30, 150,  40));
            dashBtn   = MkBtn("∞ DASHES", 260, 365, Color.FromArgb(100, 40, 180));
            crashBtn  = MkBtn("CRASH",    380, 365, Color.FromArgb(180, 30,  30));
            clearBtn  = MkBtn("CLEAR",    500, 365, Color.FromArgb(50,  50,  50));

            logBox = new ListBox {
                Location    = new Point(20, 410),
                Size        = new Size(750, 125),
                BackColor   = Color.FromArgb(4, 4, 16),
                ForeColor   = Color.FromArgb(170, 170, 170),
                Font        = new Font("Consolas", 9),
                BorderStyle = BorderStyle.FixedSingle
            };

            injectBtn.Click += OnInject;
            execBtn.Click   += OnExec;
            dashBtn.Click   += (s,e) => { scriptBox.Text = DASH_SCRIPT; Log("Script charge: Infinite Dashes"); };
            crashBtn.Click  += (s,e) => { scriptBox.Text = CRASH_SCRIPT; Log("Script charge: Crash Player"); };
            clearBtn.Click  += (s,e) => { logBox.Items.Clear(); };

            this.Controls.AddRange(new Control[] {
                title, statusLbl, scriptBox,
                injectBtn, execBtn, dashBtn, crashBtn, clearBtn,
                logBox
            });
        }

        Button MkBtn(string txt, int x, int y, Color bg) => new Button {
            Text      = txt,
            Location  = new Point(x, y),
            Size      = new Size(110, 34),
            BackColor = bg,
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            Font      = new Font("Consolas", 9, FontStyle.Bold),
            Cursor    = Cursors.Hand
        };

        void Log(string msg) {
            string line = $"[{DateTime.Now:HH:mm:ss}] {msg}";
            if (logBox.InvokeRequired)
                logBox.Invoke(new Action(() => AddLog(line)));
            else
                AddLog(line);
        }
        void AddLog(string line) {
            logBox.Items.Add(line);
            logBox.TopIndex = logBox.Items.Count - 1;
        }

        void SetStatus(string txt, Color c) {
            if (statusLbl.InvokeRequired)
                statusLbl.Invoke(new Action(() => { statusLbl.Text = txt; statusLbl.ForeColor = c; }));
            else { statusLbl.Text = txt; statusLbl.ForeColor = c; }
        }

        void OnInject(object s, EventArgs e) {
            var procs = Process.GetProcessesByName("RobloxPlayerBeta");
            if (procs.Length == 0) {
                Log("[!] Roblox non trouve - lance une partie d'abord");
                return;
            }

            string dllPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, "rbx_hook.dll");
            if (!File.Exists(dllPath)) {
                Log("[!] rbx_hook.dll manquant dans : " + AppDomain.CurrentDomain.BaseDirectory);
                return;
            }

            Log($"[*] Injection dans PID {procs[0].Id} ({procs[0].ProcessName})...");
            SetStatus("● Injection...", Color.Orange);

            byte[] dllRaw = File.ReadAllBytes(dllPath);
            string errMsg = "";
            ulong remBase = 0;
            bool ok = InjectLoadLibrary(procs[0].Id, dllPath, ref errMsg);
            if (!ok) {
                Log($"[~] LoadLibA: {errMsg}");
                Log("[~] Fallback ManualMap + TCtxHijack + APC...");
                ok = ManualMap(procs[0].Id, dllRaw, ref errMsg, out remBase);
            }
            if (ok) {
                Log($"[+] INJECTION OK  ({errMsg})");
                Log("[*] DLL injectee - clique EXECUTE pour lancer le script");
                SetStatus("● Injecte OK", Color.FromArgb(40, 200, 40));
                injected = true;
                _rbxPid    = procs[0].Id;
                _remoteDll = remBase;
                _dllBytes  = dllRaw;
            } else {
                Log($"[-] ECHEC injection: {errMsg}");
                SetStatus("● Echec injection", Color.Red);
            }
        }

        void OnExec(object s, EventArgs e) {
            string script = scriptBox.Text.Trim();
            if (string.IsNullOrEmpty(script)) { Log("[!] Script vide"); return; }
            execBtn.Enabled = false;
            System.Threading.Tasks.Task.Run(() => {
                try { TryAllMethods(script); }
                finally { execBtn.Invoke(new Action(() => execBtn.Enabled = true)); }
            });
        }

        void TryAllMethods(string script) {
            // ── Method 1: Named pipe (PipeThread inside DLL) ─────────────
            Log("[*] M1 NamedPipe...");
            try {
                using var pipe = new NamedPipeClientStream(".", "RbxExec",
                    PipeDirection.InOut, PipeOptions.None);
                pipe.Connect(3000);
                byte[] d = System.Text.Encoding.UTF8.GetBytes(script);
                pipe.Write(d, 0, d.Length);
                pipe.WaitForPipeDrain();
                byte[] resp = new byte[256];
                int rd = pipe.Read(resp, 0, resp.Length);
                string r = System.Text.Encoding.ASCII.GetString(resp, 0, rd);
                if (r == "OK") { Log("[+] M1 NamedPipe OK !"); return; }
                Log($"[-] M1 reponse: {r}");
            } catch { Log("[-] M1 pipe absent"); }

            // Need DLL injected for remaining methods
            if (_remoteDll == 0 || _dllBytes == null) {
                Log("[!] DLL non injectee - INJECT d'abord"); return;
            }
            var rprocs = Process.GetProcessesByName("RobloxPlayerBeta");
            if (rprocs.Length == 0) { Log("[!] Roblox mort"); return; }
            int pid = rprocs[0].Id;

            // Find ExecFromParam export RVA in local DLL bytes
            ulong execRva = FindExport(_dllBytes, "ExecFromParam");
            if (execRva == 0) { Log("[-] ExecFromParam export introuvable"); return; }
            ulong execAddr = _remoteDll + execRva;
            Log($"[*] ExecFromParam @ 0x{execAddr:X}");

            IntPtr hP = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
            if (hP == IntPtr.Zero) { Log("[-] OpenProcess fail"); return; }

            // Map script string into Roblox via NtMapViewOfSection
            byte[] sb = System.Text.Encoding.UTF8.GetBytes(script + "\0");
            long sSecSz = ((long)sb.Length + 0xFFF) & ~0xFFFL;
            IntPtr hSSec; IntPtr remSc = IntPtr.Zero;
            int nt2 = NtCreateSection(out hSSec, 0xF001F, IntPtr.Zero,
                ref sSecSz, 0x04, 0x8000000, IntPtr.Zero);
            if (nt2 == 0) {
                IntPtr locSc = IntPtr.Zero; long soff = 0; UIntPtr svz = UIntPtr.Zero;
                NtMapViewOfSection(hSSec, GetCurrentProcess(), ref locSc,
                    UIntPtr.Zero, UIntPtr.Zero, ref soff, ref svz, 2, 0, 0x04);
                if (locSc != IntPtr.Zero) {
                    Marshal.Copy(sb, 0, locSc, sb.Length);
                    NtUnmapViewOfSection(GetCurrentProcess(), locSc);
                }
                soff = 0; svz = UIntPtr.Zero;
                NtMapViewOfSection(hSSec, hP, ref remSc,
                    UIntPtr.Zero, UIntPtr.Zero, ref soff, ref svz, 2, 0, 0x02);
                NtClose(hSSec);
            }
            if (remSc == IntPtr.Zero) { Log("[-] Map script echec"); CloseHandle(hP); return; }
            Log($"[*] Script mapped @ 0x{(ulong)remSc:X}");
            ulong scriptPtr = (ulong)remSc;

            bool ok = false;

            // ── Method 2: TCtxHijack → ExecFromParam ────────────────────
            if (!ok) { Log("[*] M2 TCtxHijack-Exec..."); ok = TryTCtxHijackExec(hP, pid, scriptPtr, execAddr, "M2"); }

            // ── Method 3: NtCreateThreadEx flags=0 ──────────────────────
            if (!ok) { Log("[*] M3 NtCTEx-0..."); ok = TryNtCTEx(hP, execAddr, remSc, 0u, "M3"); }

            // ── Method 4: NtCreateThreadEx flags=0x4 (SKIP_ATTACH) ──────
            if (!ok) { Log("[*] M4 NtCTEx-SkipAttach..."); ok = TryNtCTEx(hP, execAddr, remSc, 0x4u, "M4"); }

            // ── Method 5: NtCreateThreadEx flags=0x80000 ────────────────
            if (!ok) { Log("[*] M5 NtCTEx-0x80000..."); ok = TryNtCTEx(hP, execAddr, remSc, 0x80000u, "M5"); }

            // ── Method 6: RtlCreateUserThread ───────────────────────────
            if (!ok) { Log("[*] M6 RtlCreateUserThread..."); ok = TryRtlCUT(hP, execAddr, remSc, "M6"); }

            // ── Method 7: NtQueueApcThread spray ────────────────────────
            if (!ok) { Log("[*] M7 ApcSpray..."); ok = TryApcSpray(hP, pid, (IntPtr)execAddr, remSc, "M7"); }

            // ── Method 8: TCtxHijack-Exec 2nd pass (different thread) ───
            if (!ok) { Log("[*] M8 TCtxHijack-Exec 2nd pass..."); ok = TryTCtxHijackExec(hP, pid, scriptPtr, execAddr, "M8"); }

            // ── Method 9: NtCreateThreadEx SUSPENDED + NtResumeThread ───
            if (!ok) {
                Log("[*] M9 NtCTEx-SUSPENDED...");
                IntPtr hTh9 = IntPtr.Zero;
                int r9 = NtCreateThreadEx(out hTh9, 0x1F03FF, IntPtr.Zero,
                    hP, (IntPtr)execAddr, remSc, 0x1u,
                    UIntPtr.Zero, UIntPtr.Zero, UIntPtr.Zero, IntPtr.Zero);
                if (r9 == 0 && hTh9 != IntPtr.Zero) {
                    uint sc9;
                    NtResumeThread(hTh9, out sc9);
                    WaitForSingleObject(hTh9, 5000);
                    uint ec9 = 0; GetExitCodeThread(hTh9, out ec9);
                    CloseHandle(hTh9);
                    ok = (ec9 == 0);
                    Log(ok ? "[+] M9 OK" : $"[-] M9 exitCode=0x{ec9:X}");
                } else { Log($"[-] M9 NtCTEx=0x{(uint)r9:X8}"); }
            }

            // ── Method 10: Direct lua shellcode (no DLL needed) ─────────
            if (!ok) { Log("[*] M10 DirectLuaShellcode..."); ok = TryDirectLua(hP, pid, remSc, (uint)(sb.Length - 1)); }

            if (!ok) {
                Log("[!] 10/10 methodes echouees");
                Log("[!] Verif rbx_debug.txt - si vide: DllMain n'a pas run");
            }
            CloseHandle(hP);
        }

        // ── RVA → raw file offset using section table ──────────────────
        static uint RvaToFO(byte[] raw, int pe, int numSec, int secOff, uint rva) {
            for (int i = 0; i < numSec; i++) {
                int   sh   = secOff + i * 40;
                uint  vA   = BitConverter.ToUInt32(raw, sh + 12);
                uint  vSz  = BitConverter.ToUInt32(raw, sh +  8);
                uint  rOff = BitConverter.ToUInt32(raw, sh + 20);
                uint  rSz  = BitConverter.ToUInt32(raw, sh + 16);
                uint  span = (vSz > rSz ? rSz : vSz);
                if (rva >= vA && rva < vA + span && rOff > 0)
                    return rOff + (rva - vA);
            }
            return 0;
        }

        // ── FindExport: parse PE export directory (raw file bytes) ──────
        // Returns the export's RVA (add to _remoteDll for absolute addr)
        static ulong FindExport(byte[] raw, string name) {
            if (raw.Length < 0x40) return 0;
            int pe     = BitConverter.ToInt32(raw, 0x3C);
            int oh     = pe + 24;
            if (BitConverter.ToUInt16(raw, oh) != 0x020B) return 0;
            int optSz  = BitConverter.ToUInt16(raw, pe + 20);
            int numSec = BitConverter.ToUInt16(raw, pe + 6);
            int secOff = pe + 24 + optSz;
            int dd     = oh + 112;
            uint expRva = BitConverter.ToUInt32(raw, dd);
            if (expRva == 0) return 0;
            // Translate export directory RVA → file offset
            uint expFO = RvaToFO(raw, pe, numSec, secOff, expRva);
            if (expFO == 0 || expFO + 40 > raw.Length) return 0;
            uint nNames  = BitConverter.ToUInt32(raw, (int)expFO + 24);
            uint addrRva = BitConverter.ToUInt32(raw, (int)expFO + 28);
            uint nameRva = BitConverter.ToUInt32(raw, (int)expFO + 32);
            uint ordRva  = BitConverter.ToUInt32(raw, (int)expFO + 36);
            uint addrFO  = RvaToFO(raw, pe, numSec, secOff, addrRva);
            uint nameFO  = RvaToFO(raw, pe, numSec, secOff, nameRva);
            uint ordFO   = RvaToFO(raw, pe, numSec, secOff, ordRva);
            if (addrFO == 0 || nameFO == 0 || ordFO == 0) return 0;
            for (uint i = 0; i < nNames && nameFO + i*4 + 4 <= raw.Length; i++) {
                uint nRva = BitConverter.ToUInt32(raw, (int)(nameFO + i*4));
                uint nFO  = RvaToFO(raw, pe, numSec, secOff, nRva);
                if (nFO == 0 || nFO >= raw.Length) continue;
                int ns = (int)nFO, ne = ns;
                while (ne < raw.Length && raw[ne] != 0) ne++;
                string eName = System.Text.Encoding.ASCII.GetString(raw, ns, ne - ns);
                if (eName != name) continue;
                ushort ord  = BitConverter.ToUInt16(raw, (int)(ordFO + i*2));
                uint fnRva  = BitConverter.ToUInt32(raw, (int)(addrFO + ord*4));
                return fnRva;  // RVA — add to _remoteDll for absolute addr
            }
            return 0;
        }

        // ── TCtxHijack-Exec: suspend thread, call ExecFromParam ─────────
        bool TryTCtxHijackExec(IntPtr hP, int pid, ulong scriptPtr, ulong execAddr, string tag) {
            // Build exec shellcode block (0x200 bytes):
            // [0..7]   origRip slot
            // [8..15]  scriptPtr
            // [16..23] execAddr
            // [32..]   shellcode calling ExecFromParam(scriptPtr)
            byte[] blk = new byte[0x200];
            Array.Copy(BitConverter.GetBytes(scriptPtr), 0, blk,  8, 8);
            Array.Copy(BitConverter.GetBytes(execAddr),  0, blk, 16, 8);
            byte[] hsc = new byte[] {
                0x4C,0x8B,0x19,             // mov r11,[rcx]      origRip
                0x4C,0x8B,0xD4,             // mov r10,rsp
                0x48,0x83,0xE4,0xF0,        // and rsp,-16
                0x48,0x83,0xEC,0x28,        // sub rsp,0x28
                0x48,0x8B,0x41,0x10,        // mov rax,[rcx+16]   execAddr
                0x48,0x8B,0x49,0x08,        // mov rcx,[rcx+8]    scriptPtr
                0xFF,0xD0,                  // call rax
                0x4D,0x8B,0xE2,             // mov rsp,r10
                0x41,0xFF,0xE3              // jmp r11
            };
            Array.Copy(hsc, 0, blk, 32, hsc.Length);

            long blkSz = 0x200L;
            IntPtr hBlkSec; IntPtr locBlk = IntPtr.Zero, remBlk = IntPtr.Zero;
            int nt = NtCreateSection(out hBlkSec, 0xF001F, IntPtr.Zero,
                ref blkSz, 0x40, 0x8000000, IntPtr.Zero);
            if (nt != 0) return false;
            long o2 = 0; UIntPtr vz = UIntPtr.Zero;
            NtMapViewOfSection(hBlkSec, GetCurrentProcess(), ref locBlk,
                UIntPtr.Zero, UIntPtr.Zero, ref o2, ref vz, 2, 0, 0x04);
            if (locBlk == IntPtr.Zero) { NtClose(hBlkSec); return false; }
            Marshal.Copy(blk, 0, locBlk, blk.Length);
            NtUnmapViewOfSection(GetCurrentProcess(), locBlk);
            o2 = 0; vz = UIntPtr.Zero;
            nt = NtMapViewOfSection(hBlkSec, hP, ref remBlk,
                UIntPtr.Zero, UIntPtr.Zero, ref o2, ref vz, 2, 0, 0x20);
            NtClose(hBlkSec);
            if (nt != 0) return false;

            var tidList = new System.Collections.Generic.List<uint>();
            IntPtr hSnap = CreateToolhelp32Snapshot(0x4, 0);
            if (hSnap != (IntPtr)(-1)) {
                var te = new THREADENTRY32(); te.dwSize = (uint)Marshal.SizeOf<THREADENTRY32>();
                if (Thread32First(hSnap, ref te)) do {
                    if ((int)te.th32OwnerProcessID == pid) tidList.Add(te.th32ThreadID);
                } while (Thread32Next(hSnap, ref te));
                CloseHandle(hSnap);
            }
            tidList.Sort((a,b) => {
                long ka=0,ua=0,kb=0,ub=0,d=0;
                IntPtr ha=OpenThread(0x40,false,a); if(ha!=IntPtr.Zero){GetThreadTimes(ha,out d,out d,out ka,out ua);CloseHandle(ha);}
                IntPtr hb=OpenThread(0x40,false,b); if(hb!=IntPtr.Zero){GetThreadTimes(hb,out d,out d,out kb,out ub);CloseHandle(hb);}
                return (ka+ua).CompareTo(kb+ub);
            });

            bool ok = false;
            foreach (uint tid in tidList) {
                IntPtr hThr = OpenThread(0x1F03FF, false, tid);
                if (hThr == IntPtr.Zero) continue;
                if (SuspendThread(hThr) == 0xFFFFFFFFu) { CloseHandle(hThr); continue; }
                byte[] ctxBuf = new byte[1232+16];
                GCHandle pin = GCHandle.Alloc(ctxBuf, GCHandleType.Pinned);
                IntPtr ctxRaw = pin.AddrOfPinnedObject();
                int ao = (int)((16 - ((long)ctxRaw & 15)) & 15);
                IntPtr ctxPtr = IntPtr.Add(ctxRaw, ao);
                System.Buffer.BlockCopy(BitConverter.GetBytes(0x100003u), 0, ctxBuf, ao+0x30, 4);
                if (GetThreadContext(hThr, ctxPtr)) {
                    ulong origRip = BitConverter.ToUInt64(ctxBuf, ao+0xF8);
                    int wrt;
                    WriteProcessMemory(hP, remBlk, BitConverter.GetBytes(origRip), 8, out wrt);
                    System.Buffer.BlockCopy(BitConverter.GetBytes((ulong)remBlk),    0, ctxBuf, ao+0x80, 8);
                    System.Buffer.BlockCopy(BitConverter.GetBytes((ulong)remBlk+32), 0, ctxBuf, ao+0xF8, 8);
                    if (SetThreadContext(hThr, ctxPtr)) {
                        pin.Free(); ResumeThread(hThr); CloseHandle(hThr);
                        Log($"[+] {tag} TCtxHijack-Exec tid={tid} OK - attends 2s");
                        System.Threading.Thread.Sleep(2000);
                        ok = true; break;
                    }
                }
                pin.Free(); ResumeThread(hThr); CloseHandle(hThr);
            }
            if (!ok) NtUnmapViewOfSection(hP, remBlk);
            return ok;
        }

        // ── NtCreateThreadEx wrapper ────────────────────────────────────
        bool TryNtCTEx(IntPtr hP, ulong execAddr, IntPtr scriptPtr, uint flags, string tag) {
            IntPtr hTh = IntPtr.Zero;
            int r = NtCreateThreadEx(out hTh, 0x1F03FF, IntPtr.Zero,
                hP, (IntPtr)execAddr, scriptPtr, flags,
                UIntPtr.Zero, UIntPtr.Zero, UIntPtr.Zero, IntPtr.Zero);
            if (r != 0 || hTh == IntPtr.Zero) { Log($"[-] {tag} NtCTEx=0x{(uint)r:X8}"); return false; }
            WaitForSingleObject(hTh, 5000);
            uint ec = 0; GetExitCodeThread(hTh, out ec); CloseHandle(hTh);
            bool ok = (ec == 0);
            Log(ok ? $"[+] {tag} OK" : $"[-] {tag} exitCode=0x{ec:X}");
            return ok;
        }

        // ── RtlCreateUserThread ─────────────────────────────────────────
        bool TryRtlCUT(IntPtr hP, ulong execAddr, IntPtr scriptPtr, string tag) {
            IntPtr hTh = IntPtr.Zero;
            int r = RtlCreateUserThread(hP, IntPtr.Zero, false, 0,
                UIntPtr.Zero, UIntPtr.Zero,
                (IntPtr)execAddr, scriptPtr, out hTh, IntPtr.Zero);
            if (r != 0 || hTh == IntPtr.Zero) { Log($"[-] {tag} RtlCUT=0x{(uint)r:X8}"); return false; }
            WaitForSingleObject(hTh, 5000);
            uint ec = 0; GetExitCodeThread(hTh, out ec); CloseHandle(hTh);
            bool ok = (ec == 0);
            Log(ok ? $"[+] {tag} OK" : $"[-] {tag} exitCode=0x{ec:X}");
            return ok;
        }

        // ── APC spray: queue ExecFromParam to all Roblox threads ────────
        bool TryApcSpray(IntPtr hP, int pid, IntPtr execAddr, IntPtr scriptPtr, string tag) {
            int cnt = 0;
            IntPtr hSnap = CreateToolhelp32Snapshot(0x4, 0);
            if (hSnap == (IntPtr)(-1)) return false;
            var te = new THREADENTRY32(); te.dwSize = (uint)Marshal.SizeOf<THREADENTRY32>();
            if (Thread32First(hSnap, ref te)) do {
                if ((int)te.th32OwnerProcessID != pid) continue;
                IntPtr hThr = OpenThread(0x1F03FF, false, te.th32ThreadID);
                if (hThr == IntPtr.Zero) continue;
                if (NtQueueApcThread(hThr, execAddr, scriptPtr, IntPtr.Zero, IntPtr.Zero) == 0) cnt++;
                CloseHandle(hThr);
            } while (Thread32Next(hSnap, ref te));
            CloseHandle(hSnap);
            if (cnt == 0) { Log($"[-] {tag} APC 0 threads"); return false; }
            Log($"[*] {tag} APC queued x{cnt} threads - attends 3s");
            System.Threading.Thread.Sleep(3000);
            return true;
        }

        // ── Method 10: Direct lua shellcode via external pattern scan ───
        // blk10 layout (each field 8-byte aligned):
        //   [0..7]   luaStateAddr  (L value read from global ptr)
        //   [8..15]  luaLoadAddr   (lua_loadbuffer)
        //   [16..23] luaPcallAddr  (lua_pcall)
        //   [24..31] scriptPtr     (remote MEM_MAPPED string)
        //   [32..35] scriptLen     (DWORD)
        //   [36..39] padding
        //   [40..47] "=rbx\0\0\0\0" (tag string inline, 8 bytes)
        //   [48..55] origRip slot  (filled per-thread by WriteProcessMemory)
        //   [56..63] padding
        //   [64..]   shellcode
        bool TryDirectLua(IntPtr hP, int pid, IntPtr scriptPtr, uint scriptLen) {
            ulong luaStateAddr = 0, luaLoadAddr = 0, luaPcallAddr = 0;

            // External scan via ReadProcessMemory
            byte[] rBuf = new byte[0x10000];
            IntPtr cur = (IntPtr)0x10000;
            long limit = 0x7FFFFFFFFFFF;
            bool needState = true, needLoad = true, needPcall = true;
            while ((long)cur < limit && (needState || needLoad || needPcall)) {
                var mbi = new MEMORY_BASIC_INFORMATION();
                if (VirtualQueryEx(hP, cur, ref mbi, (uint)Marshal.SizeOf<MEMORY_BASIC_INFORMATION>()) == 0) break;
                ulong next = (ulong)mbi.BaseAddress + mbi.RegionSize;
                const uint MEM_COMMIT=0x1000, PAGE_NOACCESS=0x01, PAGE_GUARD=0x100;
                if (mbi.State == MEM_COMMIT && (mbi.Protect & PAGE_NOACCESS) == 0 && (mbi.Protect & PAGE_GUARD) == 0) {
                    ulong rStart = (ulong)mbi.BaseAddress;
                    ulong rSize  = mbi.RegionSize;
                    for (ulong off = 0; off + (ulong)rBuf.Length <= rSize; off += (ulong)(rBuf.Length / 2)) {
                        int rd = 0;
                        if (!ReadProcessMemory(hP, (IntPtr)(rStart + off), rBuf, rBuf.Length, out rd) || rd < 15) continue;
                        // lua_State pattern: 48 8B 05 ?? ?? ?? ?? 48 85 C0 74 ??
                        for (int i = 0; i + 12 <= rd && needState; i++) {
                            if (rBuf[i]!=0x48||rBuf[i+1]!=0x8B||rBuf[i+2]!=0x05) continue;
                            if (rBuf[i+7]!=0x48||rBuf[i+8]!=0x85||rBuf[i+9]!=0xC0||rBuf[i+10]!=0x74) continue;
                            int rel = BitConverter.ToInt32(rBuf, i+3);
                            ulong sv = rStart + off + (ulong)i + 7 + (ulong)(long)rel;
                            byte[] pb = new byte[8]; int pr = 0;
                            if (!ReadProcessMemory(hP, (IntPtr)sv, pb, 8, out pr) || pr != 8) continue;
                            ulong L = BitConverter.ToUInt64(pb, 0);
                            if (L > 0x10000 && L < (ulong)limit) { luaStateAddr = L; needState = false; }
                        }
                        // lua_loadbuffer: 48 89 5C 24 ?? 48 89 74 24 ?? 57 48 83 EC 30
                        for (int i = 0; i + 15 <= rd && needLoad; i++) {
                            if (rBuf[i]==0x48&&rBuf[i+1]==0x89&&rBuf[i+2]==0x5C&&rBuf[i+3]==0x24&&
                                rBuf[i+5]==0x48&&rBuf[i+6]==0x89&&rBuf[i+7]==0x74&&rBuf[i+8]==0x24&&
                                rBuf[i+10]==0x57&&rBuf[i+11]==0x48&&rBuf[i+12]==0x83&&rBuf[i+13]==0xEC&&rBuf[i+14]==0x30)
                            { luaLoadAddr = rStart + off + (ulong)i; needLoad = false; }
                        }
                        // lua_pcall: 40 53 48 83 EC 20 49 8B D8 E8 -- or -- 48 89 5C 24 ?? 57 48 83 EC 20 48 8B FA
                        for (int i = 0; i + 11 <= rd && needPcall; i++) {
                            if (rBuf[i]==0x40&&rBuf[i+1]==0x53&&rBuf[i+2]==0x48&&rBuf[i+3]==0x83&&
                                rBuf[i+4]==0xEC&&rBuf[i+5]==0x20&&rBuf[i+6]==0x49&&rBuf[i+7]==0x8B&&rBuf[i+8]==0xD8)
                            { luaPcallAddr = rStart + off + (ulong)i; needPcall = false; }
                        }
                        for (int i = 0; i + 11 <= rd && needPcall; i++) {
                            if (rBuf[i]==0x48&&rBuf[i+1]==0x89&&rBuf[i+2]==0x5C&&rBuf[i+3]==0x24&&
                                rBuf[i+5]==0x57&&rBuf[i+6]==0x48&&rBuf[i+7]==0x83&&rBuf[i+8]==0xEC&&
                                rBuf[i+9]==0x20&&rBuf[i+10]==0x48&&rBuf[i+11-1+1]==0x8B)
                            { luaPcallAddr = rStart + off + (ulong)i; needPcall = false; }
                        }
                    }
                }
                cur = (IntPtr)next;
                if (next == 0 || next > (ulong)limit) break;
            }

            if (luaStateAddr == 0 || luaLoadAddr == 0) {
                Log($"[-] M10 state=0x{luaStateAddr:X} load=0x{luaLoadAddr:X} pcall=0x{luaPcallAddr:X} - patterns manquants");
                return false;
            }
            Log($"[*] M10 state=0x{luaStateAddr:X} load=0x{luaLoadAddr:X} pcall=0x{luaPcallAddr:X}");
            if (luaPcallAddr == 0) {
                Log("[-] M10 lua_pcall non trouve - script charge mais pas execute"); return false;
            }

            // Build shellcode block via NtMapViewOfSection (MEM_MAPPED = ACG-safe)
            byte[] blk10 = new byte[0x400];
            Array.Copy(BitConverter.GetBytes(luaStateAddr),      0, blk10,  0, 8);
            Array.Copy(BitConverter.GetBytes(luaLoadAddr),       0, blk10,  8, 8);
            Array.Copy(BitConverter.GetBytes(luaPcallAddr),      0, blk10, 16, 8);
            Array.Copy(BitConverter.GetBytes((ulong)scriptPtr),  0, blk10, 24, 8);
            Array.Copy(BitConverter.GetBytes(scriptLen),         0, blk10, 32, 4);
            // tag "=rbx\0" at offset 40
            byte[] tag10 = System.Text.Encoding.ASCII.GetBytes("=rbx\0\0\0\0");
            Array.Copy(tag10, 0, blk10, 40, 8);
            // origRip slot at offset 48 (filled by WriteProcessMemory before SetThreadContext)
            // shellcode at offset 64:
            //
            // Calling convention: rcx = remBlk10 (base pointer)
            // We use rbx/rdi/rsi as non-volatile scratch so we survive the calls.
            //
            // push rbx; push rdi; push rsi
            // mov rbx, rcx          ; save base
            // mov rdi, rsp          ; save original rsp
            // and rsp, -16          ; align
            // sub rsp, 0x38         ; shadow space (0x20) + r9 slot + 2 spare
            // mov r11, [rbx+0x30]   ; origRip from offset 48
            // -- lua_loadbuffer(L, script, len, "=rbx") --
            // mov rcx, [rbx+0]      ; L
            // mov rdx, [rbx+24]     ; scriptPtr
            // mov r8d, [rbx+32]     ; scriptLen (zero-extends to r8)
            // lea r9, [rbx+40]      ; "=rbx" tag inline
            // call [rbx+8]          ; lua_loadbuffer
            // test eax, eax
            // jnz skip_pcall        ; load failed, skip pcall
            // -- lua_pcall(L, 0, -1, 0) --
            // mov rcx, [rbx+0]      ; L
            // xor edx, edx          ; nargs=0
            // mov r8d, 0xFFFFFFFF   ; nresults=-1
            // xor r9d, r9d          ; errfunc=0
            // call [rbx+16]         ; lua_pcall
            // skip_pcall:
            // mov rsp, rdi
            // pop rsi; pop rdi; pop rbx
            // jmp r11
            byte[] sc10 = new byte[] {
                0x53,                               // push rbx
                0x57,                               // push rdi
                0x56,                               // push rsi
                0x48,0x89,0xCB,                     // mov rbx, rcx
                0x48,0x89,0xE7,                     // mov rdi, rsp
                0x48,0x83,0xE4,0xF0,                // and rsp, -16
                0x48,0x83,0xEC,0x38,                // sub rsp, 0x38
                0x4C,0x8B,0x5B,0x30,                // mov r11, [rbx+0x30]   origRip@48
                0x48,0x8B,0x0B,                     // mov rcx, [rbx]        L
                0x48,0x8B,0x53,0x18,                // mov rdx, [rbx+0x18]   scriptPtr@24
                0x44,0x8B,0x43,0x20,                // mov r8d, [rbx+0x20]   scriptLen@32
                0x4C,0x8D,0x4B,0x28,                // lea r9, [rbx+0x28]    tag@40
                0xFF,0x53,0x08,                     // call [rbx+8]           lua_loadbuffer
                0x85,0xC0,                          // test eax, eax
                0x75,0x11,                          // jnz skip_pcall (+17 bytes)
                // lua_pcall(L, 0, -1, 0):
                0x48,0x8B,0x0B,                     // mov rcx, [rbx]        L
                0x33,0xD2,                          // xor edx, edx          nargs=0
                0x41,0xB8,0xFF,0xFF,0xFF,0xFF,      // mov r8d, -1           nresults=-1
                0x45,0x33,0xC9,                     // xor r9d, r9d          errfunc=0
                0xFF,0x53,0x10,                     // call [rbx+0x10]        lua_pcall@16
                // skip_pcall:
                0x48,0x89,0xFC,                     // mov rsp, rdi
                0x5E,                               // pop rsi
                0x5F,                               // pop rdi
                0x5B,                               // pop rbx
                0x41,0xFF,0xE3                      // jmp r11
            };
            Array.Copy(sc10, 0, blk10, 64, sc10.Length);

            long blk10Sz = 0x400L;
            IntPtr hB10; IntPtr locB10 = IntPtr.Zero, remB10 = IntPtr.Zero;
            int ntB = NtCreateSection(out hB10, 0xF001F, IntPtr.Zero,
                ref blk10Sz, 0x40, 0x8000000, IntPtr.Zero);
            if (ntB != 0) { Log($"[-] M10 NtCS=0x{(uint)ntB:X8}"); return false; }
            long o10=0; UIntPtr vz10=UIntPtr.Zero;
            NtMapViewOfSection(hB10, GetCurrentProcess(), ref locB10,
                UIntPtr.Zero, UIntPtr.Zero, ref o10, ref vz10, 2, 0, 0x04);
            if (locB10 == IntPtr.Zero) { NtClose(hB10); return false; }
            Marshal.Copy(blk10, 0, locB10, blk10.Length);
            NtUnmapViewOfSection(GetCurrentProcess(), locB10);
            o10=0; vz10=UIntPtr.Zero;
            ntB = NtMapViewOfSection(hB10, hP, ref remB10,
                UIntPtr.Zero, UIntPtr.Zero, ref o10, ref vz10, 2, 0, 0x20);
            NtClose(hB10);
            if (ntB != 0) { Log($"[-] M10 MapRem=0x{(uint)ntB:X8}"); return false; }

            // TCtxHijack: origRip slot at blk offset 48, shellcode at offset 64
            bool ok10 = TryTCtxHijackExecAt(hP, pid, (ulong)remB10, 48, 64);
            Log(ok10 ? "[+] M10 DirectLua OK !" : "[-] M10 TCtxHijack echec");
            return ok10;
        }

        // TCtxHijack with separate origRip slot and shellcode offsets
        bool TryTCtxHijackExecAt(IntPtr hP, int pid, ulong remBlk, int origRipOff, int scOff) {
            var tidList = new System.Collections.Generic.List<uint>();
            IntPtr hSnap = CreateToolhelp32Snapshot(0x4, 0);
            if (hSnap == (IntPtr)(-1)) return false;
            var te = new THREADENTRY32(); te.dwSize = (uint)Marshal.SizeOf<THREADENTRY32>();
            if (Thread32First(hSnap, ref te)) do {
                if ((int)te.th32OwnerProcessID == pid) tidList.Add(te.th32ThreadID);
            } while (Thread32Next(hSnap, ref te));
            CloseHandle(hSnap);

            foreach (uint tid in tidList) {
                IntPtr hThr = OpenThread(0x1F03FF, false, tid);
                if (hThr == IntPtr.Zero) continue;
                if (SuspendThread(hThr) == 0xFFFFFFFFu) { CloseHandle(hThr); continue; }
                byte[] ctxBuf = new byte[1232+16];
                GCHandle pin = GCHandle.Alloc(ctxBuf, GCHandleType.Pinned);
                IntPtr ctxRaw = pin.AddrOfPinnedObject();
                int ao = (int)((16-((long)ctxRaw&15))&15);
                IntPtr ctxPtr = IntPtr.Add(ctxRaw, ao);
                System.Buffer.BlockCopy(BitConverter.GetBytes(0x100003u), 0, ctxBuf, ao+0x30, 4);
                if (GetThreadContext(hThr, ctxPtr)) {
                    ulong origRip = BitConverter.ToUInt64(ctxBuf, ao+0xF8);
                    int wrt;
                    WriteProcessMemory(hP, (IntPtr)(remBlk + (ulong)origRipOff),
                        BitConverter.GetBytes(origRip), 8, out wrt);
                    System.Buffer.BlockCopy(BitConverter.GetBytes(remBlk),         0, ctxBuf, ao+0x80, 8);
                    System.Buffer.BlockCopy(BitConverter.GetBytes(remBlk+(ulong)scOff), 0, ctxBuf, ao+0xF8, 8);
                    if (SetThreadContext(hThr, ctxPtr)) {
                        pin.Free(); ResumeThread(hThr); CloseHandle(hThr); return true;
                    }
                }
                pin.Free(); ResumeThread(hThr); CloseHandle(hThr);
            }
            return false;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORY_BASIC_INFORMATION {
            public IntPtr  BaseAddress;
            public IntPtr  AllocationBase;
            public uint    AllocationProtect;
            public ulong   RegionSize;
            public uint    State;
            public uint    Protect;
            public uint    Type;
        }

        [DllImport("kernel32.dll")]
        static extern uint VirtualQueryEx(IntPtr hP, IntPtr addr,
            ref MEMORY_BASIC_INFORMATION mbi, uint sz);

        static bool InjectLoadLibrary(int pid, string dllPath, ref string err) {
            IntPtr hP = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
            if (hP == IntPtr.Zero) {
                err = $"OP err {Marshal.GetLastWin32Error()}"; return false;
            }

            byte[] pathBytes = System.Text.Encoding.UTF8.GetBytes(dllPath + '\0');
            IntPtr pathMem = VirtualAllocEx(hP, IntPtr.Zero,
                (uint)(pathBytes.Length + 1), 0x3000, 0x04);
            if (pathMem == IntPtr.Zero) {
                CloseHandle(hP);
                err = $"VAllocEx err {Marshal.GetLastWin32Error()}"; return false;
            }

            int wr;
            if (!WriteProcessMemory(hP, pathMem, pathBytes, pathBytes.Length, out wr)) {
                VirtualFreeEx(hP, pathMem, 0, 0x8000);
                CloseHandle(hP);
                err = $"WPM err {Marshal.GetLastWin32Error()}"; return false;
            }

            IntPtr k32  = LoadLibraryA("kernel32.dll");
            IntPtr llA  = GetProcAddress(k32, "LoadLibraryA");
            if (llA == IntPtr.Zero) {
                VirtualFreeEx(hP, pathMem, 0, 0x8000);
                CloseHandle(hP);
                err = "GetProcAddr(LoadLibraryA) = NULL"; return false;
            }

            uint tid;
            IntPtr hThread = CreateRemoteThread(hP, IntPtr.Zero, 0,
                llA, pathMem, 0, out tid);
            if (hThread == IntPtr.Zero) {
                int e2 = Marshal.GetLastWin32Error();
                VirtualFreeEx(hP, pathMem, 0, 0x8000);
                CloseHandle(hP);
                err = $"CRT(LLA) err {e2}"; return false;
            }

            WaitForSingleObject(hThread, 12000);
            uint exitCode = 0;
            GetExitCodeThread(hThread, out exitCode);
            CloseHandle(hThread);
            VirtualFreeEx(hP, pathMem, 0, 0x8000);
            CloseHandle(hP);

            if (exitCode == 0 || exitCode >= 0x80000000u) {
                err = $"LoadLib fail 0x{exitCode:X8} (Hyperion DLL block ou CIG)"; return false;
            }
            err = $"LoadLib ok hMod=0x{exitCode:X8}";
            return true;
        }

        static bool ManualMap(int pid, byte[] raw, ref string err, out ulong remoteDllBase)
        {
            remoteDllBase = 0;
            if (raw.Length < 0x40 || raw[0] != 0x4D || raw[1] != 0x5A)
                { err = "Bad MZ"; return false; }
            int pe = BitConverter.ToInt32(raw, 0x3C);
            if (pe + 4 > raw.Length || BitConverter.ToUInt32(raw, pe) != 0x4550)
                { err = "Bad PE sig"; return false; }

            int oh = pe + 24;
            if (BitConverter.ToUInt16(raw, oh) != 0x020B)
                { err = "Besoin d'un DLL x64"; return false; }

            uint epRva  = BitConverter.ToUInt32(raw, oh + 16);
            ulong ib0   = BitConverter.ToUInt64(raw, oh + 24);
            uint iSz    = BitConverter.ToUInt32(raw, oh + 56);
            uint hSz    = BitConverter.ToUInt32(raw, oh + 60);
            int optSz   = BitConverter.ToUInt16(raw, pe + 20);
            int numSec  = BitConverter.ToUInt16(raw, pe + 6);
            int secOff  = pe + 24 + optSz;

            int  dd     = oh + 112;
            uint impRva = BitConverter.ToUInt32(raw, dd + 8);
            uint relRva = BitConverter.ToUInt32(raw, dd + 40);
            uint relSz  = BitConverter.ToUInt32(raw, dd + 44);

            IntPtr hP = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
            if (hP == IntPtr.Zero)
                { err = $"OpenProcess err {Marshal.GetLastWin32Error()}"; return false; }

            long dllSecSz = ((long)iSz + 0xFFF) & ~0xFFFL;
            IntPtr hDllSec;
            int nt = NtCreateSection(out hDllSec, 0xF001F, IntPtr.Zero,
                ref dllSecSz, 0x40, 0x8000000, IntPtr.Zero);
            if (nt != 0) {
                CloseHandle(hP);
                err = $"NtCreateSection(dll)=0x{(uint)nt:X8}"; return false;
            }

            IntPtr localDll = IntPtr.Zero;
            long   secOff2  = 0L;
            UIntPtr viewSz  = UIntPtr.Zero;
            nt = NtMapViewOfSection(hDllSec, GetCurrentProcess(),
                ref localDll, UIntPtr.Zero, UIntPtr.Zero,
                ref secOff2, ref viewSz, 2, 0, 0x04);
            if (nt != 0) {
                NtClose(hDllSec); CloseHandle(hP);
                err = $"NtMapViewOfSection(local dll)=0x{(uint)nt:X8}"; return false;
            }

            IntPtr remoteDll = IntPtr.Zero;
            secOff2 = 0L; viewSz = UIntPtr.Zero;
            nt = NtMapViewOfSection(hDllSec, hP,
                ref remoteDll, UIntPtr.Zero, UIntPtr.Zero,
                ref secOff2, ref viewSz, 2, 0, 0x40);
            if (nt != 0) {
                NtUnmapViewOfSection(GetCurrentProcess(), localDll);
                NtClose(hDllSec); CloseHandle(hP);
                err = $"NtMapViewOfSection(remote dll)=0x{(uint)nt:X8}"; return false;
            }

            byte[] mp = new byte[iSz];
            uint cpH = Math.Min(hSz, (uint)raw.Length);
            Array.Copy(raw, 0, mp, 0, (int)cpH);

            for (int i = 0; i < numSec; i++) {
                int  sh   = secOff + i * 40;
                uint vRva = BitConverter.ToUInt32(raw, sh + 12);
                uint rSz  = BitConverter.ToUInt32(raw, sh + 16);
                uint rOff = BitConverter.ToUInt32(raw, sh + 20);
                if (rOff == 0 || rSz == 0) continue;
                if (vRva + rSz > iSz) rSz = iSz - vRva;
                uint avail = Math.Min(rSz, (uint)raw.Length - rOff);
                if (avail > 0) Array.Copy(raw, (int)rOff, mp, (int)vRva, (int)avail);
            }

            if (relRva != 0 && relSz != 0) {
                ulong delta = (ulong)remoteDll - ib0;
                uint  rp   = relRva;
                while (rp + 8 <= relRva + relSz) {
                    uint pageRva = BitConverter.ToUInt32(mp, (int)rp);
                    uint blkSz   = BitConverter.ToUInt32(mp, (int)(rp + 4));
                    if (blkSz < 8) break;
                    uint cnt = (blkSz - 8) / 2;
                    for (uint x = 0; x < cnt; x++) {
                        ushort entry = BitConverter.ToUInt16(mp, (int)(rp + 8 + x * 2));
                        if ((entry >> 12) != 10) continue;
                        uint loc = pageRva + (uint)(entry & 0xFFF);
                        if (loc + 8 > iSz) continue;
                        ulong v = BitConverter.ToUInt64(mp, (int)loc) + delta;
                        Array.Copy(BitConverter.GetBytes(v), 0, mp, (int)loc, 8);
                    }
                    rp += blkSz;
                }
            }

            if (impRva != 0) {
                uint id = impRva;
                while (id + 20 <= iSz) {
                    uint oFT   = BitConverter.ToUInt32(mp, (int)id);
                    uint nRva  = BitConverter.ToUInt32(mp, (int)(id + 12));
                    uint ftRva = BitConverter.ToUInt32(mp, (int)(id + 16));
                    if (nRva == 0 && ftRva == 0) break;
                    int ni = (int)nRva, ne = ni;
                    while (ne < mp.Length && mp[ne] != 0) ne++;
                    string dllName = System.Text.Encoding.ASCII.GetString(mp, ni, ne - ni);
                    IntPtr hD = LoadLibraryA(dllName);
                    uint ilt = (oFT != 0) ? oFT : ftRva;
                    uint iat = ftRva;
                    while (ilt + 8 <= iSz && iat + 8 <= iSz) {
                        ulong thunk = BitConverter.ToUInt64(mp, (int)ilt);
                        if (thunk == 0) break;
                        IntPtr fn = IntPtr.Zero;
                        if (hD != IntPtr.Zero) {
                            if ((thunk & 0x8000000000000000UL) != 0) {
                                fn = GetProcAddressOrd(hD, (IntPtr)(thunk & 0xFFFF));
                            } else {
                                int hr = (int)(thunk & 0x7FFFFFFF) + 2;
                                int he = hr;
                                while (he < mp.Length && mp[he] != 0) he++;
                                fn = GetProcAddress(hD, System.Text.Encoding.ASCII.GetString(mp, hr, he - hr));
                            }
                        }
                        if (fn != IntPtr.Zero)
                            Array.Copy(BitConverter.GetBytes((ulong)fn), 0, mp, (int)iat, 8);
                        ilt += 8; iat += 8;
                    }
                    id += 20;
                }
            }

            Marshal.Copy(mp, 0, localDll, (int)iSz);
            NtUnmapViewOfSection(GetCurrentProcess(), localDll);
            NtClose(hDllSec);

            ulong epAbs = (ulong)remoteDll + epRva;

            byte[] sc = new byte[26] {
                0x48,0x83,0xEC,0x28,
                0x48,0x8B,0xC1,
                0xBA,0x01,0x00,0x00,0x00,
                0x4D,0x33,0xC0,
                0x48,0x8B,0x08,
                0xFF,0x50,0x08,
                0x48,0x83,0xC4,0x28,
                0xC3
            };

            byte[] hsc = new byte[] {
                0x48,0x8B,0xC1,
                0x4C,0x8B,0x58,0x30,
                0x4C,0x8B,0xD4,
                0x48,0x83,0xE4,0xF0,
                0x48,0x83,0xEC,0x28,
                0xBA,0x01,0x00,0x00,0x00,
                0x4D,0x33,0xC0,
                0x48,0x8B,0x08,
                0xFF,0x50,0x08,
                0x49,0x8B,0xE2,
                0x41,0xFF,0xE3
            };

            byte[] scBlock = new byte[0x1000];
            Array.Copy(BitConverter.GetBytes((ulong)remoteDll), 0, scBlock,  0, 8);
            Array.Copy(BitConverter.GetBytes(epAbs),            0, scBlock,  8, 8);
            Array.Copy(sc,                                      0, scBlock, 16, 26);
            Array.Copy(hsc,                                     0, scBlock, 64, hsc.Length);

            long scSecSz = 0x1000L;
            IntPtr hScSec;
            nt = NtCreateSection(out hScSec,
                0xF001F, IntPtr.Zero,
                ref scSecSz, 0x40, 0x8000000, IntPtr.Zero);
            if (nt != 0) {
                NtUnmapViewOfSection(hP, remoteDll);
                CloseHandle(hP);
                err = $"NtCreateSection(sc)=0x{(uint)nt:X8}"; return false;
            }

            IntPtr localSc = IntPtr.Zero;
            secOff2 = 0L; viewSz = UIntPtr.Zero;
            NtMapViewOfSection(hScSec, GetCurrentProcess(),
                ref localSc, UIntPtr.Zero, UIntPtr.Zero,
                ref secOff2, ref viewSz, 2, 0, 0x04);

            IntPtr remoteSc = IntPtr.Zero;
            secOff2 = 0L; viewSz = UIntPtr.Zero;
            nt = NtMapViewOfSection(hScSec, hP,
                ref remoteSc, UIntPtr.Zero, UIntPtr.Zero,
                ref secOff2, ref viewSz, 2, 0, 0x20);
            if (nt != 0) {
                NtUnmapViewOfSection(GetCurrentProcess(), localSc);
                NtClose(hScSec);
                NtUnmapViewOfSection(hP, remoteDll);
                CloseHandle(hP);
                err = $"NtMapViewOfSection(remote sc)=0x{(uint)nt:X8}"; return false;
            }

            Marshal.Copy(scBlock, 0, localSc, scBlock.Length);
            NtUnmapViewOfSection(GetCurrentProcess(), localSc);
            NtClose(hScSec);

            uint tid;
            IntPtr hThread = CreateRemoteThread(hP, IntPtr.Zero, 0,
                IntPtr.Add(remoteSc, 16), remoteSc, 0, out tid);

            if (hThread != IntPtr.Zero) {
                WaitForSingleObject(hThread, 8000);
                uint exitCode = 0xDEAD;
                GetExitCodeThread(hThread, out exitCode);
                CloseHandle(hThread);
                if (exitCode == 0 || exitCode == 1) {
                    NtUnmapViewOfSection(hP, remoteSc);
                    CloseHandle(hP);
                    remoteDllBase = (ulong)remoteDll;
                    err = $"MM CRT ok threadExit=0x{exitCode:X}";
                    return true;
                }
            }

            int crtErr = Marshal.GetLastWin32Error();
            bool hijackOk = false;
            {
                var tidList = new List<uint>();
                IntPtr hSnap2 = CreateToolhelp32Snapshot(0x4, 0);
                if (hSnap2 != (IntPtr)(-1)) {
                    var te2 = new THREADENTRY32();
                    te2.dwSize = (uint)Marshal.SizeOf<THREADENTRY32>();
                    if (Thread32First(hSnap2, ref te2)) {
                        do {
                            if ((int)te2.th32OwnerProcessID == pid) tidList.Add(te2.th32ThreadID);
                        } while (Thread32Next(hSnap2, ref te2));
                    }
                    CloseHandle(hSnap2);
                }
                tidList.Sort((a, b) => {
                    long ka=0,ua=0,kb=0,ub=0,dummy=0;
                    IntPtr ha = OpenThread(0x40, false, a);
                    if (ha != IntPtr.Zero) { GetThreadTimes(ha,out dummy,out dummy,out ka,out ua); CloseHandle(ha); }
                    IntPtr hb = OpenThread(0x40, false, b);
                    if (hb != IntPtr.Zero) { GetThreadTimes(hb,out dummy,out dummy,out kb,out ub); CloseHandle(hb); }
                    return (ka+ua).CompareTo(kb+ub);
                });
                foreach (uint htid in tidList) {
                    IntPtr hThr = OpenThread(0x1F03FF, false, htid);
                    if (hThr == IntPtr.Zero) continue;
                    uint suspRet = SuspendThread(hThr);
                    if (suspRet == 0xFFFFFFFFu) { CloseHandle(hThr); continue; }

                    byte[] ctxBuf = new byte[1232 + 16];
                    GCHandle pin = GCHandle.Alloc(ctxBuf, GCHandleType.Pinned);
                    IntPtr ctxRaw = pin.AddrOfPinnedObject();
                    int ao = (int)((16 - ((long)ctxRaw & 15)) & 15);
                    IntPtr ctxPtr = IntPtr.Add(ctxRaw, ao);

                    System.Buffer.BlockCopy(BitConverter.GetBytes(0x100003u), 0, ctxBuf, ao + 0x30, 4);
                    bool gotCtx = GetThreadContext(hThr, ctxPtr);
                    if (gotCtx) {
                        ulong origRip = BitConverter.ToUInt64(ctxBuf, ao + 0xF8);
                        int wrt;
                        WriteProcessMemory(hP, IntPtr.Add(remoteSc, 48),
                            BitConverter.GetBytes(origRip), 8, out wrt);
                        System.Buffer.BlockCopy(BitConverter.GetBytes((ulong)remoteSc),
                            0, ctxBuf, ao + 0x80, 8);
                        System.Buffer.BlockCopy(BitConverter.GetBytes((ulong)remoteSc + 64),
                            0, ctxBuf, ao + 0xF8, 8);
                        bool setOk = SetThreadContext(hThr, ctxPtr);
                        pin.Free();
                        ResumeThread(hThr);
                        CloseHandle(hThr);
                        if (setOk) {
                            hijackOk = true;
                            err = $"TCtx hijack tid={htid} origRip=0x{origRip:X}";
                            break;
                        }
                    } else {
                        pin.Free();
                        ResumeThread(hThr);
                        CloseHandle(hThr);
                    }
                }
            }
            if (hijackOk) { remoteDllBase = (ulong)remoteDll; CloseHandle(hP); return true; }

            bool apcOk = false;
            int  apcCnt = 0;
            IntPtr hSnap = CreateToolhelp32Snapshot(0x4, 0);
            if (hSnap != (IntPtr)(-1)) {
                var te = new THREADENTRY32();
                te.dwSize = (uint)Marshal.SizeOf<THREADENTRY32>();
                if (Thread32First(hSnap, ref te)) {
                    do {
                        if ((int)te.th32OwnerProcessID != pid) continue;
                        IntPtr hThr = OpenThread(0x1F03FF, false, te.th32ThreadID);
                        if (hThr == IntPtr.Zero) continue;
                        int aqr = NtQueueApcThread(hThr,
                            IntPtr.Add(remoteSc, 16), remoteSc,
                            IntPtr.Zero, IntPtr.Zero);
                        if (aqr == 0) { apcCnt++; apcOk = true; }
                        CloseHandle(hThr);
                    } while (Thread32Next(hSnap, ref te));
                }
                CloseHandle(hSnap);
            }

            if (!apcOk) {
                NtUnmapViewOfSection(hP, remoteSc);
                NtUnmapViewOfSection(hP, remoteDll);
                CloseHandle(hP);
                err = $"CRT err {crtErr} + APC echec";
                return false;
            }

            remoteDllBase = (ulong)remoteDll;
            CloseHandle(hP);
            err = $"APC queued x{apcCnt} threads (CRT err {crtErr})";
            return true;
        }

        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
'@
Write-Host "[+] MainForm.cs ecrit (v2.7 10x exec methods bypass)" -ForegroundColor Green

# ────────────────────────────────────────────────────────────
#  3) executor.csproj
# ────────────────────────────────────────────────────────────
Set-Content -Encoding UTF8 -Path "$src\executor.csproj" -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <UseWindowsForms>true</UseWindowsForms>
    <AssemblyName>RBLXExecutor</AssemblyName>
    <Nullable>disable</Nullable>
    <AllowUnsafeBlocks>false</AllowUnsafeBlocks>
    <ImplicitUsings>disable</ImplicitUsings>
  </PropertyGroup>
</Project>
'@
Write-Host "[+] executor.csproj ecrit" -ForegroundColor Green

# ────────────────────────────────────────────────────────────
#  4) Compilation DLL
# ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Compilation rbx_hook.dll ===" -ForegroundColor Cyan

$cpp = "$hook\rbx_hook.cpp"
$dll = "$dest\rbx_hook.dll"

$dbg = "$env:USERPROFILE\Desktop\rbx_debug.txt"
if (Test-Path $dbg) { Remove-Item $dbg -Force }

$gppArgs = "`"$gpp`" -O2 -std=c++17 -shared -nostartfiles -Wl,-e,DllMain " +
           "`"-o`" `"$dll`" `"$cpp`" " +
           "-lkernel32 -lpsapi -static-libgcc -static-libstdc++ -s -Wl,--strip-all 2>&1"

$out = cmd /c $gppArgs
if ($LASTEXITCODE -eq 0) {
    $sz = [math]::Round((Get-Item $dll).Length / 1024)
    Write-Host "[+] rbx_hook.dll compile ! ($sz Ko)" -ForegroundColor Green
} else {
    Write-Host "[-] ERREUR compilation DLL:" -ForegroundColor Red
    Write-Host $out -ForegroundColor Red
    exit 1
}

# ────────────────────────────────────────────────────────────
#  5) Publish EXE
# ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Compilation RBLXExecutor.exe ===" -ForegroundColor Cyan

$pub    = "$dest\publish"
$csproj = "$src\executor.csproj"

$dotnetOut = dotnet publish "$csproj" `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -c Release `
    -o "$pub" 2>&1 | Out-String

if ($LASTEXITCODE -ne 0) {
    Write-Host "[-] ERREUR build .NET:" -ForegroundColor Red
    Write-Host $dotnetOut -ForegroundColor Red
    exit 1
}

$exeSrc = "$pub\RBLXExecutor.exe"
if (!(Test-Path $exeSrc)) {
    Write-Host "[-] EXE introuvable apres publish. Contenu:" -ForegroundColor Red
    Get-ChildItem $pub | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Copy-Item $exeSrc "$dest\RBLXExecutor.exe" -Force
Write-Host "[+] RBLXExecutor.exe copie !" -ForegroundColor Green

# ────────────────────────────────────────────────────────────
#  DONE
# ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   INSTALLATION COMPLETE (v2.7 - 10 exec methods)    ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Fichiers dans : $dest" -ForegroundColor White
Write-Host "    RBLXExecutor.exe  <- l'executeur" -ForegroundColor Cyan
Write-Host "    rbx_hook.dll      <- le DLL injecte" -ForegroundColor Cyan
Write-Host ""
Write-Host "  PROCEDURE :" -ForegroundColor Yellow
Write-Host "  1. Lance Roblox et rejoins une partie" -ForegroundColor White
Write-Host "  2. Lance RBLXExecutor.exe (en Admin si besoin)" -ForegroundColor White
Write-Host "  3. Clique INJECT" -ForegroundColor White
Write-Host "     - Si TCtx hijack ok : 'INJECTION OK (TCtx hijack tid=... origRip=0x...)'" -ForegroundColor White
Write-Host "  4. Attends 10-15 secondes" -ForegroundColor White
Write-Host "  5. Clique EXECUTE" -ForegroundColor White
Write-Host ""
Write-Host "  Debug log: $dbg" -ForegroundColor Gray
Write-Host "  -> INJECT: 'INJECTION OK (TCtx hijack ...)'" -ForegroundColor Gray
Write-Host "  -> EXECUTE teste M1..M10 et log laquelle marche" -ForegroundColor Gray
Write-Host "  -> M10 scanne lua_State de l'exterieur (0 dep thread DLL)" -ForegroundColor Gray
Write-Host ""
