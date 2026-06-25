import Foundation
import SwiftUI

@MainActor
@Observable
final class AppLifecycleCoordinator {
    var scenePhase: ScenePhase = .active
}

