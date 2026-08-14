package haxedump;

// Document symbols come back as either DocumentSymbol (has `range`) or SymbolInformation
// (has `location.range`), depending on the provider.
typedef Symbol = {
	final name:String;
	final ?range:Range;
	final ?location:{final range:Range;};
}

typedef UriPick = {> QuickPickItem, final uri:Uri;}

final typeName = ~/^[A-Z]\w*$/;
final firstWord = ~/^\w+/;
final packageDecl = ~/^package\s+([\w.]*)\s*;/m;
final dumpFlag = ~/(^|\s)(-D|--define)\s+dump[=\s]/;

// Outermost document symbol containing pos -> the module-level type the cursor sits in.
// Null when the language server is asleep or the cursor is on imports/package.
@:jsasync function enclosingType(doc:TextDocument, pos:Position):Promise<Null<String>> {
	final syms:Null<Array<Symbol>> = commands.executeCommand("vscode.executeDocumentSymbolProvider", doc.uri).jsawait();
	var best:Null<String> = null;
	var bestHeight = -1;
	if (syms != null)
		for (s in syms) {
			final range = s.range != null ? s.range : s.location.range;
			if (!range.contains(pos))
				continue;
			final height = range.end.line - range.start.line;
			if (height > bestHeight) {
				bestHeight = height;
				best = s.name;
			}
		}
	return best != null && firstWord.match(best) ? firstWord.matched(0) : null;
}

// A capitalised word under the cursor is a type reference (EditorMacros, ImGui, CameraConfig).
// Anything else -> the type the cursor is inside -> the module name.
@:jsasync function targetType(ed:Null<TextEditor>, fallback:String):Promise<String> {
	if (ed == null)
		return fallback;
	final range = ed.document.getWordRangeAtPosition(ed.selection.active);
	final word = range == null ? null : ed.document.getText(range);
	if (word != null && typeName.match(word))
		return word;
	final enclosing = enclosingType(ed.document, ed.selection.active).jsawait();
	return enclosing != null ? enclosing : fallback;
}

// dump/js is what you almost always want; dump/macro holds the same package paths and is
// last resort. Any other target (hl, cpp, ...) sits in between.
function rank(uri:Uri):Int
	return uri.path.contains("/dump/js/") ? 0 : uri.path.contains("/dump/macro/") ? 2 : 1;

@:jsasync function pick(hits:Array<Uri>, pkgDir:String):Promise<Null<Uri>> {
	final sorted = hits.copy();
	sorted.sort((a, b) -> rank(a) - rank(b));
	// Same type name in several packages: narrow to this file's own package when it matches.
	final inPkg = (uri:Uri) -> pkgDir != "" && uri.path.substring(0, uri.path.lastIndexOf("/")).endsWith(pkgDir);
	final scope = Lambda.exists(sorted, inPkg) ? sorted.filter(inPkg) : sorted;

	if (scope.length == 1)
		return scope[0];
	final js = scope.filter(uri -> rank(uri) == 0);
	if (js.length == 1)
		return js[0];

	final items:Array<UriPick> = [
		for (i => uri in scope)
			{label: workspace.asRelativePath(uri), description: i == 0 ? "recommended" : null, uri: uri}
	];
	final chosen = window.showQuickPick(items, {placeHolder: "Multiple dumps match"}).jsawait();
	return chosen == null ? null : chosen.uri;
}

