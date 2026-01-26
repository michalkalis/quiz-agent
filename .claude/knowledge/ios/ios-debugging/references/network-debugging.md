# Network Debugging

## Log Request and Response

```swift
func logRequest(_ request: URLRequest) {
    print("🌐 \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")

    if let headers = request.allHTTPHeaderFields {
        print("   Headers: \(headers)")
    }

    if let body = request.httpBody,
       let json = String(data: body, encoding: .utf8) {
        print("   Body: \(json)")
    }
}

func logResponse(_ response: URLResponse?, data: Data?) {
    if let http = response as? HTTPURLResponse {
        print("📥 Status: \(http.statusCode)")
        print("   Headers: \(http.allHeaderFields)")
    }

    if let data = data,
       let json = String(data: data, encoding: .utf8) {
        print("   Body: \(json)")
    }
}
```

## Test with curl

```bash
# Test POST endpoint
curl -v -X POST http://localhost:8002/api/v1/sessions \
  -H "Content-Type: application/json" \
  -d '{"max_questions": 5, "difficulty": "medium"}'

# Test GET endpoint
curl -v http://localhost:8002/api/v1/sessions/abc123

# Upload audio file
curl -v -X POST http://localhost:8002/api/v1/voice/submit/abc123 \
  -F "audio=@recording.m4a;type=audio/m4a"
```

## Common Issues

### Connection Refused
```
Error Domain=NSURLErrorDomain Code=-1004 "Could not connect to the server."
```
- Backend not running
- Wrong port
- Check: `curl http://localhost:8002/docs`

### Timeout
```
Error Domain=NSURLErrorDomain Code=-1001 "The request timed out."
```
- Server too slow
- Network issues
- Increase timeout: `request.timeoutInterval = 60`

### SSL/TLS Error
```
Error Domain=NSURLErrorDomain Code=-1200 "An SSL error has occurred"
```
- HTTPS required but using HTTP
- Certificate invalid
- For local dev: use HTTP not HTTPS

### No Network (Simulator)
- Reset simulator network: Settings → General → Reset → Reset Network Settings
- Restart simulator
- Check Mac's network connection

## Charles Proxy / Proxyman

### Enable Proxy in Simulator
1. Install Charles or Proxyman
2. Install SSL certificate on simulator
3. Traffic appears in proxy app

### SSL Certificate Installation
```bash
# Charles certificate
open ~/Library/Application\ Support/Charles/charles-ssl-proxying/charles-ssl-proxying-certificate.pem

# Install on simulator
# Drag .pem file onto running simulator
```

## Network Link Conditioner

Test slow network conditions:

1. Install from Additional Tools for Xcode
2. System Preferences → Network Link Conditioner
3. Choose profile: 3G, Edge, 100% Loss, etc.

## Debug Response Issues

### Check Status Code
```swift
guard let http = response as? HTTPURLResponse else {
    print("❌ Not HTTP response")
    return
}

print("Status: \(http.statusCode)")

switch http.statusCode {
case 200...299:
    print("✅ Success")
case 400:
    print("❌ Bad Request - check input")
case 401:
    print("❌ Unauthorized - check auth")
case 404:
    print("❌ Not Found - check URL")
case 500...599:
    print("❌ Server Error - check backend logs")
default:
    print("⚠️ Unexpected status")
}
```

### Inspect Raw Response
```swift
if let data = data {
    print("Raw bytes: \(data.count)")

    if let string = String(data: data, encoding: .utf8) {
        print("Response: \(string)")
    } else {
        print("Response not UTF-8 (binary data)")
    }
}
```

## Simulator Network Issues

### Reset Network
```bash
# Restart network in simulator
xcrun simctl spawn booted networkservices -disable_wifi
xcrun simctl spawn booted networkservices -enable_wifi
```

### Check Localhost Access
```swift
// Simulator can access Mac's localhost
// Use http://localhost:8002 not http://127.0.0.1:8002
```

### Physical Device to Mac
```swift
// Use Mac's IP address instead of localhost
let baseURL = "http://192.168.1.100:8002"

// Find Mac IP:
// System Preferences → Network → Wi-Fi → IP Address
```
