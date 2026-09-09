import Foundation
import Testing
import WeVaultCore
@testable import WeVaultApp

struct FileDetailContextTests {
    private func file(_ name: String) -> FileRecord {
        FileRecord(path: "/fixture/\(name)", relativePath: name, objectType: .ordinaryFile,
            accountHash: "fixture", accountName: "fixture", filename: name, fileExtension: "txt",
            month: nil, sizeBytes: 10, allocatedBytes: 10, inode: 1, nlink: 1, mtime: Date(timeIntervalSince1970: 0))
    }

    @Test("changing filter or page preserves the open file, and returning refreshes its status")
    func preservesContentAcrossTableChanges() {
        let selected = file("selected.txt"), other = file("other.txt")
        var detail = FileDetailContext(file: selected, families: [], cloud: nil, archive: nil)
        for page in [[other, selected], [], [other], [selected, other]] {
            detail.refresh(files: page, families: [])
            #expect(detail.file == selected)
        }
        var refreshed = selected
        refreshed.status = .verified
        detail.refresh(files: [other, refreshed], families: [])
        #expect(detail.file.id == selected.id)
        #expect(detail.file.status == .verified)
    }
}
