import Foundation
import zlib

public enum Tombstone {
    public static let magic = "WEVAULT_TOMBSTONE_V1"
    public static let textFormat = "text"
    private static let maxDetectionBytes = 4 * 1024 * 1024

    public struct Payload: Sendable {
        public let data: Data
        public let format: String
    }

    public static func payload(for snapshot: ArchivedFileSnapshot, createdAt: Date) throws -> Payload? {
        let ext = snapshot.archivedFile.originalFilename.lowercased().split(separator: ".").last.map(String.init) ?? ""
        let text = tombstoneText(for: snapshot, createdAt: createdAt)
        switch ext {
        case "txt", "md", "csv", "json", "log", "sql":
            return Payload(data: Data(text.utf8), format: textFormat)
        case "pdf":
            return Payload(data: pdfData(text: text), format: "pdf")
        case "docx":
            return Payload(data: try docxData(text: text), format: "docx")
        case "pptx":
            return Payload(data: try pptxData(text: text), format: "pptx")
        case "xlsx":
            return Payload(data: try xlsxData(text: text), format: "xlsx")
        case "zip":
            return Payload(data: try zipData(entries: [ZipEntry(path: "\(magic).txt", data: Data(text.utf8))]), format: "zip")
        default:
            return nil
        }
    }

    public static func tombstoneText(for snapshot: ArchivedFileSnapshot, createdAt: Date) -> String {
        let placeholderURL = "https://wevault.example/archive/\(snapshot.binding.bindingID)"
        let body = """
        \(magic)
        这不是原文件。
        原文件已由 WeVault 归档到云端。
        请先在 WeVault 中恢复原件，再打开、转发或导出。
        直接从微信转发或导出此附件时，可能得到的是这个 WeVault 占位提示，不是原件。

        原文件名：\(snapshot.archivedFile.originalFilename)
        查看归档内容：\(placeholderURL)
        """
        return body
    }

    public static func isTombstone(_ url: URL) -> Bool {
        if (try? magicLine(at: url)) == magic {
            return true
        }
        guard let data = try? detectionData(at: url) else {
            return false
        }
        if data.range(of: Data(magic.utf8)) != nil {
            return true
        }
        return zipContainsMagic(data)
    }

