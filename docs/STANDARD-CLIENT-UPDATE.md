# Habitual standard client: CB compatibility and Aurora updates

The standard Desktop shortcut launches iw7-mod.exe in the base game installation.
The original installed file is not the current Aurora v1.1.0 release asset: its
5402624-byte length and SHA1 A2201FAA028338B99566BE3555767188B2FD25DD match the
CBServers/updater files.json entry exactly. Its SHA256 is
1C2DFF70C555237DC36815BEC522DDA5276B40B0563795CF01E128E9B0C6170D.
The executable contains the CB updater URL and NAT/launcher components. These
facts establish its distribution lineage, not an exact source commit for that
historical build. The old file and shortcut remain recoverable in the local kit.

Use client-profiles.json and Build-StandardClient.ps1 from a verified product
source package. The new source pin de58e0a merges CB develop d9c5dea with official
Aurora develop 37abcb. The CB source contains the NAT traversal, UPnP, friends,
launcher IPC, Discord invite and movement capabilities the plain Aurora build
would remove. One Discord conflict preserves null checking and the existing
parsed token/address queue; secret logging follows upstream's debug-only guard.
The retired CB player_movement translation unit is removed because Aurora's
new gameplay component implements the same nine movement functions and owns the
same hook addresses/dvars/defaults, plus the new jump-penalty path. Compiling both
would install duplicate MinHook detours and fail during startup.

The build refuses dirty tracked source, untracked src files and residual private
Paris translation units. It regenerates the project from the clean CB lineage.
A bounded owned Lua adapter neutralizes upstream machine-name, environment and
copy-to deployment destinations during generation; nonempty client post-build
commands are refused before MSBuild and post-build execution is disabled. The
receipt hashes the adapter, generated project, EXE/PDB and every source file.
Upstream LFS data is unnecessary for native compilation; fresh checkout skips its
smudge downloads and no game assets or private Paris code are uploaded publicly.

The original CB updater endpoint remains unchanged. Add only -noupdate to the
existing ordinary shortcut arguments, preserving its name, target, port27018 and
other arguments. This supported flag prevents the older remote CB binary AND
its data package from overwriting the locally merged profile. Keep future updates
manual: review/advance both public source pins, rebuild, apply the matching data
delta under the same backup/occupancy guards, then update the local receipt.
Do not present automatic remote updates as still enabled for this managed profile.

The official source data delta adds frontend/usermaps.gsc and Usermaps/__init__.lua.
Retain the CB EndGame, MainMenu/MPMainMenu and Patches scripts and other CB data;
copying an entire Aurora cdata package would remove the retained friends UI.
The independent Paris dedicated/VC v2 binary is not this standard client profile.

Native build, frontend initialization and exact installed hashes are technical
validation. Owner gameplay, NAT joins, FPS, WAN and human microphone acceptance
remain separate; no simulated or menu-only witness proves them.
