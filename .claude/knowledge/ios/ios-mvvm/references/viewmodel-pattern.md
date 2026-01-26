# ViewModel Pattern

## Core Structure

```swift
@MainActor
final class FeatureViewModel: ObservableObject {
    // MARK: - Published State (UI-bound)
    @Published var items: [Item] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - Dependencies (injected)
    private let networkService: NetworkServiceProtocol
    private let storageService: StorageServiceProtocol

    // MARK: - Private State
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    init(
        networkService: NetworkServiceProtocol,
        storageService: StorageServiceProtocol
    ) {
        self.networkService = networkService
        self.storageService = storageService
    }

    // MARK: - Public Actions
    func loadItems() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            items = try await networkService.fetchItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

## Key Principles

### 1. @MainActor for Thread Safety
```swift
@MainActor  // All @Published updates on main thread
final class ViewModel: ObservableObject {
    @Published var state: ViewState = .idle
}
```

### 2. Dependency Injection
```swift
// Inject protocols, not concrete types
init(networkService: NetworkServiceProtocol) {
    self.networkService = networkService
}

// Enables testing with mocks
let viewModel = ViewModel(networkService: MockNetworkService())
```

### 3. Single Source of Truth
```swift
// One ViewModel per feature/screen
// Don't split state across multiple ViewModels
@MainActor
final class QuizViewModel: ObservableObject {
    @Published var currentQuestion: Question?
    @Published var score: Double = 0
    @Published var state: QuizState = .idle
    // All quiz state in one place
}
```

## State Machine Pattern

```swift
enum QuizState: Equatable {
    case idle
    case loading
    case playing
    case showingResult
    case finished
    case error
}

@MainActor
final class QuizViewModel: ObservableObject {
    @Published var state: QuizState = .idle

    func startQuiz() async {
        state = .loading

        do {
            let question = try await networkService.fetchQuestion()
            currentQuestion = question
            state = .playing
        } catch {
            errorMessage = error.localizedDescription
            state = .error
        }
    }
}
```

## Action Methods

```swift
@MainActor
final class QuizViewModel: ObservableObject {
    // User-triggered actions
    func startQuiz() async { ... }
    func submitAnswer(_ answer: String) async { ... }
    func skipQuestion() async { ... }

    // UI-triggered without async (immediate)
    func dismissError() {
        errorMessage = nil
        state = .idle
    }
}
```

## Computed Properties for UI

```swift
@MainActor
final class QuizViewModel: ObservableObject {
    @Published var questionsAnswered: Int = 0
    @Published var totalQuestions: Int = 10

    // Computed - not @Published
    var progressText: String {
        "\(questionsAnswered)/\(totalQuestions)"
    }

    var progressPercentage: Double {
        Double(questionsAnswered) / Double(totalQuestions)
    }

    var canSubmit: Bool {
        !isLoading && currentAnswer != nil
    }
}
```

## Handling Async in Init

```swift
@MainActor
final class ViewModel: ObservableObject {
    @Published var items: [Item] = []

    init(networkService: NetworkServiceProtocol) {
        self.networkService = networkService
        // Don't call async in init - let View trigger it
    }
}

// View triggers load
struct ContentView: View {
    @StateObject private var viewModel: ViewModel

    var body: some View {
        List(viewModel.items) { ... }
            .task {
                await viewModel.loadItems()  // Called when view appears
            }
    }
}
```

## Preview Support

```swift
#if DEBUG
extension ViewModel {
    static let preview: ViewModel = {
        let vm = ViewModel(
            networkService: MockNetworkService()
        )
        vm.items = [.preview, .preview2]
        vm.state = .loaded
        return vm
    }()
}
#endif

// In preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(ViewModel.preview)
    }
}
```
