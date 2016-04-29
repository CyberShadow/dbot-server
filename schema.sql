CREATE TABLE [Jobs] (
[ID] INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, -- Job ID
[StartTime] INTEGER NOT NULL,
[FinishTime] INTEGER NOT NULL DEFAULT 0,
[Hash] CHAR(40) NOT NULL, -- Unique hash for this job's parameters
[ClientID] VARCHAR(32) NOT NULL, -- ID of client that executed this job
[Status] VARCHAR(32) NOT NULL, -- Job status
[Error] TEXT NULL
);

CREATE INDEX [JobsHash] ON [Jobs] (
[ClientID],
[Hash]
);

CREATE TABLE [Tasks] (
[Key] TEXT NOT NULL, -- Hierarchical job key
[Spec] TEXT NOT NULL, -- JSON-encoded build spec
[Hash] CHAR(40) NOT NULL, -- [Jobs].[Hash]
UNIQUE([Key], [Hash])
);

CREATE TABLE [Metrics] (
[JobID] INTEGER NOT NULL,
[TestID] VARCHAR(100) NOT NULL,
[Value] INTEGER NOT NULL,
[Error] TEXT NULL
);

CREATE UNIQUE INDEX [MetricIndex] ON [Metrics] (
[JobID],
[TestID] ASC
);
