# CarPlay and Siri

Pier in the car is for a glance and the voice: what needs the person, answered without typing or reading while
driving. Three pieces work together, all going by the same conversation id, `pier-session:<box>/<session>` (both parts
percent-encoded; `CarDigest.conversationID` in PierKit, tested):

| Piece | Where | What it does |
|---|---|---|
| CarPlay screen | `App/CarPlay/CarPlayScene.swift` | Three lists: **Precisa de você** (a waiting agent opens big rows: Permitir / Negar, or its question's choices, plus "Responder por voz"), **Sua vez** (turns that ended: a `CPMessageListItem`, so picking it has Siri read the reply aloud and take a spoken answer) and **Trabalhando** (information only). Read from every paired box every 5 s while the car shows it. |
| Siri messages | `App/Intents/MessageIntents.swift` | `INSendMessageIntent` (a dictated reply goes to the session with `when: idle`), `INSearchForMessagesIntent` (what Siri reads: a waiting agent's request or question, or the reply that ended the turn with its Markdown, code and tables taken out, `CarDigest.spoken`), `INSetMessageAttributeIntent` (said done). Handled in the app (`AppDelegate.application(_:handlerFor:)`), which Siri starts in the background. |
| Messages as notifications | `App/Shared/CommunicationNotification.swift` | Every agent notification (local, and pierd's pushes through the notification service extension) becomes a communication notification: the agent is the sender with its avatar, the session is the conversation. Siri announces them in the car (and on AirPods) and "Responder" comes back as an `INSendMessageIntent`. The categories carry `.allowInCarPlay` and the message intent; the app asks for `.carPlay` with the other notification permissions. |

All of it runs without the app's window (the phone locked in a pocket): `CarFeed` reads the boxes through
`HeadlessBoxes`, and archived turns are read from the saved prefs (`LocalPrefs.savedClosedMarks`) without writing them.
Answers go through the same checked paths as the notification buttons (`SessionActions`: the menu is read again before
Permitir / Negar, a choice must still be there under the same words). iPhone and iPad only; the Mac app is unchanged.

## Entitlements

| Entitlement | Target | Status |
|---|---|---|
| `com.apple.developer.siri` | app | self-service: automatic signing adds the capability to the App ID |
| `com.apple.developer.usernotifications.communication` | app | self-service, same |
| `com.apple.developer.carplay-communication` | app | **granted by Apple on request** ([developer.apple.com/carplay](https://developer.apple.com/carplay), Communication category) |

Simulator builds always carry the CarPlay entitlement (`App/Resources/Pier-carplay.entitlements`, picked by
`CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]`). Device builds use `PIER_IOS_ENTITLEMENTS` (`Config/Base.xcconfig`),
`App/Resources/Pier.entitlements` by default. Once Apple has added the CarPlay communication capability to the App ID,
set in the gitignored `Config/Signing.xcconfig`:

```
PIER_IOS_ENTITLEMENTS = App/Resources/Pier-carplay.entitlements
```

`Pier-carplay.entitlements` is not generated: keep it the generated `Pier.entitlements` plus the CarPlay key when
project.yml's entitlements change. Without the CarPlay entitlement the rest still works on a device: the messages, Siri
reading them and the spoken replies, in the car included (CarPlay reads communication notifications through Siri).

## Checking it

- `-carPlaySelfTest 1` (with `-uiTestMock 1` or real boxes, iPhone or iPad simulator): builds the car's rows and the
  CarPlay list, has `MessageIntentHandler` read the conversations and resolve a spoken name, sends a reply to an ended
  turn and reads the box's record back. One `CARPLAY-TEST …` line each on stderr
  (`xcrun simctl launch --console-pty <udid> <bundle id> -uiTestMock 1 -carPlaySelfTest 1`).
- `CarDigestTests` (PierKit): ids, order and caps of the lists, and the spoken text.
- The CarPlay screen itself: Xcode 27's Device Hub has no CarPlay display menu any more. Through CoreSimulator and
  SimulatorKit (private) the simulator's CarPlay session does start — `-[SimDevice enableCarPlay:error:]`, the
  `wireless0` screen (the one whose `carPlayProperties` carry `SimCarPlayPropertyKeyStark`) given a mode and power,
  `IndigoHIDMessageToCreateCarPlayService` sent through `SimDeviceLegacyHIDClient` — and CarPlayApp and carkitd run and
  list Pier (`online.residente.pier`) among the car's apps, but on Xcode 27 the screen stays black (no frames). Seeing
  it takes a device with the entitlement, in a car or Apple's CarPlay Simulator app over USB.
- A spoken reply to an agent waiting on a question: `-uiTestMock 1 -uiTestAsk 1 -carPlaySelfTest 1` (the words go in
  through the question's "Type something." row, read from the screen with `MenuParser.typeSomethingKey`, or its form
  when the record holds the question; a permission refuses them).
