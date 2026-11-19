# Haxe Dump Opener

Jumps to the `-D dump=pretty` output for the Haxe type under the cursor.

Then right-click in a `.hx` editor / file tab / explorer entry, or run it from the command palette:

- **Haxe: Peek .dump for Class** — the dump opens inline under the cursor, `Esc` to dismiss.
- **Haxe: Open .dump for Class** — opens it as a normal tab.
- **Haxe: Open .dump for Class to the Side** — opens it in a split, next to the source.

Dumps only exist if the build sets `-D dump=pretty`.

Hovering a type name that has a dump also shows a link that opens it (`haxeDump.hover`, default `true`).

Each type that has a dump also gets a CodeLens row on its declaration line (below its doc comment and metadata): **Peek .dump** · **Open .dump**, with the dump's path and age in the tooltip. Since dumps aren't written by every build, the row adds **stale .dump** when the file has unsaved edits or was saved after the dump was written. It only compares the type's own file, so a dump stays unflagged when only a macro or a dependency changed (e.g. `NodeMacros.hx` for nodes). The row updates when a rebuild rewrites the dumps. `haxeDump.codeLens` (default `true`) turns it off.

**Haxe: Rebuild .dumps** (or clicking **stale .dump**) compiles an hxml from the workspace root with `-D dump=pretty`, as a task with its output in a terminal. The palette command asks which hxml when there are several; a lens click reuses the last one. Its `-js` output goes to a temp folder, so the project's own build output is untouched and only `dump/` changes; the hxml's other side effects (macros writing caches) happen as in any build. It's a cold compile, not one on a compilation server: vshaxe's server would lose its completion cache, and a build server would keep a second cache context for the extra define. Only `-js` builds are supported.

Long dump lines are wrapped for reading: any `(` `[` `{` group that doesn't fit gets one element per line, so e.g. a `__descriptors` array lists one entry per line. It's a read-only view that refreshes whenever a rebuild rewrites the dump; the file on disk is untouched. `haxeDump.wrapWidth` (default 120) sets the width, `0` opens the raw file. `haxeDump.wrapDepth` caps how many bracket levels get broken (`1` = one entry per line, entries kept whole; default `0` = no limit). Metas in `haxeDump.wrapSkipMeta` (default `[":value"]`) keep their arguments on one line.

## Metadata docs

Hover and `@` / `@:` completion for a library's own metadata, which Haxe itself shows no docs for. A library documents its metadata in a `haxe-metadata.json` in its root: an array in Haxe's [metadata description format](https://github.com/HaxeFoundation/haxe/blob/development/src-json/meta.json) (`metadata`, `doc`, optional `params`). `haxeDump.metaHover` and `haxeDump.metaCompletion` (both default `true`) turn the hover and the completion off.

An entry whose `params` is a single `{…}` takes one structure: completing its name inserts `@:name({})` with the cursor in the braces and opens the suggestions there, and typing `(` after the name offers the braces. The keys themselves come from the compiler (for the wrench editor's metadata, its macros). `haxeDump.metaBraces` and `haxeDump.metaBracesOnParen` (both default `true`) turn the two off.

The files are found through the active Haxe configuration's classpaths (vshaxe), so only libraries in that configuration count: the wrench editor's metadata is documented while `build-debug.hxml` is selected. Don't also register the file with the compiler (`registerMetadataDescriptionFile`): vshaxe would then list every entry a second time, without its doc.

## Building

Written in Haxe against the [vscode externs](https://vshaxe.github.io/vscode-extern/). One-time setup:

	haxelib newrepo
	haxelib install build.hxml --always

Then `haxe build.hxml` (or `./install.sh`, which builds and packages a `.vsix`).