# Original convex boxes — experimental native provider

This candidate creates the eight corners of a box in the game's native Havok
factory, then uses the retail capsule body-instantiation path with a scoped
replacement shape. It does not generate `havokWorldShapeData`, a new map, an
HKX archive, a trigger, or an analytic replacement for engine traces.

## Current evidence

Source inspection identified the strided-vertices factory and its 56-byte
configuration constructor in the retained, already patched IW7 code snapshot.
The native capsule factory calls that same factory after generating vertices.
The code converts local corners by the wrapper's observed 1/32 scale. The
capsule body path preserves the returned shape's allocation header and uses
the normal body creation, world insertion and reference-release code.

The retained trace decoder's exact switch table maps reference system 0 to
world entity 2046. The body therefore uses world reference 0 in both server
and client worlds. The script-model number is a teardown owner, not the hit
or prediction reference. This avoids a guessed server/client entity-ref ABI;
fresh traces and movement still have to qualify the result.

Twelve pure PowerShell checks pass: profile refusal before admission, exact
source selection, removal of an unchanged disabled overlay and preservation
of an independently edited overlay. The C++ geometry test is prepared but has
not been compiled. No provider executable, fresh engine trace, sweep, player
collision, client prediction or lifecycle acceptance has been obtained yet.

The earlier proposed sphere-body adapter was rejected during source review:
it rewrites a 128-byte allocation header, which is unsuitable for a variable
size convex shape. It was never compiled or executed. The capsule adapter
avoids that overwrite. Retained unwind chains were followed; the first unwind
fragment alone is not treated as the complete function.

## Dependencies and limits

The eight corners are original geometry. Body properties and a physics material
come from the game's already loaded default `PhysicsAsset` at the qualified
binding; the provider does not load a donor map or copy a stock HKX. A fresh run
must record that template's actual name and verify the instantiated body's
contents, static/sensor behavior, traces and movement. Entry signatures are
checked before installing the hook; they are a refusal guard, not ABI proof.

The runtime flag is `-paris-collision-provider`, together with
`-paris-isolated-lab`. Without the provider flag no collision bindings, hook,
commands or GSC methods are installed. The dedicated must also be loaded,
bound to `127.0.0.1`, password protected and `sv_lanOnly=1` before creation.
Use the existing heartbeat-suppressed private test profile and complete shared
resource ownership. Main UDP27016 and an occupied owner client are preserved.

This first API permits dedicated worlds 0/1 only; the current GSC method
creates world 0. Client activation returns before bindings/hooks/commands and
client creation is also refused by the allocation policy. A ready client world
and launch flags cannot establish its current private endpoint or generation.
Independent review found that the server VM pre-shutdown callback would leave
client records containing IDs and asset pointers across disconnect/map reset.
Clearing those against a recycled world could destroy somebody else's body.
The correction refuses clients while the real pre-reset client lifecycle and
loopback/private connection are investigated. It does not clear stale pointers
or treat a server callback as client cleanup.

It does not replicate colliders automatically or prove player prediction.
Explicitly clear a model's boxes before deleting it. The dedicated's existing
pre-shutdown callback also clears owned instances. Server/client reset lifetime
and epoch validation remain required before any claim of persistent map support.

## Creator interface

Build the reviewed isolated Modules profile with `Build-Voice.ps1
-ServerModules -IsolatedLab -CollisionProvider`. Its manifest declares
`CollisionProvider: true` and includes `collision_provider.cpp` and
`collision_provider.hpp` in addition to the ordinary 34 sources (39 with the
debugger). A false or absent declaration retains the historical inventory.
The server package checker accepts the explicit 36/41-file variant. The
historical native958 image and SourceTip's strict 34-file pin are unchanged.

After the engine has loaded the private scenario, an owned script model can
request an independent box with world-coordinate minimum and maximum:

```c
floor = spawn("script_model", (0, 0, -8));
floor solid(); // Retail contents and entity linking; still no shape until below.
instance = floor collision_createbox((-256, -192, -16), (256, 192, 0));
// Keep the same entity until its boxes have been removed.
floor collision_clearboxes();
floor delete();
```

Rendering remains the asset/World product's responsibility. A `setmodel` is
optional for this collision probe and is not evidence of a collision asset.
Console commands, dispatched on the owning engine thread, are:

```text
collision_box_create <world> <script-model entity> <minX> <minY> <minZ> <maxX> <maxY> <maxZ>
collision_box_probe <world> <instance>
collision_box_clear
```

The probe logs results returned by `PhysicsQuery_LegacyTrace`, including
fraction, normal, contents, hit type/ID, startsolid and allsolid. Its point
path crosses the box top from +80 to -80. Its second query passes engine
bounds with half sizes (15,15,36) from +80 to +20. This query's actual shape
and margin must be identified before comparing it to World's AABB oracle.

## Next decisive test

Compile the pure geometry test and the provider against pinned upstream
77e6d4d, then build a separately identified candidate under the parent's heavy
workload slot. Do not reuse native958's executable or runtime evidence.
First create one elevated box in a zero-client private dedicated and inspect
real engine traces plus removal. Keep the point fraction 0.5 and the AABB
oracle 44/60 as expectations, not measured outcomes. Qualify the actual client
pre-reset lifecycle, generation binding and loopback/private endpoint before
reenabling client creation. Then mirror the box into the protected rendering
client, establish fresh engine godmode/inactivity0/sv_cheats0 and observe standing,
falling, contact and movement. Preserve any failed build/run and update this
record with the exact candidate and results.
