# iOS sample

Open `CalliopeiaSample.xcodeproj`, select an iOS 15 or newer simulator/device,
and run the `CalliopeiaSample` scheme.

The project resolves `CalliopeiaSDK` from the repository root as a local Swift
package, so edits to the SDK are reflected immediately. The sample keeps endpoint
and credential values in memory only. A production app should obtain a short-lived
JWT from its authenticated session instead of exposing a token input.

Regenerate the project after editing `project.yml`:

```bash
xcodegen generate --spec samples/ios/project.yml
```
