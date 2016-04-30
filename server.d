import ae.net.asockets;
import ae.net.ssl.openssl;
import ae.sys.net.ae;

import common;
import clients;

import scheduler.common;
import scheduler.github;
import web.server;

void main()
{
	log("Starting up");

	initializeScheduler();
	initializeGitHub();

	startWebServer();

	startClients();

	socketManager.loop();
}
