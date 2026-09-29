# proto-zonyx-alerts

Protocol contract repository for the Zonyx Alerts API: ingestion of indoor-location
and tag-info events, tag registration, alert rule
management, and alert history. The event schema is provider-agnostic; events
from a location provider are translated into it by the publisher.

This is a standalone system — it does not share data, tags, or users with the
NagiZone platform.

## Contract model

| Service               | Purpose                                                                        |
| --------------------- | ------------------------------------------------------------------------------ |
| `IngestService`       | HTTP ingest targets for location and tag-info events, independent of the channel |
| `TagRegistryService`  | Register/manage tags (phone numbers, status, battery)                          |
| `RuleEngineService`   | CRUD for alert suppression/trigger rules (zones, tags, time windows, priority) |
| `AlertHistoryService` | Read-only query of sent/suppressed/failed alerts                               |

All services support HTTP mapping through grpc-gateway.

## RPC reference

| RPC                    | HTTP                       | Request                       | Response                       |
| ---------------------- | -------------------------- | ----------------------------- | ------------------------------ |
| `IngestLocationUpdate` | `POST /v1/ingest/location` | `IngestLocationUpdateRequest` | `IngestLocationUpdateResponse` |
| `IngestTagInfoUpdate`  | `POST /v1/ingest/info`     | `IngestTagInfoUpdateRequest`  | `IngestTagInfoUpdateResponse`  |
| `RegisterTag`          | `POST /v1/tags`            | `RegisterTagRequest`          | `RegisterTagResponse`          |
| `GetTag`               | `GET /v1/tags/{id}`        | `GetTagRequest`               | `GetTagResponse`               |
| `UpdateTag`            | `PATCH /v1/tags/{id}`      | `UpdateTagRequest`            | `UpdateTagResponse`            |
| `ListTags`             | `GET /v1/tags`             | `ListTagsRequest`             | `ListTagsResponse`             |
| `DeactivateTag`        | `POST /v1/tags/{id}:deactivate` | `DeactivateTagRequest`        | `DeactivateTagResponse`        |
| `CreateRule`           | `POST /v1/rules`           | `CreateRuleRequest`           | `CreateRuleResponse`           |
| `GetRule`              | `GET /v1/rules/{id}`       | `GetRuleRequest`              | `GetRuleResponse`              |
| `UpdateRule`           | `PATCH /v1/rules/{id}`     | `UpdateRuleRequest`           | `UpdateRuleResponse`           |
| `DeleteRule`           | `DELETE /v1/rules/{id}`    | `DeleteRuleRequest`           | `DeleteRuleResponse`           |
| `ListRules`            | `GET /v1/rules`            | `ListRulesRequest`            | `ListRulesResponse`            |
| `ListAlerts`           | `GET /v1/alerts`           | `ListAlertsRequest`           | `ListAlertsResponse`           |

## Ingest payloads

`IngestService` is independent of the delivery channel: the request body is the
JSON event itself, with no transport envelope. It is one of:

- `LocationEvent` — tag position, zones, movement status.
- `TagInfoEvent` — battery, radio, tag health telemetry.

Each event carries an `event_id`, assigned by the publisher (a UUID, or a hash of
`tag_id` and the event timestamp) and kept across redeliveries. Delivery is
at-least-once: alert creation is idempotent on `event_id` + `zone_id` +
`phone_number`. A 2xx response confirms the event; a non-2xx response may make
the channel deliver it again.

### Delivery channels

Channels are deployment choices, not part of the contract. Any channel that
POSTs the event as the JSON body, with `Content-Type: application/json` and the
service's bearer authentication, works:

- **Pub/Sub push with payload unwrapping**: create the push subscription with
  `--push-no-wrapper` (delivers the raw message data as the body) and
  `--push-no-wrapper-write-metadata`, and publish each message with the
  attribute `Content-Type: application/json` (attributes only reach the request
  as headers when write metadata is on). Use `tag_id` as the ordering key if
  per-tag order matters. See
  https://docs.cloud.google.com/pubsub/docs/payload-unwrapping.
- **Cloud Tasks**: create HTTP tasks whose body is the event JSON.
- **Direct HTTP**: the publisher calls the endpoint itself.

## Alert evaluation

How events become alerts (triggers, rule matching, overlapping rules, cooldown,
alert records, rule and tag semantics, ingest responses, worked examples and
requirements for the implementing service) is specified in
[docs/ALERT_EVALUATION.md](docs/ALERT_EVALUATION.md). In short:

- Alerts are raised by two triggers, derived by comparing a tag's zones with the
  previous event: `ZONE_ENTRY` (a zone newly present) and `SIGNAL_LOST` (the tag
  was in a zone and its zone list is now empty).
- Each (tag, zone, trigger) is resolved by exactly one rule. Rules may overlap; the
  highest `priority` decides, then `SUPPRESS` over `ALERT`, then the oldest rule.
  With no matching rule nothing happens.
- `ALERT` rules can set a `cooldown_seconds` per tag and zone.
- One `Alert` is stored per event, zone, trigger and phone number.

