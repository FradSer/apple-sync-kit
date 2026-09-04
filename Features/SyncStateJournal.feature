Feature: Consolidated Sync State Journal

  Scenario: Consumer-owned JSON remains available outside the sync journal
    Given a consumer-owned Codable file path under its config namespace
    When ConfigStore atomically saves and strictly or leniently loads that file
    Then its value roundtrips without using legacy sync state paths

  Scenario: Atomic commit and roundtrip of sync journal state
    Given a clean temporary config store directory
    And an initial empty sync journal
    When an entity state, an ID mapping, and a pull cursor are added to the journal
    And the journal is committed as a checkpoint
    Then the sync-state.json file exists with mode 0o600
    And reloading the journal restores the exact entity state, ID mapping, and cursor

  Scenario: Strict error when sync journal is corrupted
    Given a corrupt sync-state.json file on disk
    When the journal load is attempted
    Then a SyncError.unknown is thrown indicating parse failure

  Scenario: Strict error when sync journal cannot be read
    Given the filesystem reports a read failure for sync-state.json
    When the journal load is attempted
    Then a SyncError.unknown is thrown indicating the journal could not be read
