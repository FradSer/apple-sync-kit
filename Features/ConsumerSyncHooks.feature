Feature: Consumer synchronization hooks

  Scenario: Push and pull payload transforms preserve local snapshots
    Given a LocalSyncSource that transforms records for the remote payload
    When the coordinator pushes a local record
    Then the transformed payload is sent to the remote client
    And the local record is recorded in the journal without the transformed payload
    When a transformed pull page is returned
    Then the source receives the transformed-back record
    And the journal records the transformed-back local value

  Scenario: Pull filtering and domain not-found handling stay inside the source seam
    Given a LocalSyncSource with a pull-item filter and domain not-found classifier
    When a filtered remote upsert or tombstone is returned
    Then filtering runs before either item is applied or changes state and mappings
    And the coordinator advances the cursor without applying the filtered items
    When applying an accepted tombstone raises the source's not-found error
    Then the coordinator removes the mapping and continues the pull

  Scenario: Built-in sources expose focused consumer hooks
    Given a SnapshotSyncSource or FlaggedSyncSource configured with consumer closures
    When push transformation, pull filtering, deletion filtering, metadata, not-found, or deletion finalization is needed
    Then the configured closure implements that behavior without a wrapper source type

  Scenario: Accepted push IDs cross the transport boundary
    Given the worker accepts only a subset of pushed records
    When its response is decoded as PushResult
    Then synced_ids identifies exactly the accepted records for local acknowledgement

  Scenario: Extra entity metadata is recorded for push and pull
    Given a LocalSyncSource that records entity-specific metadata
    When a record is pushed or pulled
    Then the metadata is stored in the journal's entity state
