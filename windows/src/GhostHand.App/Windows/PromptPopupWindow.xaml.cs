using System.Windows;
using System.Windows.Input;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Models;

namespace GhostHand.App.Windows;

public partial class PromptPopupWindow : Window
{
    private AppTarget? _currentTarget;
    private bool _isListening;
    private CancellationTokenSource? _speechCts;

    public event Action<string, AppTarget?>? TaskSubmitted;
    public event Action? Cancelled;
    /// <summary>Voice recording started (a new utterance).</summary>
    public event Action? ListeningStarted;
    /// <summary>Live transcript while the user is still speaking, with the current target.</summary>
    public event Action<string, AppTarget?>? PartialTranscript;

    public ISpeechInput? SpeechInput { get; set; }

    public PromptPopupWindow()
    {
        InitializeComponent();
    }

    public void ShowForTarget(AppTarget? target)
    {
        _currentTarget = target;
        _isListening = false;
        MicButton.Content = "🎤 Mic";

        if (target != null)
        {
            var title = !string.IsNullOrWhiteSpace(target.WindowTitle) ? target.WindowTitle : target.ProcessName;
            TargetAppText.Text = $"Target: {target.ProcessName} — \"{title}\"";
            ElevatedBadge.Visibility = target.IsElevated ? Visibility.Visible : Visibility.Collapsed;

            if (target.IsElevated)
            {
                StatusText.Text = "⚠ Target process is elevated (Admin). UIPI restricts automation.";
                StatusText.Foreground = System.Windows.Media.Brushes.OrangeRed;
            }
            else
            {
                StatusText.Text = "Press Enter to submit, Esc to cancel";
                StatusText.Foreground = System.Windows.Media.Brushes.Gray;
            }
        }
        else
        {
            TargetAppText.Text = "Target: Windows Desktop";
            ElevatedBadge.Visibility = Visibility.Collapsed;
            StatusText.Text = "Press Enter to submit, Esc to cancel";
            StatusText.Foreground = System.Windows.Media.Brushes.Gray;
        }

        PromptInput.Text = string.Empty;
        Show();
        Activate();
        PromptInput.Focus();
    }

    public void UpdateTarget(AppTarget target)
    {
        _currentTarget = target;
        Dispatcher.Invoke(() =>
        {
            var title = !string.IsNullOrWhiteSpace(target.WindowTitle) ? target.WindowTitle : target.ProcessName;
            TargetAppText.Text = $"Target: {target.ProcessName} — \"{title}\"";
            ElevatedBadge.Visibility = target.IsElevated ? Visibility.Visible : Visibility.Collapsed;
        });
    }

    public void SetExecuting(bool isExecuting, string? status = null)
    {
        Dispatcher.Invoke(() =>
        {
            PromptInput.IsEnabled = !isExecuting;
            SendButton.IsEnabled = !isExecuting;
            SendButton.Content = isExecuting ? "Running…" : "Send ↵";
            if (!string.IsNullOrEmpty(status))
            {
                StatusText.Text = status;
                StatusText.Foreground = System.Windows.Media.Brushes.LightSkyBlue;
            }
        });
    }

    public void UpdateStatus(string status, bool isError = false)
    {
        Dispatcher.Invoke(() =>
        {
            StatusText.Text = status;
            StatusText.Foreground = isError
                ? System.Windows.Media.Brushes.OrangeRed
                : System.Windows.Media.Brushes.LightSkyBlue;
        });
    }

    public void OnRunCompleted(string message, bool success)
    {
        Dispatcher.Invoke(() =>
        {
            SetExecuting(false);
            if (!success)
            {
                StatusText.Text = "⚠ " + message;
                StatusText.Foreground = System.Windows.Media.Brushes.OrangeRed;
                Show();
                Activate();
            }
        });
    }

    public void HidePopup()
    {
        _speechCts?.Cancel();
        SetExecuting(false);
        Hide();
        Cancelled?.Invoke();
    }

