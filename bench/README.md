# README benchmark

The comparison table in the project README is a snapshot of four CLI tools on
115 real and synthetic screenshot pairs. The pairs cover unchanged captures,
edits in place, insertions, removals and moved content. The ground truth was
hand-checked against the before and after captures. It records the expected
change regions and, for 56 moved cases, their vertical offsets.

- A pair scores as exact when its expected changes are all found and there
  are no extra boxes. A spurious box marks content with no ground-truth
  change. The move score counts cases where the tool finds the expected
  displacement. A tool without displacement output has no move score.
- Tools that produce pixel masks are scored after grouping their marked pixels
  and merging nearby groups using uidiff's merge distance at the capture
  scale. uidiff's own regions are scored directly. This gives the tools a
  shared unit of comparison, a region box.
- The timing run used the same 2560×1600 pair for each tool on an Apple M4.
  Each comparison launched a fresh CLI process, including Node startup for
  Iris and pixelmatch. uidiff wrote its JSON report without rendering a sheet.
  The table reports the median of 15 rounds, rotating tool order between
  rounds. CPU time is user plus system time. Peak memory is resident memory
  for the CLI process. The install row reports tool size with Node listed
  separately where it is required.

The full comparison corpus and raw results are outside this repository. The
committed [synthetic pairs](../tests/fixtures/README.md) provide separate,
reproducible fixtures for the uidiff benchmark. Run `zig build bench` to
measure decode, compare, sheet rendering, the file pipeline and peak RSS.
Use `-Dbench-before=before.png -Dbench-after=after.png` for a local pair,
adding `-Dbench-scale=2` if it was captured at 2×.
