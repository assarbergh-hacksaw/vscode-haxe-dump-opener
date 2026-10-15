package haxedump;

// One line of a dump, bracket-matched. Sep is a comma plus the spaces after it.
enum Node {
	Text(s:String);
	Sep(s:String);
	Group(open:String, items:Array<Node>, close:String);
}

typedef Options = {
	final width:Int;
	// How many bracket levels a line may be broken into; 0 = no limit.
	final depth:Int;
	// Metas whose arguments are never broken, e.g. "@:value".
	final flatMeta:Array<String>;
}

// Lines longer than width get every ( [ { group that doesn't fit split to one element per line,
// recursively, so e.g. a long array literal of constructor calls reads one entry per line.
// Only whitespace changes.
function wrap(text:String, opts:Options):String
	return [for (line in text.split("\n")) wrapLine(line, opts)].join("\n");

function wrapLine(line:String, opts:Options):String {
	if (columns(line) <= opts.width)
		return line;
	final body = line.ltrim();
	final indent = line.substr(0, line.length - body.length);
	return indent + render(parse(body), indent, opts, 1);
}

// Tabs as 4, matching the editor default.
function columns(s:String):Int
	return s.length + 3 * (s.split("\t").length - 1);

// String literals are skipped over, so their commas and brackets don't count.
// A group still open at end of line is closed with "".
function parse(s:String):Array<Node> {
	final stack:Array<{open:String, items:Array<Node>}> = [];
	var items:Array<Node> = [];
	var start = 0;
	var i = 0;
	function text()
		if (i > start)
			items.push(Text(s.substring(start, i)));
	while (i < s.length) {
		final c = s.charAt(i);
		if (c == '"' || c == "'") {
			i++;
			while (i < s.length && s.charAt(i) != c)
				i += s.charAt(i) == "\\" ? 2 : 1;
			i++;
			continue;
		}
		if ("([{".contains(c)) {
			text();
			stack.push({open: c, items: items});
			items = [];
			start = ++i;
		} else if (")]}".contains(c) && stack.length > 0) {
			text();
			final frame = stack.pop();
			frame.items.push(Group(frame.open, items, c));
			items = frame.items;
			start = ++i;
		} else if (c == ",") {
			text();
			var end = i + 1;
			while (end < s.length && s.charAt(end) == " ")
				end++;
			items.push(Sep(s.substring(i, end)));
			start = i = end;
		} else {
			i++;
		}
	}
	text();
	while (stack.length > 0) {
		final frame = stack.pop();
		frame.items.push(Group(frame.open, items, ""));
		items = frame.items;
	}
	return items;
}

function flat(n:Node):String
	return switch n {
		case Text(s) | Sep(s): s;
		case Group(open, items, close): open + items.map(flat).join("") + close;
	}

// Output starts at indent's column; a broken group's elements go one level deeper.
function render(nodes:Array<Node>, indent:String, opts:Options, level:Int):String {
	final out = new StringBuf();
	var col = columns(indent);
	var before = "";
	for (n in nodes) {
		final f = flat(n);
		final breakable = (opts.depth == 0 || level <= opts.depth) && !Lambda.exists(opts.flatMeta, m -> before.endsWith(m));
		before = f;
		switch n {
			case Group(open, items, close) if (items.length > 0 && breakable && col + f.length > opts.width):
				final pad = indent + "\t";
				final elems = [[]];
				for (item in items)
					switch item {
						case Sep(_): elems.push([]);
						case _: elems[elems.length - 1].push(item);
					}
				out.add(open);
				out.add([for (el in elems) "\n" + pad + render(el, pad, opts, level + 1)].join(","));
				out.add("\n" + indent + close);
				col = columns(indent) + close.length;
			case _:
				out.add(f);
				col += f.length;
		}
	}
	return out.toString();
}
