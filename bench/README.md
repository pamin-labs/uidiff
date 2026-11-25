# README benchmark

The comparison table in the project README is a snapshot of four CLI tools on
115 real and synthetic screenshot pairs. The pairs cover unchanged captures,
edits in place, insertions, removals and moved content. The ground truth was
hand-checked against the before and after captures. It records the expected
change regions and, for 56 moved cases, their vertical offsets.

- The exact-count row counts pairs with the expected number of boxes. A
  spurious box marks content with no ground-truth change. The move score counts cases where the tool finds the expected
  displacement. A tool without displacement output has no move score.
- Tools that produce pixel masks are scored after grouping their marked pixels
  and merging nearby groups using uidiff's merge distance at the capture
  scale. uidiff's own regions are scored directly. This gives the tools a
  shared unit of comparison, a region box.
- The timing run used the same 2560×1600 pair for each tool on an Apple M4.
  Each comparison launched a fresh CLI process, including Node startup for
  Iris and pixelmatch. uidiff wrote its JSON report without rendering a sheet.
  The table reports the median of 15 rounds, rotating tool order between
  rounds. The uidiff column uses a separate remeasurement on the same pair
  and the same rotation. Elapsed time is measured around process launch and
  exit. CPU time is user plus system time and peak RSS is in MiB, both from
  child process usage. The install row reports tool size with Node listed
  separately where it is required.

The full comparison corpus and raw results are outside this repository.
For a local CLI measurement, build with `zig build -Doptimize=safe` and run
`zig-out/bin/uidiff "$BEFORE" "$AFTER" --scale "$SCALE" --json` on your pair.
Count exit statuses 0 and 1 as completed comparisons. On macOS,
`/usr/bin/time -l` reports elapsed time, CPU time and peak RSS per process.
Use `wc -c < zig-out/bin/uidiff` for the file size. The
committed [synthetic pairs](../tests/fixtures/README.md) provide separate,
reproducible fixtures for the uidiff benchmark. Run `zig build bench` to
measure decode, compare, sheet rendering, the file pipeline and peak RSS.
Use `-Dbench-before=before.png -Dbench-after=after.png` for a local pair,
adding `-Dbench-scale=2` if it was captured at 2×.

## README sheets

Build the CLI in ReleaseSafe and pass a corpus directory plus the four pair
directory names. Each pair contains `before.png` and `after.png` at 2× scale.
The renderer writes the sheets under `docs/images/` and runs lossless
`oxipng -o max` on each.

```sh
zig build -Doptimize=safe
python3 scripts/readme-images.py render "$PAIRS_DIR" \
  --desktop-dark "$DESKTOP_PAIR" --phone-insert "$INSERT_PAIR" \
  --phone-settings "$SETTINGS_PAIR" --phone-list "$LIST_PAIR"
python3 scripts/readme-images.py check
```
