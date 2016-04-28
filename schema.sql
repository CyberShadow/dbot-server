CREATE TABLE [Jobs] (
[ID] INTEGER PRIMARY KEY NOT NULL AUTOINCREMENT, -- Job ID
[MainlineBranch] VARCHAR(32) NOT NULL, -- Name of branch tested
[MainlineCommit] CHAR(40) NOT NULL, -- SHA1 of meta-repository mainline branch commit
[PRComponent] VARCHAR(32) NULL, -- Component of pull request which triggered this job
[PRNumber] INTEGER NOT NULL DEFAULT 0, -- Pull request number
[Merges] TEXT NOT NULL, -- component:SHA1 list, incl. dependencies
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
