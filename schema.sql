CREATE TABLE [Jobs] (
[ID] INTEGER PRIMARY KEY NOT NULL AUTOINCREMENT, -- Job ID
[StartTime] INTEGER NOT NULL,
[FinishTime] INTEGER NOT NULL DEFAULT 0,
[Key] TEXT NOT NULL, -- Hierarchical job key
[ClientArguments] TEXT NOT NULL; -- JSON-encoded array of relevant client arguments (should this job need to be repeated)
[ClientID] VARCHAR(32) NOT NULL, -- ID of client that executed this job
[Status] VARCHAR(32) NOT NULL, -- Job status
[Error] TEXT NULL,
);

CREATE TABLE [Metrics] (
[JobID] INTEGER NOT NULL,
[TestID] VARCHAR(100) NOT NULL,
[Value] INTEGER NOT NULL,
[Error] TEXT NULL
);

CREATE UNIQUE INDEX [ResultIndex] ON [Metrics] (
[JobID] ASC,
[TestID] ASC
);
