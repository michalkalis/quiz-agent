# Apple StoreKit Trust Anchor

`AppleRootCA-G3.cer` is the trust anchor for offline StoreKit V2 JWS
verification (`app/storekit/verifier.py`). It is **not** checked into git —
download it once into this directory:

```sh
curl -fsSL -o AppleRootCA-G3.cer \
  https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
```

Expected SHA-256:

```
63 34 3a bf b8 9a 6a 03 eb b5 7e 9b 3f 5f a7 be
7c 4f 5c 75 6f 30 17 b3 a8 c4 88 c3 65 3e 91 79
```

Verify:

```sh
shasum -a 256 AppleRootCA-G3.cer
```

The cert is DER-encoded (`.cer` is the conventional extension); the verifier
also accepts PEM if you re-encode it.

## Rotation

Apple's G3 root is valid through 2039, so rotation isn't imminent — but a CI
test (`tests/storekit/test_verifier.py::test_bundled_root_validity_runway`)
fails if the bundled cert is less than 90 days from expiry. Refresh the file
from the same URL when that alarm goes off.

## Why not check it in?

The cert is public, ~600 bytes, and would simplify CI — but checking it in
makes "is the bundled cert current?" a code-review question instead of a
build-time check. The download is a one-liner; CI should run the same curl
during job setup (Task 1.12 will wire that step into `backend-ci`).
