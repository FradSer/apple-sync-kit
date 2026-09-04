Feature: LocalSyncSource Storage Adapters

  Scenario: SnapshotSyncSource identifies modified records and deletion candidates
    Given a SnapshotSyncSource with a known remote entity state
    When local records have 1 unchanged item and 1 modified item
    Then changes returns only the modified item
    And changes returns remote IDs no longer present in local items

  Scenario: FlaggedSyncSource extracts local-only rows and tombstone records
    Given a SQLiteSyncStore backing a FlaggedSyncSource
    When 1 record is marked local-only and 1 record is marked deleted
    Then changes returns the local-only record
    And changes returns the deleted record ID
    And acknowledgePushed clears the local-only flag in the SQLite store

  Scenario: FlaggedSyncSource detects a known remote record missing locally
    Given the entity state knows a remote record that has no local row or tombstone
    And another non-deleted local row maps to its remote ID
    When changes discovers deletion candidates
    Then it includes the missing known remote ID
    And it excludes the mapped remote ID that is still present
    And explicit tombstones remain included without duplicates
    And explicit tombstones retain their stored deletion timestamp
    And missing-row deletions use the current observation timestamp

  Scenario: FlaggedSyncSource applies mapped remote updates to the local row
    Given a remote ID is mapped to a different local ID
    When a remote upsert is applied with the mapped local ID and remote timestamp
    Then the local row is updated at the mapped local ID
    And the local row stores the remote timestamp
