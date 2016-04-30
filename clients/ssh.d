module clients.ssh;

import core.sys.posix.unistd : dup;

import std.algorithm.searching;
import std.process;
import std.string;

import ae.net.asockets;
import ae.utils.json;
import ae.utils.meta : GenerateContructorProxies;

import dbot.protocol;

import clients;
import common;
import scheduler.common;

alias Config = common.Config;

final class SshClient : Client
{
	mixin GenerateContructorProxies;

	private class SshJob : Job
	{
		Pid pid;
		string abortReason;

		static class ProcessConnection : TcpConnection
		{
			this(Socket conn)
			{
				conn.blocking = false;
				super(conn);
			}
		}
		ProcessConnection cStdOut, cStdErr;

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
			log("Launching command: %s".format(args));
			pid = spawnProcess(args, fStdIn, fStdOut, fStdErr);

			// just in case these callbacks outlive the job
			abortReason = null;

			ProcessConnection wrapSocket(Socket socket, Message.Log.Type messageLogType)
			{
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

				lbuf.handleDisconnect =
					(string reason, DisconnectType type)
					{
						if (this.done)
						{
							// The job has already been completed and its log closed,
							// but we still need to reap the process if necessary.
							if (pid)
							{
								pid.wait();
								this.pid = null;
							}
							return; // Doesn't matter, already completed
						}

						log("Stream %s disconnected (%s) with reason %s".format(messageLogType, type, reason));
						if (messageLogType == Message.Log.Type.stdout) // Just for one of them
						{
							log("Reaping process %d...".format(pid.processID));
							auto status = pid.wait();
							this.pid = null;
							log("Reaped with status %d.".format(status));
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
						}
					};
				return conn;
			}

			cStdOut = wrapSocket(pStdOut[1], Message.Log.Type.stdout);
			cStdErr = wrapSocket(pStdErr[1], Message.Log.Type.stderr);
		}

		override void abort(string reason)
		{
			log("Aborting (%s) - killing process %d".format(reason, pid.processID));
			abortReason = reason;
			if (cStdOut && cStdOut.state != ConnectionState.disconnected)
				cStdOut.disconnect();
			if (cStdErr && cStdErr.state != ConnectionState.disconnected)
				cStdErr.disconnect();
			if (pid) // Usually the process will be reaped by the disconnect handlers
				pid.kill();
		}
	}

	override Job createJob() { return new SshJob; }

	override void startJob(Job job)
	{
		auto cmdLine = ["bash", "-s"];
		cmdLine ~= bootstrapArgs;
		cmdLine ~= job.task.spec.commandLine;
		cmdLine = ["ssh", clientConfig.ssh.host, escapeShellCommand(cmdLine)];
		(cast(SshJob)job).launch(cmdLine);
	}
}
