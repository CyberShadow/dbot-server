module clients;

import std.datetime;
import std.string;

import ae.utils.json;

import dbot.protocol;

import clients.ssh;
import common;
import scheduler.common;

class Client
{
	this(string id, Config.Client clientConfig)
	{
		this.id = id;
		this.clientConfig = clientConfig;
	}


	Job* job;

	final void run()
	{
		assert(!job);
		job = getJob(id);
		if (job)
			startJob();
	}

	final void prod()
	{
		if (!job)
			run();
	}

	abstract void startJob();

	/// Abort the currently running job, if possible.
	/// If aborted, client becomes idle. Prod if necessary.
	/// The partial job result should still be reported via jobComplete.
	void abortJob()
	{
		// TODO: accept a reason parameter
	}

protected:
	Config.Client clientConfig;
	string id;

	/// DMD version used to build the client
	static const dmdVer = "2.071.0";

	/// Return download URL for the DMD zip for this platform
	static string dmdURL(Config.Client.Platform platform)
	{
		string zipPlatform;
		final switch (platform)
		{
			case Config.Client.Platform.windows:
				zipPlatform = "windows";
				break;
			case Config.Client.Platform.linux64:
				zipPlatform = "linux";
				break;
			case Config.Client.Platform.unknown:
				assert(false);
		}
		return "http://downloads.dlang.org/releases/2.x/%s/dmd.%s.%s.zip".format(dmdVer, dmdVer, zipPlatform);
	}

	/// Return path for the bin directory in the DMD zip for this platform
	static string binPath(Config.Client.Platform platform)
	{
		final switch (platform)
		{
			case Config.Client.Platform.windows:
				return "windows/bin";
			case Config.Client.Platform.linux64:
				return "linux/bin64";
			case Config.Client.Platform.unknown:
				assert(false);
		}
	}

	final string[] bootstrapArgs()
	{
		return [
			clientConfig.dir,
			dmdURL(clientConfig.platform),
			"dmd.%s/%s/rdmd".format(dmdVer, binPath(clientConfig.platform)),
			job.task.getComponentCommit(clientOrganization, clientRepository),
			job.task.getComponentRef(clientOrganization, clientRepository),
		];
	}

	JobResult result; // Result so far

	final void handleMessage(Job* job, Message message)
	{
		final switch (message.type)
		{
			case Message.Type.log:
			{
				LogMessage logMessage;
				logMessage.type = message.log.type;
				logMessage.text = message.log.text;
				logMessage.time = Clock.currTime().stdTime;

				job.logSink.writeln(logMessage.toJson());
				job.logSink.flush();

				if (!job.done && message.log.type == Message.Log.Type.error)
				{
					result.status = JobStatus.failure;
					result.error = message.log.text;
					jobComplete(job, result);
				}
				break;
			}
			case Message.Type.progress:
				job.progress = message.progress.type;
				if (!job.done && job.progress == Message.Progress.Type.done)
				{
					result.status = JobStatus.success;
					jobComplete(job, result);
				}
				break;
		}
	}
}

Client[string] allClients;

void startClients()
{
	foreach (id, clientConfig; config.clients)
	{
		Client client;
		final switch (clientConfig.type)
		{
			case Config.Client.Type.ssh:
				client = new SshClient(id, clientConfig);
		}
		allClients[id] = client;
		client.run();
	}
}

void prodClients()
{
	foreach (id, client; allClients)
		client.prod();
}
