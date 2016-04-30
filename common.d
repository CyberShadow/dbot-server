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

		enum Platform
		{
			unknown,
			windows,
			linux64,
			// ... add as needed ...
		}
		Platform platform;

		string dir; // Working directory on the host
	}
	Client[string] clients; // key is client ID

	struct Web
	{
		string addr;
		ushort port = 80;
	}
	Web web;

	string localCache; // Location of the cache for the "local" remote

	string githubToken;
}

immutable Config config;

shared static this()
{
	config = cast(immutable)
		loadIni!Config("conf/dbot.ini");
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

const clientOrganization = "CyberShadow";
const clientRepository = "dbot-client";

/// The repositories we're testing
immutable string[][string] testedRepos;
shared static this() { testedRepos = [
	"dlang" : ["dlang.org", "dmd", "druntime", "phobos", "tools"],
	clientOrganization : [clientRepository],
]; }

bool isInMetaRepository(string org, string repo)
{
	return org == "dlang";
}

//const mainBranches = ["master", "stable"];

enum JobStatus
{
	started,   /// A client is working on this right now
	aborted,   /// Explicitly aborted due to one reason or another (see error field)
	orphaned,  /// The server was killed/restarted while this job was still running
	obsoleted, /// Job killed because a newer version of this PR has been pushed
	tempfail,  /// Job failed, but we should retry it
	success,   /// Job completed, all is well
	failure,   /// Job completed, something is not well
	error,     /// Job failed due to something that should not normally happen
}

// ***************************************************************************

// TODO: This is shared code with DFeed and others. Belongs in its own ae module

import ae.sys.sqlite3;

SQLite db;

shared static this()
{
	auto dbFileName = "stor/dbot.s3db";

	void createDatabase(string target)
	{
		log("Creating new database from schema");
		ensurePathExists(target);
		enforce(spawnProcess(["sqlite3", target], File("schema.sql", "rb")).wait() == 0, "sqlite3 failed");
	}

	if (!dbFileName.exists)
		atomic!createDatabase(dbFileName);

	db = new SQLite(dbFileName);

	query("PRAGMA case_sensitive_like = ON").exec();
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

int transactionDepth;

enum DB_TRANSACTION = q{
	if (transactionDepth++ == 0) query("BEGIN TRANSACTION").exec();
	scope(failure) if (--transactionDepth == 0) query("ROLLBACK TRANSACTION").exec();
	scope(success) if (--transactionDepth == 0) query("COMMIT TRANSACTION").exec();
};
