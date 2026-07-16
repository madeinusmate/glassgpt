# Contributing to GlassGPT

Thanks for contributing. GlassGPT handles real-time voice, visual context, and native iOS actions, so changes should be careful about user consent, privacy, and behavior on real hardware.

## Before you begin

Read the [README](README.md) and complete its local setup. You need a physical iPhone and a configured Meta Wearables developer app to exercise glasses features; the Simulator cannot validate Bluetooth glasses or DAT streaming.

Create your own local configuration before building:

```bash
cp Config.xcconfig.example Config.xcconfig
xcodegen generate
open GlassGPT.xcodeproj
```

`Config.xcconfig` is ignored intentionally. Never commit API keys, Meta client tokens, provisioning profiles, personal contact data, photos, logs containing user data, or other credentials.

## Development workflow

1. Check existing issues and pull requests before starting a large change.
2. Create a focused branch from the current default branch.
3. Keep each pull request limited to one cohesive improvement.
4. Regenerate the project with `xcodegen generate` whenever you change `project.yml`.
5. Build the app before opening a pull request. For changes involving glasses, audio routing, Live Activities, or operating-system permissions, test on a physical iPhone as well.

A useful unsigned build check is:

```bash
xcodebuild \
  -project GlassGPT.xcodeproj \
  -scheme GlassGPT \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Use your connected iPhone in Xcode for the complete integration test. A simulator build cannot prove that the Meta AI pairing, glasses camera/microphone, or Bluetooth audio route works.

## Code and product expectations

- Follow the existing Swift and SwiftUI style. Prefer small, focused types and descriptive names over large, multi-purpose views or managers.
- Keep user-facing copy clear about what will happen. Native actions such as creating a reminder, calendar event, or call must remain user initiated and respect iOS authorization state.
- Add or update permission handling when introducing a capability that accesses system data or hardware.
- Do not broaden what is sent to an AI service without making that behavior clear to the user. Treat camera frames, audio, location, contacts, photos, and calendar data as sensitive.
- Do not add a production flow that embeds an OpenAI API key in the app. A production integration must use a trusted backend and short-lived Realtime credentials.
- Preserve third-party attribution. If you copy or adapt external code, record its license and notice in `THIRD_PARTY_NOTICES.md`.

## Pull requests

Please include:

- A concise explanation of the problem and the approach.
- Screenshots or a short recording for visible UI, animation, Live Activity, or permission-flow changes when possible.
- The device and iOS version used for hardware testing, or a note explaining why hardware testing was not possible.
- Any configuration, privacy, or documentation changes required by the feature.

Avoid unrelated reformatting and generated-file churn. If the change modifies the required setup, bundle identifiers, permissions, or developer-portal flow, update `README.md` in the same pull request.

## Reporting issues

Use a clear title and include steps to reproduce, expected behavior, actual behavior, iOS/Xcode versions, and whether glasses were connected. Redact API keys, client tokens, device identifiers, personal data, and screenshots that contain sensitive content before posting publicly.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

