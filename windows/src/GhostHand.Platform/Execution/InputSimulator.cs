using System.Drawing;
using Windows.Win32;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace GhostHand.Platform.Execution;

public static class InputSimulator
{
    public static unsafe void Click(int x, int y)
    {
        // 1. Move cursor
        PInvoke.SetCursorPos(x, y);

        // 2. Mouse down and up
        var inputs = new INPUT[2];

        inputs[0].type = INPUT_TYPE.INPUT_MOUSE;
        inputs[0].Anonymous.mi.dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_LEFTDOWN;

        inputs[1].type = INPUT_TYPE.INPUT_MOUSE;
        inputs[1].Anonymous.mi.dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_LEFTUP;

        fixed (INPUT* pInputs = inputs)
        {
            PInvoke.SendInput((uint)inputs.Length, pInputs, sizeof(INPUT));
        }
    }

    public static unsafe void Scroll(bool down)
    {
        var inputs = new INPUT[1];
        inputs[0].type = INPUT_TYPE.INPUT_MOUSE;
        inputs[0].Anonymous.mi.dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_WHEEL;
        inputs[0].Anonymous.mi.mouseData = unchecked((uint)(down ? -120 : 120));

        fixed (INPUT* pInputs = inputs)
        {
            PInvoke.SendInput(1, pInputs, sizeof(INPUT));
        }
    }

    public static unsafe void TypeText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        var inputs = new INPUT[text.Length * 2];
        int idx = 0;

        foreach (var ch in text)
        {
            // Key down
            inputs[idx].type = INPUT_TYPE.INPUT_KEYBOARD;
            inputs[idx].Anonymous.ki.wScan = ch;
            inputs[idx].Anonymous.ki.dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_UNICODE;
            idx++;

            // Key up
            inputs[idx].type = INPUT_TYPE.INPUT_KEYBOARD;
            inputs[idx].Anonymous.ki.wScan = ch;
            inputs[idx].Anonymous.ki.dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_UNICODE | KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;
            idx++;
        }

        fixed (INPUT* pInputs = inputs)
        {
            PInvoke.SendInput((uint)inputs.Length, pInputs, sizeof(INPUT));
        }
    }

    public static unsafe void SendKey(VIRTUAL_KEY vk)
    {
        var inputs = new INPUT[2];

        // Key down
        inputs[0].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[0].Anonymous.ki.wVk = vk;

        // Key up
        inputs[1].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[1].Anonymous.ki.wVk = vk;
        inputs[1].Anonymous.ki.dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;

        fixed (INPUT* pInputs = inputs)
        {
            PInvoke.SendInput(2, pInputs, sizeof(INPUT));
        }
    }

    public static unsafe void SendChord(VIRTUAL_KEY mod, VIRTUAL_KEY key)
    {
        var inputs = new INPUT[4];

        // Mod down
        inputs[0].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[0].Anonymous.ki.wVk = mod;

        // Key down
        inputs[1].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[1].Anonymous.ki.wVk = key;

        // Key up
        inputs[2].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[2].Anonymous.ki.wVk = key;
        inputs[2].Anonymous.ki.dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;

        // Mod up
        inputs[3].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[3].Anonymous.ki.wVk = mod;
        inputs[3].Anonymous.ki.dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;

        fixed (INPUT* pInputs = inputs)
        {
            PInvoke.SendInput(4, pInputs, sizeof(INPUT));
        }
    }

    /// <summary>
    /// Types text one character at a time with a small delay between each keystroke.
    /// Arithmetic operators (+, -, *, /) are sent as virtual key codes so that Calculator
    /// (and similar apps) interpret them correctly instead of ignoring KEYEVENTF_UNICODE
    /// scan codes for those characters.
    /// </summary>
    public static void TypeTextSlowly(string text, int delayMs = 30)
    {
        if (string.IsNullOrEmpty(text)) return;

        foreach (var ch in text)
        {
            // Map arithmetic operators to virtual keys that Calculator understands
            VIRTUAL_KEY? vk = ch switch
            {
                '+' => VIRTUAL_KEY.VK_ADD,
                '-' => VIRTUAL_KEY.VK_SUBTRACT,
                '*' => VIRTUAL_KEY.VK_MULTIPLY,
                '/' => VIRTUAL_KEY.VK_DIVIDE,
                _ => null
            };

            if (vk.HasValue)
            {
                SendKey(vk.Value);
            }
            else
            {
                TypeChar(ch);
            }

            Thread.Sleep(delayMs);
        }
    }

    /// <summary>Sends a single Unicode character via KEYEVENTF_UNICODE.</summary>
    private static unsafe void TypeChar(char ch)
    {
        var inputs = new INPUT[2];

        inputs[0].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[0].Anonymous.ki.wScan = ch;
        inputs[0].Anonymous.ki.dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_UNICODE;

        inputs[1].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[1].Anonymous.ki.wScan = ch;
        inputs[1].Anonymous.ki.dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_UNICODE | KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;

        fixed (INPUT* pInputs = inputs)
        {
            PInvoke.SendInput(2, pInputs, sizeof(INPUT));
        }
    }

    public static void SelectAllAndClear()
    {
        // Ctrl + A
        SendChord((VIRTUAL_KEY)0x11, (VIRTUAL_KEY)0x41);
        Thread.Sleep(30);
        // Backspace
        SendKey((VIRTUAL_KEY)0x08);
        Thread.Sleep(30);
    }
}
