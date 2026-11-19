package haxedump;

// Document symbols come back as either DocumentSymbol (has `range`) or SymbolInformation
// (has `location.range`), depending on the provider.
typedef Symbol = {
	final name:String;
	final ?range:Range;
	final ?selectionRange:Range;
	final ?location:{final range:Range;};
}

typedef UriPick = {> QuickPickItem, final uri:Uri;}
final typeName = ~/^[A-Z]\w*$/;
final firstWord = ~/^\w+/;
final packageDecl = ~/^package\s+([\w.]*)\s*;/m;
final dumpFlag = ~/(^|\s)(-D|--define)\s+dump[=\s]/;

// Dumps open as a read-only wrapped view (see Wrap.hx): same path, so the tab still reads
// Foo.dump, with the real file's URI in the query. The file itself is never rewritten.
final viewScheme = "haxedump";
final viewChanged = new EventEmitter<Uri>();

function wrapWidth():Int
	return workspace.getConfiguration("haxeDump").get("wrapWidth", 120);

function wrapOptions():Wrap.Options {
	final config = workspace.getConfiguration("haxeDump");
	final metas:Array<String> = config.get("wrapSkipMeta", []);
	return {
		width: wrapWidth(),
		depth: config.get("wrapDepth", 0),
		flatMeta: [for (m in metas) m.startsWith("@") ? m : "@" + m],
	};
}

function view(dump:Uri):Uri
	return wrapWidth() > 0 ? dump.with({scheme: viewScheme, query: dump.toString()}) : dump;

@:jsasync function provideView(uri:Uri, token:CancellationToken):Promise<String> {
	final bytes = workspace.fs.readFile(Uri.parse(uri.query)).jsawait();
	return Wrap.wrap(new js.html.TextDecoder().decode(bytes), wrapOptions());
}

function rangeOf(s:Symbol):Range
	return s.range != null ? s.range : s.location.range;

function packageDir(doc:TextDocument):String
	return packageDecl.match(doc.getText()) ? packageDecl.matched(1).replace(".", "/") : "";

