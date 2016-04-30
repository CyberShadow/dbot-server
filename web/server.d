module web.server;

import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.functional;
import std.meta;
import std.string;
import std.typecons;

import ae.net.http.responseex;
import ae.net.http.server;
import ae.net.shutdown;
import ae.sys.git;
import ae.sys.log;
import ae.utils.exception;
import ae.utils.textout;
import ae.utils.time;
import ae.utils.xmllite;

import clients;
import common;

StringBuffer html;
private Logger log;

void onRequest(HttpRequest request, HttpServerConnection conn)
{
	conn.sendResponse(handleRequest(request, conn));
}

HttpResponse handleRequest(HttpRequest request, HttpServerConnection conn)
{
	auto response = new HttpResponseEx();
	auto status = HttpStatusCode.OK;
	string title;
	html.clear();

	try
	{
		auto pathStr = request.resource.findSplit("?")[0];
		enforce(pathStr.startsWith('/'), "Invalid path");
		auto path = pathStr[1..$].split("/");
		if (!path.length) path = [""];

		pathSwitch:
		switch (path[0])
		{
			case "":
				title = "DBot status";
				showIndex();
				break;
			case "worker":
				title = "Worker " ~ path[1];
				enforce!NotFoundException(path.length == 2, "Bad path");
				showWorker(path[1]);
				break;
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
		"content" : cast(string) html.get(),
	];

	response.serveData(response.loadTemplate("data/web/skel.htt", vars));
	response.setStatus(status);
	return response;
}

mixin DeclareException!q{NotFoundException};

void showIndex()
{
	html.put(
		`<h3>Metrics</h3>`
		`<p>(TODO)</p>`

		`<h3>Jobs</h3>`
	);

	const jobsShown = 10;
	html.put(
		`<div style="float:right"><a href="/jobs/">Browse all jobs</a></div>`
		`<p>Last `, jobsShown.text, ` jobs:</p>`,
	);
	jobTable(jobsShown, No.pager);

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
		`<table>`
		`<tr><th>ID</th><td>`, client.id, `</td></tr>`
		`<tr><th>Driver</th><td>`, client.clientConfig.type.text, `</td></tr>`
		`</tr>`
		`<h3>Jobs</h3>`
	);

	jobTable(25, Yes.pager, "WHERE [ClientID] = ?", clientID);
}

void jobTable(Args...)(int limit, Flag!"pager" pager, string where = null, Args args = Args.init)
{
	// TODO: show tasks too

	html.put(
		`<table>`
		`<tr>`
		`<th>ID</th>`
		`<th>Start</th>`
		`<th>Finish</th>`
		`<th>Worker</th>`
		`<th>Status</th>`
		`</tr>`
	);
	foreach (long jobID, StdTime startTime, StdTime finishTime, string hash, string clientID, string status;
		query("SELECT [ID], [StartTime], [FinishTime], [Hash], [ClientID], [Status] FROM [Jobs] " ~ where ~ "ORDER BY [ID] DESC LIMIT ?").iterate(args, limit))
	{
		enum timeFormat = "Y-m-d H:i:s.E";
		html.put(
			`<tr>`
			`<td><a href="/job/"`, text(jobID), `">`, text(jobID), `</a></td>`,
			`<td>`, SysTime(startTime).formatTime!timeFormat, `</td>`,
			`<td>`, finishTime ? SysTime(finishTime).formatTime!timeFormat : "-", `</td>`,
			`<td><a href="/client/"`, clientID, `">`, clientID, `</a></td>`,
			`<td>`, status, `</td>`, // TODO: explanation in title attribute
			`</tr>`
		);
	}
	html.put(
		`</table>`
	);

	// TODO: pager
}

void workerTable()
{
	html.put(
		`<table>`
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
				`<td rowspan="2">(idle)</td>`
			);
	}
	html.put(
		`</table>`
	);
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
