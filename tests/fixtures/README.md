# Synthetic screenshot fixtures

`zig build fixtures` renders the fixture pairs with Zig from a fixed seed and copies them into `images/`. The renderer draws a header, sidebar, rows of text-like bars, and rectangular inputs. The phone and desktop sizes, the device scale and the light and dark variants are listed in `cases.zig`. Each insertion layout gains a block near the top of its viewport. Two same-height pairs add or remove a banner at the top of the viewport. A changed input and an identical pair act as controls. `claims-16-bit-giant.png` is a one-pixel PNG whose header the generator rewrites to claim a 16-bit image past the decode budget; the decoder must refuse it before allocating.

The generator uses the pinned stb encoders for PNG and quality-100 JPEG and the pinned libwebp encoder for lossless WebP, through their own translated headers, separate from the decoders'. It builds scalar WebP encoding and disables floating-point contraction in both encoders for reproducibility. The expected JSON comes from the drawn geometry and includes the padded region boxes.

`zig build test` regenerates the set into the build cache and fails when any committed file differs. `tests/fixtures.zig` re-exports `cases.zig` for the build script and the tests. `unsupported.txt` covers unknown file formats. The oversized file test creates its own sparse file at runtime.
