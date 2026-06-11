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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.question)
                                .font(.headline)
                            Spacer()
                            Text(entry.ts, format: .dateTime.hour().minute().day().month())
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Text(PointParser.process(entry.answer).display)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(entry.provider)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.teal)
                    }
                    .padding(.vertical, 6)
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
