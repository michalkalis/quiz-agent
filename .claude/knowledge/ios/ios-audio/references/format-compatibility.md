# Audio Format Compatibility

## iOS AVPlayer Supported Formats

| Format | Container | Supported | Notes |
|--------|-----------|-----------|-------|
| MP3 | .mp3 | ✅ Yes | Universal, recommended |
| AAC | .m4a, .mp4 | ✅ Yes | Apple preferred |
| WAV | .wav | ✅ Yes | Large files |
| AIFF | .aiff | ✅ Yes | Large files |
| Apple Lossless | .m4a | ✅ Yes | Lossless, Apple |
| Opus | .caf, .mp4, .mov | ✅ Yes | Only in these containers |
| Opus | .opus, .ogg | ❌ No | **Ogg container not supported** |
| Vorbis | .ogg | ❌ No | Not supported |

## Critical: Opus Container Issue

```swift
// ❌ Will NOT play - Opus in Ogg container
let url = URL(string: "audio.opus")  // Ogg container
let url = URL(string: "audio.ogg")   // Ogg container

// ✅ Will play - Opus in supported containers
let url = URL(string: "audio.caf")   // Core Audio Format
let url = URL(string: "audio.mp4")   // MP4 container
```

## Diagnosing Format Issues

### Symptom: Audio Stalls Immediately

```swift
// Check player status
player?.observe(\.timeControlStatus, options: [.new]) { player, _ in
    if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
        let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
        print("⚠️ Stalling: \(reason)")  // Often "toMinimizeStalls"

        // Check for format/codec error
        if let error = player.currentItem?.error {
            print("❌ Error: \(error.localizedDescription)")
        }
    }
}
```

### Symptom: Player Item Error

```swift
// Common error for unsupported formats:
// "The operation couldn't be completed. (CoreMediaErrorDomain error -12847.)"
// Error -12847 = kCMFormatDescriptionError_InvalidFormatDescription
```

## Recommended Server Configuration

For maximum iOS compatibility, backend should serve:

```python
# Good: MP3 for universal compatibility
tts_output_format = "mp3"

# Good: AAC in M4A container
tts_output_format = "aac"

# Bad: Opus in Ogg (iOS doesn't support Ogg)
tts_output_format = "opus"  # Results in .opus/.ogg file
```

## File Extension Detection

```swift
func suggestFormat(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()

    switch ext {
    case "mp3", "m4a", "aac", "wav", "aiff", "caf":
        return "✅ Supported"
    case "opus", "ogg", "oga", "webm":
        return "❌ Not supported by AVPlayer"
    default:
        return "⚠️ Unknown - test playback"
    }
}
```

## Handling Unsupported Formats

```swift
enum AudioFormat {
    case mp3, aac, wav, opus, unknown

    static func from(url: URL) -> AudioFormat {
        switch url.pathExtension.lowercased() {
        case "mp3": return .mp3
        case "m4a", "aac": return .aac
        case "wav": return .wav
        case "opus", "ogg": return .opus
        default: return .unknown
        }
    }

    var isSupported: Bool {
        switch self {
        case .mp3, .aac, .wav: return true
        case .opus, .unknown: return false
        }
    }
}

func playAudio(from url: URL) async throws {
    let format = AudioFormat.from(url: url)

    guard format.isSupported else {
        throw AudioError.unsupportedFormat(url.pathExtension)
    }

    // Proceed with playback
}
```

## Quality vs Compatibility Trade-offs

| Format | File Size | Quality | Compatibility |
|--------|-----------|---------|---------------|
| MP3 128kbps | Medium | Good | Universal |
| MP3 192kbps | Larger | Better | Universal |
| AAC 128kbps | Medium | Better than MP3 | iOS/Mac/Android |
| Opus | Smallest | Best | Limited iOS support |
| WAV | Largest | Lossless | Universal |

## Recommendation

**For cross-platform streaming apps:**
- Use MP3 for maximum compatibility
- AAC is good if all clients are Apple/Android

**For iOS-only apps:**
- AAC in M4A container is optimal
- Opus in CAF container works but adds complexity
