module clients.ssh;

import core.sys.posix.unistd : dup;

import std.algorithm.searching;
import std.process;

import ae.net.asockets;
import ae.utils.json;
import ae.utils.meta : GenerateContructorProxies;

import dbot.protocol;

import clients;
import common;
import scheduler.common;

alias Config = common.Config;

class SshClient : Client
{
	mixin GenerateContructorProxies;

	Pid pid;
	string abortReason;

	final void launch(string[] args)
	{
		import std.socket;
		import std.stdio;

		auto pStdOut = socketPair();
		auto pStdErr = socketPair();

		File fStdOut, fStdErr;
		fStdOut.fdopen(dup(pStdOut[0].handle));
		fStdErr.fdopen(dup(pStdErr[0].handle));
		auto fStdIn = File("data/client-bootstrap.sh", "rb");
		auto pid = spawnProcess(args, fStdIn, fStdOut, fStdErr);
		this.pid = pid;

		// just in case these callbacks outlive the job
		auto job = this.job;
		abortReason = null;

		void wrapSocket(Socket socket, Message.Log.Type messageLogType)
		{
			static class ProcessConnection : TcpConnection
			{
				this(Socket conn)
				{
					conn.blocking = false;
					super(conn);
				}
			}

			auto conn = new ProcessConnection(socket);
			auto lbuf = new LineBufferedAdapter(conn);
			lbuf.delimiter = "\n";
			lbuf.handleReadData =
				(Data data)
				{
					auto str = cast(string)data.toHeap();
					debug scope(failure) log("Error with line: " ~ str);
					if (str.skipOver("dbot-client: "))
						handleMessage(job, jsonParse!Message(str));
					else
					{
						Message message;
						message.type = Message.Type.log;
						message.log.type = messageLogType;
						message.log.text = str;
						handleMessage(job, message);
					}
				};

			if (messageLogType == Message.Log.Type.stdout)
				lbuf.handleDisconnect =
					(string reason, DisconnectType type)
					{
						if (!job.done)
						{
							if (abortReason)
							{
								this.result.status = JobStatus.aborted;
								this.result.error = abortReason;
							}
							else
							{
								this.result.status = JobStatus.error;
								this.result.error = "Unexpected disconnect (" ~ reason ~ ")";
							}
							reportResult(job);
						}
						pid.wait();
					};
		}

		wrapSocket(pStdOut[1], Message.Log.Type.stdout);
		wrapSocket(pStdErr[1], Message.Log.Type.stderr);
	}

	override void startJob()
	{
		auto cmdLine = ["ssh", clientConfig.ssh.host, "bash", "-s"];
		cmdLine ~= bootstrapArgs;
		cmdLine ~= job.task.spec.commandLine;
		launch(cmdLine);
	}

	override void abortJob(string reason)
	{
		assert(job);
		abortReason = reason;
		pid.kill(1);
	}
}
