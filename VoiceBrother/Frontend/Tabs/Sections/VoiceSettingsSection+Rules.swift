import SwiftUI

extension VoiceSettingsSection {
    // MARK: - Replacement Rules

    var replacementRulesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "替换规则")

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
                    .foregroundColor(theme.accentSecondary)
                }
                .buttonStyle(.plain)
            }

            Text("识别后自动替换的文字")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)

            if showNewRuleEditor {
                newRuleEditorRow
            }

            // Fixed-height scroll box so a long rule list doesn't stretch the
            // whole page. Newest rules first (storage stays append-ordered;
            // only the display is reversed).
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(configManager.replacements.reversed()) { rule in
                        if editingRuleId == rule.id {
                            editingRuleRow(rule)
                        } else {
                            ruleRow(rule)
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: 300)
            .background(theme.inputBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(theme.border, lineWidth: 1)
            )
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
                .background(theme.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accentSecondary, lineWidth: 1)
                )

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)

            TextField("正确词", text: $newRuleTo)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(theme.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accentSecondary, lineWidth: 1)
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
                    .background(theme.accent)
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
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassCard(cornerRadius: 10, borderColor: theme.accentSecondary)
    }

    private func ruleRow(_ rule: ReplacementRule) -> some View {
        HStack(spacing: 8) {
            Text(rule.from)
                .font(.system(size: 13))
                .foregroundColor(theme.destructive)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.destructiveBackground)
                .cornerRadius(6)

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)

            Text(rule.to)
                .font(.system(size: 13))
                .foregroundColor(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.successBackground)
                .cornerRadius(6)

            Spacer()

            Button {
                withAnimation {
                    editingRuleId = rule.id
                    editFrom = rule.from
                    editTo = rule.to
                }
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
            }
            .buttonStyle(.plain)

            Button {
                removeRule(rule)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(theme.destructive)
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
                .background(theme.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accentSecondary, lineWidth: 1)
                )

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)

            TextField("正确词", text: $editTo)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(theme.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accentSecondary, lineWidth: 1)
                )

            Button {
                saveEdit(rule)
            } label: {
                Text("保存")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.accent)
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
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassCard(cornerRadius: 10, borderColor: theme.accentSecondary)
    }
}
