import ae.net.asockets;
import ae.net.ssl.openssl;
import ae.sys.net.ae;

import clients;

import scheduler.common;
import scheduler.github;

void main()
{
	// TODO: Start web server

	initializeScheduler();
	initializeGitHub();
	// TODO: Grab initial GitHub data (pulls to test)

	startClients();

	socketManager.loop();
}
