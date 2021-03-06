module web.server;

import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.functional;
import std.meta;
import std.path;
import std.string;
import std.stdio : File;
import std.typecons;

import ae.net.http.responseex;
import ae.net.http.server;
import ae.net.shutdown;
import ae.sys.git;
import ae.sys.log;
import ae.utils.array;
import ae.utils.exception;
import ae.utils.json;
import ae.utils.text.html;
import ae.utils.textout;
import ae.utils.time;
import ae.utils.xmllite;

import clients;
import common;
import scheduler.common;

private StringBuffer html;
private Logger log;
private int page; // 0-indexed

void onRequest(HttpRequest request, HttpServerConnection conn)
{
	conn.sendResponse(handleRequest(request, conn));
}

HttpResponse handleRequest(HttpRequest request, HttpServerConnection conn)
{
	auto response = new HttpResponseEx();
	auto status = HttpStatusCode.OK;
	string title = null, bodyClass = "page";
	html.clear();

	try
	{
		string pathStr, argStr;
		list(pathStr, null, argStr) = request.resource.findSplit("?");
		enforce(pathStr.startsWith('/'), "Invalid path");
		auto path = pathStr[1..$].split("/");
		if (!path.length) path = [""];

		page = 0;
		auto args = decodeUrlParameters(argStr);
		if ("page" in args)
			page = args["page"].to!int - 1;

	pathSwitch:
		switch (path[0])
		{
			case "":
				enforce!NotFoundException(path.length == 1, "Bad path");
				title = "DBot status";
				showIndex();
				break;
			case "worker":
				enforce!NotFoundException(path.length == 2, "Bad path");
				title = "Worker " ~ path[1];
				showWorker(path[1]);
				break;
			case "jobs":
				enforce!NotFoundException(path.length == 1, "Bad path");
				title = "Jobs";
				showJobs();
				break;
			case "job":
			{
				enforce!NotFoundException(path.length >= 2, "Bad path");
				JobID id = path[1].to!JobID();
				if (path.length == 2)
				{
					title = "Job " ~ text(id);
					showJob(id);
				}
				else
					switch (path[2])
					{
						case "log.html":
							enforce!NotFoundException(path.length == 3, "Bad path");
							title = "Log for job " ~ text(id);
							bodyClass = "bare";
							showLog(id);
							break;
						case "log.txt":
							enforce!NotFoundException(path.length == 3, "Bad path");
							showTextLog(id);
							return response.serveText(cast(string) html.get());
						default:
							throw new NotFoundException("Unknown resource");
					}
				break;
			}
			case "tasks":
				enforce!NotFoundException(path.length == 1, "Bad path");
				title = "Tasks";
				showTasks();
				break;
			case "task":
			{
				enforce!NotFoundException(path.length == 2, "Bad path");
				auto key = path[1];
				title = "Task " ~ title;
				showTask(key, title);
				break;
			}
			/*
			case "results":
				title = "Test result";
				enforce!NotFoundException(path.length > 3, "Bad path");
				enforce!NotFoundException(path[1].match(re!`^[0-9a-f]{40}$`), "Bad base commit");
				enforce!NotFoundException(path[2].match(re!`^[0-9a-f]{40}$`) || path[2] == "!base", "Bad pull commit");

				auto testDir = "results/%s/%s/".format(path[1], path[2]);
				enforce!NotFoundException(testDir.exists, "No such commit");

				auto action = path[3];
				switch (action)
				{
					case "":
						showResult(testDir);
						break;
					case "build.log":
						return response.serveText(cast(string)read(pathStr[1..$]));
					case "file":
					{
						auto buildID = readText(testDir ~ "buildid.txt");
						return response.redirect("/artifact/" ~ buildID ~ "/" ~ path[4..$].join("/"));
					}
					case "diff":
					{
						auto buildID = readText(testDir ~ "buildid.txt");
						auto baseBuildID = readText(testDir ~ "../!base/buildid.txt");
						return response.redirect("/diff/" ~ baseBuildID ~ "/" ~ buildID ~ "/" ~ path[4..$].join("/"));
					}
					default:
						throw new NotFoundException("Unknown action");
				}
				break;
			case "artifact":
			{
				enforce!NotFoundException(path.length >= 2, "Bad path");
				auto refName = GitCache.refPrefix ~ path[1];
				auto commitObject = objectReader.read(refName);
				auto obj = objectReader.read(commitObject.parseCommit().tree);
				foreach (dirName; path[2..$])
				{
					auto tree = obj.parseTree();
					if (dirName == "")
					{
						title = "Artifact storage directory listing";
						showDirListing(tree, path.length > 3);
						break pathSwitch;
					}
					auto index = tree.countUntil!(entry => entry.name == dirName);
					enforce!NotFoundException(index >= 0, "Name not in tree: " ~ dirName);
					obj = objectReader.read(tree[index].hash);
				}
				if (obj.type == "tree")
					return response.redirect(path[$-1] ~ "/");
				enforce(obj.type == "blob", "Invalid object type");
				return response.serveData(Data(obj.data), guessMime(path[$-1]));
			}
			case "diff":
			{
				enforce!NotFoundException(path.length >= 4, "Bad path");
				auto refA = GitCache.refPrefix ~ path[1];
				auto refB = GitCache.refPrefix ~ path[2];
				return response.serveText(cache.query(["diff", refA, refB, "--", path[3..$].join("/")]));
			}
			case "webhook":
				if (request.headers.get("X-GitHub-Event", null).isOneOf("push", "pull_request"))
					touch(eventFile);
				return response.serveText("DAutoTest/webserver OK\n");
			*/
			case "static":
				return response.serveFile(pathStr[1..$], "data/web/");
			case "robots.txt":
				return response.serveText("User-agent: *\nDisallow: /");
			default:
				throw new NotFoundException("Unknown resource");
		}
	}
	catch (CaughtException e)
	{
		status = cast(NotFoundException)e ? HttpStatusCode.NotFound : HttpStatusCode.InternalServerError;
		return response.writeError(status, e.toString());
	}

	assert(title, "No title");

	auto vars = [
		"title" : title,
		"class" : bodyClass,
		"content" : cast(string) html.get(),
	];

	response.serveData(response.loadTemplate("data/web/skel.htt", vars));
	response.setStatus(status);
	return response;
}

