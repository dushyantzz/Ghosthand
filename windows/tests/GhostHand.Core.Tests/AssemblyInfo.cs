using Xunit;

// Match GhostHand.Tests: keep the suite serial so a shared temp directory or audit log
// ordering can never make a failure flaky.
[assembly: CollectionBehavior(DisableTestParallelization = true)]
