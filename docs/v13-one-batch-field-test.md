# V13 field test: one batch, two offline phones

## Scope and honest success criteria

This pass verifies the new visual checkpoint workflow in a **single-floor**
corridor. It does **not** claim full-campus drift correction, cross-floor
relocalization, third-party iOS support, or independent 3D graph merging.

A build passing CI means the software compiles and tested transformations
round-trip. Only this field test can establish whether ARCore recognizes
someone else's saved scene and places a line in the right corridor.

### Setup

- Phone A and B: two different ARCore-compatible Android phones if possible,
  both running this branch's APK
- Airplane mode ON after sharing/importing the project
- An easily recognizable 10–20 m corridor with distinct door/sign/wall
  patterns, no crowds, and one clear destination at the far end
- **Do not** use repeating tiles, mirrored glass, or a patternless wall as
  the saved visual image

### One continuous mapping pass on Phone A

1. Start a fresh campus project. Open the unified 3D mapper.
2. START CONTINUOUS 3D RECORDING and allow tracking to stabilize.
3. At the first entrance **PLACE OFFLINE START CHECKPOINT** and name it
   `West Entrance`. In the live AR placement view, place the virtual QR
   on a stable visible surface. Aim the camera straight at a distinctive
   real-world door/sign/wall patch and SAVE START AREA, then SAVE CHECKPOINT.
4. Return to the last trusted path point before RESUME if the mapper paused
   because you moved during the visual capture.
5. Walk 6–10 m, place a second checkpoint `East Entrance` on a different
   distinctive surface, ideally facing a different direction. Repeat capture.
6. Continue to the end, TAG ROOM / STAIR / LOCATION → Room, and name it
   `Corridor Destination`. FINISH & SAVE 3D ROUTE.
7. Open Saved Mappings, open the finished recording, PUBLISH 3D CAMPUS GRAPH.
   Confirm two QR/visual checkpoints and one named destination appear.
8. SHARE or SAVE the `.arnav.json` file; inspect the saved mapping preview
   for discontinuities where the checkpoints were placed.

### Phone B: independent new-session navigation

1. Install the app, import the shared file from Saved Mappings.
2. Confirm correct project title, two checkpoints, same destination, floors
   and route preview. Restart the app: the imported project should still be
   selected. Turn off internet.
3. Choose `West Entrance` as the start on Home, select Corridor Destination,
   then START AR & FIND START.
4. Aim the camera at the SAME distinctive detail captured at West Entrance.
   Do not walk until AR shows **START LOCKED**, not just a progress percentage.
   Verify the line starts near the real corridor and faces the correct way.
5. Close the app. Choose `East Entrance`, repeat. Confirm the line has a
   different, physically correct orientation; no manual compass calibration.
6. Deliberately point at an incorrect wall or hide its detail: it should
   **not** claim a successful lock. Pause tracking during a walk: it should
   stop guiding rather than show a floating false route.

### Send all results together

Use one message, even for multiple failures. Put actual reproduction steps
next to each failure, and include relevant photos, one phone screen recording
and `COPY DIAG` output from the offline visual scan where available.

```
V13 TEST BATCH
Phones + Android versions:
Map exported/imported: YES/NO
#1 Recording before/after checkpoint: PASS/FAIL + what moved
#2 Two checkpoints published: PASS/FAIL
#3 Phone B import/restart/offline: PASS/FAIL
#4 West start scene lock: PASS/FAIL + screenshot/video
#5 East start scene lock: PASS/FAIL + screenshot/video
#6 Route direction and real-world endpoint: PASS/FAIL + offset
#7 Wrong-scene rejection/tracking-loss: PASS/FAIL
Other problems:
What I expected vs what happened:
Relevant logs:
```

One pass should return enough evidence to fix several defects together.
Only re-test affected features after each code revision; do not repeat the
whole campus walk until the mapped data schema actually changes.

### Blockers and limits

The native scene image resolver is ARCore Augmented Images with local captured
visual references. It does **not** require an internet service. Lighting,
perceptual ambiguity, camera quality and limited image size can still prevent
recognition. A virtual QR cannot be scanned by another camera until that
camera has localized against a recognizable real physical scene.
