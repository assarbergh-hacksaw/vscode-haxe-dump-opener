#!/usr/bin/env bash
# Packages the extension into a .vsix and installs it into the running VS Code
# (the remote/container host when run from an integrated terminal).
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="$(grep -o '"version": *"[^"]*"' "$src/extension/package.json" | head -1 | cut -d'"' -f4)"

# Prefer the server binary: it works headlessly, so the same script serves both an interactive
# run and a devcontainer lifecycle hook. The `code` wrapper needs VSCODE_IPC_HOOK_CLI, and
# without it it prints an error to stdout and still exits 0 — useless to probe with.
cli="$(ls -1 /vscode/vscode-server/bin/*/*/bin/code-server "$HOME"/.vscode-server/bin/*/bin/code-server 2>/dev/null | head -1)"
[ -n "$cli" ] && [ -x "$cli" ] || { echo "no VS Code server CLI found — is the server installed yet?" >&2; exit 1; }

# Lets the devcontainer hook run this on every attach for the price of one process.
if "$cli" --list-extensions --show-versions 2>/dev/null | grep -qx "local.haxe-dump-opener@$version"; then
	echo "v$version already installed."
	exit 0
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

cp -r "$src/extension" "$out/extension"

cat > "$out/extension.vsixmanifest" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
	<Metadata>
		<Identity Language="en-US" Id="haxe-dump-opener" Version="$version" Publisher="local" />
		<DisplayName>Haxe Dump Opener</DisplayName>
		<Description xml:space="preserve">Open the haxe -D dump output for the type under the cursor</Description>
		<Tags></Tags>
		<Categories>Other</Categories>
		<GalleryFlags>Public</GalleryFlags>
		<Properties>
			<Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0" />
			<Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace" />
			<Property Id="Microsoft.VisualStudio.Code.ExecutesCode" Value="true" />
		</Properties>
	</Metadata>
	<Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
	<Dependencies/>
	<Assets>
		<Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
	</Assets>
</PackageManifest>
EOF

cat > "$out/[Content_Types].xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".json" ContentType="application/json"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
EOF

(cd "$out" && zip -q -r haxe-dump-opener.vsix 'extension.vsixmanifest' '[Content_Types].xml' extension)
"$cli" --install-extension "$out/haxe-dump-opener.vsix" --force
echo "Installed v$version. Reload the window (Developer: Reload Window)."
