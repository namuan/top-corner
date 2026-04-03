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
    private let pocketRadius: CGFloat = 15

    // Nodes
    private var cueBall: SKShapeNode!
    private var balls:   [SKShapeNode: BallType] = [:]
    private var aimLine: SKShapeNode?

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
    // Snapshot of game state at the moment the cue ball is struck — used in
    // endOfShot() so that mid-shot phase changes don't affect foul evaluation.
    private var shotPhase:          TurnPhase = .needRed
    private var shotClearanceIndex: Int       = 0

    // Power
    private var powerMultiplier: CGFloat = 3   // 1–5, user-adjustable
    private var powerPips: [SKShapeNode] = []

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
        let pR = pocketRadius

        // Cushion rects (inset from baize edges, with gaps at pockets)
        let segments: [(CGRect, String)] = [
            // Bottom left half
            (CGRect(x: t.minX + pR,       y: t.minY,            width: t.width/2 - pR * 1.5, height: thickness), "bot-L"),
            // Bottom right half
            (CGRect(x: t.midX + pR * 0.5, y: t.minY,            width: t.width/2 - pR * 1.5, height: thickness), "bot-R"),
            // Top left half
            (CGRect(x: t.minX + pR,       y: t.maxY - thickness, width: t.width/2 - pR * 1.5, height: thickness), "top-L"),
            // Top right half
            (CGRect(x: t.midX + pR * 0.5, y: t.maxY - thickness, width: t.width/2 - pR * 1.5, height: thickness), "top-R"),
            // Left cushion
            (CGRect(x: t.minX,            y: t.minY + pR,       width: thickness, height: t.height - pR * 2), "left"),
            // Right cushion
            (CGRect(x: t.maxX - thickness, y: t.minY + pR,      width: thickness, height: t.height - pR * 2), "right"),
        ]

        for (rect, _) in segments {
            let node = SKShapeNode(rect: rect)
            node.fillColor   = NSColor(red: 0.07, green: 0.52, blue: 0.16, alpha: 1)
            node.strokeColor = .clear
            node.zPosition   = 2

            let body = SKPhysicsBody(edgeLoopFrom: rect)
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
        let pR = pocketRadius
        let positions: [CGPoint] = [
            CGPoint(x: t.minX,  y: t.minY),   // bottom-left
            CGPoint(x: t.midX,  y: t.minY),   // bottom-mid
            CGPoint(x: t.maxX,  y: t.minY),   // bottom-right
            CGPoint(x: t.minX,  y: t.maxY),   // top-left
            CGPoint(x: t.midX,  y: t.maxY),   // top-mid
            CGPoint(x: t.maxX,  y: t.maxY),   // top-right
        ]

        for pos in positions {
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

        // ── SCORE section (top) ───────────────────────────────────────
        addSideHeader("SCORE", y: 358)

        // Player 1 row
        player1Dot = SKShapeNode(circleOfRadius: 4)
        player1Dot.position  = CGPoint(x: sideInL + 4, y: 342)
        player1Dot.zPosition = 11
        addChild(player1Dot)
        let p1Lbl = SKLabelNode(text: "P1")
        p1Lbl.fontName  = "Helvetica Neue"
        p1Lbl.fontSize  = 11
        p1Lbl.fontColor = NSColor(white: 0.75, alpha: 1)
        p1Lbl.position  = CGPoint(x: sideInL + 16, y: 336)
        p1Lbl.horizontalAlignmentMode = .left
        p1Lbl.zPosition = 10
        addChild(p1Lbl)
        score1Label = SKLabelNode(fontNamed: "Helvetica Neue Bold")
        score1Label.fontSize  = 16
        score1Label.fontColor = .white
        score1Label.position  = CGPoint(x: sideInR, y: 336)
        score1Label.horizontalAlignmentMode = .right
        score1Label.zPosition = 10
        addChild(score1Label)

        // Player 2 row
        player2Dot = SKShapeNode(circleOfRadius: 4)
        player2Dot.position  = CGPoint(x: sideInL + 4, y: 318)
        player2Dot.zPosition = 11
        addChild(player2Dot)
        let p2Lbl = SKLabelNode(text: "P2")
        p2Lbl.fontName  = "Helvetica Neue"
        p2Lbl.fontSize  = 11
        p2Lbl.fontColor = NSColor(white: 0.75, alpha: 1)
        p2Lbl.position  = CGPoint(x: sideInL + 16, y: 312)
        p2Lbl.horizontalAlignmentMode = .left
        p2Lbl.zPosition = 10
        addChild(p2Lbl)
        score2Label = SKLabelNode(fontNamed: "Helvetica Neue Bold")
        score2Label.fontSize  = 16
        score2Label.fontColor = NSColor(white: 0.55, alpha: 1)
        score2Label.position  = CGPoint(x: sideInR, y: 312)
        score2Label.horizontalAlignmentMode = .right
        score2Label.zPosition = 10
        addChild(score2Label)

        addSideSeparator(y: 298)

        // ── NEXT BALL section ─────────────────────────────────────────
        addSideHeader("NEXT BALL", y: 276)
        nextBallIndicator = SKShapeNode(circleOfRadius: 16)
        nextBallIndicator.position    = CGPoint(x: sideCX, y: 242)
        nextBallIndicator.strokeColor = NSColor.white.withAlphaComponent(0.35)
        nextBallIndicator.lineWidth   = 1
        nextBallIndicator.zPosition   = 10
        addChild(nextBallIndicator)

        nextBallLabel = SKLabelNode(fontNamed: "Helvetica Neue")
        nextBallLabel.fontSize  = 11
        nextBallLabel.fontColor = NSColor(white: 0.75, alpha: 1)
        nextBallLabel.position  = CGPoint(x: sideCX, y: 216)
        nextBallLabel.horizontalAlignmentMode = .center
        nextBallLabel.zPosition = 10
        addChild(nextBallLabel)

        addSideSeparator(y: 204)

        // ── STATUS / MESSAGE ──────────────────────────────────────────
        messageLabel = SKLabelNode(fontNamed: "Helvetica Neue")
        messageLabel.fontSize  = 11
        messageLabel.fontColor = NSColor.yellow
        messageLabel.position  = CGPoint(x: sideCX, y: 188)
        messageLabel.horizontalAlignmentMode = .center
        messageLabel.zPosition = 10
        addChild(messageLabel)

        addSideSeparator(y: 176)

        // ── POWER section ─────────────────────────────────────────────
        addSideHeader("POWER", y: 164)

        // [–] button
        let minusBg = SKShapeNode(rect: CGRect(x: sideInL, y: 130, width: 26, height: 26), cornerRadius: 4)
        minusBg.fillColor   = NSColor(white: 0.25, alpha: 1)
        minusBg.strokeColor = NSColor(white: 0.40, alpha: 1)
        minusBg.lineWidth   = 0.5
        minusBg.zPosition   = 10
        minusBg.name        = "pwrMinus"
        addChild(minusBg)
        let minusLbl = SKLabelNode(text: "–")
        minusLbl.fontName  = "Helvetica Neue"
        minusLbl.fontSize  = 16
        minusLbl.fontColor = .white
        minusLbl.position  = CGPoint(x: sideInL + 13, y: 133)
        minusLbl.horizontalAlignmentMode = .center
        minusLbl.zPosition = 11
        minusLbl.name      = "pwrMinus"
        addChild(minusLbl)

        // [+] button
        let plusBg = SKShapeNode(rect: CGRect(x: sideInR - 26, y: 130, width: 26, height: 26), cornerRadius: 4)
        plusBg.fillColor   = NSColor(white: 0.25, alpha: 1)
        plusBg.strokeColor = NSColor(white: 0.40, alpha: 1)
        plusBg.lineWidth   = 0.5
        plusBg.zPosition   = 10
        plusBg.name        = "pwrPlus"
        addChild(plusBg)
        let plusLbl = SKLabelNode(text: "+")
        plusLbl.fontName  = "Helvetica Neue"
        plusLbl.fontSize  = 15
        plusLbl.fontColor = .white
        plusLbl.position  = CGPoint(x: sideInR - 13, y: 134)
        plusLbl.horizontalAlignmentMode = .center
        plusLbl.zPosition = 11
        plusLbl.name      = "pwrPlus"
        addChild(plusLbl)

        // Power number label
        powerLabel = SKLabelNode(fontNamed: "Helvetica Neue Bold")
        powerLabel.fontSize  = 15
        powerLabel.fontColor = .white
        powerLabel.position  = CGPoint(x: sideCX, y: 134)
        powerLabel.horizontalAlignmentMode = .center
        powerLabel.zPosition = 11
        addChild(powerLabel)

        // Power pip indicators
        powerPips = []
        let pipSpacing: CGFloat = 18
        let pipStartX = sideCX - pipSpacing * 2
        for i in 0..<5 {
            let pip = SKShapeNode(circleOfRadius: 5)
            pip.position  = CGPoint(x: pipStartX + CGFloat(i) * pipSpacing, y: 116)
            pip.lineWidth = 1
            pip.zPosition = 10
            addChild(pip)
            powerPips.append(pip)
        }
        updatePowerPips()

        addSideSeparator(y: 104)

        // ── RESET button ──────────────────────────────────────────────
        let resetBg = SKShapeNode(rect: CGRect(x: sideInL, y: 66, width: sideW, height: 30), cornerRadius: 5)
        resetBg.fillColor   = NSColor(white: 0.25, alpha: 1)
        resetBg.strokeColor = NSColor(white: 0.42, alpha: 1)
        resetBg.lineWidth   = 0.5
        resetBg.zPosition   = 10
        resetBg.name        = "resetBtn"
        addChild(resetBg)
        let resetLbl = SKLabelNode(text: "New Game")
        resetLbl.fontName   = "Helvetica Neue"
        resetLbl.fontSize   = 12
        resetLbl.fontColor  = .white
        resetLbl.position   = CGPoint(x: sideCX, y: 74)
        resetLbl.horizontalAlignmentMode = .center
        resetLbl.zPosition  = 11
        resetLbl.name       = "resetBtn"
        addChild(resetLbl)

        // ── QUIT button ───────────────────────────────────────────────
        let quitBg = SKShapeNode(rect: CGRect(x: sideInL, y: 26, width: sideW, height: 30), cornerRadius: 5)
        quitBg.fillColor   = NSColor(red: 0.45, green: 0.08, blue: 0.08, alpha: 1)
        quitBg.strokeColor = NSColor(red: 0.65, green: 0.18, blue: 0.18, alpha: 1)
        quitBg.lineWidth   = 0.5
        quitBg.zPosition   = 10
        quitBg.name        = "quitBtn"
        addChild(quitBg)
        let quitLbl = SKLabelNode(text: "Quit")
        quitLbl.fontName   = "Helvetica Neue"
        quitLbl.fontSize   = 12
        quitLbl.fontColor  = .white
        quitLbl.position   = CGPoint(x: sideCX, y: 34)
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
            nextBallIndicator.fillColor = BallType.black.color
            nextBallLabel.text = "Next: Colour"
        case .redsAllGone:
            let next = clearanceOrder[min(clearanceIndex, clearanceOrder.count - 1)]
            nextBallIndicator.fillColor = next.color
            nextBallLabel.text = "Next: \(next)".capitalized
        }

        if foulFlag {
            messageLabel.text = "FOUL! +\(foulPenalty) to P\(currentPlayer == 0 ? 2 : 1)"
            messageLabel.fontColor = NSColor.orange
        } else {
            messageLabel.text = ""
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
        aimLine = nil

        let loc  = event.location(in: self)
        let dx   = dragStart.x - loc.x
        let dy   = dragStart.y - loc.y
        let dist = hypot(dx, dy)
        guard dist > 4 else { return }

        let maxForce: CGFloat = 150 * powerMultiplier
        let scale = min(dist / 120, 1.0) * maxForce
        let impulse = CGVector(dx: (dx / dist) * scale, dy: (dy / dist) * scale)
        cue.physicsBody?.applyImpulse(impulse)

        gLog("P\(currentPlayer + 1) shot — power \(Int(powerMultiplier)), drag \(Int(dist))px, impulse (dx:\(String(format:"%.1f", impulse.dx)) dy:\(String(format:"%.1f", impulse.dy))), phase: \(phase)")

        waitingForStop        = true
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
    }

    private func drawAimLine(from start: CGPoint, to end: CGPoint) {
        aimLine?.removeFromParent()

        let dx = start.x - end.x
        let dy = start.y - end.y
        let dist = hypot(dx, dy)
        guard dist > 2, let cue = cueBall else { return }

        let maxLen: CGFloat = 160
        let ratio = min(dist, maxLen) / maxLen
        let lineEnd = CGPoint(
            x: cue.position.x + (dx / dist) * maxLen,
            y: cue.position.y + (dy / dist) * maxLen
        )

        let path = CGMutablePath()
        path.move(to: cue.position)
        path.addLine(to: lineEnd)

        let line = SKShapeNode(path: path)
        line.strokeColor = NSColor.white.withAlphaComponent(0.5 + ratio * 0.4)
        line.lineWidth   = 1.5
        line.lineCap     = .round
        line.zPosition   = 8
        line.name        = "aimLine"

        // Power dot
        let dot = SKShapeNode(circleOfRadius: 3 + ratio * 4)
        dot.position    = end
        dot.fillColor   = NSColor(red: 1, green: 0.5 - ratio * 0.5, blue: 0, alpha: 0.8)
        dot.strokeColor = .clear
        dot.zPosition   = 8
        line.addChild(dot)

        aimLine = line
        addChild(line)
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

        if foulThisShot {
            // Award penalty to opponent and hand over turn
            let opponent = 1 - currentPlayer
            scores[opponent] += foulPenalty
            gLog("Turn end — FOUL: P\(opponent + 1) awarded \(foulPenalty)pt (score now \(scores[opponent])). Turn passes to P\(opponent + 1)")
            currentPlayer = opponent
        } else if !pottedThisShot {
            // Clean miss — switch player, clear foul display
            let next = 1 - currentPlayer
            gLog("Turn end — clean miss. Turn passes to P\(next + 1)")
            currentPlayer = next
            foulFlag = false
        } else {
            gLog("Turn end — pot(s) scored. P\(currentPlayer + 1) continues (score: \(scores[currentPlayer]))")
        }
        // Clean pot → same player continues

        let wasCueBallPotted  = cueBallPottedThisShot
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
        aimLine = nil
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
        clearanceIndex = 0
        redsOnTable    = 0

        spawnBalls()
        updateUI()
        messageLabel.text = ""
        messageLabel.fontColor = NSColor.yellow
    }

    // MARK: AI Player

    private func aiPlaceCueBall() {
        let t = tableRect
        let baulkX  = t.minX + t.width * 0.22
        let dCenter = CGPoint(x: baulkX, y: t.midY)
        let dRadius = t.width * 0.083

        // Try D-centre then sweep around the semicircle for a free spot
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
        guard let target = findAITarget() else { return }

        let pockets = aiPocketPositions()

        // Ghost-ball: for each pocket find the contact point that pots the target,
        // then aim the cue ball at that contact point.  Pick the pocket with the
        // shortest cue-ball → contact path (simplest shot geometry).
        var bestDir  = CGVector(dx: 1, dy: 0)
        var bestCost = CGFloat.infinity

        for pocket in pockets {
            let tdx = target.position.x - pocket.x
            let tdy = target.position.y - pocket.y
            let td  = hypot(tdx, tdy)
            guard td > 0 else { continue }

            // Ghost contact point: on far side of target, 2r away from its centre
            let contact = CGPoint(
                x: target.position.x + (tdx / td) * ballRadius * 2,
                y: target.position.y + (tdy / td) * ballRadius * 2
            )

            let cdx = contact.x - cue.position.x
            let cdy = contact.y - cue.position.y
            let cd  = hypot(cdx, cdy)
            guard cd > 0 else { continue }

            // Cost: distance cue must travel to reach contact point
            if cd < bestCost {
                bestCost = cd
                bestDir  = CGVector(dx: cdx / cd, dy: cdy / cd)
            }
        }

        // Add a small random angular error so the AI isn't perfect
        let error = CGFloat.random(in: -0.09...0.09)
        let angle = atan2(bestDir.dy, bestDir.dx) + error
        let force: CGFloat = 120 * powerMultiplier
        let impulse = CGVector(dx: cos(angle) * force, dy: sin(angle) * force)
        let targetType = balls[target] ?? .red
        gLog("AI shot — target: \(targetType) at (\(String(format:"%.1f", target.position.x)), \(String(format:"%.1f", target.position.y))), angle error: \(String(format:"%.3f", error)) rad, impulse (dx:\(String(format:"%.1f", impulse.dx)) dy:\(String(format:"%.1f", impulse.dy)))")
        cue.physicsBody?.applyImpulse(impulse)

        waitingForStop        = true
        ballsWereMoving       = false
        pottedThisShot        = false
        foulThisShot          = false
        foulPenalty           = 0
        firstBallHit          = nil
        cueBallPottedThisShot = false
        shotPhase             = phase
        shotClearanceIndex    = clearanceIndex
    }

    private func findAITarget() -> SKShapeNode? {
        let cuePos = cueBall?.position ?? tableRect.center
        switch phase {
        case .needRed:
            // Nearest red ball
            return balls
                .filter { $0.value == .red }
                .min { hypot($0.key.position.x - cuePos.x, $0.key.position.y - cuePos.y) <
                       hypot($1.key.position.x - cuePos.x, $1.key.position.y - cuePos.y) }?
                .key
        case .needColour:
            // Prefer highest-value colour still on the table
            for t in [BallType.black, .pink, .blue, .brown, .green, .yellow] {
                if let node = colouredBalls[t] { return node }
            }
            return nil
        case .redsAllGone:
            let required = clearanceOrder[min(clearanceIndex, clearanceOrder.count - 1)]
            return colouredBalls[required]
        }
    }

    private func aiPocketPositions() -> [CGPoint] {
        let t = tableRect
        return [
            CGPoint(x: t.minX, y: t.minY),
            CGPoint(x: t.midX, y: t.minY),
            CGPoint(x: t.maxX, y: t.minY),
            CGPoint(x: t.minX, y: t.maxY),
            CGPoint(x: t.midX, y: t.maxY),
            CGPoint(x: t.maxX, y: t.maxY),
        ]
    }
}

// MARK: - CGRect helper

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