// Outermost document symbol containing pos -> the module-level type the cursor sits in.
// Null when the language server is asleep or the cursor is on imports/package.
@:jsasync function enclosingType(doc:TextDocument, pos:Position):Promise<Null<String>> {
	final syms:Null<Array<Symbol>> = commands.executeCommand("vscode.executeDocumentSymbolProvider", doc.uri).jsawait();
	var best:Null<String> = null;
	var bestHeight = -1;
	if (syms != null)
		for (s in syms) {
			final range = rangeOf(s);
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

// Best first. Same type name in several packages: narrowed to this file's own package when it matches.
function candidates(hits:Array<Uri>, pkgDir:String):Array<Uri> {
	final sorted = hits.copy();
	sorted.sort((a, b) -> rank(a) - rank(b));
	final inPkg = (uri:Uri) -> pkgDir != "" && uri.path.substring(0, uri.path.lastIndexOf("/")).endsWith(pkgDir);
	return Lambda.exists(sorted, inPkg) ? sorted.filter(inPkg) : sorted;
}

// The only candidate, else the only dump/js one, else the user's pick.
@:jsasync function choose(scope:Array<Uri>):Promise<Null<Uri>> {
	if (scope.length == 1) {
		return scope[0];
	}
	final js = scope.filter(uri -> rank(uri) == 0);
	if (js.length == 1) {
		return js[0];
	}

	final items:Array<UriPick> = [
		for (i => uri in scope) {
			{label: workspace.asRelativePath(uri), description: i == 0 ? "recommended" : null, uri: uri};
		}
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
	// path, not fsPath: fsPath is backslash-separated when the extension host runs on Windows,
	// which the "/" splitting below would miss. path is always "/" whatever the scheme.
	final src = aimedAt == null ? null : aimedAt.path;
	if (src == null || !src.endsWith(".hx")) {
		window.showWarningMessage("Not a .hx file");
		return null;
	}

	// Explorer right-click can target a file that isn't the focused editor: no cursor there.
	final cursorIn = ed != null && ed.document.uri.path == src ? ed : null;
	final module = src.substring(src.lastIndexOf("/") + 1, src.length - 3);
	final type = targetType(cursorIn, module).jsawait();
	final pkgDir = cursorIn != null ? packageDir(cursorIn.document) : "";

	// ponytail: 20 is plenty for a type name; bump if a name ever collides more than that
	final hits = workspace.findFiles('dump/**/$type.dump', null, 20).jsawait();
	if (hits.length == 0) {
		reportMiss(type);
		return null;
	}
	return choose(candidates(hits, pkgDir)).jsawait();
}

// Menu titles are static in package.json, so the hover is where the resolved dump gets named.
@:jsasync function provideHover(doc:TextDocument, pos:Position, token:CancellationToken) {
	if (!workspace.getConfiguration("haxeDump").get("hover", true)) {
		return null;
	}
	final range = doc.getWordRangeAtPosition(pos);
	final word = range == null ? null : doc.getText(range);
	if (word == null || !typeName.match(word))
		return null;
	final hits = workspace.findFiles('dump/**/$word.dump', null, 1).jsawait();
	if (hits.length == 0)
		return null;
	// Own command rather than the built-in vscode.open, which re-parses a string arg as a
	// path and lands on /workspaces/.../file:///workspaces/... Round-trip the whole URI, not
	// just fsPath: running as a ui extension against a remote workspace, the scheme and
	// authority are what say "the container's /workspaces", not the host's.
	final args = haxe.Json.stringify([view(hits[0]).toString()]).urlEncode();
	final md = new MarkdownString('[Open ${workspace.asRelativePath(hits[0])}](command:haxeDump.openFile?$args)');
	md.isTrusted = true;
	return new Hover(md, range);
}

@:jsasync function open(uri:Null<Uri>, ?column:ViewColumn) {
	final chosen = resolve(uri).jsawait();
	if (chosen != null)
		window.showTextDocument(view(chosen), {preview: false, viewColumn: column});
}

@:jsasync function peek(uri:Null<Uri>) {
	final ed = window.activeTextEditor;
	final chosen = resolve(uri).jsawait();
	if (chosen == null)
		return;
	if (ed == null) {
		window.showTextDocument(view(chosen), {preview: false});
		return;
	}
	peekAt(ed.document.uri, ed.selection.active, chosen);
}

// Built-in peek widget: the dump renders inline under `at`, no custom UI.
function peekAt(doc:Uri, at:Position, dump:Uri)
	commands.executeCommand("editor.action.peekLocations", doc, at, [new Location(view(dump), new Position(0, 0))], "peek");

final lensChanged = new EventEmitter<Void>();
var lensRefresh:Null<haxe.Timer> = null;

// A dump build rewrites every dump at once: one lens refresh for the lot.
function refreshLenses(_:Uri) {
	if (lensRefresh != null) {
		lensRefresh.stop();
	}
	lensRefresh = haxe.Timer.delay(() -> lensChanged.fire(), 300);
}

final relativeTime = new js.lib.intl.RelativeTimeFormat("en", {numeric: Auto});

// Relative, as the extension host's time zone (a container's is usually UTC) needn't be the user's.
function age(time:Float):String {
	final mins = Math.round((time - Date.now().getTime()) / 60000);
	return if (mins > -60) {
		relativeTime.format(mins, Minute);
	} else if (mins > -60 * 24) {
		relativeTime.format(Math.round(mins / 60), Hour);
	} else {
		relativeTime.format(Math.round(mins / (60 * 24)), Day);
	}
}

// A row above each module-level type that has a dump. Dumps aren't part of every build, so it
// also says when the dump can't match this file: unsaved edits, or saved since it was written.
// ponytail: only this file's mtime counts; an edited macro elsewhere (e.g. NodeMacros.hx) leaves the dump looking fresh
@:jsasync function provideCodeLenses(doc:TextDocument, token:CancellationToken):Promise<Array<CodeLens>> {
	if (!workspace.getConfiguration("haxeDump").get("codeLens", true)) {
		return [];
	}
	final syms:Null<Array<Symbol>> = commands.executeCommand("vscode.executeDocumentSymbolProvider", doc.uri).jsawait();
	final lenses:Array<CodeLens> = [];
	if (syms == null) {
		return lenses;
	}
	final saved = workspace.fs.stat(doc.uri).jsawait().mtime;
	final file = doc.uri.path.substring(doc.uri.path.lastIndexOf("/") + 1);
	final pkgDir = packageDir(doc);
	for (s in syms) {
		final type = firstWord.match(s.name) ? firstWord.matched(0) : "";
		if (!typeName.match(type)) {
			continue;
		}
		final hits = workspace.findFiles('dump/**/$type.dump', null, 20).jsawait();
		if (hits.length == 0) {
			continue;
		}
		final scope = candidates(hits, pkgDir);
		final written = workspace.fs.stat(scope[0]).jsawait().mtime;
		final when = age(written);
		final info = '${workspace.asRelativePath(scope[0])}, written $when';
		// The name, so the row sits on the declaration line: vshaxe starts `range` at the doc comment.
		final range = s.selectionRange != null ? s.selectionRange : rangeOf(s);
		lenses.push(new CodeLens(range, {title: "Peek .dump", command: "haxeDump.lensPeek", arguments: [scope, doc.uri, range.start], tooltip: info}));
		lenses.push(new CodeLens(range, {title: "Open .dump", command: "haxeDump.lensOpen", arguments: [scope], tooltip: info}));
		if (doc.isDirty || written < saved) {
			final why = '$file changed after this dump was written ($when). Click to rebuild the dumps.';
			lenses.push(new CodeLens(range, {title: "$(warning) stale .dump", command: "haxeDump.rebuild", arguments: [false], tooltip: why}));
		}
	}
	return lenses;
}

// Lens clicks get the dumps the lens was built from, so no cursor guessing.
@:jsasync function lensPeek(scope:Array<Uri>, doc:Uri, at:Position) {
	final chosen = choose(scope).jsawait();
	if (chosen != null) {
		peekAt(doc, at, chosen);
	}
}

@:jsasync function lensOpen(scope:Array<Uri>) {
	final chosen = choose(scope).jsawait();
	if (chosen != null) {
		window.showTextDocument(view(chosen), {preview: false});
	}
}

// Per workspace: a lens click rebuilds with the hxml used last.
var memo:Null<Memento> = null;
final lastHxml = "haxeDump.lastHxml";

// The hxml to rebuild the dumps with. `ask` picks again (last one first) instead of reusing it.
// Root-level only: libraries under .haxelib/node_modules ship hxml files of their own.
@:jsasync function buildFile(ask:Bool):Promise<Null<Uri>> {
	final hxmls = workspace.findFiles("*.hxml", null, 50).jsawait();
	if (hxmls.length == 0) {
		window.showErrorMessage("No .hxml in the workspace root to rebuild the dumps with.");
		return null;
	}
	final last:Null<String> = memo.get(lastHxml);
	final isLast = (uri:Uri) -> uri.toString() == last;
	hxmls.sort((a, b) -> (isLast(b) ? 1 : 0) - (isLast(a) ? 1 : 0));
	if (hxmls.length == 1 || (!ask && isLast(hxmls[0]))) {
		return hxmls[0];
	}
	final items:Array<UriPick> = [
		for (uri in hxmls) {
			{label: workspace.asRelativePath(uri), description: isLast(uri) ? "last used" : null, uri: uri};
		}
	];
	final chosen = window.showQuickPick(items, {placeHolder: "Rebuild the dumps with"}).jsawait();
	if (chosen == null) {
		return null;
	}
	memo.update(lastHxml, chosen.uri.toString());
	return chosen.uri;
}

// An hxml's arguments with included hxml files inlined, resolved from `dir` as Haxe does.
// ponytail: any argument ending in .hxml counts as an include (a `-D x=y.hxml` value would too), and --cwd is ignored
function hxmlArgs(vshaxe:MetaDocs.Vshaxe, dir:String, hxml:String):Array<String> {
	var args = [];
	for (arg in vshaxe.parseHxmlToArguments(sys.io.File.getContent(js.node.Path.resolve(dir, hxml)))) {
		args = args.concat(arg.endsWith(".hxml") ? hxmlArgs(vshaxe, dir, arg) : [arg]);
	}
	return args;
}

// A cold compile of the hxml plus -D dump=pretty, as a task so its output shows in a terminal.
// The JS goes to a temp folder, leaving the dev build's output alone: only dump/ changes. Cold
// on purpose: builds on vshaxe's server (6060) reset completion, and the extra define would pin
// a second ~1.5 GB cache context in the dev stack's server (6061).
@:jsasync function rebuild(ask:Bool) {
	final ext:Null<Extension<MetaDocs.Vshaxe>> = extensions.getExtension("nadako.vshaxe");
	if (ext == null) {
		window.showErrorMessage("Rebuilding the dumps needs the Haxe extension (nadako.vshaxe).");
		return;
	}
	final vshaxe = ext.activate().jsawait();
	final hxml = buildFile(ask).jsawait();
	if (hxml == null) {
		return;
	}
	final dir = js.node.Path.dirname(hxml.fsPath);
	final args = hxmlArgs(vshaxe, dir, js.node.Path.basename(hxml.fsPath));
	final outputs = [
		for (i => arg in args) {
			if ((arg == "-js" || arg == "--js") && i + 1 < args.length) {
				i + 1;
			}
		}
	];
	if (outputs.length == 0) {
		window.showErrorMessage('${workspace.asRelativePath(hxml)} has no -js output: only JS builds can be rebuilt with dumps.');
		return;
	}
	final tmp = js.node.Path.join(js.node.Os.tmpdir(), "haxe-dump-opener", js.node.Path.basename(dir));
	for (i in outputs) {
		args[i] = js.node.Path.join(tmp, js.node.Path.basename(args[i]));
	}
	final exe = vshaxe.haxeExecutable.configuration;
	final run = new ProcessExecution(exe.executable, args.concat(["-D", "dump=pretty"]), {cwd: dir, env: exe.env});
	tasks.executeTask(new Task({type: "haxeDump"}, workspace.getWorkspaceFolder(hxml), "Rebuild .dumps", "haxeDump", run));
}

@:expose("activate") function main(ctx:ExtensionContext) {
	ctx.subscriptions.push(languages.registerHoverProvider({language: "haxe"}, {provideHover: provideHover}));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.openFile", (uri:String) -> window.showTextDocument(Uri.parse(uri), {preview: false})));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.open", (?uri:Uri) -> open(uri)));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.openToSide", (?uri:Uri) -> open(uri, Beside)));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.peek", (?uri:Uri) -> peek(uri)));
	ctx.subscriptions.push(languages.registerCodeLensProvider({language: "haxe", scheme: "file"}, {provideCodeLenses: provideCodeLenses, onDidChangeCodeLenses: lensChanged.event}));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.lensPeek", lensPeek));
	ctx.subscriptions.push(commands.registerCommand("haxeDump.lensOpen", lensOpen));
	memo = ctx.workspaceState;
	ctx.subscriptions.push(commands.registerCommand("haxeDump.rebuild", (?ask:Bool) -> rebuild(ask != false)));
	MetaDocs.register(ctx);

	// Every compile rewrites the dumps: re-wrap any open view of one. Cheap for closed ones,
	// VS Code only re-asks for documents it has open.
	ctx.subscriptions.push(workspace.registerTextDocumentContentProvider(viewScheme, {onDidChange: viewChanged.event, provideTextDocumentContent: provideView}));
	final watcher = workspace.createFileSystemWatcher("**/dump/**/*.dump");
	ctx.subscriptions.push(watcher);
	ctx.subscriptions.push(watcher.onDidChange(uri -> viewChanged.fire(view(uri))));
	ctx.subscriptions.push(watcher.onDidCreate(uri -> viewChanged.fire(view(uri))));
	// Lenses come and go with the dumps, and lose their stale flag once a rebuild rewrites them.
	ctx.subscriptions.push(watcher.onDidChange(refreshLenses));
	ctx.subscriptions.push(watcher.onDidCreate(refreshLenses));
	ctx.subscriptions.push(watcher.onDidDelete(refreshLenses));
	ctx.subscriptions.push(workspace.onDidChangeConfiguration(e -> {
		if (e.affectsConfiguration("haxeDump.codeLens")) {
			lensChanged.fire();
		}
		if (e.affectsConfiguration("haxeDump")) {
			for (doc in workspace.textDocuments) {
				if (doc.uri.scheme == viewScheme) {
					viewChanged.fire(doc.uri);
				}
			}
		}
	}));
}
