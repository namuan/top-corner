import SpriteKit
import AppKit

// MARK: - Constants

private enum PhysicsCategory: UInt32 {
    case ball    = 0b0001
    case cushion = 0b0010
    case pocket  = 0b0100
}

// MARK: - Ball Type

enum BallType: Int, CaseIterable {
    case cue, red, yellow, green, brown, blue, pink, black

    var color: NSColor {
        switch self {
        case .cue:    return .white
        case .red:    return NSColor(red: 0.85, green: 0.07, blue: 0.07, alpha: 1)
        case .yellow: return NSColor(red: 0.95, green: 0.85, blue: 0.10, alpha: 1)
        case .green:  return NSColor(red: 0.05, green: 0.60, blue: 0.15, alpha: 1)
        case .brown:  return NSColor(red: 0.50, green: 0.25, blue: 0.05, alpha: 1)
        case .blue:   return NSColor(red: 0.10, green: 0.30, blue: 0.85, alpha: 1)
        case .pink:   return NSColor(red: 0.95, green: 0.55, blue: 0.70, alpha: 1)
        case .black:  return NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        }
    }

    var points: Int {
        switch self {
        case .cue:    return 0
        case .red:    return 1
        case .yellow: return 2
        case .green:  return 3
        case .brown:  return 4
        case .blue:   return 5
        case .pink:   return 6
        case .black:  return 7
        }
    }
}

// MARK: - AI Difficulty

private enum AIDifficulty: Int, CaseIterable {
    case easy, medium, hard

    /// Max random angular error in radians applied to each AI shot.
    var angleError: CGFloat {
        switch self {
        case .easy:   return 0.20
        case .medium: return 0.09
        case .hard:   return 0.02
        }
    }

    /// Whether the AI picks a random valid target rather than the optimal one.
    var usesRandomTarget: Bool { self == .easy }

    var label: String {
        switch self {
        case .easy:   return "Easy"
        case .medium: return "Med"
        case .hard:   return "Hard"
        }
    }
}

// MARK: - AI Configuration

private enum AIConfig {
    static let distDecayBase:         CGFloat = 380   // probability distance-decay denominator
    static let safetyThreshold:       CGFloat = 0.12  // play safe below this pot probability
    static let lookaheadWeightRed:    CGFloat = 0.35  // next-shot blend weight when potting reds
    static let lookaheadWeightColour: CGFloat = 0.45  // higher weight after colour — sets up reds
    static let forceCalibDist:        CGFloat = 480   // force scaling denominator
    static let targetLeaveBuffer:     CGFloat = 120   // desired px gap between leave and next target
    static let minDesiredRoll:        CGFloat = 60    // minimum cue-ball post-contact roll
    static let safetyForceMin:        CGFloat = 35
    static let safetyForceMax:        CGFloat = 65
    static let safetyPathThreshold:   CGFloat = 0.4   // minimum clearance for a valid safety path
}

// MARK: - Game State

private enum TurnPhase {
    case needRed       // Must pot a red next
    case needColour    // Must pot a colour after a red
    case redsAllGone   // Pot colours in order
}

// MARK: - Snooker Scene

final class SnookerScene: SKScene, SKPhysicsContactDelegate {

    // Layout
    private let tableRect    = CGRect(x: 8, y: 8, width: 656, height: 364)
    private let ballRadius:  CGFloat = 10
    private let cornerPocketRadius: CGFloat = 17
    private let middlePocketRadius: CGFloat = 13

    // Nodes
    private var cueBall: SKShapeNode!
    private var balls:   [SKShapeNode: BallType] = [:]
    private var aimLine:       SKNode?
    // Sub-nodes of aimLine — created once, updated each drag event to avoid per-frame allocation
    private var aimCueLine:    SKShapeNode?
    private var aimGhostBall:  SKShapeNode?
    private var aimTargetLine: SKShapeNode?
    private var aimPowerDot:   SKShapeNode?

    // Input
    private var isDragging            = false
    private var dragStart             = CGPoint.zero
    private var isPlacingCueBall      = false
    private var isDraggingPlacement   = false
    private var lastValidPlacementPos = CGPoint.zero
    private var dHighlight: SKShapeNode?
    private var redsOnTable           = 0

    // Game state
    private var scores        = [0, 0]    // [player1, player2]
    private var currentPlayer = 0         // 0 = P1, 1 = P2
    private var phase: TurnPhase = .needRed
    private var lastRedPotted = false
    private var foulFlag      = false

    // Shot tracking
    private var waitingForStop       = false
    private var ballsWereMoving      = false
    private var pottedThisShot       = false
    private var foulThisShot         = false
    private var foulPenalty          = 0
    private var firstBallHit: BallType? = nil
    private var cueBallPottedThisShot  = false
    private var needsCueBallRespawn    = false
    private var lastFoulPenalty        = 0   // kept for display after foulPenalty is reset
    // Snapshot of game state at the moment the cue ball is struck — used in
    // endOfShot() so that mid-shot phase changes don't affect foul evaluation.
    private var shotPhase:          TurnPhase = .needRed
    private var shotClearanceIndex: Int       = 0

    // Power
    private var powerMultiplier: CGFloat = 3   // 1–5, user-adjustable
    private var powerPips: [SKShapeNode] = []

    // AI difficulty
    private var aiDifficulty: AIDifficulty = .medium
    private var diffButtons:  [AIDifficulty: SKShapeNode] = [:]

    // Probability overlay
    private var showOdds:            Bool       = false
    private var oddsToggleNode:      SKShapeNode?
    private var oddsToggleLabel:     SKLabelNode?
    private var probabilityOverlays: [SKNode]   = []

    // Pocket positions and radii — populated in setupPockets(), used by shot evaluation
    private var pocketData: [(position: CGPoint, radius: CGFloat)] = []

    // UI
    private var score1Label:      SKLabelNode!
    private var score2Label:      SKLabelNode!
    private var player1Dot:       SKShapeNode!
    private var player2Dot:       SKShapeNode!
    private var messageLabel:     SKLabelNode!
    private var nextBallIndicator: SKShapeNode!
    private var nextBallLabel:    SKLabelNode!
    private var powerLabel:       SKLabelNode!

    // Colours in clearance order
    private let clearanceOrder: [BallType] = [.yellow, .green, .brown, .blue, .pink, .black]
    private var clearanceIndex = 0
    private var colouredBalls: [BallType: SKShapeNode] = [:]

    // MARK: Scene lifecycle

    override func didMove(to view: SKView) {
        gLog("Scene loaded — size \(Int(size.width))×\(Int(size.height))")
        backgroundColor = NSColor(red: 0.12, green: 0.18, blue: 0.12, alpha: 1)
        physicsWorld.gravity   = .zero
        physicsWorld.contactDelegate = self

        loadSettings()
        setupTable()
        setupCushions()
        setupPockets()
        setupUI()
        spawnBalls()
    }

    // MARK: Table

