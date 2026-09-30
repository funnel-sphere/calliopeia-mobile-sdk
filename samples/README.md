# Sample applications

- `ios`: SwiftUI reference app using the local Swift package.
- `android`: Android reference app using the local Gradle modules.

Both apps use email OTP sign-in, save a raw WAV master and an M4A delivery copy,
submit explicitly, and display the job result. Add your own ignored
`amplify_outputs.json` following each sample's README. Amplify manages session
persistence and token refresh; neither UI asks for a JWT or a tenant API key.
