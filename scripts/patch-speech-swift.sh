#!/bin/bash
# 给 SPM checkout 里的 speech-swift 打 cache-fast-path 补丁。
#
# 为什么：原版 downloadWeights 每次都调 hub.snapshot()，模型已完整缓存时仍向
# HuggingFace 发 6+ 次 HEAD 请求验证 etag，国内网络下冷启动多等 5-30 秒。
# HF 的 .metadata 文件只在下载完整成功后写入，存在即证明缓存不是半成品。
#
# 用法：构建前调用（先 xcodebuild -resolvePackageDependencies 确保 checkout 存在）：
#   bash scripts/patch-speech-swift.sh [derivedDataPath]
# derivedDataPath 默认 build/.tmp-build。幂等：已打过直接跳过。
# 锚点找不到 = speech-swift 上游改了该文件 → 报错退出，需人工重新移植补丁。
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${1:-$PROJECT_ROOT/build/.tmp-build}"
TARGET="$DERIVED/SourcePackages/checkouts/speech-swift/Sources/AudioCommon/HuggingFaceDownloader.swift"

if [[ ! -f "$TARGET" ]]; then
    echo "ERROR: $TARGET 不存在——先跑 xcodebuild -resolvePackageDependencies" >&2
    exit 1
fi

if grep -q "VoiceBrother local patch" "$TARGET"; then
    echo "patch-speech-swift: 已打过，跳过"
    exit 0
fi

# SPM 把 checkout 文件标记为只读
chmod u+w "$TARGET"

python3 - "$TARGET" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()

anchor_fastpath = '''    ) async throws {
        var globs: [String] = ["config.json"]'''

fastpath = '''    ) async throws {
        // ── VoiceBrother local patch: cache fast-path ──────────────────
        // hub.snapshot() revalidates etags with 6+ HEAD requests even when
        // the model is fully cached — 5-30 s extra on slow networks. HF only
        // writes .metadata files after a complete committed download, so
        // their presence (plus config + weights) proves the cache is whole.
        if isLocalCacheComplete(directory: directory, additionalFiles: additionalFiles) {
            progressHandler?(1.0)
            return
        }
        // ── end VoiceBrother local patch ────────────────────────────────
        var globs: [String] = ["config.json"]'''

anchor_helper = '''    // MARK: - Security Helpers (kept for backward compat + security tests)'''

helper = '''    // ── VoiceBrother local patch: cache fast-path helper ──────────────
    /// True when the local cache already holds a complete model snapshot:
    /// config.json + at least one .safetensors + every non-glob additional
    /// file + HF download metadata (written only after a verified download).
    public static func isLocalCacheComplete(directory: URL, additionalFiles: [String] = []) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path) else { return false }
        guard weightsExist(in: directory) else { return false }
        for file in additionalFiles where !file.contains("*") {
            guard fm.fileExists(atPath: directory.appendingPathComponent(file).path) else { return false }
        }
        let metaDir = directory.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        guard let metas = try? fm.contentsOfDirectory(at: metaDir, includingPropertiesForKeys: nil),
              metas.contains(where: { $0.pathExtension == "metadata" }) else { return false }
        return true
    }
    // ── end VoiceBrother local patch ───────────────────────────────────

    // MARK: - Security Helpers (kept for backward compat + security tests)'''

for name, anchor in [("fast-path", anchor_fastpath), ("helper", anchor_helper)]:
    if src.count(anchor) != 1:
        sys.exit(f"ERROR: {name} 锚点匹配 {src.count(anchor)} 次（应为 1）——上游改了 HuggingFaceDownloader.swift，补丁需人工重新移植")

src = src.replace(anchor_fastpath, fastpath).replace(anchor_helper, helper)
open(path, "w").write(src)
print("patch-speech-swift: 补丁已写入")
PYEOF
