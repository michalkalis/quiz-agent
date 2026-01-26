# State Management

## Property Wrappers Overview

| Wrapper | Ownership | Use Case |
|---------|-----------|----------|
| `@State` | View owns | Local view state (toggles, text input) |
| `@StateObject` | View creates & owns | ViewModel created by view |
| `@ObservedObject` | Parent owns | ViewModel passed from parent |
| `@EnvironmentObject` | App-wide | Shared across view hierarchy |
| `@Published` | ViewModel | Observable properties |
| `@Binding` | Parent owns | Two-way connection to parent state |

## @State for Local View State

```swift
struct SettingsView: View {
    @State private var showingAlert = false
    @State private var sliderValue: Double = 50

    var body: some View {
        VStack {
            Slider(value: $sliderValue)
            Button("Reset") {
                showingAlert = true
            }
        }
        .alert("Reset?", isPresented: $showingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                sliderValue = 50
            }
        }
    }
}
```

## @StateObject for ViewModels

```swift
struct QuizView: View {
    // View CREATES and OWNS the ViewModel
    @StateObject private var viewModel = QuizViewModel(
        networkService: NetworkService(),
        audioService: AudioService()
    )

    var body: some View {
        VStack {
            Text(viewModel.currentQuestion?.text ?? "Loading...")
            ProgressView(value: viewModel.progress)
        }
        .task {
            await viewModel.startQuiz()
        }
    }
}
```

## @ObservedObject for Passed ViewModels

```swift
struct QuestionView: View {
    // Parent PASSES the ViewModel - don't use @StateObject
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        Text(viewModel.currentQuestion?.text ?? "")
        Button("Submit") {
            Task { await viewModel.submitAnswer() }
        }
    }
}

// Parent view
struct QuizContainerView: View {
    @StateObject private var viewModel = QuizViewModel()

    var body: some View {
        QuestionView(viewModel: viewModel)  // Passed down
    }
}
```

## @EnvironmentObject for App-Wide State

```swift
// At app level
@main
struct MyApp: App {
    @StateObject private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionStore)
        }
    }
}

// Any child view can access
struct ProfileView: View {
    @EnvironmentObject var sessionStore: SessionStore

    var body: some View {
        if sessionStore.isLoggedIn {
            Text("Welcome!")
        }
    }
}
```

## @Published in ViewModels

```swift
@MainActor
final class QuizViewModel: ObservableObject {
    // Changes trigger view updates
    @Published var state: QuizState = .idle
    @Published var score: Double = 0
    @Published private(set) var isLoading = false  // Read-only from outside

    // NOT @Published - computed from other state
    var scoreText: String {
        String(format: "%.1f points", score)
    }
}
```

## @Binding for Two-Way Data Flow

```swift
struct VolumeSlider: View {
    @Binding var volume: Double  // Parent controls this

    var body: some View {
        Slider(value: $volume, in: 0...100)
    }
}

struct SettingsView: View {
    @State private var volume: Double = 50

    var body: some View {
        VolumeSlider(volume: $volume)  // Two-way binding
    }
}
```

## State Flow Patterns

### Unidirectional Data Flow
```
User Action → ViewModel Method → Update @Published → View Re-renders
     ↑                                                      │
     └──────────────────────────────────────────────────────┘
```

### Example
```swift
struct QuizView: View {
    @StateObject private var viewModel = QuizViewModel()

    var body: some View {
        VStack {
            // Read state
            Text(viewModel.currentQuestion?.text ?? "")

            // Trigger action
            Button("Submit") {
                Task { await viewModel.submitAnswer() }  // → Updates @Published
            }
        }
    }
}

@MainActor
final class QuizViewModel: ObservableObject {
    @Published var currentQuestion: Question?

    func submitAnswer() async {
        // ... process answer
        currentQuestion = nextQuestion  // → Triggers view update
    }
}
```

## Avoiding Common Mistakes

### ❌ Wrong: @StateObject for passed ViewModel
```swift
struct ChildView: View {
    @StateObject var viewModel: QuizViewModel  // WRONG - creates new instance
}
```

### ✅ Right: @ObservedObject for passed ViewModel
```swift
struct ChildView: View {
    @ObservedObject var viewModel: QuizViewModel  // RIGHT - uses parent's instance
}
```

### ❌ Wrong: Creating ViewModel in body
```swift
struct BadView: View {
    var body: some View {
        let viewModel = QuizViewModel()  // WRONG - recreated every render
        Text(viewModel.text)
    }
}
```

### ✅ Right: @StateObject persists across renders
```swift
struct GoodView: View {
    @StateObject private var viewModel = QuizViewModel()  // Created once

    var body: some View {
        Text(viewModel.text)
    }
}
```
