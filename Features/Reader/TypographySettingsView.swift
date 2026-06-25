import SwiftUI

struct TypographySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ReaderPreferencesSnapshot
    let onChange: (ReaderPreferencesSnapshot) -> Void

    init(snapshot: ReaderPreferencesSnapshot, onChange: @escaping (ReaderPreferencesSnapshot) -> Void) {
        _snapshot = State(initialValue: snapshot)
        self.onChange = onChange
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("typography.theme", selection: $snapshot.theme) {
                    Text("typography.theme.day").tag(ReaderPreferencesSnapshot.Theme.day)
                    Text("typography.theme.sepia").tag(ReaderPreferencesSnapshot.Theme.sepia)
                    Text("护眼").tag(ReaderPreferencesSnapshot.Theme.eyeCare)
                    Text("typography.theme.night").tag(ReaderPreferencesSnapshot.Theme.night)
                }
                .pickerStyle(.segmented)
                Picker("typography.font", selection: $snapshot.font) {
                    Text("typography.font.publisher").tag(ReaderPreferencesSnapshot.FontChoice.publisher)
                    Text("typography.font.serif").tag(ReaderPreferencesSnapshot.FontChoice.serif)
                    Text("typography.font.sans").tag(ReaderPreferencesSnapshot.FontChoice.sansSerif)
                }
                StepLevelPicker(title: "typography.font_size", selection: $snapshot.fontSizeLevel)
                StepLevelPicker(title: "typography.line_height", selection: $snapshot.lineHeightLevel)
                StepLevelPicker(title: "typography.margins", selection: $snapshot.marginLevel)
                Button("typography.reset") {
                    snapshot = ReaderPreferencesSnapshot()
                    onChange(snapshot)
                }
            }
            .onChange(of: snapshot) { _, newValue in
                onChange(newValue)
            }
            .navigationTitle("reader.typography")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
    }
}

private struct StepLevelPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: ReaderPreferencesSnapshot.Level

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(ReaderPreferencesSnapshot.Level.allCases) { level in
                Text("\(level.rawValue)").tag(level)
            }
        }
        .pickerStyle(.segmented)
    }
}
