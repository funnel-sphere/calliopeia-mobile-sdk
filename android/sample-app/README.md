# Android sample

Open the `android` directory in Android Studio and run the `sample-app`
configuration on Android 8.0 or newer.

The sample depends on the repository's local `:calliopeia-sdk` module. It keeps
endpoint and credential values in memory only. Replace the token field with a
`CalliopeiaCredentialProvider` backed by the host application's authenticated
session before production use.
