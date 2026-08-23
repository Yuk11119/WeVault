import SwiftUI
import WeVaultCore

struct SummaryGrid: View {
    let summary: ScanSummary

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            metric("普通文件", count: summary.ordinaryCount, bytes: summary.ordinaryBytes)
            metric("大文件候选", count: summary.largeOrdinaryCount, bytes: summary.largeOrdinaryBytes)
            metric("图片高清层候选", count: summary.imageHighCandidateCount, bytes: summary.imageHighCandidateBytes)
            metric("视频 Raw 层候选", count: summary.videoRawCandidateCount, bytes: summary.videoRawCandidateBytes)
            metric("发现 Raw 层", count: summary.videoRawDiscoveredCount, bytes: summary.videoRawDiscoveredBytes)
            metric("发现普通视频", count: summary.videoPlaybackDiscoveredCount, bytes: summary.videoPlaybackDiscoveredBytes)
            metric("重复可去重", count: nil, bytes: summary.duplicateReclaimableBytes)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ title: String, count: Int?, bytes: Int64) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let count {
                    Text("\(count)")
                        .monospacedDigit()
                }
                Text(humanBytes(bytes))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