    private void Submit()
    {
        _speechCts?.Cancel();
        var goal = PromptInput.Text.Trim();
        if (string.IsNullOrWhiteSpace(goal)) return;

        if (_currentTarget?.IsElevated == true)
        {
            MessageBox.Show(
                "GhostHand cannot automate an elevated (Administrator) application.\n\nPlease activate a standard window or restart GhostHand as administrator.",
                "Target is Elevated",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return;
        }

        Hide();
        TaskSubmitted?.Invoke(goal, _currentTarget);
    }

    private void PromptInput_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        PlaceholderText.Visibility = string.IsNullOrEmpty(PromptInput.Text)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void SendButton_Click(object sender, RoutedEventArgs e) => Submit();

    private void CloseButton_Click(object sender, RoutedEventArgs e) => HidePopup();

    private async void MicButton_Click(object sender, RoutedEventArgs e)
    {
        // If already listening, finish now and use what was said (Esc / close still cancels)
        if (_isListening)
        {
            SpeechInput?.RequestStop();
            return;
        }

        if (SpeechInput == null)
        {
            StatusText.Text = "⚠ Voice input is not available.";
            StatusText.Foreground = System.Windows.Media.Brushes.OrangeRed;
            return;
        }

        _isListening = true;
        _speechCts?.Dispose();
        _speechCts = new CancellationTokenSource();
        var token = _speechCts.Token;

        MicButton.Content = "⏹ Stop";
        StatusText.Text = "🎙 Listening… speak your command (auto-submits when you pause)";
        StatusText.Foreground = System.Windows.Media.Brushes.LightGreen;

        // Live transcript: words appear in the input box while the user is still talking
        void OnSpeechRecognizing(string partial)
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (token.IsCancellationRequested) return;
                PromptInput.Text = partial;
                PromptInput.CaretIndex = partial.Length;
                if (!StatusText.Text.StartsWith("⚡"))
                {
                    StatusText.Text = "🎙 Listening… (live)";
                    StatusText.Foreground = System.Windows.Media.Brushes.LightSkyBlue;
                }
                PartialTranscript?.Invoke(partial, _currentTarget);
            });
        }
        ListeningStarted?.Invoke();
        SpeechInput.SpeechRecognizing += OnSpeechRecognizing;

        try
        {
            var transcript = await SpeechInput.TranscribeAsync(token);

            SpeechInput.SpeechRecognizing -= OnSpeechRecognizing;

            if (!string.IsNullOrWhiteSpace(transcript))
            {
                PromptInput.Text = transcript;
                StatusText.Text = $"✓ \"{transcript}\" — executing…";
                StatusText.Foreground = System.Windows.Media.Brushes.LightGreen;

                await Task.Delay(120);
                Submit();
            }
            else if (token.IsCancellationRequested)
            {
                StatusText.Text = "Voice recording cancelled.";
                StatusText.Foreground = System.Windows.Media.Brushes.Gray;
            }
            else
            {
                StatusText.Text = "No speech detected. Speak clearly and try again.";
                StatusText.Foreground = System.Windows.Media.Brushes.OrangeRed;
            }
        }
        catch (OperationCanceledException)
        {
            SpeechInput.SpeechRecognizing -= OnSpeechRecognizing;
            StatusText.Text = "Voice recording cancelled.";
            StatusText.Foreground = System.Windows.Media.Brushes.Gray;
        }
        catch (Exception ex)
        {
            SpeechInput.SpeechRecognizing -= OnSpeechRecognizing;
            var msg = ex.Message.StartsWith("⚠") ? ex.Message : "⚠ " + ex.Message;
            StatusText.Text = msg;
            StatusText.Foreground = System.Windows.Media.Brushes.OrangeRed;
        }
        finally
        {
            _isListening = false;
            MicButton.Content = "🎤 Mic";
        }
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            Submit();
        }
        else if (e.Key == Key.Escape)
        {
            e.Handled = true;
            HidePopup();
        }
    }
}
