# BDD Specifications — Dual-Mode Sync

Planning-stage Gherkin. Kit-side scenarios become XCTest in `Tests/AppleSyncKitTests/`. Scenarios
tagged `@worker` belong to the separate Worker repo and are out of the kit's test scope. Vocabulary is
canonical per the glossary in `_index.md` ("self-host mode", "cloud mode", "tenant", "API token",
"AuthClient", "Worker").

## Feature: Self-host mode regression (static API token)

```gherkin
Feature: Self-host mode keeps working unchanged
  As a self-hosting user
  I want existing env/file config with a static API token to keep working
  So that adding cloud mode changes nothing for me

  Scenario: Sync with a static API token from environment variables
    Given the env vars for API URL and a static API token are set
    And the encryption key env var is exported
    When I run a sync
    Then config resolves from the environment without contacting any auth endpoint
    And the sync uses the static API token as a bearer token unchanged

  Scenario: Sync with a static API token from config.json
    Given no sync env vars are set
    And a config.json holds an HTTPS API URL and a static API token
    When I run a sync
    Then config resolves from the file without contacting any auth endpoint
    And the sync proceeds unchanged
```

## Feature: Cloud mode registration

```gherkin
Feature: Cloud mode registration
  As a new cloud user
  I want to register a tenant and receive an API token
  So that I can sync against the author's hosted Worker without deploying anything

  Scenario: Register a new tenant and persist the API token
    Given a cloud auth endpoint over HTTPS
    And no existing tenant for my email
    When I register with a fresh email and password
    Then I receive an API token
    And the token is persisted to config.json with mode 0o600
    And a later sync uses that token and succeeds

  Scenario: Register with an already-taken email
    Given a tenant already exists for my email
    When I register with that email
    Then I receive a clear "account already exists" error
    And no token is persisted

  Scenario: Registration is rejected over plain HTTP
    Given an auth endpoint URL that uses http rather than https
    When I attempt to register
    Then registration is refused before any network call
    And the error states HTTPS is required
```

## Feature: Cloud mode login

```gherkin
Feature: Cloud mode login
  As an existing cloud user on a new device
  I want to log in and receive an API token
  So that the new device can sync

  Scenario: Log in from a new device
    Given a tenant exists for my email
    And I am on a device with no stored token
    When I log in with correct credentials
    Then I receive an API token
    And the token is persisted to config.json
    And a later sync from this device succeeds

  Scenario: Log in with wrong password
    Given a tenant exists for my email
    When I log in with an incorrect password
    Then I receive a generic "invalid credentials" error
    And the error does not reveal whether the tenant exists
    And no token is persisted

  Scenario: Log in for a non-existent tenant
    Given no tenant exists for my email
    When I log in with that email
    Then I receive the same generic "invalid credentials" error as a wrong password
    And the error does not reveal that the tenant is missing
```

## Feature: Mode-agnostic sync path

```gherkin
Feature: Mode-agnostic sync path
  As the kit
  I want the sync path to be byte-identical regardless of how the API token was obtained
  So that cloud mode adds no special-casing to sync

  Scenario Outline: Sync behaves identically for any token source
    Given a SyncConfig whose API token was obtained via <source>
    When I run push, pull, and delete
    Then the requests carry the same Authorization bearer header shape
    And the same /api/v1/<entity> routes are used
    And no request differs based on how the token was obtained

    Examples:
      | source                  |
      | static env var          |
      | static config.json      |
      | cloud register response |
      | cloud login response    |
```

## Feature: API version compatibility

```gherkin
Feature: API version compatibility between kit and Worker
  As a user running an older or newer client
  I want a clear warning when client and Worker API versions diverge
  So that I can update before subtle breakage occurs

  Scenario: Client and Worker API versions match
    Given the Worker reports its API version via the response header
    And it equals the client's version
    When I run a sync
    Then no version warning is emitted

  Scenario: Worker reports a different API version than the client
    Given the Worker reports an API version different from the client's
    When I run a sync
    Then a single non-fatal warning is surfaced to the user
    And the sync still proceeds

  Scenario: Worker omits the API version header
    Given the Worker response carries no API version header
    When I run a sync
    Then the client treats the version as unknown and does not crash
    And no warning is emitted

  Scenario: Version warning is emitted at most once per process
    Given the Worker reports a different API version
    When I run several batched requests in one process
    Then the version warning is printed only once
```

## Feature: Encryption stays client-side in cloud mode

```gherkin
Feature: Encryption is client-side in cloud mode
  As a privacy-conscious cloud user
  I want the encryption key to remain on my devices
  So that the operator never sees my plaintext

  Scenario: Cloud sync still requires the local encryption key to read content
    Given a SyncConfig whose apiToken is "tok_live_abc123" obtained from cloud login
    And the encryption key env var is not set
    When I attempt to decrypt pulled records
    Then decryption fails with "key not configured"
    And no plaintext was ever sent to the Worker

  Scenario: A new logged-in device without the key cannot read content
    Given a new device holding apiToken "tok_live_abc123" from a prior cloud login
    And the device does not have the encryption key
    When it pulls records
    Then it receives only ciphertext
    And it cannot decrypt any record until the key is provided
```

## Feature (@worker): Server-side tenant isolation

```gherkin
@worker
Feature: Server-side tenant isolation
  As the cloud operator
  I want each API token scoped to exactly one tenant server-side
  So that tenants can never read or write each other's data

  Scenario: A token cannot access another tenant's data
    Given tenant A and tenant B each have records
    When a request presents tenant A's token against tenant B's records
    Then the response contains no tenant B data
    And the tenant is derived from the token, never from the client device id

  Scenario: A spoofed device id does not cross tenant boundaries
    Given a request with tenant A's token
    And a device id belonging to tenant B
    When the request is processed
    Then it is still scoped to tenant A only
```

## Feature (@worker): Public registration abuse controls

```gherkin
@worker
Feature: Public registration abuse controls
  As the cloud operator
  I want registration and login throttled
  So that the open endpoints cannot be abused at scale

  Scenario: Repeated registration attempts are rate-limited
    Given many registration attempts from one source in a short window
    When the limit is exceeded
    Then further attempts are throttled

  Scenario: Repeated failed logins are throttled
    Given many failed login attempts for one tenant
    When the threshold is crossed
    Then further attempts are temporarily refused
```

## Feature (@worker): Single Worker codebase, two modes

```gherkin
@worker
Feature: One Worker codebase serves both modes
  As a self-hoster
  I want to run the same Worker the author runs
  So that self-host and cloud share one trusted, maintained codebase

  Scenario: Self-host deployment with CLOUD_MODE off
    Given the Worker is deployed with CLOUD_MODE off
    Then the auth endpoints are absent
    And a single static configured token is honored
    And no tenant scoping is applied

  Scenario: Cloud deployment with CLOUD_MODE on
    Given the Worker is deployed with CLOUD_MODE on
    Then the register and login endpoints are available
    And every request is tenant-scoped from its token
```
</content>
