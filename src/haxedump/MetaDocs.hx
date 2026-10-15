package haxedump;

// Docs for a library's own metadata, which Haxe 4.3 shows nowhere: hover returns nothing for
// metadata it doesn't know, and completion items for registered metadata carry no doc. Each
// library ships a `haxe-metadata.json` (Haxe's MetadataDescription format) in its root. The
// metadata stays unregistered with the compiler on purpose: registered, it would show up a
// second time, doc-less, in vshaxe's completion list.
typedef MetaDoc = {
	final metadata:String;
	final doc:String;
	final ?params:Array<String>;
}

final docsFile = "haxe-metadata.json";

function parse(json:String):Array<MetaDoc> {
	final docs:Dynamic = haxe.Json.parse(json);
	if (!(docs is Array)) {
		throw "expected an array of metadata descriptions";
	}
	for (i => meta in (docs : Array<Dynamic>)) {
		if (!(meta.metadata is String) || !(meta.doc is String) || (meta.params != null && !(meta.params is Array))) {
			throw 'entry $i needs string "metadata" and "doc", and "params" as an array if any';
		}
	}
	return docs;
}

// Completion only (docs on hover are fine in a comment): keeps `@param` in a doc comment from
// popping up the metadata list.
// ponytail: text scan, not a tokenizer: a `/*` or `//` inside a string literal fools it
function inComment(before:String):Bool
	return before.lastIndexOf("/*") > before.lastIndexOf("*/") || before.substr(before.lastIndexOf("\n") + 1).contains("//");

// `@`, `@:`, `@:name`: the metadata being typed or hovered.
final metaWord = new js.lib.RegExp("@:?[\\w.]*");

typedef Vshaxe = {
	function getActiveConfiguration():Promise<{final classPaths:Array<{final path:String;}>;}>;
}

// Read fresh on every request: a handful of exists() checks, and edits to the files or a switch
// of the active Haxe configuration show up without a watcher.
@:jsasync function load():Promise<Array<MetaDoc>> {
	final vshaxe:Null<Extension<Vshaxe>> = extensions.getExtension("nadako.vshaxe");
	if (vshaxe == null) {
		return [];
	}
	final config = vshaxe.activate().jsawait().getActiveConfiguration().jsawait();
	// A library's classpath sits in its root, both for a `haxelib dev` checkout and an installed version.
	final files = [
		for (cp in config.classPaths) {
			js.node.Path.resolve(cp.path, "..", docsFile) => true;
		}
	];
	final docs = [];
	for (file in files.keys()) {
		if (sys.FileSystem.exists(file)) {
			try {
				for (meta in parse(sys.io.File.getContent(file))) {
					docs.push(meta);
				}
			} catch (e) {
				window.showErrorMessage('$file: ${e.message}');
			}
		}
	}
	return docs;
}

function markdown(meta:MetaDoc):MarkdownString {
	final params = meta.params == null ? "" : '(${meta.params.join(", ")})';
	return new MarkdownString().appendCodeblock('@${meta.metadata}$params', "haxe").appendMarkdown(meta.doc);
}

@:jsasync function hover(doc:TextDocument, pos:Position, token:CancellationToken):Promise<Null<Hover>> {
	final range = doc.getWordRangeAtPosition(pos, metaWord);
	if (range == null) {
		return null;
	}
	final name = doc.getText(range);
	final meta = Lambda.find(load().jsawait(), meta -> '@${meta.metadata}' == name);
	return meta == null ? null : new Hover(markdown(meta), range);
}

@:jsasync function complete(doc:TextDocument, pos:Position, token:CancellationToken, context:CompletionContext):Promise<Array<CompletionItem>> {
	final range = doc.getWordRangeAtPosition(pos, metaWord);
	if (range == null || inComment(doc.getText(new Range(new Position(0, 0), range.start)))) {
		return [];
	}
	final docs = load().jsawait();
	return [
		for (meta in docs) {
			final item = new CompletionItem('@${meta.metadata}', Function);
			item.range = range;
			item.documentation = markdown(meta);
			item;
		}
	];
}

function register(ctx:ExtensionContext) {
	ctx.subscriptions.push(languages.registerHoverProvider({language: "haxe"}, {provideHover: hover}));
	ctx.subscriptions.push(languages.registerCompletionItemProvider({language: "haxe"}, {provideCompletionItems: complete}, "@", ":"));
}
