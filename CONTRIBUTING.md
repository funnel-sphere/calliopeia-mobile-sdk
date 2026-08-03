# Contributing

Small, focused pull requests are welcome for the public contracts, recording
adapters, API integration, tests, and documentation.

Before opening a pull request, run:

```bash
./scripts/check-public-boundary.sh
swift test
cd android && ./gradlew test lint
```

Do not submit model weights, production recordings, credentials, proprietary
runtime binaries, or source copied from the separately licensed edge runtime.
