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

// Zero CRT: pas de std::atomic, pas de vector, pas de string
static volatile LONG g_ready = 0;   // 0=scan, 1=pret, 2=echec

typedef int(*loadbuf_t)(void*, const char*, size_t, const char*);
typedef int(*pcall_t)(void*, int, int, int);

static void**    g_stateRef = nullptr;
static loadbuf_t g_load     = nullptr;
static pcall_t   g_pcall    = nullptr;

// ─── Debug: ecrit dans un fichier sur le Bureau ─────────────
static void dbg(const char* msg) {
    char path[MAX_PATH];
    ExpandEnvironmentStringsA("%USERPROFILE%\\Desktop\\rbx_debug.txt", path, MAX_PATH);
    HANDLE f = CreateFileA(path, FILE_APPEND_DATA,
        FILE_SHARE_READ|FILE_SHARE_WRITE,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD w;
    WriteFile(f, msg, (DWORD)lstrlenA(msg), &w, nullptr);
    WriteFile(f, "\r\n", 2, &w, nullptr);
    CloseHandle(f);
}

// ─── Parser de pattern CRT-free ─────────────────────────────
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

// ─── Patterns Lua VM ────────────────────────────────────────
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

// ─── FinderThread ────────────────────────────────────────────
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
    dbg("[FinderThread] echec apres 180s - mettez a jour les patterns");
    return 0;
}

// ─── PipeThread ──────────────────────────────────────────────
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
            dbg("[PipeThread] ERR:SCAN - scan encore en cours, attends 5-10s");
        }

        DWORD wr = 0;
        WriteFile(h, resp, (DWORD)lstrlenA(resp), &wr, nullptr);
        DisconnectNamedPipe(h);
        CloseHandle(h);
    }
    return 0;
}

// ─── DllMain - extern C pour -Wl,-e,DllMain ─────────────────
extern "C" BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        dbg("[DllMain] DLL_PROCESS_ATTACH - injection OK !");

        // Cacher le thread au debugger
        auto NtSIT = reinterpret_cast<BOOL(__stdcall*)(HANDLE,ULONG,PVOID,ULONG)>(
            GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtSetInformationThread"));
        if (NtSIT) NtSIT(GetCurrentThread(), 0x11, nullptr, 0);

        HANDLE h;
        h = CreateThread(nullptr,0,FinderThread,nullptr,0,nullptr);
        if (h) { CloseHandle(h); dbg("[DllMain] FinderThread OK"); }
        else   { dbg("[DllMain] FinderThread FAILED"); }

        h = CreateThread(nullptr,0,PipeThread,nullptr,0,nullptr);
        if (h) { CloseHandle(h); dbg("[DllMain] PipeThread OK"); }
        else   { dbg("[DllMain] PipeThread FAILED"); }
    }
    return TRUE;
}
'@
Write-Host "[+] rbx_hook.cpp ecrit" -ForegroundColor Green

# ────────────────────────────────────────────────────────────
#  2) MainForm.cs
# ────────────────────────────────────────────────────────────
Set-Content -Encoding UTF8 -Path "$src\MainForm.cs" -Value @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Drawing;

namespace RBLXExecutor
{
    public class MainForm : Form
    {
        // ── Win32 P/Invoke ──────────────────────────────────────────────────────
        const uint PROCESS_ALL_ACCESS = 0x1F0FFF;
        const uint MEM_COMMIT   = 0x1000;
        const uint MEM_RESERVE  = 0x2000;
        const uint MEM_RELEASE  = 0x8000;
        const uint PAGE_EXECUTE_READWRITE = 0x40;

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr VirtualAllocEx(IntPtr hP, IntPtr addr, uint sz, uint tp, uint pr);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool VirtualFreeEx(IntPtr hP, IntPtr addr, uint sz, uint tp);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool WriteProcessMemory(IntPtr hP, IntPtr addr, byte[] buf, uint sz, out uint wr);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr CreateRemoteThread(IntPtr hP, IntPtr attr, uint stkSz,
            IntPtr fn, IntPtr param, uint flags, out uint tid);

        [DllImport("kernel32.dll")]
        static extern uint WaitForSingleObject(IntPtr h, uint ms);

        [DllImport("kernel32.dll")]
        static extern bool GetExitCodeThread(IntPtr h, out uint code);

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr GetProcAddress(IntPtr hMod, string name);

        [DllImport("kernel32.dll", EntryPoint="GetProcAddress")]
        static extern IntPtr GetProcAddressOrd(IntPtr hMod, IntPtr ordinal);

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Ansi)]
        static extern IntPtr LoadLibraryA(string name);

        // ── Scripts Lua pre-charges ─────────────────────────────────────────────
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

