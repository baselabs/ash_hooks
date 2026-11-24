# 0023: Installer mutation scope

Status: Accepted November 16, 2026.

## Context

`mix igniter.install ash_hooks` edits a host application. It touches the
formatter configuration and the request-processing chain that every request in
the endpoint passes through. A host may already own a body reader that serves
other purposes. [BodyReader](../../lib/ash_hooks/body_reader.ex) documents that
such a host calls `put_raw_body/2` from its own reader instead of adding a
second one.

## Decision

The [installer](../../lib/mix/tasks/ash_hooks.install.ex) makes exactly two kinds
of edit:

- It adds `:ash_hooks` to `import_deps` in `.formatter.exs`.
- In each `lib/**/*endpoint.ex`, it finds the `plug Plug.Parsers, opts` call, in
  any spelling that resolves to `Plug.Parsers`. When `opts` is a literal keyword
  list without `:body_reader`, it adds
  `body_reader: {AshHooks.BodyReader, :read_body, []}`.

The installer preserves the host's existing `body_reader`. For a reader other
than `AshHooks.BodyReader`, it emits a notice to call
`AshHooks.BodyReader.put_raw_body/2` with the complete body.

The formatter import also applies when there is no editable parser call.
Missing `Plug.Parsers` calls and options that are not a literal keyword list
leave those endpoints unchanged and produce a notice with the manual step.
The installer edits no other file, plug or option.

Without Igniter, the task changes nothing and raises with the dependency line to
add and a pointer to the manual setup.

## Consequences

Installing never removes a responsibility the host built. Every case the
installer does not handle tells the host what to do. A host can run the installer
more than once with the same result.