    public static func magicLine(at url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 1024)
        guard !data.isEmpty else {
            return nil
        }
        let lineData: Data
        if let newline = data.firstIndex(of: 0x0A) {
            lineData = data[..<newline]
        } else {
            lineData = data
        }
        return String(data: lineData, encoding: .ascii)
    }

    private static func detectionData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return handle.readData(ofLength: maxDetectionBytes)
    }

    public static func validatePlaceholder(at url: URL, binding: ArchiveBinding) throws {
        guard binding.placeholderPath == url.path else {
            throw WeVaultError.fileSystem("Tombstone path does not match manifest placeholder path")
        }
        guard let expectedSHA = binding.placeholderSHA256 else {
            throw WeVaultError.fileSystem("Manifest is missing tombstone SHA-256")
        }
        let actualSHA = try sha256File(url)
        guard actualSHA == expectedSHA else {
            throw WeVaultError.fileSystem("Tombstone SHA-256 does not match manifest")
        }
        guard isTombstone(url) else {
            throw WeVaultError.fileSystem("Existing file is not a WeVault tombstone")
        }
    }

    private static func pdfData(text: String) -> Data {
        let escaped = pdfEscape(asciiFallback(text))
        let stream = """
        BT
        /F1 18 Tf
        72 760 Td
        22 TL
        (\(escaped)) Tj
        ET

        """
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
            "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
            "5 0 obj\n<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream\nendobj\n"
        ]
        var result = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for object in objects {
            offsets.append(result.count)
            result.append(Data(object.utf8))
        }
        let xrefOffset = result.count
        result.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            result.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        result.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return result
    }

    private static func docxData(text: String) throws -> Data {
        let paragraphs = xmlLines(text).map { "<w:p><w:r><w:t>\($0)</w:t></w:r></w:p>" }.joined()
        return try zipData(entries: [
            ZipEntry(path: "[Content_Types].xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
            """.utf8)),
            ZipEntry(path: "_rels/.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
            """.utf8)),
            ZipEntry(path: "word/document.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>
            """.utf8)),
            ZipEntry(path: "docProps/core.xml", data: coreProperties()),
            ZipEntry(path: "docProps/\(magic).txt", data: Data(magic.utf8)),
            ZipEntry(path: "docProps/app.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>WeVault</Application></Properties>
            """.utf8))
        ])
    }

    private static func pptxData(text: String) throws -> Data {
        let lines = xmlLines(text)
        let title = lines.dropFirst().first ?? magic
        let body = lines.enumerated().filter { $0.offset != 1 }.map { _, line in
            "<a:p><a:pPr marL=\"0\" indent=\"0\"/><a:r><a:rPr lang=\"zh-CN\" sz=\"2200\"/><a:t>\(line)</a:t></a:r><a:endParaRPr lang=\"zh-CN\" sz=\"2200\"/></a:p>"
        }.joined()
        return try zipData(entries: [
            ZipEntry(path: "[Content_Types].xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
            """.utf8)),
            ZipEntry(path: "_rels/.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
            """.utf8)),
            ZipEntry(path: "ppt/presentation.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/><p:defaultTextStyle><a:defPPr><a:defRPr lang="zh-CN"/></a:defPPr></p:defaultTextStyle></p:presentation>
            """.utf8)),
            ZipEntry(path: "ppt/_rels/presentation.xml.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>
            """.utf8)),
            ZipEntry(path: "ppt/slides/slide1.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="WeVault Tombstone Title"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="685800" y="457200"/><a:ext cx="10820400" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap="square" anchor="mid"><a:spAutoFit/></a:bodyPr><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="zh-CN" sz="4000" b="1"><a:solidFill><a:srgbClr val="C00000"/></a:solidFill></a:rPr><a:t>\(title)</a:t></a:r><a:endParaRPr lang="zh-CN" sz="4000"/></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="WeVault Tombstone Body"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="914400" y="1600200"/><a:ext cx="10363200" cy="4572000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="F7F7F7"/></a:solidFill><a:ln w="12700"><a:solidFill><a:srgbClr val="BFBFBF"/></a:solidFill></a:ln></p:spPr><p:txBody><a:bodyPr wrap="square" lIns="228600" tIns="171450" rIns="228600" bIns="171450"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(body)</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """.utf8)),
            ZipEntry(path: "ppt/slides/_rels/slide1.xml.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>
            """.utf8)),
            ZipEntry(path: "ppt/slideMasters/slideMaster1.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
            """.utf8)),
            ZipEntry(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
            """.utf8)),
            ZipEntry(path: "ppt/slideLayouts/slideLayout1.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
            """.utf8)),
            ZipEntry(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
            """.utf8)),
            ZipEntry(path: "ppt/theme/theme1.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="WeVault"><a:themeElements><a:clrScheme name="WeVault"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F1F1F"/></a:dk2><a:lt2><a:srgbClr val="F7F7F7"/></a:lt2><a:accent1><a:srgbClr val="C00000"/></a:accent1><a:accent2><a:srgbClr val="666666"/></a:accent2><a:accent3><a:srgbClr val="4472C4"/></a:accent3><a:accent4><a:srgbClr val="70AD47"/></a:accent4><a:accent5><a:srgbClr val="FFC000"/></a:accent5><a:accent6><a:srgbClr val="5B9BD5"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="WeVault"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface="Arial"/><a:cs typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface="Arial"/><a:cs typeface="Arial"/></a:minorFont></a:fontScheme><a:fmtScheme name="WeVault"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
            """.utf8)),
            ZipEntry(path: "docProps/core.xml", data: coreProperties()),
            ZipEntry(path: "docProps/\(magic).txt", data: Data(magic.utf8)),
            ZipEntry(path: "docProps/app.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>WeVault</Application><PresentationFormat>On-screen Show (16:9)</PresentationFormat><Slides>1</Slides></Properties>
            """.utf8))
        ])
    }

    private static func xlsxData(text: String) throws -> Data {
        let rows = xmlLines(text).enumerated().map { index, line in
            "<row r=\"\(index + 1)\"><c r=\"A\(index + 1)\" t=\"inlineStr\"><is><t>\(line)</t></is></c></row>"
        }.joined()
        return try zipData(entries: [
            ZipEntry(path: "[Content_Types].xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
            """.utf8)),
            ZipEntry(path: "_rels/.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
            """.utf8)),
            ZipEntry(path: "xl/workbook.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="WeVault Tombstone" sheetId="1" r:id="rId1"/></sheets></workbook>
            """.utf8)),
            ZipEntry(path: "xl/_rels/workbook.xml.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """.utf8)),
            ZipEntry(path: "xl/worksheets/sheet1.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rows)</sheetData></worksheet>
            """.utf8)),
            ZipEntry(path: "docProps/core.xml", data: coreProperties()),
            ZipEntry(path: "docProps/\(magic).txt", data: Data(magic.utf8)),
            ZipEntry(path: "docProps/app.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>WeVault</Application></Properties>
            """.utf8))
        ])
    }

    private static func coreProperties() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>WEVAULT_TOMBSTONE_V1</dc:title><dc:creator>WeVault</dc:creator></cp:coreProperties>
        """.utf8)
    }

    private static func xmlLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { xmlEscape(String($0)) }
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func asciiFallback(_ value: String) -> String {
        value
            .replacingOccurrences(of: "这不是原文件。", with: "THIS IS NOT THE ORIGINAL FILE.")
            .replacingOccurrences(of: "原文件已由 WeVault 归档到云端。", with: "The original file was archived to cloud storage by WeVault.")
            .replacingOccurrences(of: "请先在 WeVault 中恢复原件，再打开、转发或导出。", with: "Restore the original in WeVault before opening, forwarding, or exporting.")
            .replacingOccurrences(of: "直接从微信转发或导出此附件时，可能得到的是这个 WeVault 占位提示，不是原件。", with: "Forwarding/exporting from WeChat may send this placeholder, not the original.")
            .replacingOccurrences(of: "原文件名：", with: "Original filename: ")
            .replacingOccurrences(of: "查看归档内容：", with: "Archive page: ")
            .unicodeScalars.map { $0.isASCII ? Character($0) : "?" }
            .map(String.init)
            .joined()
    }

    private static func pdfEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "\n", with: ") Tj T* (")
    }
}

private struct ZipEntry {
    let path: String
    let data: Data
}

private func zipContainsMagic(_ data: Data) -> Bool {
    let magicData = Data(Tombstone.magic.utf8)
    var offset = 0
    while offset + 30 <= data.count {
        guard data.uint32LE(at: offset) == 0x04034b50 else {
            break
        }
        let flags = data.uint16LE(at: offset + 6)
        let method = data.uint16LE(at: offset + 8)
        let compressedSize = Int(data.uint32LE(at: offset + 18))
        let uncompressedSize = Int(data.uint32LE(at: offset + 22))
        let nameLength = Int(data.uint16LE(at: offset + 26))
        let extraLength = Int(data.uint16LE(at: offset + 28))
        let nameStart = offset + 30
        let contentStart = nameStart + nameLength + extraLength
        guard nameStart <= data.count, contentStart <= data.count else {
            return false
        }
        let nameData = data[nameStart..<min(nameStart + nameLength, data.count)]
        if nameData.range(of: magicData) != nil {
            return true
        }
        guard flags & 0x0008 == 0 else {
            return false
        }
        guard compressedSize >= 0, contentStart + compressedSize <= data.count else {
            return false
        }
        let content = data[contentStart..<contentStart + compressedSize]
        if method == 0 {
            if content.range(of: magicData) != nil {
                return true
            }
        } else if method == 8, compressedSize <= 1024 * 1024, uncompressedSize <= 4 * 1024 * 1024 {
            if let inflated = inflateRaw(content, expectedSize: uncompressedSize), inflated.range(of: magicData) != nil {
                return true
            }
        }
        offset = contentStart + compressedSize
    }
    return false
}

private func inflateRaw(_ data: Data.SubSequence, expectedSize: Int) -> Data? {
    var output = Data(count: max(expectedSize, 1))
    let outputCount = output.count
    var stream = z_stream()
    let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else {
        return nil
    }
    defer { inflateEnd(&stream) }

    var written: Int?
    data.withUnsafeBytes { inputBuffer in
        output.withUnsafeMutableBytes { outputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress,
                  let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(data.count)
            stream.next_out = outputBase
            stream.avail_out = uInt(outputCount)
            let status = inflate(&stream, Z_FINISH)
            guard status == Z_STREAM_END else {
                return
            }
            written = Int(stream.total_out)
        }
    }
    guard let written else {
        return nil
    }
    return Data(output.prefix(written))
}

private func zipData(entries: [ZipEntry]) throws -> Data {
    var result = Data()
    var central = Data()
    var offset: UInt32 = 0

    for entry in entries {
        let name = Data(entry.path.utf8)
        let crc = crc32(entry.data)
        let size = UInt32(entry.data.count)
        let localOffset = offset

        result.appendUInt32LE(0x04034b50)
        result.appendUInt16LE(20)
        result.appendUInt16LE(0)
        result.appendUInt16LE(0)
        result.appendUInt16LE(0)
        result.appendUInt16LE(0)
        result.appendUInt32LE(crc)
        result.appendUInt32LE(size)
        result.appendUInt32LE(size)
        result.appendUInt16LE(UInt16(name.count))
        result.appendUInt16LE(0)
        result.append(name)
        result.append(entry.data)

        central.appendUInt32LE(0x02014b50)
        central.appendUInt16LE(20)
        central.appendUInt16LE(20)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt32LE(crc)
        central.appendUInt32LE(size)
        central.appendUInt32LE(size)
        central.appendUInt16LE(UInt16(name.count))
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt16LE(0)
        central.appendUInt32LE(0)
        central.appendUInt32LE(localOffset)
        central.append(name)

        offset = UInt32(result.count)
    }

    let centralOffset = UInt32(result.count)
    result.append(central)
    result.appendUInt32LE(0x06054b50)
    result.appendUInt16LE(0)
    result.appendUInt16LE(0)
    result.appendUInt16LE(UInt16(entries.count))
    result.appendUInt16LE(UInt16(entries.count))
    result.appendUInt32LE(UInt32(central.count))
    result.appendUInt32LE(centralOffset)
    result.appendUInt16LE(0)
    return result
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb88320
            } else {
                crc >>= 1
            }
        }
    }
    return crc ^ 0xffffffff
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