-- Kill cooldown flag en boucle
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
-- Fallback stress memoire
task.spawn(function()
    while true do
        local t = {}
        for i = 1, 10000 do t[i] = Instance.new('Part') end
        task.wait()
    end
end)";

        // ── UI ─────────────────────────────────────────────────────────────────
        RichTextBox scriptBox;
        ListBox     logBox;
        Button      injectBtn, execBtn, dashBtn, crashBtn, clearBtn;
        Label       statusLbl;
        bool        injected = false;

        public MainForm()
        {
            this.Text            = "RBX Executor v2.1";
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

        void Log(string msg)
        {
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

        // ── Injection ───────────────────────────────────────────────────────────
        void OnInject(object s, EventArgs e)
        {
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

            string errMsg = "";
            bool ok = ManualMap(procs[0].Id, File.ReadAllBytes(dllPath), ref errMsg);
            if (ok) {
                Log($"[+] INJECTION OK  ({errMsg})");
                Log("[*] Attends 5-10s puis clique EXECUTE");
                SetStatus("● Injecte OK", Color.FromArgb(40, 200, 40));
                injected = true;
            } else {
                Log($"[-] ECHEC injection: {errMsg}");
                SetStatus("● Echec injection", Color.Red);
            }
        }

        // ── Execution via Named Pipe ────────────────────────────────────────────
        void OnExec(object s, EventArgs e)
        {
            string script = scriptBox.Text.Trim();
            if (string.IsNullOrEmpty(script)) { Log("[!] Script vide"); return; }

            Log("[*] Envoi du script via pipe...");
            try {
                using var pipe = new NamedPipeClientStream(".", "RbxExec",
                    PipeDirection.InOut, PipeOptions.None);
                pipe.Connect(5000);
                byte[] data = System.Text.Encoding.UTF8.GetBytes(script);
                pipe.Write(data, 0, data.Length);
                pipe.WaitForPipeDrain();
                byte[] resp = new byte[256];
                int rd = pipe.Read(resp, 0, resp.Length);
                string r = System.Text.Encoding.ASCII.GetString(resp, 0, rd);
                if (r == "OK")
                    Log("[+] Script execute avec succes !");
                else
                    Log($"[-] Reponse DLL: {r}");
            }
            catch (TimeoutException) {
                Log("[!] Timeout pipe - clique INJECT d'abord et attends 10s");
            }
            catch (Exception ex) {
                Log($"[-] Pipe error: {ex.Message}");
            }
        }

        // ── Manual PE Mapper (PE32+ x64) ────────────────────────────────────────
        static bool ManualMap(int pid, byte[] raw, ref string err)
        {
            if (raw.Length < 0x40 || raw[0] != 0x4D || raw[1] != 0x5A)
                { err = "Bad MZ header"; return false; }
            int pe = BitConverter.ToInt32(raw, 0x3C);
            if (pe + 4 > raw.Length || BitConverter.ToUInt32(raw, pe) != 0x4550)
                { err = "Bad PE signature"; return false; }

            int oh = pe + 24;
            if (BitConverter.ToUInt16(raw, oh) != 0x020B)
                { err = "Not PE32+ (need x64 DLL)"; return false; }

            uint epRva = BitConverter.ToUInt32(raw, oh + 16);
            ulong ib0  = BitConverter.ToUInt64(raw, oh + 24);
            uint iSz   = BitConverter.ToUInt32(raw, oh + 56);
            uint hSz   = BitConverter.ToUInt32(raw, oh + 60);

            int optSz  = BitConverter.ToUInt16(raw, pe + 20);
            int numSec = BitConverter.ToUInt16(raw, pe + 6);
            int secOff = pe + 24 + optSz;

            int dd      = oh + 112;
            uint impRva = BitConverter.ToUInt32(raw, dd + 8);
            uint relRva = BitConverter.ToUInt32(raw, dd + 40);
            uint relSz  = BitConverter.ToUInt32(raw, dd + 44);

            IntPtr hP = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
            if (hP == IntPtr.Zero)
                { err = $"OpenProcess failed: {Marshal.GetLastWin32Error()}"; return false; }

            IntPtr rm = VirtualAllocEx(hP, IntPtr.Zero, iSz,
                MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
            if (rm == IntPtr.Zero) {
                CloseHandle(hP);
                err = $"VirtualAllocEx failed: {Marshal.GetLastWin32Error()}";
                return false;
            }

            byte[] mp = new byte[iSz];
            uint copyH = Math.Min(hSz, (uint)raw.Length);
            Array.Copy(raw, 0, mp, 0, (int)copyH);

            for (int i = 0; i < numSec; i++) {
                int sh    = secOff + i * 40;
                uint vRva = BitConverter.ToUInt32(raw, sh + 12);
                uint rSz  = BitConverter.ToUInt32(raw, sh + 16);
                uint rOff = BitConverter.ToUInt32(raw, sh + 20);
                if (rOff == 0 || rSz == 0) continue;
                if (vRva + rSz > iSz) rSz = iSz - vRva;
                uint avail = Math.Min(rSz, (uint)raw.Length - rOff);
                if (avail > 0) Array.Copy(raw, (int)rOff, mp, (int)vRva, (int)avail);
            }

            if (relRva != 0 && relSz != 0) {
                ulong delta = (ulong)rm - ib0;
                uint rp = relRva;
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
                        byte[] vb = BitConverter.GetBytes(v);
                        Array.Copy(vb, 0, mp, (int)loc, 8);
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
                        ulong entry = BitConverter.ToUInt64(mp, (int)ilt);
                        if (entry == 0) break;
                        IntPtr fn = IntPtr.Zero;
                        if (hD != IntPtr.Zero) {
                            if ((entry & 0x8000000000000000UL) != 0) {
                                fn = GetProcAddressOrd(hD, (IntPtr)(entry & 0xFFFF));
                            } else {
                                int hr = (int)(entry & 0x7FFFFFFF) + 2;
                                int he = hr;
                                while (he < mp.Length && mp[he] != 0) he++;
                                string fnName = System.Text.Encoding.ASCII.GetString(mp, hr, he - hr);
                                fn = GetProcAddress(hD, fnName);
                            }
                        }
                        if (fn != IntPtr.Zero) {
                            byte[] fb = BitConverter.GetBytes((ulong)fn);
                            Array.Copy(fb, 0, mp, (int)iat, 8);
                        }
                        ilt += 8; iat += 8;
                    }
                    id += 20;
                }
            }

            uint wr;
            if (!WriteProcessMemory(hP, rm, mp, iSz, out wr)) {
                CloseHandle(hP);
                err = $"WriteProcessMemory failed: {Marshal.GetLastWin32Error()}";
                return false;
            }

            ulong epAbs = (ulong)rm + epRva;
            byte[] pd = new byte[16];
            Array.Copy(BitConverter.GetBytes((ulong)rm), 0, pd, 0, 8);
            Array.Copy(BitConverter.GetBytes(epAbs),     0, pd, 8, 8);

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

            byte[] cb = new byte[pd.Length + sc.Length];
            Array.Copy(pd, 0, cb, 0, pd.Length);
            Array.Copy(sc, 0, cb, pd.Length, sc.Length);

            IntPtr rp2 = VirtualAllocEx(hP, IntPtr.Zero, (uint)cb.Length,
                MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
            if (rp2 == IntPtr.Zero) {
                CloseHandle(hP);
                err = $"VirtualAllocEx(shellcode) failed: {Marshal.GetLastWin32Error()}";
                return false;
            }
            WriteProcessMemory(hP, rp2, cb, (uint)cb.Length, out wr);

            uint tid;
            IntPtr ht = CreateRemoteThread(hP, IntPtr.Zero, 0,
                IntPtr.Add(rp2, pd.Length), rp2, 0, out tid);
            if (ht == IntPtr.Zero) {
                VirtualFreeEx(hP, rp2, 0, MEM_RELEASE);
                CloseHandle(hP);
                err = $"CreateRemoteThread failed: {Marshal.GetLastWin32Error()}";
                return false;
            }

            WaitForSingleObject(ht, 5000);
            uint exitCode = 0xDEAD;
            GetExitCodeThread(ht, out exitCode);
            CloseHandle(ht);
            VirtualFreeEx(hP, rp2, 0, MEM_RELEASE);
            CloseHandle(hP);

            err = $"threadExit=0x{exitCode:X}";
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
Write-Host "[+] MainForm.cs ecrit" -ForegroundColor Green

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
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║           INSTALLATION COMPLETE !            ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Fichiers dans : $dest" -ForegroundColor White
Write-Host "    RBLXExecutor.exe  <- l'executeur" -ForegroundColor Cyan
Write-Host "    rbx_hook.dll      <- le DLL injecte" -ForegroundColor Cyan
Write-Host ""
Write-Host "  PROCEDURE :" -ForegroundColor Yellow
Write-Host "  1. Lance Roblox et rejoins une partie" -ForegroundColor White
Write-Host "  2. Lance RBLXExecutor.exe (en Admin si besoin)" -ForegroundColor White
Write-Host "  3. Clique INJECT  (attends 'INJECTION OK')" -ForegroundColor White
Write-Host "  4. Attends 5-10 secondes" -ForegroundColor White
Write-Host "  5. Clique  INFINITE DASHES  ou  CRASH" -ForegroundColor White
Write-Host "  6. Clique EXECUTE" -ForegroundColor White
Write-Host ""
Write-Host "  Debug log: $dbg" -ForegroundColor Gray
Write-Host ""
