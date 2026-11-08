# Frame evidence measurements

`ops/iw7_frame_evidence.py` measures in-game captures deterministically, so an
agent opens a frame only when the question is genuinely visual (look, mood,
pose, readability). It is offline and read-only: no game, server, client,
lease or network is touched. Requires Pillow and numpy.

## When to use it

| Question | Instrument |
| --- | --- |
| Can these captures answer anything? (black, blank, frozen, duplicate) | `frames` before any vision review |
| Did anything move or draw between two captures? | `frames` (`vs_previous`, `max_change`) |
| Does the test effect/model draw where the control does, and how strongly? | `diff control test --roi x,y,w,h` |
| Does it look right, read as a shipped asset, carry the mood? | Vision review (unchanged) |
| Is geometry floating, intersecting, on the rails, untextured? | Source-level lint of the generated level, then vision review |

## Usage

```powershell
python -B ops/iw7_frame_evidence.py frames <evidence>\result.local.json --json frames.json
python -B ops/iw7_frame_evidence.py frames <capture dir> <more dirs or frames>
python -B ops/iw7_frame_evidence.py diff control.png test.png --roi 800,400,320,240 --mask change.png
```

`frames` accepts frame files, directories, a witness `result.local.json`
(schema `iw7.bo3wpn-visual/1`; one sequence per scenario) or a vision
`index.json`. Exit code 1 means at least one sequence is `SUSPECT`; 2 is an
input error. Per frame it records luma statistics, black/clipped fractions,
saturation, a pixel SHA-256 (decoded pixels, not file bytes) and a 64-bit
difference hash, plus the change since the previous capture of the same
sequence. Flags: `BLACK` (95% of pixels below 0.03 luma), `UNIFORM`
(luma deviation below 0.01), `CLIPPED`, `MISSING`, `IDENTICAL_TO_PREVIOUS`
(no channel differs by more than 2/255) and `STATIC_SINCE_PREVIOUS` (under
0.1% of pixels changed by more than 12/255). A sequence is `SUSPECT` when a
frame is unusable or every capture repeats the previous picture.

`diff` reports the changed fraction, mean and maximum difference, luma delta,
the bounding box of the change and the mean colour of the changed pixels in
the control and in the test. The region is in full-frame pixels.

## Measured on retained evidence (2026-11-08)

- 101 passed BO3 weapon witness runs (549 frames, 185 scenario sequences,
  75 s): no black, blank, frozen or duplicate capture. Their weapon evidence
  was valid; its cost lay in repeated in-game runs, not in bad frames.
- 80 Station Zero/Kino capture sequences (80 s): 24 `SUSPECT`; 20 of them
  were entirely black with every view pixel-identical (custom map bring-up),
  the rest had one black view.
- The nine BO3 FX probe runs of 2026-11-07: when converted effects drew, the
  change between consecutive captures was 15-73%; when nothing drew it stayed
  at 2-4% ambient. The probe that an agent read as contradicting an earlier
  one measured 2%, i.e. nothing drew in it, a number available without vision.

## Rejected: a pixel placeholder/void detector

A detector of large textureless regions (void, flat bright, magenta) was
built and calibrated on 2564 Station Zero frame quadrants (g24, g25) against
the 192 quadrants that vision reviewers localised defects in. Best ranking:
AUC 0.70 for placeholder/void classes using dark textureless area; bright flat
area was anti-correlated (AUC 0.35-0.43) because lit walls and ceilings are
flat. As an attention hint it fired on 75% of all quadrants. It was removed.
Geometry and material faults belong to the generator's lint; look and mood
stay with the vision reviewers.
