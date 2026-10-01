using FluentAssertions;
using GhostHand.Core.Hotkey;
using Xunit;

namespace GhostHand.Core.Tests.Hotkey;

public class ChordStateMachineTests
{
    private readonly ChordStateMachine _machine = new();
    private int _triggerCount;
    private int _cancelCount;

    public ChordStateMachineTests()
    {
        _machine.OnTrigger += () => _triggerCount++;
        _machine.OnCancel += () => _cancelCount++;
    }

    [Fact]
    public void HK01_CtrlDown_WinDown_WinUp_FiresExactlyOnce()
    {
        // Act: Ctrl down -> Win down -> Win up -> Ctrl up
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLControl));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLControl));

        // Assert
        _triggerCount.Should().Be(1);
        _cancelCount.Should().Be(0);
    }

    [Fact]
    public void HK01_WinDown_CtrlDown_CtrlUp_FiresExactlyOnce()
    {
        // Act: Reversed order
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLControl));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLControl));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLWin));

        // Assert
        _triggerCount.Should().Be(1);
        _cancelCount.Should().Be(0);
    }

    [Fact]
    public void HK02_CtrlWinD_InterveningKey_DoesNotFire()
    {
        const int vkD = 0x44;

        // Act: Ctrl down -> Win down -> D down -> D up -> Win up -> Ctrl up
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLControl));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(vkD));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(vkD));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLControl));

        // Assert
        _triggerCount.Should().Be(0);
        _cancelCount.Should().Be(0);
    }

    [Fact]
    public void HK03_CtrlAlone_Or_WinAlone_DoesNotFire()
    {
        // Ctrl alone
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLControl));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLControl));
        _triggerCount.Should().Be(0);

        // Win alone
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLWin));
        _triggerCount.Should().Be(0);
    }

    [Fact]
    public void HK04_LeftAndRightModifierVariants_BothWork()
    {
        // Right Ctrl + Left Win
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkRControl));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkRControl));
        _triggerCount.Should().Be(1);

        // Left Ctrl + Right Win
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLControl));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkRWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkRWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLControl));
        _triggerCount.Should().Be(2);
    }

    [Fact]
    public void HK05_InjectedEvents_AreIgnored()
    {
        // Synthetic / injected events should not trigger
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLControl, isInjected: true));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin, isInjected: true));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLWin, isInjected: true));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLControl, isInjected: true));

        _triggerCount.Should().Be(0);
    }

    [Fact]
    public void HK06_TriggerWhileRunActive_EmitsCancelNotShow()
    {
        _machine.IsRunActive = true;

        // Perform chord
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLControl));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLControl));

        // Assert: Kill switch behavior
        _triggerCount.Should().Be(0);
        _cancelCount.Should().Be(1);
    }

    [Fact]
    public void HK06_EscapeWhileRunActive_EmitsCancel()
    {
        _machine.IsRunActive = true;

        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(ChordStateMachine.VkEscape));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(ChordStateMachine.VkEscape));

        _triggerCount.Should().Be(0);
        _cancelCount.Should().Be(1);
    }

    [Fact]
    public void HK07_KeyAutoRepeat_DoesNotDoubleFire()
    {
        // Ctrl down -> Win down -> Win down (auto repeat) -> Win down (auto repeat) -> Win up
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLControl));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyDown(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLWin));
        _machine.ProcessKeyEvent(RawKeyEvent.KeyUp(RawKeyEvent.VkLControl));

        _triggerCount.Should().Be(1);
    }
}
