// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct TransferQueueView: View {
    @ObservedObject var queue: TransferQueue

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("Transfers")
                    .font(.callout.bold())
                Spacer()
                Button("Clear Finished") {
                    queue.clearFinished()
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queue.tasks) { task in
                        TransferRow(task: task)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(height: 130)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct TransferRow: View {
    @ObservedObject var task: TransferTask

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(color)

            Text(task.isMove ? "Move: \(task.name)" : task.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 220, alignment: .leading)

            progressView

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch task.state {
        case .completed: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }

    @ViewBuilder
    private var progressView: some View {
        switch task.state {
        case .running(let progress):
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 160)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 160, alignment: .leading)
            }
        case .queued:
            ProgressView(value: 0)
                .frame(width: 160)
        case .completed:
            ProgressView(value: 1)
                .frame(width: 160)
        case .failed:
            ProgressView(value: 0)
                .frame(width: 160)
        }
    }

    private var statusText: String {
        switch task.state {
        case .queued: return "Queued"
        case .running(let progress):
            if let progress { return "\(Int(progress * 100))%" }
            return "Working..."
        case .completed: return task.isMove ? "Moved" : "Done"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}
