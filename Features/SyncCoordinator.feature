Feature: Deep SyncCoordinator Orchestrator

  Scenario: Full bidirectional sync execution with file lock and journal checkpoint
    Given an initialized SyncCoordinator with valid config and store
    And a mock remote D1 sync client
    And a LocalSyncSource with 1 dirty record
    When coordinator.sync(source: source) is invoked
    Then the file lock is held during execution
    And the dirty record is pushed to remote
    And remote pull updates are applied to the source
    And the updated state is checkpointed in sync-state.json
    And the lock is released
    And a SyncResult containing push and pull counts is returned

  Scenario: A local deletion sends its observation timestamp
    Given a remote record was last synced at t1
    When the local deletion is observed at t3
    Then the coordinator sends t3 with the remote delete rather than t1
    And a competing remote update from t2 is rejected by the worker

  Scenario: A tombstone retains its deletion timestamp for last-write-wins
    Given a live remote record was last modified at t1
    When it is deleted at t3 and an upsert from t2 arrives later
    Then the stale upsert is rejected
    And pulls still return the tombstone with last modified t3

  Scenario: An absent remote deletion is idempotently accepted
    Given a deletion candidate no longer exists on the worker
    When the coordinator pushes its deletion
    Then the worker reports the deletion accepted
    And local deletion bookkeeping is finalized

  Scenario: A stale remote deletion is rejected without local cleanup
    Given a deletion candidate maps a remote ID to a different local ID
    And the worker rejects its stale last-write-wins tombstone
    When the coordinator pushes deletions
    Then local finalization does not run
    And mapping and entity state remain for a future retry

  Scenario: Failed local deletion finalization preserves retry bookkeeping
    Given a deletion candidate maps a remote ID to a different local ID
    And the remote delete succeeds but local finalization fails
    When the push is retried
    Then the original remote ID and mapped local ID are used again
    And mapping and entity state are removed only after finalization succeeds

  Scenario: Accepted and skipped pushes are acknowledged independently
    Given a LocalSyncSource with 2 dirty records
    And the remote accepts the first record and skips the second record
    When coordinator.push(source: source) is invoked
    Then the accepted record is checkpointed and acknowledged
    And the skipped record remains pending locally

  Scenario: Concurrency protection during active sync
    Given an existing process holding the sync lock
    When coordinator.sync(source: source) is invoked
    Then it throws SyncError.alreadyRunning immediately
    And no remote push or pull requests are executed

  Scenario: A caller holds one lock and client across a multi-entity session
    Given the caller starts a shared coordinator session
    When multiple coordinator operations use caller-managed locking
    Then each operation runs without acquiring a second lock
    And every operation reuses the same remote client lifecycle
    And automatic locking remains the default for other calls

  Scenario: An entity without comparable timestamps explicitly accepts remote state
    Given a local record exists without a comparable timestamp
    And its source reports the accept-remote conflict state
    When a remote upsert is pulled
    Then the remote record replaces the local record
