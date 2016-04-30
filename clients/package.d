module clients;

import std.datetime;
import std.string;

import ae.net.shutdown;
import ae.utils.json;

import dbot.protocol;

import clients.ssh;
import common;
import scheduler.common;

// TODO: time-outs

class Client
{
	Config.Client clientConfig;
	string id;

	Job job; /// Current job

	this(string id, Config.Client clientConfig)
	{
		this.id = id;
		this.clientConfig = clientConfig;
	}

	final void prod()
	{
		if (!job)
			run();
	}

	Job createJob() { return new Job(); }

private:
	final void run()
	{
		assert(!job);
		job = getJob(this);
		if (job)
			startJob(job);
	}

protected:
	abstract void startJob(Job job); /// Start the assigned job.

	/// DMD version used to build the client
	static const dmdVer = "2.071.0";

	/// Return DMD zip file name suffix for this platform
	static string zipSuffix(Config.Client.Platform platform)
	{
		final switch (platform)
		{
			case Config.Client.Platform.windows:
				return "windows";
			case Config.Client.Platform.linux64:
				return "linux";
			case Config.Client.Platform.unknown:
				assert(false, "Unspecified client platform");
		}
	}

	/// Return download URL for the DMD zip for this platform
	static string dmdURL(Config.Client.Platform platform)
	{
		return "http://downloads.dlang.org/releases/2.x/%s/dmd.%s.%s.zip".format(dmdVer, dmdVer, zipSuffix(platform));
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
				assert(false, "Unspecified client platform");
		}
	}

	final string[] bootstrapArgs()
	{
		return [
			clientConfig.dir,
			dmdURL(clientConfig.platform),
			"dmd.%s.%s/dmd2/%s/rdmd".format(dmdVer, zipSuffix(clientConfig.platform), binPath(clientConfig.platform)),
			job.task.getComponentCommit(clientOrganization, clientRepository),
			job.task.getComponentRef(clientOrganization, clientRepository),

			"--id",
			this.id,
		];
	}

	final void handleMessage(Job job, Message message)
	{
		final switch (message.type)
		{
			case Message.Type.log:
			{
				job.log(message.log.text, message.log.type);

				if (!job.done && message.log.type == Message.Log.Type.error)
				{
					job.result.status = JobStatus.failure;
					if (message.log.text.length)
						job.result.error = message.log.text.splitLines()[0];
					reportResult(job);
				}
				break;
			}
			case Message.Type.progress:
				job.progress = message.progress.type;
				log("Client %s / job %d progress: %s".format(this.id, job.id, message.progress.type));
				if (!job.done && job.progress == Message.Progress.Type.done)
				{
					job.result.status = JobStatus.success;
					reportResult(job);
				}
				break;
		}
	}

	final void reportResult(Job job)
	{
		job.log("Job %d (%s) belonging to client %s complete with status %s (%s)"
			.format(job.id, job.task.jobKey, this.id, job.result.status, job.result.error ? job.result.error : "no error"));
		assert(job is this.job);
		this.job = null;
		jobComplete(job);
		run();
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
				break;
		}
		allClients[id] = client;
		client.run();
	}

	addShutdownHandler({ stopClients("DBot server shutting down"); });
}

void stopClients(string reason)
{
	foreach (id, client; allClients)
		if (client.job)
			client.job.abort(reason);
}

void prodClients()
{
	foreach (id, client; allClients)
		client.prod();
}
