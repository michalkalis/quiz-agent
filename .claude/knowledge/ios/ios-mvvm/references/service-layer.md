# Service Layer Pattern

## Service Types

| Service Type | Annotation | Use Case |
|-------------|------------|----------|
| Network | `actor` | API calls, downloads |
| Audio/Video | `@MainActor` | AVFoundation requires main |
| Storage | `actor` | UserDefaults, file I/O |
| Location | `@MainActor` | CLLocationManager |

## Actor-Based Service (Network)

```swift
protocol NetworkServiceProtocol: Sendable {
    func fetchItems() async throws -> [Item]
    func submitData(_ data: Data) async throws
}

actor NetworkService: NetworkServiceProtocol {
    private let session: URLSession
    private let baseURL: URL

    init(baseURL: String = "https://api.example.com") {
        self.baseURL = URL(string: baseURL)!
        self.session = URLSession(configuration: .default)
    }

    func fetchItems() async throws -> [Item] {
        let url = baseURL.appendingPathComponent("/items")
        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NetworkError.invalidResponse
        }

        return try JSONDecoder().decode([Item].self, from: data)
    }
}
```

## MainActor Service (Audio)

```swift
@MainActor
protocol AudioServiceProtocol: Sendable {
    var isPlaying: Bool { get }
    func play(_ data: Data) async throws
    func stop()
}

@MainActor
final class AudioService: ObservableObject, AudioServiceProtocol {
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?

    func play(_ data: Data) async throws {
        player = try AVAudioPlayer(data: data)
        player?.play()
        isPlaying = true
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }
}
```

## Storage Service

```swift
protocol SessionStoreProtocol: Sendable {
    var currentSessionId: String? { get }
    func saveSession(id: String)
    func clearSession()
}

actor SessionStore: SessionStoreProtocol {
    private let defaults = UserDefaults.standard
    private let sessionKey = "current_session_id"

    var currentSessionId: String? {
        defaults.string(forKey: sessionKey)
    }

    func saveSession(id: String) {
        defaults.set(id, forKey: sessionKey)
    }

    func clearSession() {
        defaults.removeObject(forKey: sessionKey)
    }
}
```

## Service Composition in ViewModel

```swift
@MainActor
final class QuizViewModel: ObservableObject {
    // Multiple services, each with single responsibility
    private let networkService: NetworkServiceProtocol
    private let audioService: AudioServiceProtocol
    private let sessionStore: SessionStoreProtocol

    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        sessionStore: SessionStoreProtocol
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.sessionStore = sessionStore
    }

    func startQuiz() async {
        // Coordinate multiple services
        let session = try await networkService.createSession()
        sessionStore.saveSession(id: session.id)

        let question = try await networkService.fetchQuestion()
        if let audioUrl = question.audioUrl {
            let data = try await networkService.downloadAudio(from: audioUrl)
            try await audioService.play(data)
        }
    }
}
```

## Error Handling in Services

```swift
enum NetworkError: LocalizedError {
    case invalidResponse
    case invalidURL
    case decodingFailed(Error)
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .invalidURL:
            return "Invalid URL"
        case .decodingFailed(let error):
            return "Decoding failed: \(error.localizedDescription)"
        case .serverError(_, let message):
            return message
        }
    }
}

actor NetworkService {
    func fetch() async throws -> Data {
        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 400...499:
            let message = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw NetworkError.serverError(
                statusCode: http.statusCode,
                message: message?.detail ?? "Client error"
            )
        default:
            throw NetworkError.invalidResponse
        }
    }
}
```

## Singleton vs Injection

```swift
// ❌ Singleton (hard to test)
class NetworkService {
    static let shared = NetworkService()
}

// ✅ Dependency Injection (testable)
actor NetworkService: NetworkServiceProtocol {
    // No static shared
}

// Create at app startup, inject everywhere
@main
struct MyApp: App {
    let networkService = NetworkService()
    let audioService = AudioService()

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: QuizViewModel(
                    networkService: networkService,
                    audioService: audioService
                )
            )
        }
    }
}
```
