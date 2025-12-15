import SwiftUI
import SwiftData

struct AskClaudeView: View {
    @StateObject private var claudeService = ClaudeService()
    @Query(sort: \Activity.timestamp, order: .reverse)
    private var activities: [Activity]
    @State private var question = ""
    @State private var conversationHistory: [ConversationMessage] = []

    var body: some View {
        VStack(spacing: 0) {
            // Conversation history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if conversationHistory.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(conversationHistory) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }

                        if claudeService.isLoading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Claude is thinking...")
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .id("loading")
                        }
                    }
                    .padding()
                }
                .onChange(of: conversationHistory.count) { _, _ in
                    withAnimation {
                        if let lastId = conversationHistory.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 12) {
                TextField("Ask about your productivity...", text: $question)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    .onSubmit {
                        sendQuestion()
                    }
                    .disabled(claudeService.isLoading)

                Button(action: sendQuestion) {
                    Image(systemName: claudeService.isLoading ? "stop.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(question.isEmpty && !claudeService.isLoading ? .secondary : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(question.isEmpty && !claudeService.isLoading)
            }
            .padding()
        }
        .navigationTitle("Ask Claude")
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Ask Claude about your productivity")
                .font(.headline)

            Text("\(activities.count) activities tracked")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                SuggestionButton(text: "What have I been working on today?") {
                    question = "What have I been working on today?"
                    sendQuestion()
                }

                SuggestionButton(text: "How productive was I this week?") {
                    question = "How productive was I this week?"
                    sendQuestion()
                }

                SuggestionButton(text: "Which project took most of my time?") {
                    question = "Which project took most of my time?"
                    sendQuestion()
                }

                SuggestionButton(text: "Give me insights about my work patterns") {
                    question = "Give me insights about my work patterns"
                    sendQuestion()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func sendQuestion() {
        guard !question.isEmpty else { return }

        if claudeService.isLoading {
            claudeService.cancel()
            return
        }

        let userMessage = ConversationMessage(role: .user, content: question)
        conversationHistory.append(userMessage)

        let currentQuestion = question
        question = ""

        Task {
            let response = await claudeService.ask(currentQuestion, activities: activities)
            let assistantMessage = ConversationMessage(role: .assistant, content: response)
            conversationHistory.append(assistantMessage)
        }
    }
}

struct ConversationMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp = Date()

    enum MessageRole {
        case user
        case assistant
    }
}

struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(12)
                    .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.2))
                    .foregroundColor(message.role == .user ? .white : .primary)
                    .cornerRadius(16)
                    .textSelection(.enabled)

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: 500, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant {
                Spacer()
            }
        }
    }
}

struct SuggestionButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                Text(text)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AskClaudeView()
}
