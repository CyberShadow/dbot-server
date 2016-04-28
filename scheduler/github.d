module scheduler.github;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.datetime;
import std.json;
import std.range.interfaces;
import std.string;

import ae.utils.meta : enumLength;
import ae.utils.time.common;
import ae.utils.time.parse;

import clients : clients, prodClients;
import common;
import api;

import scheduler.common;

/// Sort a predefined array of tasks
class StaticTaskSource : TaskSource
{
	string clientID;

	Task[][enumLength!(Priority.Group)] taskGroups;

	this(string clientID, Task[] tasks)
	{
		// Group by priority group, then sort within group by order
		auto priorities = tasks.map!(task => task.getPriority(clientID)).array();
		size_t[][enumLength!(Priority.Group)] index;
		foreach (i, task; tasks)
			index[priorities[i].group] ~= i;
		foreach (group, groupIndex; index)
		{
			groupIndex.sort!((a, b) => priorities[a].order > priorities[b].order);
			taskGroups[group] = groupIndex.map!(i => tasks[i]).array();
		}
	}

	override InputRange!Task getTasks(Priority.Group priorityGroup)
	{
		return inputRangeObject(taskGroups[priorityGroup]);
	}
}

static this()
{
	taskSourceFactories ~= clientID => new StaticTaskSource(clientID, tasks.values);
}

string[string] branches;

/// Handle a meta-repository branch state change
void handleBranch(SysTime time, string name, string commit, Action action)
{
	/*
	  Needed information:
	  - github organization
	  - github repository
	  - branch name
	  - new commit
	*/
	branches[name] = commit;

	class BranchTask : Task
	{
		override @property string key() { return "branch:%s".format(name); }

		override Priority getPriority(string clientID)
		{
			// TODO: Cache in RAM?
			// TODO: Indexes
			if (query("SELECT COUNT(*) FROM [Jobs] WHERE [ClientID]=? AND [MainlineCommit]=? AND [PRComponent] IS NULL").iterate(clientID, commit).selectValue!int() > 0)
				return Priority(Priority.Group.none); // already tested this commit
			return Priority(Priority.Group.branch, time.stdTime);
		}

		override string[] getClientCommandLine()
		{
			return [commit];
		}

		override @property string mainlineBranch() { return name; }
		override @property string mainlineCommit() { return commit; }
		override @property string prComponent() { return null; }
		override @property int prNumber() { return 0; }
		override @property string merges() { return null; }
	}

	handleTask(new BranchTask, action);
}

/// Handle a GitHub pull request state change
void handlePull(SysTime time, string org, string repo, int number, string commit, string targetBranch, string description, Action action)
{
	/*
	  Needed information:
	  - github organization
	  - github repository
	  - pull request number
	  - pull request SHA
	  - pull request description (for parsing dependencies and such)
	 */
	// TODO: Parse the description for dependencies
	string merges = "%s:%s".format(repo, commit);

	if (targetBranch !in branches)
	{
		log("Ignoring pull request %s:%s:%d against unknown branch %s".format(org, repo, number, targetBranch));
		return;
	}
	auto branchCommit = branches[targetBranch];

	class PullTask : Task
	{
		override @property string key() { return "pr:%s:%s:%d".format(org, repo, number); }

		override Priority getPriority(string clientID)
		{
			// TODO: Cache in RAM?
			// TODO: Indexes
			if (query("SELECT COUNT(*) FROM [Jobs] WHERE [ClientID]=? AND [Merges]=? AND [MainlineCommit]=?").iterate(clientID, merges, branchCommit).selectValue!int() > 0)
				return Priority(Priority.Group.none); // already tested this PR version against the current branch
			if (query("SELECT COUNT(*) FROM [Jobs] WHERE [ClientID]=? AND [Merges]=?"                       ).iterate(clientID, merges              ).selectValue!int() > 0)
				return Priority(Priority.Group.idle, time.stdTime); // already tested this PR version against an older version of the target branch
			return Priority(Priority.Group.newPR, time.stdTime);
		}

		override string[] getClientCommandLine()
		{
			// TODO: dependencies
			return [
				"--fetch", "%s|origin|refs/pull/%d/head".format(repo, number),
				"--merge", "%s|%s".format(repo, commit),
				branchCommit
			];
		}

		override @property string mainlineBranch() { return targetBranch; }
		override @property string mainlineCommit() { return branchCommit; }
		override @property string prComponent() { return "%s/%s".format(org, repo); }
		override @property int prNumber() { return number; }
		override @property string merges() { return merges; }
	}

	handleTask(new PullTask, action);
}

/// Get the current state of the meta-repository branches from BitBucket.
void getBranches()
{
	auto response = httpQuery("https://api.bitbucket.org/2.0/repositories/cybershadow/d/refs/branches?pagelen=100").parseJSON();
	enforce("size" !in response.object, "Paged BitBucket object");

	foreach (value; response.object["values"].array)
	{
		auto name = value.object["name"].str;
		auto hash = value.object["target"].object["hash"].str;
		auto date = value.object["target"].object["date"].str.parseTime!(TimeFormats.RFC3339)();
		handleBranch(date, name, hash, Action.resume);
	}
}

/// Get the current state of pull requests from GitHub.
void getPullRequests()
{
	JSONValue[] pulls;
	// TODO: Include dbot-client here too
	auto org = "dlang";
	foreach (repo; testedRepos)
		pulls ~= httpQuery("https://api.github.com/repos/" ~ org ~ "/" ~ repo ~ "/pulls?per_page=100").parseJSON().array;

	log("Verifying pulls");

	foreach (pull; pulls)
	{
		auto sha = pull["head"]["sha"].str;
		auto repo = pull["base"]["repo"]["name"].str;
		int n = pull["number"].integer.to!int;
		auto date = pull["updated_at"].str.parseTime!(TimeFormats.ISO8601)();
		auto target = pull["base"]["ref"].str;
		auto description = null; // TODO (requires separate request)
		handlePull(date, org, repo, n, sha, target, null, Action.resume);
	}
}

void initialize()
{
	assert(!clients.length, "Scheduler initialization should occur before client initialization");

	query("UPDATE [Jobs] SET [Status]='orphaned' WHERE [Status]='started'").exec();

	getBranches();
	getPullRequests();
}
