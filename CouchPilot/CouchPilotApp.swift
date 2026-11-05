import SwiftUI

@main
struct CouchPilotApp: App {
    @StateObject private var model = ControllerModel()
    var body: some Scene {
        WindowGroup { ContentView(model: model).frame(minWidth: 950, minHeight: 700) }
    }
}
