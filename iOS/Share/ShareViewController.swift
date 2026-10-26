import HearthCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Or share from any app": a text, a link or an image goes into the App Group
/// for Hearth to read with Claude next time it opens. Nothing is read or added here.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(context: extensionContext))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

struct ShareView: View {
    enum Phase: Equatable {
        case saving
        case saved
        case failed(String)
    }

    let context: NSExtensionContext?
    @State private var phase = Phase.saving

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "flame").font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.ember)
            switch phase {
            case .saving:
                ProgressView()
                Text("Saving to Hearth…").font(.hBody).foregroundStyle(Theme.muted)
            case .saved:
                Text("Saved to Hearth").font(.hTitle).foregroundStyle(Theme.ink)
                Text("Open Hearth and tap + to have Claude read it. Nothing goes on a calendar until you say so.")
                    .font(.hBody).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            case .failed(let message):
                Text("Couldn't save it").font(.hCardTitle).foregroundStyle(Theme.ink)
                Text(message).font(.hMeta).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            Button("Done") { context?.completeRequest(returningItems: nil) }
                .buttonStyle(.pill(.primary))
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .task { await save() }
    }

    func save() async {
        let appGroup = Bundle.main.object(forInfoDictionaryKey: "HearthAppGroup") as? String
        let inbox = SharedInbox.inAppGroup(appGroup)
        let items = (context?.inputItems as? [NSExtensionItem]) ?? []
        let note = items.compactMap { $0.attributedContentText?.string }.first { !$0.isEmpty }
        var saved = 0
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            do {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let data = try await Self.data(from: provider, type: .image)
                    try inbox.put(SharedItem(kind: .image, createdAt: Date(), text: note), image: ImageShrinker.jpeg(data) ?? data)
                    saved += 1
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let data = try await Self.data(from: provider, type: .url)
                    let url = URL(dataRepresentation: data, relativeTo: nil)?.absoluteString ?? String(decoding: data, as: UTF8.self)
                    try inbox.put(SharedItem(kind: .url, createdAt: Date(), text: [note, url].compactMap { $0 }.joined(separator: "\n")))
                    saved += 1
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let data = try await Self.data(from: provider, type: .plainText)
                    try inbox.put(SharedItem(kind: .text, createdAt: Date(), text: String(decoding: data, as: UTF8.self)))
                    saved += 1
                }
            } catch {
                continue
            }
        }
        if saved == 0, let note {
            try? inbox.put(SharedItem(kind: .text, createdAt: Date(), text: note))
            saved = 1
        }
        phase = saved > 0 ? .saved : .failed("Hearth can read text, links and images.")
    }

    static func data(from provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
