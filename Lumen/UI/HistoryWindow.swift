import SwiftUI

/// Past conversations — every exchange with its answer, provider, and time.
/// Reads the durable conversation log; part of the auditability story:
/// what was asked, what came back, through which provider.
struct HistoryView: View {
    @State private var entries: [ConversationEntry] = []

    var body: some View {
        Group {
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No conversations yet")
                        .font(.headline)
                    Text("Hold ⌃⌥ and ask about your screen — exchanges land here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.question)
                                .font(.headline)
                            Spacer()
                            Text(entry.ts, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Text(PointParser.process(entry.answer).display)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                        Text(entry.provider)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.teal.opacity(0.15), in: Capsule())
                            .foregroundStyle(.teal)
                    }
                    .padding(.vertical, 8)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 460, minHeight: 380)
        .navigationTitle("Lumen — History")
        .toolbar {
            Button {
                entries = ConversationStore.shared.loadAll()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .onAppear {
            entries = ConversationStore.shared.loadAll()
        }
    }
}
