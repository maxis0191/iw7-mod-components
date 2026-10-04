# Private Zombies voice beta

This package is for a supervised two-player test on the owner's private Zombies
server. It is not an official IW7-Mod release or an accepted voice feature.
Current testing uses generic voice protocol **2**, relayed through the dedicated
server's existing game socket. Both players and the server need the same tested
executable and protocol. This is a conversation between two players; it does not
create a direct peer-to-peer connection between their PCs. Real microphone quality,
device/privacy behavior and Internet delivery still require this test.

## Install

1. Extract the complete package into a separate folder. Keep
   `build-manifest.json`, `Install-VoiceClient.ps1` and the supplied launcher beside
   the executable. For the current test, the manifest must declare
   `SelectedVoiceProtocol: 2`.
2. Run `./Install-VoiceClient.ps1 -GameRoot 'YOUR EXISTING GAME FOLDER'` in
   PowerShell. The installer checks the executable and launcher hashes, preserves
   earlier custom files and installs alongside `iw7-mod.exe`. It does not stop a
   running game, change graphics settings, install game assets or modify profiles,
   keys or bank data. Close a running older custom executable yourself before
   replacing it with a different build.
3. Exit your current client when you are ready, then run the installed
   `Start-IW7-Zombies-Voice.bat`. For protocol 2 this launcher includes
   `-iw7-voice-relay`; opening the executable directly does not select that
   transport. `-noupdate` preserves the private executable while leaving the
   official updater/launcher available.
4. Open Zombies and join **Private Testing Server** using the owner's usual
   server address and private access. Every speaker and listener needs this exact
   package/profile. Stock-client voice and mixed versions remain unaccepted.

Use the game's audio settings to enable voice, select the intended microphone and
output, and check the actual push-to-talk binding. Windows microphone permission
and device availability still apply. Use headphones for the first test. No extra
audio application, account or recording service is required.

The existing game UDP port is used; no additional router port is required. A new
executable can trigger the ordinary Windows Firewall prompt. The server must have
its own scoped UDP allow rule. The player launcher has no server IO, godmode,
inactivity bypass, PCM-injection or development-fixture flag.

## Two-player test

Test on different PCs. First establish both directions on the LAN, then have one
player connect from another external network through the existing server address.

1. Speak a short sentence in each direction while holding the configured voice
   key. Confirm intelligibility, correct speaker attribution and normal game
   audio. Release the key and confirm speech stops.
2. Disable/re-enable voice, then mute/unmute the other player through the
   scoreboard. Check silence and resumed speech in both directions. Test activity
   mode and its threshold separately if you use it.
3. Change the selected input/output device, then test an unavailable microphone
   and device reconnection. Check the applicable privacy settings. Report failures
   without changing a privacy decision to manufacture a pass.
4. Reconnect each player while the other remains. Verify no stale speech or wrong
   speaker, then use the normal map-vote/defeat lifecycle and check the next map.
   Bank and gameplay behavior must remain normal.
5. Report the map, LAN/WAN scenario, executable hash/protocol and which step
   succeeds or fails. Do not share passwords, complete logs, player identifiers
   or recordings.

For protocol 2, `voice_relay_status` reports bounded aggregate readiness, encoded,
sent, relay/playback, rejection and mute counters. Run it on both clients and the
server if speech fails. Counters increasing cannot prove intelligibility or the
actual output device. `paris_voice_status`, legacy self-tests and synthetic tones
are not the current protocol-2 player acceptance procedure.

The package includes GPL/dependency notices and complete corresponding source.
It includes no game assets or private server scripts/configuration. Protocol 1 is
retained in the executable for historical research; a protocol-1 package is not
interchangeable with this test. No official contribution or accepted tag is made
until the documented validation matrix and owner evidence are complete.
