ExUnit.start()

Mox.defmock(Buildex.Common.TaskMockRunner, for: Buildex.Common.Tasks.Runners.Runner)
Mox.defmock(Buildex.Common.TaskMockSource, for: Buildex.Common.Tasks.Sources.Source)
Mox.defmock(Buildex.Common.Service.MockDatabase, for: Buildex.Common.Services.Database)
