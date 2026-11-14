# Portable offline campus projects (V12)

A venue project is an Android-shareable `.arnav.json` file with the
`ar_campus_nav.project.v1` schema. This is a data file, **not an APK**.
A recipient needs the AR Campus Nav app installed but does not rebuild it.

## What travels with the file

- Project ID, name, active XYZ venue graph, floor labels, edges and stair/elevator transitions
- Named destinations, QR checkpoint IDs and any already-saved offline visual reference images and poses
- Original walking recordings and marker metadata (including drift checks)
- Coordinate system and applied recording IDs

Android private file paths, a live ARCore world and camera-tracking state do not
travel with the file. Receiving a valid project file does not establish camera
orientation or position in the physical building.

## Phone A: create and share

1. Home → **REVIEW SAVED MAPPINGS** → **CREATE NEW CAMPUS PROJECT**; name it.
   New projects get independent, stable IDs.
2. Home → **V11 • OPEN CAMPUS 3D MAPPER**; walk, tag rooms/QR references and
   stairs, finish and save the 3D route. Return to Saved Mappings, open that
   recording and **PUBLISH 3D CAMPUS GRAPH**.
3. Saved Mappings → **SHARE MAPPING PROJECT** for Android's share sheet.
   Alternatively **SAVE PROJECT FILE (.ARNAV.JSON)** to a local folder.
4. Send the resulting file by your preferred channel (Bluetooth, messaging,
   storage transfer, etc.). The app does not require a cloud account.

## Phone B: import and verify

1. Install the same compatible Android app build.
2. Save/download the shared `.arnav.json` file.
3. Home → **REVIEW SAVED MAPPINGS** → **IMPORT SHARED PROJECT FILE**.
   Confirm the displayed name, graph size, QR checkpoint and recording counts.
4. Verify the same floors, rooms, XYZ geometry, saved QR IDs and route preview.
   Close and reopen the app: the imported project should remain selected.
5. In Saved Mappings use **SWITCH SAVED PROJECT** to switch between projects.
6. Turn off internet on both phones and repeat route **planning** to prove
   the data path is offline.

If an import has the same project ID as a local project, the app explicitly
asks to replace that graph and keeps a previous-graph backup. Import aborts
rather than overwriting a walking recording with a colliding ID and different
contents.

## Separate physical-localization test (not certified by V12)

A printed QR/location tag can identify a node, but a QR ID alone cannot
relocalize another phone's ARCore camera to the stored metric XYZ frame.
A virtual-only QR is not a physical object another camera can scan. Live AR
guidance must stay gated until an offline environment/marker localization
method estimates and verifies a rigid pose transform on the receiving phone.

To claim cross-device live AR guidance, test at minimum:
- Phone A map → fully close → reopen and relocalize at a known checkpoint
- Phone B import → independently relocalize at the same physical checkpoint
- Check rendered line position and facing at several known fixed landmarks
- Repeat after camera tracking loss, turning corners and traversing stairs
- Test two distinct ARCore-supported Android models, and report errors honestly

This release targets project files on Android. It does not add iOS support
or guarantee that all Android phones support ARCore.
