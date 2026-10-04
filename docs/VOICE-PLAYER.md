# Zombies voice: quick setup

For Windows 10/11 x64 with Infinite Warfare installed. Both players and the server
must use this same protocol-2 package. Second-PC compatibility is still being tested.

## Install

1. Extract the entire ZIP. Close your game.
2. Open PowerShell in the extracted folder and run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-VoiceClient.ps1 -GameRoot "D:\Games\Infinite Warfare"
   ```

   Replace the path with your game folder containing `iw7_ship.exe`.
3. In that game folder, run **Start-IW7-Zombies-Voice.bat**.
4. Join **Private Testing Server** using the server address/password supplied by
   the owner. Enable voice and check your microphone and voice-key binding.
   Use headphones; allow the game through Windows Firewall if prompted.

The installer preserves the official launcher, profiles and game data.

## Test together

- Speak in both directions. Release the voice key: speech must stop.
- Mute/unmute each other, then disable/re-enable voice: check silence and recovery.
- Reconnect each player and change maps: speech should resume with the correct speaker.

If it fails, report the failed step and map; run `voice_relay_status` in the console.
Keep passwords and complete logs private.

This is a private beta using the server's existing UDP port, not an official release.
