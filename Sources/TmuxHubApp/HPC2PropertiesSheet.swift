import SwiftUI

struct HPC2PropertiesSheet: View {
    @ObservedObject var model: HPC2PlatformModel

    var body: some View {
        HPC2StartSheet(
            initialProfile: model.profile,
            initialPreset: model.defaultPreset,
            mode: .properties
        ) { profile, preset in
            try model.saveConfiguration(profile: profile, preset: preset)
            return true
        }
    }
}
