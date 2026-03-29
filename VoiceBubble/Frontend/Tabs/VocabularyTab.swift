import SwiftUI

struct VocabularyTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var voiceService: VoiceService

    @State private var newHotword = ""
    @State private var showNewRuleEditor = false
    @State private var newRuleFrom = ""
    @State private var newRuleTo = ""
    @State private var editingRuleId: UUID? = nil
    @State private var editFrom = ""
    @State private var editTo = ""
    @State private var hasUnsavedChanges = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // MARK: - Hotwords Section
                hotwordsSection

                // MARK: - Replacement Rules Section
                replacementRulesSection
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hotwords Section

    private var hotwordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("热词")

            Text("传递给识别模型，帮助识别专有名词")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "8AA0BE"))

            // Tag cloud
            FlowLayout(spacing: 8) {
                ForEach(configManager.hotwords, id: \.self) { word in
                    hotwordTag(word)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()

            // Input field
            HStack(spacing: 8) {
                TextField("输入新热词，按 Enter 添加", text: $newHotword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(hex: "F5F8FE"))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "C0D0E4"), lineWidth: 1)
                    )
                    .onSubmit {
                        addHotword()
                    }

                Button {
                    addHotword()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color(hex: "7B8CF5"))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(newHotword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func hotwordTag(_ word: String) -> some View {
        HStack(spacing: 6) {
            Text(word)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "3A4E7A"))

            Button {
                removeHotword(word)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: "8AA0BE"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(hex: "F2F6FC"))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: "C8D8EA"), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    // MARK: - Replacement Rules Section

    private var replacementRulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("替换规则")

                Spacer()

                Button {
                    withAnimation {
                        showNewRuleEditor = true
                        newRuleFrom = ""
                        newRuleTo = ""
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                        Text("添加规则")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color(hex: "7B8CF5"))
                }
                .buttonStyle(.plain)
            }

            Text("识别后自动替换的文字")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "8AA0BE"))

            // New rule inline editor
            if showNewRuleEditor {
                newRuleEditorRow
            }

            // Existing rules
            VStack(spacing: 6) {
                ForEach(configManager.replacements) { rule in
                    if editingRuleId == rule.id {
                        editingRuleRow(rule)
                    } else {
                        ruleRow(rule)
                    }
                }
            }

            // Restart notice
            if hasUnsavedChanges {
                restartNotice
            }
        }
    }

    private var newRuleEditorRow: some View {
        HStack(spacing: 8) {
            TextField("错误词", text: $newRuleFrom)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(Color(hex: "F5F8FE"))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "7B8CF5"), lineWidth: 1)
                )

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "8AA0BE"))

            TextField("正确词", text: $newRuleTo)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(Color(hex: "F5F8FE"))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "7B8CF5"), lineWidth: 1)
                )
                .onSubmit {
                    addRule()
                }

            Button {
                addRule()
            } label: {
                Text("保存")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(hex: "4ECDC4"))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(newRuleFrom.trimmingCharacters(in: .whitespaces).isEmpty || newRuleTo.trimmingCharacters(in: .whitespaces).isEmpty)

            Button {
                withAnimation {
                    showNewRuleEditor = false
                }
            } label: {
                Text("取消")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "5A7098"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassCard(cornerRadius: 10, borderColor: Color(hex: "7B8CF5"))
    }

    private func ruleRow(_ rule: ReplacementRule) -> some View {
        HStack(spacing: 8) {
            Text(rule.from)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "FF6B8A"))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(hex: "FFF0F3"))
                .cornerRadius(6)

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "8AA0BE"))

            Text(rule.to)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "4ECDC4"))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(hex: "EDFCFA"))
                .cornerRadius(6)

            Spacer()

            // Edit button
            Button {
                withAnimation {
                    editingRuleId = rule.id
                    editFrom = rule.from
                    editTo = rule.to
                }
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "8AA0BE"))
            }
            .buttonStyle(.plain)

            // Delete button
            Button {
                removeRule(rule)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "FF6B8A"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 10)
    }

    private func editingRuleRow(_ rule: ReplacementRule) -> some View {
        HStack(spacing: 8) {
            TextField("错误词", text: $editFrom)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(Color(hex: "F5F8FE"))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "7B8CF5"), lineWidth: 1)
                )

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "8AA0BE"))

            TextField("正确词", text: $editTo)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(Color(hex: "F5F8FE"))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "7B8CF5"), lineWidth: 1)
                )

            Button {
                saveEdit(rule)
            } label: {
                Text("保存")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(hex: "4ECDC4"))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation {
                    editingRuleId = nil
                }
            } label: {
                Text("取消")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "5A7098"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassCard(cornerRadius: 10, borderColor: Color(hex: "7B8CF5"))
    }

    private var restartNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "C89828"))

            Text("替换规则修改后，需要重启语音服务生效")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "C89828"))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "FFFBF0"))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: "F0E0B0"), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Color(hex: "2C3E6B"))
    }

    // MARK: - Hotword Actions

    private func addHotword() {
        let word = newHotword.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        guard !configManager.hotwords.contains(word) else {
            newHotword = ""
            return
        }
        configManager.hotwords.append(word)
        newHotword = ""
        markChanged()
    }

    private func removeHotword(_ word: String) {
        configManager.hotwords.removeAll { $0 == word }
        markChanged()
    }

    // MARK: - Rule Actions

    private func addRule() {
        let from = newRuleFrom.trimmingCharacters(in: .whitespaces)
        let to = newRuleTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty && !to.isEmpty else { return }

        let rule = ReplacementRule(from: from, to: to)
        configManager.replacements.append(rule)

        withAnimation {
            showNewRuleEditor = false
            newRuleFrom = ""
            newRuleTo = ""
        }
        markChanged()
    }

    private func removeRule(_ rule: ReplacementRule) {
        configManager.replacements.removeAll { $0.id == rule.id }
        markChanged()
    }

    private func saveEdit(_ rule: ReplacementRule) {
        let from = editFrom.trimmingCharacters(in: .whitespaces)
        let to = editTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty && !to.isEmpty else { return }

        if let index = configManager.replacements.firstIndex(where: { $0.id == rule.id }) {
            configManager.replacements[index] = ReplacementRule(id: rule.id, from: from, to: to)
        }

        withAnimation {
            editingRuleId = nil
        }
        markChanged()
    }

    private func markChanged() {
        hasUnsavedChanges = true
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing

            totalWidth = max(totalWidth, currentX)
            totalHeight = currentY + rowHeight
        }

        return LayoutResult(
            size: CGSize(width: totalWidth, height: totalHeight),
            positions: positions
        )
    }
}
