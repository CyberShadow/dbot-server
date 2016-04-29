module clients.ssh;

import clients;
import common;
import scheduler.common;

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
		JobResult result;
		jobComplete(job, result);
		job = null;
		run();
	}
}