mixin DeclareException!q{NotFoundException};

const indexPageSize = 10;
const inlinePageSize = 20;
const fullPageSize = 30;

void showIndex()
{
	html.put(
		`<h3>Metrics</h3>`
		`<p>(TODO)</p>`

		`<h3>Jobs</h3>`
	);

	html.put(
		`<div class="right"><a href="/jobs">Browse all jobs</a></div>`
		`<p>Last `, indexPageSize.text, ` jobs:</p>`,
	);
	jobTable(indexPageSize, No.pager);

	html.put(
		`<h3>Tasks</h3>`
	);

	html.put(
		`<div class="right"><a href="/tasks">Browse all tasks</a></div>`
		`<p>Last `, indexPageSize.text, ` tasks:</p>`,
	);
	taskTable(indexPageSize, No.pager);

	html.put(
		`<h3>Workers</h3>`
	);
	workerTable();
}

void showWorker(string clientID)
{
	auto pClient = clientID in allClients;
	enforce!NotFoundException(pClient);
	auto client = *pClient;

	html.put(
		`<table class="horiz">`
		`<tr><th>ID</th><td>`, client.id, `</td></tr>`
		`<tr><th>Driver</th><td>`, client.clientConfig.type.text, `</td></tr>`
		`</table>`
		`<h3>Jobs</h3>`
	);

	jobTable(inlinePageSize, Yes.pager, "WHERE [ClientID] = ?", clientID);
}

void showJobs()
{
	jobTable(fullPageSize, Yes.pager);
}

enum timeFormat = "Y-m-d H:i:s.E";

