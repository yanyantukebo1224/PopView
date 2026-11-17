# PopView Architecture

## Processing pipeline

1. Import manga pages from Files or Photos.
2. Detect panels, speech balloons, text regions, and candidate speakers.
3. Run OCR and let the user correct text, reading order, and speaker assignment.
4. Associate each character with a locally stored voice profile and permitted reference audio.
5. Generate speech locally with a Core ML-compatible TTS runtime.
6. Obtain word/phoneme timing, or align generated audio to text when timing is not exposed by the TTS runtime.
7. Render karaoke-style text highlighting synchronized to audio playback.
8. Animate original artwork with masks, expression assets, depth maps, and camera transforms.

## Proposed Apple frameworks

- SwiftUI: application UI and reader navigation.
- Vision / VisionKit: text recognition and image analysis.
- Core ML: local ML inference, subject/depth models where compatible.
- AVFoundation: audio playback, scheduling, and waveform/timing utilities.
- Metal: custom depth/parallax rendering when needed.
- Core Animation: lightweight bubble, subtitle, and camera animations.
- PDFKit: local PDF page rendering.

## Important implementation boundaries

- TTS output timing must be measured or aligned; do not assume character-level timestamps are automatically available.
- A 2D image does not contain hidden pixels behind a foreground subject. Layer separation may require inpainting or user-provided correction assets.
- Core ML model conversion does not guarantee that every model operator, custom layer, or dynamic shape is supported. Validate the exact model on target devices.
- Keep model weights out of Git until their redistribution license and size strategy are confirmed.
- Keep all processing offline by default; no analytics or upload pipeline is required for the core experience.

## Milestones

### M0 — App shell
SwiftUI app, local image import, preview, and project build.

### M1 — Manga ingestion
Multi-page library, PDFKit, page ordering, local persistence.

### M2 — Speech analysis
Balloon detection, OCR, reading order, editable speaker assignment.

### M3 — Voice
Character voice profiles, Core ML runtime spike, local audio cache.

### M4 — Karaoke reader
Timed word highlighting, bubble focus, audio controls.

### M5 — Motion
Mouth/eye masks, depth estimation, parallax and camera movement.
