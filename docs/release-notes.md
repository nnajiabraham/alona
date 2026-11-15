# Alona 0.1.1

A test build of the rewrite. It replaces 0.1.0, whose Android formatting toolbar had defects found in review: nested bold and italic, formats at a bare caret, formats over several lines, and links with parentheses. Alona records a meeting, transcribes it with a local speech model, and has a local language model write the notes. Nothing about a meeting leaves the device. The only network use is downloading the models once.

This release also carries the clinical app, a white-label patient note-taking app, built once per tenant file under `tenants/`.

## What was run before this release

| Platform | Screens and flows | Real models |
|---|---|---|
| macOS (Apple silicon) | 14 of 14 flows | Lite, Balanced, and Quality. Lite: 4.2% word error rate on a spoken fixture, about 6 s per meeting, idle near 95 MB |
| Web | 8 of 8 flows | Lite in Chrome on WebGPU |
| Android | 8 of 8 flows on an emulator | Lite and Balanced on an 8 GB emulator. Lite: 4.2% word error rate, about 21 s per meeting |
| Linux `.deb` | Flows in a container, arm64 | Not verified. The container had no GPU, so it showed samples |
| Windows | Built on a Mac, never run | Not verified |
| iOS | Not in this release | The build machine's Xcode 27.1 is not licensed yet |

## Know before you install

- Every package is unsigned or ad-hoc signed, so each system warns on first open.
- Accuracy figures come from synthetic voices played as a file. No hardware microphone and no real meeting has been measured.
- On macOS, recording other apps' audio, Zoom and Meet detection, and notifications pass their automated flows with stand-ins, and have not yet been watched working with the real permission prompts.
- Notes from the Lite tier are draft quality.
- The clinical app claims no regulatory compliance. It says what it does. Do not use it with real patients before a review.

The field guide in `docs/explainer/index.html` has the design, every flow with screenshots and video, and the open gaps.