## Message reference

### Tag

| Field                | Type        | Notes                                   |
| -------------------- | ----------- | --------------------------------------- |
| `id`                 | `string`    | The event `tag_id`                      |
| `phone_numbers`      | `string[]`  | E.164, 1 to 10, unique                  |
| `status`             | `TagStatus` | `ACTIVE` / `INACTIVE`                   |
| `battery_voltage`    | `float`     | Optional, from the latest tag info      |
| `battery_alarm`      | `BatteryAlarm` | Optional, `OK` / `LOW`, from the latest tag info |
| `created_at`         | `Timestamp` |                                         |
| `updated_at`         | `Timestamp` |                                         |

### Rule

| Field              | Type           | Notes                                                       |
| ------------------ | -------------- | ----------------------------------------------------------- |
| `id`               | `string`       |                                                             |
| `name`             | `string`       | Not unique                                                  |
| `enabled`          | `bool`         |                                                             |
| `trigger`          | `AlertTrigger` | `ZONE_ENTRY` / `SIGNAL_LOST`                                |
| `zone_selector`    | `ZoneSelector` | `zone_ids`; empty = every zone                              |
| `tag_selector`     | `TagSelector`  | `tag_ids` or `tag_group_names`; empty = every tag           |
| `time_window`      | `TimeWindow`   | Days, `HH:MM` start (inclusive) / end (exclusive), IANA timezone; empty = always; may cross midnight |
| `action`           | `RuleAction`   | `SUPPRESS` / `ALERT`                                        |
| `priority`         | `int32`        | Higher wins                                                 |
| `cooldown_seconds` | `uint32`       | `ALERT` only, 0 to 86400; 0 = no limit                      |
| `created_at`       | `Timestamp`    |                                                             |
| `updated_at`       | `Timestamp`    |                                                             |

### Alert

| Field             | Type          | Notes                            |
| ----------------- | ------------- | -------------------------------- |
| `id`              | `string`      |                                  |
| `tag_id`          | `string`      |                                  |
| `zone_id`         | `string`      |                                  |
| `phone_number`    | `string`      |                                  |
| `status`          | `AlertStatus` | `SENT` / `SUPPRESSED` / `FAILED` |
| `trigger`         | `AlertTrigger`| `ZONE_ENTRY` / `SIGNAL_LOST`     |
| `suppression_reason` | `AlertSuppressionReason` | `RULE` / `COOLDOWN`; only when `SUPPRESSED` |
| `matched_rule_id` | `string`      | The deciding rule; may be deleted since |
| `failure_reason`  | `string`      | Optional                         |
| `triggered_at`    | `Timestamp`   |                                  |
| `zone_name`       | `string`      | Optional                         |
| `event_time`      | `Timestamp`   | `location_ts` of the triggering event |
| `event_id`        | `string`      | `event_id` of the triggering event |
| `delivered_to`    | `AlertDeliveryTarget` | `NETWORK` / `DEVICE`; only when `SENT` |
| `channel`         | `AlertChannel` | `SMS`; when `SENT` or `FAILED`  |
| `delivery_status` | `string`      | Optional, provider status as reported (e.g. `DELIVERED_TO_OPERATOR`) |

## Validation and security metadata

The contract uses Protovalidate rules (`buf.validate`) for string/numeric
bounds, required fields, repeated cardinality, and non-zero enum constraints.
The generated OpenAPI 3.1 document declares bearer-token security (HTTP `Authorization: Bearer <token>`); it is applied by `scripts/generate.sh`.

## Repository layout

- `api/proto/v1`: protobuf definitions.
- `pkg/api`: generated Go artifacts.
- `docs/openapi`: generated OpenAPI 3.1 files and `versions.txt`.
- `scripts`: generation scripts.

## Build and generation

### Prerequisites

- Buf CLI installed.
- `jq` installed.

Reference: https://buf.build/docs/installation

### Generate contract artifacts

```bash
./scripts/generate.sh
```

Generation pipeline:

1. Checks formatting (`buf format --exit-code`; fix with `buf format -w`).
2. Runs Buf lint.
3. Optionally checks breaking changes when `BREAKING_AGAINST` is set, e.g.
   `BREAKING_AGAINST='.git#branch=master' ./scripts/generate.sh`.
4. Generates protobuf/grpc/gateway code into `pkg/api` and OpenAPI 3.1 files
   into `docs/openapi` (`buf.gen.yaml` cleans both directories first; remote
   plugin versions are pinned and `go_package` is set by managed mode).
5. Sets the OpenAPI `info` and bearer security scheme with `jq` (required).
6. Regenerates `docs/openapi/versions.txt`.

Dependencies are not updated on each run. After changing `deps` in `buf.yaml`,
run `buf dep update` and commit `buf.lock`.

## Documentation artifacts

Generated files include:

- `docs/openapi/v1/index.openapi.json`
- `docs/openapi/versions.txt`

You can use `docs/index.html` as a static entrypoint to browse the generated OpenAPI versions with Scalar (served from any static host).
