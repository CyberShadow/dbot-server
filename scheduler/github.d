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

import clients;
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
		override @property string taskKey() const { return "branch:%s".format(name); }

		override @property string jobKey() const { return "%s:branch:%s".format(name, commit); }

		override @property Spec spec() const
		{
			Spec spec;
			spec.branchName = name;
			spec.branchCommit = commit;
			return spec;
		}

		override Priority getPriority(string clientID) const
		{
			// TODO: Cache in RAM?
			// TODO: Indexes
			// enum qStr = "SELECT COUNT(*) FROM [Tasks] " ~
			// 	"JOIN [Jobs] ON [Tasks].[Hash]=[Jobs].[Hash] " ~
			// 	"WHERE [Status] IN ('success', 'failure', 'error') AND [ClientID]=? AND [Key]=?";
			// if (query().iterate(clientID, commit).selectValue!int() > 0)
			// 	return Priority(Priority.Group.none); // already tested this commit
			if (query("SELECT COUNT(*) FROM [Jobs] WHERE [ClientID]=? AND [Hash]=? AND [Status] IN ('success', 'failure', 'error')").iterate(clientID, spec.hash).selectValue!int() > 0)
				return Priority(Priority.Group.none); // already tested this commit
			return Priority(Priority.Group.branch, time.stdTime);
		}

		// override string[] getClientCommandLine()
		// {
		// 	return [commit];
		// }

		// override @property string mainlineBranch() { return name; }
		// override @property string mainlineCommit() { return commit; }
		// override @property string prComponent() { return null; }
		// override @property int prNumber() { return 0; }
		// override @property string merges() { return null; }
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

	Spec.Merge[] merges;

	// TODO: Parse the description for dependencies
	// For now, there is only one mergeable

	Spec.Merge merge = {
		repository : repo,
		remote : "origin",
		remoteRef : "refs/pull/%d/head".format(number),
		commit : commit,
	};
	merges ~= merge;

	if (targetBranch !in branches)
	{
		log("Ignoring pull request %s:%s:%d against unknown branch %s".format(org, repo, number, targetBranch));
		return;
	}
	auto branchCommit = branches[targetBranch];

	class PullTask : Task
	{
		override @property string taskKey() const { return "pr:%s:%s:%d".format(org, repo, number); }

		override @property string jobKey() const { return "%s:pr:%s:%s:%d:%s:%s".format(targetBranch, org, repo, number, commit, branchCommit); }

		override @property Spec spec() const
		{
			Spec spec;
			spec.branchName = targetBranch;
			spec.branchCommit = branchCommit;
			spec.merges = merges;
			return spec;
		}

		override Priority getPriority(string clientID) const
		{
			// TODO: Cache in RAM?
			// TODO: Indexes
			if (query("SELECT COUNT(*) FROM [Jobs] WHERE [ClientID]=? AND [Hash]=? AND [Status] IN ('success', 'failure', 'error')").iterate(clientID, spec.hash).selectValue!int() > 0)
				return Priority(Priority.Group.none); // already tested this PR version against the current branch
			// if (query("SELECT COUNT(*) FROM [Jobs] WHERE [ClientID]=? AND [Merges]=? AND [Status] IN ('success', 'failure', 'error')"                       ).iterate(clientID, merges              ).selectValue!int() > 0)
			// 	return Priority(Priority.Group.idle, time.stdTime); // already tested this PR version against an older version of the target branch
			enum qStr = "SELECT COUNT(*) FROM [Tasks] " ~
				"JOIN [Jobs] ON [Tasks].[Hash]=[Jobs].[Hash] " ~
				"WHERE [Status] IN ('success', 'failure', 'error') " ~
				"AND [ClientID]=? AND [Key] LIKE ?";
			auto keyPattern = "%s:pr:%s:%s:%d:%s:%%".format(targetBranch, org, repo, number, commit);
			if (query(qStr).iterate(clientID, keyPattern).selectValue!int() > 0)
				return Priority(Priority.Group.idle, time.stdTime); // already tested this PR version against an older version of the target branch
			return Priority(Priority.Group.newPR, time.stdTime);
		}

		// override string[] getClientCommandLine()
		// {
		// 	// TODO: dependencies
		// 	return [
		// 		"--fetch", "%s|origin|".format(repo, number),
		// 		"--merge", "%s|%s".format(repo, commit),
		// 		branchCommit
		// 	];
		// }

		override string getComponentCommit(string organization, string repository) const
		{
			if (isInMetaRepository(organization, repository))
				foreach (merge; merges)
					if (repository == merge.repository)
						return merge.commit;
			return super.getComponentCommit(organization, repository);
		}

		override string getComponentRef(string organization, string repository) const
		{
			if (isInMetaRepository(organization, repository))
				foreach (merge; merges)
					if (repository == merge.repository)
						return merge.remoteRef;
			return super.getComponentRef(organization, repository);
		}
	}

	handleTask(new PullTask, action);
}

/// Get the current state of the meta-repository branches from BitBucket.
void getBranches()
{
	log("Querying branches");

	auto response = httpQuery("https://api.bitbucket.org/2.0/repositories/cybershadow/d/refs/branches?pagelen=100").parseJSON();
	enforce(response.object["size"].integer < response.object["pagelen"].integer, "Paged BitBucket object"); // TODO

	foreach (value; response.object["values"].array)
	{
		auto name = value.object["name"].str;
		auto hash = value.object["target"].object["hash"].str;
		auto date = value.object["target"].object["date"].str.parseTime!(TimeFormats.RFC3339)();
		handleBranch(date, name, hash, Action.resume);
	}

	foreach (org, repos; testedRepos)
		foreach (repo; repos)
			foreach (branch; httpQuery("https://api.github.com/repos/" ~ org ~ "/" ~ repo ~ "/branches?per_page=100").parseJSON().array)
				branches["%s:%s:%s".format(org, repo, branch.object["name"].str)] = branch.object["commit"].object["sha"].str;
}

/// Get the current state of pull requests from GitHub.
void getPullRequests()
{
	log("Querying pulls");

	JSONValue[] pulls;

	foreach (org, repos; testedRepos)
		foreach (repo; repos)
			pulls ~= httpQuery("https://api.github.com/repos/" ~ org ~ "/" ~ repo ~ "/pulls?per_page=100").parseJSON().array;

	log("Registering pulls");

	foreach (pull; pulls)
	{
		auto sha = pull["head"]["sha"].str;
		auto org = pull["base"]["user"]["login"].str;
		auto repo = pull["base"]["repo"]["name"].str;
		int n = pull["number"].integer.to!int;
		auto date = pull["updated_at"].str.parseTime!(TimeFormats.ISO8601)();
		auto target = pull["base"]["ref"].str;
		auto description = null; // TODO (requires separate request)
		handlePull(date, org, repo, n, sha, target, null, Action.resume);
	}
}

void initializeGitHub()
{
	assert(!allClients.length, "Scheduler initialization should occur before client initialization");

	getBranches();
	getPullRequests();

	log("GitHub: Initialized.");
}
