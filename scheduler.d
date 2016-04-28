import std.conv;
import std.exception;
import std.datetime;
import std.json;
import std.string;

import ae.utils.time.common;
import ae.utils.time.parse;

import clients : clients, prodClients;
import common;
import api;

/*
  Goals:
  - Run jobs in this order:
    - Mainline branches
    - Untested pulls (most recently updated first)
    - Interleave of:
      - Tested pulls (most recently updated first)
      - Old versions (for performance charts)
  - Avoid database queries in getTask ("thundering herd")
  - Unqueue / abort obsolete jobs
  - Unqueue / abort jobs for closed PRs

  - Branch updates should unqueue (or update) queued jobs targeting the old branch

  - Do we create a Job ID at queue or start time?

  Scenarios:
  - Enumerate all branches on startup
  - Enumerate all open PRs on startup

  Conclusions:
  - Priorities depend on the client and are a property of the job,
    thus a pre-sorted Task array does not work
  - Aside from PR/branch creation/deletion, the number of tasks is constant
    - isSupersededBy is not needed?
  - We still need to get the mainline branch

  Options:
  1. Task*[] tasks + isSupersededBy + isObsoletedBy

  2. Task*[string...] branches + Task*[string...] pullRequests + isObsoletedBy

  3. Task*[key] tasks + isObsoletedBy

  4. string...[string...] branches, pullRequests
     - logic will be less general
*/

/// One job per client
struct Job
{
	/// Contains:
	/// - information that's passed on the client's command line
	/// - information needed by scheduler to mark the task as completed
	///   and make relevant information available
	/// - information needed to know whether this job should be canceled?
	///   (we can also store pointers to this job)

	Task task;
}

/// Return the next task to be done by a worker client,
/// or null if there is no more work for this client.
Job* getJob(string clientID)
{
	// TODO: Find a job
	// TODO: Save to database that this job has been started
	// TODO: Multiple job sources (pull scheduler)
	return null;
}

/// Called by a client to report a job's completion.
void jobComplete(Job* job)
{
	// TODO: Save to database
}

/*
/// One task for multiple clients
struct Task
{
	enum Type
	{
		branch,
		pr,
	}
	Type type;

	string organization, repository;

	// Type.branch:
	string branchName;

	// Type.pr:
	string prNumber;
}
*/

struct Priority
{
	/// Priority group, highest first.
	/// Multiple sources from the same group get interleaved.
	enum Group
	{
		branch,
		newPR,
		idle,
		none, /// don't test at all
	}
	Group group;

	/// Order within the group, highest first.
	long order;
}

class Task
{
	abstract @property string key();

	/// Return true if we should abort the given job due to the given action performed with this task.
	/// E.g. if action is Action.create or Action.modify, does this task supersede that job?
	/// Or if action is Action.remove, does that (the PR being closed etc.) make this job obsolete?
	bool obsoletes(Job* job, Action action) { return false; }

	/// Return the priority (higher = more important) for the given client ID.
	/// Return PriorityGroup.none to skip this task for this client.
	abstract Priority getPriority(string clientID);
}

/*
/// Return true if we should unqueue (but not
/// abort) oldTask in favor of newTask.
bool isSupersededBy(Task* oldTask, Task* newTask)
{
	// TODO
	return false;
}

bool isObsoletedBy(Task* oldTask, Task* newTask)
{
	// TODO
	return false;
}

/// Return true if we should abort any running oldTask jobs when it is deleted
/// (i.e. its pull request is closed).
bool isObsoletedByDeletion(Task* oldTask)
{
	// TODO
	return false;
}
*/

Task[string] tasks;

enum Action
{
	create,
	modify,
	remove,
}

void handleTask(Task task, Action action)
{
	if (action == Action.remove)
	{
		assert(task.key in tasks, "Deleting non-existing task %s".format(task.key));
		tasks.remove(task.key);
	}
	else
	{
		if (action == Action.create)
			assert(task.key !in tasks, "Creating already-existing task %s".format(task.key));
		tasks[task.key] = task;
	}
	foreach (client; clients)
		if (client.job && task.obsoletes(client.job, action))
			client.abortJob();
	prodClients();
}

string[string] branches;

/// Handle an updated meta-repository branch
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
	}

	handleTask(new BranchTask, action);
}

/// Handle a new or updated GitHub pull
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
	// TODO: Parse the description
	string merges = "%s:%s".format(repo, commit);

	if (targetBranch !in branches)
	{
		log("Ignoring pull request %s:%s:%d against unknown branch %s".format(org, repo, number, targetBranch));
		return;
	}

	class PullTask : Task
	{
		override @property string key() { return "pr:%s:%s:%d".format(org, repo, number); }

		override Priority getPriority(string clientID)
		{
			// TODO: Cache in RAM?
			// TODO: Indexes
			if (query("SELECT COUNT(*) FROM [Jobs] WHERE [ClientID]=? AND [Merges]=? AND [MainlineCommit]=?").iterate(clientID, merges, branches[targetBranch]).selectValue!int() > 0)
				return Priority(Priority.Group.none); // already tested this PR version against the current branch
			if (query("SELECT COUNT(*) FROM [Jobs] WHERE [ClientID]=? AND [Merges]=?"                       ).iterate(clientID, merges                        ).selectValue!int() > 0)
				return Priority(Priority.Group.idle, time.stdTime); // already tested this PR version against an older version of the target branch
			return Priority(Priority.Group.newPR, time.stdTime);
		}
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
		handleBranch(date, name, hash, Action.create);
	}
}

/// Get the current state of pull requests from GitHub.
void getPullRequests()
{
	JSONValue[] pulls;
	foreach (repo; testedRepos)
		pulls ~= httpQuery("https://api.github.com/repos/dlang/" ~ repo ~ "/pulls?per_page=100").parseJSON().array;

	log("Verifying pulls");

	foreach (pull; pulls)
	{
		auto sha = pull["head"]["sha"].str;
		auto repo = pull["base"]["repo"]["name"].str;
		int n = pull["number"].integer.to!int;
		auto date = pull["updated_at"].str.parseTime!(TimeFormats.ISO8601)();
	}
}

void initialize()
{
	assert(!clients.length, "Scheduler initialization should occur before client initialization");

	query("UPDATE [Jobs] SET [Status]='orphaned' WHERE [Status]='started'").exec();

	getBranches();
	getPullRequests();
}

