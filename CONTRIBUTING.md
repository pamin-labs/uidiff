# Contributing

Thanks for helping. uidiff follows the usual open-source flow: open an issue or a pull request on GitHub, and every change is reviewed and must pass CI before it merges.

## Before you open a pull request

1. Build with the Zig version pinned as `minimum_zig_version` in `build.zig.zon`.
2. Read [AGENTS.md](AGENTS.md): it holds the layout, the layer rules the tests enforce, and the gates.
3. Run the [repository gates](AGENTS.md#gates) locally.
4. A behaviour change updates the tests in the same pull request. For performance claims, rotate before and after runs of `zig build bench`, report the medians, and name the hardware. The sample count is `rounds` in `bench/main.zig`.
5. Fixtures are synthetic and generated: change `tests/fixtures/` and run `zig build fixtures`; never commit a real screenshot.

## Commits and pull requests

- Commits and pull request titles use [Conventional Commits](https://www.conventionalcommits.org/) with a scope, for example `fix(codec): refuse 16-bit headers past the budget`, at most 72 characters.
- One logical change per commit; each commit builds and passes the tests on its own. Refactors, behaviour changes and formatting go in separate commits.
- The description says what changed, why, how it was verified, and any follow-up.
- Pull requests are merged without squashing, so every commit is kept.

## Licence

By contributing you agree that your contribution is licensed under the MIT License in [LICENSE](LICENSE).

## Stack traces for bug reports

For a panic with a stack trace, temporarily remove the `pub const panic = std.debug.simple_panic;` declaration from `src/cli.zig`, then run `zig build -Doptimize=debug`. Reproduce the issue with `zig-out/bin/uidiff` and include the trace in the report.
