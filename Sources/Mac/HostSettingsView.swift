import SwiftUI

struct HostSettingsView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    Text(hostModel.permissions.screenCaptureGranted ? "Allowed" : "Needed")
                        .foregroundStyle(hostModel.permissions.screenCaptureGranted ? .green : .orange)
                }

                LabeledContent("Accessibility") {
                    Text(hostModel.permissions.accessibilityGranted ? "Allowed" : "Needed for input")
                        .foregroundStyle(hostModel.permissions.accessibilityGranted ? .green : .orange)
                }

                HStack {
                    Button("Open Screen Recording") {
                        hostModel.openScreenRecordingSettings()
                    }

                    Button("Open Accessibility") {
                        hostModel.openAccessibilitySettings()
                    }
                }
            }

            Section("Prototype") {
                LabeledContent("Transport") {
                    Text("Local snapshot")
                }

                LabeledContent("Next") {
                    Text("Live stream and input mapping")
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}
