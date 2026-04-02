**RFC: Menu-Bar Snooker – A Native macOS Menu-Bar Snooker Game**  
**RFC-001**  
**Author:** Grok (xAI)  
**Date:** 02 April 2026  

### 1. Abstract

This RFC proposes the creation of **SnookerMenuBar**, a lightweight, fully native macOS application that implements a simplified yet realistic snooker game. The application runs exclusively as a menu-bar status item with no Dock icon or persistent main window. Clicking the menu-bar icon opens a compact, attached `NSPopover` containing a playable snooker table implemented with SpriteKit physics. The entire codebase is written in pure Swift, managed exclusively by Swift Package Manager (SPM), and builds directly in Xcode without any Xcode project file or third-party dependencies.

The goal is a self-contained, install-free utility that provides instant access to a snooker simulation directly from the menu bar, suitable for quick practice sessions during work breaks.

### 2. Motivation

- Provide an always-available, zero-footprint snooker experience on macOS.
- Demonstrate a clean, modern architecture using only Apple frameworks and SPM.
- Deliver realistic 2D physics-driven gameplay within the strict visual and memory constraints of a menu-bar popover.
- Create a foundation that can be extended with additional rules, sounds, or visual polish while remaining fully native.

### 3. Goals and Non-Goals

**Goals**
- Fully functional single-frame snooker game with realistic ball physics.
- Menu-bar icon that toggles a small attached popover window.
- No Dock icon, no Cmd-Tab entry (`LSUIElement`).
- 100 % Swift, SPM-only build system.
- Mouse-drag aiming and shooting mechanic.
- Basic scoring and foul detection.
- Runs on macOS 14+ (Sonoma) and later.

**Non-Goals**
- Full tournament rules engine (multi-frame, handicaps, referee AI).
- Network/multiplayer support.
- Custom physics engine (SpriteKit is sufficient).
- iOS / iPadOS / visionOS ports.
- Any third-party libraries or SwiftUI (pure AppKit + SpriteKit).

### 4. Requirements

#### 4.1 Functional Requirements
- Status item in the system menu bar displaying a simple cue-ball icon.
- Clicking the icon opens a 560 × 340 pt popover containing the snooker table.
- Popover closes automatically when the user clicks outside (`NSPopover.Behavior.transient`).
- Table contains: 1 white cue ball, 15 red balls, 6 coloured balls, 6 pockets, and cushion borders.
- Mouse interaction: click-and-drag from cue ball to aim and set power; release to strike.
- Realistic physics: friction, restitution, collisions, and potting detection.
- Basic scoring: reds (1 pt) followed by colours (2–7 pts), foul penalties.
- Visual feedback: aiming line, power indicator, current score overlay.
- Reset / new frame functionality via a button inside the popover.

#### 4.2 Technical Requirements
- Pure Swift 6+.
- Build system: Swift Package Manager (`Package.swift`) only.
- Frameworks: `AppKit`, `SpriteKit` (mandatory); `AVFoundation` (optional for sound).
- No storyboards, no `.xib` files, no SwiftUI.
- All resources loaded via `Bundle.module`.
- Target deployment: macOS 14.0+.

### 5. Architecture Overview

The application follows a minimal, event-driven structure:

```
SnookerMenuBar/
├── Package.swift
├── Info.plist
├── Sources/
│   └── SnookerMenuBar/
│       ├── main.swift
│       ├── AppDelegate.swift
│       ├── GameViewController.swift
│       └── SnookerScene.swift
└── Resources/ (optional PNGs, sounds)
```

- **AppDelegate** (`main.swift` + `AppDelegate.swift`): owns `NSStatusItem` and `NSPopover`.
- **GameViewController**: hosts `SKView` and presents `SnookerScene`.
- **SnookerScene**: `SKScene` subclass containing all game logic, physics bodies, contact delegate, and input handling.

### 6. Detailed Component Design

#### 6.1 Package.swift
Defines an executable target with explicit linker settings for `AppKit`, `SpriteKit`, and optional `AVFoundation`. Includes `Info.plist` and `Resources` folder.

#### 6.2 Info.plist
Contains `LSUIElement = true` and standard bundle identifiers. No other keys required.

