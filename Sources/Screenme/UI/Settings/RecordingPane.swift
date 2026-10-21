import AVFoundation
import SwiftUI

struct RecordingPane: View {
    @AppStorage(Pref.recordingMicrophone.name) private var microphoneOn = Pref.recordingMicrophone.defaultValue
    @AppStorage(Pref.recordingMicrophoneID.name) private var microphoneID = Pref.recordingMicrophoneID.defaultValue
    @AppStorage(Pref.recordingShowKeystrokes.name) private var keystrokes = Pref.recordingShowKeystrokes.defaultValue
    @AppStorage(Pref.recordingWebcam.name) private var webcam = Pref.recordingWebcam.defaultValue
    @AppStorage(Pref.recordingQuality.name) private var quality = Pref.recordingQuality.defaultValue
    @AppStorage(Pref.recordingFormat.name) private var format = Pref.recordingFormat.defaultValue
    @ObservedObject private var permissions = Permissions.shared
    @State private var devices: [AVCaptureDevice] = []

    var body: some View {
        Form {
            Section {
                PrefToggle("Show Quick Access", Pref.afterRecordingQuickAccess)
                PrefToggle("Copy file to clipboard", Pref.afterRecordingCopy)
                PrefToggle("Save to folder", Pref.afterRecordingSave)
                PrefToggle("Open in video editor", Pref.afterRecordingOpenEditor)
                PrefToggle("Create report for AI", Pref.afterRecordingAIReport,
                           detail: "Transcribes what you said and writes the report folder, as Report for AI does.")
                    .help("Create report for AI\nWhen a video recording stops, Screenme makes its Report for AI on its own: the keyframes, the contact sheet and a prompt, saved to your save folder and copied.")
                PrefToggle("Auto-crop frames", Pref.reportAutoCrop,
                           detail: "Reports of a screen or area recording cut each keyframe down to the window you were working in.")
                    .help("Auto-crop frames\nIn a Report for AI of a screen or area recording, each keyframe is cropped to the window where you clicked, drew or rested the pointer, so an agent reads it without searching the whole screen. The uncropped frames stay in frames-full.")
            } header: {
                Text("After recording")
            } footer: {
                Text("With Open in video editor on, the editor opens instead of Quick Access. GIFs have no editor and go to Quick Access. Reports are made for videos only.")
            }

            Section("Video") {
                Picker("Format", selection: $format) {
                    Text("Video (MP4)").tag(RecordingFormat.video)
                    Text("GIF").tag(RecordingFormat.gif)
                }
                .pickerStyle(.segmented)
                PrefIntPicker("Frame rate", Pref.recordingFPS, options: [("30 fps", 30), ("60 fps", 60)])
                Picker("Quality", selection: $quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }
                PrefToggle("Show cursor", Pref.recordingShowCursor)
                PrefToggle("Smooth cursor (render after recording)", Pref.recordingSmoothCursor,
                           detail: "Films the video without the cursor; the video editor draws a smooth one, which you can resize or hide.")
                    .help("Smooth cursor (render after recording)\nVideos are filmed without the cursor and Screenme records where it went. The video editor then draws a smooth cursor with click highlights. GIF recordings keep the filmed cursor.")
                PrefToggle("Highlight clicks", Pref.recordingHighlightClicks)
                Toggle("Show keystrokes", isOn: $keystrokes)
                if keystrokes && !permissions.isGranted(.accessibility) {
                    permissionHint("Keystrokes need Accessibility access.", .accessibility)
                }
                PrefIntPicker("Countdown", Pref.recordingCountdown, options: [("Off", 0), ("3 seconds", 3), ("5 seconds", 5), ("10 seconds", 10)])
                PrefToggle("Hide desktop icons while recording", Pref.recordingHideDesktopIcons)
                PrefToggle("Hide notifications", Pref.recordingHideNotifications, detail: "Banners stay on your screen but are left out of the video.")
            }

            Section("Audio and camera") {
                Toggle("Record microphone", isOn: $microphoneOn)
                if microphoneOn {
                    Picker("Microphone", selection: $microphoneID) {
                        Text("System default").tag("")
                        ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        if !microphoneID.isEmpty && !devices.contains(where: { $0.uniqueID == microphoneID }) {
                            Text("Unavailable device").tag(microphoneID)
                        }
                    }
                    if !permissions.isGranted(.microphone) {
                        permissionHint("Microphone access is off.", .microphone)
                    }
                }
                PrefToggle("Record system audio", Pref.recordingSystemAudio)
                Toggle("Show webcam", isOn: $webcam)
                if webcam && !permissions.isGranted(.camera) {
                    permissionHint("Camera access is off.", .camera)
                }
            }
        }
        .formStyle(.grouped)
        .polling(every: 2) {
            permissions.refresh()
            devices = InputDevices.microphones()
        }
    }

    private func permissionHint(_ text: String, _ permission: Permission) -> some View {
        HStack {
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            Spacer()
            Button(permission.requestTitle) { permission.request() }
        }
    }
}
