import AppKit
import SpriteKit

final class GameViewController: NSViewController {

    private var skView: SKView!

    override func loadView() {
        skView = SKView(frame: NSRect(x: 0, y: 0, width: 560, height: 380))
        skView.ignoresSiblingOrder = true
        skView.showsFPS = false
        skView.showsPhysics = false
        skView.showsNodeCount = false
        view = skView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        presentScene()
    }

    func presentScene() {
        let scene = SnookerScene(size: CGSize(width: 560, height: 380))
        scene.scaleMode = .aspectFit
        skView.presentScene(scene)
    }
}
