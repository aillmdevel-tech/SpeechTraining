using System.Runtime.InteropServices;

namespace SpeechTraining;

internal static class Desktop
{
    public const int HotKeyMessage = 0x0312;
    private const uint ControlShift = 0x0002 | 0x0004;
    private const uint NoRepeat = 0x4000;

    public static string? Register(IntPtr handle, int id, Keys preferred, Keys fallback)
    {
        if (RegisterHotKey(handle, id, ControlShift | NoRepeat, (uint)preferred))
            return preferred == Keys.Space ? "Ctrl+Shift+Пробел" : "Ctrl+Shift+`";
        if (RegisterHotKey(handle, id, ControlShift | NoRepeat, (uint)fallback))
            return $"Ctrl+Shift+{fallback}";
        return null;
    }

    public static void Unregister(IntPtr handle, int id) => UnregisterHotKey(handle, id);

    public static bool Protect(IntPtr window, bool ghost) => SetWindowDisplayAffinity(window, ghost ? 0x11u : 0u);

    public static void BringToFront(Form form)
    {
        form.Show();
        if (form.WindowState == FormWindowState.Minimized) form.WindowState = FormWindowState.Normal;
        form.Activate();
        SetForegroundWindow(form.Handle);
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(IntPtr window, int id);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);
}