    private func setupTable() {
        // Outer cream rail/frame — sits behind everything
        let railRect = tableRect.insetBy(dx: -14, dy: -14)
        let rail = SKShapeNode(rect: railRect, cornerRadius: 10)
        rail.fillColor   = NSColor(red: 0.91, green: 0.88, blue: 0.82, alpha: 1)
        rail.strokeColor = NSColor(red: 0.70, green: 0.66, blue: 0.58, alpha: 1)
        rail.lineWidth   = 2
        rail.zPosition   = 0
        addChild(rail)

        // Green baize — vivid, like the reference image
        let baize = SKShapeNode(rect: tableRect, cornerRadius: 3)
        baize.fillColor   = NSColor(red: 0.07, green: 0.52, blue: 0.16, alpha: 1)
        baize.strokeColor = .clear
        baize.zPosition   = 1
        addChild(baize)

        // Baulk line
        let baulkX = tableRect.minX + tableRect.width * 0.22
        let baulkLine = SKShapeNode()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: baulkX, y: tableRect.minY + 4))
        path.addLine(to: CGPoint(x: baulkX, y: tableRect.maxY - 4))
        baulkLine.path = path
        baulkLine.strokeColor = NSColor.white.withAlphaComponent(0.55)
        baulkLine.lineWidth = 1.5
        baulkLine.zPosition = 2
        addChild(baulkLine)

        // D semi-circle
        let dCenter = CGPoint(x: baulkX, y: tableRect.midY)
        let dRadius = tableRect.width * 0.083
        let dPath = CGMutablePath()
        dPath.addArc(center: dCenter, radius: dRadius, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: false)
        let dArc = SKShapeNode(path: dPath)
        dArc.strokeColor = NSColor.white.withAlphaComponent(0.55)
        dArc.lineWidth = 1.5
        dArc.zPosition = 2
        addChild(dArc)
    }

    // MARK: Cushions

    private func setupCushions() {
        let t = tableRect
        let thickness: CGFloat = 6
        let cR = cornerPocketRadius
        let mR = middlePocketRadius

        // Visual cushion rects
        let visualRects: [CGRect] = [
            CGRect(x: t.minX + cR,        y: t.minY,            width: t.width/2 - cR - mR * 0.5, height: thickness),
            CGRect(x: t.midX + mR * 0.5,  y: t.minY,            width: t.width/2 - mR * 0.5 - cR, height: thickness),
            CGRect(x: t.minX + cR,        y: t.maxY - thickness, width: t.width/2 - cR - mR * 0.5, height: thickness),
            CGRect(x: t.midX + mR * 0.5,  y: t.maxY - thickness, width: t.width/2 - mR * 0.5 - cR, height: thickness),
            CGRect(x: t.minX,             y: t.minY + cR,        width: thickness, height: t.height - cR * 2),
            CGRect(x: t.maxX - thickness,  y: t.minY + cR,       width: thickness, height: t.height - cR * 2),
        ]
        for rect in visualRects {
            let node = SKShapeNode(rect: rect)
            node.fillColor   = NSColor(red: 0.07, green: 0.52, blue: 0.16, alpha: 1)
            node.strokeColor = .clear
            node.zPosition   = 2
            addChild(node)
        }

        // Physics edges at the actual table boundary so balls travel to the rail face
        let physicsEdges: [(CGPoint, CGPoint)] = [
            // Bottom wall (left half)
            (CGPoint(x: t.minX + cR,       y: t.minY), CGPoint(x: t.midX - mR * 0.5, y: t.minY)),
            // Bottom wall (right half)
            (CGPoint(x: t.midX + mR * 0.5, y: t.minY), CGPoint(x: t.maxX - cR,       y: t.minY)),
            // Top wall (left half)
            (CGPoint(x: t.minX + cR,       y: t.maxY), CGPoint(x: t.midX - mR * 0.5, y: t.maxY)),
            // Top wall (right half)
            (CGPoint(x: t.midX + mR * 0.5, y: t.maxY), CGPoint(x: t.maxX - cR,       y: t.maxY)),
            // Left wall
            (CGPoint(x: t.minX, y: t.minY + cR), CGPoint(x: t.minX, y: t.maxY - cR)),
            // Right wall
            (CGPoint(x: t.maxX, y: t.minY + cR), CGPoint(x: t.maxX, y: t.maxY - cR)),
        ]
        for (start, end) in physicsEdges {
            let node = SKNode()
            let body = SKPhysicsBody(edgeFrom: start, to: end)
            body.friction    = 0.1
            body.restitution = 0.75
            body.categoryBitMask    = PhysicsCategory.cushion.rawValue
            body.collisionBitMask   = PhysicsCategory.ball.rawValue
            body.contactTestBitMask = 0
            node.physicsBody = body
            addChild(node)
        }
    }

    // MARK: Pockets

    private func setupPockets() {
        let t = tableRect
        let positions: [(CGPoint, CGFloat)] = [
            (CGPoint(x: t.minX,  y: t.minY), cornerPocketRadius),   // bottom-left
            (CGPoint(x: t.midX,  y: t.minY), middlePocketRadius),   // bottom-mid
            (CGPoint(x: t.maxX,  y: t.minY), cornerPocketRadius),   // bottom-right
            (CGPoint(x: t.minX,  y: t.maxY), cornerPocketRadius),   // top-left
            (CGPoint(x: t.midX,  y: t.maxY), middlePocketRadius),   // top-mid
            (CGPoint(x: t.maxX,  y: t.maxY), cornerPocketRadius),   // top-right
        ]

        pocketData = positions.map { (position: $0.0, radius: $0.1) }

        for (pos, pR) in positions {
            let pocket = SKShapeNode(circleOfRadius: pR)
            pocket.position    = pos
            pocket.fillColor   = NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
            pocket.strokeColor = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
            pocket.lineWidth   = 1.5
            pocket.zPosition   = 6
            pocket.name        = "pocket"

            let body = SKPhysicsBody(circleOfRadius: pR)
            body.isDynamic          = false
            body.categoryBitMask    = PhysicsCategory.pocket.rawValue
            body.collisionBitMask   = 0
            body.contactTestBitMask = PhysicsCategory.ball.rawValue
            pocket.physicsBody = body

            addChild(pocket)
        }
    }

    // MARK: Balls

    private func spawnBalls() {
        gLog("Spawning balls — new rack")
        balls.removeAll()
        colouredBalls.removeAll()
        redsOnTable = 0
        clearanceIndex = 0

        // Coloured ball spots
        let t = tableRect
        let baulkX  = t.minX + t.width * 0.22
        let dOffset = t.width * 0.083    // same as D arc radius — yellow/green sit exactly on the D circle
        let colourSpots: [(BallType, CGPoint)] = [
            (.yellow, CGPoint(x: baulkX, y: t.midY - dOffset)),
            (.green,  CGPoint(x: baulkX, y: t.midY + dOffset)),
            (.brown,  CGPoint(x: baulkX, y: t.midY)),
            (.blue,   CGPoint(x: t.midX,                        y: t.midY)),
            (.pink,   CGPoint(x: t.minX + t.width * 0.78 - ballRadius * 2,      y: t.midY)),
            (.black,  CGPoint(x: t.minX + t.width * 0.955,      y: t.midY)),
        ]

        for (type, spot) in colourSpots {
            let node = makeBall(type: type, at: spot)
            colouredBalls[type] = node
        }

        // Cue ball — start in placement mode
        let cueBallPos = CGPoint(x: t.minX + t.width * 0.18, y: t.midY)
        cueBall = makeBall(type: .cue, at: cueBallPos)
        enterCueBallPlacement()

        gLog("Spawned \(redsOnTable) reds + \(colouredBalls.count) colours. Cue ball entering placement.")
        // 15 reds in triangle
        spawnRedTriangle()
    }

    private func spawnRedTriangle() {
        let apex = CGPoint(x: tableRect.minX + tableRect.width * 0.78, y: tableRect.midY)
        let spacing: CGFloat = ballRadius * 2.2
        var count = 0
        for row in 0..<5 {
            for col in 0...row {
                let x = apex.x + CGFloat(row) * spacing
                let y = apex.y + CGFloat(col) * spacing - CGFloat(row) * spacing / 2
                _ = makeBall(type: .red, at: CGPoint(x: x, y: y))
                count += 1
                if count >= 15 { return }
            }
        }
    }

    @discardableResult
    private func makeBall(type: BallType, at position: CGPoint) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: ballRadius)
        node.position    = position
        node.fillColor   = type.color
        node.strokeColor = NSColor.white.withAlphaComponent(0.3)
        node.lineWidth   = 0.5
        node.zPosition   = 5
        node.name        = "ball_\(type.rawValue)"

        let body = SKPhysicsBody(circleOfRadius: ballRadius)
        body.mass           = 1.0
        body.friction       = 0.25
        body.restitution    = 0.85
        body.linearDamping  = 0.3
        body.angularDamping = 0.3
        body.categoryBitMask    = PhysicsCategory.ball.rawValue
        body.collisionBitMask   = PhysicsCategory.ball.rawValue | PhysicsCategory.cushion.rawValue
        // Cue ball also reports ball-ball contacts so we can track first-ball-hit
        let contactMask = type == .cue
            ? PhysicsCategory.pocket.rawValue | PhysicsCategory.ball.rawValue
            : PhysicsCategory.pocket.rawValue
        body.contactTestBitMask = contactMask
        body.allowsRotation     = true
        node.physicsBody = body

        balls[node] = type
        addChild(node)

        if type == .red { redsOnTable += 1 }
        return node
    }

    // MARK: UI

    private let aiActionKey = "ai_shot"

    // UserDefaults keys for persisted settings
    private enum PrefKey {
        static let power      = "tc_powerMultiplier"
        static let difficulty = "tc_aiDifficulty"
        static let showOdds   = "tc_showOdds"
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PrefKey.power) != nil {
            powerMultiplier = CGFloat(defaults.double(forKey: PrefKey.power))
        }
        if defaults.object(forKey: PrefKey.difficulty) != nil,
           let diff = AIDifficulty(rawValue: defaults.integer(forKey: PrefKey.difficulty)) {
            aiDifficulty = diff
        }
        if defaults.object(forKey: PrefKey.showOdds) != nil {
            showOdds = defaults.bool(forKey: PrefKey.showOdds)
        }
        gLog("Settings loaded — power: \(Int(powerMultiplier)), difficulty: \(aiDifficulty.label), odds: \(showOdds)", .debug)
    }

    private func saveSettings() {
        UserDefaults.standard.set(Double(powerMultiplier), forKey: PrefKey.power)
        UserDefaults.standard.set(aiDifficulty.rawValue,  forKey: PrefKey.difficulty)
        UserDefaults.standard.set(showOdds,               forKey: PrefKey.showOdds)
    }

    // Sidebar geometry constants
    // Scene: 820×380. Table occupies x=8..664, y=8..372.
    // Sidebar: x=672..820 (148px wide), centered at x=746.
    private let sideX:   CGFloat = 672   // sidebar left edge
    private let sideCX:  CGFloat = 746   // sidebar centre x
    private let sideInL: CGFloat = 680   // inner left  (8px padding)
    private let sideInR: CGFloat = 812   // inner right (8px padding)
    private let sideW:   CGFloat = 132   // inner usable width

    private func setupUI() {
        // ── Sidebar panel background ──────────────────────────────────
        let panel = SKShapeNode(rect: CGRect(x: sideX, y: 0, width: 148, height: 380))
        panel.fillColor   = NSColor(white: 0.10, alpha: 1)
        panel.strokeColor = .clear
        panel.zPosition   = 9
        addChild(panel)

        // Left edge accent line
        let divider = SKShapeNode()
        let dp = CGMutablePath()
        dp.move(to: CGPoint(x: sideX, y: 0))
        dp.addLine(to: CGPoint(x: sideX, y: 380))
        divider.path = dp
        divider.strokeColor = NSColor(white: 0.28, alpha: 1)
        divider.lineWidth   = 1
        divider.zPosition   = 9
        addChild(divider)

        // ── SCORE section ────────────────────────────────────────────
        // y=322..380 (58px). Content height ≈44px → 7px padding top+bottom.
        // header_top=373→baseline=366; P1 dot=352, label=348; P2 dot=336, label=332
        addSideHeader("SCORE", y: 366)

        player1Dot = SKShapeNode(circleOfRadius: 4)
        player1Dot.position  = CGPoint(x: sideInL + 4, y: 352)
        player1Dot.zPosition = 11
        addChild(player1Dot)
        let p1Lbl = SKLabelNode(text: "P1")
        p1Lbl.fontName  = "Helvetica Neue"
        p1Lbl.fontSize  = 11
        p1Lbl.fontColor = NSColor(white: 0.75, alpha: 1)
        p1Lbl.position  = CGPoint(x: sideInL + 16, y: 348)
        p1Lbl.horizontalAlignmentMode = .left
        p1Lbl.zPosition = 10
        addChild(p1Lbl)
        score1Label = SKLabelNode(fontNamed: "Helvetica Neue Bold")
        score1Label.fontSize  = 15
        score1Label.fontColor = .white
        score1Label.position  = CGPoint(x: sideInR, y: 348)
        score1Label.horizontalAlignmentMode = .right
        score1Label.zPosition = 10
        addChild(score1Label)

        player2Dot = SKShapeNode(circleOfRadius: 4)
        player2Dot.position  = CGPoint(x: sideInL + 4, y: 336)
        player2Dot.zPosition = 11
        addChild(player2Dot)
        let p2Lbl = SKLabelNode(text: "P2")
        p2Lbl.fontName  = "Helvetica Neue"
        p2Lbl.fontSize  = 11
        p2Lbl.fontColor = NSColor(white: 0.75, alpha: 1)
        p2Lbl.position  = CGPoint(x: sideInL + 16, y: 332)
        p2Lbl.horizontalAlignmentMode = .left
        p2Lbl.zPosition = 10
        addChild(p2Lbl)
        score2Label = SKLabelNode(fontNamed: "Helvetica Neue Bold")
        score2Label.fontSize  = 15
        score2Label.fontColor = NSColor(white: 0.55, alpha: 1)
        score2Label.position  = CGPoint(x: sideInR, y: 332)
        score2Label.horizontalAlignmentMode = .right
        score2Label.zPosition = 10
        addChild(score2Label)

        addSideSeparator(y: 322)

        // ── NEXT BALL section — inline circle + label (no heading) ──────
        // y=278..322 (44px). Only the row: circle r=9 centred vertically → cy=300.
        // Circle pinned to left edge; label right-aligned so long text grows leftward
        nextBallIndicator = SKShapeNode(circleOfRadius: 9)
        nextBallIndicator.position    = CGPoint(x: sideInL + 11, y: 300)
        nextBallIndicator.strokeColor = NSColor.white.withAlphaComponent(0.35)
        nextBallIndicator.lineWidth   = 1
        nextBallIndicator.zPosition   = 10
        addChild(nextBallIndicator)

        nextBallLabel = SKLabelNode(fontNamed: "Helvetica Neue")
        nextBallLabel.fontSize  = 11
        nextBallLabel.fontColor = NSColor(white: 0.75, alpha: 1)
        nextBallLabel.position  = CGPoint(x: sideInR, y: 300)
        nextBallLabel.horizontalAlignmentMode = .right
        nextBallLabel.verticalAlignmentMode   = .center
        nextBallLabel.zPosition = 10
        addChild(nextBallLabel)

        addSideSeparator(y: 278)

        // ── STATUS / MESSAGE ──────────────────────────────────────────
        // y=254..278 (24px). 11pt label visually centred at section mid (266).
        // baseline = 266 − (11×0.25) ≈ 263
        messageLabel = SKLabelNode(fontNamed: "Helvetica Neue")
        messageLabel.fontSize  = 11
        messageLabel.fontColor = NSColor.yellow
        messageLabel.position  = CGPoint(x: sideCX, y: 263)
        messageLabel.horizontalAlignmentMode = .center
        messageLabel.zPosition = 10
        addChild(messageLabel)

        addSideSeparator(y: 254)

        // ── POWER section ─────────────────────────────────────────────
        // y=192..254 (62px). Content: header+buttons(22px)+pips → height≈52px → 5px padding.
        // header_top=249→baseline=242; buttons rect y=210..232; pips cy=200
        addSideHeader("POWER", y: 242)

        let minusBg = SKShapeNode(rect: CGRect(x: sideInL, y: 210, width: 22, height: 22), cornerRadius: 4)
        minusBg.fillColor   = NSColor(white: 0.25, alpha: 1)
        minusBg.strokeColor = NSColor(white: 0.40, alpha: 1)
        minusBg.lineWidth   = 0.5
        minusBg.zPosition   = 10
        minusBg.name        = "pwrMinus"
        addChild(minusBg)
        let minusLbl = SKLabelNode(text: "–")
        minusLbl.fontName  = "Helvetica Neue"
        minusLbl.fontSize  = 15
        minusLbl.fontColor = .white
        minusLbl.position  = CGPoint(x: sideInL + 11, y: 217)
        minusLbl.horizontalAlignmentMode = .center
        minusLbl.zPosition = 11
        minusLbl.name      = "pwrMinus"
        addChild(minusLbl)

        let plusBg = SKShapeNode(rect: CGRect(x: sideInR - 22, y: 210, width: 22, height: 22), cornerRadius: 4)
        plusBg.fillColor   = NSColor(white: 0.25, alpha: 1)
        plusBg.strokeColor = NSColor(white: 0.40, alpha: 1)
        plusBg.lineWidth   = 0.5
        plusBg.zPosition   = 10
        plusBg.name        = "pwrPlus"
        addChild(plusBg)
        let plusLbl = SKLabelNode(text: "+")
        plusLbl.fontName  = "Helvetica Neue"
        plusLbl.fontSize  = 14
        plusLbl.fontColor = .white
        plusLbl.position  = CGPoint(x: sideInR - 11, y: 217)
        plusLbl.horizontalAlignmentMode = .center
        plusLbl.zPosition = 11
        plusLbl.name      = "pwrPlus"
        addChild(plusLbl)

        powerLabel = SKLabelNode(fontNamed: "Helvetica Neue Bold")
        powerLabel.fontSize  = 14
        powerLabel.fontColor = .white
        powerLabel.position  = CGPoint(x: sideCX, y: 217)
        powerLabel.horizontalAlignmentMode = .center
        powerLabel.zPosition = 11
        addChild(powerLabel)

        // Pips centred horizontally around sideCX; cy=200 (7px below buttons, 5px above sep)
        powerPips = []
        let pipSpacing: CGFloat = 16
        let pipStartX = sideCX - pipSpacing * 2
        for i in 0..<5 {
            let pip = SKShapeNode(circleOfRadius: 3)
            pip.position  = CGPoint(x: pipStartX + CGFloat(i) * pipSpacing, y: 200)
            pip.lineWidth = 1
            pip.zPosition = 10
            addChild(pip)
            powerPips.append(pip)
        }
        updatePowerPips()

        addSideSeparator(y: 192)

        // ── AI LEVEL + SHOW ODDS section ──────────────────────────────
        // y=98..192 (94px). Content: header+diff(16px)+odds(16px) → height≈57px → 18px padding.
        // header_top=174→baseline=167; diff rect y=141..157; odds rect y=117..133
        addSideHeader("AI LEVEL", y: 167)

        let diffData: [(AIDifficulty, String, CGFloat)] = [
            (.easy,   "Easy", sideInL),
            (.medium, "Med",  sideInL + 46),
            (.hard,   "Hard", sideInL + 92),
        ]
        for (diff, title, bx) in diffData {
            let bg = SKShapeNode(rect: CGRect(x: bx, y: 141, width: 40, height: 16), cornerRadius: 3)
            bg.lineWidth   = 0.5
            bg.zPosition   = 10
            bg.name        = "diff_\(diff.rawValue)"
            addChild(bg)
            diffButtons[diff] = bg

            let lbl = SKLabelNode(text: title)
            lbl.fontName  = "Helvetica Neue"
            lbl.fontSize  = 10
            lbl.fontColor = .white
            lbl.position  = CGPoint(x: bx + 20, y: 149)  // rect centre: 141+8
            lbl.horizontalAlignmentMode = .center
            lbl.verticalAlignmentMode   = .center
            lbl.zPosition = 11
            lbl.name      = "diff_\(diff.rawValue)"
            addChild(lbl)
        }
        updateDifficultyButtons()

        let oddsBg = SKShapeNode(rect: CGRect(x: sideInL, y: 117, width: sideW, height: 16), cornerRadius: 3)
        oddsBg.lineWidth   = 0.5
        oddsBg.zPosition   = 10
        oddsBg.name        = "oddsToggle"
        addChild(oddsBg)
        oddsToggleNode = oddsBg

        let oddsLbl = SKLabelNode(text: "")
        oddsLbl.fontName  = "Helvetica Neue"
        oddsLbl.fontSize  = 10
        oddsLbl.fontColor = .white
        oddsLbl.position  = CGPoint(x: sideCX, y: 125)  // rect centre: 117+8
        oddsLbl.horizontalAlignmentMode = .center
        oddsLbl.verticalAlignmentMode   = .center
        oddsLbl.zPosition = 11
        oddsLbl.name      = "oddsToggle"
        addChild(oddsLbl)
        oddsToggleLabel = oddsLbl
        updateOddsToggle()

        addSideSeparator(y: 98)

        // ── Action buttons ────────────────────────────────────────────
        // y=0..98 (98px). Two 24px buttons + 10px gap = 58px → 20px padding top+bottom.
        // New Game rect y=54..78; Quit rect y=20..44
        let resetBg = SKShapeNode(rect: CGRect(x: sideInL, y: 54, width: sideW, height: 24), cornerRadius: 5)
        resetBg.fillColor   = NSColor(white: 0.25, alpha: 1)
        resetBg.strokeColor = NSColor(white: 0.42, alpha: 1)
        resetBg.lineWidth   = 0.5
        resetBg.zPosition   = 10
        resetBg.name        = "resetBtn"
        addChild(resetBg)
        let resetLbl = SKLabelNode(text: "New Game")
        resetLbl.fontName   = "Helvetica Neue"
        resetLbl.fontSize   = 11
        resetLbl.fontColor  = .white
        resetLbl.position   = CGPoint(x: sideCX, y: 63)
        resetLbl.horizontalAlignmentMode = .center
        resetLbl.zPosition  = 11
        resetLbl.name       = "resetBtn"
        addChild(resetLbl)

        let quitBg = SKShapeNode(rect: CGRect(x: sideInL, y: 20, width: sideW, height: 24), cornerRadius: 5)
        quitBg.fillColor   = NSColor(red: 0.45, green: 0.08, blue: 0.08, alpha: 1)
        quitBg.strokeColor = NSColor(red: 0.65, green: 0.18, blue: 0.18, alpha: 1)
        quitBg.lineWidth   = 0.5
        quitBg.zPosition   = 10
        quitBg.name        = "quitBtn"
        addChild(quitBg)
        let quitLbl = SKLabelNode(text: "Quit")
        quitLbl.fontName   = "Helvetica Neue"
        quitLbl.fontSize   = 11
        quitLbl.fontColor  = .white
        quitLbl.position   = CGPoint(x: sideCX, y: 29)
        quitLbl.horizontalAlignmentMode = .center
        quitLbl.zPosition  = 11
        quitLbl.name       = "quitBtn"
        addChild(quitLbl)

        updateUI()
    }

    private func addSideHeader(_ text: String, y: CGFloat) {
        let lbl = SKLabelNode(text: text)
        lbl.fontName  = "Helvetica Neue"
        lbl.fontSize  = 9
        lbl.fontColor = NSColor(white: 0.45, alpha: 1)
        lbl.position  = CGPoint(x: sideCX, y: y)
        lbl.horizontalAlignmentMode = .center
        lbl.zPosition = 10
        addChild(lbl)
    }

    private func addSideSeparator(y: CGFloat) {
        let sep = SKShapeNode()
        let p = CGMutablePath()
        p.move(to: CGPoint(x: sideInL, y: y))
        p.addLine(to: CGPoint(x: sideInR, y: y))
        sep.path        = p
        sep.strokeColor = NSColor(white: 0.25, alpha: 1)
        sep.lineWidth   = 0.5
        sep.zPosition   = 10
        addChild(sep)
    }

    private func updateOddsToggle() {
        oddsToggleNode?.fillColor   = showOdds
            ? NSColor(red: 0.10, green: 0.45, blue: 0.20, alpha: 1)
            : NSColor(white: 0.22, alpha: 1)
        oddsToggleNode?.strokeColor = showOdds
            ? NSColor(red: 0.25, green: 0.80, blue: 0.35, alpha: 1)
            : NSColor(white: 0.38, alpha: 1)
        oddsToggleLabel?.text = showOdds ? "Odds: ON" : "Odds: OFF"
    }

    private func updateDifficultyButtons() {
        let activeStroke = NSColor(red: 0.30, green: 0.75, blue: 1.0, alpha: 1)
        for (diff, node) in diffButtons {
            let selected = diff == aiDifficulty
            node.fillColor   = selected ? NSColor(red: 0.10, green: 0.35, blue: 0.55, alpha: 1)
                                        : NSColor(white: 0.22, alpha: 1)
            node.strokeColor = selected ? activeStroke : NSColor(white: 0.38, alpha: 1)
        }
    }

    private func updatePowerPips() {
        let active   = NSColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 1)
        let inactive = NSColor(white: 0.25, alpha: 1)
        for (i, pip) in powerPips.enumerated() {
            let on = i < Int(powerMultiplier)
            pip.fillColor   = on ? active : inactive
            pip.strokeColor = on ? active.withAlphaComponent(0.5) : NSColor(white: 0.35, alpha: 1)
        }
        powerLabel.text = "\(Int(powerMultiplier))"
    }

    private func updateUI() {
        score1Label.text = "\(scores[0])"
        score2Label.text = "\(scores[1])"

        let activeColor   = NSColor.white
        let inactiveColor = NSColor(white: 0.45, alpha: 1)
        let dotActive     = NSColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1)
        let dotInactive   = NSColor(white: 0.3, alpha: 1)

        player1Dot.fillColor   = currentPlayer == 0 ? dotActive : dotInactive
        player1Dot.strokeColor = .clear
        player2Dot.fillColor   = currentPlayer == 1 ? dotActive : dotInactive
        player2Dot.strokeColor = .clear
        score1Label.fontColor  = currentPlayer == 0 ? activeColor : inactiveColor
        score2Label.fontColor  = currentPlayer == 1 ? activeColor : inactiveColor

        switch phase {
        case .needRed:
            nextBallIndicator.fillColor = BallType.red.color
            nextBallLabel.text = "Next: Red"
        case .needColour:
            // Any colour is valid — show a neutral white indicator, not a specific ball
            nextBallIndicator.fillColor = NSColor(white: 0.85, alpha: 1)
            nextBallLabel.text = "Next: Any Colour"
        case .redsAllGone:
            let next = clearanceOrder[min(clearanceIndex, clearanceOrder.count - 1)]
            nextBallIndicator.fillColor = next.color
            nextBallLabel.text = "Next: \(next)".capitalized
        }

        if foulFlag {
            messageLabel.text = "FOUL! +\(lastFoulPenalty) to P\(currentPlayer == 0 ? 2 : 1)"
            messageLabel.fontColor = NSColor.orange
        } else {
            messageLabel.text = ""
        }

        updateProbabilityOverlays()
    }

    private func updateProbabilityOverlays() {
        probabilityOverlays.forEach { $0.removeFromParent() }
        probabilityOverlays.removeAll()

        guard showOdds, let cue = cueBall, !isPlacingCueBall, !waitingForStop else { return }

        let targets   = validAITargets()
        let pockets   = aiPocketPositions()
        let allObs    = balls.keys.filter { $0 !== cue }.map { $0.position }

        for (node, _) in targets {
            let obs = obstaclesExcluding(allObs, ballAt: node.position)
            var bestProb: CGFloat = 0
            for (pocketPos, pocketRadius) in pockets {
                let (_, p) = evaluateShot(cuePos: cue.position,
                                          target: node,
                                          pocket: pocketPos,
                                          pocketRadius: pocketRadius,
                                          obstacles: obs)
                if p > bestProb { bestProb = p }
            }

            // Colour: green ≥ 0.35, yellow ≥ 0.12, red below
            let ringColor: NSColor
            switch bestProb {
            case 0.35...: ringColor = NSColor(red: 0.15, green: 0.90, blue: 0.25, alpha: 0.90)
            case 0.12..<0.35: ringColor = NSColor(red: 0.95, green: 0.80, blue: 0.10, alpha: 0.90)
            default:      ringColor = NSColor(red: 0.95, green: 0.20, blue: 0.15, alpha: 0.90)
            }

            let ring = SKShapeNode(circleOfRadius: ballRadius + 3.5)
            ring.position    = node.position
            ring.fillColor   = .clear
            ring.strokeColor = ringColor
            ring.lineWidth   = 2
            ring.zPosition   = 7
            addChild(ring)
            probabilityOverlays.append(ring)

            let pct = Int(bestProb * 100)
            let lbl = SKLabelNode(text: "\(pct)%")
            lbl.fontName  = "Helvetica Neue Bold"
            lbl.fontSize  = 8
            lbl.fontColor = ringColor
            lbl.position  = CGPoint(x: node.position.x, y: node.position.y + ballRadius + 6)
            lbl.horizontalAlignmentMode = .center
            lbl.zPosition = 7
            addChild(lbl)
            probabilityOverlays.append(lbl)
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let loc = event.location(in: self)

        let tapped = atPoint(loc)
        if tapped.name == "resetBtn" { resetGame(); return }
        if tapped.name == "quitBtn"  { NSApp.terminate(nil); return }
        if tapped.name == "pwrMinus" { adjustPower(-1); return }
        if tapped.name == "pwrPlus"  { adjustPower(+1); return }
        if let name = tapped.name, name.hasPrefix("diff_"),
           let raw = Int(name.dropFirst(5)),
           let diff = AIDifficulty(rawValue: raw) {
            aiDifficulty = diff
            gLog("AI difficulty set to \(diff.label)")
            updateDifficultyButtons()
            saveSettings()
            return
        }
        if tapped.name == "oddsToggle" {
            showOdds = !showOdds
            gLog("Probability indicators \(showOdds ? "enabled" : "disabled")")
            updateOddsToggle()
            updateProbabilityOverlays()
            saveSettings()
            return
        }

        // Cue ball placement mode
        if isPlacingCueBall {
            isDraggingPlacement   = true
            lastValidPlacementPos = cueBall.position
            let candidate = clampToD(loc)
            if !overlapsAnyBall(candidate) {
                cueBall.position      = candidate
                lastValidPlacementPos = candidate
            }
            return
        }

        // Only start shot drag if clicking near cue ball and balls are settled
        guard let cue = cueBall, !isBallMoving() else { return }
        let d = hypot(loc.x - cue.position.x, loc.y - cue.position.y)
        if d < ballRadius * 3 {
            isDragging = true
            dragStart  = loc
            foulFlag   = false
            updateUI()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = event.location(in: self)

        if isDraggingPlacement {
            let candidate = clampToD(loc)
            if !overlapsAnyBall(candidate) {
                cueBall.position      = candidate
                lastValidPlacementPos = candidate
            } else {
                cueBall.position = lastValidPlacementPos
            }
            return
        }

        guard isDragging else { return }
        drawAimLine(from: dragStart, to: loc)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingPlacement {
            cueBall.position = lastValidPlacementPos
            exitCueBallPlacement()
            return
        }

        guard isDragging, let cue = cueBall else { return }
        isDragging = false
        aimLine?.removeFromParent()
        aimLine = nil; aimCueLine = nil; aimGhostBall = nil; aimTargetLine = nil; aimPowerDot = nil

        let loc  = event.location(in: self)
        let dx   = cue.position.x - loc.x
        let dy   = cue.position.y - loc.y
        let dist = hypot(dx, dy)
        guard dist > 4 else { return }

        let maxForce: CGFloat = 150 * powerMultiplier
        let scale = min(dist / 120, 1.0) * maxForce
        let impulse = CGVector(dx: (dx / dist) * scale, dy: (dy / dist) * scale)
        cue.physicsBody?.applyImpulse(impulse)

        gLog("P\(currentPlayer + 1) shot — power \(Int(powerMultiplier)), drag \(Int(dist))px, impulse (dx:\(String(format:"%.1f", impulse.dx)) dy:\(String(format:"%.1f", impulse.dy))), phase: \(phase)")

        waitingForStop        = true
        updateProbabilityOverlays()   // hide immediately — balls now in play
        ballsWereMoving       = false
        pottedThisShot        = false
        foulThisShot          = false
        foulPenalty           = 0
        firstBallHit          = nil
        cueBallPottedThisShot = false
        shotPhase             = phase
        shotClearanceIndex    = clearanceIndex
    }

    private func adjustPower(_ delta: CGFloat) {
        powerMultiplier = max(1, min(5, powerMultiplier + delta))
        gLog("Power adjusted to \(Int(powerMultiplier))", .debug)
        updatePowerPips()
        saveSettings()
    }

    /// Returns the point where a ray from `from` in direction (dirX, dirY) first hits
    /// the table boundary, clamped to a sensible maximum so it never overshoots.
    private func rayToTableEdge(from origin: CGPoint, dirX: CGFloat, dirY: CGFloat) -> CGPoint {
        let t = tableRect
        var tMin = CGFloat.infinity
        if dirX > 0 { tMin = min(tMin, (t.maxX - origin.x) / dirX) }
        else if dirX < 0 { tMin = min(tMin, (t.minX - origin.x) / dirX) }
        if dirY > 0 { tMin = min(tMin, (t.maxY - origin.y) / dirY) }
        else if dirY < 0 { tMin = min(tMin, (t.minY - origin.y) / dirY) }
        let safeT = max(0, min(tMin, 1000))
        return CGPoint(x: origin.x + dirX * safeT, y: origin.y + dirY * safeT)
    }

    private func drawAimLine(from start: CGPoint, to end: CGPoint) {
        guard let cue = cueBall else { return }

        // Direction is always anchored to the cue ball centre so the visual and
        // the actual shot trajectory share the same origin and direction.
        let dx = cue.position.x - end.x
        let dy = cue.position.y - end.y
        let dist = hypot(dx, dy)
        guard dist > 2 else { return }

        let dirX  = dx / dist
        let dirY  = dy / dist
        let ratio = min(hypot(start.x - end.x, start.y - end.y), 160) / 160

        // Lazy creation — nodes are reused across drag events to avoid per-frame allocation.
        if aimLine == nil {
            let container = SKNode()
            container.zPosition = 8
            addChild(container)

            let cl = SKShapeNode(); cl.lineWidth = 1; cl.lineCap = .round
            container.addChild(cl); aimCueLine = cl

            let gb = SKShapeNode(circleOfRadius: ballRadius)
            gb.fillColor   = NSColor.white.withAlphaComponent(0.18)
            gb.strokeColor = NSColor.white.withAlphaComponent(0.70)
            gb.lineWidth   = 1
            container.addChild(gb); aimGhostBall = gb

            let tl = SKShapeNode()
            tl.strokeColor = NSColor(red: 0.95, green: 0.75, blue: 0.20, alpha: 0.70)
            tl.lineWidth = 1; tl.lineCap = .round
            container.addChild(tl); aimTargetLine = tl

            let dot = SKShapeNode(); dot.strokeColor = .clear
            container.addChild(dot); aimPowerDot = dot

            aimLine = container
        }

        // Ray-cast: find the first object ball the cue ball would hit.
        // Solves |cuePos + t·dir - T|² = (2r)² for t > 0.
        var closestT   = CGFloat.infinity
        var ghostPos:   CGPoint? = nil
        var hitBallPos: CGPoint? = nil

        for (ballNode, _) in balls where ballNode !== cue {
            let fx   = cue.position.x - ballNode.position.x
            let fy   = cue.position.y - ballNode.position.y
            let fd   = fx * dirX + fy * dirY
            let disc = fd * fd - (fx * fx + fy * fy - ballRadius * ballRadius * 4)
            guard disc >= 0 else { continue }
            let t = -fd - sqrt(disc)
            guard t > 0, t < closestT else { continue }
            closestT   = t
            ghostPos   = CGPoint(x: cue.position.x + t * dirX, y: cue.position.y + t * dirY)
            hitBallPos = ballNode.position
        }

        // Update cue-ball path.
        let cueEnd = ghostPos ?? rayToTableEdge(from: cue.position, dirX: dirX, dirY: dirY)
        let cuePath = CGMutablePath(); cuePath.move(to: cue.position); cuePath.addLine(to: cueEnd)
        aimCueLine?.path        = cuePath
        aimCueLine?.strokeColor = NSColor.white.withAlphaComponent(0.45 + ratio * 0.35)

        // Update ghost ball and target projection.
        if let ghost = ghostPos, let hit = hitBallPos {
            aimGhostBall?.position = ghost
            aimGhostBall?.isHidden = false

            let tddx = hit.x - ghost.x
            let tddy = hit.y - ghost.y
            let tddist = hypot(tddx, tddy)
            if tddist > 0 {
                let targetEnd = rayToTableEdge(from: hit, dirX: tddx / tddist, dirY: tddy / tddist)
                let tp = CGMutablePath(); tp.move(to: hit); tp.addLine(to: targetEnd)
                aimTargetLine?.path     = tp
                aimTargetLine?.isHidden = false
            } else {
                aimTargetLine?.isHidden = true
            }
        } else {
            aimGhostBall?.isHidden  = true
            aimTargetLine?.isHidden = true
        }

        // Update power dot (radius varies with drag distance).
        let dotR = 3 + ratio * 4
        aimPowerDot?.path      = CGPath(ellipseIn: CGRect(x: -dotR, y: -dotR, width: dotR * 2, height: dotR * 2), transform: nil)
        aimPowerDot?.position  = end
        aimPowerDot?.fillColor = NSColor(red: 1, green: 0.5 - ratio * 0.5, blue: 0, alpha: 0.8)
    }

    // MARK: Physics contact

    func didBegin(_ contact: SKPhysicsContact) {
        let (nodeA, nodeB) = (contact.bodyA.node, contact.bodyB.node)
        let isPocketA = nodeA?.name == "pocket"
        let isPocketB = nodeB?.name == "pocket"

        // Track the first object ball the cue ball touches this shot
        if !isPocketA && !isPocketB && waitingForStop && firstBallHit == nil {
            let isCueA = nodeA === cueBall
            let isCueB = nodeB === cueBall
            if isCueA || isCueB {
                let other = (isCueA ? nodeB : nodeA) as? SKShapeNode
                if let other, let type = balls[other] {
                    firstBallHit = type
                    gLog("Cue ball first contact: \(type) (phase: \(phase), required: \(requiredBallDescription()))")
                }
            }
        }

        guard isPocketA || isPocketB else { return }
        let potentialBall = isPocketA ? nodeB : nodeA
        guard let ballNode = potentialBall as? SKShapeNode else { return }
        guard let type = balls[ballNode] else { return }
        potBall(node: ballNode, type: type)
    }

    private func potBall(node: SKShapeNode, type: BallType) {
        balls.removeValue(forKey: node)
        node.removeFromParent()

        if type == .cue {
            // Cue ball potted — foul. Don't respawn yet; endOfShot() will do it
            // after the turn has been correctly switched to the opponent.
            cueBallPottedThisShot = true
            needsCueBallRespawn   = true
            let pen = cueBallFoulPenalty()
            gLog("FOUL — cue ball potted (penalty \(pen))", .warning)
            recordFoul(penalty: pen)
            updateUI()
            return
        }

        switch phase {
        case .needRed:
            if type == .red {
                redsOnTable -= 1
                scores[currentPlayer] += type.points
                pottedThisShot = true
                phase = .needColour
                gLog("P\(currentPlayer + 1) potted red (+\(type.points)pt) — score now \(scores[currentPlayer]), reds remaining: \(redsOnTable), phase → needColour")
            } else {
                let pen = max(4, type.points)
                gLog("FOUL — potted \(type) (\(type.points)pt) when red required — penalty \(pen), \(type) respawned", .warning)
                recordFoul(penalty: pen)
                respawnColour(type)
            }

        case .needColour:
            if type != .red {
                scores[currentPlayer] += type.points
                pottedThisShot = true
                let nextPhase: TurnPhase = redsOnTable > 0 ? .needRed : .redsAllGone
                gLog("P\(currentPlayer + 1) potted \(type) (+\(type.points)pt) — score now \(scores[currentPlayer]), reds remaining: \(redsOnTable), phase → \(nextPhase)")
                if redsOnTable > 0 {
                    respawnColour(type)
                }
                phase = nextPhase
            } else if pottedThisShot {
                // Extra red potted in the same shot as a previous red — legal,
                // scores 1pt each; player still owes one colour (phase stays needColour)
                redsOnTable -= 1
                scores[currentPlayer] += type.points
                gLog("P\(currentPlayer + 1) potted extra red in same shot (+\(type.points)pt, legal) — score now \(scores[currentPlayer]), reds remaining: \(redsOnTable)")
            } else {
                // Foul — red potted on a shot where colour was required
                gLog("FOUL — potted red when colour required — penalty 4, red removed", .warning)
                recordFoul(penalty: 4)
                redsOnTable -= 1
            }

        case .redsAllGone:
            let required = clearanceOrder[clearanceIndex]
            if type == required {
                scores[currentPlayer] += type.points
                pottedThisShot = true
                clearanceIndex += 1
                gLog("P\(currentPlayer + 1) potted \(type) in clearance (+\(type.points)pt) — score now \(scores[currentPlayer]), clearance index: \(clearanceIndex)/\(clearanceOrder.count)")
                if clearanceIndex >= clearanceOrder.count {
                    showWin()
                }
            } else {
                let pen = max(4, type.points)
                gLog("FOUL — potted \(type) in clearance but required \(required) — penalty \(pen), \(type) respawned", .warning)
                recordFoul(penalty: pen)
                respawnColour(type)
            }
        }

        updateUI()
    }

    private func recordFoul(penalty: Int) {
        let previous = foulPenalty
        foulFlag     = true
        foulThisShot = true
        foulPenalty  = max(foulPenalty, penalty)   // keep the highest if multiple fouls
        if foulPenalty > previous {
            gLog("Foul recorded — penalty raised to \(foulPenalty) (was \(previous))", .warning)
        }
    }

    private func cueBallFoulPenalty(for phase: TurnPhase? = nil, clearanceIndex idx: Int? = nil) -> Int {
        let p = phase ?? self.phase
        let i = idx   ?? self.clearanceIndex
        switch p {
        case .needRed:    return 4
        case .needColour: return 4
        case .redsAllGone:
            let on = clearanceOrder[min(i, clearanceOrder.count - 1)]
            return max(4, on.points)
        }
    }

    private func respawnCueBall() {
        let t = tableRect
        let pos = CGPoint(x: t.minX + t.width * 0.18, y: t.midY)
        cueBall = makeBall(type: .cue, at: pos)
        enterCueBallPlacement()
    }

    private func enterCueBallPlacement() {
        gLog("Cue ball placement entered — P\(currentPlayer + 1) placing in D")
        isPlacingCueBall = true
        // Ghost the ball — remove from physics category system entirely while positioning
        cueBall.physicsBody?.isDynamic          = false
        cueBall.physicsBody?.categoryBitMask    = 0
        cueBall.physicsBody?.collisionBitMask   = 0
        cueBall.physicsBody?.contactTestBitMask = 0

        // AI: auto-place without showing the D UI
        if currentPlayer == 1 {
            messageLabel.text      = "P2 placing…"
            messageLabel.fontColor = NSColor(white: 0.60, alpha: 1)
            run(SKAction.sequence([
                SKAction.wait(forDuration: 0.6),
                SKAction.run { [weak self] in self?.aiPlaceCueBall() }
            ]), withKey: aiActionKey)
            return
        }

        // Human P1: highlight the D area
        let t = tableRect
        let baulkX = t.minX + t.width * 0.22
        let dRadius = t.width * 0.083
        let dCenter = CGPoint(x: baulkX, y: t.midY)
        let dPath = CGMutablePath()
        dPath.move(to: CGPoint(x: baulkX, y: dCenter.y - dRadius))
        dPath.addLine(to: CGPoint(x: baulkX, y: dCenter.y + dRadius))
        dPath.addArc(center: dCenter, radius: dRadius,
                     startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        dPath.closeSubpath()
        let highlight = SKShapeNode(path: dPath)
        highlight.fillColor   = NSColor.white.withAlphaComponent(0.12)
        highlight.strokeColor = NSColor.white.withAlphaComponent(0.45)
        highlight.lineWidth   = 1.5
        highlight.zPosition   = 4
        highlight.name        = "dHighlight"
        addChild(highlight)
        dHighlight = highlight

        messageLabel.text      = "Place cue ball in D"
        messageLabel.fontColor = NSColor(red: 0.4, green: 0.9, blue: 1.0, alpha: 1)
    }

    private func exitCueBallPlacement() {
        gLog("Cue ball placement done — placed at (\(String(format:"%.1f", cueBall.position.x)), \(String(format:"%.1f", cueBall.position.y)))")
        isPlacingCueBall    = false
        isDraggingPlacement = false
        cueBall.physicsBody?.isDynamic          = true
        cueBall.physicsBody?.categoryBitMask    = PhysicsCategory.ball.rawValue
        cueBall.physicsBody?.collisionBitMask   = PhysicsCategory.ball.rawValue | PhysicsCategory.cushion.rawValue
        cueBall.physicsBody?.contactTestBitMask = PhysicsCategory.pocket.rawValue | PhysicsCategory.ball.rawValue
        dHighlight?.removeFromParent()
        dHighlight = nil
        foulFlag = false
        updateUI()
    }

    // Returns true if placing the cue ball at point would overlap any other ball
    private func overlapsAnyBall(_ point: CGPoint) -> Bool {
        let minDist = ballRadius * 2
        for (node, _) in balls where node !== cueBall {
            if hypot(point.x - node.position.x, point.y - node.position.y) < minDist {
                return true
            }
        }
        return false
    }

    // Returns the nearest valid point inside the D for a given location
    private func clampToD(_ point: CGPoint) -> CGPoint {
        let t = tableRect
        let baulkX  = t.minX + t.width * 0.22
        let dCenter = CGPoint(x: baulkX, y: t.midY)
        let dRadius = t.width * 0.083
        var p = CGPoint(x: min(point.x, baulkX), y: point.y)
        let dx = p.x - dCenter.x
        let dy = p.y - dCenter.y
        let dist = hypot(dx, dy)
        if dist > dRadius {
            p.x = dCenter.x + (dx / dist) * dRadius
            p.y = dCenter.y + (dy / dist) * dRadius
        }
        return p
    }

    private func respawnColour(_ type: BallType) {
        let t = tableRect
        let baulkX  = t.minX + t.width * 0.22
        let dOffset = t.width * 0.083
        let spots: [BallType: CGPoint] = [
            .yellow: CGPoint(x: baulkX, y: t.midY - dOffset),
            .green:  CGPoint(x: baulkX, y: t.midY + dOffset),
            .brown:  CGPoint(x: baulkX, y: t.midY),
            .blue:   CGPoint(x: t.midX,                        y: t.midY),
            .pink:   CGPoint(x: t.minX + t.width * 0.78 - ballRadius * 2,      y: t.midY),
            .black:  CGPoint(x: t.minX + t.width * 0.955,      y: t.midY),
        ]
        if let spot = spots[type] {
            let node = makeBall(type: type, at: spot)
            colouredBalls[type] = node
        }
    }

    // MARK: Shot completion

    override func didSimulatePhysics() {
        guard waitingForStop else { return }
        let moving = isBallMoving()
        if moving { ballsWereMoving = true; return }
        guard ballsWereMoving else { return }   // wait until balls have moved at least once
        waitingForStop  = false
        ballsWereMoving = false
        endOfShot()
    }

    private func endOfShot() {
        // Check "fail to hit nominated ball" — skip if cue ball was already potted (covered separately)
        if !cueBallPottedThisShot {
            if let hit = firstBallHit {
                if !isCorrectFirstBall(hit, phase: shotPhase, clearanceIndex: shotClearanceIndex) {
                    let pen = cueBallFoulPenalty(for: shotPhase, clearanceIndex: shotClearanceIndex)
                    gLog("FOUL — first ball hit was \(hit) but required \(requiredBallDescription(phase: shotPhase, clearanceIndex: shotClearanceIndex)) — penalty \(pen)", .warning)
                    recordFoul(penalty: pen)
                }
            } else {
                let pen = cueBallFoulPenalty(for: shotPhase, clearanceIndex: shotClearanceIndex)
                gLog("FOUL — cue ball hit nothing (required \(requiredBallDescription(phase: shotPhase, clearanceIndex: shotClearanceIndex))) — penalty \(pen)", .warning)
                recordFoul(penalty: pen)
            }
        }

        let turnSwitched: Bool
        if foulThisShot {
            // Award penalty to opponent and hand over turn
            let opponent = 1 - currentPlayer
            scores[opponent] += foulPenalty
            gLog("Turn end — FOUL: P\(opponent + 1) awarded \(foulPenalty)pt (score now \(scores[opponent])). Turn passes to P\(opponent + 1)")
            currentPlayer = opponent
            turnSwitched = true
        } else if !pottedThisShot {
            // Clean miss — switch player, clear foul display
            let next = 1 - currentPlayer
            gLog("Turn end — clean miss. Turn passes to P\(next + 1)")
            currentPlayer = next
            foulFlag = false
            turnSwitched = true
        } else {
            gLog("Turn end — pot(s) scored. P\(currentPlayer + 1) continues (score: \(scores[currentPlayer]))")
            turnSwitched = false
        }

        // Red–colour alternation is a within-break rule.
        // When the turn switches, the new player always starts on red
        // (as long as reds remain). Only redsAllGone clearance order persists.
        if turnSwitched && redsOnTable > 0 && phase != .needRed {
            gLog("Turn switched — phase reset to needRed for P\(currentPlayer + 1) (\(redsOnTable) reds remain)")
            phase = .needRed
        }

        let wasCueBallPotted  = cueBallPottedThisShot
        if foulThisShot { lastFoulPenalty = foulPenalty }
        pottedThisShot        = false
        foulThisShot          = false
        foulPenalty           = 0
        firstBallHit          = nil
        cueBallPottedThisShot = false
        updateUI()

        if wasCueBallPotted {
            // Respawn now — turn has already been switched to the correct player above.
            gLog("Respawning cue ball for P\(currentPlayer + 1) after foul")
            run(SKAction.sequence([
                SKAction.wait(forDuration: 0.4),
                SKAction.run { [weak self] in self?.respawnCueBall() }
            ]))
        } else if currentPlayer == 1 {
            scheduleAIShot()
        }
    }

    private func requiredBallDescription(phase p: TurnPhase? = nil, clearanceIndex idx: Int? = nil) -> String {
        let p = p ?? phase
        let i = idx ?? clearanceIndex
        switch p {
        case .needRed:    return "red"
        case .needColour: return "any colour"
        case .redsAllGone:
            return "\(clearanceOrder[min(i, clearanceOrder.count - 1)])"
        }
    }

    private func isCorrectFirstBall(_ type: BallType, phase p: TurnPhase? = nil, clearanceIndex idx: Int? = nil) -> Bool {
        let p = p ?? phase
        let i = idx ?? clearanceIndex
        switch p {
        case .needRed:
            return type == .red
        case .needColour:
            return type != .red
        case .redsAllGone:
            return type == clearanceOrder[min(i, clearanceOrder.count - 1)]
        }
    }

    // MARK: Helpers

    private func isBallMoving() -> Bool {
        for (node, _) in balls {
            let v = node.physicsBody?.velocity ?? .zero
            if abs(v.dx) > 2 || abs(v.dy) > 2 { return true }
        }
        return false
    }

    private func showWin() {
        let winner = scores[0] > scores[1] ? "P1" : (scores[1] > scores[0] ? "P2" : "Draw")
        gLog("FRAME OVER — \(winner) wins. Final scores: P1=\(scores[0]) P2=\(scores[1])")
        messageLabel.text = "Frame over! \(winner) wins"
        messageLabel.fontColor = NSColor(red: 0.3, green: 1.0, blue: 0.4, alpha: 1)
    }

    private func resetGame() {
        gLog("New game — resetting. Final scores before reset: P1=\(scores[0]) P2=\(scores[1])")
        removeAction(forKey: aiActionKey)
        for (node, _) in balls { node.removeFromParent() }
        balls.removeAll()
        colouredBalls.removeAll()
        cueBall = nil
        aimLine?.removeFromParent()
        aimLine = nil; aimCueLine = nil; aimGhostBall = nil; aimTargetLine = nil; aimPowerDot = nil
        dHighlight?.removeFromParent()
        dHighlight = nil
        isPlacingCueBall    = false
        isDraggingPlacement = false
        scores         = [0, 0]
        currentPlayer  = 0
        phase          = .needRed
        foulFlag       = false
        waitingForStop        = false
        ballsWereMoving       = false
        pottedThisShot        = false
        foulThisShot          = false
        foulPenalty           = 0
        firstBallHit          = nil
        cueBallPottedThisShot = false
        needsCueBallRespawn   = false
        lastFoulPenalty       = 0
        probabilityOverlays.forEach { $0.removeFromParent() }
        probabilityOverlays.removeAll()
        clearanceIndex = 0
        redsOnTable    = 0

        spawnBalls()
        updateUI()
        messageLabel.text = ""
        messageLabel.fontColor = NSColor.yellow
    }

    // MARK: AI Player

    private func aiPlaceCueBall() {
        let t       = tableRect
        let baulkX  = t.minX + t.width * 0.22
        let dCenter = CGPoint(x: baulkX, y: t.midY)
        let dRadius = t.width * 0.083

        // Hard mode: scan the full D arc and pick the position that gives the
        // highest-probability opening shot instead of always using D-centre.
        if aiDifficulty == .hard {
            let targets   = validAITargets()
            let obstacles = balls.keys.filter { $0 !== cueBall }.map { $0.position }
            var bestPos   = dCenter
            var bestProb: CGFloat = -1
            let steps = 24
            for i in 0...steps {
                let angle = CGFloat(i) * .pi / CGFloat(steps)
                let candidate = CGPoint(
                    x: dCenter.x - cos(angle) * dRadius * 0.9,
                    y: dCenter.y + sin(angle) * dRadius * 0.9
                )
                guard tableRect.contains(candidate), !overlapsAnyBall(candidate) else { continue }
                let prob = bestShotProbability(from: candidate, targets: targets, obstacles: obstacles)
                if prob > bestProb { bestProb = prob; bestPos = candidate }
            }
            gLog("AI (Hard) D-placement — best pos (\(String(format:"%.1f", bestPos.x)), \(String(format:"%.1f", bestPos.y))) prob \(String(format:"%.3f", bestProb))")
            cueBall.position = bestPos
            exitCueBallPlacement()
            scheduleAIShot()
            return
        }

        // Easy / Medium: try D-centre then sweep for any free spot.
        var placed = dCenter
        if overlapsAnyBall(placed) {
            var found = false
            let steps = 16
            for i in 0..<steps {
                let angle = Double(i) * Double.pi / Double(steps)
                let candidate = CGPoint(
                    x: dCenter.x - CGFloat(cos(angle)) * dRadius * 0.8,
                    y: dCenter.y + CGFloat(sin(angle)) * dRadius * 0.8
                )
                if !overlapsAnyBall(candidate) {
                    placed = candidate
                    found  = true
                    break
                }
            }
            if !found { placed = dCenter }
        }
        gLog("AI placing cue ball at (\(String(format:"%.1f", placed.x)), \(String(format:"%.1f", placed.y)))")
        cueBall.position = placed
        exitCueBallPlacement()
        scheduleAIShot()
    }

    private func scheduleAIShot() {
        guard currentPlayer == 1 else { return }
        gLog("AI shot scheduled in 1.0s (phase: \(phase))")
        run(SKAction.sequence([
            SKAction.wait(forDuration: 1.0),
            SKAction.run { [weak self] in self?.performAIShot() }
        ]), withKey: aiActionKey)
    }

    private func performAIShot() {
        guard let cue = cueBall, currentPlayer == 1, !isPlacingCueBall else { return }

        let impulse: CGVector
        let logDesc: String

        if aiDifficulty == .hard {
            // Hard mode: pick best pot; fall back to safety if nothing is on.
            guard let best = bestHardShot(cue: cue) else { return }

            // Near-zero execution error — easy shots are nearly perfect.
            let maxErr: CGFloat
            if best.isSafety {
                maxErr = 0.008   // slight variance so safety isn't robotic
            } else {
                switch best.probability {
                case 0.80...: maxErr = 0.000   // makeable pot — virtually perfect
                case 0.55..<0.80: maxErr = 0.003
                case 0.25..<0.55: maxErr = 0.010
                default:      maxErr = 0.018
                }
            }
            let error = CGFloat.random(in: -maxErr...maxErr)
            let angle = atan2(best.direction.dy, best.direction.dx) + error

            // Use position-calibrated force stored in the shot.
            let force = best.force * powerMultiplier
            impulse = CGVector(dx: cos(angle) * force, dy: sin(angle) * force)
            let shotKind = best.isSafety ? "SAFETY" : "pot"
            logDesc = "\(shotKind) target: \(best.targetType) at (\(String(format:"%.1f", best.target.position.x)), \(String(format:"%.1f", best.target.position.y))), prob: \(String(format:"%.2f", best.probability)), err: \(String(format:"%.4f", error)) rad, force: \(String(format:"%.0f", force))"
        } else {
            // Easy / Medium: simple nearest-ball + nearest-pocket logic.
            guard let target = findAITarget() else { return }
            let targetType = balls[target] ?? .red
            let pockets    = aiPocketPositions()
            var bestDir    = CGVector(dx: 1, dy: 0)
            var bestCost   = CGFloat.infinity
            for (pocketPos, _) in pockets {
                guard let contact = ghostBallContact(target: target.position, pocket: pocketPos) else { continue }
                let cdx = contact.x - cue.position.x
                let cdy = contact.y - cue.position.y
                let cd  = hypot(cdx, cdy)
                guard cd > 0 else { continue }
                if cd < bestCost {
                    bestCost = cd
                    bestDir  = CGVector(dx: cdx / cd, dy: cdy / cd)
                }
            }
            let maxErr = aiDifficulty.angleError
            let error  = CGFloat.random(in: -maxErr...maxErr)
            let angle  = atan2(bestDir.dy, bestDir.dx) + error
            let force: CGFloat = 120 * powerMultiplier
            impulse = CGVector(dx: cos(angle) * force, dy: sin(angle) * force)
            logDesc = "target: \(targetType) at (\(String(format:"%.1f", target.position.x)), \(String(format:"%.1f", target.position.y))), angle error: \(String(format:"%.3f", error)) rad"
        }

        gLog("AI shot (\(aiDifficulty.label)) — \(logDesc), impulse (dx:\(String(format:"%.1f", impulse.dx)) dy:\(String(format:"%.1f", impulse.dy)))")
        cue.physicsBody?.applyImpulse(impulse)

        waitingForStop        = true
        updateProbabilityOverlays()   // hide immediately — balls now in play
        ballsWereMoving       = false
        pottedThisShot        = false
        foulThisShot          = false
        foulPenalty           = 0
        firstBallHit          = nil
        cueBallPottedThisShot = false
        shotPhase             = phase
        shotClearanceIndex    = clearanceIndex
    }

    // MARK: Hard-mode shot selection

    private struct EvaluatedShot {
        let target:      SKShapeNode
        let targetType:  BallType
        let direction:   CGVector
        let probability: CGFloat
        let totalDist:   CGFloat   // cue-to-contact + target-to-pocket
        let leavePos:    CGPoint   // expected cue ball rest after contact
        let force:       CGFloat   // recommended impulse magnitude (pre-powerMultiplier)
        let isSafety:    Bool      // true = intentional safety, not a pot attempt
    }

    /// Returns all valid target nodes for the current phase.
    private func validAITargets() -> [(node: SKShapeNode, type: BallType)] {
        switch phase {
        case .needRed:
            return balls.filter { $0.value == .red }.map { ($0.key, $0.value) }
        case .needColour:
            return colouredBalls.map { ($0.value, $0.key) }
        case .redsAllGone:
            let required = clearanceOrder[min(clearanceIndex, clearanceOrder.count - 1)]
            if let node = colouredBalls[required] { return [(node, required)] }
            return []
        }
    }

    /// Scores one (target, pocket) combination.
    /// Returns the cue-ball direction and a probability in [0, 1].
    private func evaluateShot(cuePos: CGPoint,
                               target: SKShapeNode,
                               pocket: CGPoint,
                               pocketRadius: CGFloat,
                               obstacles: [CGPoint]) -> (direction: CGVector, probability: CGFloat) {
        let td = hypot(target.position.x - pocket.x, target.position.y - pocket.y)
        guard td > 0 else { return (.zero, 0) }

        guard let contact = ghostBallContact(target: target.position, pocket: pocket) else { return (.zero, 0) }
        // Reject geometrically impossible shots where the cue ball position would be off-table.
        guard tableRect.contains(contact) else { return (.zero, 0) }

        let cdx = contact.x - cuePos.x
        let cdy = contact.y - cuePos.y
        let cd  = hypot(cdx, cdy)
        guard cd > 0 else { return (.zero, 0) }

        let dir = CGVector(dx: cdx / cd, dy: cdy / cd)

        // Cut angle: between cue-travel direction and target→pocket direction.
        // cos⁴(θ) aggressively penalises cut shots: 0°=1.0, 30°≈0.56, 45°≈0.25, 60°≈0.06.
        let potDirX  = (pocket.x - target.position.x) / td
        let potDirY  = (pocket.y - target.position.y) / td
        let cutAngle = CGFloat(acos(max(-1, min(1, Double(dir.dx * potDirX + dir.dy * potDirY)))))
        let angleFactor = pow(max(0, CGFloat(cos(Double(cutAngle)))), 4)

        // Distance factor scaled by pocket size — larger corner pockets are more forgiving.
        let pocketScale = pocketRadius / cornerPocketRadius
        let distFactor  = exp(-(cd + td) / (AIConfig.distDecayBase * pocketScale))

        let cuePathFactor    = pathClearanceFactor(from: cuePos, to: contact, clearOf: obstacles)
        let targetPathFactor = pathClearanceFactor(from: target.position, to: pocket, clearOf: obstacles)
        let jawFactor        = middlePocketJawFactor(targetPos: target.position, pocket: pocket, td: td)

        return (dir, angleFactor * distFactor * cuePathFactor * targetPathFactor * jawFactor)
    }

    /// Evaluates all valid targets × all pockets and returns the best shot,
    /// using two-shot lookahead and position-calibrated force.
    /// Falls back to a safety shot when no pot has acceptable probability.
    private func bestHardShot(cue: SKShapeNode) -> EvaluatedShot? {
        let targets   = validAITargets()
        let pockets   = aiPocketPositions()
        let obstacles = balls.keys.filter { $0 !== cue }.map { $0.position }

        // Pre-compute which targets are valid for the *next* phase so the lookahead
        // can estimate second-shot probability from the expected cue-ball leave.
        let nextTargets: [(node: SKShapeNode, type: BallType)]
        switch phase {
        case .needRed:
            // After a red the AI must pot a colour — any colour currently on the table.
            nextTargets = colouredBalls.map { ($0.value, $0.key) }
        case .needColour:
            // After a colour the AI must pot a red.
            nextTargets = balls.filter { $0.value == .red }.map { ($0.key, $0.value) }
        case .redsAllGone:
            nextTargets = []   // deterministic clearance — lookahead not needed
        }

        var best: EvaluatedShot?
        var bestScore: CGFloat = 0

        for (node, type) in targets {
            let obs = obstaclesExcluding(obstacles, ballAt: node.position)
            for (pocketPos, pocketRadius) in pockets {
                let (dir, potProb) = evaluateShot(cuePos: cue.position,
                                                   target: node,
                                                   pocket: pocketPos,
                                                   pocketRadius: pocketRadius,
                                                   obstacles: obs)
                guard potProb > 0 else { continue }

                guard let ghost = ghostBallContact(target: node.position, pocket: pocketPos) else { continue }
                let cd = hypot(ghost.x - cue.position.x, ghost.y - cue.position.y)

                let leavePos = expectedCueBallLeave(
                    ghostPos: ghost, targetPos: node.position,
                    dirX: dir.dx, dirY: dir.dy, cueDistance: cd
                )

                let lookaheadProb = nextTargets.isEmpty ? 0 :
                    bestShotProbability(from: leavePos, targets: nextTargets, obstacles: obstacles)

                // In needColour phase prefer positions that set up reds (higher lookahead weight).
                let lw = phase == .needColour ? AIConfig.lookaheadWeightColour : AIConfig.lookaheadWeightRed
                let combinedScore = potProb * (1 - lw) + lookaheadProb * lw

                if combinedScore > bestScore {
                    bestScore = combinedScore

                    // Calibrate force so the cue ball rolls toward the next target after contact.
                    let td = hypot(node.position.x - pocketPos.x, node.position.y - pocketPos.y)
                    let nextTarget = nextTargets.min {
                        hypot($0.node.position.x - leavePos.x, $0.node.position.y - leavePos.y) <
                        hypot($1.node.position.x - leavePos.x, $1.node.position.y - leavePos.y)
                    }
                    let desiredRoll: CGFloat
                    if let nt = nextTarget {
                        let distToNext = hypot(nt.node.position.x - ghost.x, nt.node.position.y - ghost.y)
                        desiredRoll = max(AIConfig.minDesiredRoll, distToNext - AIConfig.targetLeaveBuffer)
                    } else {
                        desiredRoll = cd * 0.5
                    }
                    let force = 50 + 100 * min(1.0, (cd + td + desiredRoll) / AIConfig.forceCalibDist)

                    best = EvaluatedShot(target: node, targetType: type, direction: dir,
                                         probability: potProb, totalDist: cd + td,
                                         leavePos: leavePos, force: force, isSafety: false)
                }
            }
        }

        if (best?.probability ?? 0) < AIConfig.safetyThreshold {
            if let safeShot = bestSafetyShot(cue: cue) {
                gLog("AI (Hard) playing safety — best pot prob was \(String(format:"%.3f", best?.probability ?? 0))")
                return safeShot
            }
        }

        if let best {
            gLog("AI (Hard) best shot: \(best.targetType), pot \(String(format:"%.3f", best.probability)), score \(String(format:"%.3f", bestScore)), force \(String(format:"%.0f", best.force))", .debug)
        } else {
            gLog("AI (Hard) — no shot found", .warning)
        }
        return best
    }

    private func findAITarget() -> SKShapeNode? {
        let cuePos = cueBall?.position ?? tableRect.center
        switch phase {
        case .needRed:
            let reds = balls.filter { $0.value == .red }.map { $0.key }
            guard !reds.isEmpty else { return nil }
            if aiDifficulty.usesRandomTarget { return reds.randomElement() }
            return reds.min {
                hypot($0.position.x - cuePos.x, $0.position.y - cuePos.y) <
                hypot($1.position.x - cuePos.x, $1.position.y - cuePos.y)
            }
        case .needColour:
            if aiDifficulty.usesRandomTarget { return colouredBalls.values.randomElement() }
            for t in [BallType.black, .pink, .blue, .brown, .green, .yellow] {
                if let node = colouredBalls[t] { return node }
            }
            return nil
        case .redsAllGone:
            let required = clearanceOrder[min(clearanceIndex, clearanceOrder.count - 1)]
            return colouredBalls[required]
        }
    }

    /// Ghost-ball contact point: the cue ball centre position needed to send `target` toward `pocket`.
    private func ghostBallContact(target: CGPoint, pocket: CGPoint) -> CGPoint? {
        let tdx = target.x - pocket.x
        let tdy = target.y - pocket.y
        let td  = hypot(tdx, tdy)
        guard td > 0 else { return nil }
        return CGPoint(x: target.x + (tdx / td) * ballRadius * 2,
                       y: target.y + (tdy / td) * ballRadius * 2)
    }

    /// Filters `obstacles` to exclude any point within touching distance of `target`.
    private func obstaclesExcluding(_ obstacles: [CGPoint], ballAt target: CGPoint) -> [CGPoint] {
        obstacles.filter { hypot($0.x - target.x, $0.y - target.y) > ballRadius * 2 }
    }

    /// Returns a smooth clearance factor in [0.02, 1.0] for the straight path from `from` to `to`.
    /// 1.0 = fully unobstructed; degrades quadratically as obstacles encroach; floors at 0.02.
    private func pathClearanceFactor(from: CGPoint, to: CGPoint, clearOf obstacles: [CGPoint]) -> CGFloat {
        let dx   = to.x - from.x
        let dy   = to.y - from.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return 1.0 }
        let threshold2 = ballRadius * ballRadius * 4   // (2r)² — avoids sqrt in the inner loop

        var minDist2 = CGFloat.infinity
        for obs in obstacles {
            let fx = obs.x - from.x
            let fy = obs.y - from.y
            let t  = max(0, min(1, (fx * dx + fy * dy) / len2))
            let ex = from.x + t * dx - obs.x
            let ey = from.y + t * dy - obs.y
            let d2 = ex * ex + ey * ey
            if d2 < minDist2 { minDist2 = d2 }
        }
        guard minDist2 < threshold2 else { return 1.0 }
        let ratio = max(0, sqrt(minDist2) / (ballRadius * 2))   // single sqrt at the end
        return max(0.02, ratio * ratio)
    }

    /// Penalises shallow-angle approaches into middle pockets.
    /// Middle pockets (at midX on the long cushions) require the ball to arrive roughly
    /// perpendicular to the cushion; a near-parallel approach rattles the jaws.
    private func middlePocketJawFactor(targetPos: CGPoint, pocket: CGPoint, td: CGFloat) -> CGFloat {
        guard abs(pocket.x - tableRect.midX) < 2 else { return 1.0 }   // not a middle pocket
        // approachY is the y-component of the normalised target→pocket direction.
        // 1.0 = straight into the pocket, 0.0 = parallel to the cushion.
        let approachY = abs((pocket.y - targetPos.y) / td)
        return approachY * approachY   // quadratic: 45° approach → 0.5, very shallow → ~0
    }

    /// Estimates where the cue ball comes to rest after striking a target ball.
    /// Uses the natural-angle model: post-contact direction is perpendicular to the
    /// contact normal, and the ball rolls roughly half the pre-contact distance.
    private func expectedCueBallLeave(ghostPos: CGPoint,
                                       targetPos: CGPoint,
                                       dirX: CGFloat, dirY: CGFloat,
                                       cueDistance: CGFloat) -> CGPoint {
        let cnx = targetPos.x - ghostPos.x
        let cny = targetPos.y - ghostPos.y
        let cnLen = hypot(cnx, cny)
        guard cnLen > 0 else { return ghostPos }
        let nx = cnx / cnLen
        let ny = cny / cnLen

        // Remove component along contact normal — leaves only the lateral (deflected) component.
        let dot  = dirX * nx + dirY * ny
        let deflX = dirX - dot * nx
        let deflY = dirY - dot * ny
        let deflLen = hypot(deflX, deflY)
        // Straight shot (dot ≈ 1): cue ball stuns and stops near contact point.
        guard deflLen > 0.01 else { return ghostPos }

        // Post-contact roll ≈ 50 % of the pre-contact travel distance.
        let rollDist = cueDistance * 0.50
        let rawX = ghostPos.x + (deflX / deflLen) * rollDist
        let rawY = ghostPos.y + (deflY / deflLen) * rollDist
        return CGPoint(
            x: max(tableRect.minX + ballRadius, min(tableRect.maxX - ballRadius, rawX)),
            y: max(tableRect.minY + ballRadius, min(tableRect.maxY - ballRadius, rawY))
        )
    }

    /// Returns the highest pot probability achievable for any of `targets` from `cuePos`.
    private func bestShotProbability(from cuePos: CGPoint,
                                      targets: [(node: SKShapeNode, type: BallType)],
                                      obstacles: [CGPoint]) -> CGFloat {
        let pockets = aiPocketPositions()
        var best: CGFloat = 0
        for (node, _) in targets {
            let obs = obstaclesExcluding(obstacles, ballAt: node.position)
            for (pocketPos, pocketRadius) in pockets {
                let (_, p) = evaluateShot(cuePos: cuePos, target: node,
                                          pocket: pocketPos, pocketRadius: pocketRadius,
                                          obstacles: obs)
                if p > best { best = p }
            }
        }
        return best
    }

    /// Returns the best safety shot when no pot is on: finds a valid first contact that
    /// leaves the cue ball in a position minimising the opponent's follow-up probability.
    private func bestSafetyShot(cue: SKShapeNode) -> EvaluatedShot? {
        let targets      = validAITargets()
        let allObstacles = balls.keys.filter { $0 !== cue }.map { $0.position }

        var bestShot:        EvaluatedShot? = nil
        var bestSafetyScore: CGFloat        = -1

        for (node, type) in targets {
            let dxCT   = node.position.x - cue.position.x
            let dyCT   = node.position.y - cue.position.y
            let distCT = hypot(dxCT, dyCT)
            guard distCT > 0 else { continue }
            let dirX = dxCT / distCT
            let dirY = dyCT / distCT

            // Centre-ball ghost position for a direct hit.
            let ghost = CGPoint(x: node.position.x - dirX * ballRadius * 2,
                                y: node.position.y - dirY * ballRadius * 2)
            let obs   = obstaclesExcluding(allObstacles, ballAt: node.position)
            guard pathClearanceFactor(from: cue.position, to: ghost, clearOf: obs) > AIConfig.safetyPathThreshold
            else { continue }

            let cd       = hypot(ghost.x - cue.position.x, ghost.y - cue.position.y)
            let leavePos = expectedCueBallLeave(ghostPos: ghost, targetPos: node.position,
                                                dirX: dirX, dirY: dirY, cueDistance: cd * 0.3)

            let safetyScore = 1.0 - bestShotProbability(from: leavePos, targets: targets,
                                                         obstacles: allObstacles)
            if safetyScore > bestSafetyScore {
                bestSafetyScore = safetyScore
                let force = max(AIConfig.safetyForceMin, min(AIConfig.safetyForceMax, cd * 0.45))
                bestShot = EvaluatedShot(
                    target: node, targetType: type,
                    direction: CGVector(dx: dirX, dy: dirY),
                    probability: 0, totalDist: distCT,
                    leavePos: leavePos, force: force, isSafety: true
                )
            }
        }
        return bestShot
    }

    /// Returns the stored pocket positions and radii populated during setupPockets().
    private func aiPocketPositions() -> [(position: CGPoint, radius: CGFloat)] {
        return pocketData
    }
}

// MARK: - CGRect helper

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
