# Graph Report - GhostHand  (2026-09-21)

## Corpus Check
- 74 files · ~33,949 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 867 nodes · 1565 edges · 44 communities (40 shown, 4 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 112 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `724a8509`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- GhostHand.App.csproj
- App
- AppTarget
- JevClient
- AppDelegate
- AgentDecision
- AccessibilityElement
- ScaffoldTests.cs
- WindowSnapshot
- AXTreeWalker
- .prepare
- KeychainHelper
- PROMPT START
- 1. Upstream Source Files
- .run
- TaskRunner
- 2026-09-21 — M0: Recon and Setup
- ChordStateMachine
- PromptPopupWindow
- .EvaluateAsync
- AppKit
- LowLevelKeyboardHook
- GhostHand — Architecture Decision Records
- GhostHand
- windows/NativeMethods.json
- GhostHand — Agent Instructions
- GhostHand — Port Status
- rebuild.sh script
- Package.swift
- notarize.sh
- GhostHand.Platform/NativeMethods.json
- JevTests
- StatusIndicatorWindow
- JevDecisionModel
- .info
- OverlayPanel
- GhostHand.Core.Models
- CoreInterfaces.cs
- AppTarget
- WindowCaptureService.cs
- render
- AgentDecision
- .EvaluateAsync
- ActionResult

## God Nodes (most connected - your core abstractions)
1. `AppDelegate` - 32 edges
2. `TaskRunner` - 29 edges
3. `ControllerError` - 27 edges
4. `AgentDecision` - 20 edges
5. `JevClient` - 19 edges
6. `JevTests` - 19 edges
7. `LowLevelKeyboardHook` - 19 edges
8. `CDPClient` - 16 edges
9. `App` - 16 edges
10. `RunProgressTests` - 15 edges

## Surprising Connections (you probably didn't know these)
- `rebuild.sh script` --calls--> `build.sh script`  [EXTRACTED]
  rebuild.sh → Scripts/build.sh
- `TaskRunner` --calls--> `RunProgress`  [INFERRED]
  Sources/GhostHand/TaskRunner.swift → Sources/GhostHand/RunProgress.swift
- `TaskRunner` --references--> `ActionHistory`  [EXTRACTED]
  Sources/GhostHand/TaskRunner.swift → Sources/GhostHand/AgentTypes.swift
- `AppDelegate` --references--> `HotkeyManager`  [EXTRACTED]
  Sources/GhostHand/AppDelegate.swift → Sources/GhostHand/HotkeyManager.swift
- `AppDelegate` --references--> `OverlayPanel`  [EXTRACTED]
  Sources/GhostHand/AppDelegate.swift → Sources/GhostHand/OverlayPanel.swift

## Import Cycles
- None detected.

## Communities (44 total, 4 thin omitted)

### Community 0 - "GhostHand.App.csproj"
Cohesion: 0.07
Nodes (27): coverlet.collector, FlaUI.UIA3, FluentAssertions, H.NotifyIcon.Wpf, Microsoft.Extensions.DependencyInjection.Abstractions, Microsoft.NET.Test.Sdk, Microsoft.Windows.CsWin32, Moq (+19 more)

### Community 1 - "App"
Cohesion: 0.06
Nodes (21): GhostHand.Core.Common, GhostHand.Cli, EventArgs, ExitEventArgs, IServiceCollection, Mutex, ServiceProvider, StartupEventArgs (+13 more)

### Community 2 - "AppTarget"
Cohesion: 0.19
Nodes (11): IntPtr, CancellationToken, IReadOnlyList, Task, TimeSpan, IActionExecutor, IAuditLog, IDecisionModel (+3 more)

### Community 3 - "JevClient"
Cohesion: 0.09
Nodes (24): Codable, Foundation, ActionHistory, String, JevClient, JevResult, JevServiceError, .errorDescription (+16 more)

### Community 4 - "AppDelegate"
Cohesion: 0.14
Nodes (13): NSApplication, NSApplicationDelegate, NSObject, NSWindow, ObservableObject, AppDelegate, SetupView, .body (+5 more)

### Community 5 - "AgentDecision"
Cohesion: 0.11
Nodes (19): Equatable, AgentDecision, Double, ActionVerification, ObservationState, RunProgress, AccessibilityElement, AgentDecision (+11 more)

### Community 6 - "AccessibilityElement"
Cohesion: 0.06
Nodes (21): ApplicationServices, AccessibilityElement, .displayLabel, .displayRole, .isOutcomeEvidence, AXUIElement, Bool, CGRect (+13 more)

### Community 7 - "ScaffoldTests.cs"
Cohesion: 0.40
Nodes (3): GhostHand.Tests, Fact, ScaffoldTests

### Community 8 - "WindowSnapshot"
Cohesion: 0.09
Nodes (17): ScreenCaptureKit, AccessibilityElement, CGImage, CGRect, pid_t, VisionObserver, CGImage, CGPoint (+9 more)

### Community 9 - "AXTreeWalker"
Cohesion: 0.17
Nodes (11): Date, AXTreeWalker, AccessibilityElement, AnyObject, AppTarget, AXUIElement, Bool, Int (+3 more)

### Community 10 - ".prepare"
Cohesion: 0.11
Nodes (14): LocalizedError, Node, Failure, changed, .errorDescription, unavailable, AXUIElement, Bool (+6 more)

### Community 11 - "KeychainHelper"
Cohesion: 0.36
Nodes (4): Security, KeychainHelper, Any, String

### Community 12 - "PROMPT START"
Cohesion: 0.10
Nodes (20): 10. Test plan (write these; unit tests must need neither network nor a UI session), 11. Performance targets and demos, 12. Your first actions now, 1. Mission, 2. Ground rules, 3. Target stack (chosen for speed and small footprint on user PCs), 4. Architecture, 5.1 Use the plain HTTP endpoint (no TypeScript / AI SDK needed) (+12 more)

### Community 13 - "1. Upstream Source Files"
Cohesion: 0.10
Nodes (19): 1.1 App Shell & Lifecycle, 1.2 Hotkey & Input, 1.3 UI, 1.4 Screen Reading, 1.5 Agent Loop & Decision, 1.6 Browser Support (M9), 1.7 Build Scripts (Drop), 1. Upstream Source Files (+11 more)

### Community 14 - ".run"
Cohesion: 0.14
Nodes (14): CheckedContinuation, Error, MainActor, Result, AsyncTimeout, Race, Never, String (+6 more)

### Community 15 - "TaskRunner"
Cohesion: 0.06
Nodes (48): AnyObject, CGKeyCode, Character, Decodable, Int32, ControllerError, .errorDescription, invalid (+40 more)

### Community 16 - "2026-09-21 — M0: Recon and Setup"
Cohesion: 0.09
Nodes (22): 2026-09-21 — M0: Recon and Setup, 2026-09-21 — M1: Scaffold, 2026-09-21 — M2: Hotkey and Popup, Components Built, Files Created, Files Read (upstream), Graphify, Graphify Update (+14 more)

### Community 17 - "ChordStateMachine"
Cohesion: 0.14
Nodes (14): ChordArmed, GhostHand.Tests.Hotkey, GhostHand.Core.Hotkey, CtrlDown, Interrupted, WinDown, bool, int (+6 more)

### Community 18 - "PromptPopupWindow"
Cohesion: 0.13
Nodes (17): KeyEventArgs, RoutedEventArgs, TextChangedEventArgs, CloseButton, ElevatedBadge, MicButton, PlaceholderText, PromptInput (+9 more)

### Community 19 - ".EvaluateAsync"
Cohesion: 0.07
Nodes (29): GhostHand.Tests.Jev, GhostHand.Core.Jev, Exception, HttpClient, JsonElement, JsonSerializerOptions, List, CancellationToken (+21 more)

### Community 20 - "AppKit"
Cohesion: 0.09
Nodes (19): App, AppKit, CGEventTapProxy, CGEventType, CoreGraphics, Scene, ElectronDetector, AppTarget (+11 more)

### Community 21 - "LowLevelKeyboardHook"
Cohesion: 0.10
Nodes (16): CancellationTokenSource, Channel, DllImport, HHOOK, HOOKPROC, LPARAM, LRESULT, TaskCompletionSource (+8 more)

### Community 22 - "GhostHand — Architecture Decision Records"
Cohesion: 0.22
Nodes (8): ADR-001: .NET 8 LTS over .NET 9, ADR-002: Vercel AI Gateway vs Direct TypeSafe API, ADR-003: Ctrl+Win Chord via Low-Level Hook + State Machine, ADR-004: FlaUI.UIA3 for UI Automation, ADR-005: CsWin32 Source Generator for P/Invoke, ADR-006: Serilog with File Sink for Logging, ADR-007: Whisper.net for Local Voice Input, GhostHand — Architecture Decision Records

### Community 23 - "GhostHand"
Cohesion: 0.25
Nodes (7): Build from source, Development, Download, How it works, License, Status, GhostHand

### Community 24 - "windows/NativeMethods.json"
Cohesion: 0.50
Nodes (3): emitSingleFile, public, $schema

### Community 25 - "GhostHand — Agent Instructions"
Cohesion: 0.40
Nodes (4): 2. Ground rules, 7. Safety invariants (non-negotiable), graphify, GhostHand — Agent Instructions

### Community 26 - "GhostHand — Port Status"
Cohesion: 0.50
Nodes (3): New Windows Capabilities, GhostHand — Port Status, Upstream Capabilities

### Community 30 - "GhostHand.Platform/NativeMethods.json"
Cohesion: 0.50
Nodes (3): emitSingleFile, public, $schema

### Community 31 - "JevTests"
Cohesion: 0.16
Nodes (4): JevTests, AccessibilityElement, Int, String

### Community 32 - "StatusIndicatorWindow"
Cohesion: 0.18
Nodes (10): NSHostingView, NSPanel, StatusIndicatorWindow, StatusView, .body, .message, AppTarget, Bool (+2 more)

### Community 33 - "JevDecisionModel"
Cohesion: 0.21
Nodes (9): CancellationToken, Dictionary, ILogger, IReadOnlyList, Task, JevDecisionModel, IReadOnlyList, Rectangle (+1 more)

### Community 34 - ".info"
Cohesion: 0.16
Nodes (9): CFMachPort, CFRunLoopSource, Notification, HotkeyManager, .isRunning, Bool, Void, Log (+1 more)

### Community 35 - "OverlayPanel"
Cohesion: 0.27
Nodes (10): OverlayInputView, .body, OverlayPanel, .canBecomeKey, Any, AppTarget, Bool, NSImage (+2 more)

### Community 36 - "GhostHand.Core.Models"
Cohesion: 0.20
Nodes (5): GhostHand.App, GhostHand.Platform.Hotkey, GhostHand.App.Windows, GhostHand.Core.Interfaces, GhostHand.Core.Models

### Community 37 - "CoreInterfaces.cs"
Cohesion: 0.18
Nodes (6): IDisposable, DateTimeOffset, IClock, ICredentialStore, IHotkeyService, ISpeechInput

### Community 38 - "AppTarget"
Cohesion: 0.27
Nodes (7): NSRect, NSRunningApplication, AppTarget, AXUIElement, NSImage, pid_t, String

### Community 39 - "WindowCaptureService.cs"
Cohesion: 0.38
Nodes (3): GhostHand.Platform.Windowing, IWindowCaptureService, WindowCaptureService

### Community 40 - "render"
Cohesion: 0.40
Nodes (4): CGFloat, render(), Data, Int

### Community 41 - "AgentDecision"
Cohesion: 0.50
Nodes (3): IRiskPolicy, AgentDecision, AgentOperation

### Community 42 - ".EvaluateAsync"
Cohesion: 0.40
Nodes (3): CancellationToken, Task, IJevClient

## Knowledge Gaps
- **129 isolated node(s):** `PackageDescription`, `notarize.sh script`, `.isOutcomeEvidence`, `.displayRole`, `.displayLabel` (+124 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `TaskRunner` connect `TaskRunner` to `StatusIndicatorWindow`, `JevClient`, `AppDelegate`, `AgentDecision`?**
  _High betweenness centrality (0.046) - this node is a cross-community bridge._
- **Why does `AppDelegate` connect `AppDelegate` to `StatusIndicatorWindow`, `.info`, `OverlayPanel`, `AppTarget`, `TaskRunner`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Why does `ControllerError` connect `TaskRunner` to `JevClient`, `WindowSnapshot`, `.prepare`, `KeychainHelper`, `.run`?**
  _High betweenness centrality (0.040) - this node is a cross-community bridge._
- **Are the 14 inferred relationships involving `AgentDecision` (e.g. with `.testOCRLabelsCannotBecomeClickTargetsWithoutVisualGrounding()` and `.testOCRTextUsesExplicitClickTextRatherThanPretendingToBeAButton()`) actually correct?**
  _`AgentDecision` has 14 INFERRED edges - model-reasoned connections that need verification._
- **Are the 5 inferred relationships involving `JevClient` (e.g. with `.runLoop()` and `.testCompletionCheckDoesNotAskForAnotherAction()`) actually correct?**
  _`JevClient` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `notarize.sh script`, `.isOutcomeEvidence` to the rest of the system?**
  _129 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `GhostHand.App.csproj` be split into smaller, more focused modules?**
  _Cohesion score 0.06722689075630252 - nodes in this community are weakly interconnected._