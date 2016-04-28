module clients;

import common;
import scheduler;

class Client
{
	string id;

	this(string id)
	{
		this.id = id;
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
	void abortJob()
	{
		// TODO: accept a reason parameter
	}
}

class SshClient : Client
{
	Config.Client.SSH clientConfig;

	this(string id, Config.Client.SSH clientConfig)
	{
		super(id);
		this.clientConfig = clientConfig;
	}

	override void startJob()
	{
		// TODO
		jobComplete(job);
		run();
	}
}

Client[string] clients;

void startClients()
{
	foreach (id, config; config.clients)
	{
		Client client;
		final switch (config.type)
		{
			case Config.Client.Type.ssh:
				client = new SshClient(id, config.ssh);
		}
		clients[id] = client;
		client.run();
	}
}

void prodClients()
{
	foreach (id, client; clients)
		client.prod();
}
