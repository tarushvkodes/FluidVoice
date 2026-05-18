import SwiftUI

struct VoiceEngineSettingsView: View {
    enum DictationTab: String, CaseIterable, Identifiable {
        case voiceEngine
        case fillerWords

        var id: String { self.rawValue }

        var title: String {
            switch self {
            case .voiceEngine:
                return "Voice Engine"
            case .fillerWords:
                return "Remove Filler Words"
            }
        }
    }

    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject var settings: SettingsStore
    @State var isShowingNemotronLanguagePicker = false
    let theme: AppTheme
    @State var selectedTab: DictationTab = .voiceEngine

    var body: some View {
        self.speechRecognitionCard
            .onAppear { self.viewModel.onAppear() }
            .onChange(of: self.settings.selectedSpeechModel) { _, newValue in
                self.viewModel.handleSelectedSpeechModelChange(newValue)
            }
    }
}
