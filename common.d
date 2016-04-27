module common;

import ae.utils.sini;

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
}

immutable Config config;

shared static this()
{
	config = cast(immutable)
		loadIni!Config("dbot.ini");
}