void showJob(JobID id)
{
	foreach (StdTime startTime, StdTime finishTime, string hash, string clientID, string status, string error;
		query("SELECT [StartTime], [FinishTime], [Hash], [ClientID], [Status], [Error] FROM [Jobs] WHERE [ID]=?").iterate(id))
	{
		html.put(
			`<table class="horiz">`
			`<tr><th>ID</th><td>`, id.text, `</td></tr>`
			`<tr><th>Client</th><td><a href="/worker/`, clientID, `">`, clientID, `</a></td></tr>`,
			`<tr><th>Start time</th><td>`, SysTime(startTime, UTC()).formatTime!timeFormat, `</td></tr>`
			`<tr><th>Finish time</th><td>`, finishTime ? SysTime(finishTime, UTC()).formatTime!timeFormat : "(still running)", `</td></tr>`,
			`<tr><th>Status</th><td>`, status, `</td></tr>`,
			`<tr><th>Error</th><td>`, error ? encodeHtmlEntities(error) : `(no error)`, `</td></tr>`,
			`<tr><th>Progress</th><td>`, id in activeJobs ? activeJobs[id].progress.text : `(not running)`, `</td></tr>`,
			`</table>`
			`<h3>Tasks</h3>`
		);
		taskTable(0, No.pager, "WHERE [Hash]=?", hash);

		html.put(
			`<div class="heading-right">`
			`<a href="`, text(id), `/log.html">expand</a>`
			` &middot; `
			`<a href="`, text(id), `/log.txt">raw</a>`
			`</div>`
			`<h3>Log</h3>`
		);
		showLog(id);

		// TODO: Live status (log etc.)
		return;
	}
	throw new NotFoundException("No such job");
}

void showLog(JobID id)
{
	auto fileName = jobDir(id).buildPath("log.json");
	html.put(
		`<pre class="log">`
	);
	foreach (line; File(fileName, "rb").byLine())
	{
		try
		{
			auto message = line.jsonParse!LogMessage();
			html.put(
				`<div>`
				`[`,
				SysTime(message.time, UTC()).formatTime!timeFormat,
				`] <span class="log-`, message.type.text, `">`,
				encodeHtmlEntities(message.text),
				`</span></div>`
			);
		}
		catch (Exception e)
			continue;
	}
	html.put(
		`</pre>`
	);
	// TODO: stream in changes live
}

void showTextLog(JobID id)
{
	auto fileName = jobDir(id).buildPath("log.json");
	foreach (line; File(fileName, "rb").byLine())
	{
		try
		{
			auto message = line.jsonParse!LogMessage();
			html.put(`[`, SysTime(message.time, UTC()).formatTime!timeFormat, `] `, message.text, "\n");
		}
		catch (Exception e)
			continue;
	}
}

void showTasks()
{
	// TODO: Browseable hierarchy
	taskTable(fullPageSize, Yes.pager);
}

void showTask(string key, out string title)
{
	foreach (string hash; query("SELECT [Hash] FROM [Tasks] WHERE [Key]=?").iterate(key))
	{
		title = "(TODO)";

		auto parsedKey = parseJobKey(key);
		html.put(
			`<table class="horiz">`
			`<tr><th>Title</th><td>`, title, `</td></tr>`
		);
		foreach (pair; parsedKey.htmlDetails)
			html.put(
				`<tr><th>`, pair[0], `</th><td>`, pair[1], `</td></tr>`
			);
		html.put(
			`</table>`
			`<h3>Jobs</h3>`
		);

		jobTable(inlinePageSize, Yes.pager, "WHERE [Hash] = ?", hash);

		return;
	}
	throw new NotFoundException("No such task");
}

void jobTable(Args...)(int limit, Flag!"pager" pager, string where = null, Args args = Args.init)
{
	// TODO: show tasks too

	html.put(
		`<table class="vert">`
		`<tr>`
		`<th>ID</th>`
		`<th>Start</th>`
		`<th>Finish</th>`
		`<th>Worker</th>`
		`<th>Status</th>`
		`</tr>`
	);
	int count;
	foreach (JobID jobID, StdTime startTime, StdTime finishTime, string hash, string clientID, string status;
		query("SELECT [ID], [StartTime], [FinishTime], [Hash], [ClientID], [Status] FROM [Jobs] " ~ where ~ "ORDER BY [ID] DESC LIMIT ? OFFSET ?").iterate(args, limit, page * limit))
	{
		html.put(
			`<tr>`
			`<td><a href="/job/`, text(jobID), `">`, text(jobID), `</a></td>`,
			`<td>`, SysTime(startTime, UTC()).formatTime!timeFormat, `</td>`,
			`<td>`, finishTime ? SysTime(finishTime, UTC()).formatTime!timeFormat : "-", `</td>`,
			`<td><a href="/worker/`, clientID, `">`, clientID, `</a></td>`,
			`<td>`, status, `</td>`, // TODO: explanation in title attribute
			`</tr>`
		);
		count++;
	}
	if (!count)
		html.put(
			`<tr><td colspan="5">(no jobs found)</td></tr>`
		);
	html.put(
		`</table>`
	);

	if (count && pager)
		showPager(getPageCount(query("SELECT COUNT(*) FROM [Jobs] " ~ where).iterate(args).selectValue!int, limit));
}

