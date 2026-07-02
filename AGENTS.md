# AGENTS.md - Synergy Public Repository

Synergy is a Perl REPL for talking to AI assistants. It supports interactive
command-processor use and one-shot noninteractive use over stdin.

This file gives public-repository guidance for automated agents.

## Repo Layout

- `synergy` - the single-file Perl program.
- `t/*.t` - focused regression tests.
- `t/lib/` - shared test helpers.
- `t/data/*.xml` - sanitized XML fixtures for dump/load compatibility tests.
- `Makefile` - development, test, install, and distribution commands.
- `README.pod` - generated from POD embedded in `synergy`.

## Commands

Run the full test suite:

```sh
make test
```

Show verbose failing test output:

```sh
prove -lv
```

Useful checks:

```sh
make lint
make critique
make podcheck
```

Regenerate generated documentation after POD/help changes:

```sh
make readme
make man
```

## Editing Guidance

- Keep changes conservative and close to the existing single-file style.
- Preserve command syntax and user-visible REPL behavior unless a behavior
  change is intentional.
- Treat tests as behavioral documentation. Do not weaken assertions unless the
  expected behavior has intentionally changed.
- Do not commit credentials, local runtime logs, private notes, editor backup
  files, or machine-specific generated output.

<!-- eof -->
