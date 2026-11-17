# V17 — one-camera, two-floor offline AR field test

## Scope
This tests the **first** measured 3D staircase navigation candidate. It does not
certify cross-device localization or campus-scale accuracy. Use the installed
V17 build, based on V16. Export/back up any important mapping before installing.
Do **not** wipe app data to simulate a second phone.

## Prerequisites
- An already **PUBLISHED** continuous 3D map with Floor 1 → Floor 2 stairs,
  full measured XYZ samples and at least one saved visual checkpoint on the start
  node; an existing V14/V16 completed recording works if published.
- The Floor 2 endpoint is a saved named endpoint, a tagged room, or the
  provisional `Floor 2 - recorded route end` from V16.
- The exact original distinctive physical wall/sign/door scene is available
  near the entrance. No GPS, internet connection or printed QR is required.

## One-phone test, with one consolidated video/report
1. Open **Home** and confirm it shows your published 3D map (not bundled
   sample). Select **Main Entrance** as start.
2. Select **Floor 2** and choose the named/provisional route end.
   **Route Preview** should state `V17 ONE-CAMERA 3D CLIMB` and offer
   **START CONTINUOUS 3D AR • FLOOR TO FLOOR**. If disabled, record the
   reason; don't force a legacy manual alignment.
3. Restart the AR camera and look at the **same physical entrance scene**
   saved during mapping. Observe actual progress toward visual lock. The
   blue ribbon must NOT appear before verification succeeds.
4. After lock, while stationary, observe the ribbon continuing from the
   entrance toward the real staircase, rather than appearing on a random
   floor or rotated 90/180 degrees.
5. Observe the ribbon/stair HUD from safe stationary spots at **bottom,
   mid-landing, and top**. It should visibly rise with saved XYZ, announce
   ascent toward Floor 2, and keep the SAME camera session. **Do not use
   your phone while stepping on stairs**; pause to check safely.
6. At the Floor 2 endpoint check that arrival occurs only near the actual
   upper end (not beneath it on Floor 1 at the same 2D XY position).
7. Test the **wrong scene** and **tracking pause** cases, if safe. No AR
   guidance should appear before start lock or after an uncertain pose.
8. Optional reverse test after adding a verified upstairs visual checkpoint:
   start upstairs → choose a downstairs destination → the ribbon descends.

## Expected limitations
- Because the first image match has not yet been validated on a second
  device, physical placement can still be wrong. Visual recognition is
  NOT the same as proven centimeter-accurate localization.
- Camera height held at different chest/eye levels causes some vertical
  error. V17 uses a fixed camera-at-lock height as the stair progress origin.
- Long route ARCore drift and independently recorded-section 6DoF alignment
  are separate work.
- Mixed old floor maps without measured XYZ are deliberately rejected.

## Report once, not after every button
Send the **version/branch**, phone/ARCore version, video with timestamps,
actual floor heights if known, whether visual lock succeeded, whether the
route rose correctly, whether a landing incorrectly counted as arrived,
whether camera restarted or stopped, and **COPY DIAG** on failure.
Compare route orientation at two physical entrances if you've mapped them.
