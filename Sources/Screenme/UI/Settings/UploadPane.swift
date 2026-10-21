import SwiftUI

struct UploadPane: View {
    @AppStorage(Pref.s3Endpoint.name) private var endpoint = Pref.s3Endpoint.defaultValue
    @AppStorage(Pref.s3Region.name) private var region = Pref.s3Region.defaultValue
    @AppStorage(Pref.s3Bucket.name) private var bucket = Pref.s3Bucket.defaultValue
    @AppStorage(Pref.s3AccessKeyID.name) private var accessKeyID = Pref.s3AccessKeyID.defaultValue
    @AppStorage(Pref.s3PublicURL.name) private var publicURL = Pref.s3PublicURL.defaultValue
    @State private var secret = S3Keychain.read()
    /// What the Keychain holds, so leaving the field unchanged writes nothing.
    @State private var savedSecret = S3Keychain.read()
    @State private var secretError: String?
    @FocusState private var secretFocused: Bool
    @State private var testing = false
    @State private var result: (message: String, ok: Bool)?

    var body: some View {
        Form {
            Section {
                field("Endpoint URL", $endpoint, prompt: "https://<accountID>.r2.cloudflarestorage.com")
                field("Region", $region, prompt: "auto")
                field("Bucket", $bucket, prompt: "screenme")
                field("Access Key ID", $accessKeyID, prompt: "")
                LabeledContent("Secret Access Key") {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField("Secret Access Key", text: $secret, prompt: Text("Stored in the Keychain"))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 280)
                            .focused($secretFocused)
                            .onSubmit { saveSecret() }
                            .onChange(of: secretFocused) { _, focused in if !focused { saveSecret() } }
                        if let secretError {
                            Text(secretError).font(.caption).foregroundStyle(.red).frame(width: 280, alignment: .leading)
                        }
                    }
                }
                field("Public URL", $publicURL, prompt: "https://pub-xxxx.r2.dev")
                LabeledContent("Connection") {
                    HStack {
                        if let result {
                            Text(result.message).font(.callout).foregroundStyle(result.ok ? .green : .red)
                        }
                        Button("Test Connection") { test() }.disabled(testing)
                    }
                }
            } header: {
                Text("Upload & Copy Link")
            } footer: {
                Text("Uploads a capture to your own bucket and copies a public link. Free options: Cloudflare R2 (10 GB free) and Backblaze B2 (10 GB free). AWS S3 and any S3-compatible server work too. Each user brings their own bucket.")
            }

            Section("Setup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cloudflare R2").font(.callout.weight(.semibold))
                    Text("1. In the Cloudflare dashboard, create an R2 bucket.\n2. Open the bucket Settings and enable the Public Development URL (r2.dev), or connect a domain. That is the Public URL.\n3. R2 > Manage API Tokens: create a token with Object Read & Write on that bucket.\n4. Endpoint: https://<accountID>.r2.cloudflarestorage.com. Region: auto. Paste the Access Key ID and Secret Access Key here.")
                    Text("Backblaze B2").font(.callout.weight(.semibold))
                    Text("1. Create a bucket and set it to Public.\n2. Create an Application Key for that bucket.\n3. Endpoint: the bucket's S3 endpoint, e.g. https://s3.us-west-004.backblazeb2.com. Region: the part after s3., e.g. us-west-004.\n4. Public URL: https://f00X.backblazeb2.com/file/<bucket>, or the bucket's friendly URL.")
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onDisappear { saveSecret() }
    }

    /// The Keychain is written when the secret is submitted or the field loses focus, not on every keystroke.
    private func saveSecret() {
        guard secret != savedSecret else { return }
        do {
            try S3Keychain.write(secret)
            savedSecret = secret
            secretError = nil
        } catch {
            secretError = error.localizedDescription
        }
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 280)
        }
    }

    private func test() {
        // The button does not take focus, so a secret still being typed is saved here.
        saveSecret()
        guard secretError == nil else { return }
        guard let settings = UploadSettings.load() else {
            result = ("Fill in every field first", false)
            return
        }
        testing = true
        result = nil
        Task {
            do {
                try await S3Upload.test(settings: settings)
                result = ("Connected", true)
            } catch {
                result = (error.localizedDescription, false)
            }
            testing = false
        }
    }
}
