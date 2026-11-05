import Foundation
import GameController
let controllers = GCController.controllers()
print("GameController controllers: \(controllers.count)")
for c in controllers {
    print("name: \(c.vendorName ?? "unknown")")
    print("extendedGamepad: \(c.extendedGamepad != nil)")
    if let gamepad = c.extendedGamepad {
        print("buttonHome exposed: \(gamepad.buttonHome != nil)")
        if let home = gamepad.buttonHome { print("boundToSystemGesture: \(home.isBoundToSystemGesture)") }
    }
}
