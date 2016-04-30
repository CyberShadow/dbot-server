/// Code pertaining to displaying website diffs.
module web.website;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.functional;
import std.path;
import std.regex;
import std.string;

import ae.net.asockets;
import ae.net.http.common;
import ae.net.http.responseex;
import ae.net.http.server;
import ae.net.shutdown;
import ae.sys.d.cache;
import ae.sys.file;
import ae.sys.git;
import ae.sys.log;
import ae.utils.array;
import ae.utils.exception;
import ae.utils.meta;
import ae.utils.mime;
import ae.utils.regex;
import ae.utils.sini;
import ae.utils.textout;
import ae.utils.xmllite;

import web.server;

Repository cache;
Repository.ObjectReader objectReader;

static this()
{
	cache = Repository(config.localCache); // "work/cache-git/v3/"
	objectReader = cache.createObjectReader();
}

void showDirListing(GitObject.TreeEntry[] entries, bool showUpLink)
{
	html.put(
		`<ul class="dirlist">`
	);
	if (showUpLink)
		html.put(
			`<li>       <a href="../">..</a></li>`
		);
	foreach (entry; entries)
	{
		auto name = encodeEntities(entry.name) ~ (entry.mode & octal!40000 ? `/` : ``);
		html.put(
			`<li>`, "%06o".format(entry.mode), ` <a href="`, name, `">`, name, `</a></li>`
		);
	}
	html.put(
		`</ul>`
	);
}

void showResult(string testDir)
{
	string tryReadText(string fileName, string def = null) { return fileName.exists ? fileName.readText : def; }

	auto result = tryReadText(testDir ~ "result.txt").splitLines();
	auto info = tryReadText(testDir ~ "info.txt").splitLines();

	auto base = testDir.split("/")[1];
	auto hash = testDir.split("/")[2];

	html.put(
		`<table>`
	);
	if (hash == "!base")
		html.put(
		`<tr><td>Base commit</td><td>`, base, `</td></tr>`
		);
	else
		html.put(
		`<tr><td>Component</td><td>`, info.get(0, "master"), `</td></tr>`
		`<tr><td>Pull request</td><td>`, info.length>2 ? `<a href="` ~ info[2] ~ `">#` ~ info[1] ~ `</a>` : `-`, `</td></tr>`
		`<tr><td>Base result</td><td><a href="../!base/">View</a></td></tr>`
		);
	html.put(
		`<tr><td>Status</td><td>`, result.get(0, "?"), `</td></tr>`
		`<tr><td>Details</td><td>`, result.get(1, "?"), `</td></tr>`
	//	`<tr><td>Build log</td><td><pre>`, tryReadText(testDir ~ "build.log").encodeEntities(), `</pre></td></tr>`
		`<tr><td>Build log</td><td>`, exists(testDir ~ "build.log") ? `<a href="build.log">View</a>` : "-", `</td></tr>`
		`<tr><td>Files</td><td>`
			`<a href="file/web/index.html">Main page</a> &middot; `
			`<a href="file/web/phobos-prerelease/index.html">Phobos</a> &middot; `
			`<a href="file/web/library-prerelease/index.html">DDox</a> &middot; `
			`<a href="file/web/">All files</a>`
		`</td></tr>`
	);
	if (result.get(0, null) == "success" && exists(testDir ~ "numstat.txt"))
	{
		auto lines = readText(testDir ~ "numstat.txt").strip.splitLines.map!(line => line.split('\t')).array;
		int additions, deletions, maxChanges;
		foreach (line; lines)
		{
			if (line[0] == "-")
				additions++, deletions++;
			else
			{
				additions += line[0].to!int;
				deletions += line[1].to!int;
				maxChanges = max(maxChanges, line[0].to!int + line[1].to!int);
			}
		}

		html.put(
			`<tr><td>Changes</td><td>`
			`<table class="changes">`
		);
		if (!lines.length)
			html.put(`(no changes)`);
		auto changeWidth = min(100.0 / maxChanges, 5.0);
		foreach (line; lines)
		{
			auto fn = line[2];
			if (fileIgnored(fn))
				continue;
			html.put(`<tr><td>`, encodeEntities(fn), `</td><td>`);
			if (line[0] == "-")
				html.put(`(binary file)`);
			else
			{
				html.put(`<div class="additions" style="width:%5.3f%%" title="%s addition%s"></div>`.format(line[0].to!int * changeWidth, line[0], line[0]=="1" ? "" : "s"));
				html.put(`<div class="deletions" style="width:%5.3f%%" title="%s deletion%s"></div>`.format(line[1].to!int * changeWidth, line[1], line[1]=="1" ? "" : "s"));
			}
			html.put(
				`</td>`
				`<td>`
					`<a href="../!base/file/`, encodeEntities(fn), `">Old</a> `
					`<a href="file/`, encodeEntities(fn), `">New</a> `
					`<a href="diff/`, encodeEntities(fn), `">Diff</a>`
				`</td>`
				`</tr>`
			);
		}
		html.put(
			`</table>`
			`</td></tr>`
		);
	}
	html.put(
		`</table>`
	);
}

string ansiToHtml(string ansi)
{
	return ansi
		.I!(s => `<span>` ~ s ~ `</span>`)
		.replace("\x1B[m"  , `</span><span>`)
		.replace("\x1B[31m", `</span><span class="ansi-1">`)
		.replace("\x1B[32m", `</span><span class="ansi-2">`)
	;
}
