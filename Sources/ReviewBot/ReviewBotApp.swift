import SwiftUI

@main
struct ReviewBotApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.statusSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
