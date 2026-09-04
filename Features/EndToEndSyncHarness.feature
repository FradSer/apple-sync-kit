Feature: End-to-End Sync Harness

  Scenario: Full bidirectional sync with memory source and checkpoint commit
    Given an InMemorySyncSource with local items
    And an initialized SyncCoordinator
    When coordinator executes push and pull
    Then pushed items are marked synced in the journal
    And pulled items from remote are stored in the memory source
    And the sync-state.json journal contains the latest checkpoint

  Scenario: Mixed push results only acknowledge accepted records
    Given an InMemorySyncSource with two local items
    And the remote accepts one item and skips one item
    When coordinator executes push
    Then only the accepted item is acknowledged
    And the skipped item remains pending
