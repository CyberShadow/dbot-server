module scheduler.common;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.json;
import std.path;
import std.range;
import std.stdio;
import std.string;

import ae.net.shutdown;
import ae.utils.json;
import ae.utils.meta : enumLength;
import ae.utils.text : arrayFromHex, toHex;
import ae.utils.time;
import ae.sys.file;

import dbot.protocol;

import api;
import clients;
import common;

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

struct LogMessage
{
	Message.Log.Type type;
	StdTime time;
	string text;
}

struct JobResult
{
	JobStatus status; /// success/failure/error/obsoleted
	string error; /// error message; null if no error
	// TODO: build cache keys (for doc diffs from local server)
	// TODO: coverage
	// TODO: metrics
}

/// A job is one client's task instance, and corresponds to one row in the [Jobs] table
class Job
{
	long id;   /// The job ID, as the [Jobs].[ID] database field
	Task task; /// The corresponding task
	JobResult result; /// Result so far

	bool done = false; // Result has been reported
	Message.Progress.Type progress;
	File logSink;

	void log(string text, Message.Log.Type type = Message.Log.Type.server)
	{
		LogMessage logMessage;
		logMessage.type = type;
		logMessage.text = text;
		logMessage.time = Clock.currTime().stdTime;

		logSink.writeln(logMessage.toJson());
		logSink.flush();

		if (type == Message.Log.Type.server)
			.log("[Job %d] %s".format(id, text));
	}

	/// Abort the currently running job, if possible.
	/// If aborted, client picks up the next job as usual.
	/// The partial job result must still be reported via jobComplete.
	void abort(string reason) {}
}

/// Represents all information needed to create or rerun a job
struct Spec
{
	/// The name of the meta-repository branch.
	string branchName;

	/// The commit hash on that branch.
	string branchCommit;

	/// Represents one ref to be merged into a tested source code snapshot.
	struct Merge
	{
		/// The name of the repository where the merge will be performed
		string repository;

		/// The remote name or URL to fetch from. Usually just "origin"
		string remote;

		/// The full remote name of the ref to fetch. Usually starts with "refs/"
		string remoteRef;

		/// The exact commit to merge.
		/// The ref will only be used to obtain the commit.
		/// We merge the commit to avoid race conditions.
		string commit;

		int opCmp(ref const Merge o) const
		{
			int result = cmp(repository, o.repository);
			if (!result)
				result = cmp(remoteRef, o.remoteRef);
			if (!result)
				result = cmp(commit, o.commit);
			return result;
		}
	}

	/// Any merges to be laid on top.
	Merge[] merges;

	// @property string jobKey()
	// {
	// 	// TODO

	// 	//override @property string jobKey() { return "%s:branch:%s".format(name, commit); }
	// 	//override @property string jobKey() { return "%s:pr:%s:%s:%d:%s:%s".format(targetBranch, org, repo, number, commit, branchCommit); }

	// 	return "%s:%-(%s%):%-(%s%):%-(%s%):%-(%s%):"

	// 	assert(false);
	// }

	@property string hash() const
	{
		// XOR all commit hashes.
		// Bonus: order doesn't matter.
		// Nothing else matters.

		ubyte[20] finalDigest;
		foreach (hash; chain(branchCommit.only, merges.map!(m => m.commit)))
		{
			ubyte[20] hashDigest;
			arrayFromHex(hash, hashDigest);
			finalDigest[] ^= hashDigest[];
		}
		return finalDigest.toHex();
	}

	@property string[] commandLine() const
	{
		string[] result;
		foreach (merge; merges)
			result ~= [
				"--fetch", "%s|%s|%s".format(merge.repository, merge.remote, merge.remoteRef),
				"--merge", "%s|%s".format(merge.repository, merge.commit),
			];
		result ~= [branchCommit];
		return result;
	}
}

string jobDir(long id)
{
	return "stor/jobs/%d".format(id);
}

/// Return the next task to be done by a worker client,
/// or null if there is no more work for this client.
Job getJob(Client client)
{
	if (shuttingDown)
		return null;

	auto task = (){
		auto taskSources = taskSourceFactories.map!(f => f(client.id)).array();

		foreach_reverse (priorityGroup; Priority.Group.idle .. enumLength!(Priority.Group))
		{
			// Alternate between multiple task sources at same priority
			static int[enumLength!(Priority.Group)][string] sourceCounters;
			if (client.id !in sourceCounters)
				sourceCounters[client.id] = typeof(sourceCounters[client.id]).init;
			auto counter = sourceCounters[client.id][priorityGroup]++;
			foreach (n; 0..taskSources.length)
			{
				auto tasks = taskSources[(n + counter) % $].getTasks(priorityGroup);
				if (!tasks.empty)
					return tasks.front;
			}
		}
		return null;
	}();

	if (!task)
	{
		log("No task found for client " ~ client.id);
		return null;
	}

	query("INSERT INTO [Jobs] ([StartTime], [Hash], [ClientID], [Status]) VALUES (?, ?, ?, ?)")
		.exec(Clock.currTime.stdTime, task.spec.hash, client.id, JobStatus.started.text);
	auto jobID = db.lastInsertRowID;

	auto job = client.createJob();
	job.id = jobID;
	job.task = task;

	auto logFileName = jobDir(job.id).buildPath("log.json");
	logFileName.ensurePathExists();
	job.logSink = File(logFileName, "wb");
	job.log("Assigning job %d (%s) for client %s".format(job.id, task.jobKey, client.id));

	return job;
}