#### 6.3 AppDelegate
- Creates `NSStatusItem` with system-symbol image (`circle.fill`).
- Instantiates `NSPopover` with fixed content size (560 × 340 pt).
- Handles toggle action to show/hide popover relative to the status button.

#### 6.4 GameViewController
- Subclass of `NSViewController`.
- In `loadView()` creates and configures `SKView`:
  - `ignoresSiblingOrder = true`
  - `showsFPS = true` (debug only)
  - `showsPhysics = false`
- Instantiates and presents `SnookerScene`.

#### 6.5 SnookerScene
Core game implementation:

**Setup (`didMove(to:)`)**:
- Background colour matching snooker baize.
- `physicsWorld.gravity = .zero`, `contactDelegate = self`.
- Create table:
  - Green baize rectangle (`SKShapeNode`).
  - Brown cushion borders with high restitution (`0.95`).
  - Six pocket sensor nodes (circular, `isSensor = true`).
- Spawn balls:
  - Cue ball (white).
  - 15 red balls in standard triangle formation.
  - 6 coloured balls on their respective spots.
- All balls use circular `SKPhysicsBody` with appropriate mass, friction (`0.25`), and linear damping.

**Input Handling**:
- `mouseDown` / `mouseDragged` / `mouseUp` override.
- When mouse is pressed on cue ball, display aiming line (`SKShapeNode`).
- Drag distance determines impulse magnitude (capped).
- On mouse up: calculate direction vector and apply `applyImpulse` to cue-ball physics body.

**Physics & Rules**:
- `didBegin(_ contact:)` detects pocket contacts.
- Pot detection removes ball, updates score, checks for foul (cue ball potted or wrong ball hit first).
- Simple state machine tracks “next colour required” and current break.
- Collision sounds (optional) via `AVAudioPlayer`.

**UI Overlay**:
- Score label, next ball indicator, and “Reset Frame” button rendered as child `SKNode` labels or overlaid via additional `NSView` if needed.

### 7. Data Model & State Management

- `enum BallType: Int { case red, yellow, green, brown, blue, pink, black, cue }`
- `struct GameState` (value type) holding:
  - Current score (Player 1 / Player 2 or single-player break).
  - Balls remaining on table.
  - Next required colour.
  - Foul flag.
- All state persisted only in memory for the duration of the popover session.

### 8. Visual & Audio Design

- Colour palette: classic snooker green (#0A5C1F), brown cushions, white/red/yellow/green/brown/blue/pink/black balls.
- Aiming line: thin white dashed line with power gradient.
- Ball sprites: either solid `SKShapeNode` circles with fill colours or small PNG assets in `Resources`.
- Optional audio: short strike and potting sounds loaded from `Bundle.module`.

### 9. Extensibility Points

- Future rule modules can be added as separate `GameRuleEngine` protocols.
- Sound manager can be extracted into its own class.
- Additional scenes (menu, settings) can be swapped into the `SKView` without changing popover size.
- High-break persistence via `UserDefaults` (future).

### 10. Risks & Mitigations

- **Popover size constraint**: Fixed at 560 × 340 pt; SpriteKit `scaleMode = .aspectFit` ensures table remains fully visible.
- **Performance**: Maximum 22 dynamic bodies; SpriteKit handles 120 fps effortlessly.
- **Mouse coordinate mapping**: `SKView.convertPoint(fromView:)` used to translate correctly.
- **Dark mode**: All colours defined with semantic NSColors or explicit values that work in both appearances.
- **Resource loading**: All assets use SPM’s `Bundle.module` pattern.

### 11. Acceptance Criteria

- Application launches with only a menu-bar icon.
- Clicking icon displays exactly the snooker table in an attached popover.
- Balls can be struck with mouse drag; physics behave realistically.
- Pocketing balls updates score correctly and removes them from play.
- Foul detection works for cue-ball potting.
- Popover closes cleanly when clicking outside.
- Project builds and runs directly from `Package.swift` in Xcode with zero additional configuration.

This RFC fully specifies the architecture, implementation, and behaviour of SnookerMenuBar. Subsequent implementation can proceed directly from the component designs outlined above.