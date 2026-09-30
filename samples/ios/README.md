# iOS recorder sample

A small, Apache-2.0 licensed app built entirely on the public SDK. Use Xcode with
Swift 6.2 or newer for the currently resolved dependencies; the app targets iOS 17
or newer. Real microphone verification requires an iPhone, and adding connection
configuration requires XcodeGen. Verified locally with Xcode 27.0 (27A266a).
The checked-in project builds
without a service account; local recording remains available.

Use the repository's `main` branch for this Recorder sample. It was added after
the immutable SDK `0.3.0` tag and uses the APIs available in that release.

## Run

1. Open `CalliopeiaSample.xcodeproj` and select the `CalliopeiaSample` scheme.
2. For a physical iPhone, select your own signing team and an available bundle ID.
3. Run, allow microphone access, tap **録音開始**, then **録音を停止**.
4. Share the exported M4A or original WAV to inspect it. Stopping never uploads.

The app uses `CalliopeiaHighQualityRecorder`: raw capture with voice processing
disabled, a preferred 48 kHz rate, WAV retention, and the Recorder-derived AAC
export. The actual route/format/gain are saved in a JSON manifest beside each
recording. No noise-removal model or EdgeRuntime download is needed. See
[the capture contract](../../docs/recorder-capture.md) for parameters and limits.

## Enable email OTP and API calls

Use a Calliopeia deployment configured for Cognito email OTP and an existing
account with permission to submit audio jobs. This sample does not create accounts.

1. Obtain that deployment's `amplify_outputs.json` from its administrator or your
   normal Amplify deployment workflow.
2. Copy it to `CalliopeiaSample/amplify_outputs.json`. This path is Git-ignored.
   `amplify_outputs.example.json` documents the shape using dummy values only;
   it cannot connect to a real service. Do not put a tenant API key, JWT, OTP, or
   password in either configuration file.
3. From the repository root, regenerate the Xcode project so the real config is
   bundled:

   ```sh
   xcodegen generate --spec samples/ios/project.yml
   ```

4. Run the app, enter your email, request a code, and confirm the received code.
   `CalliopeiaSession` handles Cognito, Keychain persistence, and token refresh;
   the sample never asks the user to paste a token.
5. Record and stop, then explicitly tap **録音を送信**. Tap **状態を更新** until the
   backend finishes; the result is shown below the job ID.

Submission uses `.qualityBatch()` with BGM separation and individual kartes off.
A retry after an uncertain job response reuses both the uploaded ticket and the
request's idempotency key. It uses real
services and may consume your deployment's processing quota. A fresh recording
gets a new request. The sample does not automatically purchase formatted output.

## Source map and limits

- `SampleModel.swift`: SDK configuration, OTP steps, account access, recording,
  explicit submission, and status/result retrieval.
- `PendingAudioSubmission.swift`: retains the successful upload and request key
  together so retrying a job request does not create a new upload object.
- `ContentView.swift`: SwiftUI controls; interruption/background transitions stop
  and save recording. They do not upload it.
- `project.yml`: local package dependencies on `CalliopeiaSDK` and `CalliopeiaAuth`.

Recordings remain in the app's Documents/CalliopeiaRecordings directory until
removed by the owner or the app is uninstalled. The visible recording and job
selection are session-only; this minimal sample does not implement a history,
retention policy, background recording, or automatic result polling. Design those
policies for your own app before production use. Logging out clears the displayed
remote result but does not delete local audio.

Do not commit real connection configuration, captured audio, screenshots containing
personal data, or signing settings. The public project is generated without a real
configuration file; regenerate locally after adding yours. No private Recorder
repository history or service fixtures are required to build this sample.
