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
    private let tableRect   = CGRect(x: 40, y: 50, width: 480, height: 280)
    private let ballRadius:  CGFloat = 8
    private let pocketRadius: CGFloat = 12

    // Nodes
    private var cueBall: SKShapeNode!
    private var balls:   [SKShapeNode: BallType] = [:]
    private var aimLine: SKShapeNode?

    // Input
    private var isDragging    = false
    private var dragStart     = CGPoint.zero
    private var redsOnTable   = 0

    // Game state
    private var score         = 0
    private var phase: TurnPhase = .needRed
    private var lastRedPotted = false
    private var foulFlag      = false

    // Power
    private var powerMultiplier: CGFloat = 3   // 1–5, user-adjustable

    // UI
    private var scoreLabel:    SKLabelNode!
    private var messageLabel:  SKLabelNode!
    private var nextBallIndicator: SKShapeNode!
    private var nextBallLabel: SKLabelNode!
    private var powerLabel:    SKLabelNode!

    // Colours in clearance order
    private let clearanceOrder: [BallType] = [.yellow, .green, .brown, .blue, .pink, .black]
    private var clearanceIndex = 0
    private var colouredBalls: [BallType: SKShapeNode] = [:]

    // MARK: Scene lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
        physicsWorld.gravity   = .zero
        physicsWorld.contactDelegate = self

        setupTable()
        setupCushions()
        setupPockets()
        spawnBalls()
        setupUI()
    }

    // MARK: Table

    private func setupTable() {
        let baize = SKShapeNode(rect: tableRect, cornerRadius: 4)
        baize.fillColor   = NSColor(red: 0.04, green: 0.36, blue: 0.12, alpha: 1)
        baize.strokeColor = NSColor(red: 0.45, green: 0.25, blue: 0.05, alpha: 1)
        baize.lineWidth   = 8
        baize.zPosition   = 0
        addChild(baize)

        // Baulk line
        let baulkX = tableRect.minX + tableRect.width * 0.22
        let baulkLine = SKShapeNode()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: baulkX, y: tableRect.minY + 4))
        path.addLine(to: CGPoint(x: baulkX, y: tableRect.maxY - 4))
        baulkLine.path = path
        baulkLine.strokeColor = NSColor.white.withAlphaComponent(0.25)
        baulkLine.lineWidth = 1
        baulkLine.zPosition = 1
        addChild(baulkLine)

        // D semi-circle
        let dCenter = CGPoint(x: baulkX, y: tableRect.midY)
        let dRadius: CGFloat = 40
        let dPath = CGMutablePath()
        dPath.addArc(center: dCenter, radius: dRadius, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        let dArc = SKShapeNode(path: dPath)
        dArc.strokeColor = NSColor.white.withAlphaComponent(0.25)
        dArc.lineWidth = 1
        dArc.zPosition = 1
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
            node.fillColor   = NSColor(red: 0.45, green: 0.25, blue: 0.05, alpha: 1)
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
            pocket.fillColor   = NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
            pocket.strokeColor = NSColor(red: 0.20, green: 0.10, blue: 0.02, alpha: 1)
            pocket.lineWidth   = 2
            pocket.zPosition   = 3
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
        balls.removeAll()
        colouredBalls.removeAll()
        redsOnTable = 0
        clearanceIndex = 0

        // Coloured ball spots
        let t = tableRect
        let colourSpots: [(BallType, CGPoint)] = [
            (.yellow, CGPoint(x: t.minX + t.width * 0.22 - 20, y: t.midY)),
            (.green,  CGPoint(x: t.minX + t.width * 0.22 + 20, y: t.midY)),
            (.brown,  CGPoint(x: t.minX + t.width * 0.22,      y: t.midY)),
            (.blue,   CGPoint(x: t.midX,                        y: t.midY)),
            (.pink,   CGPoint(x: t.minX + t.width * 0.72,      y: t.midY)),
            (.black,  CGPoint(x: t.minX + t.width * 0.88,      y: t.midY)),
        ]

        for (type, spot) in colourSpots {
            let node = makeBall(type: type, at: spot)
            colouredBalls[type] = node
        }

        // Cue ball in D
        let cueBallPos = CGPoint(x: t.minX + t.width * 0.18, y: t.midY)
        cueBall = makeBall(type: .cue, at: cueBallPos)

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
        body.contactTestBitMask = PhysicsCategory.pocket.rawValue
        body.allowsRotation     = true
        node.physicsBody = body

        balls[node] = type
        addChild(node)

        if type == .red { redsOnTable += 1 }
        return node
    }

    // MARK: UI

    private func setupUI() {
        // Layout constants for the 560×50 bottom bar
        // Zone 1: Score  x=10..110  (left-anchored)
        // Zone 2: Message            (centered at x=195)
        // Zone 3: Next ball          (label right-edge at x=388, dot at x=398)
        // Zone 4: Buttons            (Reset x=414..471, Quit x=476..533)
        let btnY: CGFloat      = 13   // button rect bottom
        let btnH: CGFloat      = 24   // button height
        let textY: CGFloat     = 18   // label baseline (≈ vertical center of bar)

        // Score — Zone 1
        scoreLabel = SKLabelNode(fontNamed: "Helvetica Neue")
        scoreLabel.fontSize    = 13
        scoreLabel.fontColor   = .white
        scoreLabel.position    = CGPoint(x: 10, y: textY)
        scoreLabel.horizontalAlignmentMode = .left
        scoreLabel.zPosition   = 10
        addChild(scoreLabel)

        // Message — Zone 2
        messageLabel = SKLabelNode(fontNamed: "Helvetica Neue")
        messageLabel.fontSize  = 12
        messageLabel.fontColor = NSColor.yellow
        messageLabel.position  = CGPoint(x: 195, y: textY)
        messageLabel.horizontalAlignmentMode = .center
        messageLabel.zPosition = 10
        addChild(messageLabel)

        // Next ball — Zone 3: label then dot
        nextBallLabel = SKLabelNode(fontNamed: "Helvetica Neue")
        nextBallLabel.fontSize = 11
        nextBallLabel.fontColor = NSColor(white: 0.8, alpha: 1)
        nextBallLabel.position = CGPoint(x: 348, y: textY)
        nextBallLabel.horizontalAlignmentMode = .right
        nextBallLabel.zPosition = 10
        addChild(nextBallLabel)

        nextBallIndicator = SKShapeNode(circleOfRadius: 7)
        nextBallIndicator.position = CGPoint(x: 360, y: textY + 5)
        nextBallIndicator.strokeColor = NSColor.white.withAlphaComponent(0.4)
        nextBallIndicator.lineWidth = 0.5
        nextBallIndicator.zPosition = 10
        addChild(nextBallIndicator)

        // Reset button — Zone 4
        let resetBg = SKShapeNode(rect: CGRect(x: 376, y: btnY, width: 58, height: btnH), cornerRadius: 4)
        resetBg.fillColor   = NSColor(white: 0.28, alpha: 1)
        resetBg.strokeColor = NSColor(white: 0.45, alpha: 1)
        resetBg.lineWidth   = 0.5
        resetBg.zPosition   = 10
        resetBg.name        = "resetBtn"
        addChild(resetBg)

        let resetLabel = SKLabelNode(text: "Reset")
        resetLabel.fontName   = "Helvetica Neue"
        resetLabel.fontSize   = 11
        resetLabel.fontColor  = .white
        resetLabel.position   = CGPoint(x: 405, y: textY)
        resetLabel.horizontalAlignmentMode = .center
        resetLabel.zPosition  = 11
        resetLabel.name       = "resetBtn"
        addChild(resetLabel)

        // Quit button — Zone 4
        let quitBg = SKShapeNode(rect: CGRect(x: 441, y: btnY, width: 52, height: btnH), cornerRadius: 4)
        quitBg.fillColor   = NSColor(red: 0.50, green: 0.10, blue: 0.10, alpha: 1)
        quitBg.strokeColor = NSColor(red: 0.70, green: 0.20, blue: 0.20, alpha: 1)
        quitBg.lineWidth   = 0.5
        quitBg.zPosition   = 10
        quitBg.name        = "quitBtn"
        addChild(quitBg)

        let quitLabel = SKLabelNode(text: "Quit")
        quitLabel.fontName   = "Helvetica Neue"
        quitLabel.fontSize   = 11
        quitLabel.fontColor  = .white
        quitLabel.position   = CGPoint(x: 467, y: textY)
        quitLabel.horizontalAlignmentMode = .center
        quitLabel.zPosition  = 11
        quitLabel.name       = "quitBtn"
        addChild(quitLabel)

        // Power controls — Zone 5: [–] power [+]
        let pwrMinusBg = SKShapeNode(rect: CGRect(x: 500, y: btnY, width: 22, height: btnH), cornerRadius: 4)
        pwrMinusBg.fillColor   = NSColor(white: 0.28, alpha: 1)
        pwrMinusBg.strokeColor = NSColor(white: 0.45, alpha: 1)
        pwrMinusBg.lineWidth   = 0.5
        pwrMinusBg.zPosition   = 10
        pwrMinusBg.name        = "pwrMinus"
        addChild(pwrMinusBg)

        let pwrMinusLabel = SKLabelNode(text: "–")
        pwrMinusLabel.fontName  = "Helvetica Neue"
        pwrMinusLabel.fontSize  = 14
        pwrMinusLabel.fontColor = .white
        pwrMinusLabel.position  = CGPoint(x: 511, y: textY - 1)
        pwrMinusLabel.horizontalAlignmentMode = .center
        pwrMinusLabel.zPosition = 11
        pwrMinusLabel.name      = "pwrMinus"
        addChild(pwrMinusLabel)

        powerLabel = SKLabelNode(text: "Pwr:3")
        powerLabel.fontName   = "Helvetica Neue"
        powerLabel.fontSize   = 11
        powerLabel.fontColor  = NSColor(white: 0.85, alpha: 1)
        powerLabel.position   = CGPoint(x: 535, y: textY)
        powerLabel.horizontalAlignmentMode = .center
        powerLabel.zPosition  = 11
        addChild(powerLabel)

        let pwrPlusBg = SKShapeNode(rect: CGRect(x: 555, y: btnY, width: 22, height: btnH), cornerRadius: 4)
        pwrPlusBg.fillColor   = NSColor(white: 0.28, alpha: 1)
        pwrPlusBg.strokeColor = NSColor(white: 0.45, alpha: 1)
        pwrPlusBg.lineWidth   = 0.5
        pwrPlusBg.zPosition   = 10
        pwrPlusBg.name        = "pwrPlus"
        addChild(pwrPlusBg)

        let pwrPlusLabel = SKLabelNode(text: "+")
        pwrPlusLabel.fontName  = "Helvetica Neue"
        pwrPlusLabel.fontSize  = 13
        pwrPlusLabel.fontColor = .white
        pwrPlusLabel.position  = CGPoint(x: 566, y: textY)
        pwrPlusLabel.horizontalAlignmentMode = .center
        pwrPlusLabel.zPosition = 11
        pwrPlusLabel.name      = "pwrPlus"
        addChild(pwrPlusLabel)

        updateUI()
    }

    private func updateUI() {
        scoreLabel.text = "Score: \(score)"

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
            messageLabel.text = "FOUL!"
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

        // Only start drag if clicking near cue ball and balls are settled
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
        guard isDragging else { return }
        let loc = event.location(in: self)
        drawAimLine(from: dragStart, to: loc)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let cue = cueBall else { return }
        isDragging = false
        aimLine?.removeFromParent()
        aimLine = nil

        let loc  = event.location(in: self)
        let dx   = dragStart.x - loc.x
        let dy   = dragStart.y - loc.y
        let dist = hypot(dx, dy)
        guard dist > 4 else { return }

        let maxForce: CGFloat = 60 * powerMultiplier
        let scale = min(dist / 120, 1.0) * maxForce
        let impulse = CGVector(dx: (dx / dist) * scale, dy: (dy / dist) * scale)
        cue.physicsBody?.applyImpulse(impulse)
    }

    private func adjustPower(_ delta: CGFloat) {
        powerMultiplier = max(1, min(5, powerMultiplier + delta))
        powerLabel.text = "Pwr:\(Int(powerMultiplier))"
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
            // Cue ball potted — foul
            foulFlag = true
            score    = max(0, score - 4)
            run(SKAction.sequence([
                SKAction.wait(forDuration: 0.5),
                SKAction.run { [weak self] in self?.respawnCueBall() }
            ]))
            updateUI()
            return
        }

        switch phase {
        case .needRed:
            if type == .red {
                redsOnTable -= 1
                score += type.points
                phase = .needColour
            } else {
                // Foul — potted a colour when red required
                foulFlag = true
                score    = max(0, score - max(4, type.points))
                respawnColour(type)
            }

        case .needColour:
            if type != .red {
                score += type.points
                // Colour goes back unless reds all gone
                if redsOnTable > 0 {
                    respawnColour(type)
                }
                phase = redsOnTable > 0 ? .needRed : .redsAllGone
            } else {
                // Potted another red — allowed in some house rules; treat as valid
                redsOnTable -= 1
                score += type.points
            }

        case .redsAllGone:
            let required = clearanceOrder[clearanceIndex]
            if type == required {
                score += type.points
                clearanceIndex += 1
                if clearanceIndex >= clearanceOrder.count {
                    showWin()
                }
            } else {
                foulFlag = true
                score    = max(0, score - max(4, type.points))
                respawnColour(type)
            }
        }

        updateUI()
    }

    private func respawnCueBall() {
        let t = tableRect
        let pos = CGPoint(x: t.minX + t.width * 0.18, y: t.midY)
        cueBall = makeBall(type: .cue, at: pos)
    }

    private func respawnColour(_ type: BallType) {
        let t = tableRect
        let spots: [BallType: CGPoint] = [
            .yellow: CGPoint(x: t.minX + t.width * 0.22 - 20, y: t.midY),
            .green:  CGPoint(x: t.minX + t.width * 0.22 + 20, y: t.midY),
            .brown:  CGPoint(x: t.minX + t.width * 0.22,      y: t.midY),
            .blue:   CGPoint(x: t.midX,                        y: t.midY),
            .pink:   CGPoint(x: t.minX + t.width * 0.72,      y: t.midY),
            .black:  CGPoint(x: t.minX + t.width * 0.88,      y: t.midY),
        ]
        if let spot = spots[type] {
            let node = makeBall(type: type, at: spot)
            colouredBalls[type] = node
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
        messageLabel.text = "Frame Over!  Break: \(score)"
        messageLabel.fontColor = NSColor.green
    }

    private func resetGame() {
        for (node, _) in balls { node.removeFromParent() }
        balls.removeAll()
        colouredBalls.removeAll()
        cueBall = nil
        aimLine?.removeFromParent()
        aimLine = nil
        score         = 0
        phase         = .needRed
        foulFlag      = false
        clearanceIndex = 0
        redsOnTable   = 0

        spawnBalls()
        updateUI()
        messageLabel.text = ""
        messageLabel.fontColor = NSColor.yellow
    }
}
