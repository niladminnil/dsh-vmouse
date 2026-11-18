#
#
#
#
#
#
#
#
#
#
#
#
#
#
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File vmouse.ps1 -Run '{"cmd":"click","x":480,"y":300}'
param(
    [string]$Run = '',
    [string]$Run64 = '',
    [int]$Hold = 1800
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class VMouseHost
{

    public const int S = 400;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int ULW_ALPHA = 0x00000002;
    public const byte AC_SRC_OVER = 0x00;
    public const byte AC_SRC_ALPHA = 0x01;

    const int WM_MOUSEMOVE = 0x0200;
    const int WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202, WM_LBUTTONDBLCLK = 0x0203;
    const int WM_RBUTTONDOWN = 0x0204, WM_RBUTTONUP = 0x0205, WM_RBUTTONDBLCLK = 0x0206;
    const int WM_MBUTTONDOWN = 0x0207, WM_MBUTTONUP = 0x0208, WM_MBUTTONDBLCLK = 0x0209;
    const int WM_MOUSEWHEEL = 0x020A;
    const int MK_LBUTTON = 0x0001, MK_RBUTTON = 0x0002, MK_MBUTTON = 0x0010;
    const uint GA_ROOT = 2;

    const int VISIBLE_MS = 3200;
    const int FADE_MS = 420;
    const int RIPPLE_MS = 760;
    const int FRAME_MS = 30;

    // ---------- Win32 ----------
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct POINTL { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)]
    struct SIZEL { public int cx; public int cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

    [DllImport("user32.dll", SetLastError = true)] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINTL pptDst, ref SIZEL psize, IntPtr hdcSrc, ref POINTL pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr h);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr hObject);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern void mouse_event(uint dwFlags, int dx, int dy, int dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr hWnd, ref POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr hWndParent, IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);


    static OverlayForm overlay;
    static System.Windows.Forms.Timer animTimer;
    static readonly object outLock = new object();
    static readonly object stateLock = new object();

    static int curX = 0, curY = 0;
    static int fromX = 0, fromY = 0;
    static int toX = 0, toY = 0;
    static long glideStart = 0;
    static bool gliding = false;
    static int lastActivityTick = 0;
    static bool hidden = true;
    static string lastAction = "none";
    static long startedTick = Environment.TickCount;
    public static int HoldMs = 1800;

    sealed class Ripple
    {
        public long Start;
        public int X;
        public int Y;
        public bool Right;
    }
    static readonly List<Ripple> ripples = new List<Ripple>();


    static class J
    {
        public static Dictionary<string, string> Obj(string s)
        {
            Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (string.IsNullOrEmpty(s)) return d;
            int i = 0, n = s.Length;
            SkipWs(s, ref i);
            if (i >= n || s[i] != '{') return d;
            i++;
            while (i < n)
            {
                SkipWs(s, ref i);
                if (i >= n) break;
                if (s[i] == '}') break;
                if (s[i] != '"') break;
                string key = ReadStr(s, ref i);
                SkipWs(s, ref i);
                if (i >= n || s[i] != ':') break;
                i++;
                SkipWs(s, ref i);
                if (i >= n) break;
                string val;
                if (s[i] == '"') val = ReadStr(s, ref i);
                else if (s[i] == '{' || s[i] == '[')
                {
                    int depth = 0; int start = i;
                    while (i < n)
                    {
                        if (s[i] == '{' || s[i] == '[') depth++;
                        else if (s[i] == '}' || s[i] == ']') { depth--; if (depth == 0) { i++; break; } }
                        i++;
                    }
                    val = s.Substring(start, i - start);
                }
                else
                {
                    int start = i;
                    while (i < n && s[i] != ',' && s[i] != '}') i++;
                    val = s.Substring(start, i - start).Trim();
                }
                d[key] = val;
                SkipWs(s, ref i);
                if (i < n && s[i] == ',') i++;
            }
            return d;
        }

        static void SkipWs(string s, ref int i)
        {
            while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
        }

        static string ReadStr(string s, ref int i)
        {
            StringBuilder sb = new StringBuilder();
            i++; // opening quote
            while (i < s.Length)
            {
                char c = s[i++];
                if (c == '"') break;
                if (c == '\\' && i < s.Length)
                {
                    char e = s[i++];
                    switch (e)
                    {
                        case 'n': sb.Append('\n'); break;
                        case 't': sb.Append('\t'); break;
                        case 'r': sb.Append('\r'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'u':
                            if (i + 4 <= s.Length)
                            {
                                sb.Append((char)Convert.ToInt32(s.Substring(i, 4), 16));
                                i += 4;
                            }
                            break;
                        default: sb.Append(e); break;
                    }
                }
                else sb.Append(c);
            }
            return sb.ToString();
        }

        public static int Int(Dictionary<string, string> d, string k, int def)
        {
            string v;
            if (!d.TryGetValue(k, out v) || v == null) return def;
            int r;
            if (int.TryParse(v, out r)) return r;
            double dd;
            if (double.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out dd)) return (int)Math.Round(dd);
            return def;
        }

        public static bool Bool(Dictionary<string, string> d, string k, bool def)
        {
            string v;
            if (!d.TryGetValue(k, out v) || v == null) return def;
            v = v.Trim().ToLowerInvariant();
            if (v == "true" || v == "1" || v == "yes") return true;
            if (v == "false" || v == "0" || v == "no") return false;
            return def;
        }

        public static string Str(Dictionary<string, string> d, string k, string def)
        {
            string v;
            if (!d.TryGetValue(k, out v) || v == null) return def;
            return v;
        }

        public static string Q(string s)
        {
            if (s == null) return "null";
            StringBuilder sb = new StringBuilder("\"");
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }
    }


    public sealed class OverlayForm : Form
    {
        public Bitmap Surface;

        public OverlayForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            Size = new Size(S, S);
            Location = new Point(0, 0);
            BackColor = Color.Black;
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                return cp;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {

        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
        }

        public void Push(int dstX, int dstY)
        {
            if (Surface == null) return;
            IntPtr screenDc = GetDC(IntPtr.Zero);
            IntPtr memDc = CreateCompatibleDC(screenDc);
            IntPtr hBmp = IntPtr.Zero;
            IntPtr old = IntPtr.Zero;
            try
            {
                hBmp = Surface.GetHbitmap(Color.FromArgb(0));
                old = SelectObject(memDc, hBmp);
                POINTL dst;
                dst.x = dstX; dst.y = dstY;
                SIZEL size;
                size.cx = S; size.cy = S;
                POINTL src;
                src.x = 0; src.y = 0;
                BLENDFUNCTION blend;
                blend.BlendOp = AC_SRC_OVER;
                blend.BlendFlags = 0;
                blend.SourceConstantAlpha = 255;
                blend.AlphaFormat = AC_SRC_ALPHA;
                bool ulw = UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, ULW_ALPHA);
                if (!ulw)
                {
                    lastPushError = "UpdateLayeredWindow failed err=" + Marshal.GetLastWin32Error() + " hbmp=" + hBmp.ToInt64() + " memdc=" + memDc.ToInt64() + " dst=" + dstX + "," + dstY;
                }
                else lastPushError = "";
            }
            finally
            {
                if (old != IntPtr.Zero) SelectObject(memDc, old);
                if (hBmp != IntPtr.Zero) DeleteObject(hBmp);
                DeleteDC(memDc);
                ReleaseDC(IntPtr.Zero, screenDc);
            }
        }
    }

    // ---------- DPI ----------
    static void MakeDpiAware()
    {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }


    static PointF[] ArrowPoints()
    {
        float k = 2.0f;
        return new PointF[]
        {
            new PointF(0, 0),
            new PointF(0, 16 * k),
            new PointF(4 * k, 12 * k),
            new PointF(6.5f * k, 18 * k),
            new PointF(9 * k, 17 * k),
            new PointF(6.5f * k, 11.5f * k),
            new PointF(12 * k, 11.5f * k)
        };
    }

    static GraphicsPath PathAt(PointF[] pts, float dx, float dy)
    {
        GraphicsPath p = new GraphicsPath();
        p.AddPolygon(new PointF[]
        {
            new PointF(pts[0].X + dx, pts[0].Y + dy),
            new PointF(pts[1].X + dx, pts[1].Y + dy),
            new PointF(pts[2].X + dx, pts[2].Y + dy),
            new PointF(pts[3].X + dx, pts[3].Y + dy),
            new PointF(pts[4].X + dx, pts[4].Y + dy),
            new PointF(pts[5].X + dx, pts[5].Y + dy),
            new PointF(pts[6].X + dx, pts[6].Y + dy)
        });
        p.CloseFigure();
        return p;
    }

    static string lastDrawError = "";
    static string lastPushError = "";

    static void DrawFrame(double alpha)
    {
        try { DrawFrameCore(alpha); }
        catch (Exception ex) { lastDrawError = ex.GetType().Name + ": " + ex.Message; }
    }

    static void DrawFrameCore(double alpha)
    {
        if (overlay == null || overlay.Surface == null || !overlay.IsHandleCreated) return;
        Graphics g = Graphics.FromImage(overlay.Surface);
        try
        {
            g.Clear(Color.FromArgb(0, 0, 0, 0));
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

            int cx = S / 2;
            int cy = S / 2;
            long now = Environment.TickCount;
            float a = (float)Math.Max(0.0, Math.Min(1.0, alpha));


            lock (stateLock)
            {
                for (int i = ripples.Count - 1; i >= 0; i--)
                {
                    Ripple r = ripples[i];
                    double t = (now - r.Start) / (double)RIPPLE_MS;
                    if (t < 0) continue;
                    if (t > 1.0)
                    {
                        ripples.RemoveAt(i);
                        continue;
                    }
                    float ease = (float)(1.0 - Math.Pow(1.0 - t, 2.2));
                    float rad = 10f + 78f * ease;
                    int alphaRing = (int)(215 * (1.0 - t) * a);
                    if (alphaRing <= 0) continue;
                    Color rc = r.Right ? Color.FromArgb(alphaRing, 251, 146, 60) : Color.FromArgb(alphaRing, 34, 211, 238);
                    using (Pen pen = new Pen(rc, 3.2f))
                    {
                        g.DrawEllipse(pen, cx - rad, cy - rad, rad * 2, rad * 2);
                    }
                    float rad2 = 10f + 78f * ease * 0.62f;
                    int alpha2 = (int)(120 * (1.0 - t) * a);
                    if (alpha2 > 0)
                    {
                        using (Pen pen2 = new Pen(Color.FromArgb(alpha2, 255, 255, 255), 1.6f))
                        {
                            g.DrawEllipse(pen2, cx - rad2, cy - rad2, rad2 * 2, rad2 * 2);
                        }
                    }
                }
            }

            PointF[] pts = ArrowPoints();

            int glow = (int)(120 * a);
            if (glow > 0)
            {
                using (GraphicsPath gp = PathAt(pts, cx, cy))
                using (Pen pen = new Pen(Color.FromArgb(glow, 34, 211, 238), 7f))
                using (Pen pen2 = new Pen(Color.FromArgb((int)(60 * a), 34, 211, 238), 15f))
                {
                    pen.LineJoin = LineJoin.Round;
                    pen2.LineJoin = LineJoin.Round;
                    g.DrawPath(pen2, gp);
                    g.DrawPath(pen, gp);
                }
            }

            using (GraphicsPath sp = PathAt(pts, cx + 2.5f, cy + 3.0f))
            using (SolidBrush sb = new SolidBrush(Color.FromArgb((int)(80 * a), 0, 0, 0)))
            {
                g.FillPath(sb, sp);
            }

            using (GraphicsPath ap = PathAt(pts, cx, cy))
            using (SolidBrush fill = new SolidBrush(Color.FromArgb((int)(252 * a), 255, 255, 255)))
            using (Pen outline = new Pen(Color.FromArgb((int)(255 * a), 15, 23, 42), 2.0f))
            {
                outline.LineJoin = LineJoin.Round;
                g.FillPath(fill, ap);
                g.DrawPath(outline, ap);
            }

            {
                float bx = cx + 30f, by = cy + 26f, br = 12.5f;
                int ba = (int)(255 * a);
                using (SolidBrush badge = new SolidBrush(Color.FromArgb(ba, 6, 182, 212)))
                using (Pen ring = new Pen(Color.FromArgb(ba, 255, 255, 255), 2.0f))
                {
                    g.FillEllipse(badge, bx - br, by - br, br * 2, br * 2);
                    g.DrawEllipse(ring, bx - br, by - br, br * 2, br * 2);
                }
                using (Font f = new Font("Segoe UI", 10.5f, FontStyle.Bold, GraphicsUnit.Pixel))
                using (SolidBrush tb = new SolidBrush(Color.FromArgb(ba, 255, 255, 255)))
                using (StringFormat sf = new StringFormat())
                {
                    sf.Alignment = StringAlignment.Center;
                    sf.LineAlignment = StringAlignment.Center;
                    g.DrawString("AI", f, tb, new RectangleF(bx - br, by - br, br * 2, br * 2), sf);
                }
            }
        }
        finally
        {
            g.Dispose();
        }
        overlay.Push(curX - S / 2, curY - S / 2);
    }


    static void EnsureForm()
    {
        if (overlay != null) return;
        MakeDpiAware();
        overlay = new OverlayForm();
        overlay.Surface = new Bitmap(S, S, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        overlay.Show();
        DrawFrame(0.0);
        animTimer = new System.Windows.Forms.Timer();
        animTimer.Interval = FRAME_MS;
        animTimer.Tick += delegate { OnTick(); };
    }

    static void OnTick()
    {
        long now = Environment.TickCount;
        int idle = (int)(now - lastActivityTick);
        double alpha;
        if (idle > VISIBLE_MS + FADE_MS) alpha = 0.0;
        else if (idle > VISIBLE_MS) alpha = 1.0 - (idle - VISIBLE_MS) / (double)FADE_MS;
        else alpha = 1.0;
        if (alpha <= 0.0)
        {
            hidden = true;
            animTimer.Stop();
            DrawFrame(0.0);
            return;
        }

        if (gliding)
        {
            double t = (now - glideStart) / 220.0;
            if (t >= 1.0)
            {
                curX = toX; curY = toY; gliding = false;
            }
            else
            {
                double e = 1.0 - Math.Pow(1.0 - t, 3.0);
                curX = fromX + (int)Math.Round((toX - fromX) * e);
                curY = fromY + (int)Math.Round((toY - fromY) * e);
            }
        }
        DrawFrame(alpha);
    }

    static void Trigger()
    {
        lock (stateLock)
        {
            lastActivityTick = Environment.TickCount;
            hidden = false;
        }
        if (overlay == null || !overlay.IsHandleCreated) return;
        try
        {
            overlay.BeginInvoke(new Action(delegate
            {
                if (animTimer != null) animTimer.Start();
                OnTick();
            }));
        }
        catch { }
    }

    static void AddRipple(int x, int y, bool right)
    {
        lock (stateLock)
        {
            ripples.Add(new Ripple { Start = Environment.TickCount, X = x, Y = y, Right = right });
        }
    }


    static IntPtr MakeLParam(int x, int y)
    {
        int v = ((y & 0xFFFF) << 16) | (x & 0xFFFF);
        return new IntPtr(v);
    }

    static string WinTitle(IntPtr h)
    {
        if (h == IntPtr.Zero) return "";
        StringBuilder sb = new StringBuilder(512);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    static string WinClass(IntPtr h)
    {
        if (h == IntPtr.Zero) return "";
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    static int WinPid(IntPtr h)
    {
        if (h == IntPtr.Zero) return 0;
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return (int)pid;
    }

    sealed class TargetInfo
    {
        public IntPtr Hwnd;
        public int ClientX;
        public int ClientY;
        public IntPtr Root;
        public string Title;
        public string Class;
        public int Pid;
    }

    static TargetInfo ResolveTarget(int x, int y, string hwndText, string windowTitle)
    {
        POINT spt;
        spt.X = x; spt.Y = y;
        IntPtr under = WindowFromPoint(spt);

        IntPtr explicitHwnd = IntPtr.Zero;
        if (!string.IsNullOrEmpty(hwndText))
        {
            long parsed;
            if (long.TryParse(hwndText, out parsed)) explicitHwnd = new IntPtr(parsed);
            else if (!string.IsNullOrEmpty(windowTitle))
            {
                IntPtr found = FindWindowByTitle(windowTitle);
                if (found != IntPtr.Zero) explicitHwnd = found;
            }
        }
        else if (!string.IsNullOrEmpty(windowTitle))
        {
            explicitHwnd = FindWindowByTitle(windowTitle);
        }

        IntPtr target = under;
        if (explicitHwnd != IntPtr.Zero)
        {
            if (under != IntPtr.Zero && (under == explicitHwnd || IsChild(explicitHwnd, under))) target = under;
            else
            {
                TargetInfo t = new TargetInfo();
                IntPtr deepest = DeepestChildAt(explicitHwnd, x, y);
                t.Hwnd = deepest;
                t.Root = GetAncestor(deepest, GA_ROOT);
                if (t.Root == IntPtr.Zero) t.Root = explicitHwnd;
                t.Title = WinTitle(t.Root);
                t.Class = WinClass(deepest);
                t.Pid = WinPid(t.Root);
                POINT cp2;
                cp2.X = x; cp2.Y = y;
                ScreenToClient(deepest, ref cp2);
                t.ClientX = cp2.X; t.ClientY = cp2.Y;
                return t;
            }
        }

        TargetInfo info = new TargetInfo();
        info.Hwnd = target;
        if (target == IntPtr.Zero)
        {
            info.ClientX = x; info.ClientY = y;
            return info;
        }
        POINT cp;
        cp.X = x; cp.Y = y;
        ScreenToClient(target, ref cp);
        info.ClientX = cp.X;
        info.ClientY = cp.Y;
        info.Root = GetAncestor(target, GA_ROOT);
        if (info.Root == IntPtr.Zero) info.Root = target;
        info.Title = WinTitle(info.Root);
        info.Class = WinClass(target);
        info.Pid = WinPid(info.Root);
        return info;
    }

    static IntPtr FindWindowByTitle(string needle)
    {
        IntPtr found = IntPtr.Zero;
        try
        {
            IntPtr desktop = GetDesktopWindow();
            List<KeyValuePair<IntPtr, string>> list = new List<KeyValuePair<IntPtr, string>>();
            EnumWindows(delegate (IntPtr h, IntPtr p)
            {
                if (IsWindowVisible(h))
                {
                    string t = WinTitle(h);
                    if (t.Length > 0) list.Add(new KeyValuePair<IntPtr, string>(h, t));
                }
                return true;
            }, IntPtr.Zero);
            for (int i = 0; i < list.Count; i++)
            {
                if (list[i].Value.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    found = list[i].Key;
                    break;
                }
            }
        }
        catch { }
        return found;
    }

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern IntPtr ChildWindowFromPointEx(IntPtr hWnd, POINT pt, uint flags);

    static IntPtr DeepestChildAt(IntPtr parent, int screenX, int screenY)
    {
        IntPtr cur = parent;
        for (int depth = 0; depth < 8; depth++)
        {
            POINT p;
            p.X = screenX; p.Y = screenY;
            if (!ScreenToClient(cur, ref p)) break;
            IntPtr child = ChildWindowFromPointEx(cur, p, 3u); // skip invisible | disabled
            if (child == IntPtr.Zero || child == cur) break;
            cur = child;
        }
        return cur;
    }

    static void PostMouse(int msg, int wparam, int cx, int cy, IntPtr target)
    {
        PostMessage(target, msg, new IntPtr(wparam), MakeLParam(cx, cy));
    }


    static TargetInfo DoInjectedClick(int x, int y, string button, int clicks, string hwnd, string window)
    {
        TargetInfo t = ResolveTarget(x, y, hwnd, window);
        if (t.Hwnd == IntPtr.Zero) throw new InvalidOperationException("no window at (" + x + "," + y + ")");

        int down = WM_LBUTTONDOWN, up = WM_LBUTTONUP, dbl = WM_LBUTTONDBLCLK, mk = MK_LBUTTON;
        if (button == "right") { down = WM_RBUTTONDOWN; up = WM_RBUTTONUP; dbl = WM_RBUTTONDBLCLK; mk = MK_RBUTTON; }
        else if (button == "middle") { down = WM_MBUTTONDOWN; up = WM_MBUTTONUP; dbl = WM_MBUTTONDBLCLK; mk = MK_MBUTTON; }

        PostMouse(WM_MOUSEMOVE, 0, t.ClientX, t.ClientY, t.Hwnd);
        Thread.Sleep(20);
        int n = clicks < 1 ? 1 : (clicks > 3 ? 3 : clicks);
        for (int i = 0; i < n; i++)
        {
            int press = (i == 1 && n == 2) ? dbl : down;
            PostMouse(press, mk, t.ClientX, t.ClientY, t.Hwnd);
            Thread.Sleep(28);
            PostMouse(up, 0, t.ClientX, t.ClientY, t.Hwnd);
            if (i < n - 1) Thread.Sleep(70);
        }
        return t;
    }


    static void DoRealMouse(string kind, int x, int y, string button, int clicks, int toX2, int toY2)
    {
        POINT orig;
        GetCursorPos(out orig);
        int down, up;
        down = 0x0002; up = 0x0004;
        if (button == "right") { down = 0x0008; up = 0x0010; }
        else if (button == "middle") { down = 0x0020; up = 0x0040; }
        try
        {
            SetCursorPos(x, y);
            Thread.Sleep(40);
            if (kind == "click")
            {
                int n = clicks < 1 ? 1 : clicks;
                for (int i = 0; i < n; i++)
                {
                    mouse_event((uint)down, 0, 0, 0, UIntPtr.Zero);
                    Thread.Sleep(25);
                    mouse_event((uint)up, 0, 0, 0, UIntPtr.Zero);
                    if (i < n - 1) Thread.Sleep(80);
                }
            }
            else if (kind == "drag")
            {
                mouse_event((uint)down, 0, 0, 0, UIntPtr.Zero);
                Thread.Sleep(60);
                for (int i = 1; i <= 14; i++)
                {
                    int cx = x + (toX2 - x) * i / 14;
                    int cy = y + (toY2 - y) * i / 14;
                    SetCursorPos(cx, cy);
                    Thread.Sleep(12);
                }
                Thread.Sleep(60);
                mouse_event((uint)up, 0, 0, 0, UIntPtr.Zero);
            }
            else if (kind == "scroll")
            {
                mouse_event(0x0800, 0, 0, toY2, UIntPtr.Zero);
            }
        }
        finally
        {
            Thread.Sleep(30);
            SetCursorPos(orig.X, orig.Y);
        }
    }


    static string Exec(Dictionary<string, string> req, out bool ok, out string error)
    {
        ok = true;
        error = null;
        string cmd = J.Str(req, "cmd", "");
        int x = J.Int(req, "x", 0);
        int y = J.Int(req, "y", 0);
        string hwnd = J.Str(req, "hwnd", "");
        string window = J.Str(req, "window", "");

        lock (stateLock) { lastAction = cmd; }

        if (cmd == "move")
        {
            lock (stateLock)
            {
                fromX = curX; fromY = curY; toX = x; toY = y;
                glideStart = Environment.TickCount; gliding = true;
            }
            Trigger();
            POINT p; GetCursorPos(out p);
            return "{\"x\":" + x + ",\"y\":" + y + ",\"realX\":" + p.X + ",\"realY\":" + p.Y + ",\"mode\":\"virtual\"}";
        }

        if (cmd == "click")
        {
            string button = J.Str(req, "button", "left");
            int clicks = J.Int(req, "clicks", 1);
            bool real = J.Bool(req, "real", false);

            POINT before; GetCursorPos(out before);
            lock (stateLock) { curX = x; curY = y; gliding = false; }
            AddRipple(x, y, button == "right");
            Trigger();

            string targetJson;
            if (real)
            {
                DoRealMouse("click", x, y, button, clicks, 0, 0);
                targetJson = "\"mode\":\"real\"";
            }
            else
            {
                TargetInfo t;
                try { t = DoInjectedClick(x, y, button, clicks, hwnd, window); }
                catch (Exception ex) { ok = false; error = ex.Message; return null; }
                targetJson = "\"mode\":\"message\",\"target\":{\"hwnd\":" + t.Hwnd.ToInt64() + ",\"title\":" + J.Q(t.Title) + ",\"class\":" + J.Q(t.Class) + ",\"pid\":" + t.Pid + ",\"clientX\":" + t.ClientX + ",\"clientY\":" + t.ClientY + "}";
            }
            POINT after; GetCursorPos(out after);
            Trigger();
            return "{\"x\":" + x + ",\"y\":" + y + ",\"button\":" + J.Q(button) + ",\"clicks\":" + clicks + "," + targetJson +
                   ",\"realBefore\":{\"x\":" + before.X + ",\"y\":" + before.Y + "},\"realAfter\":{\"x\":" + after.X + ",\"y\":" + after.Y + "}}";
        }

        if (cmd == "drag")
        {
            int fx = J.Int(req, "from_x", 0), fy = J.Int(req, "from_y", 0);
            int tx = J.Int(req, "to_x", 0), ty = J.Int(req, "to_y", 0);
            string button = J.Str(req, "button", "left");
            bool real = J.Bool(req, "real", false);
            POINT before; GetCursorPos(out before);
            lock (stateLock) { curX = fx; curY = fy; gliding = false; }
            Trigger();

            string mode;
            if (real)
            {
                DoRealMouse("drag", fx, fy, button, 1, tx, ty);
                mode = "\"mode\":\"real\"";
            }
            else
            {
                TargetInfo a = ResolveTarget(fx, fy, hwnd, window);
                if (a.Hwnd == IntPtr.Zero) { ok = false; error = "no window at start point"; return null; }
                int down, up, mk;
                down = WM_LBUTTONDOWN; up = WM_LBUTTONUP; mk = MK_LBUTTON;
                if (button == "right") { down = WM_RBUTTONDOWN; up = WM_RBUTTONUP; mk = MK_RBUTTON; }
                else if (button == "middle") { down = WM_MBUTTONDOWN; up = WM_MBUTTONUP; mk = MK_MBUTTON; }
                PostMouse(WM_MOUSEMOVE, 0, a.ClientX, a.ClientY, a.Hwnd);
                Thread.Sleep(30);
                PostMouse(down, mk, a.ClientX, a.ClientY, a.Hwnd);
                Thread.Sleep(60);
                for (int i = 1; i <= 14; i++)
                {
                    int cx = fx + (tx - fx) * i / 14;
                    int cy = fy + (ty - fy) * i / 14;
                    POINT cp; cp.X = cx; cp.Y = cy;
                    ScreenToClient(a.Hwnd, ref cp);
                    PostMouse(WM_MOUSEMOVE, mk, cp.X, cp.Y, a.Hwnd);
                    lock (stateLock) { curX = cx; curY = cy; }
                    Thread.Sleep(16);
                }
                POINT ep; ep.X = tx; ep.Y = ty;
                ScreenToClient(a.Hwnd, ref ep);
                PostMouse(up, 0, ep.X, ep.Y, a.Hwnd);
                lock (stateLock) { curX = tx; curY = ty; }
                Trigger();
                mode = "\"mode\":\"message\",\"target\":{\"hwnd\":" + a.Hwnd.ToInt64() + ",\"title\":" + J.Q(a.Title) + ",\"class\":" + J.Q(a.Class) + ",\"pid\":" + a.Pid + "}";
            }
            POINT after; GetCursorPos(out after);
            return "{\"from\":{\"x\":" + fx + ",\"y\":" + fy + "},\"to\":{\"x\":" + tx + ",\"y\":" + ty + "}," + mode +
                   ",\"realBefore\":{\"x\":" + before.X + ",\"y\":" + before.Y + "},\"realAfter\":{\"x\":" + after.X + ",\"y\":" + after.Y + "}}";
        }

        if (cmd == "scroll")
        {
            int dy = J.Int(req, "delta_y", 0);
            bool real = J.Bool(req, "real", false);
            POINT before; GetCursorPos(out before);
            lock (stateLock) { curX = x; curY = y; gliding = false; }
            Trigger();
            if (real)
            {
                DoRealMouse("scroll", x, y, "left", 1, 0, dy);
            }
            else
            {
                TargetInfo t = ResolveTarget(x, y, hwnd, window);
                if (t.Hwnd == IntPtr.Zero) { ok = false; error = "no window at scroll point"; return null; }
                int wp = (dy << 16);
                PostMessage(t.Hwnd, WM_MOUSEWHEEL, new IntPtr(wp), MakeLParam(x, y));
            }
            POINT after; GetCursorPos(out after);
            return "{\"x\":" + x + ",\"y\":" + y + ",\"delta_y\":" + dy + ",\"realBefore\":{\"x\":" + before.X + ",\"y\":" + before.Y + "},\"realAfter\":{\"x\":" + after.X + ",\"y\":" + after.Y + "}}";
        }

        if (cmd == "status")
        {
            POINT p; GetCursorPos(out p);
            int idx, idy;
            lock (stateLock) { idx = curX; idy = curY; }
            int visible = (Environment.TickCount - lastActivityTick) <= VISIBLE_MS + FADE_MS && !hidden ? 1 : 0;
            return "{\"overlay\":\"" + (visible == 1 ? "visible" : "idle") + "\",\"x\":" + idx + ",\"y\":" + idy +
                   ",\"realX\":" + p.X + ",\"realY\":" + p.Y + ",\"lastAction\":" + J.Q(lastAction) +
                   ",\"pid\":" + System.Diagnostics.Process.GetCurrentProcess().Id +
                   ",\"uptimeMs\":" + (Environment.TickCount - startedTick) + "}";
        }

        if (cmd == "probe")
        {
            lock (stateLock) { curX = x; curY = y; gliding = false; }
            using (Graphics g = Graphics.FromImage(overlay.Surface))
            {
                g.Clear(Color.FromArgb(255, 20, 20, 28));
                g.FillRectangle(new SolidBrush(Color.FromArgb(255, 255, 0, 0)), 60, 60, 120, 120);
                g.FillRectangle(new SolidBrush(Color.FromArgb(255, 0, 255, 0)), 190, 60, 120, 120);
            }
            overlay.Push(curX - S / 2, curY - S / 2);
            return "{\"probe\":true}";
        }

        if (cmd == "hide")
        {
            lock (stateLock) { lastActivityTick = Environment.TickCount - VISIBLE_MS - FADE_MS - 1; }
            return "{\"ok\":true}";
        }

        ok = false;
        error = "unknown cmd: " + cmd;
        return null;
    }

    static void Respond(string prefix, string body)
    {
        lock (outLock)
        {
            Console.Out.WriteLine(prefix + body);
            Console.Out.Flush();
        }
    }

    static void Reply(int id, bool ok, string resultJson, string error)
    {
        StringBuilder sb = new StringBuilder();
        sb.Append("{\"id\":").Append(id).Append(",\"ok\":").Append(ok ? "true" : "false");
        if (ok) sb.Append(",\"result\":").Append(resultJson);
        else sb.Append(",\"error\":").Append(J.Q(error));
        sb.Append("}");
        Respond("", sb.ToString());
    }

    static void HandleLine(string json)
    {
        int id = 0;
        try
        {
            Dictionary<string, string> req = J.Obj(json);
            string idText = J.Str(req, "id", "0");
            int.TryParse(idText, out id);
            bool ok;
            string error;
            string result = Exec(req, out ok, out error);
            if (!ok) Reply(id, false, null, error);
            else Reply(id, true, result, null);
            if (J.Str(req, "cmd", "") == "shutdown")
            {
                try { overlay.BeginInvoke(new Action(delegate { Application.Exit(); })); } catch { Application.Exit(); }
            }
        }
        catch (Exception ex)
        {
            Reply(id, false, null, ex.Message);
        }
    }

    static void StdinLoop()
    {
        StreamReader reader = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
        string line;
        while ((line = reader.ReadLine()) != null)
        {
            line = line.Trim();
            if (line.Length == 0) continue;
            string json;
            try { json = Encoding.UTF8.GetString(Convert.FromBase64String(line)); }
            catch { continue; }
            HandleLine(json);
        }
        try
        {
            if (overlay != null && overlay.IsHandleCreated) overlay.BeginInvoke(new Action(delegate { Application.Exit(); }));
        }
        catch { }
    }


    public static void Run()
    {
        EnsureForm();
        Thread t = new Thread(StdinLoop);
        t.IsBackground = true;
        t.Start();
        Application.Run(overlay);
    }


    static void TakeShot(string path)
    {
        try
        {
            int w = 320, h = 280;
            Bitmap b = new Bitmap(w, h);
            Graphics gg = Graphics.FromImage(b);
            int sx = curX - w / 2;
            int sy = curY - h / 2;
            gg.CopyFromScreen(sx, sy, 0, 0, new Size(w, h));
            gg.Dispose();
            b.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            b.Dispose();
        }
        catch (Exception ex) { lastDrawError = "shot: " + ex.Message; }
    }

    public static void OneShot(string json)
    {
        EnsureForm();
        int id = 0;
        Dictionary<string, string> req = J.Obj(json);
        int.TryParse(J.Str(req, "id", "0"), out id);
        bool ok;
        string error;
        string result = Exec(req, out ok, out error);
        string shotPath = Environment.GetEnvironmentVariable("VMOUSE_SHOT");
        int shotDelay = 700;
        string delayText = Environment.GetEnvironmentVariable("VMOUSE_SHOT_DELAY");
        if (delayText != null)
        {
            int d;
            if (int.TryParse(delayText, out d)) shotDelay = d;
        }
        long shotAt = Environment.TickCount + shotDelay;
        bool shotDone = false;
        long until = Environment.TickCount + HoldMs;
        while (Environment.TickCount < until)
        {
            Application.DoEvents();
            if (!shotDone && shotPath != null && shotPath.Length > 0 && Environment.TickCount >= shotAt)
            {
                TakeShot(shotPath);
                shotDone = true;
            }
            Thread.Sleep(20);
        }
        Reply(id, ok, result, error);
        Respond("", "{\"debug\":{\"lastDrawError\":" + J.Q(lastDrawError) + ",\"lastPushError\":" + J.Q(lastPushError) + ",\"curX\":" + curX + ",\"curY\":" + curY +
                ",\"gliding\":" + (gliding ? "true" : "false") + ",\"visible\":" + (overlay != null && overlay.Visible ? "true" : "false") +
                ",\"handle\":" + (overlay != null && overlay.IsHandleCreated ? "true" : "false") + "}}");
    }
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll'

if ($Run64) {
    [VMouseHost]::HoldMs = $Hold
    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Run64))
    [VMouseHost]::OneShot($json)
}
elseif ($Run) {
    [VMouseHost]::HoldMs = $Hold
    [VMouseHost]::OneShot($Run)
}
else {
    [VMouseHost]::Run()
}
