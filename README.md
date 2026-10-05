# CoreAutismAcc

An Apple Watch recording app with an iPhone companion for SensorKit PPG downloads. Both apps are built from `CoreAutismAcc.xcodeproj`. No third-party dependencies are required.

## Build and install

1. Open `CoreAutismAcc.xcodeproj` in Xcode. The deployment targets are iOS 17.6 and watchOS 10.6; use SDKs that support your connected devices.
2. Select each target’s **Signing & Capabilities** tab and choose your Apple Developer team. The project defaults to automatic signing without a preset team.
3. The iPhone app needs Apple-approved SensorKit Reader Access for **PPG**. Its signed entitlement and provisioning profile must both include uppercase `PPG`. The Watch app needs HealthKit.
4. The study identifiers are `edu.missouri.CoreAutism` and `edu.missouri.CoreAutism.watchapp`. If using another team, replace both identifiers and update the Watch target’s `WKCompanionAppBundleIdentifier` to match the phone.
5. For manual Ad Hoc signing, import your own matching distribution certificate and device provisioning profiles, then select them for both targets. Signing files are excluded from this repository.
6. Review `NSSensorKitPrivacyPolicyURL` and usage descriptions in the iPhone `Info.plist`. The included URL is the existing development notice; replace it with your study’s policy before participant use.
7. Connect and unlock the paired devices. Run **CoreAutismAcc iPhone** on the iPhone, then **CoreAutismAcc Watch App** on the Watch. Enable Developer Mode if Xcode requests it.

The apps remain installed after disconnecting from the Mac, subject to their signing validity. Simulators can display the interface but cannot collect Watch PPG.

## Record

Open the phone app and authorize PPG access. On the Watch, enter a participant name and grant microphone, HealthKit, and notification access. Names cannot contain whitespace, underscores, or slashes.

**Start ACC** starts Watch audio, HealthKit heart rate, and battery capture, and sends the session start to the phone. **Stop ACC** saves the Watch files and sends the session end. The current phone implementation keeps SensorKit collection requested between sessions and exports only samples within each session’s recorded time boundaries.

Watch **Options** opens files, settings, and sign out. The existing options password is `autism` or `Autism`. The Audio Files screen supports playback and deletion.

Settings configure a daily recording window and record/rest intervals: 15/15 minutes, 30/30 minutes, or 60/60 minutes. At the scheduled start, tap the notification to begin. The microphone engine stays active during rest periods while discarding audio buffers. Stop ends the automatic run.

## Retrieve data

On the iPhone, tap **Refresh Available PPG**, expand the recording, and use **Share file** to send its JSON Lines export to the Mac. The app waits 25 hours after a session ends: the 24-hour holding period plus a one-hour margin. Data availability also depends on SensorKit and Watch synchronization. Empty fetches do not create shareable PPG files.

Watch files are stored under `Documents`:

| Folder | Contents |
| --- | --- |
| `AudioRecorderWear` | AAC audio (`.m4a`) |
| `hrData` | HealthKit heart-rate JSON |
| `BatteryData` | Battery JSON |
| `PPGSessions` | Session boundaries and Watch-to-phone command state |
| `Queue` | Upload retry metadata |

To copy Watch files to the Mac, find the Watch device ID with `xcrun devicectl list devices`, then run:

```sh
xcrun devicectl device copy from \
  --device "<watch-device-id>" \
  --domain-type appDataContainer \
  --domain-identifier edu.missouri.CoreAutism.watchapp \
  --source Documents \
  --destination ./watch-export
```

Use your Watch bundle identifier if you changed it. Phone PPG files are in `Documents/PPG` and are also available through Finder file sharing.

The app implements SensorKit PPG and its associated motion samples. Separate SensorKit ECG, on-wrist state, heart rate, and accelerometer readers are not part of the recording path. The Watch heart-rate files come from HealthKit. Battery values come from WatchKit.

Optional uploads use HTTP PUT to `<upload_base_url>/<filename>`, with `upload_base_url` read from Watch `UserDefaults`. Without a configured endpoint, recordings remain local. No backend or cloud credentials are included.

## Source

- `CoreAutismAcc Watch App/`: Watch UI, audio, HealthKit, schedules, and uploads.
- `CoreAutismAcc iOS App/`: SensorKit authorization, PPG export, and sharing.
- `Shared/`: session messages and timing used by both apps.
- `CoreAutismAcc.xcodeproj/`: targets, shared schemes, and capabilities.

To check that both targets compile without signing:

```sh
xcodebuild -project CoreAutismAcc.xcodeproj \
  -scheme "CoreAutismAcc iPhone" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath /tmp/CoreAutismAcc-build \
  CODE_SIGNING_ALLOWED=NO build
```
