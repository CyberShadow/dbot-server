module scheduler.common;

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
	long id;

	/// Contains:
	/// - information that's passed on the client's command line
	/// - information needed by scheduler to mark the task as completed
	///   and make relevant information available
	/// - information needed to know whether this job should be canceled?
	///   (we can also store pointers to this job)

	Task task;
}

struct LogMessage
{
	enum Type
	{
		log,
		stdout,
		stderr,
	}
	Type type;
	SysTime time;
	string text;
}

struct JobResult
{
	LogMessage[] log;
	JobStatus status; /// success/failure/error/obsoleted
	string error; /// error message; null if no error
	// TODO: coverage
	// TODO: metrics
}

/// Return the next task to be done by a worker client,
/// or null if there is no more work for this client.
Job* getJob(string clientID)
{
	// TODO: Find a job
	// TODO: Save to database that this job has been started
	// TODO: Multiple job sources (pull scheduler)

	auto job = new Job;
	job.id = db.lastInsertRowID;

	return null;
}

class TaskSource
{
	abstract InputRange!Task getTasks(Priority.Group priorityGroup);
}

TaskSource function(string clientID)[] taskSourceFactories;

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
	/// The task key, used to uniquely identify a testable item such as a pull request or meta-repository branch.
	/// E.g. one pull request is one task, even if it's updated / rebased, or the branch it's targeting is updated.
	abstract @property string taskKey();

	/// The job key, used to uniquely identify a concrete job for any given version of a task.
	/// E.g. each time a pull request, or the branch it's targeting, is updated, should result in a different job key.
	/// The job key is structured in a way that prefixed searches should find relevant jobs for a given topic
	/// (e.g. all jobs belonging to a pull request, or to a specific pull request version, or to a pull request version
	/// targeting a specific target branch version.
	abstract @property string jobKey();

	/// Return true if we should abort the given job due to the given action performed with this task.
	/// E.g. if action is Action.create or Action.modify, does this task supersede that job?
	/// Or if action is Action.remove, does that (the PR being closed etc.) make this job obsolete?
	bool obsoletes(Job* job, Action action) { return false; }

	/// Return the priority (higher = more important) for the given client ID.
	/// Return PriorityGroup.none to skip this task for this client.
	abstract Priority getPriority(string clientID);

	/// Return what to pass on the client command line.
	abstract string[] getClientCommandLine();
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
	foreach (client; clients)
		if (client.job && task.obsoletes(client.job, action))
			client.abortJob();
	prodClients();
}
