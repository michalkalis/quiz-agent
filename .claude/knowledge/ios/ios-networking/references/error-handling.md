# Network Error Handling

## Typed Error Enum

```swift
enum NetworkError: LocalizedError {
    case invalidResponse
    case invalidURL
    case decodingFailed(Error)
    case serverError(statusCode: Int, message: String)
    case timeout
    case noConnection

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .invalidURL:
            return "Invalid URL"
        case .decodingFailed(let error):
            return "Failed to decode: \(error.localizedDescription)"
        case .serverError(_, let message):
            return message
        case .timeout:
            return "Request timed out"
        case .noConnection:
            return "No internet connection"
        }
    }
}
```

## Status Code Handling

```swift
actor NetworkService {
    private func handleResponse(data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            return data

        case 400...499:
            // Client error - try to parse error message
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw NetworkError.serverError(
                    statusCode: http.statusCode,
                    message: errorResponse.detail
                )
            }
            throw NetworkError.serverError(statusCode: http.statusCode, message: "Client error")

        case 500...599:
            throw NetworkError.serverError(statusCode: http.statusCode, message: "Server error")

        default:
            throw NetworkError.invalidResponse
        }
    }
}

// Backend error response structure
private struct ErrorResponse: Decodable {
    let detail: String
}
```

## URL Error Mapping

```swift
extension NetworkService {
    private func mapURLError(_ error: URLError) -> NetworkError {
        switch error.code {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .networkConnectionLost:
            return .noConnection
        case .cannotFindHost, .cannotConnectToHost:
            return .serverError(statusCode: 0, message: "Cannot reach server")
        default:
            return .invalidResponse
        }
    }
}
```

## Complete Error Handling Pattern

```swift
actor NetworkService {
    func fetchWithErrorHandling() async throws -> [Item] {
        let url = baseURL.appendingPathComponent("/items")

        do {
            let (data, response) = try await session.data(from: url)
            let validData = try handleResponse(data: data, response: response)
            return try decodeWithLogging(validData, as: [Item].self)

        } catch let error as URLError {
            throw mapURLError(error)
        } catch let error as DecodingError {
            throw NetworkError.decodingFailed(error)
        } catch let error as NetworkError {
            throw error  // Already our error type
        } catch {
            throw NetworkError.invalidResponse
        }
    }
}
```

## ViewModel Error Handling

```swift
@MainActor
final class ViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var state: ViewState = .idle

    func loadData() async {
        state = .loading
        errorMessage = nil

        do {
            let items = try await networkService.fetchItems()
            self.items = items
            state = .loaded

        } catch let error as NetworkError {
            handleNetworkError(error)
        } catch {
            errorMessage = "An unexpected error occurred"
            state = .error
        }
    }

    private func handleNetworkError(_ error: NetworkError) {
        errorMessage = error.localizedDescription

        switch error {
        case .noConnection:
            // Maybe show offline mode
            state = .offline
        case .timeout:
            // Allow retry
            state = .error
        case .serverError(let code, _) where code == 404:
            // Session expired - need new session
            state = .sessionExpired
        default:
            state = .error
        }
    }
}
```

## Distinguishing Error Context

```swift
enum ErrorContext {
    case initialization  // Session creation, quiz start
    case submission      // Answer submission
    case general         // Other operations
}

@MainActor
final class ViewModel: ObservableObject {
    private var errorContext: ErrorContext = .general

    func startQuiz() async {
        errorContext = .initialization
        do {
            // ...
        } catch {
            // Error in initialization context
        }
    }

    func submitAnswer() async {
        errorContext = .submission
        do {
            // ...
        } catch {
            // Error in submission context - allow re-record
        }
    }

    func retry() async {
        switch errorContext {
        case .initialization:
            await startQuiz()  // Start over
        case .submission:
            state = .askingQuestion  // Allow re-record
        case .general:
            // Generic retry
        }
    }
}
```

## Graceful Degradation for Non-Critical Errors

```swift
func playQuestionAudio(from url: String) async {
    do {
        let data = try await networkService.downloadAudio(from: url)
        try await audioService.play(data)
    } catch {
        // Audio is non-critical - log but don't fail quiz
        if Config.verboseLogging {
            print("⚠️ Failed to play audio: \(error)")
        }
        // Continue without audio
    }
}
```
