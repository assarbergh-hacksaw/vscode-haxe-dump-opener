const vscode = require('vscode');

// Outermost document symbol containing pos -> the module-level type the cursor sits in.
// Undefined when the language server is asleep or the cursor is on imports/package.
async function enclosingType(doc, pos) {
	const syms = (await vscode.commands.executeCommand('vscode.executeDocumentSymbolProvider', doc.uri)) ?? [];
	const containing = syms
		.map(s => ({ name: s.name, range: s.range ?? s.location.range }))
		.filter(s => s.range.contains(pos));
	if (!containing.length) return undefined;
	const height = s => s.range.end.line - s.range.start.line;
	return containing.reduce((a, b) => (height(b) > height(a) ? b : a)).name.match(/^\w+/)?.[0];
}

// A capitalised word under the cursor is a type reference (EditorMacros, ImGui, CameraConfig).
// Anything else -> the type the cursor is inside -> the module name.
async function targetType(ed, fallback) {
	if (!ed) return fallback;
	const range = ed.document.getWordRangeAtPosition(ed.selection.active);
	const word = range && ed.document.getText(range);
	if (/^[A-Z]\w*$/.test(word ?? '')) return word;
	return (await enclosingType(ed.document, ed.selection.active)) ?? fallback;
}

// dump/js is what you almost always want; dump/macro holds the same package paths and is
// last resort. Any other target (hl, cpp, ...) sits in between.
const rank = uri => (/\/dump\/js\//.test(uri.path) ? 0 : /\/dump\/macro\//.test(uri.path) ? 2 : 1);

async function pick(hits, pkgDir) {
	const sorted = [...hits].sort((a, b) => rank(a) - rank(b));
	// Same type name in several packages: narrow to this file's own package when it matches.
	const inPkg = uri => pkgDir && uri.path.slice(0, uri.path.lastIndexOf('/')).endsWith(pkgDir);
	const scope = sorted.some(inPkg) ? sorted.filter(inPkg) : sorted;

	if (scope.length === 1) return scope[0];
	const js = scope.filter(uri => rank(uri) === 0);
	if (js.length === 1) return js[0];

	const chosen = await vscode.window.showQuickPick(
		scope.map((uri, i) => ({
			label: vscode.workspace.asRelativePath(uri),
			description: i === 0 ? 'recommended' : undefined,
			uri
		})),
		{ placeHolder: 'Multiple dumps match' }
	);
	return chosen?.uri;
}

// Nothing found: either the build never had dumps switched on, or it's just stale.
// Only runs on a miss, so no startup or background cost.
async function reportMiss(type) {
	const hxmls = await vscode.workspace.findFiles('**/*.hxml', '**/node_modules/**', 50);
	const bodies = await Promise.all(hxmls.map(async f => {
		const text = new TextDecoder().decode(await vscode.workspace.fs.readFile(f));
		return text.split('\n').filter(l => !l.trim().startsWith('#')).join('\n');
	}));
	// ponytail: flag lookup is per-file; an hxml that only gets it from an included hxml reads as missing
	if (bodies.some(b => /(^|\s)(-D|--define)\s+dump[=\s]/.test(b))) {
		return vscode.window.showWarningMessage(`No dump for ${type} — rebuild to refresh dump/.`);
	}

	const choice = await vscode.window.showWarningMessage(
		`No dump for ${type}: no .hxml sets -D dump=pretty.`, 'Add -D dump=pretty'
	);
	if (!choice) return;

	const target = hxmls.length === 1 ? hxmls[0] : (await vscode.window.showQuickPick(
		hxmls.map(uri => ({ label: vscode.workspace.asRelativePath(uri), uri })),
		{ placeHolder: 'Which build file?' }
	))?.uri;
	if (!target) return;

	// ponytail: appends at the end, so on a multi-target hxml it lands in the last --next section
	const doc = await vscode.workspace.openTextDocument(target);
	const edit = new vscode.WorkspaceEdit();
	edit.insert(target, doc.lineAt(doc.lineCount - 1).range.end, '\n-D dump=pretty\n');
	await vscode.workspace.applyEdit(edit);
	await doc.save();
	vscode.window.showTextDocument(doc, { preview: false });
}

// The dump for whatever the command was aimed at, or undefined (having said why).
async function resolve(uri) {
	const ed = vscode.window.activeTextEditor;
	const src = (uri ?? ed?.document.uri)?.fsPath;
	if (!src?.endsWith('.hx')) return void vscode.window.showWarningMessage('Not a .hx file');

	// Explorer right-click can target a file that isn't the focused editor: no cursor there.
	const cursorIn = ed && ed.document.uri.fsPath === src ? ed : undefined;
	const module = src.slice(src.lastIndexOf('/') + 1, -3);
	const type = await targetType(cursorIn, module);
	const pkgDir = (cursorIn?.document.getText().match(/^package\s+([\w.]*)\s*;/m)?.[1] ?? '').replace(/\./g, '/');

	// ponytail: 20 is plenty for a type name; bump if a name ever collides more than that
	const hits = await vscode.workspace.findFiles(`dump/**/${type}.dump`, null, 20);
	if (!hits.length) return void reportMiss(type);
	return pick(hits, pkgDir);
}

// Menu titles are static in package.json, so the hover is where the resolved dump gets named.
const hoverProvider = {
	async provideHover(doc, pos) {
		const range = doc.getWordRangeAtPosition(pos);
		const word = range && doc.getText(range);
		if (!/^[A-Z]\w*$/.test(word ?? '')) return;
		const [hit] = await vscode.workspace.findFiles(`dump/**/${word}.dump`, null, 1);
		if (!hit) return;
		// Own command taking an fsPath: the built-in vscode.open re-parses a string arg as a
		// path, so handing it a file:// URI lands on /workspaces/.../file:///workspaces/...
		const args = encodeURIComponent(JSON.stringify([hit.fsPath]));
		const md = new vscode.MarkdownString(
			`[Open ${vscode.workspace.asRelativePath(hit)}](command:haxeDump.openFile?${args})`
		);
		md.isTrusted = true;
		return new vscode.Hover(md, range);
	}
};

exports.activate = ctx => ctx.subscriptions.push(
	vscode.languages.registerHoverProvider({ language: 'haxe' }, hoverProvider),
	vscode.commands.registerCommand('haxeDump.openFile', p => vscode.window.showTextDocument(vscode.Uri.file(p), { preview: false })),
	vscode.commands.registerCommand('haxeDump.open', async uri => {
		const chosen = await resolve(uri);
		if (chosen) vscode.window.showTextDocument(chosen, { preview: false });
	}),
	vscode.commands.registerCommand('haxeDump.openToSide', async uri => {
		const chosen = await resolve(uri);
		if (chosen) vscode.window.showTextDocument(chosen, { preview: false, viewColumn: vscode.ViewColumn.Beside });
	}),
	vscode.commands.registerCommand('haxeDump.peek', async uri => {
		const ed = vscode.window.activeTextEditor;
		const chosen = await resolve(uri);
		if (!chosen) return;
		if (!ed) return vscode.window.showTextDocument(chosen, { preview: false });
		// Built-in peek widget: the dump renders inline under the cursor line, no custom UI.
		return vscode.commands.executeCommand(
			'editor.action.peekLocations',
			ed.document.uri,
			ed.selection.active,
			[new vscode.Location(chosen, new vscode.Position(0, 0))],
			'peek'
		);
	})
);
