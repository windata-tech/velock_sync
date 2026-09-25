import Foundation
import AVFoundation
import Vision
import AppKit
import CryptoKit

// Read-only video QC. Never serialize raw OCR, full frames, or sensitive input values.
// Only fixed UI labels and exact allowlisted static error-line crops may be persisted.
struct Hit: Codable {
    let label: String
    let confidence: Float
    let box: [Double] // Vision normalized bottom-left coordinates
}
struct Sample: Codable {
    let requested: Double
    let actual: Double
    let labels: [String]
    let hits: [Hit]
    let meanPixelDelta: Double?
    let changedPixelFraction: Double?
    let nearStill: Bool
    let observationCount: Int
    let recognized: Bool
}
struct Interval: Codable {
    let kind: String
    let start: Double
    let lastObserved: Double
    let nextSampleBoundary: Double
    let observedDuration: Double
    let labels: [String]
}
struct Report: Codable {
    let sourceName: String
    let duration: Double
    let step: Double
    let sha256Before: String
    let sha256After: String
    let sourceUnchanged: Bool
    let sampleCount: Int
    let ocrFailureCount: Int
    let status: String
    let notes: [String]
    let samples: [Sample]
    let intervals: [Interval]
}
func normalized(_ s: String) -> String {
    (s.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? s).lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
}
// Only fixed UI vocabulary is persisted. Unmatched OCR text stays transient in RAM.
let vocabulary = [
    "密码错误", "密码不正确", "密码输入错误", "密码不匹配", "主密码错误", "主密码不正确",
    "解锁失败", "解密失败", "验证失败", "认证失败", "连接失败", "恢复失败", "同步失败", "导入失败",
    "密码太短", "两次密码不一致", "密码不一致", "请重试", "请稍后再试", "尝试次数过多",
    "欢迎使用", "开始使用", "创建保险库", "创建密码库", "创建主密码", "设置主密码", "设置密码", "确认密码",
    "重复密码", "输入密码", "输入主密码", "请输入主密码", "主密码", "密码", "解锁", "解锁保险库",
    "解锁密码库", "忘记密码", "新设备", "恢复", "恢复数据", "恢复保险库", "恢复密码库", "从云端恢复",
    "WebDAV", "Velock", "Velock Sync", "同步", "同步设置", "同步方案", "新建同步方案", "添加同步方案",
    "立即同步", "开始同步", "同步中", "正在同步", "同步完成", "同步成功", "上次同步", "同步记录",
    "连接", "测试连接", "连接成功", "服务器地址", "用户名", "账号", "授权", "允许", "继续", "下一步",
    "完成", "确定", "取消", "保存", "创建", "返回", "导入", "导出", "设置", "凭证", "账户", "账号密码",
    "全部", "所有凭证", "添加凭证", "添加账户", "添加账号", "暂无数据", "暂无凭证", "没有凭证", "密码库",
    "连接Velock", "打开Velock", "本地文件夹", "远程文件夹", "选择文件夹", "双向同步", "单向同步",
    "上传", "下载", "正在下载", "正在上传", "扫描", "正在扫描", "加载中", "正在加载", "恢复完成", "恢复成功",
    "数据集", "同步内容", "同步方向", "加密", "端到端加密", "启用同步", "备份", "解密", "验证密码",
    "密码错误，请重试", "密码错误，请重新输入", "主密码错误，请重试", "输入的密码不正确",
    "Password incorrect", "Incorrect password", "Wrong password", "Invalid password", "Unlock failed"
]
let canonical = Dictionary((vocabulary + ["密码不能为空", "密码为空", "欢迎回来", "请输入密码", "新建空间", "恢复空间", "授权同步", "备份 Velock", "创建同步方案", "允许同步", "授权并返回"]).map { (normalized($0), $0) }, uniquingKeysWith: { a, _ in a })
let errorVocabulary = ["操作失败", "Operation failed", "PathNotFoundException", "Password cannot be null", "Authentication failed", "Authorization failed", "Sync failed", "Connection test failed", "不能为空", "口令错误", "密码验证错误", "password cannot be empty", "password is required", "密码不能为空", "密码为空", "密码有误", "密码不对", "请输入有效密码", "密码长度不足", "密码至少", "密码格式错误"] + Array(vocabulary.prefix(20)) + ["Password incorrect", "Incorrect password", "Wrong password", "Invalid password", "Unlock failed"]
let errorKeys = Set(errorVocabulary.map(normalized))
func safeLabels(_ text: String) -> [String] {
    let n = normalized(text)
    if let exact = canonical[n] { return [exact] }
    // Error text can be accompanied by dynamic counters. Emit the fixed error label only.
    let errors = errorVocabulary.filter { n.contains(normalized($0)) }
    let topics = ["欢迎", "请输入密码", "新建空间", "恢复空间", "新建", "恢复", "空间", "授权", "同步", "备份", "创建", "WebDAV", "文件夹", "连接", "添加", "凭证", "扫码", "二维码", "权限", "只读", "允许", "返回", "解锁", "扫描", "加载", "错误", "失败", "成功", "完成", "口令", "密钥"]
    return (errors + topics.filter { n.contains(normalized($0)) }.map { "主题:" + $0 }).sorted()
}
func isError(_ label: String) -> Bool {
    errorKeys.contains(normalized(label)) || normalized(label).contains("密码错误") || normalized(label).contains("密码不正确")
}
func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func fingerprint(_ image: CGImage) -> [UInt8] {
    let w = 96, h = 192
    var pixels = [UInt8](repeating: 0, count: w*h)
    pixels.withUnsafeMutableBytes { ptr in
        let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    // Ignore top 8% status bar and bottom 4% home indicator; keyboard remains included.
    return Array(pixels[(w*16)..<(w*184)])
}
func delta(_ a: [UInt8], _ b: [UInt8]) -> (Double, Double) {
    var sum = 0, changed = 0
    for (x, y) in zip(a,b) { let d = abs(Int(x)-Int(y)); sum += d; if d > 12 { changed += 1 } }
    return (Double(sum)/Double(a.count)/255, Double(changed)/Double(a.count))
}
func timeLabel(_ s: Double) -> String {
    String(format: "%02d:%05.2f", Int(s)/60, s.truncatingRemainder(dividingBy: 60))
}
func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}
// Evidence is a privacy-safe OCR-layout rendering, NOT an unredacted screenshot.
// No source pixels are copied into layouts. Separate error-line crops contain only exact fixed error UI text.
func writeEvidence(_ sample: Sample, size: CGSize, to url: URL) throws {
    let w = 600, h = Int(600*size.height/size.width)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    NSColor(white: 0.94, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
    NSString(string: "OCR-only / values omitted / t=\(timeLabel(sample.actual))").draw(at: NSPoint(x: 8, y: h-24), withAttributes: attrs)
    for hit in sample.hits {
        let box = NSRect(x: hit.box[0]*Double(w), y: hit.box[1]*Double(h), width: max(80, hit.box[2]*Double(w)), height: max(18, hit.box[3]*Double(h)))
        (isError(hit.label) ? NSColor.systemRed.withAlphaComponent(0.18) : NSColor.white).setFill(); box.fill()
        var a = attrs; a[.foregroundColor] = isError(hit.label) ? NSColor.systemRed : NSColor.black
        NSString(string: hit.label).draw(in: box, withAttributes: a)
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
}
func makeIntervals(_ samples: [Sample], duration: Double, step: Double, minDwell: Double) -> [Interval] {
    var result: [Interval] = []
    func add(_ kind: String, _ a: Int, _ b: Int, _ labels: [String]) {
        let start = samples[a].requested, last = samples[b].requested
        result.append(Interval(kind: kind, start: start, lastObserved: last,
            nextSampleBoundary: b+1 < samples.count ? samples[b+1].requested : duration,
            observedDuration: last-start, labels: labels))
    }
    for label in Set(samples.flatMap { $0.labels.filter(isError) }).sorted() {
        var begin: Int?
        for i in 0...samples.count {
            let present = i < samples.count && samples[i].labels.contains(label)
            if present && begin == nil { begin = i }
            if !present, let a = begin { add("error_observed", a, i-1, [label]); begin = nil }
        }
    }
    var stillStart: Int?
    for i in 1...samples.count {
        let still = i < samples.count && samples[i].nearStill
        if still && stillStart == nil { stillStart = i-1 }
        if !still, let a = stillStart {
            if samples[i-1].requested-samples[a].requested >= minDwell { add("near_static_review", a, i-1, samples[a].labels) }
            stillStart = nil
        }
    }
    var a = 0
    for i in 1...samples.count {
        if i == samples.count || samples[i].labels != samples[a].labels || !samples[i].recognized {
            if samples[a].recognized && !samples[a].labels.isEmpty && samples[i-1].requested-samples[a].requested >= minDwell {
                add("same_labels_review", a, i-1, samples[a].labels)
            }
            a = i
        }
    }
    return result.sorted { $0.start == $1.start ? $0.kind < $1.kind : $0.start < $1.start }
}
func fail(_ message: String, code: Int32 = 2) -> Never { fputs(message + "\n", stderr); exit(code) }
let args = CommandLine.arguments
if args.count == 2 && args[1] == "--self-test" {
    assert(safeLabels("密码不能为空").contains("密码不能为空"))
    assert(isError("密码不能为空"))
    assert(isError("不能为空"))
    assert(safeLabels("该字段不能为空").contains("不能为空"))
    assert(safeLabels("密碼錯誤").contains("密码错误"))
    assert(!isError("创建保险库"))
    assert(!isError("欢迎使用"))
    assert(safeLabels("arbitrary_private_value").isEmpty)
    assert(safeLabels("服务器地址：arbitrary_private_value").isEmpty)
    assert(safeLabels("密码错误，请重试").contains("密码错误，请重试"))
    assert(safeLabels("输入的密码不正确，请重试（3）").contains("密码不正确"))
    assert(delta([0,0], [0,0]).0 == 0)
    let s = (0...10).map { Sample(requested: Double($0), actual: Double($0), labels: $0 < 3 ? ["密码错误"] : ["恢复"], hits: [], meanPixelDelta: 0, changedPixelFraction: 0, nearStill: $0 > 0, observationCount: 1, recognized: true) }
    let spans = makeIntervals(s, duration: 11, step: 1, minDwell: 6)
    assert(spans.contains { $0.kind == "error_observed" && $0.start == 0 && $0.lastObserved == 2 })
    assert(spans.contains { $0.kind == "near_static_review" && $0.observedDuration == 10 })
    let repeated = (0...8).map { Sample(requested: Double($0), actual: 0, labels: ["恢复"], hits: [], meanPixelDelta: 0, changedPixelFraction: 0, nearStill: $0 > 0, observationCount: 1, recognized: true) }
    assert(makeIntervals(repeated, duration: 9, step: 1, minDwell: 6).contains { $0.kind == "near_static_review" && $0.observedDuration == 8 })
    print("SELF_TEST_PASS"); exit(0)
}
guard args.count >= 3 else { fail("Usage: video-qc INPUT.mp4 NEW_OUTPUT_DIR [step=1 (0.1...2)] [minDwell=6] [start=0] [end=duration]") }
let input = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
let output = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
let step = args.count > 3 ? Double(args[3]) ?? -1 : 1
let minDwell = args.count > 4 ? Double(args[4]) ?? -1 : 6
let start = args.count > 5 ? Double(args[5]) ?? -1 : 0
guard (0.1...2).contains(step), minDwell.isFinite, minDwell > 0, start.isFinite, start >= 0 else { fail("Invalid numeric options") }
guard input.path != output.path, !FileManager.default.fileExists(atPath: output.path) else { fail("Output must be a NEW directory; existing artifacts will not be overwritten") }
do {
    let before = try hashFile(input)
    let asset = AVURLAsset(url: input)
    let duration = try await asset.load(.duration).seconds
    let end = args.count > 6 ? Double(args[6]) ?? -1 : duration
    guard duration.isFinite, end > start, end <= duration, start < duration else { fail("Invalid time range") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let evidence = output.appendingPathComponent("safe-evidence")
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: 900, height: 1800)
    var samples: [Sample] = [], previous: [UInt8]?, failures = 0
    var lastPTS: Double?, cachedSample: Sample?
    let timestamps = Array(stride(from: start, to: end, by: step))
    for (index, t) in timestamps.enumerated() {
        let frame = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 60000))
        let sample: Sample = autoreleasepool {
            if lastPTS == frame.actualTime.seconds, let old = cachedSample {
                return Sample(requested: t, actual: frame.actualTime.seconds, labels: old.labels, hits: old.hits,
                    meanPixelDelta: 0, changedPixelFraction: 0, nearStill: true,
                    observationCount: old.observationCount, recognized: old.recognized)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.007
            var hits: [Hit] = [], recognized = true
            do { try VNImageRequestHandler(cgImage: frame.image).perform([request]) }
            catch { recognized = false; failures += 1 } // Never echo framework errors that could contain text.
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let box = observation.boundingBox
                // Export only an exact allowlisted error-line crop; never an input field or full frame.
                if errorKeys.contains(normalized(candidate.string)), box.minY > 0.05, box.maxY < 0.95,
                   candidate.confidence >= 0.5 {
                    let r = CGRect(x: floor(box.minX * Double(frame.image.width)),
                        y: floor((1-box.maxY) * Double(frame.image.height)),
                        width: ceil(box.width * Double(frame.image.width)), height: ceil(box.height * Double(frame.image.height)))
                    if let crop = frame.image.cropping(to: r),
                       let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
                        try? png.write(to: evidence.appendingPathComponent(String(format: "error-line-%07.2f.png", t)), options: .atomic)
                    }
                }
                for label in safeLabels(candidate.string) {
                    hits.append(Hit(label: label, confidence: candidate.confidence, box: [box.minX,box.minY,box.width,box.height]))
                }
            }
            let current = fingerprint(frame.image)
            let d = previous.map { delta($0, current) }; previous = current
            return Sample(requested: t, actual: frame.actualTime.seconds,
                labels: Array(Set(hits.map(\.label))).sorted(), hits: hits,
                meanPixelDelta: d?.0, changedPixelFraction: d?.1,
                nearStill: d.map { $0.0 < 0.004 && $0.1 < 0.015 } ?? false,
                observationCount: request.results?.count ?? 0, recognized: recognized)
        }
        samples.append(sample)
        lastPTS = frame.actualTime.seconds; cachedSample = sample
        if sample.labels.contains(where: isError) || index % 10 == 0 {
            try writeEvidence(sample, size: CGSize(width: frame.image.width, height: frame.image.height),
                to: evidence.appendingPathComponent(String(format: "ocr-layout-%07.2f.png", t)))
        }
        if index % 20 == 0 { print("QC \(input.lastPathComponent) \(timeLabel(t)) / \(timeLabel(duration)) labels=\(sample.labels.joined(separator: "|"))") }
    }
    let after = try hashFile(input)
    let intervals = makeIntervals(samples, duration: end, step: step, minDwell: minDwell)
    let hasErrors = intervals.contains { $0.kind == "error_observed" }
    let status = before != after || failures > 0 ? "INCOMPLETE" : hasErrors ? "FAIL_ERROR_UI" : intervals.isEmpty ? "NO_FLAGS_NOT_A_GUARANTEED_PASS" : "REVIEW_DWELL"
    let report = Report(sourceName: input.lastPathComponent, duration: duration, step: step,
        sha256Before: before, sha256After: after, sourceUnchanged: before == after,
        sampleCount: samples.count, ocrFailureCount: failures, status: status,
        notes: ["Raw OCR and full source frames are never saved. Fixed UI labels and exact allowlisted error-line crops only.",
                "near_static_review means little visual change, not proof of an application hang.",
                "same_labels_review may include input edits or animation; only allowlisted text is compared.",
                "Error intervals are first/last positive sample observations, NOT the exact toast lifetime or attempt count.",
                "Events shorter than sample step may be missed. Interval times use requested playback positions; actual stores source PTS, which can lag on variable-frame-rate recordings. Boundaries uncertain by about one step.",
                "ocr-layout files are synthetic OCR layout renderings (no source pixels); error-line files are source crops of exact allowlisted error phrases only.",
                "This QC does not inspect audio or certify that original videos contain no secrets."],
        samples: samples, intervals: intervals)
    try writeJSON(report, to: output.appendingPathComponent("report.json"))
    var md = "# Read-only video QC: \(input.lastPathComponent)\n\nStatus: **\(status)**; duration \(timeLabel(duration)); step \(step)s; samples \(samples.count); SHA-256 unchanged: \(before == after).\n\n"
    md += "| Kind | First → last observed | Duration | Fixed UI labels |\n|---|---|---:|---|\n"
    for span in intervals { md += "| \(span.kind) | \(timeLabel(span.start)) → \(timeLabel(span.lastObserved)) | \(String(format: "%.2f",span.observedDuration))s | \(span.labels.joined(separator: " / ")) |\n" }
    md += "\n" + report.notes.map { "- " + $0 }.joined(separator: "\n") + "\n"
    try md.write(to: output.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    print("QC_DONE \(input.lastPathComponent) status=\(status) samples=\(samples.count) errors=\(intervals.filter { $0.kind == "error_observed" }.count) unchanged=\(before == after)")
    exit(status == "INCOMPLETE" ? 2 : hasErrors ? 3 : intervals.isEmpty ? 0 : 4)
} catch { fail("QC failed; no raw framework error emitted (privacy). Check input readability, AVFoundation support, and output permissions.") }
