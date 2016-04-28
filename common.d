module common;

import std.exception;
import std.file;
import std.process;
import std.stdio;

import ae.utils.sini;
import ae.sys.file;
import ae.sys.log;

struct Config
{
	struct Client
	{
		enum Type
		{
			ssh,
		}
		Type type;

		struct SSH
		{
			string host;
		}
		SSH ssh;
	}
	Client[string] clients; // key is client ID

	string githubToken;
}

immutable Config config;

shared static this()
{
	config = cast(immutable)
		loadIni!Config("dbot.ini");
}

// ***************************************************************************

void log(string s)
{
	static Logger instance;
	if (!instance)
		instance = createLogger("DBot");
	instance(s);
}

// ***************************************************************************

/// The repositories we're testing
const testedRepos = ["dlang.org", "dmd", "druntime", "phobos", "tools"];

//const mainBranches = ["master", "stable"];

enum JobStatus
{
	started,   /// A client is working on this right now
	orphaned,  /// The server was killed/restarted while this job was still running
	obsoleted, /// Job killed because a newer version of this PR has been pushed
	success,   /// Job completed, all is well
	failure,   /// Job completed, something is not well
	error,     /// Job failed due to something that should not normally happen
}

// ***************************************************************************

import ae.sys.sqlite3;

SQLite db;

shared static this()
{
	auto dbFileName = "data/dbot.s3db";

	void createDatabase(string target)
	{
		log("Creating new database from schema");
		ensurePathExists(target);
		enforce(spawnProcess(["sqlite3", target], File("schema.sql", "rb")).wait() == 0, "sqlite3 failed");
	}

	if (!dbFileName.exists)
		atomic!createDatabase(dbFileName);

	db = new SQLite(dbFileName);
}

SQLite.PreparedStatement query(string sql)
{
	static SQLite.PreparedStatement[string] cache;
	if (auto pstatement = sql in cache)
		return *pstatement;
	return cache[sql] = db.prepare(sql).enforce("Statement compilation failed: " ~ sql);
}

T selectValue(T, Iter)(Iter iter)
{
	foreach (T val; iter)
		return val;
	throw new Exception("No results for query");
}
