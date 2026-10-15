# Haxe Dump Opener

Jumps to the `-D dump=pretty` output for the Haxe type under the cursor.

Then right-click in a `.hx` editor / file tab / explorer entry, or run it from the command palette:

- **Haxe: Peek .dump for Class** — the dump opens inline under the cursor, `Esc` to dismiss.
- **Haxe: Open .dump for Class** — opens it as a normal tab.
- **Haxe: Open .dump for Class to the Side** — opens it in a split, next to the source.

Dumps only exist if the build sets `-D dump=pretty`.

Long dump lines are wrapped for reading: any `(` `[` `{` group that doesn't fit gets one element per line, so e.g. a `__descriptors` array lists one entry per line. It's a read-only view that refreshes whenever a rebuild rewrites the dump; the file on disk is untouched. `haxeDump.wrapWidth` (default 120) sets the width, `0` opens the raw file. `haxeDump.wrapDepth` caps how many bracket levels get broken (`1` = one entry per line, entries kept whole; default `0` = no limit). Metas in `haxeDump.wrapSkipMeta` (default `[":value"]`) keep their arguments on one line.

## Metadata docs

Hover and `@` / `@:` completion for a library's own metadata, which Haxe itself shows no docs for. A library documents its metadata in a `haxe-metadata.json` in its root: an array in Haxe's [metadata description format](https://github.com/HaxeFoundation/haxe/blob/development/src-json/meta.json) (`metadata`, `doc`, optional `params`).

The files are found through the active Haxe configuration's classpaths (vshaxe), so only libraries in that configuration count: the wrench editor's metadata is documented while `build-debug.hxml` is selected. Don't also register the file with the compiler (`registerMetadataDescriptionFile`): vshaxe would then list every entry a second time, without its doc.

## Building

Written in Haxe against the [vscode externs](https://vshaxe.github.io/vscode-extern/). One-time setup:

	haxelib newrepo
	haxelib install build.hxml --always

Then `haxe build.hxml` (or `./install.sh`, which builds and packages a `.vsix`).