void workerTable()
{
	html.put(
		`<table class="vert">`
		`<tr>`
		`<th>ID</th>`
		`<th>Driver</th>`
		`<th>Job</th>`
		`<th>Progress</th>`
		`</tr>`
	);
	foreach (client; allClients)
	{
		html.put(
			`<tr>`
			`<td><a href="/worker/`, client.id, `">`, client.id, `</a></td>`,
			`<td>`, client.clientConfig.type.text, `</td>`,
		);
		if (client.job)
			html.put(
				`<td><a href="/job/`, client.job.id.text, `">`, client.job.id.text, `</a></td>`,
				`<td>`, client.job.progress.text, `</td>`,
			);
		else
			html.put(
				`<td colspan="2">(idle)</td>`
			);
	}
	html.put(
		`</table>`
	);
}

void taskTable(Args...)(int limit, Flag!"pager" pager, string where = null, Args args = Args.init)
{
	html.put(
		`<table class="vert tasks">`
		`<tr>`
		`<th>Task</th>`
		`<th>Title</th>`
		`</tr>`
	);
	if (!limit)
		limit = int.max;
	int count;
	foreach (string key, string specJson;
		query("SELECT [Key], [Spec] FROM [Tasks] " ~ where ~ "ORDER BY [RowID] DESC LIMIT ? OFFSET ?").iterate(args, limit, page * limit))
	{
		auto spec = jsonParse!Spec(specJson);
		auto parsedKey = parseJobKey(key);
		string title = "(TODO)";
		html.put(
			`<tr>`
			`<td><a href="/task/`, encodeHtmlEntities(key), `">`, encodeHtmlEntities(parsedKey.name), `</a></td>`,
			`<td>`, encodeHtmlEntities(title), `</td>`,
			`</tr>`
		);
		count++;
	}
	if (!count)
		html.put(
			`<tr><td colspan="2">(no tasks found)</td></tr>`
		);
	html.put(
		`</table>`
	);

	if (count && pager)
		showPager(getPageCount(query("SELECT COUNT(*) FROM [Tasks] " ~ where).iterate(args).selectValue!int, limit));
}

int getPageCount(int count, int perPage) { return (count + perPage-1) / perPage; }

void showPager(int pageCount)
{
	if (pageCount <= 1)
		return;

	string linkOrNot(string text, int page, bool cond)
	{
		if (cond)
			return `<a href="?page=` ~ .text(page+1) ~ `">` ~ text ~ `</a>`;
		else
			return `<span class="disabled-link">` ~ text ~ `</span>`;
	}

	// Try to make the pager as wide as it will fit in the alotted space

	int radius = 3;
	int pagerStart = max(0, page - radius);
	int pagerEnd = min(pageCount - 1, page + radius);

	string[] pager;
	if (pagerStart > 1)
		pager ~= "&hellip;";
	foreach (pagerPage; pagerStart..pagerEnd+1)
		if (pagerPage == page)
			pager ~= `<b>` ~ text(pagerPage+1) ~ `</b>`;
		else
			pager ~= linkOrNot(text(pagerPage+1), pagerPage, true);
	if (pagerEnd < pageCount - 1)
		pager ~= "&hellip;";

	html.put(
		`<div class="pager">`
			`<div class="pager-left">`,
				linkOrNot("&laquo; First", 0, page!=0),
				`&nbsp;&nbsp;&nbsp;`,
				linkOrNot("&lsaquo; Prev", page-1, page>0),
			`</div>`
			`<div class="pager-right">`,
				linkOrNot("Next &rsaquo;", page+1, page<pageCount-1),
				`&nbsp;&nbsp;&nbsp;`,
				linkOrNot("Last &raquo; ", pageCount-1, page!=pageCount-1),
			`</div>`
			`<div class="pager-numbers">`, pager.join(` `), `</div>`
		`</div>`);
}

void startWebServer()
{
	log = createLogger("WebServer");

	auto server = new HttpServer();
	server.log = log;
	server.handleRequest = toDelegate(&onRequest);
	server.listen(config.web.port, config.web.addr);
	addShutdownHandler({ server.close(); });
}