// Nothing found: either the build never had dumps switched on, or it's just stale.
// Only runs on a miss, so no startup or background cost.
@:jsasync function reportMiss(type:String) {
	final hxmls = workspace.findFiles("**/*.hxml", "**/node_modules/**", 50).jsawait();
	// ponytail: flag lookup is per-file; an hxml that only gets it from an included hxml reads as missing
	for (file in hxmls) {
		final text = workspace.openTextDocument(file).jsawait().getText();
		final body = [for (line in text.split("\n")) if (!line.trim().startsWith("#")) line].join("\n");
		if (dumpFlag.match(body)) {
			window.showWarningMessage('No dump for $type — rebuild to refresh dump/.');
			return;
		}
	}

	final choice = window.showWarningMessage('No dump for $type: no .hxml sets -D dump=pretty.', "Add -D dump=pretty").jsawait();
	if (choice == null)
		return;

	var target = hxmls.length == 1 ? hxmls[0] : null;
	if (target == null) {
		final items:Array<UriPick> = [for (uri in hxmls) {label: workspace.asRelativePath(uri), uri: uri}];
		final chosen = window.showQuickPick(items, {placeHolder: "Which build file?"}).jsawait();
		if (chosen == null)
			return;
		target = chosen.uri;
	}

	// ponytail: appends at the end, so on a multi-target hxml it lands in the last --next section
	final doc = workspace.openTextDocument(target).jsawait();
	final edit = new WorkspaceEdit();
	edit.insert(target, doc.lineAt(doc.lineCount - 1).range.end, "\n-D dump=pretty\n");
	workspace.applyEdit(edit).jsawait();
	doc.save().jsawait();
	window.showTextDocument(doc, {preview: false});
}

// The dump for whatever the command was aimed at, or null (having said why).
@:jsasync function resolve(uri:Null<Uri>):Promise<Null<Uri>> {
	final ed = window.activeTextEditor;
	final aimedAt = uri != null ? uri : (ed == null ? null : ed.document.uri);
	final src = aimedAt == null ? null : aimedAt.fsPath;
	if (src == null || !src.endsWith(".hx")) {
		window.showWarningMessage("Not a .hx file");
		return null;
	}

	// Explorer right-click can target a file that isn't the focused editor: no cursor there.
	final cursorIn = ed != null && ed.document.uri.fsPath == src ? ed : null;
	final module = src.substring(src.lastIndexOf("/") + 1, src.length - 3);
	final type = targetType(cursorIn, module).jsawait();
	final pkgDir = cursorIn != null && packageDecl.match(cursorIn.document.getText()) ? packageDecl.matched(1).replace(".", "/") : "";

	// ponytail: 20 is plenty for a type name; bump if a name ever collides more than that
	final hits = workspace.findFiles('dump/**/$type.dump', null, 20).jsawait();
	if (hits.length == 0) {
		reportMiss(type);
		return null;
	}
	return pick(hits, pkgDir).jsawait();
}

// Menu titles are static in package.json, so the hover is where the resolved dump gets named.
@:jsasync function provideHover(doc:TextDocument, pos:Position, token:CancellationToken) {
	final range = doc.getWordRangeAtPosition(pos);
	final word = range == null ? null : doc.getText(range);
	if (word == null || !typeName.match(word))
		return null;
	final hits = workspace.findFiles('dump/**/$word.dump', null, 1).jsawait();
	if (hits.length == 0)
		return null;
	// Own command taking an fsPath: the built-in vscode.open re-parses a string arg as a
	// path, so handing it a file:// URI lands on /workspaces/.../file:///workspaces/...
	final args = haxe.Json.stringify([hits[0].fsPath]).urlEncode();
	final md = new MarkdownString('[Open ${workspace.asRelativePath(hits[0])}](command:haxeDump.openFile?$args)');
	md.isTrusted = true;
	return new Hover(md, range);
}

@:jsasync function open(uri:Null<Uri>, ?column:ViewColumn) {
	final chosen = resolve(uri).jsawait();
	if (chosen != null)
		window.showTextDocument(chosen, {preview: false, viewColumn: column});
}

@:jsasync function peek(uri:Null<Uri>) {
	final ed = window.activeTextEditor;
	final chosen = resolve(uri).jsawait();
	if (chosen == null)
		return;
	if (ed == null) {
		window.showTextDocument(chosen, {preview: false});
		return;
	}
	// Built-in peek widget: the dump renders inline under the cursor line, no custom UI.
	commands.executeCommand("editor.action.peekLocations", ed.document.uri, ed.selection.active, [new Location(chosen, new Position(0, 0))], "peek");
}

@:expose("activate") function main(ctx:ExtensionContext) {
	ctx.subscriptions.push(languages.registerHoverProvider({language: "haxe"}, {provideHover: provideHover}));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.openFile", (path:String) -> window.showTextDocument(Uri.file(path), {preview: false})));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.open", (?uri:Uri) -> open(uri)));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.openToSide", (?uri:Uri) -> open(uri, Beside)));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.peek", (?uri:Uri) -> peek(uri)));
}