class TaskSource
{
	// TODO: Maybe this should return just one valid task, and its priority?
	abstract InputRange!Task getTasks(Priority.Group priorityGroup);
}

TaskSource function(string clientID)[] taskSourceFactories;

/// Called by a client to report a job's completion, whether it suceeded or errored.
void jobComplete(Job job)
{
	assert(!job.done, "Duplicate job completion report");
	job.done = true;
	job.logSink.close();
	query("UPDATE [Jobs] SET [FinishTime]=?, [Status]=?, [Error]=?")
		.exec(Clock.currTime.stdTime, job.result.status.text, job.result.error);
	// TODO: Save other JobResult fields
}

/// Current commits of meta-repository and individual repository branches.
string[string] branches;

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
		none, /// don't test at all
		idle,
		newPR,
		branch,
	}
	Group group;

	/// Order within the group, highest first.
	long order;
}

/// Represents something testable - a branch, pull request, or old commit (for historical trend data).
class Task
{
	/// The task key, used to uniquely identify a testable item such as a pull request or meta-repository branch.
	/// E.g. one pull request is one task, even if it's updated / rebased, or the branch it's targeting is updated.
	abstract @property string taskKey() const;

	/// The job key, used to uniquely identify a concrete job for any given version of a task.
	/// E.g. each time a pull request, or the branch it's targeting, is updated, should result in a different job key.
	/// The job key is structured in a way that prefixed searches should find relevant jobs for a given topic
	/// (e.g. all jobs belonging to a pull request, or to a specific pull request version, or to a pull request version
	/// targeting a specific target branch version).
	/// Note that this job key does not identify a job uniquely - two pull requests that depend on one another
	/// will have two different job keys, but will be tested once.
	abstract @property string jobKey() const;

	/// Return the job spec.
	abstract @property Spec spec() const;

	/// Return true if we should abort the given job due to the given action performed with this task.
	/// E.g. if action is Action.create or Action.modify, does this task supersede that job?
	/// Or if action is Action.remove, does that (the PR being closed etc.) make this job obsolete?
	bool obsoletes(Job job, Action action) const { return false; }

	/// Return the priority (higher = more important) for the given client ID.
	/// Return PriorityGroup.none to skip this task for this client.
	abstract Priority getPriority(string clientID) const;

	/// Return what to pass on the client command line.
	//abstract string[] getClientCommandLine();

	/// Get commit for component not in meta-repository.
	string getComponentCommit(string organization, string repository) const
	{
		return branches["%s:%s:%s".format(organization, repository, "master")];
	}

	/// Get ref for component not in meta-repository.
	string getComponentRef(string organization, string repository) const
	{
		return "refs/heads/master";
	}
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

/// Live tasks by key.
Task[string] tasks;

/// How did the task's state change?
enum Action
{
	resume, /// It was there when we started
	create, /// It was just created
	modify, /// It already existed, and has been updated
	remove, /// It was just deleted
}

/// Handle a task state change
void handleTask(Task task, Action action)
{
	if (action == Action.remove)
	{
		assert(task.taskKey in tasks, "Deleting non-existing task %s".format(task.taskKey));
		tasks.remove(task.taskKey);
	}
	else
	{
		if (action == Action.modify)
			assert(task.taskKey in tasks, "Modifying non-existing task %s".format(task.taskKey));
		else
			assert(task.taskKey !in tasks, "Creating already-existing task %s".format(task.taskKey));
		tasks[task.taskKey] = task;
	}
	foreach (client; allClients)
		if (client.job && task.obsoletes(client.job, action))
			client.job.abort("Obsoleted by %s".format(task.jobKey));
	prodClients();

	if (action != Action.remove)
	{
		auto spec = task.spec;
		spec.merges.sort();
		query("INSERT OR IGNORE INTO [Tasks] ([Key], [Spec], [Hash]) VALUES (?, ?, ?)").exec(task.jobKey, spec.toJson(), spec.hash);
	}
}

private bool shuttingDown = false;

void initializeScheduler()
{
	assert(!allClients.length, "Scheduler initialization should occur before client initialization");

	query("UPDATE [Jobs] SET [Status]='orphaned' WHERE [Status]='started'").exec();

	addShutdownHandler({ shuttingDown = true; });
}
