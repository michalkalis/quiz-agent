# Mocking for Tests

## Protocol-Based Mocking

### 1. Define Protocol
```swift
protocol NetworkServiceProtocol: Sendable {
    func fetchItems() async throws -> [Item]
    func submitAnswer(_ answer: String) async throws -> Result
}
```

### 2. Real Implementation
```swift
actor NetworkService: NetworkServiceProtocol {
    func fetchItems() async throws -> [Item] {
        // Real network call
        let (data, _) = try await session.data(from: itemsURL)
        return try JSONDecoder().decode([Item].self, from: data)
    }
}
```

### 3. Mock Implementation
```swift
#if DEBUG
final class MockNetworkService: NetworkServiceProtocol {
    // Control mock behavior
    var mockItems: [Item] = []
    var shouldFail = false
    var error: Error = NetworkError.invalidResponse

    func fetchItems() async throws -> [Item] {
        if shouldFail {
            throw error
        }
        return mockItems
    }

    func submitAnswer(_ answer: String) async throws -> Result {
        if shouldFail {
            throw error
        }
        return .correct
    }
}
#endif
```

### 4. Use in Tests
```swift
@MainActor
final class QuizViewModelTests: XCTestCase {
    var mockNetwork: MockNetworkService!
    var viewModel: QuizViewModel!

    override func setUp() {
        super.setUp()
        mockNetwork = MockNetworkService()
        viewModel = QuizViewModel(networkService: mockNetwork)
    }

    func testLoadItemsSuccess() async {
        // Arrange
        mockNetwork.mockItems = [.preview, .preview2]

        // Act
        await viewModel.loadItems()

        // Assert
        XCTAssertEqual(viewModel.items.count, 2)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadItemsFailure() async {
        // Arrange
        mockNetwork.shouldFail = true

        // Act
        await viewModel.loadItems()

        // Assert
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }
}
```

## Mock Audio Service

```swift
#if DEBUG
@MainActor
final class MockAudioService: AudioServiceProtocol {
    var isPlaying = false
    var isRecording = false
    var shouldFailPlayback = false
    var shouldFailRecording = false
    var mockRecordingData = Data("mock audio".utf8)

    func play(_ data: Data) async throws {
        if shouldFailPlayback {
            throw AudioError.playbackFailed
        }
        isPlaying = true
        try await Task.sleep(nanoseconds: 100_000_000)  // Simulate playback
        isPlaying = false
    }

    func startRecording() throws {
        if shouldFailRecording {
            throw AudioError.recordingFailed
        }
        isRecording = true
    }

    func stopRecording() async throws -> Data {
        isRecording = false
        return mockRecordingData
    }

    func stop() {
        isPlaying = false
    }
}
#endif
```

## Mock Session Store

```swift
#if DEBUG
final class MockSessionStore: SessionStoreProtocol {
    var storedSessionId: String?
    var storedSettings: QuizSettings = .default

    var currentSessionId: String? {
        storedSessionId
    }

    func saveSession(id: String) {
        storedSessionId = id
    }

    func clearSession() {
        storedSessionId = nil
    }

    func loadSettings() -> QuizSettings {
        storedSettings
    }

    func saveSettings(_ settings: QuizSettings) {
        storedSettings = settings
    }
}
#endif
```

## Preview Support with Mocks

```swift
#if DEBUG
extension QuizViewModel {
    static let preview: QuizViewModel = {
        let mockNetwork = MockNetworkService()
        mockNetwork.mockItems = Item.previewList

        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: MockAudioService(),
            sessionStore: MockSessionStore()
        )
        viewModel.state = .playing
        viewModel.currentQuestion = .preview
        return viewModel
    }()

    static let previewError: QuizViewModel = {
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            sessionStore: MockSessionStore()
        )
        viewModel.state = .error
        viewModel.errorMessage = "Network connection failed"
        return viewModel
    }()
}
#endif
```

## Testing State Transitions

```swift
@MainActor
final class QuizViewModelTests: XCTestCase {
    func testStateTransitionsOnSuccess() async {
        // Arrange
        let mockNetwork = MockNetworkService()
        mockNetwork.mockQuestion = .preview
        let viewModel = QuizViewModel(networkService: mockNetwork)

        // Initial state
        XCTAssertEqual(viewModel.state, .idle)

        // Act
        await viewModel.startQuiz()

        // Assert state progression
        XCTAssertEqual(viewModel.state, .playing)
        XCTAssertNotNil(viewModel.currentQuestion)
    }

    func testStateTransitionsOnFailure() async {
        // Arrange
        let mockNetwork = MockNetworkService()
        mockNetwork.shouldFail = true
        let viewModel = QuizViewModel(networkService: mockNetwork)

        // Act
        await viewModel.startQuiz()

        // Assert
        XCTAssertEqual(viewModel.state, .error)
        XCTAssertNotNil(viewModel.errorMessage)
    }
}
```

## Async Test Utilities

```swift
extension XCTestCase {
    /// Wait for a condition to become true
    func waitFor(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 5.0
    ) async {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timeout waiting for condition")
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

// Usage
func testAsyncStateChange() async {
    await viewModel.startQuiz()
    await waitFor { viewModel.state == .playing }
    XCTAssertNotNil(viewModel.currentQuestion)
}
```
