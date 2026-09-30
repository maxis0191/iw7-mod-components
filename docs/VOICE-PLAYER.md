# Paris Zombies voice test build

This is a private modified Aurora client, not an official supported Aurora release. It implements voice for dedicated Zombies. Multiplayer voice is not implemented. The official launcher remains usable. Do not let the updater replace the custom executable: the supplied launcher uses `-noupdate`.

## Install and launch

1. Extract the package into a separate folder. In PowerShell run `./Install-VoiceClient.ps1 -GameRoot 'YOUR EXISTING GAME FOLDER'`. If local script execution is restricted, manually copy `iw7-paris-voice.exe` and `Start-IW7-Zombies-Voice.bat` beside `iw7_ship.exe`; the executable's SHA-256 must match `build-manifest.json`. Preserve any previous custom build first.
2. Launch `Start-IW7-Zombies-Voice.bat`, open Zombies and join **Paris Server (Beta Phase)**. Every participant who speaks or listens needs this exact build. Existing official clients can still join gameplay but cannot participate in this custom voice relay.
3. In the base game's audio settings, enable voice chat, select the intended microphone/playback device and configure push-to-talk. Check the actual voice key binding; do not assume a key. Windows microphone permission and device availability still apply. This build preserves normal voice settings.

No extra router port, account, audio application, recording service or client `-allow_root_io` flag is required. Use the included launcher without development-test flags. A new executable may trigger Windows Firewall's ordinary network-access prompt; the owner controls those permissions.

## Owner acceptance

Use two real players on different machines, ideally with one outside the server's LAN. Both use this build and headphones.

1. Speak a short sentence in each direction while holding the configured voice key. Verify intelligibility and normal gameplay audio together.
2. Release the key: speech must stop. Disable voice chat, then re-enable it. Test voice activity mode if you use it.
3. Mute the other player using the scoreboard: their voice must stop; unmute must restore it. Check both directions.
4. Disconnect/rejoin, then play through one definitive defeat/map vote and verify voice on the next map. Bank/gameplay behavior must remain normal.
5. If any step fails, run `paris_voice_status` in the mod console on both clients and record whether `client_ready`, `capture`, `sent`, `decoded`, `queued_bytes` and `queue_errors` change while speaking. Share the outcome with the owner; avoid sending unrelated logs, player identifiers or audio recordings.

`paris_voice_selftest` checks the actual codec. `paris_voice_network_test` plays a brief synthetic calibration only back to its own client; it is not a real microphone or two-player speech test. No audio is recorded by the added component.

The package includes the upstream GPL license and complete corresponding source with dependencies in `corresponding-source.zip`. It contains no game assets or Paris gameplay scripts. Owner gameplay acceptance remains pending until real-player results are supplied.
