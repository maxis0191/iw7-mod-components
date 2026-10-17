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
source package. The retained base pin de58e0a merges CB develop d9c5dea with official
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

The 18 October map-transition crash after a Spaceland defeat and a vote for
Attack was traced to the client loading-new-map hook. Its twelve-byte far jump
overwrote the continuation that the generated stub resumed at entry plus five
bytes. The crash dump confirmed the installed far-jump bytes; the generated
stub's continuation lies inside that overwritten span. Native successor
`13adfd0aba11b4173a8deac04d6e31194fc927af`
retains the CB/Aurora merge and changes that entry to the five-byte near jump;
the existing hook utility allocates a nearby trampoline when needed.
Decoding the dump from the declared continuation reaches the exact fatal
instruction through the overwritten bytes. This establishes the bad transition
path without claiming that the dynamically allocated stub or a complete game
call stack was captured.

The standard-client builder now refuses a far jump, unknown entry address,
changed stub or unknown continuation before project generation. The build
receipt records the reviewed five-byte entry and continuation. Fixture tests
reproduce the old width mismatch and preserve unrelated far jumps. Source and
build checks remain separate from a successful occupied Spaceland-to-Attack
rotation and owner gameplay acceptance, which are pending for this correction.

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

Installed qualification (18 October 2026): the CB-preserving binary is installed
as iw7-mod.exe and iw7-cb-aurora.exe in the existing game root. The habitual
iw7-mod shortcut retains its name, working directory, port and original arguments,
with -noupdate added, and targets the separate iw7-cb-aurora.exe. The external
CB Launcher remains unchanged and may replace its own iw7-mod.exe distribution;
its current manifest does not manage the separate executable. Its updater only
removes previously cached manifest names inside declared data folders, so unknown
root executables are preserved. No global updater setting or BO3 setting changed.

Both installed profiles carry receipts; recovery kit aurora-update-20261017 holds
old executable, shortcut and cdata hash inventory. Existing CB data hashes are
unchanged; only the two official Usermaps files were added. Frontend startup
loads both CB menus and Usermaps. Real invitations/NAT joins remain unqualified.
