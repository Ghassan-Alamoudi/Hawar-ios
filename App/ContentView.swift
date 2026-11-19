import SwiftUI
import ReplayKit
#if canImport(Translation)
import Translation
#endif

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        v.showsMicrophoneButton = false
        // preferredExtension left empty on purpose: re-signing can change bundle IDs.
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

func diagnostics() -> String {
    var lines = ["App: \(Bundle.main.bundleIdentifier ?? "?")"]
    let fm = FileManager.default
    if let url = Bundle.main.builtInPlugInsURL,
       let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil), !items.isEmpty {
        for item in items {
            let b = Bundle(url: item)
            let ext = (b?.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPrincipalClass"] as? String ?? "-"
            lines.append("PlugIn: \(item.lastPathComponent) id=\(b?.bundleIdentifier ?? "?") class=\(ext)")
        }
    } else {
        lines.append("PlugIns: NONE (removed by signing?)")
    }
    lines.append("Supabase configured: \(!Config.supabaseURL.isEmpty)")
    lines.append("Build: \(Config.build)")
    return lines.joined(separator: "\n")
}

struct ContentView: View {
    @State private var input = "Okay, so how you want me to play this?"
    @State private var output = ""
    @State private var status = ""
    @State private var trConfig: TranslationSession.Configuration?

    var body: some View {
        NavigationStack {
            Form {
                Section("1) تجهيز الترجمة بدون نت (مرة وحدة)") {
                    Button("نزّل لغة العربية للترجمة") {
                        trConfig = TranslationSession.Configuration(
                            source: Locale.Language(identifier: "en"),
                            target: Locale.Language(identifier: "ar"))
                    }
                    if !status.isEmpty { Text(status).font(.footnote) }
                }

                Section("2) اختبار الشاشة") {
                    Button("أرسل جملة تجربة للشاشة") {
                        TVSender.send("تجربة من الآيفون ✅")
                        status = "انرسلت، شوف الشاشة"
                    }
                    Button("امسح الترجمة من الشاشة") { TVSender.send("") }
                }

                Section("3) اختبار الترجمة") {
                    TextField("جملة إنجليزية", text: $input)
                        .environment(\.layoutDirection, .leftToRight)
                    Button("ترجم وأرسل للشاشة") {
                        Task {
                            let ar = await Translator.shared.translate(input) ?? "ما قدرت أترجم"
                            output = ar
                            TVSender.send(ar, en: input)
                        }
                    }
                    if !output.isEmpty { Text(output) }
                }

                Section("4) ابدأ الترجمة") {
                    HStack {
                        Spacer()
                        BroadcastPicker().frame(width: 80, height: 80)
                        Spacer()
                    }
                    Text("اضغط الزر واختر Hawar ثم Start Broadcast. بعدها افتح PlayStation App على البث بالعرض وبملء الشاشة.")
                        .font(.footnote)
                }

                Section("تشخيص") {
                    Text(diagnostics()).font(.caption).environment(\.layoutDirection, .leftToRight)
                }

                Section("Google") {
                    Text(Config.googleKey.isEmpty
                         ? "مو مفعّل، الترجمة من Apple والقاموس"
                         : "المستخدم هذا الشهر: \(GoogleQuota.used()) / 480000 حرف")
                        .font(.footnote)
                }
            }
            .navigationTitle("حوار")
        }
        .translationTask(trConfig) { session in
            do {
                try await session.prepareTranslation()
                await MainActor.run { status = "✅ الترجمة بدون نت جاهزة" }
            } catch {
                await MainActor.run { status = "خطأ: \(error.localizedDescription)" }
            }
        }
    }
}
