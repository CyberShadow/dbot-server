module clients;

import common;

class Client
{
	string id;

	this(string id)
	{
		this.id = id;
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
}

void startClients()
{
	foreach (id, config; config.clients)
	{
		final switch (config.type)
		{
			case Config.Client.Type.ssh:
				new SshClient(id, config.ssh);
		}
	}
}
