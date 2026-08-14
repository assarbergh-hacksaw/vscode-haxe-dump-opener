# Haxe Dump Opener

Jumps to the `-D dump=pretty` output for the Haxe type under the cursor.

Then right-click in a `.hx` editor / file tab / explorer entry, or run it from the command palette:

- **Haxe: Peek .dump for Class** — the dump opens inline under the cursor, `Esc` to dismiss.
- **Haxe: Open .dump for Class** — opens it as a normal tab.
- **Haxe: Open .dump for Class to the Side** — opens it in a split, next to the source.

Dumps only exist if the build sets `-D dump=pretty`.

## Building

Written in Haxe against the [vscode externs](https://vshaxe.github.io/vscode-extern/). One-time setup:

	haxelib newrepo
	haxelib install build.hxml --always

Then `haxe build.hxml` (or `./install.sh`, which builds and packages a `.vsix`).